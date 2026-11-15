import AppKit
import CoreGraphics

/// 贴图内容视图：1:1 像素精确绘制（不重采样）+ 6pt 圆角 + 1px 白描边 + 交互转发。
/// isFlipped 场景：CGContext.draw 假设 Y-up，本视图 Y-down ⇒ 局部镜像一次再 draw
/// （同 Sources/Overlay/OverlayWindow.swift drawEditor 的翻转处理）。
///
/// 成组视觉（设计定稿 §1.3，inGroup 标志位驱动，摘组即回纯图）：
/// 8pt 白垫 + 1px 描边 + 10pt 圆角（窗体已由 controller.setInGroup 外扩 9pt）。
@MainActor
final class PinContentView: NSView {
    static let cornerRadius: CGFloat = 6
    static let groupCornerRadius: CGFloat = 10
    static let borderWidth: CGFloat = 1

    weak var controller: PinWindowController?

    /// 右下角百分比读数（缩放 / ⌥透明度共用）
    let hud = PinHUDView(frame: .zero)

    /// 吸附预览发光（拖动中贴合：移动卡与目标卡都亮）
    private var snapGlow = false {
        didSet { needsDisplay = true }
    }

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

    func setSnapGlow(_ on: Bool) {
        snapGlow = on
    }

    override func mouseDown(with event: NSEvent) {
        // 手动拖动（设计定稿 §1.1）：普通拖 = 单卡移动 + 磁吸预览；
        // ⌘拖 = 所在组全体刚体移动（吸整组包围盒）；⌥拖 = 拆组拖（脱离所在组）。
        // 拖动/松手事件由 mouseDragged/mouseUp 转发（不 performDrag）。
        let groupDrag = event.modifierFlags.contains(.command)
        let detach = event.modifierFlags.contains(.option)
        // 双击复位到 100%（锚在光标处）
        if event.clickCount >= 2 {
            controller?.resetZoom(anchor: convert(event.locationInWindow, from: nil))
        }
        controller?.beginDrag(groupDrag: groupDrag, detach: detach)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.dragMoved()
    }

    override func mouseUp(with event: NSEvent) {
        controller?.endDrag()
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
        let inGroup = controller.inGroup
        let pad: CGFloat = inGroup ? PinWindowController.groupPad : 0
        let radius = inGroup ? Self.groupCornerRadius : Self.cornerRadius

        // 1. 成组白垫（外层圆角矩形；未成组无垫）
        if inGroup {
            let padPath = CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            ctx.addPath(padPath)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
        }

        // 2. 图像 1:1 像素精确绘制：Y-down 上下文需镜像一次再 draw，方向才正确。
        //    成组时画在白垫+描边内缩 9pt 的矩形里（窗体外扩 9pt ⇒ 图像全局位置不变）
        let imageRect = inGroup
            ? rect.insetBy(dx: pad + Self.borderWidth, dy: pad + Self.borderWidth)
            : rect
        ctx.saveGState()
        ctx.addPath(CGPath(
            roundedRect: imageRect, cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius, transform: nil
        ))
        ctx.clip()
        ctx.translateBy(x: imageRect.midX, y: imageRect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -imageRect.midX, y: -imageRect.midY)
        ctx.interpolationQuality = .none
        ctx.draw(controller.image, in: imageRect)
        ctx.restoreGState()

        // 3. 描边：未成组 1px 白描边（内缩 0.5pt 让描边完整落在窗口内，深浅背景都可见）；
        //    成组 1px 深色发丝线骑在白垫外缘（白垫在深色桌面上自身已可见）
        let borderRect = rect.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
        let borderPath = CGPath(
            roundedRect: borderRect, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        ctx.setStrokeColor(inGroup ? NSColor.black.withAlphaComponent(0.15).cgColor : NSColor.white.cgColor)
        ctx.setLineWidth(Self.borderWidth)
        ctx.addPath(borderPath)
        ctx.strokePath()

        // 4. 吸附预览发光（贴合瞬间：边框高亮 + 外发光）
        if snapGlow {
            let glowRect = rect.insetBy(dx: 1, dy: 1)
            let glowPath = CGPath(
                roundedRect: glowRect, cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 12, color: NSColor(srgbRed: 0.298, green: 0.553, blue: 1.0, alpha: 0.9).cgColor)
            ctx.setStrokeColor(NSColor(srgbRed: 0.298, green: 0.553, blue: 1.0, alpha: 1).cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(glowPath)
            ctx.strokePath()
            ctx.restoreGState()
        }
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
