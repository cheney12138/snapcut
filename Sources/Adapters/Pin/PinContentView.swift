import AppKit
import CoreGraphics

/// 贴图内容视图：1:1 像素精确绘制（不重采样）+ 6pt 圆角 + 1px 白描边 + 交互转发。
/// isFlipped 场景：CGContext.draw 假设 Y-up，本视图 Y-down ⇒ 局部镜像一次再 draw
/// （同 Sources/Overlay/OverlayWindow.swift drawEditor 的翻转处理）。
@MainActor
final class PinContentView: NSView {
    static let cornerRadius: CGFloat = 6
    static let borderWidth: CGFloat = 1

    weak var controller: PinWindowController?

    /// 右下角百分比读数（缩放 / ⌥透明度共用）
    let hud = PinHUDView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        hud.isHidden = true
        hud.alphaValue = 0
        // 固定贴住右下角：翻转坐标下 min-Y 视觉上是顶部，顶部/左侧边距可伸缩
        hud.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(hud)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PinContentView 只走代码创建") }

    // MARK: - 响应链 / 事件

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 双击复位到 100%（锚在光标处）；随后 performDrag 处理按住拖动，互不冲突
        if event.clickCount >= 2 {
            controller?.resetZoom(anchor: convert(event.locationInWindow, from: nil))
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // 滚轮/触摸板缩放以光标为锚点；⌥+滚轮调透明度
        controller?.handleScroll(event, anchor: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        buildContextMenu().popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc（仅窗口为 key 时事件才会到达这里）
            controller?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "复制图像", action: #selector(menuCopyImage), keyEquivalent: "")
        let reset = NSMenuItem(title: "缩放 100%", action: #selector(menuResetZoom), keyEquivalent: "")
        let close = NSMenuItem(title: "关闭", action: #selector(menuClose), keyEquivalent: "")
        for item in [copy, reset, close] {
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuCopyImage() { controller?.copyImageToPasteboard() }
    @objc private func menuResetZoom() { controller?.resetZoom(anchor: CGPoint(x: bounds.midX, y: bounds.midY)) }
    @objc private func menuClose() { controller?.close() }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let radius = Self.cornerRadius

        // 1. 圆角裁剪（窗口背景透明，四角自然透出桌面）
        let clipPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()

        // 2. 图像 1:1 像素精确绘制：Y-down 上下文需镜像一次再 draw，方向才正确
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        ctx.interpolationQuality = .none
        ctx.draw(controller.image, in: rect)
        ctx.restoreGState()

        // 3. 1px 白描边（内缩 0.5pt 让描边完整落在窗口内，深浅背景都可见）
        let borderRect = rect.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
        let borderPath = CGPath(roundedRect: borderRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(Self.borderWidth)
        ctx.addPath(borderPath)
        ctx.strokePath()
    }

    // MARK: - HUD

    /// 右下角显示读数并重置 1s 淡出计时（计时由控制器驱动）
    func showHUD(text: String) {
        hud.text = text
        let textSize = (text as NSString).size(withAttributes: PinHUDView.textAttributes)
        let padding: CGFloat = 8
        let margin: CGFloat = 10
        let width = ceil(textSize.width) + padding * 2
        let height = ceil(textSize.height) + 6
        // 翻转坐标：maxY 一侧是视觉底部
        hud.frame = NSRect(
            x: bounds.width - width - margin,
            y: bounds.height - height - margin,
            width: width,
            height: height
        )
        hud.isHidden = false
        hud.alphaValue = 1
    }
}

/// 百分比读数：深色圆角底 + 白字
@MainActor
final class PinHUDView: NSView {
    var text: String = "" { didSet { needsDisplay = true } }

    static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(path)
        ctx.fillPath()

        let textSize = (text as NSString).size(withAttributes: Self.textAttributes)
        let origin = CGPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2
        )
        (text as NSString).draw(at: origin, withAttributes: Self.textAttributes)
    }
}
