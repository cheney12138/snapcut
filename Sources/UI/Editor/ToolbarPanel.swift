import AppKit

/// 标注工具栏（NSPanel + AppKit 控件）
///
/// 视觉规范来自 snapcut-design/index.html 原型（DeepSeek 交付，Apple 玻璃质感）：
/// - 磨砂玻璃：blur+饱和度（NSVisualEffectView .hudWindow 近似）、12px 连续曲率圆角
/// - 1px 内描边（半透明白）+ 双层柔影
/// - 工具按钮：无 bezel 扁平胶囊；选中 = 系统蓝底白字；hover 亮 8%
/// - 出场：从选区底边 spring 滑入（240ms, spring(0.34,1.3,0.5,1) 的 NSAnimationContext 近似）
///
/// 铁律：nonactivatingPanel（不抢激活）；isMovableByWindowBackground=false。
@MainActor
final class ToolbarPanel: NSPanel {
    private weak var session: EditorSession?
    private var onToolChange: () -> Void = {}
    private var onAction: (Action) -> Void = { _ in }

    enum Action {
        case undo, redo, toggleVisibility, done, save, cancel, ocr, pin
    }

    private var toolButtons: [EditorSession.Tool: ToolButton] = [:]
    private var colorButtons: [ColorButton] = []
    private var undoButton: ActionButton!
    private var redoButton: ActionButton!

    // 视觉 token（与 HTML 原型对齐）
    private enum Style {
        static let cornerRadius: CGFloat = 12
        static let buttonHeight: CGFloat = 26
        static let buttonSpacing: CGFloat = 3
        static let selectionBlue = NSColor.controlAccentColor
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 52))
        container.wantsLayer = true

        // 磨砂玻璃底 + 圆角 + 内描边（原型 --glass 体系）
        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Style.cornerRadius
        effect.layer?.masksToBounds = true
        // 1px 内描边
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        container.addSubview(effect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Style.buttonSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // 六个工具（原型：胶囊 + 图标 + 热键 tooltip）
        for tool in EditorSession.Tool.allCases {
            let button = ToolButton(tool: tool)
            button.target = self
            button.action = #selector(toolTapped(_:))
            stack.addArrangedSubview(button)
            toolButtons[tool] = button
        }

        stack.addArrangedSubview(makeSeparator())

        // 五色（原型：圆点 + 选中白描边）
        for (i, color) in AnnotationModel.palette.enumerated() {
            let button = ColorButton(color: NSColor(cgColor: color.cgColor) ?? .red)
            button.tag = i
            button.target = self
            button.action = #selector(colorTapped(_:))
            stack.addArrangedSubview(button)
            colorButtons.append(button)
        }

        stack.addArrangedSubview(makeSeparator())

        // 粗细三档（原型：三条线按钮）
        for w in 1...3 {
            let button = StrokeButton(level: w)
            button.tag = w
            button.target = self
            button.action = #selector(strokeTapped(_:))
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(makeSeparator())

        undoButton = ActionButton(title: "↩︎", tooltip: "撤销 ⌘Z")
        undoButton.tag = 100
        undoButton.target = self
        undoButton.action = #selector(actionTapped(_:))
        stack.addArrangedSubview(undoButton)

        redoButton = ActionButton(title: "↪︎", tooltip: "重做 ⇧⌘Z")
        redoButton.tag = 101
        redoButton.target = self
        redoButton.action = #selector(actionTapped(_:))
        stack.addArrangedSubview(redoButton)

        stack.addArrangedSubview(makeSeparator())

        // 隐藏 / 复制（主按钮）/ 保存 / 取消
        let hide = ActionButton(title: "隐藏", tooltip: "隐藏工具栏 (H)")
        hide.tag = 200
        hide.target = self
        hide.action = #selector(actionTapped(_:))
        stack.addArrangedSubview(hide)

        let ocr = ActionButton(title: "取字 O", tooltip: "识别图中文字（Vision 本地）")
        ocr.tag = 204
        ocr.target = self
        ocr.action = #selector(actionTapped(_:))
        stack.addArrangedSubview(ocr)

        let pin = ActionButton(title: "贴图 P", tooltip: "把截图钉在屏幕上")
        pin.tag = 205
        pin.target = self
        pin.action = #selector(actionTapped(_:))
        stack.addArrangedSubview(pin)

        let done = ActionButton(title: "复制 ↩", tooltip: "复制并完成", prominent: true)
        done.tag = 201
        done.target = self
        done.action = #selector(actionTapped(_:))
        stack.addArrangedSubview(done)

        let save = ActionButton(title: "保存 ⌘S", tooltip: "保存到文件")
        save.tag = 202
        save.target = self
        save.action = #selector(actionTapped(_:))
        stack.addArrangedSubview(save)

        let cancel = ActionButton(title: "取消", tooltip: "取消本次截图 (Esc)")
        cancel.tag = 203
        cancel.target = self
        cancel.action = #selector(actionTapped(_:))
        stack.addArrangedSubview(cancel)

        contentView = container
    }

    private func makeSeparator() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        return view
    }

    // MARK: - 位置（选区下方 12px，放不下翻上方）+ spring 出场

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
        setFrameOrigin(origin)

        // 出场动效（原型 spring 240ms）：从选区底边 +8px 滑入 + 淡入
        let dy: CGFloat = selection.minY >= origin.y + size.height ? -8 : 8
        let finalFrame = frame
        setFrameOrigin(NSPoint(x: origin.x, y: origin.y + dy))
        alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.5, 1)
            self.animator().setFrame(finalFrame, display: true)
            self.animator().alphaValue = 1
        })
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
        undoButton.isEnabled = session.store.canUndo
        redoButton.isEnabled = session.store.canRedo
    }

    // MARK: - 事件

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = EditorSession.Tool(rawValue: sender.tag) else { return }
        session?.currentTool = tool
        Log.event(.editor, "annotate.tool.select", ["tool": tool.label])
        refreshSelectionState()
        onToolChange()
    }

    @objc private func colorTapped(_ sender: NSButton) {
        session?.colorIndex = sender.tag
        refreshSelectionState()
    }

    @objc private func strokeTapped(_ sender: NSButton) {
        session?.strokeWidth = sender.tag
    }

    @objc private func actionTapped(_ sender: NSButton) {
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

// MARK: - 扁平胶囊按钮（原型视觉：无 bezel、hover 亮、选中蓝底白字）

@MainActor
private final class ToolButton: NSButton {
    private let tool: EditorSession.Tool

    init(tool: EditorSession.Tool) {
        self.tool = tool
        super.init(frame: .zero)
        title = tool.label
        tag = tool.rawValue
        toolTip = "\(tool.label)（热键 \(tool.rawValue)）"
        configureCommon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    fileprivate func setSelected(_ selected: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 7
        if selected {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 0
            setContent()
        } else {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
            layer?.borderWidth = 0
            setContent()
        }
    }

    private func setContent() {
        let selected = state == .on
        // 文字色：选中白，未选中 label 色
        let attr = NSAttributedString(string: tool.label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
        ])
        attributedTitle = attr
    }

    private func configureCommon() {
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 12, weight: .medium)
        setContent()
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if state == .off {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        if state == .off {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        }
    }
}

// MARK: - 色点按钮

@MainActor
private final class ColorButton: NSButton {
    private let dotColor: NSColor

    init(color: NSColor) {
        self.dotColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        configureCommon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    fileprivate func setSelected(_ selected: Bool) {
        layer?.borderWidth = selected ? 2.5 : 1
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.black.withAlphaComponent(0.25).cgColor
    }

    private func configureCommon() {
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = dotColor.cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
}

// MARK: - 粗细按钮

@MainActor
private final class StrokeButton: NSButton {
    init(level: Int) {
        super.init(frame: .zero)
        isBordered = false
        let dashes = String(repeating: "—", count: level)
        let attr = NSAttributedString(string: dashes, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        attributedTitle = attr
        toolTip = "粗细 \(level)/3"
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 动作按钮（复制为强调色主按钮）

@MainActor
private final class ActionButton: NSButton {
    init(title: String, tooltip: String, prominent: Bool = false) {
        super.init(frame: .zero)
        isBordered = false
        self.toolTip = tooltip
        let color: NSColor = prominent ? .white : .labelColor
        let attr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: prominent ? .semibold : .regular),
            .foregroundColor: color,
        ])
        attributedTitle = attr
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = prominent
            ? NSColor.controlAccentColor.cgColor
            : NSColor.black.withAlphaComponent(0.06).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.35
        }
    }
}
