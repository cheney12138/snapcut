import AppKit
import CoreGraphics

/// 标注工具栏（原型 scene 03 的 1:1 移植）
///
/// 视觉真源：`html-pages/snapcut-design/index.html` 第 7 节 `.toolbar / .tb-btn /
/// .tb-colors / .tb-widths / .tb-primary`。逐条对齐（CSS px = pt）：
/// - 面板：padding 5/6、radius 12、rgba(38,38,43,.60) + blur(.hudWindow)、
///   border 0.5pt 白 16%、inset 高光 0 1px 0 白 14%、
///   双层投影 0 14px 34px -8px rgba(0,0,0,.55) + 0 2px 6px rgba(0,0,0,.30)
/// - 按钮：28×28、radius 8、图标 17pt、默认白 82%、hover 白 12% + 上移 2pt，
///   选中 #0A84FF + inset 白高光 0 1px 0 白 30% + 蓝色外发光 0 2px 8px rgba(10,132,255,.42)
/// - 颜色点 15px（选中：白 1.5px 环 + 外圈 3px 黑 32% 环）、间距 5
/// - 粗细三档 26×28 内横条 13pt 宽、高度 2/4/6（原型 1.5/3/5 的整数化，保证 2x 屏一眼可分）
/// - 主按钮「复制」28 高、padding 0 10、margin 0 2、11.5pt semibold、图标 14pt
/// - 分隔线 0.5×17、margin 0 5px（叠加 flex gap 1 ⇒ 按钮到分隔线 6pt）
/// - 悬停提示：深色胶囊（10.5pt，上方 8pt，阴影 0 6px 16px 黑 35%）
///
/// 结构要点：按钮的蓝色发光与 hover 态不能被裁剪 ⇒ 栈不放进 effect view
/// （其 layer.masksToBounds=true 会裁掉子视图阴影），而是放在无裁剪的根视图上；
/// 面板投影由根视图上的专用图层绘制（hasShadow=false）。
///
/// 铁律：nonactivatingPanel（不抢激活）；点击不 makeKey。

/// 视觉 token（照抄原型 CSS，单位 pt；px == pt）——文件级私有，按钮类共用
private enum TBStyle {
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
    static let accent = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)        // #0A84FF
    static let accentHover = NSColor(srgbRed: 0.102, green: 0.549, blue: 1.0, alpha: 1)   // #1A8CFF
    static let accentGlow = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.42) // rgba(10,132,255,.42)
    static let iconIdle = NSColor.white.withAlphaComponent(0.82)
    static let iconActive = NSColor.white
}

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
    private var eyeButton: TBIconButton?
    private var tooltip: ToolbarTooltipWindow?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // ⚠️ 必须比覆盖层（.screenSaver）高一级：同级时覆盖层 makeKey 后会压在
        // 工具栏上面，把点击全部吃掉（病例：所有按钮点了没反应）
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // 阴影由根视图图层画（面板自带阴影会被裁掉/难调 spread）
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
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        // 根视图绝不 masksToBounds：面板投影、按钮发光都在它上面溢出绘制

        // 1) 面板投影（两层，照 CSS box-shadow 顺序画在最底）
        //    0 14px 34px -8px rgba(0,0,0,.55) → offset(0,-14) blur→radius 17 spread→path 内缩 8
        root.addSubview(makeShadowView(radius: 17, offset: CGSize(width: 0, height: -14),
                                       alpha: 0.55, spread: 8))
        //    0 2px 6px rgba(0,0,0,.30) → offset(0,-2) radius 3
        root.addSubview(makeShadowView(radius: 3, offset: CGSize(width: 0, height: -2),
                                       alpha: 0.30, spread: 0))

        // 2) 玻璃容器（hudWindow 磨砂 + 60% 深色着色，等价原型的 rgba(38,38,43,.60)）
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.layer?.cornerRadius = TBStyle.cornerRadius
        effect.layer?.masksToBounds = true      // 只裁自己的材质/描边，按钮不在它里面
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        effect.layer?.backgroundColor = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.169, alpha: 0.60).cgColor
        root.addSubview(effect)

        // 2b) 面板 inset 高光：0 1px 0 rgba(255,255,255,.14) inset → 顶部 1pt 白 14% 条
        //     （放在 effect 内部，被圆角裁剪，贴着描边下沿）
        let insetHighlight = NSView()
        insetHighlight.wantsLayer = true
        insetHighlight.translatesAutoresizingMaskIntoConstraints = false
        insetHighlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        effect.addSubview(insetHighlight)

        // 3) 内容栈（在 effect 之上、根视图之下 ⇒ 按钮发光不被裁）
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: TBStyle.paddingV, left: TBStyle.paddingH,
                                        bottom: TBStyle.paddingV, right: TBStyle.paddingH)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            insetHighlight.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            insetHighlight.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            insetHighlight.topAnchor.constraint(equalTo: effect.topAnchor, constant: 0.5),
            insetHighlight.heightAnchor.constraint(equalToConstant: 1),
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

        // 2) 五色（.tb-colors：gap 5 + padding 0 1）
        let colorsGroup = NSStackView(views: [])
        colorsGroup.orientation = .horizontal
        colorsGroup.alignment = .centerY
        colorsGroup.spacing = TBStyle.dotGap
        colorsGroup.edgeInsets = NSEdgeInsets(top: 0, left: 1, bottom: 0, right: 1)
        for (i, color) in AnnotationModel.palette.enumerated() {
            let button = TBColorButton(color: NSColor(cgColor: color.cgColor) ?? .red)
            button.tag = i
            button.target = self
            button.action = #selector(colorTapped(_:))
            button.onHover = { [weak self] inside in self?.handleHover(inside, button: button, text: self?.colorName(i) ?? "颜色") }
            colorButtons.append(button)
            colorsGroup.addArrangedSubview(button)
        }
        stack.addArrangedSubview(colorsGroup)

        stack.addArrangedSubview(makeSeparator())

        // 3) 三档粗细（.tb-widths：gap 1）
        let widthsGroup = NSStackView(views: [])
        widthsGroup.orientation = .horizontal
        widthsGroup.alignment = .centerY
        widthsGroup.spacing = 1
        for width in 1...3 {
            let button = TBWidthButton(level: width)
            button.tag = width
            button.target = self
            button.action = #selector(strokeTapped(_:))
            button.onHover = { [weak self] inside in self?.handleHover(inside, button: button, text: self?.widthName(width) ?? "粗细") }
            widthButtons.append(button)
            widthsGroup.addArrangedSubview(button)
        }
        stack.addArrangedSubview(widthsGroup)

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
        eyeButton = eye
        eye.target = self
        eye.action = #selector(actionTapped(_:))
        eye.onHover = { [weak self] inside in self?.handleHover(inside, button: eye, text: "隐藏工具栏 H") }
        stack.addArrangedSubview(eye)

        // 6) 主按钮「复制」（margin 0 2）+ 保存 + 关闭
        let copy = TBPrimaryButton(symbol: "doc.on.doc", title: "复制")
        copy.tag = 201
        copy.target = self
        copy.action = #selector(actionTapped(_:))
        copy.onHover = { [weak self] inside in self?.handleHover(inside, button: copy, text: "复制并完成 ↩") }
        stack.addArrangedSubview(wrapWithMargin(copy, margin: 2))

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

        contentView = root
        root.layoutSubtreeIfNeeded()
        let fitting = root.fittingSize
        setContentSize(fitting)
    }

    /// CSS margin 0 Npx：包一层左右各 Npt 的定宽容器（栈间距 1 照常叠加）
    private func wrapWithMargin(_ view: NSView, margin: CGFloat) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: margin),
            view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -margin),
            view.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: TBStyle.buttonSide),
        ])
        // 宽度 = 内容自适应宽 + 两侧 margin；在布局后由 fitting 决定，
        // 这里用 >= 兜底，最终面板宽度由 fittingSize 算出
        wrapper.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return wrapper
    }

    private func makeShadowView(radius: CGFloat, offset: CGSize, alpha: CGFloat, spread: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(alpha).cgColor
        view.layer?.shadowOpacity = 1
        view.layer?.shadowRadius = radius
        view.layer?.shadowOffset = offset
        // path 在布局后由面板统一设置（见 applyPanelShadowPaths）
        view.layer?.name = "panel-shadow-\(radius)"
        view.layer?.shadowPath = nil
        if spread > 0 { view.layer?.setValue(spread, forKey: "shadowSpreadHint") }
        return view
    }

    /// 布局完成后给两个投影视图设置 shadowPath（含 -8px spread：路径内缩 8）
    private func applyPanelShadowPaths() {
        guard let contentBounds = contentView?.bounds else { return }
        for subview in (contentView?.subviews ?? []) where subview.layer?.name?.hasPrefix("panel-shadow") == true {
            let spread = (subview.layer?.value(forKey: "shadowSpreadHint") as? CGFloat) ?? 0
            let rect = contentBounds.insetBy(dx: spread, dy: spread)
            subview.layer?.shadowPath = CGPath(
                roundedRect: rect,
                cornerWidth: TBStyle.cornerRadius,
                cornerHeight: TBStyle.cornerRadius,
                transform: nil
            )
        }
    }

    private func makeSeparator() -> NSView {
        // .tb-sep：0.5×17、margin 0 5px（栈间距 1 ⇒ 按钮边到分隔线 6pt）
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        let width = TBStyle.separatorWidth + TBStyle.separatorMargin * 2
        wrapper.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.widthAnchor.constraint(equalToConstant: TBStyle.separatorWidth).isActive = true
        view.heightAnchor.constraint(equalToConstant: TBStyle.separatorHeight).isActive = true
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    private func colorName(_ index: Int) -> String {
        ["红", "蓝", "黄", "黑", "白"][index % 5]
    }

    private func widthName(_ level: Int) -> String {
        ["细", "中", "粗"][level - 1]
    }

    // MARK: - 位置（选区下方 12pt，放不下翻上方）+ spring 出场

    private var targetScreen: NSScreen?

    func updateScreen(_ screen: NSScreen) {
        targetScreen = screen
    }

    func place(below selection: CGRect) {
        applyPanelShadowPaths()
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
        scheduleButtonDump()
    }

    // 诊断打点（真机验证坐标来源）
    func scheduleButtonDump() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.dumpButtonCenters() }
    }

    /// 诊断：面板 + 每个按钮的屏幕中心点（真机点击验证用）
    func dumpButtonCenters() {
        guard let contentView else { return }
        var entries: [String] = []
        func walk(_ view: NSView) {
            for sub in view.subviews {
                if let button = sub as? NSButton {
                    let screenRect = self.convertToScreen(button.convert(button.bounds, to: nil))
                    entries.append("\(button.tag)@\(Int(screenRect.midX)),\(Int(screenRect.midY))")
                } else {
                    walk(sub)
                }
            }
        }
        walk(contentView)
        Log.event(.editor, "toolbar.buttons", [
            "panel": "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
            "centers": entries.joined(separator: " "),
        ])
    }

    /// 诊断：点击是否真的进到面板（排查层级/遮挡）
    override func mouseDown(with event: NSEvent) {
        Log.event(.editor, "toolbar.mousedown", [
            "x": "\(Int(event.locationInWindow.x))", "y": "\(Int(event.locationInWindow.y))",
        ])
        super.mouseDown(with: event)
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
        // 病例：仅靠 isEnabled 的 didSet→alphaValue 在首次 build 时可能不生效，
        // 这里显式再刷一次，保证「有标注变亮 / 无标注置灰」在视觉上确定
        undoButton.alphaValue = session.store.canUndo ? 1 : 0.35
        redoButton.alphaValue = session.store.canRedo ? 1 : 0.35
    }

    /// 工具栏显隐态图标（隐藏时 eye.slash）
    func setToolbarHidden(_ hidden: Bool) {
        eyeButton?.setSymbol(hidden ? "eye.slash" : "eye", fallback: "眼")
        Log.event(.editor, "toolbar.eye.icon", ["state": hidden ? "hidden" : "visible"])
    }

    // MARK: - 悬停提示

    private func handleHover(_ inside: Bool, button: NSView?, text: String) {
        if inside, let button {
            if tooltip == nil { tooltip = ToolbarTooltipWindow() }
            let frameInWindow = button.convert(button.bounds, to: nil)
            let screenRect = self.convertToScreen(frameInWindow)
            tooltip?.show(text: text, above: screenRect, after: 0.12)
        } else {
            tooltip?.hide()
        }
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
        Log.event(.editor, "toolbar.color", ["index": "\(sender.tag)"])
        session?.colorIndex = sender.tag
        refreshSelectionState()
    }

    @objc private func strokeTapped(_ sender: NSButton) {
        Log.event(.editor, "toolbar.stroke", ["width": "\(sender.tag)"])
        session?.strokeWidth = sender.tag
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

// MARK: - 按钮选中/悬停共通态（.tb-btn 三态 + hover 上移 2pt + 按下 0.96）

@MainActor
class TBIconButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    var isHot = false
    /// 固定宽约束（粗细档要改成 26）
    /// 固定宽约束（粗细档要改成 26）；setupCommon 里创建真约束（空约束 isActive 会抛异常）
    private(set) var widthConstraint = NSLayoutConstraint()
    private var selectedState = false
    /// 选中态的 inset 白高光（CSS 0 1px 0 rgba(255,255,255,.30) inset）
    private let highlightGradient = CAGradientLayer()
    private var highlightInstalled = false

    init(symbol: String, fallback: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            )
        } else {
            title = fallback
            font = .systemFont(ofSize: 14, weight: .medium)
        }
        setupCommon()
    }

    /// 自绘模板图（文字工具的 "T"：原型 #i-text 的三笔画，SF Symbols 无对应）
    init(templateImage: NSImage, fallback: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        templateImage.isTemplate = true
        self.image = templateImage
        if templateImage.size.width == 0 {
            title = fallback
            font = .systemFont(ofSize: 14, weight: .medium)
        }
        setupCommon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupCommon() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        widthConstraint = widthAnchor.constraint(equalToConstant: 28)
        widthConstraint.isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        contentTintColor = TBStyle.iconIdle
        // inset 白高光：顶部白 30% → 透明的渐变，mask 到圆角矩形
        highlightGradient.colors = [
            NSColor.white.withAlphaComponent(0.30).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        highlightGradient.startPoint = CGPoint(x: 0.5, y: 0)
        highlightGradient.endPoint = CGPoint(x: 0.5, y: 1)
        highlightGradient.locations = [0, 0.45]
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        // 渐变 mask 跟随 bounds
        let path = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        let mask = CAShapeLayer()
        mask.path = path
        highlightGradient.frame = bounds
        highlightGradient.mask = mask
        if selectedState, !highlightInstalled, let layer {
            layer.addSublayer(highlightGradient)
            highlightInstalled = true
        }
        if selectedState {
            layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                       cornerWidth: 8, cornerHeight: 8, transform: nil)
        }
    }

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

    /// hover 上移 2pt（CSS translateY(-2px)）；AppKit 图层 y 向下为正 ⇒ y=-2 向上
    private func setLifted(_ lifted: Bool) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.transform = lifted ? CATransform3DMakeTranslation(0, -2, 0) : CATransform3DIdentity
        CATransaction.commit()
    }

    /// 换图标（眼睛显隐态用）
    func setSymbol(_ symbol: String, fallback: String) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            )
        } else {
            title = fallback
            font = .systemFont(ofSize: 13, weight: .medium)
        }
    }

    func setSelected(_ selected: Bool) {
        selectedState = selected
        if !selected, highlightInstalled {
            highlightGradient.removeFromSuperlayer()
            highlightInstalled = false
        }
        applyStyle()
    }

    func applyStyle() {
        let selected = selectedState
        setLifted(isHot)
        if selected {
            layer?.backgroundColor = (isHot ? TBStyle.accentHover : TBStyle.accent).cgColor
            contentTintColor = TBStyle.iconActive
            // 蓝色外发光：0 2px 8px rgba(10,132,255,.42) → radius 4 / offset -2（向下）
            layer?.shadowColor = TBStyle.accentGlow.cgColor
            layer?.shadowOpacity = 1
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: -2)
            layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                       cornerWidth: 8, cornerHeight: 8, transform: nil)
        } else if isHot {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            contentTintColor = TBStyle.iconActive
            layer?.shadowOpacity = 0
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = TBStyle.iconIdle
            layer?.shadowOpacity = 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        // :active → scale(.96)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        CATransaction.commit()
        super.mouseDown(with: event)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        setLifted(isHot)
        CATransaction.commit()
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
        if tool == .text {
            // 原型 #i-text 是衬线 "T"；SF Symbols（textformat/character）都长得像 "A"，
            // 按原型三笔画自绘 17pt 模板图
            super.init(templateImage: Self.makeTextGlyph(), fallback: tool.label)
        } else {
            super.init(symbol: tool.symbolName, fallback: tool.label)
        }
        tag = tool.rawValue
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 17pt 模板图：原型 #i-text 三笔画，24 单位 SVG 坐标 ×17/24、y 翻转后取整
    private static func makeTextGlyph() -> NSImage {
        let size: CGFloat = 17
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3.54, y: 12.46))   // (5, 6.4)
        path.line(to: NSPoint(x: 13.46, y: 12.46))  // (19, 6.4)
        path.move(to: NSPoint(x: 8.5, y: 12.46))    // (12, 6.4)
        path.line(to: NSPoint(x: 8.5, y: 4.53))     // (12, 17.6)
        path.move(to: NSPoint(x: 6.38, y: 4.53))    // (9, 17.6)
        path.line(to: NSPoint(x: 10.63, y: 4.53))   // (15, 17.6)
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.stroke()
        image.unlockFocus()
        return image
    }
}

// MARK: - 颜色点（15×15，选中白环 + 外圈黑环）

@MainActor
private final class TBColorButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private let dot = NSView()
    /// 选中态外圈：0 0 0 3px rgba(0,0,0,.32)
    private let outerRing = CAShapeLayer()
    private var trackingArea: NSTrackingArea?
    private var selected = false

    init(color: NSColor) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // 命中区 = 色点本身（原型 .dot 无 hover 底色，只有 scale 1.18）
        widthAnchor.constraint(equalToConstant: 15).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 7.5
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.borderWidth = 0.5
        dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.28).cgColor
        outerRing.fillColor = NSColor.clear.cgColor
        outerRing.strokeColor = NSColor.black.withAlphaComponent(0.32).cgColor
        outerRing.lineWidth = 1.5
        outerRing.isHidden = true
        dot.layer?.addSublayer(outerRing)
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

    override func layout() {
        super.layout()
        // 外圈路径：比 dot 大 1.5pt 的同心圆（环内缘 1.5 外缘 3，即 CSS 0 0 0 3px）
        let rect = dot.bounds.insetBy(dx: -1.5, dy: -1.5)
        outerRing.frame = rect.insetBy(dx: -outerRing.lineWidth / 2, dy: -outerRing.lineWidth / 2)
        outerRing.path = CGPath(ellipseIn: outerRing.bounds, transform: nil)
    }

    /// ⚠️ 必须把命中测试指回按钮自身：装饰性的 dot 子视图会吃掉 mouseDown，
    /// NSButton 收不到就没有 action（病例：颜色点了完全没反应）
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.5, 1))
        dot.layer?.transform = CATransform3DMakeScale(1.18, 1.18, 1)
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        dot.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    func setSelected(_ isOn: Bool) {
        selected = isOn
        if isOn {
            // 0 0 0 1.5px rgba(255,255,255,.95) + 外圈 3px 黑 32%
            dot.layer?.borderWidth = 1.5
            dot.layer?.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
            outerRing.isHidden = false
        } else {
            dot.layer?.borderWidth = 0.5
            dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.28).cgColor
            outerRing.isHidden = true
        }
    }
}

// MARK: - 粗细档（26×28，横条 13pt 宽、高 2/4/6）

@MainActor
private final class TBWidthButton: TBIconButton {
    private let bar = NSView()
    let level: Int
    private var isOn = false

    init(level: Int) {
        self.level = level
        super.init(symbol: "", fallback: "")
        // 父类没给图：粗细档全靠横条
        image = nil
        title = ""
        widthConstraint.constant = 26
        let barHeight: CGFloat = CGFloat(level * 2)   // 2 / 4 / 6，三档一眼可分
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.cornerRadius = barHeight / 2       // 胶囊端头（CSS border-radius 3px）
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 13),
            bar.heightAnchor.constraint(equalToConstant: barHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// ⚠️ 同颜色点：bar 子视图会吞掉 mouseDown，命中测试必须指回按钮自身
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func setSelected(_ isOn: Bool) {
        self.isOn = isOn
        super.setSelected(isOn)
        // 颜色跟随选中态（CSS currentColor：默认白 82%，选中/hover 白）
        bar.layer?.backgroundColor = (isOn ? TBStyle.iconActive : TBStyle.iconIdle).cgColor
    }

    override func applyStyle() {
        super.applyStyle()
        if !isOn, isHot {
            bar.layer?.backgroundColor = NSColor.white.cgColor
        } else {
            bar.layer?.backgroundColor = (isOn ? TBStyle.iconActive : TBStyle.iconIdle).cgColor
        }
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
            self.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        }
        imagePosition = .imageLeading
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1).cgColor
        applyShadow(hot: false)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 20   // padding 0 10：加宽后内容居中，两侧各留 10
        return size
    }

    private func applyShadow(hot: Bool) {
        // 静止：0 3px 10px rgba(10,132,255,.38)；hover：0 6px 16px rgba(10,132,255,.45)
        layer?.shadowColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0,
                                     alpha: hot ? 0.45 : 0.38).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = hot ? 8 : 5
        layer?.shadowOffset = CGSize(width: 0, height: hot ? -6 : -3)
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   cornerWidth: 8, cornerHeight: 8, transform: nil)
    }

    override func layout() {
        super.layout()
        applyShadow(hot: isHot)
    }

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
        // hover：#1A8CFF + 上移 2pt + 更大投影
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        layer?.backgroundColor = NSColor(srgbRed: 0.102, green: 0.549, blue: 1.0, alpha: 1).cgColor
        layer?.transform = CATransform3DMakeTranslation(0, -2, 0)
        CATransaction.commit()
        applyShadow(hot: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        onHover?(false)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        layer?.backgroundColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1).cgColor
        layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        applyShadow(hot: false)
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
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.backgroundColor = NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 0.86).cgColor
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // 0 6px 16px rgba(0,0,0,.35)
        bg.layer?.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        bg.layer?.shadowOpacity = 1
        bg.layer?.shadowRadius = 8
        bg.layer?.shadowOffset = CGSize(width: 0, height: -6)

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
            // padding 3.5 8 → 高 21
            let w = size.width + 16
            let h: CGFloat = 21
            let x = rect.midX - w / 2
            let y = rect.maxY + 8
            setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            contentView?.layer?.shadowPath = CGPath(
                roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                cornerWidth: 6, cornerHeight: 6, transform: nil)
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
        case .text: return "textformat"          // 实际用自绘 "T"（见 TBToolButton）
        case .mosaic: return "checkerboard.rectangle"
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
