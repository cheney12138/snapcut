import AppKit
import CoreGraphics

/// 标注工具栏（原型 scene 03 的 1:1 移植）
///
/// 视觉真源：`html-pages/snapcut-design/index.html` 第 7 节 `.toolbar / .tb-btn /
/// .tb-colors / .tb-widths / .tb-primary`。逐条对齐：
/// - 面板：padding 5/6、radius 12、rgba(38,38,43,.60) + blur(.hudWindow)、
///   border 0.5pt 白 16%、内高光 + 双层柔影
/// - 按钮：28×28、radius 8、SF Symbols 17pt、默认白 82%，hover 白 12% + 上移 2pt，
///   选中 #0A84FF + 内高光 + 蓝色外发光
/// - 颜色点 15px（选中双环）、粗细三档 26×28 内横条 13pt
/// - 主按钮「复制」28 高、padding 0 10、11.5pt semibold
/// - 悬停提示：深色胶囊（10.5pt，上方 8pt，延迟 0.35s）
///
/// 铁律：nonactivatingPanel（不抢激活）；点击不 makeKey。
@MainActor
final class ToolbarPanel: NSPanel {
    private weak var session: EditorSession?
    private var onToolChange: () -> Void = {}
    private var onAction: (Action) -> Void = { _ in }

    enum Action {
        case undo, redo, toggleVisibility, done, save, cancel, ocr, pin
    }

    // 视图
    private var rootStack: NSStackView!
    private var toolButtons: [EditorSession.Tool: TBToolButton] = [:]
    private var colorButtons: [TBColorButton] = []
    private var widthButtons: [TBWidthButton] = []
    private var undoButton: TBIconButton!
    private var redoButton: TBIconButton!
    private var tooltip: ToolbarTooltipWindow?

    // 视觉 token（照抄原型 CSS，单位 pt）
    private enum Style {
        static let paddingH: CGFloat = 6
        static let paddingV: CGFloat = 5
        static let cornerRadius: CGFloat = 12
        static let buttonSide: CGFloat = 28
        static let buttonRadius: CGFloat = 8
        static let iconSize: CGFloat = 17
        static let separatorWidth: CGFloat = 0.5
        static let separatorHeight: CGFloat = 17
        static let separatorMargin: CGFloat = 5
        static let dotSide: CGFloat = 15
        static let dotGap: CGFloat = 5
        static let accent = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)   // #0A84FF
        static let iconIdle = NSColor.white.withAlphaComponent(0.82)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // ⚠️ 必须与覆盖层同级（.screenSaver）：覆盖层是 .screenSaver，
        // 工具栏若停在 .floating 就会被压在下面——不仅看不见，鼠标点击也全被
        // 覆盖层吃掉（病例：所有按钮点了没反应，toolbar.mousedown 零日志）
        // ⚠️ 比覆盖层（.screenSaver）再高一级：同级时靠 order 决定前后，
        // 覆盖层每次 makeKeyAndOrderFront 就会压到工具栏上面，把点击全吃掉
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // 阴影由内部容器图层画（面板阴影会被裁掉）
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        buildUI()
    }

    func configure(session: EditorSession, onToolChange: @escaping () -> Void, onAction: @escaping (Action) -> Void) {
        self.session = session
        self.onToolChange = onToolChange
        self.onAction = onAction
        refreshSelectionState()
    }

    // MARK: - UI 构建

    private func buildUI() {
        // 玻璃容器（hudWindow 磨砂 + 38% 深色着色，等价原型的 rgba(38,38,43,.60)）
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Style.cornerRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        effect.layer?.backgroundColor = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.169, alpha: 0.60).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: Style.paddingV, left: Style.paddingH,
                                        bottom: Style.paddingV, right: Style.paddingH)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        rootStack = stack

        // 1) 6 个绘图工具
        for tool in EditorSession.Tool.allCases {
            let button = TBToolButton(tool: tool)
            button.target = self
            button.action = #selector(toolTapped(_:))
            button.onHover = { [weak self] inside in self?.handleHover(inside, button: button, text: tool.tipText) }
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(makeSeparator())

        // 2) 五色
        for (i, color) in AnnotationModel.palette.enumerated() {
            let button = TBColorButton(color: NSColor(cgColor: color.cgColor) ?? .red)
            button.tag = i
            button.target = self
            button.action = #selector(colorTapped(_:))
            button.onHover = { [weak self] inside in self?.handleHover(inside, button: button, text: self?.colorName(i) ?? "颜色") }
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(makeSeparator())

        // 3) 三档粗细
        for width in 1...3 {
            let button = TBWidthButton(level: width)
            button.tag = width
            button.target = self
            button.action = #selector(strokeTapped(_:))
            button.onHover = { [weak self] inside in self?.handleHover(inside, button: button, text: "粗细 \(width)") }
            widthButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(makeSeparator())

        // 4) 撤销 / 重做
        undoButton = TBIconButton(symbol: "arrow.uturn.backward", fallback: "↩︎")
        undoButton.target = self
        undoButton.action = #selector(actionTapped(_:))
        undoButton.tag = 100
        undoButton.onHover = { [weak self] inside in self?.handleHover(inside, button: self?.undoButton, text: "撤销 ⌘Z") }
        stack.addArrangedSubview(undoButton)

        redoButton = TBIconButton(symbol: "arrow.uturn.forward", fallback: "↪︎")
        redoButton.target = self
        redoButton.action = #selector(actionTapped(_:))
        redoButton.tag = 101
        redoButton.onHover = { [weak self] inside in self?.handleHover(inside, button: self?.redoButton, text: "重做 ⇧⌘Z") }
        stack.addArrangedSubview(redoButton)

        stack.addArrangedSubview(makeSeparator())

        // 5) 取字 / 贴图 / 显隐
        let ocr = TBIconButton(symbol: "text.viewfinder", fallback: "字")
        ocr.tag = 204
        ocr.target = self
        ocr.action = #selector(actionTapped(_:))
        ocr.onHover = { [weak self] inside in self?.handleHover(inside, button: ocr, text: "取字 O") }
        stack.addArrangedSubview(ocr)

        let pin = TBIconButton(symbol: "pin", fallback: "钉")
        pin.tag = 205
        pin.target = self
        pin.action = #selector(actionTapped(_:))
        pin.onHover = { [weak self] inside in self?.handleHover(inside, button: pin, text: "贴图 P") }
        stack.addArrangedSubview(pin)

        let eye = TBIconButton(symbol: "eye", fallback: "眼")
        eye.tag = 200
        eye.target = self
        eye.action = #selector(actionTapped(_:))
        eye.onHover = { [weak self] inside in self?.handleHover(inside, button: eye, text: "隐藏工具栏 H") }
        stack.addArrangedSubview(eye)

        // 6) 主按钮「复制」+ 保存 + 关闭
        let copy = TBPrimaryButton(symbol: "doc.on.doc", title: "复制")
        copy.tag = 201
        copy.target = self
        copy.action = #selector(actionTapped(_:))
        copy.onHover = { [weak self] inside in self?.handleHover(inside, button: copy, text: "复制并完成 ↩") }
        stack.addArrangedSubview(copy)

        let save = TBIconButton(symbol: "square.and.arrow.down", fallback: "存")
        save.tag = 202
        save.target = self
        save.action = #selector(actionTapped(_:))
        save.onHover = { [weak self] inside in self?.handleHover(inside, button: save, text: "保存 ⌘S") }
        stack.addArrangedSubview(save)

        let close = TBIconButton(symbol: "xmark", fallback: "×")
        close.tag = 203
        close.target = self
        close.action = #selector(actionTapped(_:))
        close.onHover = { [weak self] inside in self?.handleHover(inside, button: close, text: "取消 Esc") }
        stack.addArrangedSubview(close)

        contentView = effect
        effect.layoutSubtreeIfNeeded()
        let fitting = effect.fittingSize
        setContentSize(fitting)
    }

    private func makeSeparator() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Style.separatorWidth).isActive = true
        view.heightAnchor.constraint(equalToConstant: Style.separatorHeight).isActive = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        wrapper.widthAnchor.constraint(equalToConstant: Style.separatorWidth + Style.separatorMargin * 2).isActive = true
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    private func colorName(_ index: Int) -> String {
        ["红", "蓝", "黄", "黑", "白"][index % 5]
    }

    // MARK: - 位置（选区下方 12pt，放不下翻上方）+ spring 出场

    private var targetScreen: NSScreen?

    func updateScreen(_ screen: NSScreen) {
        targetScreen = screen
    }

    func place(below selection: CGRect) {
        contentView?.layoutSubtreeIfNeeded()
        let size = frame.size
        var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.minY - size.height - 12)
        if origin.y < (targetScreen?.visibleFrame.minY ?? 0) + 8 {
            origin.y = selection.maxY + 12
        }
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)

        // 原型入场：translateY(8px)→0 + scale(.985)→1 + 淡入，240ms spring
        let finalFrame = CGRect(origin: origin, size: size)
        setFrameOrigin(CGPoint(x: origin.x, y: origin.y - 8))
        alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.5, 1)
            self.animator().setFrame(finalFrame, display: true)
            self.animator().alphaValue = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.dumpButtonCenters()
        }
    }

    /// 诊断：把每个按钮的屏幕中心点打出来（真机点击验证用，平时无副作用）
    func dumpButtonCenters() {
        guard let contentView else { return }
        var entries: [String] = []
        for sub in contentView.subviews.first?.subviews ?? [] {
            guard sub is NSButton || sub.subviews.first is NSButton else { continue }
            let target = (sub as? NSButton) ?? (sub.subviews.first as? NSButton)
            guard let button = target else { continue }
            let rect = button.convert(button.bounds, to: nil)
            let screenRect = self.convertToScreen(rect)
            entries.append("\(button.tag)@\(Int(screenRect.midX)),\(Int(screenRect.midY))")
        }
        Log.event(.editor, "toolbar.buttons", [
            "panel": "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
            "centers": entries.joined(separator: " "),
        ])
    }

    // MARK: - 状态刷新

    func refreshSelectionState() {
        guard let session else { return }
        for (tool, button) in toolButtons {
            button.setSelected(tool == session.currentTool)
        }
        for (i, button) in colorButtons.enumerated() {
            button.setSelected(i == session.colorIndex)
        }
        for button in widthButtons {
            button.setSelected(button.tag == session.strokeWidth)
        }
        undoButton.isEnabled = session.store.canUndo
        redoButton.isEnabled = session.store.canRedo
    }

    // MARK: - 悬停提示

    private func handleHover(_ inside: Bool, button: NSView?, text: String) {
        if inside, let button {
            if tooltip == nil { tooltip = ToolbarTooltipWindow() }
            let frameInWindow = button.convert(button.bounds, to: nil)
            let screenRect = self.convertToScreen(frameInWindow)
            tooltip?.show(text: text, above: screenRect, after: 0.35)
        } else {
            tooltip?.hide()
        }
    }

    // MARK: - 事件

    /// 诊断：任何落到面板上的鼠标点击都记录一次（判断是事件没进来还是按钮没接住）
    override func mouseDown(with event: NSEvent) {
        let inWindow = event.locationInWindow
        Log.event(.editor, "toolbar.mousedown", [
            "x": "\(Int(inWindow.x))", "y": "\(Int(inWindow.y))",
        ])
        super.mouseDown(with: event)
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = EditorSession.Tool(rawValue: sender.tag) else { return }
        session?.currentTool = tool
        Log.event(.editor, "annotate.tool.select", ["tool": tool.label])
        refreshSelectionState()
        onToolChange()
    }

    @objc private func colorTapped(_ sender: NSButton) {
        session?.colorIndex = sender.tag
        Log.event(.editor, "toolbar.color", ["index": "\(sender.tag)"])
        refreshSelectionState()
    }

    @objc private func strokeTapped(_ sender: NSButton) {
        session?.strokeWidth = sender.tag
        Log.event(.editor, "toolbar.stroke", ["width": "\(sender.tag)"])
        refreshSelectionState()
    }

    @objc private func actionTapped(_ sender: NSButton) {
        tooltip?.hide()
        switch sender.tag {
        case 100: onAction(.undo)
        case 101: onAction(.redo)
        case 200: onAction(.toggleVisibility)
        case 201: onAction(.done)
        case 202: onAction(.save)
        case 203: onAction(.cancel)
        case 204: onAction(.ocr)
        case 205: onAction(.pin)
        default: break
        }
    }
}

// MARK: - 工具按钮（SF Symbols + hover/选中态）

@MainActor
private class TBIconButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHot = false

    init(symbol: String, fallback: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            )
        } else {
            title = fallback
            font = .systemFont(ofSize: 13, weight: .medium)
        }
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        contentTintColor = NSColor.white.withAlphaComponent(0.82)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
        onHover?(false)
    }

    private var selectedState = false

    func setSelected(_ selected: Bool) {
        selectedState = selected
        applyStyle()
    }

    func applyStyle() {
        let selected = selectedState
        if selected {
            layer?.backgroundColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1).cgColor
            contentTintColor = .white
            layer?.shadowColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.42).cgColor
            layer?.shadowOpacity = 1
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: -1)
            layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
        } else if isHot {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            contentTintColor = .white
            layer?.shadowOpacity = 0
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = NSColor.white.withAlphaComponent(0.82)
            layer?.shadowOpacity = 0
        }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }
}

/// 工具按钮：图标 + 数字热键语义（tooltip 由 ToolbarPanel 统一弹）
@MainActor
private final class TBToolButton: TBIconButton {
    let tool: EditorSession.Tool

    init(tool: EditorSession.Tool) {
        self.tool = tool
        super.init(symbol: tool.symbolName, fallback: tool.label)
        tag = tool.rawValue
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 颜色点（15×15，选中双环）

@MainActor
private final class TBColorButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private let dot = NSView()
    private var trackingArea: NSTrackingArea?
    private var selected = false

    init(color: NSColor) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 7.5
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.borderWidth = 0.5
        dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 15),
            dot.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    func setSelected(_ isOn: Bool) {
        selected = isOn
        dot.layer?.shadowColor = NSColor.black.cgColor
        if isOn {
            dot.layer?.borderWidth = 1.5
            dot.layer?.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
            dot.layer?.shadowOpacity = 0.45
            dot.layer?.shadowRadius = 2
            dot.layer?.shadowOffset = .zero
        } else {
            dot.layer?.borderWidth = 0.5
            dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
            dot.layer?.shadowOpacity = 0
        }
    }
}

// MARK: - 粗细档（26×28，内部横条 13pt）

@MainActor
private final class TBWidthButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private let bar = NSView()
    private var trackingArea: NSTrackingArea?
    private var selected = false
    let level: Int

    init(level: Int) {
        self.level = level
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 13),
            bar.heightAnchor.constraint(equalToConstant: CGFloat(level * 2 + 1)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
        if !selected { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        if !selected { layer?.backgroundColor = NSColor.clear.cgColor }
    }

    func setSelected(_ isOn: Bool) {
        selected = isOn
        layer?.backgroundColor = isOn
            ? NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1).cgColor
            : NSColor.clear.cgColor
        bar.layer?.backgroundColor = isOn ? NSColor.white.cgColor : NSColor.white.withAlphaComponent(0.82).cgColor
    }
}

// MARK: - 主按钮（#0A84FF 胶囊：图标 + 「复制」）

@MainActor
private final class TBPrimaryButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHot = false

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        self.title = title
        font = .systemFont(ofSize: 11.5, weight: .semibold)
        contentTintColor = .white
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        }
        imagePosition = .imageLeading
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1).cgColor
        layer?.shadowColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.38).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        let pad = NSEdgeInsets.left(10)
        _ = pad
        contentEdgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        onHover?(true)
        layer?.backgroundColor = NSColor(srgbRed: 0.102, green: 0.549, blue: 1.0, alpha: 1).cgColor
        layer?.shadowRadius = 8
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        onHover?(false)
        layer?.backgroundColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1).cgColor
        layer?.shadowRadius = 5
    }

    private var contentEdgeInsets: NSEdgeInsets = .init() {
        didSet { needsLayout = true }
    }
}

private extension NSEdgeInsets {
    static func left(_ v: CGFloat) -> NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(top: 0, leading: v, bottom: 0, trailing: v)
    }
}

// MARK: - 悬停提示浮层（深色胶囊，上方 8pt）

@MainActor
private final class ToolbarTooltipWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var work: DispatchWorkItem?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 22),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.backgroundColor = NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 0.92).cgColor
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.94)
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        contentView = bg
    }

    func show(text: String, above rect: CGRect, after delay: TimeInterval) {
        work?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            label.stringValue = text
            contentView?.layoutSubtreeIfNeeded()
            let size = contentView?.fittingSize ?? CGSize(width: 80, height: 22)
            let w = size.width + 16, h: CGFloat = 22
            let x = rect.midX - w / 2
            let y = rect.maxY + 8
            setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                self.animator().alphaValue = 1
            }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        work?.cancel()
        orderOut(nil)
    }
}

// MARK: - 工具 → SF Symbol / 提示文案

private extension EditorSession.Tool {
    var symbolName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rect: return "square"
        case .text: return "textformat"
        case .mosaic: return "squareshape.split.3x3"
        case .sequence: return "number.circle"
        case .highlight: return "highlighter"
        }
    }

    var tipText: String {
        switch self {
        case .arrow: return "箭头 1"
        case .rect: return "矩形 2"
        case .text: return "文字 3"
        case .mosaic: return "马赛克 4"
        case .sequence: return "序号 5"
        case .highlight: return "高亮 6"
        }
    }
}
