import AppKit
import CoreGraphics

/// 标注工具栏（重设计 scene 01 的 1:1 移植）
///
/// 视觉真源：`html-pages/snapcut-design-redesign/index.html` scene 01 `.toolbar`；
/// 施工图：同目录 tokens.md §2/§5/§9。所有 token 从 DesignTokens.swift 取值。
/// 逐条对齐（CSS px = pt）：
/// - 面板：padding 10（内容高 56）、radius 14、
///   mat.hud（hudWindow 钉暗，**不再叠 60% 深色着色**——材质本身已够暗）、
///   border 0.5pt stroke（白 .14）、inset.hi 顶缘内高光 白 .10、
///   shadow.float 单层投影（radius 44 offset(0,18) α.30 spread 20，高而淡）
/// - 按钮：32×32、radius 8、图标 20pt（2026-11-17 工具栏图标重设计：推荐档
///   icon 20 + 按钮 32，圆角随尺寸 7→8；对比稿 snapcut-toolbar-icons/index.html）；默认白 85%、
///   hover fill.hover（灰 α.36）**不上移**；选中 accent 实心 + 白图标 + inset.hi.strong，
///   **删除蓝色外发光**
/// - 颜色点 14pt（选中：内环 1.5pt 白 .85 @−4.5 + 外环 1.5pt 白 .28 @−8）、间距 6
/// - 主动作「复制」32×32 纯图标 accent 实心键（唯一彩色 accent，与保存/取消同构；同步 32 全条一致）
/// - 粗细：连续滑杆 2-6pt（tickless + continuous，实时生效）76×20
/// - 分组：工具(6+滚动截图) | 属性(5色+滑杆) | 历史(撤销/重做/取字/贴图/显隐) | 输出(复制/保存/取消)，
///   组间 hairline 分隔（白 .12 × 高 20，两侧各 4 ⇒ 线到内容 12）
/// - 悬停提示：深色胶囊（caption 10.5，上方 8pt，阴影 0 6px 16px 黑 35%）
///
/// 结构要点：按钮的选中态/悬停态不能被裁剪 ⇒ 栈不放进 effect view
/// （其 layer.masksToBounds=true 会裁掉子视图），而是放在无裁剪的根视图上。
///
/// 投影（v0.5 修复）：窗口四周留 shadowMargin 空白，投影图层铺在面板本体四周，
/// 溢出面板边界的阴影画在留白区里；留白区 hitTest 穿透（不挡下层编辑画布）。
/// 旧版两个投影视图从未加布局约束（frame 恒为 0）且窗口=面板大小，阴影整个被
/// 窗口边界裁掉——工具栏从来没有过投影。
///
/// 铁律：nonactivatingPanel（不抢激活）；点击不 makeKey。

/// 视觉 token：全部从 DesignTokens 取值（单一真源）；此处只留工具栏专属布局量
@MainActor
private enum TBStyle {
    static let paddingH: CGFloat = DesignTokens.Toolbar.padding      // 10
    static let paddingV: CGFloat = DesignTokens.Toolbar.padding
    static let cornerRadius: CGFloat = DesignTokens.Radius.xl        // 14
    // 2026-11-17 重设计：按钮 32×32 / radius 8（推荐档）——不再取 Control.h(28)/Radius.md(7)，
    // 工具栏专用尺寸在这里定值，其他界面的标准控件尺寸不受影响
    static let buttonSide: CGFloat = 32
    static let buttonRadius: CGFloat = 8
    static let iconPointSize: CGFloat = 20                           // 重设计推荐档：icon 20pt
    static let iconWeight = NSFont.Weight.medium
    static let separatorWidth: CGFloat = 0.5
    static let separatorHeight: CGFloat = DesignTokens.Toolbar.separatorHeight // 20
    static let separatorMargin: CGFloat = DesignTokens.Toolbar.separatorMargin // 4
    /// 窗口四周投影留白：NSWindow 会把 contentView 外的绘制裁掉，
    /// 面板投影要溢出面板边界就得多给窗口留画布；留白区 hitTest 穿透。
    /// 尺寸校验：轻盈感审查新值（shadowMargin 40→28）——单层影上缘仅 offset 18 −
    /// (radius 44 − spread 20) = −6（收进面板），左右 24、下缘 42（尾部 α.30 极淡）
    static let shadowMargin: CGFloat = 28
    static let dotSide: CGFloat = DesignTokens.Toolbar.dotSide       // 14
    static let dotGap: CGFloat = DesignTokens.Toolbar.dotGap         // 6
    static let sliderWidth: CGFloat = DesignTokens.Control.sliderWidth // 76
    static let accent = DesignTokens.accent
    static let accentHover = DesignTokens.accentHover
    static let iconIdle = NSColor.white.withAlphaComponent(DesignTokens.Toolbar.iconIdleAlpha)
    static let iconActive = DesignTokens.labelOnAccent
    static let iconDisabledAlpha = DesignTokens.Toolbar.iconDisabledAlpha
}

/// 窗口 contentView：比面板本体大 2×shadowMargin，专供投影溢出绘制；
/// 面板矩形之外的留白区 hitTest 返回 nil ⇒ 点击穿透给下层编辑画布
/// （与旧版窗口=面板大小时的行为一致：面板外的点击从来都落在画布上）
@MainActor
private final class TBOuterView: NSView {
    weak var panelRootView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let panel = panelRootView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return panel.frame.contains(local) ? super.hitTest(point) : nil
    }
}

@MainActor
final class ToolbarPanel: NSPanel {
    private weak var session: EditorSession?
    private var onToolChange: () -> Void = {}
    private var onAction: (Action) -> Void = { _ in }

    enum Action {
        case undo, redo, toggleVisibility, done, save, cancel, ocr, pin, scroll
    }

    // 视图
    private var rootStack: NSStackView!
    /// 面板本体视图（玻璃圆角矩形，不含投影留白）
    private var panelRoot: NSView?
    private var toolButtons: [EditorSession.Tool: TBToolButton] = [:]
    private var colorButtons: [TBColorButton] = []
    private var strokeWidthSlider: NSSlider!
    private var undoButton: TBIconButton!
    private var redoButton: TBIconButton!
    private var eyeButton: TBIconButton?
    private var tooltip: ToolbarTooltipWindow?

    init() {
        let m = TBStyle.shadowMargin
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560 + m * 2, height: DesignTokens.Toolbar.height + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // ⚠️ 必须比覆盖层（.screenSaver）高一级：同级时覆盖层 makeKey 后会压在
        // 工具栏上面，把点击全部吃掉（病例：所有按钮点了没反应）
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // ⚠️ 玻璃材质钉死暗色：不设的话跟随系统主题，浅色模式下 .hudWindow 是浅色
        // 材质，叠 60% 深色后成浑浊中灰，没有玻璃感（用户实报「不透明深灰」）
        appearance = NSAppearance(named: .darkAqua)
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
        strokeWidthSlider.doubleValue = Double(session.strokeWidth)
        refreshSelectionState()
    }

    // MARK: - UI 构建

    private func buildUI() {
        let m = TBStyle.shadowMargin

        // 0) 外层窗口 contentView：比面板大 2×shadowMargin，专供投影溢出绘制；
        //    留白区（面板矩形之外）hitTest 返回 nil，点击穿透给下层编辑画布
        let outer = TBOuterView()
        outer.wantsLayer = true
        // 注意：contentView 不设 translatesAutoresizingMaskIntoConstraints=false，
        // 窗口 setContentSize 直接管它的 frame（设了反而丢失窗口尺寸联动）

        // 面板本体（玻璃圆角矩形）：按钮发光/hover 上移在它上面溢出绘制，
        // 所以它自身也不 masksToBounds（裁剪交给 effect view 自己）
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(root)
        panelRoot = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: m),
            root.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -m),
            root.topAnchor.constraint(equalTo: outer.topAnchor, constant: m),
            root.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -m),
        ])

        // 1) 面板投影（shadow.float 单层，高而淡：r44 · offset(0,-18) · α.30 · spread 20）
        let shadowFloat = makeShadowView(radius: 44, offset: CGSize(width: 0, height: -18),
                                         alpha: 0.30, spread: 20)
        root.addSubview(shadowFloat)
        // ⚠️ 旧版病例：投影视图只创建没加约束（frame 恒为 0），且窗口=面板大小，
        // 阴影被窗口边界裁掉——投影从来没画出来过。现在铺满面板本体，
        // shadowPath 用自身 bounds（见 applyPanelShadowPaths）
        NSLayoutConstraint.activate([
            shadowFloat.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shadowFloat.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            shadowFloat.topAnchor.constraint(equalTo: root.topAnchor),
            shadowFloat.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // 2) 玻璃容器（mat.hud：hudWindow 磨砂，**不再叠深色着色**——材质本身已够暗）；
        //    窗口 appearance 已钉死 darkAqua（见 init），浅色系统下也能出暗玻璃
        let effect = NSVisualEffectView()
        effect.material = DesignTokens.Mat.hud
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.layer?.cornerRadius = TBStyle.cornerRadius
        effect.layer?.masksToBounds = true      // 只裁自己的材质/描边，按钮不在它里面
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = DesignTokens.stroke.cgColor
        root.addSubview(effect)

        // 2b) 面板 inset 高光：inset.hi（顶缘 1pt 白 .10，贴描边下沿，被圆角裁剪）
        //     （tokens.md 允许「或 layer 内阴影替代」，此处用 1pt 条实现）
        let insetHighlight = NSView()
        insetHighlight.wantsLayer = true
        insetHighlight.translatesAutoresizingMaskIntoConstraints = false
        insetHighlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(DesignTokens.Inset.hiAlpha.0).cgColor
        effect.addSubview(insetHighlight)

        // 3) 内容栈（在 effect 之上、根视图之下 ⇒ 按钮发光不被裁）
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8    // 8pt 栅格：控件间距（旧值 1）
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

        // 1) 工具组 + 滚动截图入口：按 settings.toolbarOrder 自定义排序
        //    （用户裁定 2026-11-17；默认 = enum 序 + 滚动尾）
        let order = (AppCoordinatorShared.coordinator?.settings ?? .defaultSettings).toolbarOrderSafe()
        for raw in order {
            if raw == 206 {
                let scrollButton = TBIconButton(icon: .scroll, fallback: "滚")
                scrollButton.tag = 206
                scrollButton.target = self
                scrollButton.action = #selector(toolTapped(_:))
                scrollButton.onHover = { [weak self] inside in self?.handleHover(inside, button: scrollButton, text: "滚动截图 \(Self.hotkeyTip("scroll"))") }
                stack.addArrangedSubview(scrollButton)
            } else if let tool = EditorSession.Tool(rawValue: raw), tool != .none {
                let button = TBToolButton(tool: tool)
                button.target = self
                button.action = #selector(toolTapped(_:))
                button.onHover = { [weak self] inside in self?.handleHover(inside, button: button, text: tool.tipText) }
                toolButtons[tool] = button
                stack.addArrangedSubview(button)
            }
        }

        stack.addArrangedSubview(makeSeparator())

        // 2) 五色（.tb-dots：gap 6）
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

        // 3) 粗细连续滑杆（2-6pt 实时生效：下一个新标注用当前值，已有标注不变）
        let slider = TBStrokeSlider(value: 2, minValue: 2, maxValue: 6, target: self, action: #selector(strokeSliderChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        let sliderHolder = NSView()
        sliderHolder.translatesAutoresizingMaskIntoConstraints = false
        sliderHolder.addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: sliderHolder.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: sliderHolder.trailingAnchor),
            slider.centerYAnchor.constraint(equalTo: sliderHolder.centerYAnchor),
            sliderHolder.widthAnchor.constraint(equalToConstant: TBStyle.sliderWidth),
            sliderHolder.heightAnchor.constraint(equalToConstant: TBStyle.buttonSide),
        ])
        slider.onHover = { [weak self] inside in self?.handleHover(inside, button: sliderHolder, text: "粗细") }
        strokeWidthSlider = slider
        stack.addArrangedSubview(sliderHolder)

        stack.addArrangedSubview(makeSeparator())

        // 4) 撤销 / 重做
        undoButton = TBIconButton(icon: .undo, fallback: "↩︎")
        undoButton.target = self
        undoButton.action = #selector(actionTapped(_:))
        undoButton.tag = 100
        undoButton.onHover = { [weak self] inside in self?.handleHover(inside, button: self?.undoButton, text: "撤销 \(Self.hotkeyTip("undo"))") }
        stack.addArrangedSubview(undoButton)

        redoButton = TBIconButton(icon: .redo, fallback: "↪︎")
        redoButton.target = self
        redoButton.action = #selector(actionTapped(_:))
        redoButton.tag = 101
        redoButton.onHover = { [weak self] inside in self?.handleHover(inside, button: self?.redoButton, text: "重做 \(Self.hotkeyTip("redo"))") }
        stack.addArrangedSubview(redoButton)

        stack.addArrangedSubview(makeSeparator())

        // 5) 取字 / 贴图 / 显隐
        let ocr = TBIconButton(icon: .ocr, fallback: "字")
        ocr.tag = 204
        ocr.target = self
        ocr.action = #selector(actionTapped(_:))
        ocr.onHover = { [weak self] inside in self?.handleHover(inside, button: ocr, text: "取字 \(Self.hotkeyTip("ocr"))") }
        stack.addArrangedSubview(ocr)

        let pin = TBIconButton(icon: .pin, fallback: "钉")
        pin.tag = 205
        pin.target = self
        pin.action = #selector(actionTapped(_:))
        pin.onHover = { [weak self] inside in self?.handleHover(inside, button: pin, text: "贴图 \(Self.hotkeyTip("pin"))") }
        stack.addArrangedSubview(pin)

        let eye = TBIconButton(icon: .eye, fallback: "眼")
        eye.tag = 200
        eyeButton = eye
        eye.target = self
        eye.action = #selector(actionTapped(_:))
        eye.onHover = { [weak self] inside in self?.handleHover(inside, button: eye, text: "隐藏工具栏 \(Self.hotkeyTip("toggleVisibility"))") }
        stack.addArrangedSubview(eye)

        stack.addArrangedSubview(makeSeparator())

        // 6) 主按钮「复制」（32×32 纯图标 accent 实心键，唯一彩色 accent；tooltip 保留）
        //    + 保存 + 取消（同构，无彩）
        let copy = TBPrimaryButton(icon: .copy)
        copy.tag = 201
        copy.target = self
        copy.action = #selector(actionTapped(_:))
        copy.onHover = { [weak self] inside in self?.handleHover(inside, button: copy, text: "复制并完成 \(Self.hotkeyTip("done"))") }
        stack.addArrangedSubview(copy)

        let save = TBIconButton(icon: .save, fallback: "存")
        save.tag = 202
        save.target = self
        save.action = #selector(actionTapped(_:))
        save.onHover = { [weak self] inside in self?.handleHover(inside, button: save, text: "保存 \(Self.hotkeyTip("save"))") }
        stack.addArrangedSubview(save)

        let close = TBIconButton(icon: .cancel, fallback: "×")
        close.tag = 203
        close.target = self
        close.action = #selector(actionTapped(_:))
        close.onHover = { [weak self] inside in self?.handleHover(inside, button: close, text: "取消 \(Self.hotkeyTip("cancel"))") }
        stack.addArrangedSubview(close)

        contentView = outer
        outer.panelRootView = root
        root.layoutSubtreeIfNeeded()
        let fitting = root.fittingSize
        // 窗口 = 面板 + 四周投影留白（留白区点击穿透，见 TBOuterView）
        setContentSize(NSSize(width: fitting.width + m * 2, height: fitting.height + m * 2))
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
        // path 在布局后由面板统一设置（见 applyPanelShadowPaths）；
        // 视图铺满面板本体，shadowPath 直接用自身 bounds（无跨坐标系换算）
        view.layer?.name = "panel-shadow-\(radius)"
        view.layer?.shadowPath = nil
        if spread > 0 { view.layer?.setValue(spread, forKey: "shadowSpreadHint") }
        return view
    }

    /// 布局完成后给投影视图设置 shadowPath（含 spread 20：路径内缩 20）。
    /// 投影视图已铺满面板本体，路径直接取自身 bounds，无跨视图坐标系换算
    private func applyPanelShadowPaths() {
        guard let root = panelRoot else { return }
        for subview in root.subviews where subview.layer?.name?.hasPrefix("panel-shadow") == true {
            let spread = (subview.layer?.value(forKey: "shadowSpreadHint") as? CGFloat) ?? 0
            let rect = CGRect(origin: .zero, size: subview.bounds.size).insetBy(dx: spread, dy: spread)
            subview.layer?.shadowPath = CGPath(
                roundedRect: rect,
                cornerWidth: TBStyle.cornerRadius,
                cornerHeight: TBStyle.cornerRadius,
                transform: nil
            )
        }
    }

    private func makeSeparator() -> NSView {
        // .tb-sep：0.5×20、margin 0 4（栈间距 8 ⇒ 线到内容 12）
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = DesignTokens.hair.cgColor
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

    // MARK: - 位置（选区下方 12pt，放不下翻上方）+ spring 出场

    private var targetScreen: NSScreen?

    func updateScreen(_ screen: NSScreen) {
        targetScreen = screen
    }

    func place(below selection: CGRect) {
        place(panelOriginFor: { visible, panelSize in
            // 1) 优先选区下方 12pt；2) 下方放不下翻到上方；3) 全屏截图这种上下都没有外部
            //    空间的情况，**落进可视区内**（贴底），否则会跑到屏幕外被裁掉（用户实拍病例）
            var origin = CGPoint(x: selection.midX - panelSize.width / 2,
                                 y: selection.minY - panelSize.height - 12)
            if origin.y < visible.minY + 8 {
                let above = selection.maxY + 12
                if above + panelSize.height <= visible.maxY - 8 {
                    origin.y = above
                } else {
                    // 全屏/贴边选区：放在可视区靠下位置（比贴顶更符合直觉、更好点）
                    origin.y = visible.minY + 16
                }
            }
            return origin
        })
    }

    /// 拼贴合成编辑窗场景（设计定稿 §1.4）：工具栏贴宿主窗顶（框顶外 12pt），
    /// 顶上放不下翻到窗底
    func place(aboveGlobal hostRect: CGRect) {
        place(panelOriginFor: { visible, panelSize in
            var origin = CGPoint(x: hostRect.midX - panelSize.width / 2,
                                 y: hostRect.maxY + 12)
            if origin.y + panelSize.height > visible.maxY - 8 {
                origin.y = hostRect.minY - panelSize.height - 12
            }
            return origin
        })
    }

    /// 共用定位/出场动画：panelOriginFor 返回「面板本体」原点（不含投影留白）
    private func place(panelOriginFor compute: (_ visible: CGRect, _ panelSize: CGSize) -> CGPoint) {
        applyPanelShadowPaths()
        contentView?.layoutSubtreeIfNeeded()
        let margin = TBStyle.shadowMargin
        // frame 含四周投影留白；定位算的是「面板本体」矩形
        let panelSize = CGSize(width: frame.width - margin * 2,
                               height: frame.height - margin * 2)
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = compute(visible, panelSize)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)

        // motion.enter 入场：rise 10pt + scale .97→1 + fade，0.26s spring
        // （注释里的 scale 承诺已兑现；窗体 frame 动画走 NSAnimationContext，
        //  scale 在根视图 layer transform 上同步动画）
        let finalFrame = CGRect(origin: CGPoint(x: origin.x - margin, y: origin.y - margin),
                                size: frame.size)
        setFrameOrigin(CGPoint(x: finalFrame.minX, y: finalFrame.minY - DesignTokens.Motion.enterRise))
        alphaValue = 0
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeScale(DesignTokens.Motion.enterScale,
                                                     DesignTokens.Motion.enterScale, 1)
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.springTimingFunction
            self.animator().setFrame(finalFrame, display: true)
            self.animator().alphaValue = 1
        })
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.enterDuration)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.springTimingFunction)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        scheduleButtonDump()
    }

    /// H 显隐唤回时的复用入场（与 place() 同语言：fade + rise 10pt + scale .97→1）
    func playEnter() {
        guard isVisible else { return }
        let finalFrame = frame
        setFrameOrigin(CGPoint(x: finalFrame.minX, y: finalFrame.minY - DesignTokens.Motion.enterRise))
        alphaValue = 0
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeScale(DesignTokens.Motion.enterScale,
                                                     DesignTokens.Motion.enterScale, 1)
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.springTimingFunction
            self.animator().setFrame(finalFrame, display: true)
            self.animator().alphaValue = 1
        })
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.enterDuration)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.springTimingFunction)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    /// motion.exit 退场：fade + scale→.97 + 下沉 4pt，0.16s ease-in；
    /// orderOut 延迟到动画尾（completionHandler 强持有 self，调用方同步置 nil
    /// 也不会让动画中断）。H 显隐、会话结束共用。
    func dismiss() {
        tooltip?.hide()
        guard isVisible else {
            orderOut(nil)
            return
        }
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.exitDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
            layer.transform = CATransform3DMakeScale(DesignTokens.Motion.exitScale,
                                                     DesignTokens.Motion.exitScale, 1)
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.exitDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            var sinkFrame = frame
            sinkFrame.origin.y -= DesignTokens.Motion.exitSink
            self.animator().setFrame(sinkFrame, display: true)
        }, completionHandler: {
            self.orderOut(nil)
            if let layer = self.contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        })
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

    /// 编辑器热键 tooltip 文案：当前设置值（用户病例 2026-11-16「贴图改 t 了
    /// toolbar 还显示 p」）——硬编码快捷键全部改为实时读
    private static func hotkeyTip(_ action: String) -> String {
        let combo = AppCoordinatorShared.coordinator?.settings.editorHotkey(for: action) ?? ""
        return HotkeySpec.display(combo)
    }

    func refreshSelectionState() {
        guard let session else { return }
        for (tool, button) in toolButtons {
            button.setSelected(tool == session.currentTool)
        }
        for (i, button) in colorButtons.enumerated() {
            button.setSelected(i == session.colorIndex)
        }
        strokeWidthSlider.doubleValue = Double(session.strokeWidth)
        undoButton.isEnabled = session.store.canUndo
        redoButton.isEnabled = session.store.canRedo
        // 病例：仅靠 isEnabled 的 didSet→alphaValue 在首次 build 时可能不生效，
        // 这里显式再刷一次，保证「有标注变亮 / 无标注置灰」在视觉上确定
        undoButton.alphaValue = session.store.canUndo ? 1 : 0.35
        redoButton.alphaValue = session.store.canRedo ? 1 : 0.35
    }

    /// 工具栏显隐态图标（隐藏时 eye.slash）
    /// 工具栏隐藏时同步收起悬停提示（病例 2026-11-15：按 H 隐藏工具栏后
    /// tooltip 永久滞留——tracking 区随窗 orderOut 消失，mouseExited 永不触发；
    /// tooltip 是 screenSaver 层独立 NSPanel，宿主窗没了它还浮着）
    func hideTooltip() {
        tooltip?.hide()
    }

    func setToolbarHidden(_ hidden: Bool) {
        eyeButton?.setSymbol(hidden ? "eye.slash" : "eye", fallback: "眼")
        Log.event(.editor, "toolbar.eye.icon", ["state": hidden ? "hidden" : "visible"])
    }

    // MARK: - 悬停提示

    private func handleHover(_ inside: Bool, button: NSView?, text: String) {
        if inside, let button {
            if tooltip == nil { tooltip = ToolbarTooltipWindow() }
            let frameInWindow = button.convert(button.bounds, to: nil)
            var screenRect = self.convertToScreen(frameInWindow)
            // 病例（用户 2026-11-16「label 在 bar 下面被遮一半」）：按钮顶之
            // 上还有 bar 的 padding（12pt）——tooltip 贴按钮顶会嵌进 bar 内部，
            // 与玻璃面板视觉混叠被「遮」。锚定改 panel 顶（窗顶）外 6pt 起
            // panel（self）顶外 6pt：tooltip 永不嵌进玻璃面板
            screenRect.origin.y = frame.maxY
            screenRect.size.height = 0
            tooltip?.show(text: text, above: screenRect, after: 0.12)
        } else {
            tooltip?.hide()
        }
    }

    // MARK: - 事件

    @objc private func toolTapped(_ sender: NSButton) {
        // 滚动截图入口（用户裁定：进工具组，tag 206 = 新值）
        if sender.tag == 206 {
            tooltip?.hide()
            onAction(.scroll)
            return
        }
        guard let tool = EditorSession.Tool(rawValue: sender.tag) else { return }
        // 再点已选工具 = 取消回 .none（与数字键同语义：默认无工具拖动=移动）
        session?.currentTool = (session?.currentTool == tool) ? .none : tool
        Log.event(.editor, "annotate.tool.select", ["tool": tool.label])
        refreshSelectionState()
        onToolChange()
    }

    @objc private func colorTapped(_ sender: NSButton) {
        Log.event(.editor, "toolbar.color", ["index": "\(sender.tag)"])
        session?.colorIndex = sender.tag
        refreshSelectionState()
    }

    @objc private func strokeSliderChanged(_ sender: NSSlider) {
        let width = CGFloat(sender.doubleValue)
        session?.strokeWidth = width
        Log.event(.editor, "toolbar.stroke", ["width": String(format: "%.1f", width)])
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

// MARK: - 按钮选中/悬停共通态（.tb-btn 三态；hover 只换 fill 底，不上移；选中无发光）

@MainActor
class TBIconButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    var isHot = false
    /// 固定宽约束（粗细档要改成 26）
    /// 固定宽约束（粗细档要改成 26）；setupCommon 里创建真约束（空约束 isActive 会抛异常）
    private(set) var widthConstraint = NSLayoutConstraint()
    private var selectedState = false
    /// 选中态的 inset 白高光（inset.hi.strong：顶缘白 .16 渐隐）
    private let highlightGradient = CAGradientLayer()
    private var highlightInstalled = false

    init(symbol: String, fallback: String) {
        super.init(frame: .zero)
        setupButtonShell()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: TBStyle.iconPointSize, weight: TBStyle.iconWeight)
            )
        } else {
            title = fallback
            font = .systemFont(ofSize: 14, weight: .medium)
        }
        setupCommon()
    }

    /// 设计稿自绘线性图标（TBIcon，模板图 + contentTintColor 上色）
    init(icon: TBIcon.Kind, fallback: String) {
        super.init(frame: .zero)
        setupButtonShell()
        image = TBIcon.image(icon, pointSize: TBStyle.iconPointSize)
        setupCommon()
    }

    private func setupButtonShell() {
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
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
        layer?.cornerRadius = TBStyle.buttonRadius
        widthConstraint = widthAnchor.constraint(equalToConstant: TBStyle.buttonSide)
        widthConstraint.isActive = true
        heightAnchor.constraint(equalToConstant: TBStyle.buttonSide).isActive = true
        contentTintColor = TBStyle.iconIdle
        // inset.hi.strong：顶部白 .16 → 透明的渐变，mask 到圆角矩形
        highlightGradient.colors = [
            NSColor.white.withAlphaComponent(DesignTokens.Inset.strongAlpha).cgColor,
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
        let path = CGPath(roundedRect: bounds,
                          cornerWidth: TBStyle.buttonRadius, cornerHeight: TBStyle.buttonRadius,
                          transform: nil)
        let mask = CAShapeLayer()
        mask.path = path
        highlightGradient.frame = bounds
        highlightGradient.mask = mask
        if selectedState, !highlightInstalled, let layer {
            layer.addSublayer(highlightGradient)
            highlightInstalled = true
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

    /// 换图标（眼睛显隐态用）
    func setSymbol(_ symbol: String, fallback: String) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: TBStyle.iconPointSize, weight: TBStyle.iconWeight)
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

    /// 选中 = accent 实心 + 白图标 + 顶缘内高光；不再发光（删蓝色 glow）、不再上移
    func applyStyle() {
        let selected = selectedState
        if selected {
            layer?.backgroundColor = (isHot ? TBStyle.accentHover : TBStyle.accent).cgColor
            contentTintColor = TBStyle.iconActive
            layer?.shadowOpacity = 0
        } else if isHot {
            layer?.backgroundColor = DesignTokens.fillHover.cgColor
            contentTintColor = TBStyle.iconActive
            layer?.shadowOpacity = 0
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = TBStyle.iconIdle
            layer?.shadowOpacity = 0
        }
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : TBStyle.iconDisabledAlpha } }
}

/// 工具按钮：图标 + 数字热键语义（tooltip 由 ToolbarPanel 统一弹）
@MainActor
private final class TBToolButton: TBIconButton {
    let tool: EditorSession.Tool

    init(tool: EditorSession.Tool) {
        self.tool = tool
        // 设计稿 1:1 自绘线性图标（SF Symbol 字形比例与设计稿不符——
        // 用户实报「icon 没跟设计稿对齐/复制键竖着拉长」）
        super.init(icon: Self.iconKind(for: tool), fallback: tool.label)
        tag = tool.rawValue
    }

    private static func iconKind(for tool: EditorSession.Tool) -> TBIcon.Kind {
        switch tool {
        case .none: return .arrow   // none 不建按钮，fallback
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .rect: return .rect
        case .text: return .text
        case .mosaic: return .mosaic
        case .sequence: return .sequence
        case .highlight: return .highlight
        }
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

// MARK: - 颜色点（14×14，选中：内环 1.5pt 白 .85 @−4.5 + 外环 1.5pt 白 .28 @−8）

@MainActor
private final class TBColorButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private let dot = NSView()
    /// 选中态内环：白 .85，比 dot 大 4.5pt。终极方案（病例四轮）：CAShapeLayer
    /// 无论挂 dot.layer 还是 self.layer 都不显示——换真实 NSView（wantsLayer
    /// + 圆形描边），subview 渲染顺序无歧义
    private let innerRing = NSView()
    private let outerRing = NSView()
    private var trackingArea: NSTrackingArea?
    private var selected = false

    init(color: NSColor) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // 命中区 = 色点本身（原型 .dot 无 hover 底色，只有 scale 1.12）。
        // 容器独立于 icon 按钮档（用户病例：按钮 28→32 后色点间距视觉太远——
        // 色点容器跟 dotSide+6 走，不吃 icon 尺寸档）
        let dotHit: CGFloat = TBStyle.dotSide + 6
        widthAnchor.constraint(equalToConstant: dotHit).isActive = true
        heightAnchor.constraint(equalToConstant: dotHit).isActive = true

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = TBStyle.dotSide / 2
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.borderWidth = 0.5
        dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.28).cgColor
        for (ring, alpha) in [(innerRing, 0.85), (outerRing, 0.28)] {
            ring.translatesAutoresizingMaskIntoConstraints = false
            ring.wantsLayer = true
            ring.layer?.borderWidth = 1.5
            ring.layer?.borderColor = NSColor.white.withAlphaComponent(alpha).cgColor
            ring.isHidden = true
            addSubview(ring)
        }
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: TBStyle.dotSide),
            dot.heightAnchor.constraint(equalToConstant: TBStyle.dotSide),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 环几何（常量直算，零布局依赖）：相对按钮 bounds 中心，内环 = dot
        // 外扩 4.5，外环外扩 8（同心圆环，线宽 1.5）。ring 挂按钮 layer
        // （病例两轮：挂 dot.layer 时子 layer 布局时机 + 超界歧义，选中环
        // 持续不显示）
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        for (ring, outset) in [(innerRing, CGFloat(4.5)), (outerRing, CGFloat(8.0))] {
            let ringSide = TBStyle.dotSide + outset * 2
            ring.frame = CGRect(
                x: c.x - ringSide / 2, y: c.y - ringSide / 2,
                width: ringSide, height: ringSide)
            ring.layer?.cornerRadius = ringSide / 2
        }
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
        dot.layer?.transform = CATransform3DMakeScale(1.12, 1.12, 1) // 审查：14pt 点放大 18% 近邻冲突 → 1.12
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
        innerRing.isHidden = !isOn
        outerRing.isHidden = !isOn
    }
}

// MARK: - 粗细连续滑杆（tickless + continuous，2-6pt 实时）

@MainActor
private final class TBStrokeSlider: NSSlider {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    init(value: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)   // NSSlider 的便捷初始化器不是 designated，从 frame 走
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
        self.target = target
        self.action = action
        sliderType = .linear
        isContinuous = true          // 拖动中实时回调
        numberOfTickMarks = 0        // tickless：无刻度、无档位吸附
        allowsTickMarkValuesOnly = false
        controlSize = .small
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
}

// MARK: - 主按钮「复制」（32×32 accent 实心纯图标键：唯一彩色 accent；无发光无上移）

@MainActor
private final class TBPrimaryButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHot = false

    init(icon: TBIcon.Kind) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""                          // 去字：纯图标（信息走 tooltip）
        imagePosition = .imageOnly
        contentTintColor = DesignTokens.labelOnAccent
        self.image = TBIcon.image(icon, pointSize: TBStyle.iconPointSize)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = TBStyle.buttonRadius
        layer?.backgroundColor = DesignTokens.accent.cgColor
        widthAnchor.constraint(equalToConstant: DesignTokens.Toolbar.copyButtonSide).isActive = true
        heightAnchor.constraint(equalToConstant: TBStyle.buttonSide).isActive = true
        applyHot(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyHot(_ hot: Bool) {
        isHot = hot
        wantsLayer = true
        // hover = accent.hover（+0.12 亮度）；无位移、无发光（删旧 glow/上移）
        layer?.backgroundColor = (hot ? TBStyle.accentHover : TBStyle.accent).cgColor
        layer?.shadowOpacity = 0
        layer?.removeAnimation(forKey: "hot")
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
        applyHot(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        onHover?(false)
        applyHot(false)
    }
}

// MARK: - 悬停提示浮层（深色胶囊，上方 8pt）

@MainActor
private final class ToolbarTooltipWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var work: DispatchWorkItem?
    private var hideEpoch = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 22),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // ⚠️ 病例（用户「tooltip 被 bar 遮一半」）：工具栏 panel 自己是
        // screenSaver+1——tooltip 若同级/低于它会被压在下面。tooltip 永远
        // 比 bar 高一层
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
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
        // 0 4px 8px rgba(0,0,0,.22)（审查：描边+深底已够分离，阴影减淡收窄）
        bg.layer?.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        bg.layer?.shadowOpacity = 1
        bg.layer?.shadowRadius = 8
        bg.layer?.shadowOffset = CGSize(width: 0, height: -4)

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
        hideEpoch += 1   // 使未完成的 hide 退场动画失效（快速扫过按钮时 hide/show 交错）
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            label.stringValue = text
            contentView?.layoutSubtreeIfNeeded()
            let size = contentView?.fittingSize ?? CGSize(width: 80, height: 22)
            // padding 3.5 8 → 高 21
            let w = size.width + 16
            let h: CGFloat = 21
            var x = rect.midX - w / 2
            let y = rect.maxY + 8
            // 屏边 clamp（用户病例：hover label 顶部/侧边被裁——工具栏近屏幕
            // 边缘时 tooltip 出界）
            if let screenFrame = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
                let visible = screenFrame.visibleFrame
                x = max(visible.minX + 4, min(x, visible.maxX - w - 4))
            }
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
        // 退场补 fade 0.12s（原 orderOut 直切）：cancel work 后动画出再收窗。
        // epoch 守卫：退场动画期间又 show() 时，旧的 completion 不再收窗
        hideEpoch += 1
        let epoch = hideEpoch
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, epoch == self.hideEpoch else { return }
            self.orderOut(nil)
            self.alphaValue = 1   // 复位，下次 show() 从 0 起动画
        })
    }
}

// MARK: - 工具 → SF Symbol / 提示文案

private extension EditorSession.Tool {
    var symbolName: String {
        switch self {
        case .none: return "arrow.up.right"   // 同上：none 无按钮，fallback
        case .ellipse: return "circle"
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
        case .none: return "移动（无工具）"
        case .ellipse: return "椭圆 7"
        case .arrow: return "箭头 1"
        case .rect: return "矩形 2"
        case .text: return "文字 3"
        case .mosaic: return "马赛克 4"
        case .sequence: return "序号 5"
        case .highlight: return "高亮 6"
        }
    }
}
