import AppKit
import CoreGraphics

/// 贴图（Pin）控制器：每张贴图一个实例，静态数组持有防提前释放，关闭时移除。
/// 入口：PinWindowController.pin(_:atGlobalRect:on:)，多张贴图互不影响（各自 scale/alpha/窗口）。
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

    /// 日志分类：LogCategory 暂无 .pin case（enum case 不能跨文件扩展，改
    /// Sources/Logging/Log.swift 超出本模块「只增不改」边界），暂挂 .overlay。
    /// 主会话接线时若给 LogCategory 增加 .pin，只需替换这一行。
    private static let logCategory: LogCategory = .overlay

    // MARK: - 存活贴图注册

    /// 控制器持有的静态数组：窗口关闭前实例不会被 ARC 回收（防提前释放）
    private static var live: [PinWindowController] = []

    /// ⌥拖合并命中测试：光标全局点落在另一张存活贴图窗口内（不含自己）
    static func hitOtherPin(at globalPoint: CGPoint, excluding: PinWindowController) -> PinWindowController? {
        live.first { $0 !== excluding && $0.window.frame.contains(globalPoint) }
    }

    // MARK: - 状态

    let image: CGImage
    /// 100% 时的全局 frame（points，AppKit 全局坐标 Y-up）
    private let baseRect: CGRect
    private let window: PinWindow
    private let contentView: PinContentView
    private(set) var scale: CGFloat = 1
    private var alpha: CGFloat = 1
    private var hudHideTask: Task<Void, Never>?

    // MARK: - ⌥拖合并手势状态（docs/06 §3a：图 ⌥拖到另一张图上松手 → 成组进拼贴）

    /// grabOffset：按下时光标相对窗口左上角的偏移（Y-up 全局坐标）；拖动中保持不变
    private var optionDrag: (grabOffset: CGPoint, originalFrame: CGRect)?
    /// 悬停命中的合并目标（变化时刷新 HUD 反馈）
    private var optionDragTarget: PinWindowController?

    // MARK: - 入口

    /// 贴一张图：窗口 frame = rect（全局 points），图像 1:1 绘制。
    /// rect 应满足 rect.size × screen.backingScaleFactor == image 像素尺寸，保证像素精确。
    static func pin(_ image: CGImage, atGlobalRect rect: CGRect, on screen: NSScreen) {
        let controller = PinWindowController(image: image, atGlobalRect: rect, on: screen)
        live.append(controller)
        controller.showWindow()
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
    }

    /// 双击 / 菜单复位到 100%
    func resetZoom(anchor: CGPoint) {
        guard abs(scale - 1) > 0.0001 else { return }
        reframe(scale: 1, anchor: anchor)
        scale = 1
        contentView.needsDisplay = true
        showHUD("100%")
        Log.event(Self.logCategory, "pin.zoom", ["scale": "100"])
    }

    /// 核心锚点数学：缩放前后光标下的图像点保持不动。
    /// 锚点 q（100% 图像坐标）= v / scale；新视图坐标 v' = q × newScale；
    /// 平移窗口使 v' 落在原光标全局位置上（全局 Y-up ↔ 视图 Y-down 换算见内）。
    private func reframe(scale newScale: CGFloat, anchor viewPoint: CGPoint) {
        guard let win = contentView.window,
              scale > 0, baseRect.width > 0, baseRect.height > 0 else { return }
        let anchorInBase = CGPoint(x: viewPoint.x / scale, y: viewPoint.y / scale)
        let newAnchor = CGPoint(x: anchorInBase.x * newScale, y: anchorInBase.y * newScale)

        let frame = win.frame
        // 光标全局位置（Y-up）：窗口左上角 + (v.x, -v.y)
        let cursorGlobal = CGPoint(x: frame.minX + viewPoint.x, y: frame.maxY - viewPoint.y)
        let newSize = CGSize(width: baseRect.width * newScale, height: baseRect.height * newScale)
        // 新左上角：锚点新视图坐标反向推（v' 在新窗口里 Y-down，换回 Y-up 要减）
        let topLeft = CGPoint(x: cursorGlobal.x - newAnchor.x, y: cursorGlobal.y + newAnchor.y)
        win.setFrame(
            CGRect(x: topLeft.x, y: topLeft.y - newSize.height, width: newSize.width, height: newSize.height),
            display: true
        )
    }

    // MARK: - 右键菜单动作

    func copyImageToPasteboard() {
        let ok = ClipboardWriter.writeImage(image) // 复用 Clipboard 模块：PNG+TIFF 双格式
        Log.event(Self.logCategory, "pin.copy", ["ok": "\(ok)"])
    }

    // MARK: - 合并到拼贴（C3，docs/06 §3b：右键「合并到拼贴…」）

    /// 本张 pin 图入拼贴画布；成功后关窗（orderOut）。
    /// 走 CollageMergeTarget 协议（AppCoordinatorShared.collageTarget，C2 侧实现），
    /// C3 不碰 CollageDocument/SnapGeometry；落位（nextGridSlot）是 C2 的事。
    @discardableResult
    func mergeToCollage() -> Bool {
        guard let collage = AppCoordinatorShared.collageTarget else {
            showHUD("拼贴暂不可用")
            Log.event(Self.logCategory, "pin.merge.noTarget", [:])
            return false
        }
        Log.event(Self.logCategory, "pin.merge.menu", [:])
        collage.acceptPiece(image: image, at: nil)
        close()
        return true
    }

    /// ⌥拖成组：目标图先入、拖动图后入（连续两次 acceptPiece =
    /// C2 侧 nextGridSlot 依次相邻落位），两张 pin 窗都关闭。
    func mergePair(with target: PinWindowController) {
        guard let collage = AppCoordinatorShared.collageTarget else {
            showHUD("拼贴暂不可用")
            Log.event(Self.logCategory, "pin.merge.noTarget", [:])
            return
        }
        Log.event(Self.logCategory, "pin.merge.pair", [
            "w": "\(Int(image.width))", "h": "\(Int(image.height))",
            "tw": "\(Int(target.image.width))", "th": "\(Int(target.image.height))",
        ])
        collage.acceptPiece(image: target.image, at: nil)
        collage.acceptPiece(image: image, at: nil)
        target.close()
        close()
    }

    /// drop target 合并：编辑器导出的图拖进 pin 窗（docs/06 §4 PinWindow 扩展），
    /// 本 pin 图与拖入图成组入拼贴，本 pin 窗关闭。
    func mergeDropped(_ dropped: CGImage) {
        guard let collage = AppCoordinatorShared.collageTarget else {
            showHUD("拼贴暂不可用")
            Log.event(Self.logCategory, "pin.merge.noTarget", [:])
            return
        }
        Log.event(Self.logCategory, "pin.merge.drop", [
            "w": "\(Int(image.width))", "h": "\(Int(image.height))",
            "dw": "\(Int(dropped.width))", "dh": "\(Int(dropped.height))",
        ])
        collage.acceptPiece(image: image, at: nil)
        collage.acceptPiece(image: dropped, at: nil)
        close()
    }

    // MARK: - ⌥拖合并手势（PinContentView mouseDown ⌥ 分支转发进来）

    /// 按下：记住抓取偏移与原位（松手未命中任何贴图时回滚）
    func beginOptionDrag() {
        let win = window
        let mouse = NSEvent.mouseLocation
        let frame = win.frame
        optionDrag = (
            grabOffset: CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y),
            originalFrame: frame
        )
        optionDragTarget = nil
        showHUD("⌥ 拖到另一张贴图合并")
        Log.event(Self.logCategory, "pin.merge.dragBegin", [:])
    }

    /// 拖动：窗口跟随光标；悬停到另一张贴图上时 HUD 提示可合并
    func optionDragMoved() {
        guard let drag = optionDrag else { return }
        let win = window
        let mouse = NSEvent.mouseLocation
        let topLeft = CGPoint(x: mouse.x - drag.grabOffset.x, y: mouse.y + drag.grabOffset.y)
        win.setFrameOrigin(CGPoint(x: topLeft.x, y: topLeft.y - win.frame.height))
        let other = Self.hitOtherPin(at: mouse, excluding: self)
        if other !== optionDragTarget {
            optionDragTarget = other
            showHUD(other == nil ? "⌥ 拖到另一张贴图合并" : "松手合并进拼贴")
        }
    }

    /// 松手：命中另一张贴图 → 两图成组进拼贴（双双关窗）；
    /// 未命中 → 回滚原位（手势取消，不误位移）。
    /// 只在 ⌥拖手势进行中生效——普通拖动（performDrag）后的 stray mouseUp 忽略。
    func endOptionDrag() {
        guard let drag = optionDrag else { return }
        optionDrag = nil
        let target = optionDragTarget
        optionDragTarget = nil
        let win = window
        let mouse = NSEvent.mouseLocation
        if let other = Self.hitOtherPin(at: mouse, excluding: self) ?? target {
            mergePair(with: other)
        } else {
            win.setFrame(drag.originalFrame, display: true)
            Log.event(Self.logCategory, "pin.merge.dragCancel", [:])
        }
    }

    // MARK: - 关闭

    func close() {
        hudHideTask?.cancel()
        hudHideTask = nil
        window.orderOut(nil)
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
