import AppKit

/// 设置窗玻璃控件库（工具栏「恒定浅色高晶玻璃」语言在设置场景的成套落地）
///
/// 与 ToolbarPanel 同一条视觉真源（snapcut-design-redesign/tokens.md）：
/// - 材质：`Mat.fixedLightCrystalBlur` —— `.aqua` 钉浅 + `.menu` 澄澈模糊 +
///   纯白晶透提亮 + `.continuous` 连续圆角；绕开 macOS 26 NSGlassEffectView
///   tracksLuma 跨 App 闪跳（工具栏已实锤稳定的配方，见 DesignTokens §2）
/// - 投影：`OuterShadowView` 双层光学影（贴边接触影 + 柔和抬升影），
///   本库所有浮空玻璃（面板/卡片）统一 .pill 规格
/// - 三态：idle（label.2 墨色）→ hover（fillHover 提亮）→ pressed（fillPress），
///   按压 TactilePress scale(0.97) 120ms ease-out；选中 = accentSoft 底 + accent 文字
/// - 分组段选器与工具栏共享同一套「滑动指示层」物理（CASpring 420/28/0.85）
///
/// 纪律：颜色/圆角/字阶/动效全部走 DesignTokens，本文件零私设值。

// MARK: - 水晶玻璃容器（容器面板 + 分组卡共用；窗口钉浅，控件前景随之墨色）

/// 浅色水晶玻璃容器视图：`Mat.fixedLightCrystalBlur` 宿主 + 双层光学投影。
/// 自身不裁剪内容（hitTest 正常下发）；`contentView` 里放业务子视图。
@MainActor
final class CrystalGlassContainer: NSView {
    let contentContainer = NSView()
    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let shadowHost: OuterShadowView
    /// 投影留白（阴影溢出区；容器 frame 比可视玻璃大 2×margin，留白区点击穿透）
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
        appearance = NSAppearance(named: .aqua)   // 恒定浅色：前景控件解析亮外观动态色

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

// MARK: - 竖向 tab 栏（设置窗左侧导航；选中胶囊竖向弹簧滑移，与工具栏指示层同物理）

@MainActor
final class GlassTabRail: NSView {
    struct Item {
        let title: String
        let symbol: String
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

        pill.cornerRadius = 10
        pill.cornerCurve = .continuous
        pill.borderWidth = 0.5
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
            let button = GlassTabRailButton(title: item.title, symbol: item.symbol)
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
            pill.backgroundColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.30 : 0.90).cgColor
            pill.borderColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.45 : 0.95).cgColor
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
        if pill.frame == .zero {
            applySelection(animated: false)
        }
    }

    private func applySelection(animated: Bool) {
        for (i, button) in buttons.enumerated() {
            button.setSelectedState(i == selectedIndex)
        }
        guard buttons.indices.contains(selectedIndex) else { return }
        layoutSubtreeIfNeeded()
        // 按钮 frame 在 stack 坐标系，pill 挂在自身 layer：换算到 rail 坐标系
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

/// 竖向 tab 栏单元：左图标右标签，选中 = 白字（底是共享滑动胶囊），hover 提亮
@MainActor
private final class GlassTabRailButton: NSButton {
    private let labelText: String
    private var isHot = false
    private var isSelectedState = false
    private var trackingArea: NSTrackingArea?

    init(title: String, symbol: String) {
        self.labelText = title
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        imagePosition = .imageLeading
        imageHugsTitle = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

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
                color = DesignTokens.labelOnAccent
            } else if isHot {
                color = DesignTokens.label1
            } else {
                color = DesignTokens.label2
            }
            contentTintColor = color
            // AX 标题（e2e/无障碍按标题定位；不能用 title= ——会被下面 attributedTitle 覆盖）
            setAccessibilityTitle(labelText)
            // 图标与文字间 8pt 距（imageHugsTitle + 手工空格）
            attributedTitle = NSAttributedString(string: "  " + labelText, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: isSelectedState ? .semibold : .regular),
                .foregroundColor: color,
            ])
        }
    }
}

// MARK: - 玻璃分段选择器（选项切换；选中胶囊弹簧滑移，与工具栏同物理）

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

        // 玻璃槽底（嵌在行内的小容器：晶透玻璃 + 细描边，连续圆角）
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        pill.cornerRadius = 8
        pill.cornerCurve = .continuous
        pill.borderWidth = 0.5
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
                : NSColor.white.withAlphaComponent(0.55)).cgColor
            layer?.borderColor = DesignTokens.Settings.cardStroke.cgColor
            pill.backgroundColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.30 : 0.88).cgColor
            pill.borderColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.45 : 0.95).cgColor
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
        if pill.frame == .zero {
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

/// 段选器单元按钮：文字三态（选中白 / hover 墨色 / idle 次墨色），无自身底色（底色是共享滑动胶囊）
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
                color = DesignTokens.labelOnAccent
            } else if isHot {
                color = DesignTokens.label1
            } else {
                color = DesignTokens.label2
            }
            setAccessibilityTitle(labelText)   // AX 可见
            attributedTitle = NSAttributedString(string: labelText, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isSelectedState ? .semibold : .regular),
                .foregroundColor: color,
            ])
        }
    }
}

// MARK: - 玻璃弹出按钮（替代 NSPopUpButton；下拉仍走 NSMenu 系统质感，按钮本体玻璃化）

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

        glassLayer.cornerRadius = 8
        glassLayer.cornerCurve = .continuous
        glassLayer.borderWidth = 0.5
        layer?.insertSublayer(glassLayer, at: 0)

        titleLabel.font = DesignTokens.Font.body
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
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassPopUpButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// 配置选项：(显示标题, 业务 rawValue)；选中项与 onSelect 回调都走 rawValue（对齐旧 NSPopUpButton representedObject 语义）
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
        let title = menu?.items.first(where: { ($0.representedObject as? String) == selectedRawValue })?.title ?? ""
        titleLabel.stringValue = title
    }

    override func layout() {
        super.layout()
        glassLayer.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true)
        if let menu {
            let origin = NSPoint(x: 0, y: bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: self)
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
                ? (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.85))
                : (isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.white.withAlphaComponent(0.62))).cgColor
            glassLayer.borderColor = DesignTokens.Settings.cardStroke.cgColor
            titleLabel.textColor = DesignTokens.label1
            chevronView.contentTintColor = DesignTokens.label2
        }
    }
}

// MARK: - 玻璃开关（NSSwitch 外观自绘：玻璃轨道 + 晶透旋钮，弹簧过冲 1.06）

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
        knobLayer.cornerCurve = .continuous
        knobLayer.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        knobLayer.shadowOpacity = 1
        knobLayer.shadowRadius = 2
        knobLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(knobLayer)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 40),
            heightAnchor.constraint(equalToConstant: 24),
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
        let trackRect = CGRect(x: 0, y: 2, width: bounds.width, height: 20)
        let knobSide: CGFloat = 16
        let knobX: CGFloat = isOn ? bounds.width - knobSide - 2 : 2
        let knobRect = CGRect(x: knobX, y: 4, width: knobSide, height: knobSide)
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
                    : (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.16))).cgColor
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

    // 点击切换 + 拖拽滑过一半松手即切（对齐系统 NSSwitch 手感）
    override func mouseDown(with event: NSEvent) {
        tracking = true
        knobStartOn = isOn
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        let dx = event.locationInWindow.x - dragStartX
        let threshold: CGFloat = 10
        if !knobStartOn, dx > threshold {
            setOn(true, animated: true)
        } else if knobStartOn, dx < -threshold {
            setOn(false, animated: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { tracking = false }
        let dx = event.locationInWindow.x - dragStartX
        if abs(dx) < 3 {   // 纯点击
            setOn(!isOn, animated: true)
        }
        if isOn != knobStartOn {
            sendAction(action, to: target)
        }
    }
}

// MARK: - 玻璃小按钮（「选择…」「去授权…」等次级动作；hover 提亮 + 按压缩放）

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
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassMiniButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let w = ceil(attributedTitle.size().width)
        return NSSize(width: max(64, w + 24), height: 24)
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
                bg = isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)
            } else if isHot {
                bg = isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.white.withAlphaComponent(0.85)
            } else {
                bg = isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.white.withAlphaComponent(0.62)
            }
            layer?.backgroundColor = bg.cgColor
            layer?.borderColor = DesignTokens.Settings.cardStroke.cgColor
            attributedTitle = NSAttributedString(string: labelText, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: DesignTokens.label1,
            ])
        }
    }
}

// MARK: - 玻璃图标按钮（排序 ▲▼ 等 24×24 纯图标动作；工具栏 TBIconButton 迷你版）

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
        glassLayer.cornerRadius = 7
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
            guard isEnabled else {
                glassLayer.backgroundColor = NSColor.clear.cgColor
                glassLayer.borderColor = NSColor.clear.cgColor
                contentTintColor = DesignTokens.label3.withAlphaComponent(0.5)
                return
            }
            let bg: NSColor
            if isPressed {
                bg = isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)
            } else if isHot {
                bg = isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.white.withAlphaComponent(0.85)
            } else {
                bg = isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.white.withAlphaComponent(0.55)
            }
            glassLayer.backgroundColor = bg.cgColor
            glassLayer.borderColor = DesignTokens.Settings.cardStroke.cgColor
            contentTintColor = DesignTokens.label1
        }
    }
}

// MARK: - 玻璃热键录制器（替代原 HotkeyRecorderView：水晶玻璃态，录制态 accent 环 + 呼吸点）

@MainActor
final class GlassHotkeyRecorderView: NSButton {
    /// allowBare = true（编辑器热键）：裸字母/数字合法；allowReturnKey（视觉记忆面板）：裸 Return 合法
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
    private var dotLeadingConstraint: NSLayoutConstraint?

    init(width: CGFloat = 160) {
        self.fixedWidth = width
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        installRecordingDot()
        updateDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlassHotkeyRecorderView 只走代码创建") }

    private func installRecordingDot() {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = DesignTokens.accent.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        dot.isHidden = true
        addSubview(dot)
        recordingDot = dot
        dotLeadingConstraint = dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        dotLeadingConstraint?.isActive = true
        dot.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.25
        anim.duration = 1.0
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

    /// 录制成功确认：✓ 前缀 0.8s + 透明度轻脉冲（状态色零参与，绝无残留蓝框）
    private func flashConfirmed() {
        guard !isRecording else { return }
        attributedTitle = NSAttributedString(
            string: "✓ " + HotkeySpec.display(combo),
            attributes: [
                .font: DesignTokens.Font.kbd,
                .foregroundColor: DesignTokens.label1,
            ]
        )
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 1.0
        pulse.duration = 0.28
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(pulse, forKey: "confirmPulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isRecording else { return }
            self.updateDisplay()
        }
    }

    private func updateDisplay() {
        let text = isRecording ? "按下新组合…" : HotkeySpec.display(combo)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: DesignTokens.Font.kbd,
            .foregroundColor: isRecording ? DesignTokens.label1 : DesignTokens.label2,
        ])
        if let layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let isDark = effectiveAppearance.isDark
                layer.backgroundColor = (isRecording
                    ? DesignTokens.accentSoft
                    : (isHot
                        ? (isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.78))
                        : (isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.white.withAlphaComponent(0.58)))).cgColor
            }
            layer.borderWidth = isRecording ? 1.5 : 0.5
            layer.borderColor = (isRecording ? DesignTokens.accentRing : DesignTokens.stroke).cgColor
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
        // 吞掉按钮默认行为
    }

    override func keyDown(with event: NSEvent) {
        Log.event(.app, "recorder.keyDown", [
            "code": "\(event.keyCode)",
            "chars": "\(event.charactersIgnoringModifiers ?? "?")",
            "recording": "\(isRecording)",
        ])
        guard isRecording else { return }
        if event.keyCode == 53 {  // Esc 取消录制
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
            // 裸键白名单：F 键（两类录制器都放行）+ 各场景特许（编辑器裸字母 / 视觉记忆裸 Return）
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
