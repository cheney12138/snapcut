import AppKit

/// 标注工具栏（NSPanel + AppKit 控件；样式后置，功能先行）
///
/// 铁律：nonactivatingPanel（不抢激活，键盘焦点留在覆盖层窗口）；
/// isMovableByWindowBackground=false（不挡鼠标手势）。
@MainActor
final class ToolbarPanel: NSPanel {
    private weak var session: EditorSession?
    private var onToolChange: () -> Void = {}
    private var onAction: (Action) -> Void = { _ in }

    enum Action {
        case undo, redo, toggleVisibility, done, save, cancel
    }

    private var stackView: NSStackView!
    private var toolButtons: [EditorSession.Tool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!

    init() {
        // 尺寸在 layout() 里根据内容计算
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 52),
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

    // MARK: - UI

    private func buildUI() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 52))
        // 磨砂背景（功能先行：视觉细节后调）
        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        container.addSubview(effect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        stackView = stack

        // 六个工具按钮（热键 1-6）
        for tool in EditorSession.Tool.allCases {
            let button = NSButton(title: tool.label, target: self, action: #selector(toolTapped(_:)))
            button.tag = tool.rawValue
            button.bezelStyle = .texturedRounded
            button.font = .systemFont(ofSize: 11, weight: .medium)
            stack.addArrangedSubview(button)
            toolButtons[tool] = button
        }

        stack.addView(makeSeparator(), in: .leading)

        // 五色
        for (i, color) in AnnotationModel.palette.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            button.tag = i
            button.bezelStyle = .texturedRounded
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = 6
            let size: CGFloat = 18
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: size).isActive = true
            button.heightAnchor.constraint(equalToConstant: size).isActive = true
            stack.addArrangedSubview(button)
            colorButtons.append(button)
        }

        stack.addView(makeSeparator(), in: .leading)

        // 粗细三档
        for w in 1...3 {
            let button = NSButton(title: "—".padding(toLength: w, withPad: "—", startingAt: 0), target: self, action: #selector(strokeTapped(_:)))
            button.tag = w
            button.bezelStyle = .texturedRounded
            stack.addArrangedSubview(button)
        }

        stack.addView(makeSeparator(), in: .leading)

        // undo / redo
        undoButton = NSButton(title: "撤销", target: self, action: #selector(actionTapped(_:)))
        undoButton.tag = 100
        undoButton.bezelStyle = .texturedRounded
        stack.addArrangedSubview(undoButton)
        redoButton = NSButton(title: "重做", target: self, action: #selector(actionTapped(_:)))
        redoButton.tag = 101
        redoButton.bezelStyle = .texturedRounded
        stack.addArrangedSubview(redoButton)

        stack.addView(makeSeparator(), in: .leading)

        // 隐藏工具栏 / 完成 / 保存 / 取消
        let hide = NSButton(title: "隐藏(H)", target: self, action: #selector(actionTapped(_:)))
        hide.tag = 200
        hide.bezelStyle = .texturedRounded
        stack.addArrangedSubview(hide)

        let done = NSButton(title: "复制(↩)", target: self, action: #selector(actionTapped(_:)))
        done.tag = 201
        done.keyEquivalent = "\r"
        done.bezelStyle = .texturedRounded
        stack.addArrangedSubview(done)

        let save = NSButton(title: "保存(⌘S)", target: self, action: #selector(actionTapped(_:)))
        save.tag = 202
        save.bezelStyle = .texturedRounded
        stack.addArrangedSubview(save)

        let cancel = NSButton(title: "取消(Esc)", target: self, action: #selector(actionTapped(_:)))
        cancel.tag = 203
        cancel.bezelStyle = .texturedRounded
        stack.addArrangedSubview(cancel)

        contentView = container
    }

    // MARK: - 位置（选区下方，放不下翻上方）

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
    }

    private var targetScreen: NSScreen?

    func updateScreen(_ screen: NSScreen) {
        targetScreen = screen
    }

    // MARK: - 状态刷新

    func refreshSelectionState() {
        guard let session else { return }
        for (tool, button) in toolButtons {
            button.state = tool == session.currentTool ? .on : .off
        }
        for (i, button) in colorButtons.enumerated() {
            button.layer?.borderWidth = i == session.colorIndex ? 2 : 0
            button.layer?.borderColor = NSColor.white.cgColor
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
        default: break
        }
    }
}

private extension ToolbarPanel {
    func makeSeparator() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 24).isActive = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }
}
