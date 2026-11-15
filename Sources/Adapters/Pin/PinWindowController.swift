import AppKit
import CoreGraphics

/// 贴图（Pin）控制器：每张贴图一个实例，静态数组持有防提前释放，关闭时移除。
/// 入口：PinWindowController.pin(_:atGlobalRect:on:)，多张贴图互不影响（各自 scale/alpha/窗口）。
///
/// 拖动模型（设计定稿 §1.1，弃 performDrag 裁决）：AppKit performDrag 的内部
/// 事件循环让视图收不到 mouseDragged → 磁吸无从计算。普通拖 / ⌘组拖 / ⌥拆组拖
/// 统一手动 setFrameOrigin（主线程逐帧，模式来源：已验证的 beginOptionDrag），
/// 拖动中 MagnetEngine 实时吸附预览，mouseUp 提交 union。
@MainActor
final class PinWindowController {
    // MARK: - 常量

    static let minScale: CGFloat = 0.1   // 10%
    static let maxScale: CGFloat = 5.0   // 500%
    static let minAlpha: CGFloat = 0.2   // 20%
    static let maxAlpha: CGFloat = 1.0   // 100%
    static let zoomSensitivity: CGFloat = 0.1    // 每单位 deltaY 的缩放步进
    static let alphaSensitivity: CGFloat = 0.05  // 每单位 deltaY 的透明度步进
    static let hudFadeDelay: Duration = .seconds(1)
    static let hudFadeDuration: TimeInterval = 0.25

    /// 成组视觉（§1.3）：8pt 白垫 + 1px 描边 = 窗体每侧外扩 9pt；圆角 10 在视图绘制
    static let groupPad: CGFloat = 8
    static let groupBorder: CGFloat = 1
    static var groupPadTotal: CGFloat { groupPad + groupBorder }

    private static let logCategory: LogCategory = .pin

    // MARK: - 存活贴图注册

    /// 控制器持有的静态数组：窗口关闭前实例不会被 ARC 回收（防提前释放）
    private static var live: [PinWindowController] = []
    static var livePins: [PinWindowController] { live }

    // MARK: - 状态

    let image: CGImage
    /// 100% 时的全局 frame（points，AppKit 全局坐标 Y-up）
    private let baseRect: CGRect
    private let window: PinWindow
    let contentView: PinContentView
    private(set) var scale: CGFloat = 1
    private var alpha: CGFloat = 1
    private var hudHideTask: Task<Void, Never>?

    /// 成组视觉标志（白垫/描边由视图绘制；窗体 frame 外扩 9pt，setInGroup 驱动）
    private(set) var inGroup = false

    var windowFrame: CGRect { window.frame }

    /// 成组/未成组下的外框换算：inset=true 时未成组窗体外扩 9pt（虚拟外框空间）
    func windowFrame(insetByGroupPad inset: Bool) -> CGRect {
        guard inset, !inGroup else { return window.frame }
        return window.frame.insetBy(dx: -Self.groupPadTotal, dy: -Self.groupPadTotal)
    }

    // MARK: - 手动拖动状态（磁吸）

    private struct DragState {
        /// 光标相对窗口左上角（视觉）的偏移；拖动中保持不变
        var grabOffset: CGPoint
        var originalFrame: CGRect
        var groupDrag: Bool
        /// ⌥拖 = 拆组拖（按下即脱离所在组）
        var detach: Bool
        /// 当前吸附预览（mouseUp 提交 union）
        var snapped: (partner: PinWindowController, edge: MagnetEdge)?
        /// ⌘组拖的成员起始 frame（外框空间 = 窗体 frame，成员皆已成组）
        var members: [(pin: PinWindowController, startFrame: CGRect)]
    }

    private var drag: DragState?

    // MARK: - 入口

    /// 贴一张图：窗口 frame = rect（全局 points），图像 1:1 绘制。
    /// rect 应满足 rect.size × screen.backingScaleFactor == image 像素尺寸，保证像素精确。
    static func pin(_ image: CGImage, atGlobalRect rect: CGRect, on screen: NSScreen) {
        let controller = PinWindowController(image: image, atGlobalRect: rect, on: screen)
        live.append(controller)
        controller.showWindow()
        PinMagnetRegistry.shared.register(controller)
        let screenScale = screen.backingScaleFactor
        Log.event(logCategory, "pin.create", [
            "w": "\(Int(rect.width))",
            "h": "\(Int(rect.height))",
            "pxW": "\(Int(rect.width * screenScale))",
            "pxH": "\(Int(rect.height * screenScale))",
            "count": "\(live.count)",
        ])
    }

    private init(image: CGImage, atGlobalRect rect: CGRect, on screen: NSScreen) {
        self.image = image
        self.baseRect = rect

        let win = PinWindow(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false // 生命周期由静态数组管理，不走 close() 自动释放

        let content = PinContentView(frame: NSRect(origin: .zero, size: rect.size))
        self.window = win
        self.contentView = content
        content.controller = self
        win.contentView = content
        win.initialFirstResponder = content // Esc keyDown 走视图响应链
    }

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 成组视觉（PinMagnetRegistry 驱动）

    /// 成组：窗体外扩 9pt（白垫 8 + 描边 1）；摘组：收回。
    /// 图像始终画在内缩 9pt 的矩形里 ⇒ 成组/摘组图像全局位置零跳变。
    func setInGroup(_ value: Bool) {
        guard inGroup != value else { return }
        inGroup = value
        let pad = Self.groupPadTotal
        let frame = window.frame
        let next = value
            ? frame.insetBy(dx: -pad, dy: -pad)
            : frame.insetBy(dx: pad, dy: pad)
        window.setFrame(next, display: true)
        contentView.needsDisplay = true
    }

    /// 组拖/框拖用：显式落位（registry 直接驱动成员窗体）
    func setFrameOrigin(_ origin: CGPoint) {
        window.setFrameOrigin(origin)
    }

    // MARK: - 手动拖动 + 磁吸

    /// mouseDown：记录 grabOffset（照抄原 ⌥拖模式）。
    /// ⌘按下 = 组刚体拖（所在组全体，含吸附）；⌥按下 = 拆组拖。
    func beginDrag(groupDrag: Bool, detach: Bool = false) {
        let frame = window.frame
        let mouse = NSEvent.mouseLocation
        var state = DragState(
            grabOffset: CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y),
            originalFrame: frame,
            groupDrag: groupDrag && PinMagnetRegistry.shared.groupID(for: self) != nil,
            detach: detach,
            snapped: nil,
            members: []
        )
        if detach {
            PinMagnetRegistry.shared.detach(self)
            showHUD("已移出拼贴组")
        }
        if state.groupDrag {
            let members = PinMagnetRegistry.shared.groupMembers(of: self)
            state.members = members.map { ($0, $0.windowFrame) }
        }
        drag = state
        window.makeKeyAndOrderFront(nil)
    }

    /// mouseDragged：新 frame = 光标 - grabOffset → MagnetEngine 吸附预览 → 落位。
    /// - Parameter candidateOrigin: 显式候选原点（--selftest-magnet 用；nil = 跟随光标）
    func dragMoved(candidateOrigin explicit: CGPoint? = nil) {
        guard var state = drag else { return }
        let frame = window.frame
        let origin: CGPoint
        if let explicit {
            origin = explicit
        } else {
            let mouse = NSEvent.mouseLocation
            origin = CGPoint(
                x: mouse.x - state.grabOffset.x,
                y: mouse.y + state.grabOffset.y - frame.height
            )
        }

        if state.groupDrag {
            dragGroupMoved(state: &state, selfOrigin: origin)
        } else {
            dragSoloMoved(state: &state, origin: origin)
        }
    }

    /// 单卡拖（含组内单卡重排）：移动盒 = 本卡外框
    private func dragSoloMoved(state: inout DragState, origin: CGPoint) {
        let candidate = CGRect(origin: origin, size: window.frame.size)
        let padTotal = inGroup ? 0 : Self.groupPadTotal
        let candidateOuter = candidate.insetBy(dx: -padTotal, dy: -padTotal)
        let others = PinMagnetRegistry.shared.snapCandidates(
            excluding: [self],
            ignoreGroupOf: state.detach ? self : nil
        )
        let active = state.snapped.map { (PinMagnetRegistry.id(of: $0.partner), $0.edge) }

        guard let outcome = MagnetGroup.snap(candidate: candidateOuter, others: others, active: active) else {
            if state.snapped != nil {
                Log.event(Self.logCategory, "collage.magnet.release", [:])
                state.snapped?.partner.contentView.setSnapGlow(false)
                state.snapped = nil
                drag = state
                contentView.setSnapGlow(false)
                showHUD("已分离")
            }
            window.setFrameOrigin(candidate.origin)
            PinMagnetRegistry.shared.notifyLayoutChanged(self)
            return
        }

        let total = CGSize(
            width: outcome.frame.minX - candidateOuter.minX,
            height: outcome.frame.minY - candidateOuter.minY
        )
        window.setFrameOrigin(candidate.origin.offsetBy(total))
        applySnapPreview(state: &state, outcome: outcome)
        PinMagnetRegistry.shared.notifyLayoutChanged(self)
    }

    /// ⌘组拖：所在组 union rect 整体平移（外框空间），吸附判定 = 整组包围盒
    private func dragGroupMoved(state: inout DragState, selfOrigin: CGPoint) {
        guard !state.members.isEmpty else {
            dragSoloMoved(state: &state, origin: selfOrigin)
            return
        }
        let selfDelta = CGSize(
            width: selfOrigin.x - state.originalFrame.minX,
            height: selfOrigin.y - state.originalFrame.minY
        )
        let startUnion = MagnetGroup.unionRect(state.members.map { $0.startFrame })
        let candidate = startUnion.offsetBy(dx: selfDelta.width, dy: selfDelta.height)
        let others = PinMagnetRegistry.shared.snapCandidates(excluding: state.members.map { $0.pin })
        let active = state.snapped.map { (PinMagnetRegistry.id(of: $0.partner), $0.edge) }

        guard let outcome = MagnetGroup.snap(candidate: candidate, others: others, active: active) else {
            if state.snapped != nil {
                Log.event(Self.logCategory, "collage.magnet.release", [:])
                state.snapped?.partner.contentView.setSnapGlow(false)
                state.snapped = nil
                drag = state
                showHUD("已分离")
            }
            moveMembers(state, delta: selfDelta)
            PinMagnetRegistry.shared.notifyLayoutChanged(self)
            return
        }

        let total = CGSize(
            width: selfDelta.width + (outcome.frame.minX - candidate.minX),
            height: selfDelta.height + (outcome.frame.minY - candidate.minY)
        )
        moveMembers(state, delta: total)
        applySnapPreview(state: &state, outcome: outcome)
        PinMagnetRegistry.shared.notifyLayoutChanged(self)
    }

    private func moveMembers(_ state: DragState, delta: CGSize) {
        for (pin, startFrame) in state.members {
            pin.setFrameOrigin(startFrame.origin.offsetBy(delta))
        }
    }

    /// 吸附预览反馈：目标卡发光 + 移动卡描边高亮（union 不提交，等 mouseUp）
    private func applySnapPreview(state: inout DragState, outcome: MagnetSnapOutcome) {
        let partner = PinMagnetRegistry.shared.pin(byID: outcome.partnerID)
        if state.snapped?.partner !== partner || state.snapped?.edge != outcome.edge {
            state.snapped?.partner.contentView.setSnapGlow(false)
            partner?.contentView.setSnapGlow(true)
            contentView.setSnapGlow(true)
            showHUD("已吸附 · 松手成组")
        }
        state.snapped = partner.map { ($0, outcome.edge) }
        drag = state
    }

    /// mouseUp：吸附生效 → UnionGroup（collage.magnet.snap）；否则保持落位
    func endDrag() {
        guard let state = drag else { return }
        drag = nil
        state.snapped?.partner.contentView.setSnapGlow(false)
        contentView.setSnapGlow(false)
        if let snap = state.snapped {
            Log.event(Self.logCategory, "collage.magnet.snap", [
                "edge": snap.edge.rawValue,
                "partner": PinMagnetRegistry.id(of: snap.partner),
                "groupDrag": "\(state.groupDrag)",
            ])
            PinMagnetRegistry.shared.union(self, snap.partner)
        }
        if state.groupDrag, let gid = PinMagnetRegistry.shared.groupID(for: self) {
            PinMagnetRegistry.shared.refreshLayout(groupID: gid)
        }
    }

    // MARK: - 缩放（滚轮 / 双击复位，光标锚点）

    func handleScroll(_ event: NSEvent, anchor: CGPoint) {
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return }
        if event.modifierFlags.contains(.option) {
            let newAlpha = min(max(alpha + deltaY * Self.alphaSensitivity, Self.minAlpha), Self.maxAlpha)
            guard newAlpha != alpha else { return }
            alpha = newAlpha
            window.alphaValue = alpha
            showHUD("α \(Int(round(alpha * 100)))%")
            Log.event(Self.logCategory, "pin.alpha", ["alpha": "\(Int(round(alpha * 100)))"])
        } else {
            applyZoom(factor: 1 + deltaY * Self.zoomSensitivity, anchor: anchor)
        }
    }

    /// factor 缩放（自动夹取 10%–500%），锚点 viewPoint 为视图内坐标（Y-down）
    func applyZoom(factor: CGFloat, anchor viewPoint: CGPoint) {
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        guard abs(newScale - scale) > 0.0001 else { return }
        reframe(scale: newScale, anchor: viewPoint)
        scale = newScale
        contentView.needsDisplay = true
        showHUD("\(Int(round(scale * 100)))%")
        Log.event(Self.logCategory, "pin.zoom", ["scale": "\(Int(round(scale * 100)))"])
        PinMagnetRegistry.shared.notifyLayoutChanged(self)
    }

    /// 双击 / 菜单复位到 100%
    func resetZoom(anchor: CGPoint) {
        guard abs(scale - 1) > 0.0001 else { return }
        reframe(scale: 1, anchor: anchor)
        scale = 1
        contentView.needsDisplay = true
        showHUD("100%")
        Log.event(Self.logCategory, "pin.zoom", ["scale": "100"])
        PinMagnetRegistry.shared.notifyLayoutChanged(self)
    }

    /// 核心锚点数学：缩放前后光标下的图像点保持不动。
    /// 锚点 q（100% 图像坐标）= v / scale；新视图坐标 v' = q × newScale；
    /// 平移窗口使 v' 落在原光标全局位置上（全局 Y-up ↔ 视图 Y-down 换算见内）。
    /// 成组时窗体比图像每侧多 9pt 垫：锚点/落位全部按图像矩形计算，垫保持 9pt 不缩放。
    private func reframe(scale newScale: CGFloat, anchor viewPoint: CGPoint) {
        guard let win = contentView.window,
              scale > 0, baseRect.width > 0, baseRect.height > 0 else { return }
        let pad = inGroup ? Self.groupPadTotal : 0
        let v = viewPoint

        // 锚点在 100% 图像里的坐标（图像相对窗体内缩 pad）
        let anchorInBaseX = (v.x - pad) / scale
        let anchorInBaseY = (v.y - pad) / scale

        let frame = win.frame
        // 光标全局位置（Y-up）：窗口左上角 + (v.x, -v.y)
        let cursorGlobalX = frame.minX + v.x
        let cursorGlobalY = frame.maxY - v.y

        let imgWidth = baseRect.width * newScale
        let imgHeight = baseRect.height * newScale
        // 新图像矩形左上角（全局，Y-up）：锚点新视图坐标反向推
        let imgLeft = cursorGlobalX - anchorInBaseX * newScale
        let imgTop = cursorGlobalY + anchorInBaseY * newScale
        win.setFrame(
            CGRect(
                x: imgLeft - pad,
                y: imgTop - pad - imgHeight,
                width: imgWidth + pad * 2,
                height: imgHeight + pad * 2
            ),
            display: true
        )
    }

    // MARK: - 右键菜单动作

    func copyImageToPasteboard() {
        let ok = ClipboardWriter.writeImage(image) // 复用 Clipboard 模块：PNG+TIFF 双格式
        Log.event(Self.logCategory, "pin.copy", ["ok": "\(ok)"])
    }

    // MARK: - 自测钩子（--selftest-magnet：不注入真实事件，显式驱动拖动状态机）

    /// 吸附预览是否生效（selftest 断言用）
    var selfTestSnapped: Bool { drag?.snapped != nil }

    // MARK: - 关闭

    func close() {
        drag = nil
        hudHideTask?.cancel()
        hudHideTask = nil
        window.orderOut(nil)
        PinMagnetRegistry.shared.remove(self)
        Self.remove(self)
        Log.event(Self.logCategory, "pin.close", ["count": "\(Self.live.count)"])
    }

    private static func remove(_ controller: PinWindowController) {
        live.removeAll { $0 === controller }
    }

    // MARK: - HUD 淡出

    /// HUD 显示（internal：PinContentView 拖拽悬停提示同文件跨类型调用）
    func showHUD(_ text: String) {
        contentView.showHUD(text: text)
        hudHideTask?.cancel()
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hudFadeDelay)
            guard !Task.isCancelled else { return }
            self?.fadeHUDOut()
        }
    }

    private func fadeHUDOut() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hudFadeDuration
            self.contentView.hud.animator().alphaValue = 0
        }
    }
}

private extension CGPoint {
    func offsetBy(_ size: CGSize) -> CGPoint {
        CGPoint(x: x + size.width, y: y + size.height)
    }
}
