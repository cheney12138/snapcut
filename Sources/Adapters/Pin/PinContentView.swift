import AppKit
import Carbon.HIToolbox
import CoreGraphics
import QuartzCore
import VisionKit

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

    /// 右上角悬停关闭按钮（20×20 深半透圆钮，悬停时柔显，一键关闭单张贴图）
    private let closeButton = PinHoverCloseButton()

    /// 实况文本宿主（垫在最底层：右上角按钮 / HUD 永远压在它上面保持可点击可读）
    private let liveTextHost = PinLiveTextHostView(frame: .zero)
    /// 右上角实况文本圆钮（位于关闭钮左侧 6pt，20×20 同规范）
    private let liveTextButton = PinHoverLiveTextButton()
    /// 后台静默分析是否识别到文字（无文字则整条实况文本入口不出现）
    private var hasLiveText = false
    /// 鼠标是否停在贴图上（悬停按钮组的显隐依据）
    private var isHovering = false
    /// 悬停按钮组在当前尺寸下是否拥挤（宽 < 84 或高 < 44 时只留关闭钮）
    private var controlsTooSmall: Bool { bounds.width < 84 || bounds.height < 44 }

    private var hoverTrackingArea: NSTrackingArea?

    /// 吸附预览（拖动中贴合：移动卡与目标卡都亮）；视觉由 CAShapeLayer 承担
    private var snapGlow = false

    /// 吸附高亮图层：1.5pt accent outline + 3.5pt soft ring（透明度脉冲）
    private var snapOutlineLayer: CAShapeLayer?
    private var snapRingLayer: CAShapeLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        liveTextHost.frame = bounds
        addSubview(liveTextHost)
        liveTextHost.onScrollWheel = { [weak self] event in
            // 划词态下的滚轮依然要能缩放（⌥ 调透明度）；锚点按内容视图（翻转）坐标换算
            guard let self else { return }
            self.controller?.handleScroll(event, anchor: self.convert(event.locationInWindow, from: nil))
        }
        liveTextHost.onMagnify = { [weak self] event in
            guard let self else { return }
            let factor = max(0.2, 1 + event.magnification)
            self.controller?.applyZoom(
                factor: factor,
                anchor: self.convert(event.locationInWindow, from: nil)
            )
        }

        hud.isHidden = true
        hud.alphaValue = 0
        // 固定贴住右下角：翻转坐标下 min-Y 视觉上是顶部，顶部/左侧边距可伸缩
        hud.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(hud)

        closeButton.alphaValue = 0
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(menuClose)
        addSubview(closeButton)

        liveTextButton.alphaValue = 0
        liveTextButton.isHidden = true
        liveTextButton.target = self
        liveTextButton.action = #selector(menuToggleLiveText)
        addSubview(liveTextButton)
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

    override func layout() {
        super.layout()
        liveTextHost.frame = bounds
        let btnSide: CGFloat = 20
        let inset: CGFloat = 8
        closeButton.frame = NSRect(
            x: max(4, bounds.width - btnSide - inset),
            y: inset,
            width: btnSide,
            height: btnSide
        )
        // 实况文本钮在关闭钮左侧 6pt（同高同宽，同一套发丝边/TactilePress 语言）
        liveTextButton.frame = NSRect(
            x: closeButton.frame.minX - btnSide - 6,
            y: inset,
            width: btnSide,
            height: btnSide
        )
        refreshLiveTextButtonVisibility(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if bounds.width >= 56, bounds.height >= 44 {
            closeButton.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                closeButton.animator().alphaValue = 1
            }
        }
        refreshLiveTextButtonVisibility(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            closeButton.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closeButton.alphaValue < 0.05 else { return }
                self.closeButton.isHidden = true
            }
        })
        // 划词态下实况文本钮常驻（mouseExited 只淡出关闭钮）
        refreshLiveTextButtonVisibility(animated: true)
    }

    // MARK: - 实况文本（划词）

    /// 是否处于实况文本划词态（外框蓝边 + 按钮常驻高亮的依据）
    var isLiveTextActive: Bool { liveTextHost.isActive }

    /// 后台静默分析完成后回调：识别到文字才开放入口
    func setLiveTextAvailable(_ available: Bool) {
        guard hasLiveText != available else { return }
        hasLiveText = available
        refreshLiveTextButtonVisibility(animated: true)
    }

    /// 进入/退出划词态（analysis 仅在进入时传入）
    func setLiveTextActive(_ active: Bool, analysis: ImageAnalysis?) {
        if active, let analysis {
            liveTextHost.activate(with: analysis)
        } else {
            liveTextHost.deactivate()
        }
        liveTextButton.isLiveTextOn = active
        refreshLiveTextButtonVisibility(animated: true)
        needsDisplay = true
    }

    /// 复制当前划选文字；返回 false = 当前没有选区（控制器据此降级为复制图像）
    @discardableResult
    func copySelectedLiveText() -> Bool {
        liveTextHost.copySelectedText()
    }

    func selectAllLiveText() {
        liveTextHost.selectAllText()
    }

    /// 悬停按钮组显隐：
    /// - 划词态：实况文本钮常驻 + accent 蓝底（一眼看出当前状态、随时可点退出）；
    /// - 平时：有文字 + 鼠标悬停 → 与关闭钮一起柔和淡入；
    /// - 贴图过小（宽 < 84 / 高 < 44）→ 只留关闭钮，防拥挤。
    private func refreshLiveTextButtonVisibility(animated: Bool) {
        let shouldShow = !controlsTooSmall && (isLiveTextActive || (hasLiveText && isHovering))
        if shouldShow {
            liveTextButton.isHidden = false
            guard animated, !DesignTokens.Motion.reduceMotion else {
                liveTextButton.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                liveTextButton.animator().alphaValue = 1
            }
        } else {
            guard !liveTextButton.isHidden else { return }
            guard animated, !DesignTokens.Motion.reduceMotion else {
                liveTextButton.alphaValue = 0
                liveTextButton.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                liveTextButton.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.liveTextButton.alphaValue < 0.05 else { return }
                    guard !self.isLiveTextActive, !self.isHovering else { return }
                    self.liveTextButton.isHidden = true
                }
            })
        }
    }

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
        let base = Self.cornerRadius

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
        // 双击：长图在适配 ↔ 1:1 原生像素间切换，普通图复位 100%（锚在光标处）
        if event.clickCount >= 2 {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            controller?.toggleDoubleClickZoom(anchor: convert(event.locationInWindow, from: nil))
            return
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

    override func magnify(with event: NSEvent) {
        // 触控板双指捏合缩放（以光标为锚点，兼容长图查看细节）
        let factor = max(0.2, 1 + event.magnification)
        controller?.applyZoom(factor: factor, anchor: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        buildContextMenu().popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape { // Esc（仅窗口为 key 时事件才会到达这里）
            // 划词态先退划词（不关窗），再按一次才关贴图
            if isLiveTextActive {
                controller?.setLiveTextActive(false)
                return
            }
            controller?.close()
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty {
            switch keyCode {
            case kVK_ANSI_T:
                controller?.toggleLiveText()
                return
            case kVK_ANSI_D, kVK_ANSI_5:
                controller?.toggleCompareOpacity()
                return
            case kVK_ANSI_0:
                controller?.resetOpacity()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let isComparing = controller?.isCompareOpacityActive == true
        let compareItem = NSMenuItem(
            title: isComparing ? "退出对比模式 (100%)" : "对比模式 50% (D)",
            action: #selector(menuToggleCompareOpacity),
            keyEquivalent: ""
        )
        compareItem.state = isComparing ? .on : .off
        let liveTextItem = NSMenuItem(
            title: isLiveTextActive ? "退出实况文本 (T)" : "实况文本划词 (T)",
            action: #selector(menuToggleLiveText),
            keyEquivalent: ""
        )
        liveTextItem.state = isLiveTextActive ? .on : .off
        liveTextItem.isEnabled = hasLiveText || isLiveTextActive
        var items: [NSMenuItem] = [
            NSMenuItem(title: "复制图像", action: #selector(menuCopyImage), keyEquivalent: ""),
            liveTextItem,
            NSMenuItem(title: "结构化取字…", action: #selector(menuStructuredOCR), keyEquivalent: ""),
            NSMenuItem(title: "缩放 100%", action: #selector(menuResetZoom), keyEquivalent: ""),
            compareItem,
        ]
        if controller?.inGroup == true {
            items.append(NSMenuItem.separator())
            items.append(NSMenuItem(title: "拆分拼贴组", action: #selector(menuUngroup), keyEquivalent: ""))
            items.append(NSMenuItem(title: "关闭整组", action: #selector(menuCloseGroup), keyEquivalent: ""))
        }
        items.append(NSMenuItem.separator())
        items.append(NSMenuItem(title: "关闭此贴图", action: #selector(menuClose), keyEquivalent: ""))
        for item in items {
            if !item.isSeparatorItem { item.target = self }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuCopyImage() { controller?.copyImageToPasteboard() }
    @objc private func menuToggleLiveText() { controller?.toggleLiveText() }
    @objc private func menuStructuredOCR() { controller?.openStructuredOCRPanel() }
    @objc private func menuResetZoom() { controller?.resetZoom(anchor: CGPoint(x: bounds.midX, y: bounds.midY)) }
    @objc private func menuToggleCompareOpacity() { controller?.toggleCompareOpacity() }
    @objc private func menuUngroup() { controller?.ungroupCurrentGroup() }
    @objc private func menuCloseGroup() { controller?.closeCurrentGroup() }
    @objc private func menuClose() { controller?.close() }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let radius = Self.cornerRadius

        // 1. 图像 1:1 像素精确绘制（无论是否成组，贴图本体尺寸永不跳变；成组凝聚感由底层统一磨砂玻璃托盘承担）
        ctx.saveGState()
        ctx.addPath(CGPath(
            roundedRect: rect, cornerWidth: radius,
            cornerHeight: radius, transform: nil
        ))
        ctx.clip()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        // 精确 1:1 像素时用 .none 保持像素锐利；缩放/长图适配时切 .high 杜绝锯齿模糊
        let backing = window?.backingScaleFactor ?? 2
        let exact1to1 = abs(rect.width * backing - CGFloat(controller.image.width)) < 1.5
            && abs(rect.height * backing - CGFloat(controller.image.height)) < 1.5
        ctx.interpolationQuality = exact1to1 ? .none : .high
        ctx.draw(controller.image, in: rect)
        ctx.restoreGState()

        // 2. Apple 双重发丝边界（外圈 0.5pt 暗影线 + 内圈 0.5pt 柔和亮边，亮/暗桌面及磨砂托盘上都通透利落）
        let outerRect = rect.insetBy(dx: 0.25, dy: 0.25)
        let outerPath = CGPath(roundedRect: outerRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(controller.inGroup ? 0.14 : 0.16).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(outerPath)
        ctx.strokePath()

        let innerRect = rect.insetBy(dx: 0.75, dy: 0.75)
        let innerPath = CGPath(roundedRect: innerRect, cornerWidth: max(1, radius - 0.5), cornerHeight: max(1, radius - 0.5), transform: nil)
        if isLiveTextActive {
            // 划词态：一圈 1pt accent 柔和蓝边替代普通白边（表达「此刻可直接在图上划词复制」）
            let liveRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let livePath = CGPath(roundedRect: liveRect, cornerWidth: max(1, radius - 1), cornerHeight: max(1, radius - 1), transform: nil)
            ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(0.70).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(livePath)
            ctx.strokePath()
        } else {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(controller.inGroup ? 0.34 : 0.42).cgColor)
            ctx.setLineWidth(0.5)
            ctx.addPath(innerPath)
            ctx.strokePath()
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

/// 贴图右上角悬停关闭圆钮（20×20 深半透圆底 + 0.5pt 白发丝边 + 轻按缩放反馈）
@MainActor
private final class PinHoverCloseButton: NSButton {
    private var isHot = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        image = TBIcon.symbolImage(named: "xmark", pointSize: 9.5, weight: .bold, hierarchical: false)
        contentTintColor = NSColor.white.withAlphaComponent(0.92)
        toolTip = "关闭 (Esc)"
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true, scale: 0.90)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    private func applyStyle() {
        layer?.backgroundColor = (isHot
            ? DesignTokens.statusError.withAlphaComponent(0.88)
            : NSColor(srgbRed: 24/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.72)).cgColor
    }
}

/// 贴图右上角悬停「实况文本划词」圆钮（与关闭钮同规范：20×20 圆底 + 0.5pt 白发丝边 + 轻按缩放）。
///
/// 两态：
/// - 平时：深半透底 + 白图标，随鼠标悬停淡入；
/// - 划词态（isLiveTextOn）：accent 强调蓝实心 + 白图标，常驻可见，随时可点退出。
@MainActor
private final class PinHoverLiveTextButton: NSButton {
    private var isHot = false
    private var trackingArea: NSTrackingArea?

    /// 划词态（由 PinContentView 同步）：蓝底常驻 + tooltip 改为退出语义
    var isLiveTextOn = false { didSet { applyStyle() } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        image = TBIcon.symbolImage(named: "text.viewfinder", pointSize: 10, weight: .semibold, hierarchical: false)
        contentTintColor = NSColor.white.withAlphaComponent(0.92)
        toolTip = "实况文本划词 (T)"
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true, scale: 0.90)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    private func applyStyle() {
        if isLiveTextOn {
            layer?.backgroundColor = DesignTokens.accent.cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
            contentTintColor = DesignTokens.labelOnAccent
            toolTip = "退出实况文本 (T / Esc)"
        } else {
            layer?.backgroundColor = (isHot
                ? DesignTokens.accent.withAlphaComponent(0.88)
                : NSColor(srgbRed: 24/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.72)).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
            contentTintColor = NSColor.white.withAlphaComponent(0.92)
            toolTip = "实况文本划词 (T)"
        }
    }
}
