import AppKit
import CoreGraphics
import QuartzCore

/// 拼贴组底层统一磨砂玻璃托盘（位于普通应用窗之上、所有贴图 PinWindow 之下）：
///
/// - 替代旧版「每张卡片各自 8pt 死白框」的零散观感，把整组卡片温柔承托在一整块
///   Apple Liquid Glass 圆角磨砂玻璃托盘之上，既提供鲜明的整体归属感，又大幅削弱
///   卡片缝隙背后透出的桌面文字干扰；
/// - 拖动托盘外圈留白或卡片间缝隙 = 整组刚体移动（显示抓手光标）；
/// - 点击托盘后按 Esc = 一键关闭整组。
@MainActor
final class GroupBackdropPanel: NSPanel {
    static let matPadding: CGFloat = 14
    static let shadowMargin: CGFloat = 22
    static let cornerRadius: CGFloat = 16

    let groupID: Int

    override var canBecomeKey: Bool { true }

    var onDragBegin: (() -> Void)?
    var onDragMoved: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onCloseGroup: (() -> Void)?

    private var backdropView: GroupBackdropView {
        contentView as! GroupBackdropView
    }

    init(groupID: Int) {
        self.groupID = groupID
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 严格位于普通窗口 (0) 之上、贴图窗口 (.floating = 3) 之下，零层级打架
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        appearance = NSAppearance(named: .aqua)
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false

        let view = GroupBackdropView(frame: NSRect(x: 0, y: 0, width: 200, height: 140))
        view.panel = self
        contentView = view
        initialFirstResponder = view
    }

    /// 按成员 union rect（全局 Y-up）更新磨砂托盘位置与尺寸
    func update(forUnion union: CGRect) {
        let matRect = union.insetBy(dx: -Self.matPadding, dy: -Self.matPadding)
        let panelFrame = matRect.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin).integral
        setFrame(panelFrame, display: true)
        backdropView.layoutMat(shadowMargin: Self.shadowMargin)
        orderFrontRegardless()
    }

    func playEntranceIfNeeded() {
        backdropView.playEntranceIfNeeded()
    }

    func dismissAnimated() {
        guard isVisible else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.exitDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
    }
}

@MainActor
private final class GroupBackdropView: NSView {
    weak var panel: GroupBackdropPanel?

    private let outerShadowView: OuterShadowView
    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let borderOverlay = NSView()
    private var entrancePlayed = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        // 恒定浅色澄澈磨砂托盘（.aqua .menu .behindWindow + state = .active）：
        // 避免 macOS 26 NSGlassEffectView 在失焦/退后台时降级成亮白不透明底，
        // 始终保持通透细腻的磨砂玻璃质感，由 OuterShadowView 镂空双层光学影托起。
        outerShadowView = OuterShadowView(
            spec: .spotlight,
            margin: GroupBackdropPanel.shadowMargin,
            cornerRadius: GroupBackdropPanel.cornerRadius
        )
        glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: GroupBackdropPanel.cornerRadius,
            tintAlpha: 0
        )
        super.init(frame: frame)
        wantsLayer = true

        addSubview(outerShadowView)
        addSubview(glassSurface.hostView)

        borderOverlay.wantsLayer = true
        borderOverlay.layer?.cornerRadius = GroupBackdropPanel.cornerRadius
        borderOverlay.layer?.cornerCurve = .continuous
        borderOverlay.layer?.borderWidth = 0.5
        borderOverlay.layer?.borderColor = NSColor.black.withAlphaComponent(0.11).cgColor
        borderOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(borderOverlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GroupBackdropView 只走代码创建") }

    func layoutMat(shadowMargin m: CGFloat) {
        let matRect = bounds.insetBy(dx: m, dy: m)
        guard matRect.width > 4, matRect.height > 4 else { return }
        outerShadowView.frame = bounds
        outerShadowView.refreshGeometry()
        glassSurface.hostView.frame = matRect
        borderOverlay.frame = matRect
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if glassSurface.hostView.frame.width > 4, glassSurface.hostView.frame.height > 4 {
            addCursorRect(glassSurface.hostView.frame, cursor: .openHand)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return glassSurface.hostView.frame.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        panel?.onDragBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        panel?.onDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        panel?.onDragEnd?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            panel?.onCloseGroup?()
        } else {
            super.keyDown(with: event)
        }
    }

    func playEntranceIfNeeded() {
        guard !entrancePlayed else { return }
        entrancePlayed = true
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            animator().alphaValue = 1
        }
    }
}

/// 拼贴组顶栏覆盖窗（Apple Liquid Glass 单枚居中悬浮胶囊，仅占胶囊自身区域，绝不遮挡下方卡片）：
///
/// - 距磨砂托盘顶缘 10pt 独立悬空：
///   [ ⊞ 已拼贴 · N 张（抓手可整组拖） | 合并拼图 | 复制 | 拆分 | × 关闭整组 ]
/// - 允许成为 key 窗口并响应 Esc 关闭整组。
@MainActor
final class GroupBorderPanel: NSPanel {
    static let shadowMargin: CGFloat = 18
    static let pillHeight: CGFloat = 32
    static let gapAboveMat: CGFloat = 10

    let groupID: Int

    override var canBecomeKey: Bool { true }

    /// 「合并拼图」回调
    var onAssemble: (() -> Void)?
    /// 「直接复制拼图」回调
    var onQuickCopy: (() -> Void)?
    /// 「拆分」回调
    var onUngroup: (() -> Void)?
    /// 「关闭整组」回调（× 按钮或 Esc）
    var onCloseGroup: (() -> Void)?
    /// 拖拽顶栏状态区 = 整组刚体移动
    var onDragBegin: (() -> Void)?
    var onDragMoved: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var borderView: GroupBorderView {
        contentView as! GroupBorderView
    }

    init(groupID: Int) {
        self.groupID = groupID
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 68),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        appearance = NSAppearance(named: .aqua)
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false

        let view = GroupBorderView(frame: NSRect(x: 0, y: 0, width: 320, height: 68))
        view.panel = self
        view.connectActions(to: self)
        contentView = view
        initialFirstResponder = view
    }

    @objc func handleAssemble() { onAssemble?() }
    @objc func handleQuickCopy() { onQuickCopy?() }
    @objc func handleUngroup() { onUngroup?() }
    @objc func handleCloseGroup() { onCloseGroup?() }

    /// 按成员 union rect（全局 Y-up）刷新顶栏悬浮胶囊的位置与计数
    func refresh(count: Int, union: CGRect) {
        borderView.memberCount = count
        borderView.refreshStatusText()
        let pillW = borderView.preferredPillWidth()
        let pillH = Self.pillHeight
        let m = Self.shadowMargin

        let matTopY = union.maxY + GroupBackdropPanel.matPadding
        let pillMinX = (union.midX - pillW / 2).rounded()
        let pillMinY = (matTopY + Self.gapAboveMat).rounded()

        let panelFrame = CGRect(
            x: pillMinX - m,
            y: pillMinY - m,
            width: pillW + m * 2,
            height: pillH + m * 2
        )
        setFrame(panelFrame, display: true)
        borderView.layoutPill(width: pillW, height: pillH, margin: m)
        orderFrontRegardless()
    }

    /// 成组诞生动效（幂等）：顶部玻璃胶囊轻浮入场
    func playEntranceIfNeeded() {
        borderView.playEntranceIfNeeded()
    }

    /// 退场：fade 0.14s strong ease-out 后 orderOut
    func dismissAnimated() {
        guard isVisible else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.exitDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
    }
}

/// 顶栏胶囊内容视图：[ ⊞ 已拼贴 · N 张 | 合并拼图 | 复制 | 拆分 | × ]
@MainActor
final class GroupBorderView: NSView {
    weak var panel: GroupBorderPanel?
    var memberCount: Int = 0

    private let outerShadowView: OuterShadowView
    private let pillSurface: DesignTokens.Mat.LiquidGlassSurface
    private let foregroundHost = NSView()
    private let pillStack = NSStackView()

    private let dragIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let divider = GroupHairlineView()
    private let assembleButton = CollageActionButton(title: "合并拼图", symbol: "rectangle.stack", primary: true)
    private let quickCopyButton = CollageSecondaryButton(title: "复制", symbol: "doc.on.doc")
    private let ungroupButton = CollageSecondaryButton(title: "拆分")
    private let closeGroupButton = CollageIconCloseButton()

    private var entrancePlayed = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        // 与 ToolbarPanel / GroupBackdropPanel 同源的恒定浅色高晶玻璃配方，
        // 避免切出/失焦后磨砂降级或发白跳变，同时由同级 .aqua foregroundHost 锁定图文清晰度。
        outerShadowView = OuterShadowView(
            spec: .pill,
            margin: GroupBorderPanel.shadowMargin,
            cornerRadius: 10
        )
        pillSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: 10,
            tintAlpha: 0.06
        )
        super.init(frame: frame)
        wantsLayer = true

        addSubview(outerShadowView)
        addSubview(pillSurface.hostView)

        foregroundHost.wantsLayer = true
        foregroundHost.appearance = NSAppearance(named: .aqua)
        addSubview(foregroundHost)

        dragIcon.image = TBIcon.symbolImage(named: "square.on.square", pointSize: 11.5, weight: .medium, hierarchical: true)
        dragIcon.contentTintColor = DesignTokens.label2
        dragIcon.translatesAutoresizingMaskIntoConstraints = false
        dragIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        dragIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.drawsBackground = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshStatusText()

        let dragCluster = NSStackView(views: [dragIcon, statusLabel])
        dragCluster.orientation = .horizontal
        dragCluster.alignment = .centerY
        dragCluster.spacing = 5

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 14).isActive = true

        quickCopyButton.toolTip = "直接复制拼图"
        ungroupButton.toolTip = "拆分拼贴组"
        closeGroupButton.toolTip = "关闭整组 (Esc)"

        pillStack.orientation = .horizontal
        pillStack.alignment = .centerY
        pillStack.spacing = 6
        pillStack.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 6)
        pillStack.addArrangedSubview(dragCluster)
        pillStack.addArrangedSubview(divider)
        pillStack.addArrangedSubview(assembleButton)
        pillStack.addArrangedSubview(quickCopyButton)
        pillStack.addArrangedSubview(ungroupButton)
        pillStack.addArrangedSubview(closeGroupButton)
        foregroundHost.addSubview(pillStack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GroupBorderView 只走代码创建") }

    func connectActions(to panel: GroupBorderPanel) {
        assembleButton.target = panel
        assembleButton.action = #selector(GroupBorderPanel.handleAssemble)
        quickCopyButton.target = panel
        quickCopyButton.action = #selector(GroupBorderPanel.handleQuickCopy)
        ungroupButton.target = panel
        ungroupButton.action = #selector(GroupBorderPanel.handleUngroup)
        closeGroupButton.target = panel
        closeGroupButton.action = #selector(GroupBorderPanel.handleCloseGroup)
    }

    func refreshStatusText() {
        let text = NSMutableAttributedString(string: "已拼贴 · ", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: DesignTokens.label2,
        ])
        text.append(NSAttributedString(string: "\(memberCount) 张", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: DesignTokens.label1,
        ]))
        statusLabel.attributedStringValue = text
    }

    func preferredPillWidth() -> CGFloat {
        pillStack.layoutSubtreeIfNeeded()
        return max(ceil(pillStack.fittingSize.width), 240)
    }

    func layoutPill(width: CGFloat, height: CGFloat, margin: CGFloat) {
        let pillRect = NSRect(x: margin, y: margin, width: width, height: height)
        outerShadowView.frame = bounds
        outerShadowView.refreshGeometry()
        pillSurface.hostView.frame = pillRect
        foregroundHost.frame = pillRect
        pillStack.frame = NSRect(origin: .zero, size: pillRect.size)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let pillRect = pillSurface.hostView.frame
        let dragMaxX = convert(divider.bounds, from: divider).maxX
        let dragWidth = dragMaxX > pillRect.minX + 20
            ? (dragMaxX - pillRect.minX)
            : max(0, pillRect.width - 190)
        if dragWidth > 20 {
            let dragZone = NSRect(x: pillRect.minX, y: pillRect.minY, width: dragWidth, height: pillRect.height)
            addCursorRect(dragZone, cursor: .openHand)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        if let hit = super.hitTest(point) {
            if hit === assembleButton || hit.isDescendant(of: assembleButton) { return assembleButton }
            if hit === quickCopyButton || hit.isDescendant(of: quickCopyButton) { return quickCopyButton }
            if hit === ungroupButton || hit.isDescendant(of: ungroupButton) { return ungroupButton }
            if hit === closeGroupButton || hit.isDescendant(of: closeGroupButton) { return closeGroupButton }
        }
        return pillSurface.hostView.frame.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        panel?.onDragBegin?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            panel?.onCloseGroup?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        panel?.onDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        panel?.onDragEnd?()
    }

    func playEntranceIfNeeded() {
        guard !entrancePlayed else { return }
        entrancePlayed = true
        let reduce = DesignTokens.Motion.reduceMotion
        alphaValue = 0
        let pillFinal = pillSurface.hostView.frame
        let shadowFinal = outerShadowView.frame
        if !reduce {
            pillSurface.hostView.frame = pillFinal.offsetBy(dx: 0, dy: -5)
            foregroundHost.frame = pillFinal.offsetBy(dx: 0, dy: -5)
            outerShadowView.frame = shadowFinal.offsetBy(dx: 0, dy: -5)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            animator().alphaValue = 1
            if !reduce {
                pillSurface.hostView.animator().setFrameOrigin(pillFinal.origin)
                foregroundHost.animator().setFrameOrigin(pillFinal.origin)
                outerShadowView.animator().setFrameOrigin(shadowFinal.origin)
            }
        }
    }
}

// MARK: - 胶囊内辅助组件

@MainActor
private final class GroupHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refresh()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignTokens.hair.cgColor
        }
    }
}

/// 顶栏主按钮（「合并拼图」：克制透明强调蓝胶囊 + accent 图文 + 按压触觉反馈）
@MainActor
private final class CollageActionButton: NSButton {
    private var isHot = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    private let labelText: String

    init(title: String, symbol: String, primary: Bool) {
        self.labelText = title
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        self.image = TBIcon.symbolImage(named: symbol, pointSize: 11.5, weight: .medium, hierarchical: true)
        contentTintColor = DesignTokens.accent
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 0.5
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let textW = (labelText as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
        ]).width
        return NSSize(width: ceil(textW) + 32, height: 22)
    }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
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
        isPressed = true
        applyStyle()
        TactilePress.animate(view: self, pressed: true, scale: 0.96)
        super.mouseDown(with: event)
        isPressed = false
        TactilePress.animate(view: self, pressed: false)
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            let alpha: CGFloat = isPressed ? (isDark ? 0.34 : 0.24)
                : (isHot ? (isDark ? 0.28 : 0.20) : (isDark ? 0.20 : 0.13))
            layer?.backgroundColor = DesignTokens.accent.withAlphaComponent(alpha).cgColor
            layer?.borderColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.32 : 0.24).cgColor
            contentTintColor = DesignTokens.accent
            attributedTitle = NSAttributedString(string: " \(labelText)", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: DesignTokens.accent,
            ])
        }
    }
}

/// 顶栏次级按钮（「复制」「拆分」：柔和悬停底 + 明确语义）
@MainActor
private final class CollageSecondaryButton: NSButton {
    private var isHot = false
    private var trackingArea: NSTrackingArea?
    private let labelText: String
    private let hasSymbol: Bool

    init(title: String, symbol: String? = nil) {
        self.labelText = title
        self.hasSymbol = symbol != nil
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        if let symbol {
            imagePosition = .imageLeading
            imageHugsTitle = true
            self.image = TBIcon.symbolImage(named: symbol, pointSize: 11, weight: .medium, hierarchical: true)
        }
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let textW = (labelText as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
        ]).width
        return NSSize(width: ceil(textW) + (hasSymbol ? 30 : 16), height: 22)
    }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
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
        TactilePress.animate(view: self, pressed: true, scale: 0.95)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fg = isHot ? DesignTokens.label1 : DesignTokens.label2
            layer?.backgroundColor = isHot ? DesignTokens.fillHover.cgColor : NSColor.clear.cgColor
            contentTintColor = fg
            attributedTitle = NSAttributedString(string: hasSymbol ? " \(labelText)" : labelText, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: fg,
            ])
        }
    }
}

/// 顶栏一键关闭整组按钮（22×22 圆形 × 按钮，悬停微红反馈）
@MainActor
private final class CollageIconCloseButton: NSButton {
    private var isHot = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        image = TBIcon.symbolImage(named: "xmark", pointSize: 10.5, weight: .semibold, hierarchical: false)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
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
        TactilePress.animate(view: self, pressed: true, scale: 0.92)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHot
                ? DesignTokens.statusError.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
            contentTintColor = isHot ? DesignTokens.statusError : DesignTokens.label2
        }
    }
}
