import AppKit
import CoreGraphics

/// 贴图（Pin）控制器：每张贴图一个实例，静态数组持有防提前释放，关闭时移除。
/// 入口：PinWindowController.pin(_:atGlobalRect:on:)，多张贴图互不影响（各自 scale/alpha/窗口）。
///
/// 拖动与拼贴模型（用户裁定 2026-11-20）：
/// - 直接拖单卡 = 1:1 丝滑自由移动（零中途阻力/死区）；若单卡原属某拼贴组，拖远（>44pt）松手自动自然脱离，拖在附近松手保持同组微调；
/// - 靠近其他贴图进入吸附区 = 仅展示视觉预览（鬼影落位框 + 软对齐参考线），松手后顺滑滑入贴合位成组；
/// - 拖顶部悬浮栏 / 磨砂玻璃托盘 / ⌘+拖 = 整组刚体移动。
@MainActor
final class PinWindowController {
    // MARK: - 常量

    static let minScale: CGFloat = 0.1   // 10%
    static let maxScale: CGFloat = 5.0   // 500%
    static let minAlpha: CGFloat = 0.2   // 20%
    static let maxAlpha: CGFloat = 1.0   // 100%
    static let zoomSensitivity: CGFloat = 0.1
    static let alphaSensitivity: CGFloat = 0.05
    static let hudFadeDelay: Duration = .seconds(1)
    static let hudFadeDuration: TimeInterval = 0.25

    private static let logCategory: LogCategory = .pin

    // MARK: - 存活贴图注册

    private static var live: [PinWindowController] = []
    static var livePins: [PinWindowController] { live }
    private(set) static var areAllPinsHidden = false
    static var hasLivePins: Bool { !live.isEmpty }

    // MARK: - 状态

    let image: CGImage
    /// 100% 时的全局 frame（points，AppKit 全局坐标 Y-up，严格保持原图宽高比）
    private let baseRect: CGRect
    /// 原生 1:1 像素清晰度对应的 scale（普通截图 ≈ 1.0；长图初始缩放到屏高时 > 1.0）
    private let nativeScaleFactor: CGFloat
    /// 动态最大缩放倍数：超长滚动图可平滑放大到原生清晰度，同时不越过 WindowServer 安全位图上限
    private let effectiveMaxScale: CGFloat
    private let window: PinWindow
    let contentView: PinContentView
    private(set) var scale: CGFloat = 1
    private var alpha: CGFloat = 1
    private var hudHideTask: Task<Void, Never>?

    /// 是否处于某个拼贴组内（视觉归属由底层统一磨砂玻璃托盘承担，本窗尺寸零跳变）
    private(set) var inGroup = false

    var windowFrame: CGRect { window.frame }

    // MARK: - 手动拖动状态

    private struct DragState {
        /// 光标相对窗口左上角（视觉）的偏移；拖动中保持不变
        var grabOffset: CGPoint
        var originalFrame: CGRect
        var groupDrag: Bool
        /// ⌥ 强拆快捷修饰键（兼容老习惯；不按 ⌥ 拖远也会自动脱离）
        var forceDetach: Bool
        var pendingForceDetach: Bool = false
        /// 当前松手吸附预览（拖动中仅画视觉预览，不劫持卡片位置；mouseUp 滑入提交）
        var snapOutcome: MagnetSnapOutcome?
        var snapPartner: PinWindowController?
        /// ⌘ 组拖的成员起始 frame
        var members: [(pin: PinWindowController, startFrame: CGRect)]
        /// 单卡直拖出组预览标志（避免频繁重复刷新 alpha）
        var detachingPreview: Bool = false
    }

    private var drag: DragState?

    // MARK: - 入口

    static func pin(_ image: CGImage, atGlobalRect rect: CGRect, on screen: NSScreen) {
        if areAllPinsHidden {
            _ = toggleAllVisibility()
        }
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

    /// 全局一键隐藏/唤回所有贴图及拼贴组托盘/顶栏（Boss Key），完整保留位置、缩放、透明度与分组状态。
    @discardableResult
    static func toggleAllVisibility() -> Bool {
        guard !live.isEmpty else {
            areAllPinsHidden = false
            return false
        }
        if !areAllPinsHidden {
            areAllPinsHidden = true
            SnapPreviewOverlay.shared.hide(immediate: true)
            PinMagnetRegistry.shared.setAllGroupPanelsHidden(true)
            for controller in live {
                controller.window.orderOut(nil)
            }
        } else {
            areAllPinsHidden = false
            PinMagnetRegistry.shared.setAllGroupPanelsHidden(false)
            for controller in live {
                controller.window.orderFrontRegardless()
            }
            PinMagnetRegistry.shared.bringBorderPanelsToFront()
        }
        Log.event(logCategory, "pin.bossKey", [
            "hidden": "\(areAllPinsHidden)",
            "count": "\(live.count)",
        ])
        return areAllPinsHidden
    }

    private static func aspectSafeRect(for image: CGImage, requested rect: CGRect, on screen: NSScreen) -> CGRect {
        let imgW = max(1, CGFloat(image.width))
        let imgH = max(1, CGFloat(image.height))
        let imgAspect = imgW / imgH
        let backing = max(1, screen.backingScaleFactor)
        let visible = screen.visibleFrame

        let rectValid = rect.width >= 20 && rect.height >= 20
        let aspectMatches = rectValid && abs((rect.width / rect.height) - imgAspect) <= 0.04
        let fitsComfortably = rectValid
            && rect.width <= visible.width * 0.95
            && rect.height <= visible.height * 0.95

        if aspectMatches && fitsComfortably {
            return rect
        }

        let logicalW = imgW / backing
        let logicalH = imgH / backing
        let maxW = visible.width * 0.82
        let maxH = visible.height * 0.82
        let fit = min(1.0, min(maxW / logicalW, maxH / logicalH))
        let w = max(60, (logicalW * fit).rounded())
        let h = max(60, (logicalH * fit).rounded())

        let center = rectValid ? CGPoint(x: rect.midX, y: rect.midY) : CGPoint(x: visible.midX, y: visible.midY)
        let x = min(max(center.x - w / 2, visible.minX + 12), visible.maxX - w - 12)
        let y = min(max(center.y - h / 2, visible.minY + 12), visible.maxY - h - 12)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    private init(image: CGImage, atGlobalRect rect: CGRect, on screen: NSScreen) {
        self.image = image
        let safeRect = Self.aspectSafeRect(for: image, requested: rect, on: screen)
        self.baseRect = safeRect
        let backing = max(1, screen.backingScaleFactor)
        let nativeLogicalW = CGFloat(image.width) / backing
        let nativeFactor = max(1.0, nativeLogicalW / max(1, safeRect.width))
        let maxSafeDimPt = min(7200.0, 14400.0 / backing)
        let maxScaleByBacking = maxSafeDimPt / max(1, max(safeRect.width, safeRect.height))
        self.nativeScaleFactor = min(nativeFactor, maxScaleByBacking)
        self.effectiveMaxScale = max(1.0, min(max(Self.maxScale, nativeFactor * 2.5), maxScaleByBacking))

        let win = PinWindow(
            contentRect: safeRect,
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
        win.isReleasedWhenClosed = false

        let content = PinContentView(frame: NSRect(origin: .zero, size: safeRect.size))
        self.window = win
        self.contentView = content
        content.controller = self
        win.contentView = content
        win.initialFirstResponder = content
    }

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 成组标志（窗体尺寸零跳变；统一磨砂玻璃托盘由 PinMagnetRegistry 维护）

    func setInGroup(_ value: Bool) {
        guard inGroup != value else { return }
        inGroup = value
        contentView.needsDisplay = true
    }

    /// 组拖/滑入动画用：显式落位
    func setFrameOrigin(_ origin: CGPoint) {
        window.setFrameOrigin(origin)
    }

    // MARK: - 手动拖动（1:1 自由跟随 + 纯视觉预览 + 松手滑入）

    func beginDrag(groupDrag: Bool, detach: Bool = false) {
        SnapGlideAnimator.shared.cancel()
        let frame = window.frame
        let mouse = NSEvent.mouseLocation
        var state = DragState(
            grabOffset: CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y),
            originalFrame: frame,
            groupDrag: groupDrag && PinMagnetRegistry.shared.groupID(for: self) != nil,
            forceDetach: detach,
            snapOutcome: nil,
            snapPartner: nil,
            members: []
        )
        if detach {
            state.pendingForceDetach = true
        }
        if state.groupDrag {
            let members = PinMagnetRegistry.shared.groupMembers(of: self)
            state.members = members.map { ($0, $0.windowFrame) }
        }
        drag = state
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
    }

    /// mouseDragged：1:1 自由落位 + 视觉吸附预览（绝不在拖动中锁死或劫持窗口位置）
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

        if state.pendingForceDetach {
            let moved = hypot(origin.x - state.originalFrame.minX, origin.y - state.originalFrame.minY)
            if moved > 3 {
                state.pendingForceDetach = false
                state.forceDetach = true
                PinMagnetRegistry.shared.detach(self)
                showHUD("已移出拼贴组")
            }
        }

        if state.groupDrag {
            dragGroupMoved(state: &state, selfOrigin: origin)
        } else {
            dragSoloMoved(state: &state, origin: origin)
        }
        drag = state
    }

    /// 单卡自由拖动：严格 1:1 跟随光标；进入吸附区时仅显示鬼影落位框与软对齐参考线
    private func dragSoloMoved(state: inout DragState, origin: CGPoint) {
        let candidate = CGRect(origin: origin, size: window.frame.size)
        window.setFrameOrigin(origin)

        let others = PinMagnetRegistry.shared.snapCandidates(
            excluding: [self],
            ignoreGroupOf: state.forceDetach ? self : nil
        )
        let outcome = MagnetGroup.previewSnap(candidate: candidate, others: others)
        updateSnapPreview(state: &state, outcome: outcome)

        // 若单卡原本在拼贴组内：拖近同伴时托盘随动，拉远超过脱离阈值时托盘柔和变淡提示「松手即移出」
        if let gid = PinMagnetRegistry.shared.groupID(for: self) {
            let siblingFrames = PinMagnetRegistry.shared.groupMembers(of: self)
                .filter { $0 !== self }
                .map(\.windowFrame)
            let isPullingAway = outcome == nil
                && MagnetGroup.shouldDetach(cardFrame: candidate, otherFrames: siblingFrames)
            if isPullingAway != state.detachingPreview {
                state.detachingPreview = isPullingAway
                PinMagnetRegistry.shared.setDetachingPreview(groupID: gid, isDetaching: isPullingAway)
            }
            if !isPullingAway {
                PinMagnetRegistry.shared.refreshLayout(groupID: gid)
            } else if siblingFrames.count >= 2 {
                PinMagnetRegistry.shared.refreshLayout(groupID: gid, excluding: self)
            }
        }
    }

    /// ⌘ 组刚体拖动：整组 1:1 平移 + 外围吸附预览
    private func dragGroupMoved(state: inout DragState, selfOrigin: CGPoint) {
        guard !state.members.isEmpty else {
            dragSoloMoved(state: &state, origin: selfOrigin)
            return
        }
        let selfDelta = CGSize(
            width: selfOrigin.x - state.originalFrame.minX,
            height: selfOrigin.y - state.originalFrame.minY
        )
        moveMembers(state, delta: selfDelta)

        let startUnion = MagnetGroup.unionRect(state.members.map(\.startFrame))
        let candidate = startUnion.offsetBy(dx: selfDelta.width, dy: selfDelta.height)
        let others = PinMagnetRegistry.shared.snapCandidates(excluding: state.members.map(\.pin))
        let outcome = MagnetGroup.previewSnap(candidate: candidate, others: others)
        updateSnapPreview(state: &state, outcome: outcome)

        PinMagnetRegistry.shared.notifyLayoutChanged(self)
    }

    private func moveMembers(_ state: DragState, delta: CGSize) {
        for (pin, startFrame) in state.members {
            pin.setFrameOrigin(startFrame.origin.offsetBy(delta))
        }
    }

    /// 纯视觉预览更新：鬼影框 + 软对齐参考线 + 对方轻柔边框提示（零卡片位移）
    private func updateSnapPreview(state: inout DragState, outcome: MagnetSnapOutcome?) {
        guard let outcome,
              let partner = PinMagnetRegistry.shared.pin(byID: outcome.partnerID)
        else {
            if let oldPartner = state.snapPartner {
                oldPartner.contentView.setSnapGlow(false)
            }
            if state.snapOutcome != nil {
                SnapPreviewOverlay.shared.hide()
            }
            state.snapOutcome = nil
            state.snapPartner = nil
            return
        }

        if state.snapPartner !== partner {
            state.snapPartner?.contentView.setSnapGlow(false)
            partner.contentView.setSnapGlow(true)
        }
        state.snapOutcome = outcome
        state.snapPartner = partner
        SnapPreviewOverlay.shared.show(outcome: outcome)
    }

    /// mouseUp：
    /// - 若有吸附预览 → 顺滑滑入落位（~160ms）并提交成组 / 组内重排；
    /// - 若无预览且单卡被拉离原组 >44pt → 自然移出拼贴组；
    /// - 若仍在组附近自由微调 → 保持同组，磨砂玻璃托盘贴合新布局。
    func endDrag() {
        guard let state = drag else { return }
        drag = nil

        SnapPreviewOverlay.shared.hide()
        state.snapPartner?.contentView.setSnapGlow(false)
        contentView.setSnapGlow(false)

        if let gid = PinMagnetRegistry.shared.groupID(for: self), state.detachingPreview {
            PinMagnetRegistry.shared.setDetachingPreview(groupID: gid, isDetaching: false)
        }

        if let outcome = state.snapOutcome, let partner = state.snapPartner,
           Self.live.contains(where: { $0 === partner }) {
            Log.event(Self.logCategory, "collage.magnet.snap", [
                "edge": outcome.edge.rawValue,
                "align": outcome.alignKind?.rawValue ?? "free",
                "partner": PinMagnetRegistry.id(of: partner),
                "groupDrag": "\(state.groupDrag)",
            ])

            let glideItems: [(pin: PinWindowController, from: CGPoint, to: CGPoint)]
            if state.groupDrag && !state.members.isEmpty {
                let currentUnion = MagnetGroup.unionRect(state.members.map { $0.pin.windowFrame })
                let delta = CGSize(
                    width: outcome.frame.minX - currentUnion.minX,
                    height: outcome.frame.minY - currentUnion.minY
                )
                glideItems = state.members.map { member in
                    let cur = member.pin.windowFrame.origin
                    return (member.pin, cur, cur.offsetBy(delta))
                }
            } else {
                glideItems = [(self, window.frame.origin, outcome.frame.origin)]
            }

            let isGroupDrag = state.groupDrag
            SnapGlideAnimator.shared.glide(
                items: glideItems,
                onStep: { [weak self] in
                    guard let self else { return }
                    if let gid = PinMagnetRegistry.shared.groupID(for: self) {
                        PinMagnetRegistry.shared.refreshLayout(groupID: gid)
                    }
                },
                onComplete: { [weak self, weak partner] in
                    guard let self, let partner,
                          Self.live.contains(where: { $0 === self }),
                          Self.live.contains(where: { $0 === partner })
                    else { return }
                    // 单卡直拖跨越到另一张孤立卡/另一组时，先从原组自然剥离，再与新伙伴成组（避免误合并整组）
                    if !isGroupDrag,
                       let myGID = PinMagnetRegistry.shared.groupID(for: self),
                       PinMagnetRegistry.shared.groupID(for: partner) != myGID {
                        PinMagnetRegistry.shared.detach(self)
                    }
                    PinMagnetRegistry.shared.union(self, partner)
                }
            )
            return
        }

        // 无吸附预览：单卡若已拖离原组足够远，松手即自然脱离；否则留在原组刷新托盘
        if !state.groupDrag, let gid = PinMagnetRegistry.shared.groupID(for: self) {
            let siblingFrames = PinMagnetRegistry.shared.groupMembers(of: self)
                .filter { $0 !== self }
                .map(\.windowFrame)
            if MagnetGroup.shouldDetach(cardFrame: window.frame, otherFrames: siblingFrames) {
                PinMagnetRegistry.shared.detach(self)
                showHUD("已移出拼贴组")
            } else {
                PinMagnetRegistry.shared.refreshLayout(groupID: gid)
            }
        } else if state.groupDrag, let gid = PinMagnetRegistry.shared.groupID(for: self) {
            PinMagnetRegistry.shared.refreshLayout(groupID: gid)
        }
    }

    // MARK: - 缩放（滚轮 / 双击复位，光标锚点）

    func handleScroll(_ event: NSEvent, anchor: CGPoint) {
        guard event.momentumPhase.isEmpty else { return }
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return }
        if event.modifierFlags.contains(.option) {
            let step = event.hasPreciseScrollingDeltas ? deltaY * 0.004 : deltaY * Self.alphaSensitivity
            let newAlpha = min(max(alpha + step, Self.minAlpha), Self.maxAlpha)
            guard newAlpha != alpha else { return }
            alpha = newAlpha
            window.alphaValue = alpha
            showHUD("α \(Int(round(alpha * 100)))%")
            Log.event(Self.logCategory, "pin.alpha", ["alpha": "\(Int(round(alpha * 100)))"])
        } else {
            let factor: CGFloat
            if event.hasPreciseScrollingDeltas {
                let clamped = min(max(deltaY, -40), 40)
                factor = pow(1.008, clamped)
            } else {
                let clamped = min(max(deltaY, -5), 5)
                factor = pow(1.12, clamped)
            }
            applyZoom(factor: factor, anchor: anchor)
        }
    }

    func applyZoom(factor: CGFloat, anchor viewPoint: CGPoint) {
        guard factor > 0 else { return }
        let newScale = min(max(scale * factor, Self.minScale), effectiveMaxScale)
        guard abs(newScale - scale) > 0.0001 else { return }
        reframe(scale: newScale, anchor: viewPoint)
        scale = newScale
        contentView.needsDisplay = true
        showHUD("\(Int(round(scale * 100)))%")
        Log.event(Self.logCategory, "pin.zoom", ["scale": "\(Int(round(scale * 100)))"])
        PinMagnetRegistry.shared.notifyLayoutChanged(self)
    }

    func toggleDoubleClickZoom(anchor: CGPoint) {
        if nativeScaleFactor > 1.25 && abs(scale - 1.0) < 0.08 {
            let target = min(nativeScaleFactor, effectiveMaxScale)
            reframe(scale: target, anchor: anchor)
            scale = target
            contentView.needsDisplay = true
            showHUD("1:1")
            Log.event(Self.logCategory, "pin.zoom", ["scale": "\(Int(round(scale * 100)))", "mode": "native"])
            PinMagnetRegistry.shared.notifyLayoutChanged(self)
        } else {
            resetZoom(anchor: anchor)
        }
    }

    func resetZoom(anchor: CGPoint) {
        guard abs(scale - 1) > 0.0001 else { return }
        reframe(scale: 1, anchor: anchor)
        scale = 1
        contentView.needsDisplay = true
        showHUD("100%")
        Log.event(Self.logCategory, "pin.zoom", ["scale": "100"])
        PinMagnetRegistry.shared.notifyLayoutChanged(self)
    }

    private func reframe(scale newScale: CGFloat, anchor viewPoint: CGPoint) {
        guard let win = contentView.window,
              scale > 0, baseRect.width > 0, baseRect.height > 0 else { return }
        let v = viewPoint

        let anchorInBaseX = v.x / scale
        let anchorInBaseY = v.y / scale

        let frame = win.frame
        let cursorGlobalX = frame.minX + v.x
        let cursorGlobalY = frame.maxY - v.y

        let imgWidth = baseRect.width * newScale
        let imgHeight = baseRect.height * newScale
        let imgLeft = cursorGlobalX - anchorInBaseX * newScale
        let imgTop = cursorGlobalY + anchorInBaseY * newScale
        win.setFrame(
            CGRect(
                x: imgLeft,
                y: imgTop - imgHeight,
                width: imgWidth,
                height: imgHeight
            ),
            display: true
        )
    }

    // MARK: - 重叠对比透明度（50% ↔ 100%）

    var isCompareOpacityActive: Bool { abs(alpha - 0.5) < 0.04 }

    func toggleCompareOpacity() {
        if isCompareOpacityActive {
            setOpacity(1.0, hudText: "100%", animated: true)
        } else {
            setOpacity(0.5, hudText: "对比 50%", animated: true)
        }
        Log.event(Self.logCategory, "pin.compareOpacity", ["alpha": String(format: "%.2f", alpha)])
    }

    func resetOpacity() {
        let needsChange = abs(alpha - 1.0) > 0.001
        setOpacity(1.0, hudText: "100%", animated: needsChange)
        if needsChange {
            Log.event(Self.logCategory, "pin.compareOpacity", ["alpha": String(format: "%.2f", alpha)])
        }
    }

    private func setOpacity(_ targetAlpha: CGFloat, hudText: String, animated: Bool) {
        let clamped = min(max(targetAlpha, Self.minAlpha), Self.maxAlpha)
        alpha = clamped
        if animated && !DesignTokens.Motion.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                window.animator().alphaValue = clamped
            }
        } else {
            window.alphaValue = clamped
        }
        showHUD(hudText)
    }

    // MARK: - 右键菜单动作

    func copyImageToPasteboard() {
        let ok = ClipboardWriter.writeImage(image)
        Log.event(Self.logCategory, "pin.copy", ["ok": "\(ok)"])
    }

    func ungroupCurrentGroup() {
        guard let gid = PinMagnetRegistry.shared.groupID(for: self) else { return }
        PinMagnetRegistry.shared.dissolveGroup(groupID: gid)
    }

    func closeCurrentGroup() {
        if let gid = PinMagnetRegistry.shared.groupID(for: self) {
            PinMagnetRegistry.shared.closeGroup(groupID: gid)
        } else {
            close()
        }
    }

    // MARK: - 自测钩子

    var selfTestSnapped: Bool { drag?.snapOutcome != nil }

    // MARK: - 关闭

    func close() {
        if drag != nil {
            SnapPreviewOverlay.shared.hide(immediate: true)
            drag?.snapPartner?.contentView.setSnapGlow(false)
            drag = nil
        }
        hudHideTask?.cancel()
        hudHideTask = nil
        window.orderOut(nil)
        PinMagnetRegistry.shared.remove(self)
        Self.remove(self)
        Log.event(Self.logCategory, "pin.close", ["count": "\(Self.live.count)"])
    }

    private static func remove(_ controller: PinWindowController) {
        live.removeAll { $0 === controller }
        if live.isEmpty {
            areAllPinsHidden = false
        }
    }

    // MARK: - HUD 淡出

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
        let hud = contentView.hud
        let sinkFrame = hud.frame
        let reduce = DesignTokens.Motion.reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.fadeDuration
            context.timingFunction = DesignTokens.Motion.easeOutStrong
            hud.animator().alphaValue = 0
            if !reduce {
                hud.animator().setFrameOrigin(CGPoint(x: sinkFrame.minX, y: sinkFrame.minY + 2))
            }
        }
    }
}

private extension CGPoint {
    func offsetBy(_ size: CGSize) -> CGPoint {
        CGPoint(x: x + size.width, y: y + size.height)
    }
}
