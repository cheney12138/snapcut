import AppKit
import CoreGraphics
import QuartzCore

/// 贴图内容视图：1:1 像素精确绘制（不重采样）+ 6pt 圆角 + 1px 白描边 + 交互转发。
/// isFlipped 场景：CGContext.draw 假设 Y-up，本视图 Y-down ⇒ 局部镜像一次再 draw
/// （同 Sources/Overlay/OverlayWindow.swift drawEditor 的翻转处理）。
///
/// 成组视觉（重设计：成员白垫保留，描边收进 token）：8pt 白垫 + 1px hair 描边
/// + 10pt 圆角（窗体已由 controller.setInGroup 外扩 9pt）。
/// 吸附反馈（snapcut-collage-ui §03 重设计）：1.5pt accent outline + 3.5pt soft ring
/// α.10↔.22 透明度脉冲（CABasicAnimation autoreverse 1.2s，对齐 Scroll 选区语言）——
/// 删除 blur 12 α.9 蓝色外发光与硬编码 #4C8DFF。
@MainActor
final class PinContentView: NSView {
    static let cornerRadius: CGFloat = 6
    static let groupCornerRadius: CGFloat = 10
    /// 贴图描边宽度：0.5pt（审查：1px 纯白是全产品最硬的边 → 0.5 阶）
    static let borderWidth: CGFloat = 0.5
    /// 未成组贴图描边色：white .55（原 alpha 1.0 纯白；分离度改由 0.5pt 半透线承担）
    static let looseBorderAlpha: CGFloat = 0.55

    weak var controller: PinWindowController?

    /// 右下角百分比读数（缩放 / ⌥透明度共用）
    let hud = PinHUDView(frame: .zero)

    /// 吸附预览（拖动中贴合：移动卡与目标卡都亮）；视觉由 CAShapeLayer 承担
    private var snapGlow = false

    /// 吸附高亮图层：1.5pt accent outline + 3.5pt soft ring（透明度脉冲）
    private var snapOutlineLayer: CAShapeLayer?
    private var snapRingLayer: CAShapeLayer?

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

    /// 未激活窗口的首次鼠标交互直接生效（用户病例 2026-11-16：「钉住之后第一
    /// 时间三指无法移动截图」）——macOS 默认未激活窗的首击只激活不交互（三指
    /// 拖移同样走此路径），贴图窗独立于激活态，必须 override。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSnapGlow(_ on: Bool) {
        guard snapGlow != on else { return }
        snapGlow = on
        if on {
            installSnapHighlight()
        } else {
            removeSnapHighlight()
        }
    }

    /// 重设计吸附反馈（对齐 Scroll 选区语言）：1.5pt accent outline + 3.5pt soft ring，
    /// ring α.10↔.22 做 1.2s autoreverse 透明度脉冲（GroupFrame.snap* token）。
    /// ring 画在窗体内侧：NSWindow 不渲染 frame 外内容，外扩 ring 会被窗体裁切
    /// （散件窗体 = 图像矩形，无外扩余量）。
    private func installSnapHighlight() {
        wantsLayer = true
        removeSnapHighlight()
        let base = (controller?.inGroup ?? false) ? Self.groupCornerRadius : Self.cornerRadius

        let outline = CAShapeLayer()
        outline.frame = bounds
        outline.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: max(base - 0.75, 1), cornerHeight: max(base - 0.75, 1), transform: nil
        )
        outline.strokeColor = DesignTokens.accent.cgColor
        outline.fillColor = NSColor.clear.cgColor
        outline.lineWidth = DesignTokens.GroupFrame.snapOutlineWidth
        layer?.addSublayer(outline)
        snapOutlineLayer = outline

        let ringInset = DesignTokens.GroupFrame.snapOutlineWidth + DesignTokens.GroupFrame.snapRingWidth / 2
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.path = CGPath(
            roundedRect: bounds.insetBy(dx: ringInset, dy: ringInset),
            cornerWidth: max(base - ringInset, 1), cornerHeight: max(base - ringInset, 1), transform: nil
        )
        ring.strokeColor = DesignTokens.accent.cgColor
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = DesignTokens.GroupFrame.snapRingWidth
        ring.opacity = Float(DesignTokens.GroupFrame.snapRingAlphaMin)
        // 透明度脉冲：α .10↔.22，1.2s ease-in-out autoreverse 往复
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = DesignTokens.GroupFrame.snapRingAlphaMin
        pulse.toValue = DesignTokens.GroupFrame.snapRingAlphaMax
        pulse.duration = DesignTokens.GroupFrame.snapPulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(pulse, forKey: "snapRingPulse")
        layer?.addSublayer(ring)
        snapRingLayer = ring
    }

    /// 吸附解除：outline/ring 0.12s fade-out（审查：磁性松开不应闪断瞬消）
    private func removeSnapHighlight() {
        guard let outline = snapOutlineLayer, let ring = snapRingLayer else {
            snapOutlineLayer = nil
            snapRingLayer = nil
            return
        }
        snapOutlineLayer = nil
        snapRingLayer = nil
        ring.removeAnimation(forKey: "snapRingPulse")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        outline.opacity = 0
        ring.opacity = 0
        CATransaction.setCompletionBlock {
            outline.removeFromSuperlayer()
            ring.removeFromSuperlayer()
        }
        CATransaction.commit()
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

        // 3. 描边：未成组 0.5pt white .55（原 1px 纯白 alpha 1.0 ——审查：全不透明白线
        //    在深色壁纸上偏硬，比组框的 白.26 重一个数量级）；
        //    成组 hair 发丝线骑在白垫外缘（白垫在深色桌面上自身已可见）
        let borderRect = rect.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
        let borderPath = CGPath(
            roundedRect: borderRect, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        ctx.setStrokeColor(inGroup ? DesignTokens.hair.cgColor
                                   : NSColor.white.withAlphaComponent(Self.looseBorderAlpha).cgColor)
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
        // 深胶囊家族（与尺寸角标/tooltip 同族减实）：rgba(24,24,27,.62) + r5 + 0.5pt 白.14
        // （原 black α.75 / r4 实心黑块）
        let path = CGPath(roundedRect: bounds, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.setFillColor(DesignTokens.capsuleDark.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(path)
        ctx.strokePath()

        let textSize = (text as NSString).size(withAttributes: Self.textAttributes)
        let origin = CGPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2
        )
        (text as NSString).draw(at: origin, withAttributes: Self.textAttributes)
    }
}
