import AppKit

/// 设置窗玻璃控件库（恒定浅色晶透玻璃体系）
///
/// 层级架构（Impeccable + Apple Craft）：
/// 1. 窗底：`AdaptiveGlassView(.menu, .behindWindow, .aqua)` 全窗澄澈磨砂
/// 2. 侧栏：轻退一层（微冷灰透层）承载左对齐导航，选中项用浮起白晶胶囊 + 强调色图标
/// 3. 分组卡：`SettingsGlassCard`（白晶半透 `0.56` + 0.5pt 细边 + 顶缘 1pt 高光，无脏黑投影晕边）
/// 4. 控件：`GlassSwitch`、`GlassSegmentedControl`、`GlassPopUpButton`、`GlassMiniButton`、
///    `GlassIconButton`、`GlassStepperControl`、`GlassHotkeyRecorderView` 统一 26pt 高与 7pt 圆角节奏。
///
/// 纪律：颜色/圆角/字阶/动效从 `DesignTokens` 取值，所有视图严格 `@MainActor`。

// MARK: - 晶透分组卡（干净、轻盈、无脏阴影晕边）

@MainActor
final class SettingsGlassCard: NSView {
    let contentContainer = NSView()
    private let cornerRadius: CGFloat
    private let specularLayer = CAGradientLayer()

    init(cornerRadius: CGFloat = 11) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .aqua)

        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true

        // 顶缘 1pt 镜面受光（左右圆角柔缓淡出）
        specularLayer.startPoint = CGPoint(x: 0, y: 0.5)
        specularLayer.endPoint = CGPoint(x: 1, y: 0.5)
        specularLayer.locations = [0, 0.12, 0.88, 1]
        layer?.addSublayer(specularLayer)

        contentContainer.wantsLayer = true
        contentContainer.appearance = NSAppearance(named: .aqua)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        refreshAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsGlassCard 只走代码创建") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let yPos = isFlipped ? 0.5 : max(0, bounds.height - 1.5)
        specularLayer.frame = CGRect(x: 0, y: yPos, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    private func refreshAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.white.withAlphaComponent(0.56)).cgColor
            layer?.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.075)).cgColor
            let hiAlpha: CGFloat = isDark ? 0.14 : 0.72
            specularLayer.colors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(hiAlpha).cgColor,
                NSColor.white.withAlphaComponent(hiAlpha).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ]
        }
    }
}

/// 兼容保留：浮空场景用的晶透玻璃容器（设置页内分组卡统一使用 `SettingsGlassCard`）
@MainActor
final class CrystalGlassContainer: NSView {
    let contentContainer = NSView()
    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let shadowHost: OuterShadowView
    let margin: CGFloat
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat, tintAlpha: CGFloat = 0.08, shadowMargin: CGFloat = 14) {
        self.margin = shadowMargin
        self.cornerRadius = cornerRadius
        self.glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: cornerRadius,
            tintAlpha: tintAlpha
        )
        self.shadowHost = OuterShadowView(spec: .pill, margin: shadowMargin, cornerRadius: cornerRadius)
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)

        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shadowHost)
        let glassHost = glassSurface.hostView
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassHost)
        contentContainer.wantsLayer = true
        contentContainer.appearance = NSAppearance(named: .aqua)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        NSLayoutConstraint.activate([
            shadowHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            shadowHost.topAnchor.constraint(equalTo: topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            glassHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            glassHost.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            glassHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
            contentContainer.leadingAnchor.constraint(equalTo: glassHost.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: glassHost.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: glassHost.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: glassHost.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CrystalGlassContainer 只走代码创建") }

    override func layout() {
        super.layout()
        shadowHost.refreshGeometry()
    }
}

// MARK: - 竖向 Tab 栏（左对齐固定图标列 + 浮起白晶选中胶囊 + 弹簧滑移）

@MainActor
final class GlassTabRail: NSView {
    struct Item {
        let title: String
        let symbol: String
        let tint: NSColor
    }

    private let items: [Item]
    private var buttons: [GlassTabRailButton] = []
    private let pill = CALayer()
    private(set) var selectedIndex: Int = 0
    var onSelect: (Int) -> Void = { _ in }

    init(items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        pill.cornerRadius = 9
        pill.cornerCurve = .continuous
        pill.borderWidth = 0.5
        pill.shadowOpacity = 1
        pill.shadowRadius = 3
        pill.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(pill)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        for (i, item) in items.enumerated() {
            let button = GlassTabRailButton(title: item.title, symbol: item.symbol, tint: item.tint)
            button.tag = i
            button.target = self
            button.action = #selector(itemTapped(_:))
            buttons.append(button)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refreshAppearanceColors()
        applySelection(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassTabRail 只走代码创建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    private func refreshAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            pill.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.white.withAlphaComponent(0.84)).cgColor
            pill.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.075)).cgColor
            pill.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.22 : 0.055).cgColor
        }
    }

    func setSelectedIndex(_ index: Int, animated: Bool = false) {
        guard buttons.indices.contains(index) else { return }
        selectedIndex = index
        applySelection(animated: animated)
    }

    @objc private func itemTapped(_ sender: NSButton) {
        guard sender.tag != selectedIndex else { return }
        selectedIndex = sender.tag
        applySelection(animated: true)
        onSelect(selectedIndex)
    }

    override func layout() {
        super.layout()
        guard buttons.indices.contains(selectedIndex) else { return }
        let frame = buttons[selectedIndex].convert(buttons[selectedIndex].bounds, to: self)
        if pill.frame == .zero || abs(pill.bounds.width - frame.width) > 0.5 || abs(pill.bounds.height - frame.height) > 0.5 {
            applySelection(animated: false)
        }
    }

    private func applySelection(animated: Bool) {
        for (i, button) in buttons.enumerated() {
            button.setSelectedState(i == selectedIndex)
        }
        guard buttons.indices.contains(selectedIndex) else { return }
        layoutSubtreeIfNeeded()
        let frame = buttons[selectedIndex].convert(buttons[selectedIndex].bounds, to: self)
        let fromPos = pill.presentation()?.position ?? pill.position
        let targetPos = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.bounds = CGRect(origin: .zero, size: frame.size)
        pill.position = targetPos
        pill.opacity = 1
        CATransaction.commit()
        guard animated, abs(targetPos.y - fromPos.y) > 0.5 else { return }
        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = NSValue(point: fromPos)
        spring.toValue = NSValue(point: targetPos)
        spring.stiffness = 420
        spring.damping = 28
        spring.mass = 0.85
        spring.duration = spring.settlingDuration
        pill.add(spring, forKey: "rail.glide")
    }
}

/// 竖向 tab 单元：严格左对齐（22pt 彩色圆角微徽标 + 9pt 间距 + 标签），选中态徽标实心亮起
@MainActor
private final class GlassTabRailButton: NSButton {
    private let labelText: String
    private let tintColor: NSColor
    private let iconBadge = NSView()
    private let iconView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")
    private let hoverLayer = CALayer()
    private var isHot = false
    private var isSelectedState = false
    private var trackingArea: NSTrackingArea?

    init(title labelText: String, symbol: String, tint: NSColor) {
        self.labelText = labelText
        self.tintColor = tint
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        hoverLayer.cornerRadius = 9
        hoverLayer.cornerCurve = .continuous
        hoverLayer.opacity = 0
        layer?.insertSublayer(hoverLayer, at: 0)

        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 6
        iconBadge.layer?.cornerCurve = .continuous
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBadge)

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.addSubview(iconView)

        textLabel.stringValue = labelText
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            iconBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 22),
            iconBadge.heightAnchor.constraint(equalToConstant: 22),
            iconView.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 9),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityTitle(labelText)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds
        CATransaction.commit()
    }

    func setSelectedState(_ selected: Bool) {
        isSelectedState = selected
        applyStyle()
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

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            hoverLayer.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.black.withAlphaComponent(0.045)).cgColor

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            hoverLayer.opacity = (!isSelectedState && isHot) ? 1 : 0
            CATransaction.commit()

            if isSelectedState {
                iconBadge.layer?.backgroundColor = tintColor.cgColor
                iconView.contentTintColor = .white
                textLabel.textColor = DesignTokens.label1
                textLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            } else if isHot {
                iconBadge.layer?.backgroundColor = tintColor.withAlphaComponent(0.18).cgColor
                iconView.contentTintColor = tintColor
                textLabel.textColor = DesignTokens.label1
                textLabel.font = .systemFont(ofSize: 13, weight: .medium)
            } else {
                iconBadge.layer?.backgroundColor = tintColor.withAlphaComponent(0.12).cgColor
                iconView.contentTintColor = tintColor.withAlphaComponent(0.88)
                textLabel.textColor = DesignTokens.label1.withAlphaComponent(0.78)
                textLabel.font = .systemFont(ofSize: 13, weight: .regular)
            }
        }
    }
}

// MARK: - 玻璃分段选择器（凹槽微透底 + 浮起白晶选中滑块）

@MainActor
final class GlassSegmentedControl: NSView {
    private let segmentTitles: [String]
    private var buttons: [GlassSegmentButton] = []
    private let pill = CALayer()
    private(set) var selectedIndex: Int = 0
    var onSelect: (Int) -> Void = { _ in }

    init(titles: [String]) {
        self.segmentTitles = titles
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        pill.cornerRadius = 7
        pill.cornerCurve = .continuous
        pill.borderWidth = 0.5
        pill.shadowOpacity = 1
        pill.shadowRadius = 2.5
        pill.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(pill)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        for (i, title) in titles.enumerated() {
            let button = GlassSegmentButton(title: title)
            button.tag = i
            button.target = self
            button.action = #selector(segmentTapped(_:))
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        refreshAppearanceColors()
        applySelection(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassSegmentedControl 只走代码创建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    private func refreshAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.black.withAlphaComponent(0.055)).cgColor
            layer?.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.07)).cgColor
            pill.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.white.withAlphaComponent(0.94)).cgColor
            pill.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.22)
                : NSColor.black.withAlphaComponent(0.08)).cgColor
            pill.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.25 : 0.08).cgColor
        }
    }

    func setSelectedIndex(_ index: Int, animated: Bool = false) {
        guard buttons.indices.contains(index), index != selectedIndex || pill.frame == .zero else { return }
        selectedIndex = index
        applySelection(animated: animated)
    }

    @objc private func segmentTapped(_ sender: NSButton) {
        guard sender.tag != selectedIndex else { return }
        selectedIndex = sender.tag
        applySelection(animated: true)
        onSelect(selectedIndex)
    }

    override func layout() {
        super.layout()
        guard buttons.indices.contains(selectedIndex) else { return }
        let frame = buttons[selectedIndex].convert(buttons[selectedIndex].bounds, to: self)
        if pill.frame == .zero || abs(pill.bounds.width - frame.width) > 0.5 || abs(pill.bounds.height - frame.height) > 0.5 {
            applySelection(animated: false)
        }
    }

    private func applySelection(animated: Bool) {
        for (i, button) in buttons.enumerated() {
            button.setSelectedState(i == selectedIndex)
        }
        guard buttons.indices.contains(selectedIndex) else { return }
        let target = buttons[selectedIndex]
        layoutSubtreeIfNeeded()
        let frame = target.frame
        let fromPos = pill.presentation()?.position ?? pill.position
        let targetPos = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.bounds = CGRect(origin: .zero, size: frame.size)
        pill.position = targetPos
        pill.opacity = 1
        CATransaction.commit()
        guard animated, abs(targetPos.x - fromPos.x) > 0.5 else { return }
        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = NSValue(point: fromPos)
        spring.toValue = NSValue(point: targetPos)
        spring.stiffness = 420
        spring.damping = 28
        spring.mass = 0.85
        spring.duration = spring.settlingDuration
        pill.add(spring, forKey: "seg.glide")
    }
}

@MainActor
private final class GlassSegmentButton: NSButton {
    private let labelText: String
    private var isHot = false
    private var isSelectedState = false
    private var trackingArea: NSTrackingArea?

    init(title: String) {
        self.labelText = title
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let w = ceil(attributedTitle.size().width)
        return NSSize(width: max(56, w + 20), height: 24)
    }

    func setSelectedState(_ selected: Bool) {
        isSelectedState = selected
        applyStyle()
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

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            if isSelectedState {
                color = NSColor(srgbRed: 0.0, green: 0.41, blue: 0.85, alpha: 1)
            } else if isHot {
                color = DesignTokens.label1.withAlphaComponent(0.82)
            } else {
                color = DesignTokens.label2
            }
            setAccessibilityTitle(labelText)
            attributedTitle = NSAttributedString(string: labelText, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isSelectedState ? .semibold : .regular),
                .foregroundColor: color,
            ])
        }
    }
}

// MARK: - 玻璃弹出按钮（26pt 高 + 7pt 圆角 + 当前项对勾）

@MainActor
final class GlassPopUpButton: NSButton {
    private var isHot = false
    private var trackingArea: NSTrackingArea?
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let glassLayer = CALayer()

    var onSelect: (String) -> Void = { _ in }
    private(set) var selectedRawValue: String = ""

    init() {
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        glassLayer.cornerRadius = 7
        glassLayer.cornerCurve = .continuous
        glassLayer.borderWidth = 0.5
        glassLayer.shadowOpacity = 1
        glassLayer.shadowRadius = 1.5
        glassLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.insertSublayer(glassLayer, at: 0)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        chevronView.image = NSImage(
            systemSymbolName: "chevron.up.chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassPopUpButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    func configure(items: [(title: String, rawValue: String)], selectedRawValue: String) {
        let menu = NSMenu()
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(menuItemPicked(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.rawValue
            menu.addItem(menuItem)
        }
        self.menu = menu
        self.selectedRawValue = selectedRawValue
        syncTitle()
    }

    func select(rawValue: String) {
        selectedRawValue = rawValue
        syncTitle()
    }

    @objc private func menuItemPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        selectedRawValue = raw
        syncTitle()
        onSelect(raw)
    }

    private func syncTitle() {
        var matchedTitle = ""
        for item in menu?.items ?? [] {
            let isSelected = (item.representedObject as? String) == selectedRawValue
            item.state = isSelected ? .on : .off
            if isSelected { matchedTitle = item.title }
        }
        titleLabel.stringValue = matchedTitle
    }

    override func layout() {
        super.layout()
        glassLayer.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true)
        if let menu {
            let selected = menu.items.first(where: { ($0.representedObject as? String) == selectedRawValue })
            let origin = NSPoint(x: 0, y: bounds.height + 4)
            menu.popUp(positioning: selected, at: origin, in: self)
        }
        TactilePress.animate(view: self, pressed: false)
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

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            glassLayer.backgroundColor = (isHot
                ? (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.95))
                : (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.78))).cgColor
            glassLayer.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.10)).cgColor
            glassLayer.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.2 : 0.05).cgColor
            titleLabel.textColor = DesignTokens.label1
            chevronView.contentTintColor = DesignTokens.label2
        }
    }
}

// MARK: - 玻璃步进器（统一替代 stock 白框 + 金属 NSStepper）

@MainActor
final class GlassStepperControl: NSView, NSTextFieldDelegate {
    private let minValue: Int
    private let maxValue: Int
    private let unitSuffix: String
    private(set) var value: Int

    var onValueChange: (Int) -> Void = { _ in }

    private let minusBtn = NSButton()
    private let plusBtn = NSButton()
    private let valueLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private var isEditing = false

    init(value: Int, minValue: Int, maxValue: Int, unitSuffix: String = "条") {
        self.value = min(max(value, minValue), maxValue)
        self.minValue = minValue
        self.maxValue = maxValue
        self.unitSuffix = unitSuffix
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)

        configureStepButton(minusBtn, symbol: "minus", action: #selector(decrementTapped))
        configureStepButton(plusBtn, symbol: "plus", action: #selector(incrementTapped))

        let divLeft = makeDivider()
        let divRight = makeDivider()

        valueLabel.font = DesignTokens.Font.monoDigit(12)
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        let click = NSClickGestureRecognizer(target: self, action: #selector(beginInlineEdit))
        valueLabel.addGestureRecognizer(click)

        inputField.font = DesignTokens.Font.monoDigit(12)
        inputField.alignment = .center
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.isHidden = true
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(minusBtn)
        addSubview(divLeft)
        addSubview(valueLabel)
        addSubview(inputField)
        addSubview(divRight)
        addSubview(plusBtn)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 112),
            heightAnchor.constraint(equalToConstant: 26),

            minusBtn.leadingAnchor.constraint(equalTo: leadingAnchor),
            minusBtn.topAnchor.constraint(equalTo: topAnchor),
            minusBtn.bottomAnchor.constraint(equalTo: bottomAnchor),
            minusBtn.widthAnchor.constraint(equalToConstant: 28),

            divLeft.leadingAnchor.constraint(equalTo: minusBtn.trailingAnchor),
            divLeft.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            divLeft.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            divLeft.widthAnchor.constraint(equalToConstant: 0.5),

            plusBtn.trailingAnchor.constraint(equalTo: trailingAnchor),
            plusBtn.topAnchor.constraint(equalTo: topAnchor),
            plusBtn.bottomAnchor.constraint(equalTo: bottomAnchor),
            plusBtn.widthAnchor.constraint(equalToConstant: 28),

            divRight.trailingAnchor.constraint(equalTo: plusBtn.leadingAnchor),
            divRight.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            divRight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            divRight.widthAnchor.constraint(equalToConstant: 0.5),

            valueLabel.leadingAnchor.constraint(equalTo: divLeft.trailingAnchor, constant: 2),
            valueLabel.trailingAnchor.constraint(equalTo: divRight.leadingAnchor, constant: -2),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            inputField.leadingAnchor.constraint(equalTo: divLeft.trailingAnchor, constant: 2),
            inputField.trailingAnchor.constraint(equalTo: divRight.leadingAnchor, constant: -2),
            inputField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        syncUI()
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassStepperControl 只走代码创建") }

    private func configureStepButton(_ btn: NSButton, symbol: String, action: Selector) {
        btn.isBordered = false
        btn.focusRingType = .none
        btn.bezelStyle = .regularSquare
        btn.title = ""
        btn.imagePosition = .imageOnly
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        btn.target = self
        btn.action = action
        btn.isContinuous = true
        btn.setPeriodicDelay(0.35, interval: 0.06)
        btn.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeDivider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func setValue(_ newValue: Int) {
        value = min(max(newValue, minValue), maxValue)
        syncUI()
    }

    private func syncUI() {
        valueLabel.stringValue = "\(value) \(unitSuffix)"
        minusBtn.isEnabled = value > minValue
        plusBtn.isEnabled = value < maxValue
        minusBtn.contentTintColor = minusBtn.isEnabled ? DesignTokens.label1 : DesignTokens.label3
        plusBtn.contentTintColor = plusBtn.isEnabled ? DesignTokens.label1 : DesignTokens.label3
    }

    @objc private func decrementTapped() {
        commitInlineEditIfNeeded()
        guard value > minValue else { return }
        value -= 1
        syncUI()
        onValueChange(value)
    }

    @objc private func incrementTapped() {
        commitInlineEditIfNeeded()
        guard value < maxValue else { return }
        value += 1
        syncUI()
        onValueChange(value)
    }

    @objc private func beginInlineEdit() {
        guard !isEditing else { return }
        isEditing = true
        inputField.stringValue = "\(value)"
        valueLabel.isHidden = true
        inputField.isHidden = false
        window?.makeFirstResponder(inputField)
        inputField.selectText(nil)
    }

    private func commitInlineEditIfNeeded() {
        guard isEditing else { return }
        isEditing = false
        if let parsed = Int(inputField.stringValue.trimmingCharacters(in: .whitespaces)) {
            let clamped = min(max(parsed, minValue), maxValue)
            if clamped != value {
                value = clamped
                onValueChange(value)
            }
        }
        inputField.isHidden = true
        valueLabel.isHidden = false
        syncUI()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitInlineEditIfNeeded()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineEditIfNeeded()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            isEditing = false
            inputField.isHidden = true
            valueLabel.isHidden = false
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.white.withAlphaComponent(0.78)).cgColor
            layer?.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.10)).cgColor
            layer?.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.2 : 0.05).cgColor
            valueLabel.textColor = DesignTokens.label1
            inputField.textColor = DesignTokens.label1
            for sub in subviews where !(sub is NSButton) && !(sub is NSTextField) {
                sub.layer?.backgroundColor = DesignTokens.hair.cgColor
            }
            syncUI()
        }
    }
}

// MARK: - 玻璃开关（38×22 比例优化 + 微边框增强浅底可读性）

@MainActor
final class GlassSwitch: NSControl {
    private(set) var isOn = false
    private let trackLayer = CALayer()
    private let knobLayer = CALayer()
    private var tracking = false
    private var dragStartX: CGFloat = 0
    private var knobStartOn = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        trackLayer.cornerCurve = .continuous
        trackLayer.borderWidth = 0.5
        knobLayer.cornerCurve = .continuous
        knobLayer.shadowColor = NSColor.black.withAlphaComponent(0.20).cgColor
        knobLayer.shadowOpacity = 1
        knobLayer.shadowRadius = 2
        knobLayer.shadowOffset = CGSize(width: 0, height: -0.8)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(knobLayer)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        applyStyle(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassSwitch 只走代码创建") }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        applyStyle(animated: animated)
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    private func applyGeometry() {
        let trackRect = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let knobSide: CGFloat = 18
        let knobX: CGFloat = isOn ? bounds.width - knobSide - 2 : 2
        let knobRect = CGRect(x: knobX, y: 2, width: knobSide, height: knobSide)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = trackRect
        trackLayer.cornerRadius = trackRect.height / 2
        knobLayer.frame = knobRect
        knobLayer.cornerRadius = knobSide / 2
        CATransaction.commit()
    }

    private func applyStyle(animated: Bool) {
        applyGeometry()
        let changes = {
            self.effectiveAppearance.performAsCurrentDrawingAppearance {
                let isDark = self.effectiveAppearance.isDark
                self.trackLayer.backgroundColor = (self.isOn
                    ? DesignTokens.accent
                    : (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.13))).cgColor
                self.trackLayer.borderColor = (self.isOn
                    ? DesignTokens.accent.withAlphaComponent(0.15)
                    : NSColor.black.withAlphaComponent(0.06)).cgColor
                self.knobLayer.backgroundColor = NSColor.white.cgColor
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                ctx.allowsImplicitAnimation = true
                changes()
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        tracking = true
        knobStartOn = isOn
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        let dx = event.locationInWindow.x - dragStartX
        let threshold: CGFloat = 9
        if !knobStartOn, dx > threshold {
            setOn(true, animated: true)
        } else if knobStartOn, dx < -threshold {
            setOn(false, animated: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { tracking = false }
        let dx = event.locationInWindow.x - dragStartX
        if abs(dx) < 3 {
            setOn(!isOn, animated: true)
        }
        if isOn != knobStartOn {
            sendAction(action, to: target)
        }
    }
}

// MARK: - 玻璃小按钮（26pt 高 + 7pt 圆角 + 晶透悬停反馈）

@MainActor
final class GlassMiniButton: NSButton {
    private let labelText: String
    private var isHot = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(title: String) {
        self.labelText = title
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassMiniButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let w = ceil(attributedTitle.size().width)
        return NSSize(width: max(62, w + 22), height: 26)
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
        TactilePress.animate(view: self, pressed: true)
        super.mouseDown(with: event)
        isPressed = false
        TactilePress.animate(view: self, pressed: false)
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            let bg: NSColor
            if isPressed {
                bg = isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.08)
            } else if isHot {
                bg = isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.95)
            } else {
                bg = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.78)
            }
            layer?.backgroundColor = bg.cgColor
            layer?.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.10)).cgColor
            layer?.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.2 : 0.05).cgColor
            attributedTitle = NSAttributedString(string: labelText, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: DesignTokens.label1,
            ])
        }
    }
}

// MARK: - 玻璃图标按钮（禁用态保留轻轮廓，避免首末行偏斜感）

@MainActor
final class GlassIconButton: NSButton {
    private var isHot = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    private let glassLayer = CALayer()
    private let symbolName: String

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        glassLayer.cornerRadius = 6.5
        glassLayer.cornerCurve = .continuous
        glassLayer.borderWidth = 0.5
        layer?.insertSublayer(glassLayer, at: 0)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassIconButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var isEnabled: Bool {
        get { super.isEnabled }
        set { super.isEnabled = newValue; applyStyle() }
    }

    override func layout() {
        super.layout()
        glassLayer.frame = bounds
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
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
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
        guard isEnabled else { return }
        isPressed = true
        applyStyle()
        TactilePress.animate(view: self, pressed: true)
        super.mouseDown(with: event)
        isPressed = false
        TactilePress.animate(view: self, pressed: false)
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            guard isEnabled else {
                glassLayer.backgroundColor = (isDark
                    ? NSColor.white.withAlphaComponent(0.03)
                    : NSColor.white.withAlphaComponent(0.32)).cgColor
                glassLayer.borderColor = (isDark
                    ? NSColor.white.withAlphaComponent(0.06)
                    : NSColor.black.withAlphaComponent(0.045)).cgColor
                contentTintColor = DesignTokens.label3.withAlphaComponent(0.55)
                return
            }
            let bg: NSColor
            if isPressed {
                bg = isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.08)
            } else if isHot {
                bg = isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.95)
            } else {
                bg = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.76)
            }
            glassLayer.backgroundColor = bg.cgColor
            glassLayer.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.095)).cgColor
            contentTintColor = DesignTokens.label1
        }
    }
}

// MARK: - 玻璃热键录制器（26pt 高 + 7pt 圆角 + 规范化键帽文案）

@MainActor
final class GlassHotkeyRecorderView: NSButton {
    var allowBare = false
    var allowReturnKey = false
    var onCombo: (String?) -> Void = { _ in }
    var onStart: () -> Void = {}

    private let fixedWidth: CGFloat
    private(set) var isRecording = false
    private var combo: String = ""
    private var trackingArea: NSTrackingArea?
    private var isHot = false
    private var recordingDot: NSView?

    init(width: CGFloat = 136) {
        self.fixedWidth = width
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        toolTip = "点击录制快捷键"
        installRecordingDot()
        updateDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassHotkeyRecorderView 只走代码创建") }

    private func installRecordingDot() {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = DesignTokens.accent.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        dot.isHidden = true
        addSubview(dot)
        recordingDot = dot
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.25
        anim.duration = 0.9
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(anim, forKey: "rec.blink")
    }

    func setCombo(_ combo: String) {
        self.combo = combo
        updateDisplay()
    }

    override var acceptsFirstResponder: Bool { true }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        onStart()
        updateDisplay()
        window?.makeFirstResponder(self)
    }

    func endRecordingIfNeeded() {
        guard isRecording else { return }
        isRecording = false
        updateDisplay()
        window?.makeFirstResponder(nil)
    }

    private static func formattedCombo(_ combo: String) -> String {
        let raw = HotkeySpec.display(combo)
        return raw == "esc" ? "Esc" : raw
    }

    private func flashConfirmed() {
        guard !isRecording else { return }
        attributedTitle = NSAttributedString(
            string: "✓ " + Self.formattedCombo(combo),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: DesignTokens.accent,
            ]
        )
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 1.0
        pulse.duration = 0.26
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(pulse, forKey: "confirmPulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isRecording else { return }
            self.updateDisplay()
        }
    }

    private func updateDisplay() {
        let text = isRecording ? "  按下快捷键…" : Self.formattedCombo(combo)
        let idleInk = NSColor(srgbRed: 0.09, green: 0.24, blue: 0.48, alpha: 0.92)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: isRecording ? DesignTokens.accent : idleInk,
        ])
        if let layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let isDark = effectiveAppearance.isDark
                layer.backgroundColor = (isRecording
                    ? DesignTokens.accentSoft
                    : (isHot
                        ? (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.95))
                        : (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.78)))).cgColor
                layer.borderColor = (isRecording
                    ? DesignTokens.accentRing
                    : (isHot
                        ? NSColor.black.withAlphaComponent(0.16)
                        : NSColor.black.withAlphaComponent(0.10))).cgColor
                layer.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.2 : 0.045).cgColor
            }
            layer.borderWidth = isRecording ? 1.5 : 0.5
            CATransaction.commit()
        }
        recordingDot?.isHidden = !isRecording
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

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        if !isRecording { updateDisplay() }
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        if !isRecording { updateDisplay() }
    }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func mouseUp(with event: NSEvent) {
    }

    override func keyDown(with event: NSEvent) {
        Log.event(.app, "recorder.keyDown", [
            "code": "\(event.keyCode)",
            "chars": "\(event.charactersIgnoringModifiers ?? "?")",
            "recording": "\(isRecording)",
        ])
        guard isRecording else { return }
        if event.keyCode == 53 {
            endRecordingIfNeeded()
            return
        }
        var mods: [String] = []
        if event.modifierFlags.contains(.command) { mods.append("cmd") }
        if event.modifierFlags.contains(.shift) { mods.append("shift") }
        if event.modifierFlags.contains(.option) { mods.append("opt") }
        if event.modifierFlags.contains(.control) { mods.append("ctrl") }
        let key = Self.keyName(for: event)
        if mods.isEmpty {
            let isBareFKey = key.hasPrefix("f") && key.count >= 2 && key.dropFirst().allSatisfy(\.isNumber)
            if isBareFKey || (allowReturnKey && key == "return") {
                onCombo(key)
                isRecording = false
                updateDisplay()
                window?.makeFirstResponder(nil)
                flashConfirmed()
                return
            }
            if allowBare, key.count == 1, (key.first?.isLetter == true || key.first?.isNumber == true) {
                onCombo(key)
                isRecording = false
                updateDisplay()
                window?.makeFirstResponder(nil)
                flashConfirmed()
                return
            }
            onCombo(nil)
            return
        }
        onCombo((mods + [key]).joined(separator: "+"))
        isRecording = false
        updateDisplay()
        window?.makeFirstResponder(nil)
        flashConfirmed()
    }

    private static func keyName(for event: NSEvent) -> String {
        if let named = specialKeys[event.keyCode] { return named }
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 {
            return chars
        }
        return "key\(event.keyCode)"
    }

    private static let specialKeys: [UInt16: String] = [
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "esc",
        115: "home", 116: "pageup", 117: "forwarddelete", 119: "end", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        123: "left", 124: "right", 125: "down", 126: "up",
    ]
}

// MARK: - 实时工具栏迷你预览（随尺寸档位与工具排序同步变化）

@MainActor
final class ToolbarMiniPreviewView: NSView {
    private let pillContainer = NSView()
    private let pillStack = NSStackView()
    private var currentOrder: [Int] = []
    private var currentSize: AppSettings.ToolbarSize = .regular

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.035).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor

        pillContainer.wantsLayer = true
        pillContainer.appearance = NSAppearance(named: .darkAqua)
        pillContainer.layer?.backgroundColor = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.17, alpha: 0.88).cgColor
        pillContainer.layer?.cornerCurve = .continuous
        pillContainer.layer?.borderWidth = 0.5
        pillContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        pillContainer.layer?.shadowColor = NSColor.black.withAlphaComponent(0.24).cgColor
        pillContainer.layer?.shadowOpacity = 1
        pillContainer.layer?.shadowRadius = 8
        pillContainer.layer?.shadowOffset = CGSize(width: 0, height: -3)
        pillContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pillContainer)

        pillStack.orientation = .horizontal
        pillStack.alignment = .centerY
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.addSubview(pillStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            pillContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            pillContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillStack.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 10),
            pillStack.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -10),
            pillStack.topAnchor.constraint(equalTo: pillContainer.topAnchor, constant: 6),
            pillStack.bottomAnchor.constraint(equalTo: pillContainer.bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ToolbarMiniPreviewView 只走代码创建") }

    func update(order: [Int], size: AppSettings.ToolbarSize) {
        currentOrder = order
        currentSize = size

        let iconPt: CGFloat
        let gap: CGFloat
        let cornerRadius: CGFloat
        switch size {
        case .compact:
            iconPt = 11; gap = 5; cornerRadius = 9
        case .regular:
            iconPt = 13; gap = 7; cornerRadius = 11
        case .large:
            iconPt = 15; gap = 9; cornerRadius = 13
        }

        pillContainer.layer?.cornerRadius = cornerRadius
        pillStack.spacing = gap
        pillStack.arrangedSubviews.forEach {
            pillStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (idx, raw) in order.enumerated() {
            guard let tool = EditorSession.Tool(rawValue: raw),
                  let kind = Self.iconKind(for: tool) else { continue }
            let iv = NSImageView()
            iv.image = TBIcon.image(kind, pointSize: iconPt)
            iv.contentTintColor = idx == 0 ? .white : NSColor.white.withAlphaComponent(0.76)
            if idx == 0 {
                let wrap = NSView()
                wrap.wantsLayer = true
                wrap.layer?.backgroundColor = DesignTokens.accent.cgColor
                wrap.layer?.cornerRadius = cornerRadius - 4
                wrap.layer?.cornerCurve = .continuous
                wrap.translatesAutoresizingMaskIntoConstraints = false
                iv.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(iv)
                let boxSide = iconPt + 9
                NSLayoutConstraint.activate([
                    wrap.widthAnchor.constraint(equalToConstant: boxSide),
                    wrap.heightAnchor.constraint(equalToConstant: boxSide),
                    iv.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                    iv.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                ])
                pillStack.addArrangedSubview(wrap)
            } else {
                pillStack.addArrangedSubview(iv)
            }
        }

        func addMiniSeparator() {
            let sep = NSView()
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
            sep.heightAnchor.constraint(equalToConstant: iconPt + 2).isActive = true
            pillStack.addArrangedSubview(sep)
        }

        addMiniSeparator()

        for kind in [TBIcon.Kind.scroll, .ocr, .pin, .more] {
            let iv = NSImageView()
            iv.image = TBIcon.image(kind, pointSize: iconPt - 0.5)
            iv.contentTintColor = NSColor.white.withAlphaComponent(0.76)
            pillStack.addArrangedSubview(iv)
        }

        addMiniSeparator()

        let copyPill = NSView()
        copyPill.wantsLayer = true
        copyPill.layer?.backgroundColor = DesignTokens.accent.cgColor
        copyPill.layer?.cornerRadius = cornerRadius - 4
        copyPill.layer?.cornerCurve = .continuous
        copyPill.translatesAutoresizingMaskIntoConstraints = false
        let copyIcon = NSImageView()
        copyIcon.image = TBIcon.image(.copy, pointSize: iconPt - 1)
        copyIcon.contentTintColor = .white
        copyIcon.translatesAutoresizingMaskIntoConstraints = false
        copyPill.addSubview(copyIcon)
        let boxSide = iconPt + 9
        NSLayoutConstraint.activate([
            copyPill.widthAnchor.constraint(equalToConstant: boxSide),
            copyPill.heightAnchor.constraint(equalToConstant: boxSide),
            copyIcon.centerXAnchor.constraint(equalTo: copyPill.centerXAnchor),
            copyIcon.centerYAnchor.constraint(equalTo: copyPill.centerYAnchor),
        ])
        pillStack.addArrangedSubview(copyPill)
    }

    private static func iconKind(for tool: EditorSession.Tool) -> TBIcon.Kind? {
        switch tool {
        case .none: return nil
        case .arrow: return .arrow
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .text: return .text
        case .mosaic: return .mosaic
        case .sequence: return .sequence
        case .highlight: return .highlight
        }
    }
}
