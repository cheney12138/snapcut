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
    /// 当前工具栏生效的尺寸度量（由 ToolbarPanel.init 按 settings.toolbarSize 动态刷新）
    static var metrics = DesignTokens.Toolbar.Metrics.forSize(.regular)

    static var paddingH: CGFloat { metrics.paddingH }
    static var paddingV: CGFloat { metrics.paddingV }
    static var groupGap: CGFloat { metrics.groupGap }
    static var barHeight: CGFloat { metrics.height }
    static var cornerRadius: CGFloat { metrics.cornerRadius }
    static var innerPillRadius: CGFloat { metrics.innerPillRadius }
    static var buttonSide: CGFloat { metrics.buttonSide }
    static let buttonRadius: CGFloat = 7.5
    static var iconPointSize: CGFloat { metrics.iconPointSize }
    static let iconWeight = NSFont.Weight.medium
    static let separatorWidth: CGFloat = 0.5
    static var separatorHeight: CGFloat { metrics.separatorHeight }
    static var separatorMargin: CGFloat { metrics.separatorMargin }
    static let shadowMargin: CGFloat = 28
    static var dotSide: CGFloat { metrics.dotSide }
    static var dotGap: CGFloat { metrics.dotGap }
    static var strokeButtonSide: CGFloat { metrics.strokeButtonSide }
    static var strokeDotScale: CGFloat { metrics.strokeDotScale }
    static let accent = DesignTokens.accent
    static let accentHover = DesignTokens.accentHover
    static let iconIdle = DesignTokens.hudForeground(DesignTokens.Toolbar.iconIdleAlpha)
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

    var onBackdropStyleChange: ((BackdropStyle) -> Void)?

    enum Action {
        case undo, redo, toggleVisibility, done, save, cancel, ocr, pin, scroll, autoRedact, toggleBackdrop
    }

    // 视图
    private var rootStack: NSStackView!
    /// 面板本体视图（玻璃圆角矩形，不含投影留白）
    private var panelRoot: NSView?
    private var outerShadowView: OuterShadowView?
    private var toolButtons: [EditorSession.Tool: TBToolButton] = [:]
    private var colorButtons: [TBColorButton] = []
    private var strokeSlider: TBStrokeSlider!
    private var undoButton: TBIconButton!
    private var redoButton: TBIconButton!
    private var backdropButton: TBIconButton?
    private var eyeButton: TBIconButton?
    private var tooltip: ToolbarTooltipWindow?
    /// 马赛克工具上下文悬浮胶囊（仅选中马赛克时在图标上方轻浮出现「✦ 智能打码 ⇧M」，不增加主栏视觉负担）
    private var smartRedactPill: SmartRedactPillPanel?
    /// 画框美化上下文微调胶囊（仅 `backdropStyle.enabled == true` 且工具栏可见时轻浮展开）
    private var smartBackdropPill: SmartBackdropPillPanel?
    private var backdropStyle = BackdropStyle()
    /// `place(...)` 入场动画期间的目标栏主体全局矩形，确保附属胶囊直接锚定终态位置而不跳动
    private var plannedBarFrameGlobal: CGRect?
    /// 共享滑动选中指示层（工具蓝胶囊 / 颜色选环）：切换选项时物理弹簧滑移
    private var indicatorView: TBSelectionIndicatorView?
    private var lastSelectedTool: EditorSession.Tool = .none
    private var lastSelectedColor: Int = -1
    /// 复用面板的退场代际守卫：旧 dismiss 动画回调不得把新一次 place 出来的面板隐藏
    private var dismissEpoch = 0
    private var usesNativeLiquidGlass = false

    init() {
        let sizeSetting = AppCoordinatorShared.coordinator?.settings.toolbarSize ?? .regular
        TBStyle.metrics = DesignTokens.Toolbar.Metrics.forSize(sizeSetting)
        let m = TBStyle.shadowMargin
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620 + m * 2, height: TBStyle.barHeight + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // ⚠️ 必须比覆盖层（.screenSaver）高一级：同级时覆盖层 makeKey 后会压在
        // 工具栏上面，把点击全部吃掉（病例：所有按钮点了没反应）
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 固定浅色高晶玻璃主题（不随系统 Dark Mode 或截取画面明暗背景变幻切换）：
        // 统一由 `OuterShadowView` 双层投影 + `.aqua` 下高对比墨色前景保证白底/深底均稳定清晰。
        appearance = NSAppearance(named: .aqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // 禁用系统窗口自投暗影（避免污染 CABackdropLayer.tracksLuma），统一走 .continuous 镂空双层影
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        buildUI()
    }

    func configure(session: EditorSession, onToolChange: @escaping () -> Void, onAction: @escaping (Action) -> Void) {
        self.session = session
        self.onToolChange = onToolChange
        self.onAction = onAction
        lastSelectedTool = session.currentTool
        lastSelectedColor = session.colorIndex
        backdropStyle = BackdropStyle()
        backdropButton?.setSelected(false)
        smartBackdropPill?.hide(immediate: true)
        refreshSelectionState(animated: false)
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

        // 0.5) 双层光学投影宿主（紧贴接触影 + 柔和抬升影）：
        //      覆盖 outer 全部区域，内部按 .continuous 圆角 100% 镂空，绝不污染玻璃内部且无 AppKit shadowOpacity 清零坑
        let shadowHost = OuterShadowView(spec: .toolbar, margin: m, cornerRadius: TBStyle.cornerRadius)
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(shadowHost)
        outerShadowView = shadowHost
        NSLayoutConstraint.activate([
            shadowHost.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            shadowHost.topAnchor.constraint(equalTo: outer.topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
        ])

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

        // 1) 恒定浅色高晶玻璃容器（.aqua .menu 澄澈模糊 + .continuous 9-slice + 纯白晶透提亮）：
        //    彻底绕开 macOS 26 NSGlassEffectView 内部 CABackdropLayer.tracksLuma = 1 导致的跨 App 闪跳，
        //    同时保持远胜 .hudWindow 的高清透亮感。
        let glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: TBStyle.cornerRadius,
            tintAlpha: 0.08
        )
        usesNativeLiquidGlass = true

        let glassHost = glassSurface.hostView
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glassHost)

        // 2) 独立前景宿主（与 glassHost 同级且叠放其上）：
        //    macOS 26 的 NSGlassEffectView 会对嵌入其 contentView 内部的子视图施加自适应亮度活力渲染
        //    （随底层画面明暗把 isTemplate 图标在黑/白之间自动反转），即使父窗口锁 .aqua 也拦不住；
        //    把指示器与工具按钮放在同级前景色视图里，即可 100% 锁定恒定浅色深墨前景，绝不随背景变色！
        let foregroundHost = NSView()
        foregroundHost.wantsLayer = true
        foregroundHost.appearance = NSAppearance(named: .aqua)
        foregroundHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(foregroundHost)

        // 2.5) 滑动选中指示层（位于玻璃之上、按钮之下）
        let indicators = TBSelectionIndicatorView()
        indicators.translatesAutoresizingMaskIntoConstraints = false
        foregroundHost.addSubview(indicators)
        indicatorView = indicators

        // 3) 内容栈（位于指示层之上 ⇒ 图标与按压态始终最清晰）
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = TBStyle.groupGap
        stack.edgeInsets = NSEdgeInsets(top: TBStyle.paddingV, left: TBStyle.paddingH,
                                        bottom: TBStyle.paddingV, right: TBStyle.paddingH)
        stack.translatesAutoresizingMaskIntoConstraints = false
        foregroundHost.addSubview(stack)

        NSLayoutConstraint.activate([
            glassHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glassHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glassHost.topAnchor.constraint(equalTo: root.topAnchor),
            glassHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            foregroundHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            foregroundHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            foregroundHost.topAnchor.constraint(equalTo: root.topAnchor),
            foregroundHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            indicators.leadingAnchor.constraint(equalTo: foregroundHost.leadingAnchor),
            indicators.trailingAnchor.constraint(equalTo: foregroundHost.trailingAnchor),
            indicators.topAnchor.constraint(equalTo: foregroundHost.topAnchor),
            indicators.bottomAnchor.constraint(equalTo: foregroundHost.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: foregroundHost.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: foregroundHost.trailingAnchor),
            stack.topAnchor.constraint(equalTo: foregroundHost.topAnchor),
            stack.bottomAnchor.constraint(equalTo: foregroundHost.bottomAnchor),
        ])
        rootStack = stack

        // 1) 工具组：按 settings.toolbarOrder 自定义排序（纯标注工具 1-7）
        let order = (AppCoordinatorShared.coordinator?.settings ?? .defaultSettings).toolbarOrderSafe()
        for raw in order {
            if let tool = EditorSession.Tool(rawValue: raw), tool != .none {
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

        // 3) 线宽无极调节滑杆（下限 2.0pt 对齐原「细」档，连续调节至 10.0pt）
        strokeSlider = TBStrokeSlider(minWidth: 2.0, maxWidth: 10.0)
        strokeSlider.onChange = { [weak self] width in
            guard let self else { return }
            self.session?.strokeWidth = width
            self.handleHover(true, button: self.strokeSlider, text: String(format: "线宽 %.1f pt", width))
        }
        strokeSlider.onCommit = { width in
            Log.event(.editor, "toolbar.stroke", ["width": String(format: "%.1f", width)])
        }
        strokeSlider.onHover = { [weak self] inside in
            guard let self else { return }
            let tip = String(format: "线宽 %.1f pt", self.strokeSlider.value)
            self.handleHover(inside, button: self.strokeSlider, text: tip)
        }
        stack.addArrangedSubview(strokeSlider)

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

        // 5) 滚动截图 / 取字 / 贴图 / 画框 / 显隐（滚动截图置于取字前）
        let scrollButton = TBIconButton(icon: .scroll, fallback: "滚")
        scrollButton.tag = 206
        scrollButton.target = self
        scrollButton.action = #selector(actionTapped(_:))
        scrollButton.onHover = { [weak self] inside in self?.handleHover(inside, button: scrollButton, text: "滚动截图 \(Self.hotkeyTip("scroll"))") }
        stack.addArrangedSubview(scrollButton)

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

        let backdrop = TBIconButton(icon: .backdrop, fallback: "框")
        backdrop.tag = 207
        backdrop.usesSelfSelectedBackdrop = true
        backdrop.target = self
        backdrop.action = #selector(actionTapped(_:))
        backdrop.onHover = { [weak self] inside in
            let tip = Self.hotkeyTip("backdrop")
            self?.handleHover(inside, button: backdrop, text: tip.isEmpty ? "画框美化 B" : "画框美化 \(tip)")
        }
        backdropButton = backdrop
        stack.addArrangedSubview(backdrop)

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

    /// 布局完成后同步双层光学投影几何
    private func applyPanelShadowPaths() {
        contentView?.layoutSubtreeIfNeeded()
        outerShadowView?.refreshGeometry()
    }

    private func makeSeparator() -> NSView {
        // 明暗自适应发丝分隔线（0.5×18，两侧各 4pt，叠加栈间距 4 ⇒ 线到内容 8pt）
        let view = TBHairlineView()
        view.translatesAutoresizingMaskIntoConstraints = false
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
            Self.originBelow(selection: selection, visible: visible, panelSize: panelSize)
        })
    }

    /// 选区移动/缩放/长图滚轮缩放时平滑跟随定位（不重播入场动画，不闪烁）
    func reposition(below selection: CGRect) {
        guard isVisible else { return }
        applyPanelShadowPaths()
        plannedBarFrameGlobal = nil
        let margin = TBStyle.shadowMargin
        let panelSize = CGSize(width: frame.width - margin * 2,
                               height: frame.height - margin * 2)
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = Self.originBelow(selection: selection, visible: visible, panelSize: panelSize)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        setFrameOrigin(CGPoint(x: origin.x - margin, y: origin.y - margin))
        syncSmartRedactPill(animated: false)
        syncSmartBackdropPill(animated: false)
    }

    private static func originBelow(selection: CGRect, visible: CGRect, panelSize: CGSize) -> CGPoint {
        let clampedX = selection.intersection(visible)
        let anchorMidX = (!clampedX.isNull && clampedX.width > 1) ? clampedX.midX : selection.midX
        var origin = CGPoint(x: anchorMidX - panelSize.width / 2,
                             y: selection.minY - panelSize.height - 12)
        if origin.y < visible.minY + 8 {
            let above = selection.maxY + 12
            if above + panelSize.height <= visible.maxY - 8 {
                origin.y = above
            } else {
                origin.y = visible.minY + 16
            }
        }
        return origin
    }

    /// 工具栏玻璃本体的全局可视矩形（扣除四周 shadowMargin，供 OCR 浮层精准避让）
    var visibleBarFrameGlobal: CGRect {
        frame.insetBy(dx: TBStyle.shadowMargin, dy: TBStyle.shadowMargin)
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        if session?.toolbarVisible ?? true {
            syncSmartRedactPill(animated: false)
            syncSmartBackdropPill(animated: false)
        }
    }

    override func orderOut(_ sender: Any?) {
        tooltip?.hide()
        smartRedactPill?.hide(immediate: true)
        smartBackdropPill?.hide(immediate: true)
        plannedBarFrameGlobal = nil
        super.orderOut(sender)
    }

    /// 键盘快捷键（H）高频切换显隐：零延迟直切，不做位移弹跳（Emil Animation Standards）
    func setVisibleInstant(_ visible: Bool) {
        dismissEpoch += 1
        tooltip?.hide()
        if visible {
            alphaValue = 1
            if let layer = contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            orderFrontRegardless()
        } else {
            smartRedactPill?.hide(immediate: true)
            smartBackdropPill?.hide(immediate: true)
            orderOut(nil)
        }
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

    /// 共用定位/出场：panelOriginFor 返回「面板本体」原点（不含投影留白）
    private func place(panelOriginFor compute: (_ visible: CGRect, _ panelSize: CGSize) -> CGPoint) {
        dismissEpoch += 1
        let epoch = dismissEpoch
        contentView?.layoutSubtreeIfNeeded()
        applyPanelShadowPaths()
        let margin = TBStyle.shadowMargin
        // frame 含四周投影留白；定位算的是「面板本体」矩形
        let panelSize = CGSize(width: frame.width - margin * 2,
                               height: frame.height - margin * 2)
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = compute(visible, panelSize)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)

        let finalFrame = CGRect(origin: CGPoint(x: origin.x - margin, y: origin.y - margin),
                                size: frame.size)
        plannedBarFrameGlobal = finalFrame.insetBy(dx: margin, dy: margin)
        let reduce = DesignTokens.Motion.reduceMotion

        if usesNativeLiquidGlass {
            // 原生 Liquid Glass 窗体保持 alphaValue == 1 且直落终态坐标再上屏，
            // 避免 0→1 透明渐变或首帧滑移触发 WindowServer 离屏光栅切换导致闪烁跳变。
            alphaValue = 1
            if let layer = contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            setFrame(finalFrame, display: true)
            orderFrontRegardless()
            if epoch == dismissEpoch {
                plannedBarFrameGlobal = nil
            }
        } else {
            let startOrigin = CGPoint(x: finalFrame.minX, y: finalFrame.minY - (reduce ? 0 : DesignTokens.Motion.enterRise))
            setFrame(CGRect(origin: startOrigin, size: finalFrame.size), display: false)
            alphaValue = 0
            if !reduce, let layer = contentView?.layer {
                let b = contentView?.bounds ?? .zero
                var t = CATransform3DIdentity
                t = CATransform3DTranslate(t, b.midX, b.midY, 0)
                t = CATransform3DScale(t, DesignTokens.Motion.enterScale, DesignTokens.Motion.enterScale, 1)
                t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = t
                CATransaction.commit()
            }
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = DesignTokens.Motion.enterDuration
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                if !reduce { self.animator().setFrame(finalFrame, display: true) }
                self.animator().alphaValue = 1
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if epoch == self.dismissEpoch {
                        self.plannedBarFrameGlobal = nil
                    }
                }
            })
            if !reduce, let layer = contentView?.layer {
                CATransaction.begin()
                CATransaction.setAnimationDuration(DesignTokens.Motion.enterDuration)
                CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
        if isVisible && (session?.toolbarVisible ?? true) {
            syncSmartRedactPill(animated: true)
            syncSmartBackdropPill(animated: true)
        }
        scheduleButtonDump()
    }

    /// 复用入场（强缓出 + 居中缩放）
    func playEnter() {
        guard isVisible else { return }
        let finalFrame = frame
        let reduce = DesignTokens.Motion.reduceMotion
        setFrameOrigin(CGPoint(x: finalFrame.minX, y: finalFrame.minY - (reduce ? 0 : DesignTokens.Motion.enterRise)))
        alphaValue = 0
        if !reduce, let layer = contentView?.layer {
            let b = contentView?.bounds ?? .zero
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, b.midX, b.midY, 0)
            t = CATransform3DScale(t, DesignTokens.Motion.enterScale, DesignTokens.Motion.enterScale, 1)
            t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = t
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            if !reduce { self.animator().setFrame(finalFrame, display: true) }
            self.animator().alphaValue = 1
        })
        if !reduce, let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.enterDuration)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    /// motion.exit 退场：fade + 居中 scale→.97 + 下沉 4pt，0.14s strong ease-out（带 dismissEpoch 复用守卫）
    func dismiss() {
        tooltip?.hide()
        smartRedactPill?.hide(immediate: false)
        smartBackdropPill?.hide(immediate: false)
        plannedBarFrameGlobal = nil
        dismissEpoch += 1
        let epoch = dismissEpoch
        guard isVisible else {
            orderOut(nil)
            return
        }
        let reduce = DesignTokens.Motion.reduceMotion
        let animateScale = !reduce && !usesNativeLiquidGlass
        if animateScale, let layer = contentView?.layer {
            let b = contentView?.bounds ?? .zero
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, b.midX, b.midY, 0)
            t = CATransform3DScale(t, DesignTokens.Motion.exitScale, DesignTokens.Motion.exitScale, 1)
            t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.exitDuration)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
            layer.transform = t
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.exitDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.animator().alphaValue = 0
            if !reduce {
                var sinkFrame = frame
                sinkFrame.origin.y -= DesignTokens.Motion.exitSink
                self.animator().setFrame(sinkFrame, display: true)
            }
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard epoch == self.dismissEpoch else { return }
                self.orderOut(nil)
                self.alphaValue = 1
                if let layer = self.contentView?.layer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.transform = CATransform3DIdentity
                    CATransaction.commit()
                }
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

    func refreshSelectionState(animated: Bool = true) {
        guard let session else { return }
        let toolChanged = session.currentTool != lastSelectedTool
        let colorChanged = session.colorIndex != lastSelectedColor
        lastSelectedTool = session.currentTool
        lastSelectedColor = session.colorIndex

        for (tool, button) in toolButtons {
            let isSel = (tool == session.currentTool)
            button.setSelected(isSel)
            if animated && toolChanged && isSel {
                button.playSelectPop()
            }
        }
        for (i, button) in colorButtons.enumerated() {
            let isSel = (i == session.colorIndex)
            button.setSelected(isSel)
            if animated && colorChanged && isSel {
                button.playSelectPop()
            }
        }
        strokeSlider.value = session.strokeWidth
        undoButton.isEnabled = session.store.canUndo
        redoButton.isEnabled = session.store.canRedo
        undoButton.alphaValue = session.store.canUndo ? 1 : 0.35
        redoButton.alphaValue = session.store.canRedo ? 1 : 0.35

        // 更新滑动指示层（工具蓝胶囊 / 颜色选环，坐标转换到 indicators 自身空间）
        if let root = panelRoot, let indicators = indicatorView {
            root.layoutSubtreeIfNeeded()
            let toolFrame: CGRect? = toolButtons[session.currentTool].map { btn in
                btn.convert(btn.bounds, to: indicators).insetBy(dx: 2, dy: 2)
            }
            let colorCenter: CGPoint? = colorButtons.indices.contains(session.colorIndex)
                ? {
                    let btn = colorButtons[session.colorIndex]
                    let r = btn.convert(btn.bounds, to: indicators)
                    return CGPoint(x: r.midX, y: r.midY)
                }()
                : nil

            indicators.updateToolPill(to: toolFrame, animated: animated)
            indicators.updateColorRing(center: colorCenter, animated: animated)
        }
        backdropButton?.setSelected(backdropStyle.enabled)
        syncSmartRedactPill(animated: animated)
        syncSmartBackdropPill(animated: animated)
    }

    func setAutoRedactBusy(_ busy: Bool) {
        smartRedactPill?.setBusy(busy)
    }

    /// 由外部同步最新画框美化样式：更新主栏画框按钮高亮，并自动控制微调胶囊显隐与选中态刷新
    func updateBackdropStyle(_ style: BackdropStyle) {
        let wasEnabled = backdropStyle.enabled
        backdropStyle = style
        backdropButton?.setSelected(style.enabled)
        if isVisible && style.enabled && !wasEnabled {
            backdropButton?.playSelectPop()
        }
        smartBackdropPill?.update(style: style)
        syncSmartBackdropPill(animated: true)
    }

    /// 仅在工具栏可见且当前工具为「马赛克」时，在马赛克图标正上方 8pt 展示轻盈玻璃胶囊「✦ 智能打码 ⇧M」
    private func syncSmartRedactPill(animated: Bool) {
        guard isVisible,
              let session,
              session.toolbarVisible,
              session.currentTool == .mosaic,
              let mosaicBtn = toolButtons[.mosaic]
        else {
            smartRedactPill?.hide(immediate: !animated)
            return
        }
        let pill = smartRedactPill ?? {
            let p = SmartRedactPillPanel { [weak self] in
                self?.onAction(.autoRedact)
            }
            self.smartRedactPill = p
            return p
        }()
        pill.appearance = appearance
        let inWindow = mosaicBtn.convert(mosaicBtn.bounds, to: nil)
        let btnGlobal = convertToScreen(inWindow)
        let barGlobal = plannedBarFrameGlobal ?? visibleBarFrameGlobal
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        pill.show(anchoredAbove: btnGlobal, barRect: barGlobal, visible: visible, animated: animated)
    }

    /// 仅在 `backdropStyle.enabled == true` 且工具栏可见时，在主工具栏上方（避让 SmartRedactPillPanel）展开微调胶囊
    private func syncSmartBackdropPill(animated: Bool) {
        guard isVisible,
              backdropStyle.enabled,
              session?.toolbarVisible ?? true
        else {
            smartBackdropPill?.hide(immediate: !animated)
            return
        }
        let pill = smartBackdropPill ?? {
            let p = SmartBackdropPillPanel(
                style: backdropStyle,
                onStyleChange: { [weak self] updated in
                    guard let self else { return }
                    self.backdropStyle = updated
                    self.backdropStyle.savePreference()
                    self.backdropButton?.setSelected(updated.enabled)
                    self.onBackdropStyleChange?(updated)
                },
                onHoverTip: { [weak self] view, text in
                    self?.handleBackdropPillHover(view: view, text: text)
                }
            )
            self.smartBackdropPill = p
            return p
        }()
        pill.appearance = appearance
        pill.update(style: backdropStyle)
        let barGlobal = plannedBarFrameGlobal ?? visibleBarFrameGlobal
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let avoidRect: CGRect? = (smartRedactPill?.isShowing == true) ? smartRedactPill?.visiblePillFrame : nil
        pill.show(anchoredToBar: barGlobal, avoiding: avoidRect, visible: visible, animated: animated)
    }

    /// 工具栏显隐态图标（隐藏时 eye.slash）
    /// 工具栏隐藏时同步收起悬停提示（病例 2026-11-15：按 H 隐藏工具栏后
    /// tooltip 永久滞留——tracking 区随窗 orderOut 消失，mouseExited 永不触发；
    /// tooltip 是 screenSaver 层独立 NSPanel，宿主窗没了它还浮着）
    func hideTooltip() {
        tooltip?.hide()
        smartRedactPill?.hide(immediate: true)
        smartBackdropPill?.hide(immediate: true)
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
            screenRect.origin.y = frame.maxY - TBStyle.shadowMargin
            screenRect.size.height = 0
            tooltip?.show(text: text, above: screenRect, after: 0.16)
        } else {
            tooltip?.hide()
        }
    }

    private func handleBackdropPillHover(view: NSView?, text: String?) {
        guard let view, let text, let pillWindow = view.window else {
            tooltip?.hide()
            return
        }
        if tooltip == nil { tooltip = ToolbarTooltipWindow() }
        let frameInWindow = view.convert(view.bounds, to: nil)
        var screenRect = pillWindow.convertToScreen(frameInWindow)
        screenRect.origin.y = pillWindow.frame.maxY - SmartBackdropPillPanel.shadowMargin
        screenRect.size.height = 0
        tooltip?.show(text: text, above: screenRect, after: 0.16)
    }

    // MARK: - 事件

    @objc private func toolTapped(_ sender: NSButton) {
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
        onToolChange()
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
        case 206: onAction(.scroll)
        case 207: onAction(.toggleBackdrop)
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
    /// 选中态是否由自身 backdropLayer 承载底色（不进共享滑动层的独立开关按钮使用）
    var usesSelfSelectedBackdrop = false
    /// 内缩呼吸感背景胶囊（相对 30×30 命中区内缩 2×2.5pt，避免选中/悬停色块贴边「拉高」）
    private let backdropLayer = CALayer()

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
        widthConstraint = widthAnchor.constraint(equalToConstant: TBStyle.buttonSide)
        widthConstraint.isActive = true
        heightAnchor.constraint(equalToConstant: TBStyle.buttonSide).isActive = true
        contentTintColor = TBStyle.iconIdle
        backdropLayer.cornerRadius = TBStyle.innerPillRadius
        backdropLayer.borderWidth = 0
        layer?.insertSublayer(backdropLayer, at: 0)
    }

    override var wantsUpdateLayer: Bool { true }
    /// macOS 26 上 NSButton(regularSquare) 即使 isBordered=false 仍会报告 top:6.5/bottom:5.5 的
    /// alignmentRectInsets，导致 heightAnchor=30 实际被撑高成 42pt 竖长条；归零后严格 30×30 正方。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds.insetBy(dx: 2, dy: 2)
        CATransaction.commit()
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

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        TactilePress.animate(view: self, pressed: true)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    /// 换图标（眼睛显隐态用，保持与 SF Symbols 光学字号/Hierarchical 质感一致）
    func setSymbol(_ symbol: String, fallback: String) {
        self.image = TBIcon.symbolImage(
            named: symbol,
            pointSize: TBStyle.iconPointSize - 0.5,
            weight: TBStyle.iconWeight,
            hierarchical: true
        )
    }

    func setSelected(_ selected: Bool) {
        selectedState = selected
        applyStyle()
    }

    /// 切换选中时的轻巧微弹（Apple Pencil Markup 手感，克制且灵动）
    func playSelectPop() {
        guard let layer else { return }
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform")
        var s1 = CATransform3DIdentity
        s1 = CATransform3DTranslate(s1, b.midX, b.midY, 0)
        s1 = CATransform3DScale(s1, 1.12, 1.12, 1)
        s1 = CATransform3DTranslate(s1, -b.midX, -b.midY, 0)
        pop.values = [
            NSValue(caTransform3D: CATransform3DIdentity),
            NSValue(caTransform3D: s1),
            NSValue(caTransform3D: CATransform3DIdentity),
        ]
        pop.keyTimes = [0, 0.42, 1.0]
        pop.duration = 0.19
        pop.timingFunction = DesignTokens.Motion.easeOutStrong
        layer.add(pop, forKey: "selectPop")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    /// 选中背景统一交由共享滑动胶囊 indicatorView 承载（实现顺滑弹簧滑移）；
    /// 本按钮仅负责图标染色（选中=accent / 悬停=label1 / 默认=iconIdle）与未选中态悬停底。
    func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if selectedState {
                if usesSelfSelectedBackdrop {
                    let isDark = effectiveAppearance.isDark
                    backdropLayer.backgroundColor = DesignTokens.accentSoft.cgColor
                    backdropLayer.borderWidth = 0.5
                    backdropLayer.borderColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.30 : 0.22).cgColor
                } else {
                    backdropLayer.backgroundColor = NSColor.clear.cgColor
                    backdropLayer.borderWidth = 0
                    backdropLayer.borderColor = nil
                }
                contentTintColor = DesignTokens.accent
            } else if isHot {
                backdropLayer.backgroundColor = DesignTokens.fillHover.cgColor
                backdropLayer.borderWidth = 0
                backdropLayer.borderColor = nil
                contentTintColor = DesignTokens.label1
            } else {
                backdropLayer.backgroundColor = NSColor.clear.cgColor
                backdropLayer.borderWidth = 0
                backdropLayer.borderColor = nil
                contentTintColor = TBStyle.iconIdle
            }
            CATransaction.commit()
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
        for (ring, isOuter) in [(innerRing, false), (outerRing, true)] {
            ring.translatesAutoresizingMaskIntoConstraints = false
            ring.wantsLayer = true
            ring.layer?.borderWidth = isOuter ? 1.0 : 1.5
            ring.layer?.borderColor = (isOuter
                ? DesignTokens.hudForeground(0.32)
                : DesignTokens.hudForeground(0.86)).cgColor
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

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

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
        guard !DesignTokens.Motion.reduceMotion, let layer = dot.layer else { return }
        let b = dot.bounds
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, b.midX, b.midY, 0)
        t = CATransform3DScale(t, 1.14, 1.14, 1)
        t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        layer.transform = t
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        dot.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true, scale: 0.92)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            innerRing.layer?.borderColor = DesignTokens.hudForeground(0.86).cgColor
            outerRing.layer?.borderColor = DesignTokens.hudForeground(0.32).cgColor
        }
    }

    func setSelected(_ isOn: Bool) {
        selected = isOn
        // 选中环已交由共享滑动 colorRingLayer 承载，避免双环重叠
        innerRing.isHidden = true
        outerRing.isHidden = true
    }

    func playSelectPop() {
        guard let layer = dot.layer else { return }
        let b = dot.bounds
        guard b.width > 0, b.height > 0 else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform")
        var s1 = CATransform3DIdentity
        s1 = CATransform3DTranslate(s1, b.midX, b.midY, 0)
        s1 = CATransform3DScale(s1, 1.24, 1.24, 1)
        s1 = CATransform3DTranslate(s1, -b.midX, -b.midY, 0)
        pop.values = [
            NSValue(caTransform3D: CATransform3DIdentity),
            NSValue(caTransform3D: s1),
            NSValue(caTransform3D: CATransform3DIdentity),
        ]
        pop.keyTimes = [0, 0.42, 1.0]
        pop.duration = 0.20
        pop.timingFunction = DesignTokens.Motion.easeOutStrong
        layer.add(pop, forKey: "dotPop")
    }
}

// MARK: - 明暗自适应组间发丝分隔线

@MainActor
private final class TBHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    private func refreshColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignTokens.hair.cgColor
        }
    }
}

// MARK: - 连续线宽无极滑杆（对齐 macOS Tahoe 胶囊滑杆：2.0pt 起步对齐原「细」档，连续调节至 10.0pt）

@MainActor
private final class TBStrokeSlider: NSView {
    var onChange: ((CGFloat) -> Void)?
    var onCommit: ((CGFloat) -> Void)?
    var onHover: ((Bool) -> Void)?

    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private var currentValue: CGFloat

    private let minDotLayer = CALayer()
    private let maxDotLayer = CALayer()
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knobLayer = CALayer()
    private let knobRimLayer = CALayer()

    private var trackingArea: NSTrackingArea?
    private var isHot = false
    private var isDragging = false

    // 随工具栏紧凑/常规/大号等比例缩放，视觉对齐 macOS 原生 Capsule Slider
    private let sliderWidth: CGFloat
    private let trackHeight: CGFloat
    private let knobWidth: CGFloat
    private let knobHeight: CGFloat
    private let minDotDiameter: CGFloat
    private let maxDotDiameter: CGFloat
    private let sidePad: CGFloat = 3
    private let dotGap: CGFloat = 5.5

    var value: CGFloat {
        get { currentValue }
        set {
            let clamped = Self.clamp(newValue, min: minWidth, max: maxWidth)
            guard abs(clamped - currentValue) > 0.01 else { return }
            currentValue = clamped
            layoutSliderLayers(animated: false)
        }
    }

    init(minWidth: CGFloat = 2.0, maxWidth: CGFloat = 10.0) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.currentValue = minWidth

        if TBStyle.buttonSide <= 32 {
            self.sliderWidth = 98
            self.trackHeight = 5.0
            self.knobWidth = 19.0
            self.knobHeight = 12.0
            self.minDotDiameter = 4.5
            self.maxDotDiameter = 9.0
        } else if TBStyle.buttonSide <= 38 {
            self.sliderWidth = 112
            self.trackHeight = 5.5
            self.knobWidth = 22.0
            self.knobHeight = 13.5
            self.minDotDiameter = 5.0
            self.maxDotDiameter = 10.5
        } else {
            self.sliderWidth = 126
            self.trackHeight = 6.0
            self.knobWidth = 25.0
            self.knobHeight = 15.5
            self.minDotDiameter = 5.5
            self.maxDotDiameter = 11.5
        }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        widthAnchor.constraint(equalToConstant: sliderWidth).isActive = true
        heightAnchor.constraint(equalToConstant: TBStyle.buttonSide).isActive = true

        let noAnim: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "cornerRadius": NSNull(),
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
        ]
        minDotLayer.actions = noAnim
        maxDotLayer.actions = noAnim
        trackLayer.actions = noAnim
        // fillLayer / knobLayer / knobRimLayer 由显式 CATransaction.setDisableActions 控制，保留丝滑过渡

        minDotLayer.cornerRadius = minDotDiameter / 2
        maxDotLayer.cornerRadius = maxDotDiameter / 2

        trackLayer.cornerRadius = trackHeight / 2
        trackLayer.cornerCurve = .continuous
        trackLayer.masksToBounds = true
        trackLayer.borderWidth = 0.5

        fillLayer.cornerRadius = trackHeight / 2
        fillLayer.cornerCurve = .continuous

        knobLayer.bounds = CGRect(x: 0, y: 0, width: knobWidth, height: knobHeight)
        knobLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        knobLayer.cornerRadius = knobHeight / 2
        knobLayer.cornerCurve = .continuous
        knobLayer.masksToBounds = false
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOffset = CGSize(width: 0, height: -1.2)

        knobRimLayer.frame = knobLayer.bounds.insetBy(dx: 0.5, dy: 0.5)
        knobRimLayer.cornerRadius = (knobHeight - 1) / 2
        knobRimLayer.cornerCurve = .continuous
        knobRimLayer.borderWidth = 0.75
        knobLayer.addSublayer(knobRimLayer)

        layer?.addSublayer(minDotLayer)
        layer?.addSublayer(maxDotLayer)
        layer?.addSublayer(trackLayer)
        trackLayer.addSublayer(fillLayer)
        layer?.addSublayer(knobLayer)

        refreshAppearance()
        updateKnobState(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        layoutSliderLayers(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
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
        updateKnobState(animated: true)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        if !isDragging {
            updateKnobState(animated: true)
            onHover?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let (trackLeft, trackRight) = trackSpan()
        // 点击左右极点圆点：步进 ±1.0pt 并柔和滑移
        if local.x < trackLeft - 2 {
            stepBy(-1.0)
            return
        }
        if local.x > trackRight + 2 {
            stepBy(1.0)
            return
        }
        isDragging = true
        updateKnobState(animated: true)
        updateValue(from: local.x, animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let local = convert(event.locationInWindow, from: nil)
        updateValue(from: local.x, animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let local = convert(event.locationInWindow, from: nil)
        updateValue(from: local.x, animated: false)
        updateKnobState(animated: true)
        onCommit?(currentValue)
        if !isHot {
            onHover?(false)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard abs(delta) > 0.05 else { return }
        let step = delta * 0.08
        let next = Self.clamp(currentValue + step, min: minWidth, max: maxWidth)
        if abs(next - currentValue) >= 0.05 {
            currentValue = next
            layoutSliderLayers(animated: false)
            onChange?(currentValue)
            onCommit?(currentValue)
        }
    }

    private func stepBy(_ delta: CGFloat) {
        let next = Self.clamp(currentValue + delta, min: minWidth, max: maxWidth)
        guard abs(next - currentValue) >= 0.05 else { return }
        currentValue = next
        layoutSliderLayers(animated: true)
        onChange?(currentValue)
        onCommit?(currentValue)
    }

    private func trackSpan() -> (left: CGFloat, right: CGFloat) {
        let left = sidePad + minDotDiameter + dotGap
        let right = max(left + knobWidth, bounds.width - sidePad - maxDotDiameter - dotGap)
        return (left, right)
    }

    private func updateValue(from localX: CGFloat, animated: Bool) {
        let (trackLeft, trackRight) = trackSpan()
        let travel = max(1, (trackRight - trackLeft) - knobWidth)
        let centerStart = trackLeft + knobWidth / 2
        let t = min(1, max(0, (localX - centerStart) / travel))
        let raw = minWidth + t * (maxWidth - minWidth)
        let next = Self.clamp(raw, min: minWidth, max: maxWidth)
        if abs(next - currentValue) >= 0.05 || isDragging {
            currentValue = next
            layoutSliderLayers(animated: animated)
            onChange?(currentValue)
        }
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            minDotLayer.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
            maxDotLayer.backgroundColor = NSColor.black.withAlphaComponent(0.50).cgColor
            trackLayer.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
            trackLayer.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
            fillLayer.backgroundColor = DesignTokens.accent.cgColor
            CATransaction.commit()
        }
        updateKnobState(animated: false)
    }

    private func updateKnobState(animated: Bool) {
        let scale: CGFloat = isDragging ? 1.12 : (isHot ? 1.05 : 1.0)
        // 静止时为高洁瓷白胶囊，拖拽时呈现 Tahoe 通透玻璃感（微露下方蓝灰分界线）
        let bg = isDragging
            ? NSColor.white.withAlphaComponent(0.80).cgColor
            : NSColor.white.cgColor
        let border = isDragging
            ? NSColor.white.withAlphaComponent(0.95).cgColor
            : NSColor.black.withAlphaComponent(0.10).cgColor
        let borderW: CGFloat = isDragging ? 0.9 : 0.5
        let rim = isDragging
            ? NSColor.white.withAlphaComponent(0.65).cgColor
            : NSColor.white.withAlphaComponent(0.85).cgColor
        let shadowOpacity: Float = isDragging ? 0.22 : (isHot ? 0.20 : 0.16)
        let shadowRadius: CGFloat = isDragging ? 5.0 : (isHot ? 3.8 : 3.0)

        CATransaction.begin()
        if animated {
            CATransaction.setDisableActions(false)
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        } else {
            CATransaction.setDisableActions(true)
        }
        knobLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        knobLayer.backgroundColor = bg
        knobLayer.borderColor = border
        knobLayer.borderWidth = borderW
        knobLayer.shadowOpacity = shadowOpacity
        knobLayer.shadowRadius = shadowRadius
        knobRimLayer.borderColor = rim
        CATransaction.commit()
    }

    private func layoutSliderLayers(animated: Bool) {
        let (trackLeft, trackRight) = trackSpan()
        let trackW = trackRight - trackLeft
        guard trackW > knobWidth else { return }

        let travel = trackW - knobWidth
        let t = max(0, min(1, (currentValue - minWidth) / max(0.01, maxWidth - minWidth)))
        let midY = bounds.midY
        let centerX = trackLeft + knobWidth / 2 + travel * t
        let fillW = t > 0.001 ? max(trackHeight, centerX - trackLeft) : 0

        CATransaction.begin()
        if animated {
            CATransaction.setDisableActions(false)
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        } else {
            CATransaction.setDisableActions(true)
        }
        minDotLayer.frame = CGRect(
            x: sidePad,
            y: midY - minDotDiameter / 2,
            width: minDotDiameter,
            height: minDotDiameter
        )
        maxDotLayer.frame = CGRect(
            x: bounds.width - sidePad - maxDotDiameter,
            y: midY - maxDotDiameter / 2,
            width: maxDotDiameter,
            height: maxDotDiameter
        )
        trackLayer.frame = CGRect(
            x: trackLeft,
            y: midY - trackHeight / 2,
            width: trackW,
            height: trackHeight
        )
        fillLayer.frame = CGRect(x: 0, y: 0, width: fillW, height: trackHeight)
        knobLayer.position = CGPoint(x: centerX, y: midY)
        CATransaction.commit()
    }

    private static func clamp(_ v: CGFloat, min minVal: CGFloat, max maxVal: CGFloat) -> CGFloat {
        let clamped = Swift.min(maxVal, Swift.max(minVal, v))
        return (clamped * 10).rounded() / 10
    }
}

// MARK: - 共享弹簧滑动选中指示层（工具 / 颜色两组丝滑物理过渡）

@MainActor
private final class TBSelectionIndicatorView: NSView {
    private let toolPill = CALayer()
    private let colorRing = CALayer()

    private var toolPillVisible = false
    private var colorRingVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        toolPill.cornerRadius = TBStyle.innerPillRadius
        toolPill.borderWidth = 0.5
        toolPill.opacity = 0
        layer?.addSublayer(toolPill)

        colorRing.bounds = CGRect(x: 0, y: 0, width: 19, height: 19)
        colorRing.cornerRadius = 9.5
        colorRing.borderWidth = 1.5
        colorRing.backgroundColor = NSColor.clear.cgColor
        colorRing.opacity = 0
        layer?.addSublayer(colorRing)

        refreshAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    private func refreshAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            toolPill.backgroundColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.22 : 0.20).cgColor
            toolPill.borderColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.30 : 0.34).cgColor
            colorRing.borderColor = DesignTokens.hudForeground(0.86).cgColor
            CATransaction.commit()
        }
    }

    private func makeSpring(keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let s = CASpringAnimation(keyPath: keyPath)
        s.fromValue = from
        s.toValue = to
        s.stiffness = 420
        s.damping = 28
        s.mass = 0.85
        s.duration = s.settlingDuration
        return s
    }

    func updateToolPill(to rect: CGRect?, animated: Bool) {
        let shouldAnimate = animated
        guard let rect else {
            guard toolPillVisible else { return }
            toolPillVisible = false
            if shouldAnimate {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.12)
                CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
                toolPill.opacity = 0
                toolPill.transform = CATransform3DMakeScale(0.86, 0.86, 1)
                CATransaction.commit()
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                toolPill.opacity = 0
                toolPill.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            return
        }

        let targetPos = CGPoint(x: rect.midX, y: rect.midY)
        let targetBounds = CGRect(origin: .zero, size: rect.size)

        if !toolPillVisible {
            toolPillVisible = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            toolPill.bounds = targetBounds
            toolPill.position = targetPos
            toolPill.transform = shouldAnimate ? CATransform3DMakeScale(0.82, 0.82, 1) : CATransform3DIdentity
            toolPill.opacity = shouldAnimate ? 0 : 1
            CATransaction.commit()
            if shouldAnimate {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.16)
                CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
                toolPill.opacity = 1
                toolPill.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        } else {
            let fromPos = toolPill.presentation()?.position ?? toolPill.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            toolPill.bounds = targetBounds
            toolPill.position = targetPos
            toolPill.opacity = 1
            toolPill.transform = CATransform3DIdentity
            CATransaction.commit()
            if shouldAnimate && hypot(targetPos.x - fromPos.x, targetPos.y - fromPos.y) > 0.5 {
                let anim = makeSpring(
                    keyPath: "position",
                    from: NSValue(point: fromPos),
                    to: NSValue(point: targetPos)
                )
                toolPill.add(anim, forKey: "glidePosition")
            }
        }
    }

    func updateColorRing(center: CGPoint?, animated: Bool) {
        let shouldAnimate = animated
        guard let center else {
            colorRingVisible = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            colorRing.opacity = 0
            CATransaction.commit()
            return
        }
        let fromPos = colorRing.presentation()?.position ?? colorRing.position
        let wasVisible = colorRingVisible
        colorRingVisible = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorRing.position = center
        colorRing.opacity = 1
        CATransaction.commit()
        if wasVisible && shouldAnimate && hypot(center.x - fromPos.x, center.y - fromPos.y) > 0.5 {
            let anim = makeSpring(
                keyPath: "position",
                from: NSValue(point: fromPos),
                to: NSValue(point: center)
            )
            colorRing.add(anim, forKey: "colorGlide")
        }
    }
}

// MARK: - 主按钮「复制」（克制透明强调蓝内缩胶囊 + accent 图标：主次分明且与玻璃融合呼吸）

@MainActor
private final class TBPrimaryButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHot = false
    private var isPressed = false
    private let backdropLayer = CALayer()

    init(icon: TBIcon.Kind) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""                          // 去字：纯图标（信息走 tooltip）
        imagePosition = .imageOnly
        contentTintColor = DesignTokens.accent
        self.image = TBIcon.image(icon, pointSize: TBStyle.iconPointSize)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: TBStyle.buttonSide).isActive = true
        heightAnchor.constraint(equalToConstant: TBStyle.buttonSide).isActive = true

        backdropLayer.cornerRadius = TBStyle.innerPillRadius
        backdropLayer.borderWidth = 0.5
        layer?.insertSublayer(backdropLayer, at: 0)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds.insetBy(dx: 2, dy: 2)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            let fillAlpha: CGFloat
            if isPressed {
                fillAlpha = isDark ? 0.34 : 0.24
            } else if isHot {
                fillAlpha = isDark ? 0.28 : 0.20
            } else {
                fillAlpha = isDark ? 0.20 : 0.13
            }
            let strokeAlpha: CGFloat = isDark ? 0.32 : 0.24
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropLayer.backgroundColor = DesignTokens.accent.withAlphaComponent(fillAlpha).cgColor
            backdropLayer.borderColor = DesignTokens.accent.withAlphaComponent(strokeAlpha).cgColor
            contentTintColor = DesignTokens.accent
            CATransaction.commit()
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
        onHover?(true)
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        onHover?(false)
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
}

// MARK: - 悬停提示浮层（Emil Craft：首次 origin-aware 轻浮 + 相邻按钮 350ms 内零延迟瞬切 + 快捷键区分排版）

@MainActor
private final class ToolbarTooltipWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var work: DispatchWorkItem?
    private var hideEpoch = 0
    /// 连续悬停热窗口（350ms 内滑过相邻按钮直接零延迟瞬切，不再反复等待淡入）
    private var lastVisibleTime: CFAbsoluteTime = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6.5
        bg.layer?.backgroundColor = NSColor(srgbRed: 0.094, green: 0.094, blue: 0.110, alpha: 0.90).cgColor
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        bg.layer?.shadowColor = NSColor.black.withAlphaComponent(0.26).cgColor
        bg.layer?.shadowOpacity = 1
        bg.layer?.shadowRadius = 8
        bg.layer?.shadowOffset = CGSize(width: 0, height: -3)

        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        contentView = bg
    }

    private static func formattedTip(_ raw: String) -> NSAttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // 把尾部快捷键（最后一个空格后的 token）以弱化等宽字重呈现，主文案与热键一目了然
        if let spaceIdx = trimmed.lastIndex(of: " "), spaceIdx > trimmed.startIndex {
            let main = String(trimmed[..<spaceIdx])
            let key = String(trimmed[trimmed.index(after: spaceIdx)...])
            let result = NSMutableAttributedString(string: main, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ])
            result.append(NSAttributedString(string: "  \(key)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.54),
            ]))
            return result
        }
        return NSAttributedString(string: trimmed, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ])
    }

    func show(text: String, above rect: CGRect, after delay: TimeInterval) {
        work?.cancel()
        hideEpoch += 1
        let now = CFAbsoluteTimeGetCurrent()
        let isWarm = isVisible || (now - lastVisibleTime) < 0.35

        let present: () -> Void = { [weak self] in
            guard let self else { return }
            self.label.attributedStringValue = Self.formattedTip(text)
            self.contentView?.layoutSubtreeIfNeeded()
            let textW = ceil(self.label.attributedStringValue.size().width)
            let w = textW + 18
            let h: CGFloat = 23
            var x = rect.midX - w / 2
            let y = rect.maxY + 8
            if let screenFrame = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
                let visible = screenFrame.visibleFrame
                x = max(visible.minX + 6, min(x, visible.maxX - w - 6))
            }
            let finalFrame = NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
            self.contentView?.layer?.shadowPath = CGPath(
                roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                cornerWidth: 6.5, cornerHeight: 6.5, transform: nil
            )
            self.lastVisibleTime = CFAbsoluteTimeGetCurrent()
            if isWarm || DesignTokens.Motion.reduceMotion {
                // 相邻按钮切换：零延迟、零重播淡入，顺滑瞬切
                self.setFrame(finalFrame, display: true)
                self.alphaValue = 1
                self.orderFrontRegardless()
            } else {
                // 首次弹出：从按钮上方 3pt + scale(0.96) 向上轻浮展开（origin-aware）
                self.setFrame(NSRect(x: finalFrame.minX, y: finalFrame.minY - 3, width: w, height: h), display: true)
                self.alphaValue = 0
                if let layer = self.contentView?.layer {
                    var t = CATransform3DIdentity
                    t = CATransform3DTranslate(t, w / 2, 0, 0)
                    t = CATransform3DScale(t, 0.96, 0.96, 1)
                    t = CATransform3DTranslate(t, -w / 2, 0, 0)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.transform = t
                    CATransaction.commit()
                }
                self.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                    self.animator().alphaValue = 1
                    self.animator().setFrame(finalFrame, display: true)
                }
                if let layer = self.contentView?.layer {
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.14)
                    CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
                    layer.transform = CATransform3DIdentity
                    CATransaction.commit()
                }
            }
        }

        if isWarm {
            present()
        } else {
            let item = DispatchWorkItem(block: present)
            self.work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func hide() {
        work?.cancel()
        hideEpoch += 1
        let epoch = hideEpoch
        guard isVisible else { return }
        lastVisibleTime = CFAbsoluteTimeGetCurrent()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.11
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, epoch == self.hideEpoch else { return }
            self.orderOut(nil)
            self.alphaValue = 1
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

    @MainActor
    var tipText: String {
        if self == .none { return "移动（无工具）" }
        if let num = EditorKeyRouter.shortcutNumber(for: self) {
            return "\(label) \(num)"
        }
        return label
    }
}

// MARK: - 马赛克上下文「✦ 智能打码」悬浮玻璃胶囊（仅选中马赛克时轻浮出现，不占主栏空间）

@MainActor
private final class SmartRedactPillPanel: NSPanel {
    private static let pillHeight: CGFloat = 28
    private static let shadowMargin: CGFloat = 20
    private static let gapAboveBar: CGFloat = 8

    private let onTap: () -> Void
    private let pillButton: SmartRedactPillButton
    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let outerShadowView: OuterShadowView
    private var hideToken = 0
    private var isShown = false

    var isShowing: Bool { isShown }
    var visiblePillFrame: CGRect { frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        self.glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: 10,
            tintAlpha: 0.08
        )
        self.pillButton = SmartRedactPillButton()
        self.outerShadowView = OuterShadowView(spec: .pill, margin: Self.shadowMargin, cornerRadius: 10)

        let initW: CGFloat = 132
        let m = Self.shadowMargin
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: initW + m * 2, height: Self.pillHeight + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        appearance = NSAppearance(named: .aqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: initW + m * 2, height: Self.pillHeight + m * 2))
        root.wantsLayer = true

        outerShadowView.frame = root.bounds
        outerShadowView.autoresizingMask = [.width, .height]
        root.addSubview(outerShadowView)

        pillButton.target = self
        pillButton.action = #selector(handleTap)
        pillButton.appearance = NSAppearance(named: .aqua)
        root.addSubview(glassSurface.hostView)
        root.addSubview(pillButton)
        contentView = root
    }

    @objc private func handleTap() {
        onTap()
    }

    func setBusy(_ busy: Bool) {
        pillButton.setBusy(busy)
        layoutPillContents()
    }

    func show(anchoredAbove buttonRect: CGRect, barRect: CGRect, visible: CGRect, animated: Bool) {
        hideToken += 1
        let pillW = pillButton.preferredWidth()
        let pillH = Self.pillHeight
        let m = Self.shadowMargin

        var x = buttonRect.midX - pillW / 2
        x = max(visible.minX + 8, min(x, visible.maxX - pillW - 8))
        var y = barRect.maxY + Self.gapAboveBar
        if y + pillH > visible.maxY - 8 {
            y = barRect.minY - Self.gapAboveBar - pillH
        }
        let targetFrame = CGRect(
            x: (x - m).rounded(),
            y: (y - m).rounded(),
            width: pillW + m * 2,
            height: pillH + m * 2
        )

        let wasShown = isShown
        isShown = true
        setFrame(targetFrame, display: false)
        layoutPillContents()

        if !wasShown {
            let reduce = DesignTokens.Motion.reduceMotion
            if animated && !reduce {
                setFrameOrigin(CGPoint(x: targetFrame.minX, y: targetFrame.minY - 5))
            }
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animated ? 0.16 : 0.01
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                if animated && !reduce {
                    self.animator().setFrame(targetFrame, display: true)
                }
                self.animator().alphaValue = 1
            }
        } else {
            orderFrontRegardless()
            alphaValue = 1
        }
    }

    func hide(immediate: Bool) {
        guard isShown || isVisible else { return }
        isShown = false
        hideToken += 1
        let token = hideToken
        if immediate || DesignTokens.Motion.reduceMotion {
            orderOut(nil)
            alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.11
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token, !self.isShown else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
    }

    private func layoutPillContents() {
        let m = Self.shadowMargin
        let pillRect = NSRect(
            x: m, y: m,
            width: max(80, frame.width - m * 2),
            height: Self.pillHeight
        )
        glassSurface.hostView.frame = pillRect
        pillButton.frame = pillRect
        outerShadowView.frame = contentView?.bounds ?? .zero
        outerShadowView.refreshGeometry()
    }
}

@MainActor
private final class SmartRedactPillButton: NSButton {
    private var isHot = false
    private var isPressed = false
    private var isBusy = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = TBIcon.symbolImage(named: "sparkles", pointSize: 11.5, weight: .semibold, hierarchical: true)
        wantsLayer = true
        layer?.cornerRadius = 14
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SmartRedactPillButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        isEnabled = !busy
        applyStyle()
    }

    func preferredWidth() -> CGFloat {
        isBusy ? 92 : 122
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
        addCursorRect(bounds, cursor: isBusy ? .arrow : .pointingHand)
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
        guard !isBusy else { return }
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
            if isPressed {
                layer?.backgroundColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.28 : 0.18).cgColor
            } else if isHot && !isBusy {
                layer?.backgroundColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.18 : 0.11).cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
            contentTintColor = isBusy ? DesignTokens.label3 : DesignTokens.accent

            let text = NSMutableAttributedString(
                string: isBusy ? " 识别中…" : " 智能打码",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: isBusy ? DesignTokens.label2 : DesignTokens.label1,
                ]
            )
            if !isBusy {
                text.append(NSAttributedString(string: "  ⇧M", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: DesignTokens.label3,
                ]))
            }
            attributedTitle = text
        }
    }
}

// MARK: - 画框美化上下文 Liquid Glass 微调胶囊（色板圆点 / 边距 / 比例 / 自动均衡留白）

@MainActor
private final class BackdropPillOuterView: NSView {
    weak var pillRootView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pill = pillRootView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return pill.frame.contains(local) ? super.hitTest(point) : nil
    }
}

@MainActor
private final class SmartBackdropPillPanel: NSPanel {
    static let shadowMargin: CGFloat = 20
    private static let pillHeight: CGFloat = 34
    private static let gapAboveBar: CGFloat = 8
    private static let stackGap: CGFloat = 6

    private var currentStyle: BackdropStyle
    private let onStyleChange: (BackdropStyle) -> Void
    private let onHoverTip: (NSView?, String?) -> Void

    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let pillRoot = NSView()
    private let contentStack = NSStackView()
    private let outerShadowView: OuterShadowView

    private var swatchButtons: [BackdropStyle.Preset: BackdropSwatchButton] = [:]
    private var paddingButtons: [BackdropStyle.Padding: BackdropOptionPillButton] = [:]
    private var aspectButtons: [BackdropStyle.AspectRatio: BackdropOptionPillButton] = [:]
    private let balanceButton: BackdropOptionPillButton

    private var hideToken = 0
    private var isShown = false

    init(
        style: BackdropStyle,
        onStyleChange: @escaping (BackdropStyle) -> Void,
        onHoverTip: @escaping (NSView?, String?) -> Void
    ) {
        self.currentStyle = style
        self.onStyleChange = onStyleChange
        self.onHoverTip = onHoverTip
        self.glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: 11,
            tintAlpha: 0.08
        )
        self.balanceButton = BackdropOptionPillButton(
            title: "均衡",
            symbolName: "rectangle.inset.filled",
            monospacedDigits: false
        )
        self.outerShadowView = OuterShadowView(spec: .pill, margin: Self.shadowMargin, cornerRadius: 11)

        let initW: CGFloat = 460
        let m = Self.shadowMargin
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: initW + m * 2, height: Self.pillHeight + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        appearance = NSAppearance(named: .aqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        buildUI()
        refreshSelections()
    }

    private func buildUI() {
        let m = Self.shadowMargin
        let outer = BackdropPillOuterView()
        outer.wantsLayer = true

        outerShadowView.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(outerShadowView)
        NSLayoutConstraint.activate([
            outerShadowView.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            outerShadowView.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            outerShadowView.topAnchor.constraint(equalTo: outer.topAnchor),
            outerShadowView.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
        ])

        pillRoot.wantsLayer = true
        pillRoot.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(pillRoot)
        outer.pillRootView = pillRoot

        NSLayoutConstraint.activate([
            pillRoot.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: m),
            pillRoot.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -m),
            pillRoot.topAnchor.constraint(equalTo: outer.topAnchor, constant: m),
            pillRoot.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -m),
            pillRoot.heightAnchor.constraint(equalToConstant: Self.pillHeight),
        ])

        let glassHost = glassSurface.hostView
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        pillRoot.addSubview(glassHost)

        let foregroundHost = NSView()
        foregroundHost.wantsLayer = true
        foregroundHost.appearance = NSAppearance(named: .aqua)
        foregroundHost.translatesAutoresizingMaskIntoConstraints = false
        pillRoot.addSubview(foregroundHost)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        foregroundHost.addSubview(contentStack)

        NSLayoutConstraint.activate([
            glassHost.leadingAnchor.constraint(equalTo: pillRoot.leadingAnchor),
            glassHost.trailingAnchor.constraint(equalTo: pillRoot.trailingAnchor),
            glassHost.topAnchor.constraint(equalTo: pillRoot.topAnchor),
            glassHost.bottomAnchor.constraint(equalTo: pillRoot.bottomAnchor),
            foregroundHost.leadingAnchor.constraint(equalTo: pillRoot.leadingAnchor),
            foregroundHost.trailingAnchor.constraint(equalTo: pillRoot.trailingAnchor),
            foregroundHost.topAnchor.constraint(equalTo: pillRoot.topAnchor),
            foregroundHost.bottomAnchor.constraint(equalTo: pillRoot.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: foregroundHost.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: foregroundHost.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: foregroundHost.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: foregroundHost.bottomAnchor),
        ])

        // 1) 6 套背景色板圆点
        let swatchGroup = NSStackView()
        swatchGroup.orientation = .horizontal
        swatchGroup.alignment = .centerY
        swatchGroup.spacing = 2
        for (idx, preset) in BackdropStyle.Preset.allCases.enumerated() {
            let btn = BackdropSwatchButton(preset: preset)
            btn.tag = idx
            btn.target = self
            btn.action = #selector(presetTapped(_:))
            btn.onHover = { [weak self, weak btn] inside in
                self?.onHoverTip(inside ? btn : nil, inside ? preset.displayName : nil)
            }
            swatchButtons[preset] = btn
            swatchGroup.addArrangedSubview(btn)
        }
        contentStack.addArrangedSubview(swatchGroup)

        contentStack.addArrangedSubview(makeHairlineSeparator())

        // 2) 3 档边距胶囊按钮：紧凑 / 标准 / 展示
        let paddingGroup = NSStackView()
        paddingGroup.orientation = .horizontal
        paddingGroup.alignment = .centerY
        paddingGroup.spacing = 2
        for (idx, padding) in BackdropStyle.Padding.allCases.enumerated() {
            let btn = BackdropOptionPillButton(title: padding.displayName, symbolName: nil, monospacedDigits: false)
            btn.tag = idx
            btn.target = self
            btn.action = #selector(paddingTapped(_:))
            paddingButtons[padding] = btn
            paddingGroup.addArrangedSubview(btn)
        }
        contentStack.addArrangedSubview(paddingGroup)

        contentStack.addArrangedSubview(makeHairlineSeparator())

        // 3) 3 档比例胶囊按钮：自动 / 16:9 / 4:3
        let aspectGroup = NSStackView()
        aspectGroup.orientation = .horizontal
        aspectGroup.alignment = .centerY
        aspectGroup.spacing = 2
        for (idx, ratio) in BackdropStyle.AspectRatio.allCases.enumerated() {
            let btn = BackdropOptionPillButton(
                title: ratio.displayName,
                symbolName: nil,
                monospacedDigits: ratio != .auto
            )
            btn.tag = idx
            btn.target = self
            btn.action = #selector(aspectTapped(_:))
            aspectButtons[ratio] = btn
            aspectGroup.addArrangedSubview(btn)
        }
        contentStack.addArrangedSubview(aspectGroup)

        contentStack.addArrangedSubview(makeHairlineSeparator())

        // 4) 自动均衡留白开关小胶囊
        balanceButton.target = self
        balanceButton.action = #selector(balanceTapped)
        balanceButton.onHover = { [weak self] inside in
            guard let self else { return }
            self.onHoverTip(inside ? self.balanceButton : nil, inside ? "自动均衡留白" : nil)
        }
        contentStack.addArrangedSubview(balanceButton)

        contentView = outer
    }

    private func makeHairlineSeparator() -> NSView {
        let hairline = TBHairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hairline.widthAnchor.constraint(equalToConstant: 0.5),
            hairline.heightAnchor.constraint(equalToConstant: 16),
        ])
        return hairline
    }

    func update(style: BackdropStyle) {
        currentStyle = style
        refreshSelections()
    }

    private func refreshSelections() {
        for (preset, btn) in swatchButtons {
            btn.setSelected(preset == currentStyle.preset)
        }
        for (padding, btn) in paddingButtons {
            btn.setSelected(padding == currentStyle.padding)
        }
        for (ratio, btn) in aspectButtons {
            btn.setSelected(ratio == currentStyle.aspectRatio)
        }
        balanceButton.setSelected(currentStyle.autoBalance)
    }

    @objc private func presetTapped(_ sender: NSButton) {
        let all = BackdropStyle.Preset.allCases
        guard all.indices.contains(sender.tag) else { return }
        let chosen = all[sender.tag]
        guard currentStyle.preset != chosen else { return }
        currentStyle.preset = chosen
        refreshSelections()
        onStyleChange(currentStyle)
    }

    @objc private func paddingTapped(_ sender: NSButton) {
        let all = BackdropStyle.Padding.allCases
        guard all.indices.contains(sender.tag) else { return }
        let chosen = all[sender.tag]
        guard currentStyle.padding != chosen else { return }
        currentStyle.padding = chosen
        refreshSelections()
        onStyleChange(currentStyle)
    }

    @objc private func aspectTapped(_ sender: NSButton) {
        let all = BackdropStyle.AspectRatio.allCases
        guard all.indices.contains(sender.tag) else { return }
        let chosen = all[sender.tag]
        guard currentStyle.aspectRatio != chosen else { return }
        currentStyle.aspectRatio = chosen
        refreshSelections()
        onStyleChange(currentStyle)
    }

    @objc private func balanceTapped() {
        currentStyle.autoBalance.toggle()
        refreshSelections()
        onStyleChange(currentStyle)
    }

    func show(anchoredToBar barRect: CGRect, avoiding avoidRect: CGRect?, visible: CGRect, animated: Bool) {
        hideToken += 1
        contentView?.layoutSubtreeIfNeeded()
        let m = Self.shadowMargin
        let pillW = max(240, ceil(max(pillRoot.fittingSize.width, contentStack.fittingSize.width)))
        let pillH = Self.pillHeight

        var x = barRect.midX - pillW / 2
        x = max(visible.minX + 8, min(x, visible.maxX - pillW - 8))

        var y = barRect.maxY + Self.gapAboveBar
        if let avoidRect, avoidRect.minY >= barRect.maxY - 1 {
            // 智能打码胶囊位于主栏上方时，将画框胶囊抬升至其上方 6pt；若顶缘空间不足则翻至主栏下方
            let stackedY = avoidRect.maxY + Self.stackGap
            if stackedY + pillH <= visible.maxY - 8 {
                y = stackedY
            } else {
                y = barRect.minY - Self.gapAboveBar - pillH
            }
        } else if y + pillH > visible.maxY - 8 {
            y = barRect.minY - Self.gapAboveBar - pillH
            if let avoidRect, avoidRect.maxY <= barRect.minY + 1 {
                let stackedBelowY = avoidRect.minY - Self.stackGap - pillH
                if stackedBelowY >= visible.minY + 8 {
                    y = stackedBelowY
                }
            }
        }
        y = min(max(y, visible.minY + 8), visible.maxY - pillH - 8)

        let targetFrame = CGRect(
            x: (x - m).rounded(),
            y: (y - m).rounded(),
            width: pillW + m * 2,
            height: pillH + m * 2
        )

        let wasShown = isShown
        isShown = true

        if !wasShown {
            setFrame(targetFrame, display: false)
            contentView?.layoutSubtreeIfNeeded()
            outerShadowView.refreshGeometry()
            let reduce = DesignTokens.Motion.reduceMotion
            if animated && !reduce {
                setFrameOrigin(CGPoint(x: targetFrame.minX, y: targetFrame.minY - 5))
            }
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animated ? 0.16 : 0.01
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                if animated && !reduce {
                    self.animator().setFrame(targetFrame, display: true)
                }
                self.animator().alphaValue = 1
            }
        } else {
            let reduce = DesignTokens.Motion.reduceMotion
            if animated && !reduce && frame != targetFrame {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                    self.animator().setFrame(targetFrame, display: true)
                }
            } else {
                setFrame(targetFrame, display: true)
            }
            contentView?.layoutSubtreeIfNeeded()
            outerShadowView.refreshGeometry()
            orderFrontRegardless()
            alphaValue = 1
        }
    }

    func hide(immediate: Bool) {
        onHoverTip(nil, nil)
        guard isShown || isVisible else { return }
        isShown = false
        hideToken += 1
        let token = hideToken
        if immediate || DesignTokens.Motion.reduceMotion {
            orderOut(nil)
            alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.11
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token, !self.isShown else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
    }
}

/// 画框色板渐变圆点按钮（16×16 渐变圆 + 清晰双环选中指示）
@MainActor
private final class BackdropSwatchButton: NSButton {
    private static let buttonSide: CGFloat = 24
    private static let dotSide: CGFloat = 16

    var onHover: ((Bool) -> Void)?
    private let dotView = NSView()
    private let gradientLayer = CAGradientLayer()
    private let innerRing = NSView()
    private let outerRing = NSView()
    private var trackingArea: NSTrackingArea?
    private var isSelectedState = false

    init(preset: BackdropStyle.Preset) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: Self.buttonSide).isActive = true
        heightAnchor.constraint(equalToConstant: Self.buttonSide).isActive = true

        for ring in [innerRing, outerRing] {
            ring.translatesAutoresizingMaskIntoConstraints = false
            ring.wantsLayer = true
            ring.isHidden = true
            addSubview(ring)
        }
        innerRing.layer?.borderWidth = 1.5
        outerRing.layer?.borderWidth = 1.2

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = Self.dotSide / 2
        dotView.layer?.masksToBounds = true
        dotView.layer?.borderWidth = 0.5

        gradientLayer.colors = preset.colors.map(\.cgColor)
        gradientLayer.startPoint = preset.startPoint
        gradientLayer.endPoint = preset.endPoint
        gradientLayer.frame = CGRect(x: 0, y: 0, width: Self.dotSide, height: Self.dotSide)
        dotView.layer?.addSublayer(gradientLayer)

        addSubview(dotView)
        NSLayoutConstraint.activate([
            dotView.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dotView.heightAnchor.constraint(equalToConstant: Self.dotSide),
        ])
        refreshAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("BackdropSwatchButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = dotView.bounds
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        for (ring, side) in [(innerRing, CGFloat(19)), (outerRing, CGFloat(23))] {
            ring.frame = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            ring.layer?.cornerRadius = side / 2
        }
        CATransaction.commit()
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
        refreshAppearanceColors()
    }

    private func refreshAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            dotView.layer?.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.18)).cgColor
            innerRing.layer?.borderColor = DesignTokens.hudForeground(0.88).cgColor
            outerRing.layer?.borderColor = DesignTokens.accent.cgColor
        }
    }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        innerRing.isHidden = !selected
        outerRing.isHidden = !selected
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
        guard !DesignTokens.Motion.reduceMotion, let layer = dotView.layer else { return }
        let b = dotView.bounds
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, b.midX, b.midY, 0)
        t = CATransform3DScale(t, 1.14, 1.14, 1)
        t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        layer.transform = t
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        dotView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true, scale: 0.92)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }
}

/// 画框胶囊内共享选项按钮（用于边距 3 档、比例 3 档及自动均衡留白开关）
@MainActor
private final class BackdropOptionPillButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private let labelText: String
    private let monospacedDigits: Bool
    private var isHot = false
    private var isPressed = false
    private var isSelectedState = false
    private var trackingArea: NSTrackingArea?

    init(title: String, symbolName: String?, monospacedDigits: Bool) {
        self.labelText = title
        self.monospacedDigits = monospacedDigits
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        if let symbolName {
            image = TBIcon.symbolImage(named: symbolName, pointSize: 11, weight: .medium, hierarchical: true)
            imagePosition = .imageLeading
            imageHugsTitle = true
        } else {
            imagePosition = .noImage
        }
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("BackdropOptionPillButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let textW = ceil(attributedTitle.size().width)
        let imageW = image.map { ceil($0.size.width) + 2 } ?? 0
        return NSSize(width: max(34, textW + imageW + 14), height: 24)
    }

    func setSelected(_ selected: Bool) {
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
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
            let textColor: NSColor
            if isSelectedState {
                layer?.backgroundColor = DesignTokens.accentSoft.cgColor
                layer?.borderWidth = 0.5
                layer?.borderColor = DesignTokens.accent.withAlphaComponent(isDark ? 0.30 : 0.22).cgColor
                textColor = DesignTokens.accent
            } else if isPressed {
                layer?.backgroundColor = DesignTokens.fillPress.cgColor
                layer?.borderWidth = 0
                layer?.borderColor = nil
                textColor = DesignTokens.label1
            } else if isHot {
                layer?.backgroundColor = DesignTokens.fillHover.cgColor
                layer?.borderWidth = 0
                layer?.borderColor = nil
                textColor = DesignTokens.label1
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                layer?.borderWidth = 0
                layer?.borderColor = nil
                textColor = DesignTokens.label2
            }
            contentTintColor = textColor

            let font = monospacedDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                : NSFont.systemFont(ofSize: 11, weight: .medium)
            let display = (image != nil) ? " \(labelText)" : labelText
            attributedTitle = NSAttributedString(string: display, attributes: [
                .font: font,
                .foregroundColor: textColor,
            ])
        }
    }
}
