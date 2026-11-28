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

    /// 选中标注的样式实时联动（颜色点选 / 线宽滑杆）
    /// - `commit == false`：滑杆拖动中的预览帧（不压撤销栈）
    /// - `commit == true`：颜色点选 / 滑杆松手，整段拖动只占一步撤销
    var onStyleChange: ((_ colorIndex: Int?, _ strokeWidth: CGFloat?, _ commit: Bool) -> Void)?

    /// 编辑画布是否有「已选中标注」：为真时即使当前是 `.none`（选择/移动态）也浮出属性胶囊，
    /// 否则选中一条线想改颜色/线宽就没有任何入口
    var annotationSelectionActive = false

    enum Action {
        case undo, redo, toggleVisibility, done, save, cancel, ocr, pin, scroll, autoRedact, toggleBackdrop
        case record, recordGIF
    }

    struct Capabilities {
        var supportsScroll: Bool
        var supportsRecording: Bool

        static let screenshot = Capabilities(supportsScroll: true, supportsRecording: true)
        static let collage = Capabilities(supportsScroll: false, supportsRecording: false)
    }

    // 视图
    private var rootStack: NSStackView!
    /// 面板本体视图（玻璃圆角矩形，不含投影留白）
    private var panelRoot: NSView?
    private var outerShadowView: OuterShadowView?
    private var toolButtons: [EditorSession.Tool: TBToolButton] = [:]
    private var undoButton: TBIconButton!
    private var redoButton: TBIconButton!
    private var scrollButton: TBIconButton!
    private var recordButton: TBIconButton!
    private var moreButton: TBIconButton!
    private var tooltip: ToolbarTooltipWindow?
    /// 工具上下文属性胶囊（选中任意标注工具时在主栏上方/下方自动展开对应属性）
    private var smartAttributePill: SmartToolAttributePillPanel?
    /// 画框美化上下文微调胶囊（仅 `backdropStyle.enabled == true` 且工具栏可见时轻浮展开）
    private var smartBackdropPill: SmartBackdropPillPanel?
    /// `•••` 更多扩展灵动岛浮层（从按钮下方顺滑展开，不遮挡主工具栏）
    private var smartMorePanel: SmartMoreMenuPanel?
    private var capabilities: Capabilities = .screenshot
    private var backdropStyle = BackdropStyle()
    /// `place(...)` 入场动画期间的目标栏主体全局矩形，确保附属胶囊直接锚定终态位置而不跳动
    private var plannedBarFrameGlobal: CGRect?
    /// 共享滑动选中指示层（工具蓝胶囊）：切换工具时物理弹簧滑移
    private var indicatorView: TBSelectionIndicatorView?
    private var lastSelectedTool: EditorSession.Tool = .none
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

    func configure(
        session: EditorSession,
        capabilities: Capabilities = .screenshot,
        onToolChange: @escaping () -> Void,
        onAction: @escaping (Action) -> Void
    ) {
        self.session = session
        self.capabilities = capabilities
        self.onToolChange = onToolChange
        self.onAction = onAction
        // 新会话默认没有选中标注（上一轮残留的样式胶囊绝不能跨会话浮着）
        annotationSelectionActive = false
        lastSelectedTool = session.currentTool
        backdropStyle = BackdropStyle()
        scrollButton?.isHidden = !capabilities.supportsScroll
        recordButton?.isHidden = !capabilities.supportsRecording
        moreButton?.setSelected(false)
        smartAttributePill?.hide(immediate: true)
        smartBackdropPill?.hide(immediate: true)
        if let root = panelRoot {
            let m = TBStyle.shadowMargin
            root.layoutSubtreeIfNeeded()
            let fitting = root.fittingSize
            setContentSize(NSSize(width: fitting.width + m * 2, height: fitting.height + m * 2))
        }
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

        // 2) 撤销 / 重做
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

        // 3) 滚动截图 / 录屏 / 贴图 / 更多（取字 · 画框美化 · 隐藏工具栏 · 录制 GIF 收敛进更多菜单）
        let scrollBtn = TBIconButton(icon: .scroll, fallback: "滚")
        scrollBtn.tag = 206
        scrollBtn.target = self
        scrollBtn.action = #selector(actionTapped(_:))
        scrollBtn.onHover = { [weak self] inside in self?.handleHover(inside, button: scrollBtn, text: "滚动截图 \(Self.hotkeyTip("scroll"))") }
        scrollButton = scrollBtn
        stack.addArrangedSubview(scrollBtn)

        let recordBtn = TBIconButton(icon: .record, fallback: "录")
        recordBtn.tag = 209
        recordBtn.target = self
        recordBtn.action = #selector(actionTapped(_:))
        recordBtn.onHover = { [weak self] inside in self?.handleHover(inside, button: recordBtn, text: "录制视频 \(Self.hotkeyTip("record"))") }
        recordButton = recordBtn
        stack.addArrangedSubview(recordBtn)

        // 取字（tag 204）已从主栏瘦身收进 `•••` 更多菜单，快捷键 O 与 actionTapped 分支保留
        let pin = TBIconButton(icon: .pin, fallback: "钉")
        pin.tag = 205
        pin.target = self
        pin.action = #selector(actionTapped(_:))
        pin.onHover = { [weak self] inside in self?.handleHover(inside, button: pin, text: "贴图 \(Self.hotkeyTip("pin"))") }
        stack.addArrangedSubview(pin)

        let more = TBIconButton(icon: .more, fallback: "…")
        more.tag = 208
        more.usesSelfSelectedBackdrop = true
        more.target = self
        more.action = #selector(actionTapped(_:))
        more.onHover = { [weak self] inside in self?.handleHover(inside, button: more, text: "更多操作") }
        moreButton = more
        stack.addArrangedSubview(more)

        stack.addArrangedSubview(makeSeparator())

        // 4) 主按钮「复制」（32×32 纯图标 accent 实心键，唯一彩色 accent；tooltip 保留）
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
        reposition(panelOriginFor: { visible, panelSize in
            Self.originBelow(selection: selection, visible: visible, panelSize: panelSize)
        })
    }

    /// 宿主窗口移动/缩放时平滑跟随定位（拼贴合成编辑窗场景）
    func reposition(aboveGlobal hostRect: CGRect) {
        reposition(panelOriginFor: { visible, panelSize in
            Self.originAbove(hostRect: hostRect, visible: visible, panelSize: panelSize)
        })
    }

    private func reposition(panelOriginFor compute: (_ visible: CGRect, _ panelSize: CGSize) -> CGPoint) {
        guard isVisible else { return }
        plannedBarFrameGlobal = nil
        let margin = TBStyle.shadowMargin
        let panelSize = CGSize(width: frame.width - margin * 2,
                               height: frame.height - margin * 2)
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = compute(visible, panelSize)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        let newOrigin = CGPoint(x: (origin.x - margin).rounded(), y: (origin.y - margin).rounded())
        if frame.origin != newOrigin {
            setFrameOrigin(newOrigin)
        }
        tooltip?.hide()
        smartMorePanel?.hide(immediate: true)
        syncSmartAttributePill(animated: false)
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

    private static func originAbove(hostRect: CGRect, visible: CGRect, panelSize: CGSize) -> CGPoint {
        var origin = CGPoint(x: hostRect.midX - panelSize.width / 2,
                             y: hostRect.maxY + 12)
        if origin.y + panelSize.height > visible.maxY - 8 {
            origin.y = hostRect.minY - panelSize.height - 12
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
            syncSmartAttributePill(animated: false)
            syncSmartBackdropPill(animated: false)
        }
    }

    override func orderOut(_ sender: Any?) {
        tooltip?.hide()
        smartAttributePill?.hide(immediate: true)
        smartBackdropPill?.hide(immediate: true)
        smartMorePanel?.hide(immediate: true)
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
            smartAttributePill?.hide(immediate: true)
            smartBackdropPill?.hide(immediate: true)
            smartMorePanel?.hide(immediate: true)
            orderOut(nil)
        }
    }

    /// 拼贴合成编辑窗场景（设计定稿 §1.4）：工具栏贴宿主窗顶（框顶外 12pt），
    /// 顶上放不下翻到窗底
    func place(aboveGlobal hostRect: CGRect) {
        place(panelOriginFor: { visible, panelSize in
            Self.originAbove(hostRect: hostRect, visible: visible, panelSize: panelSize)
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
            syncSmartAttributePill(animated: true)
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
        smartAttributePill?.hide(immediate: false)
        smartBackdropPill?.hide(immediate: false)
        smartMorePanel?.hide(immediate: false)
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
        lastSelectedTool = session.currentTool

        for (tool, button) in toolButtons {
            let isSel = (tool == session.currentTool)
            button.setSelected(isSel)
            if animated && toolChanged && isSel {
                button.playSelectPop()
            }
        }
        undoButton.isEnabled = session.store.canUndo
        redoButton.isEnabled = session.store.canRedo
        undoButton.alphaValue = session.store.canUndo ? 1 : 0.35
        redoButton.alphaValue = session.store.canRedo ? 1 : 0.35

        // 更新滑动指示层（工具蓝胶囊，坐标转换到 indicators 自身空间）
        if let root = panelRoot, let indicators = indicatorView {
            root.layoutSubtreeIfNeeded()
            let toolFrame: CGRect? = toolButtons[session.currentTool].map { btn in
                btn.convert(btn.bounds, to: indicators).insetBy(dx: 2, dy: 2)
            }
            indicators.updateToolPill(to: toolFrame, animated: animated)
        }
        moreButton?.setSelected(backdropStyle.enabled)
        syncSmartAttributePill(animated: animated)
        syncSmartBackdropPill(animated: animated)
    }

    func setAutoRedactBusy(_ busy: Bool) {
        smartAttributePill?.setBusy(busy)
    }

    /// 由外部同步最新画框美化样式：更新主栏「更多」按钮提示态，并自动控制微调胶囊显隐与选中态刷新
    func updateBackdropStyle(_ style: BackdropStyle) {
        let wasEnabled = backdropStyle.enabled
        backdropStyle = style
        moreButton?.setSelected(style.enabled)
        if isVisible && style.enabled && !wasEnabled {
            moreButton?.playSelectPop()
        }
        smartBackdropPill?.update(style: style)
        syncSmartBackdropPill(animated: true)
    }

    /// 方案 B：仅当选中具体标注工具时，在工具图标上方/下方自动浮出对应属性胶囊
    /// （额外：选中已有标注时，`.none` 选择态也浮出「颜色 + 线宽」样式胶囊）
    private func syncSmartAttributePill(animated: Bool) {
        guard isVisible,
              let session,
              session.toolbarVisible
        else {
            smartAttributePill?.hide(immediate: !animated)
            return
        }
        let styleMode = session.currentTool == .none && annotationSelectionActive
        let anchorBtn = toolButtons[session.currentTool]
        guard styleMode || (session.currentTool != .none && anchorBtn != nil) else {
            smartAttributePill?.hide(immediate: !animated)
            return
        }
        let pill = smartAttributePill ?? {
            let p = SmartToolAttributePillPanel(
                onColorSelect: { [weak self] index in
                    guard let self else { return }
                    Log.event(.editor, "toolbar.color", ["index": "\(index)"])
                    self.session?.colorIndex = index
                    self.onStyleChange?(index, nil, true)
                    self.refreshSelectionState(animated: true)
                    self.onToolChange()
                },
                onStrokeChange: { [weak self] width, sender in
                    guard let self else { return }
                    self.session?.strokeWidth = width
                    // 拖动中的逐帧预览：只套样式不压栈（松手 onStrokeCommit 时整段算一步）
                    self.onStyleChange?(nil, width, false)
                    let text = (self.session?.currentTool == .mosaic)
                        ? "马赛克 \(Int(max(8, width * 4))) px"
                        : String(format: "线宽 %.1f pt", width)
                    self.handlePillHover(view: sender, text: text)
                },
                onStrokeCommit: { [weak self] width in
                    guard let self else { return }
                    self.onStyleChange?(nil, width, true)
                    Log.event(.editor, "toolbar.stroke", ["width": String(format: "%.1f", width)])
                },
                onFontSizeSelect: { [weak self] size in
                    guard let self else { return }
                    self.session?.textFontSize = size
                    self.refreshSelectionState(animated: true)
                    self.onToolChange()
                    Log.event(.editor, "editor.text.fontSize", ["size": "\(size)"])
                },
                onAutoRedact: { [weak self] in
                    self?.onAction(.autoRedact)
                },
                onHoverTip: { [weak self] view, text in
                    self?.handlePillHover(view: view, text: text)
                }
            )
            self.smartAttributePill = p
            return p
        }()
        pill.appearance = appearance
        pill.sync(
            tool: session.currentTool,
            colorIndex: session.colorIndex,
            strokeWidth: session.strokeWidth,
            textFontSize: session.textFontSize,
            animated: animated,
            styleMode: styleMode
        )
        let barGlobal = plannedBarFrameGlobal ?? visibleBarFrameGlobal
        // 样式模式没有「当前工具按钮」：锚在工具栏水平中心，胶囊自然浮在工具栏正上方
        let anchorGlobal: CGRect
        if styleMode {
            anchorGlobal = CGRect(x: barGlobal.midX, y: barGlobal.maxY, width: 1, height: 1)
        } else if let anchorBtn {
            anchorGlobal = convertToScreen(anchorBtn.convert(anchorBtn.bounds, to: nil))
        } else {
            anchorGlobal = CGRect(x: barGlobal.midX, y: barGlobal.maxY, width: 1, height: 1)
        }
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        pill.show(anchoredTo: anchorGlobal, barRect: barGlobal, visible: visible, animated: animated)
    }

    /// 仅在 `backdropStyle.enabled == true` 且工具栏可见时，在主工具栏上方（避让 SmartToolAttributePillPanel）展开微调胶囊
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
                    self.moreButton?.setSelected(updated.enabled)
                    self.onBackdropStyleChange?(updated)
                },
                onHoverTip: { [weak self] view, text in
                    self?.handlePillHover(view: view, text: text)
                }
            )
            self.smartBackdropPill = p
            return p
        }()
        pill.appearance = appearance
        pill.update(style: backdropStyle)
        let barGlobal = plannedBarFrameGlobal ?? visibleBarFrameGlobal
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let avoidRect: CGRect? = (smartAttributePill?.isShowing == true) ? smartAttributePill?.visiblePillFrame : nil
        pill.show(anchoredToBar: barGlobal, avoiding: avoidRect, visible: visible, animated: animated)
    }

    func hideTooltip() {
        tooltip?.hide()
        smartAttributePill?.hide(immediate: true)
        smartBackdropPill?.hide(immediate: true)
        smartMorePanel?.hide(immediate: true)
    }

    func setToolbarHidden(_ hidden: Bool) {
        Log.event(.editor, "toolbar.visibility", ["state": hidden ? "hidden" : "visible"])
    }

    // MARK: - 悬停提示

    private func handleHover(_ inside: Bool, button: NSView?, text: String) {
        if inside, let button {
            if tooltip == nil { tooltip = ToolbarTooltipWindow() }
            let frameInWindow = button.convert(button.bounds, to: nil)
            var screenRect = self.convertToScreen(frameInWindow)
            screenRect.origin.y = frame.maxY - TBStyle.shadowMargin
            screenRect.size.height = 0
            tooltip?.show(text: text, above: screenRect, after: 0.16)
        } else {
            tooltip?.hide()
        }
    }

    private func handlePillHover(view: NSView?, text: String?) {
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
        case 208: toggleMoreMenu()
        case 209: onAction(.record)
        default: break
        }
    }

    /// `•••` 灵动岛式展开菜单：从按钮下方顺滑弹出（不遮挡主栏），再次点击或点外区自动收起
    private func toggleMoreMenu() {
        guard let moreButton else { return }
        if smartMorePanel?.isShowing == true {
            smartMorePanel?.hide(immediate: false)
            return
        }
        let panel = smartMorePanel ?? {
            let p = SmartMoreMenuPanel(
                onToggleBackdrop: { [weak self] in
                    self?.onAction(.toggleBackdrop)
                },
                onOCR: { [weak self] in
                    self?.onAction(.ocr)
                },
                onToggleVisibility: { [weak self] in
                    self?.onAction(.toggleVisibility)
                },
                onRecordGIF: { [weak self] in
                    self?.onAction(.recordGIF)
                }
            )
            self.smartMorePanel = p
            return p
        }()
        panel.appearance = appearance
        let toggleCombo = AppCoordinatorShared.coordinator?.settings.editorHotkey(for: "toggleVisibility") ?? "h"
        let toggleTip = HotkeySpec.compactDisplay(toggleCombo)
        let gifCombo = AppCoordinatorShared.coordinator?.settings.editorHotkey(for: "recordGIF") ?? "g"
        let gifTip = HotkeySpec.compactDisplay(gifCombo)
        let ocrCombo = AppCoordinatorShared.coordinator?.settings.editorHotkey(for: "ocr") ?? "o"
        let ocrTip = HotkeySpec.compactDisplay(ocrCombo)
        panel.updateState(
            backdropEnabled: backdropStyle.enabled,
            ocrShortcut: ocrTip,
            hideShortcut: toggleTip,
            gifShortcut: gifTip,
            supportsRecording: capabilities.supportsRecording
        )

        let inWindow = moreButton.convert(moreButton.bounds, to: nil)
        let btnGlobal = convertToScreen(inWindow)
        let barGlobal = plannedBarFrameGlobal ?? visibleBarFrameGlobal
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let upperAvoid = (smartAttributePill?.isShowing == true) ? smartAttributePill?.visiblePillFrame : nil
        panel.show(
            anchoredTo: btnGlobal,
            barRect: barGlobal,
            upperAvoidRect: upperAvoid,
            visible: visible,
            triggerButton: moreButton
        )
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
    private let dotSide: CGFloat
    private var trackingArea: NSTrackingArea?
    private var selected = false

    init(color: NSColor, dotSide: CGFloat = TBStyle.dotSide) {
        self.dotSide = dotSide
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // 命中区 = 色点本身（原型 .dot 无 hover 底色，只有 scale 1.12）。
        let dotHit: CGFloat = dotSide + 6
        widthAnchor.constraint(equalToConstant: dotHit).isActive = true
        heightAnchor.constraint(equalToConstant: dotHit).isActive = true

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotSide / 2
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
            dot.widthAnchor.constraint(equalToConstant: dotSide),
            dot.heightAnchor.constraint(equalToConstant: dotSide),
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
            let ringSide = dotSide + outset * 2
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

    init(minWidth: CGFloat = 2.0, maxWidth: CGFloat = 10.0, compactForPill: Bool = false) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.currentValue = minWidth

        if compactForPill || TBStyle.buttonSide <= 32 {
            self.sliderWidth = 96
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
        heightAnchor.constraint(equalToConstant: compactForPill ? 26 : TBStyle.buttonSide).isActive = true

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

// MARK: - 共享弹簧滑动选中指示层（工具胶囊物理过渡）

@MainActor
private final class TBSelectionIndicatorView: NSView {
    private let toolPill = CALayer()
    private var toolPillVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        toolPill.cornerRadius = TBStyle.innerPillRadius
        toolPill.borderWidth = 0.5
        toolPill.opacity = 0
        layer?.addSublayer(toolPill)

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

// MARK: - 灵动岛动效原语（作用于子视图 motionHost.layer，规避 NSWindow contentView.layer 被系统覆写）

@MainActor
private enum IslandMotion {
    static func makeTransform(
        in bounds: CGRect,
        anchorX: CGFloat,
        anchorY: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat,
        tuckY: CGFloat
    ) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, 0, tuckY, 0)
        t = CATransform3DTranslate(t, anchorX, anchorY, 0)
        t = CATransform3DScale(t, scaleX, scaleY, 1)
        t = CATransform3DTranslate(t, -anchorX, -anchorY, 0)
        return t
    }

    static func expand(
        _ host: NSView,
        anchorGlobalX: CGFloat,
        panelFrame: CGRect,
        openedBelowBar: Bool,
        shadowMargin: CGFloat
    ) {
        guard let layer = host.layer else { return }
        let b = host.bounds
        let minX = shadowMargin + 12
        let maxX = max(minX, b.width - shadowMargin - 12)
        let anchorX = min(max(anchorGlobalX - panelFrame.minX, minX), maxX)
        let anchorY = openedBelowBar ? (b.maxY - shadowMargin) : (b.minY + shadowMargin)
        let tuckY: CGFloat = openedBelowBar ? 10 : -10
        let startT = makeTransform(
            in: b,
            anchorX: anchorX,
            anchorY: anchorY,
            scaleX: 0.74,
            scaleY: 0.42,
            tuckY: tuckY
        )

        layer.removeAnimation(forKey: "islandExpand")
        layer.removeAnimation(forKey: "islandFade")
        layer.removeAnimation(forKey: "islandCollapse")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: startT)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.stiffness = 340
        spring.damping = 24
        spring.mass = 0.88
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "islandExpand")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.14
        fade.timingFunction = DesignTokens.Motion.easeOutStrong
        layer.add(fade, forKey: "islandFade")
    }

    static func morphPulse(_ host: NSView, shadowMargin: CGFloat, openedBelowBar: Bool) {
        guard let layer = host.layer else { return }
        let b = host.bounds
        let anchorY = openedBelowBar ? (b.maxY - shadowMargin) : (b.minY + shadowMargin)
        let startT = makeTransform(
            in: b,
            anchorX: b.midX,
            anchorY: anchorY,
            scaleX: 0.94,
            scaleY: 0.92,
            tuckY: 0
        )
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: startT)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.stiffness = 420
        spring.damping = 28
        spring.mass = 0.82
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "islandMorph")
    }

    static func collapse(
        _ host: NSView,
        anchorGlobalX: CGFloat,
        panelFrame: CGRect,
        openedBelowBar: Bool,
        shadowMargin: CGFloat,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let layer = host.layer else {
            completion()
            return
        }
        let b = host.bounds
        let minX = shadowMargin + 12
        let maxX = max(minX, b.width - shadowMargin - 12)
        let anchorX = min(max(anchorGlobalX - panelFrame.minX, minX), maxX)
        let anchorY = openedBelowBar ? (b.maxY - shadowMargin) : (b.minY + shadowMargin)
        let tuckY: CGFloat = openedBelowBar ? 7 : -7
        let endT = makeTransform(
            in: b,
            anchorX: anchorX,
            anchorY: anchorY,
            scaleX: 0.82,
            scaleY: 0.62,
            tuckY: tuckY
        )

        layer.removeAnimation(forKey: "islandExpand")
        layer.removeAnimation(forKey: "islandFade")

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                completion()
            }
        }
        layer.transform = endT
        layer.opacity = 0
        CATransaction.commit()
    }

    static func reset(_ host: NSView) {
        guard let layer = host.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }
}

// MARK: - 上下文工具属性胶囊（方案 B：按当前工具精准呈献色点 / 粗细 / 字号 / 智能打码）

@MainActor
private final class ToolAttrOuterView: NSView {
    weak var pillRootView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pill = pillRootView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return pill.frame.contains(local) ? super.hitTest(point) : nil
    }
}

@MainActor
private final class SmartToolAttributePillPanel: NSPanel {
    private static let pillHeight: CGFloat = 34
    private static let shadowMargin: CGFloat = 20
    private static let gapFromBar: CGFloat = 8
    private static let fontSizes: [Int] = [12, 14, 17, 21]

    private let onColorSelect: (Int) -> Void
    private let onStrokeChange: (CGFloat, NSView) -> Void
    private let onStrokeCommit: (CGFloat) -> Void
    private let onFontSizeSelect: (Int) -> Void
    private let onAutoRedact: () -> Void
    private let onHoverTip: (NSView?, String?) -> Void

    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let motionHost = NSView()
    private let pillRoot = NSView()
    private let foregroundHost = NSView()
    private let contentStack = NSStackView()
    private let outerShadowView: OuterShadowView
    private let colorRing = CALayer()
    private var colorRingVisible = false

    private let colorsGroup = NSStackView()
    private var colorButtons: [TBColorButton] = []
    private let colorSeparator = TBHairlineView()
    private let strokeSlider = TBStrokeSlider(minWidth: 2.0, maxWidth: 10.0, compactForPill: true)
    private let redactSeparator = TBHairlineView()
    private let fontSizeGroup = NSStackView()
    private var fontSizeButtons: [Int: BackdropOptionPillButton] = [:]
    private let redactButton = SmartRedactPillButton()

    private var currentTool: EditorSession.Tool = .none
    private var currentColorIndex = 0
    private var lastAnchorGlobalX: CGFloat = 0
    private var openedBelowBar = false
    private var hideToken = 0
    private var isShown = false

    var isShowing: Bool { isShown }
    var visiblePillFrame: CGRect { frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

    init(
        onColorSelect: @escaping (Int) -> Void,
        onStrokeChange: @escaping (CGFloat, NSView) -> Void,
        onStrokeCommit: @escaping (CGFloat) -> Void,
        onFontSizeSelect: @escaping (Int) -> Void,
        onAutoRedact: @escaping () -> Void,
        onHoverTip: @escaping (NSView?, String?) -> Void
    ) {
        self.onColorSelect = onColorSelect
        self.onStrokeChange = onStrokeChange
        self.onStrokeCommit = onStrokeCommit
        self.onFontSizeSelect = onFontSizeSelect
        self.onAutoRedact = onAutoRedact
        self.onHoverTip = onHoverTip
        self.glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: 11,
            tintAlpha: 0.08
        )
        self.outerShadowView = OuterShadowView(spec: .pill, margin: Self.shadowMargin, cornerRadius: 11)

        let initW: CGFloat = 240
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
    }

    private func buildUI() {
        let m = Self.shadowMargin
        let outer = ToolAttrOuterView()
        outer.wantsLayer = true

        motionHost.wantsLayer = true
        motionHost.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(motionHost)
        NSLayoutConstraint.activate([
            motionHost.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            motionHost.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            motionHost.topAnchor.constraint(equalTo: outer.topAnchor),
            motionHost.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
        ])

        outerShadowView.translatesAutoresizingMaskIntoConstraints = false
        motionHost.addSubview(outerShadowView)
        NSLayoutConstraint.activate([
            outerShadowView.leadingAnchor.constraint(equalTo: motionHost.leadingAnchor),
            outerShadowView.trailingAnchor.constraint(equalTo: motionHost.trailingAnchor),
            outerShadowView.topAnchor.constraint(equalTo: motionHost.topAnchor),
            outerShadowView.bottomAnchor.constraint(equalTo: motionHost.bottomAnchor),
        ])

        pillRoot.wantsLayer = true
        pillRoot.translatesAutoresizingMaskIntoConstraints = false
        motionHost.addSubview(pillRoot)
        outer.pillRootView = pillRoot
        NSLayoutConstraint.activate([
            pillRoot.leadingAnchor.constraint(equalTo: motionHost.leadingAnchor, constant: m),
            pillRoot.trailingAnchor.constraint(equalTo: motionHost.trailingAnchor, constant: -m),
            pillRoot.topAnchor.constraint(equalTo: motionHost.topAnchor, constant: m),
            pillRoot.bottomAnchor.constraint(equalTo: motionHost.bottomAnchor, constant: -m),
            pillRoot.heightAnchor.constraint(equalToConstant: Self.pillHeight),
        ])

        let glassHost = glassSurface.hostView
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        pillRoot.addSubview(glassHost)

        foregroundHost.wantsLayer = true
        foregroundHost.appearance = NSAppearance(named: .aqua)
        foregroundHost.translatesAutoresizingMaskIntoConstraints = false
        pillRoot.addSubview(foregroundHost)

        colorRing.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        colorRing.cornerRadius = 9
        colorRing.borderWidth = 1.5
        colorRing.backgroundColor = NSColor.clear.cgColor
        colorRing.borderColor = DesignTokens.hudForeground(0.86).cgColor
        colorRing.opacity = 0
        foregroundHost.layer?.addSublayer(colorRing)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
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

        // 1) 五色圆点组
        colorsGroup.orientation = .horizontal
        colorsGroup.alignment = .centerY
        colorsGroup.spacing = 4
        let colorNames = ["红", "蓝", "黄", "黑", "白"]
        for (i, color) in AnnotationModel.palette.enumerated() {
            let btn = TBColorButton(color: NSColor(cgColor: color.cgColor) ?? .red, dotSide: 14)
            btn.tag = i
            btn.target = self
            btn.action = #selector(colorTapped(_:))
            btn.onHover = { [weak self, weak btn] inside in
                self?.onHoverTip(inside ? btn : nil, inside ? colorNames[i % 5] : nil)
            }
            colorButtons.append(btn)
            colorsGroup.addArrangedSubview(btn)
        }
        contentStack.addArrangedSubview(colorsGroup)

        // 2) 分隔线（色点与粗细/字号之间）
        colorSeparator.translatesAutoresizingMaskIntoConstraints = false
        colorSeparator.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        colorSeparator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        contentStack.addArrangedSubview(colorSeparator)

        // 3) 线宽 / 马赛克块大小滑杆
        strokeSlider.onChange = { [weak self] width in
            guard let self else { return }
            self.onStrokeChange(width, self.strokeSlider)
        }
        strokeSlider.onCommit = { [weak self] width in
            self?.onStrokeCommit(width)
        }
        strokeSlider.onHover = { [weak self] inside in
            guard let self else { return }
            guard inside else {
                self.onHoverTip(nil, nil)
                return
            }
            let tip = (self.currentTool == .mosaic)
                ? "马赛克 \(Int(max(8, self.strokeSlider.value * 4))) px"
                : String(format: "线宽 %.1f pt", self.strokeSlider.value)
            self.onHoverTip(self.strokeSlider, tip)
        }
        contentStack.addArrangedSubview(strokeSlider)

        // 3.5) 分隔线（马赛克块大小与智能打码之间）
        redactSeparator.translatesAutoresizingMaskIntoConstraints = false
        redactSeparator.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        redactSeparator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        contentStack.addArrangedSubview(redactSeparator)

        // 4) 文字字号 4 档 (12 / 14 / 17 / 21)
        fontSizeGroup.orientation = .horizontal
        fontSizeGroup.alignment = .centerY
        fontSizeGroup.spacing = 2
        for sz in Self.fontSizes {
            let btn = BackdropOptionPillButton(title: "\(sz)", symbolName: nil, monospacedDigits: true)
            btn.tag = sz
            btn.target = self
            btn.action = #selector(fontSizeTapped(_:))
            btn.onHover = { [weak self, weak btn] inside in
                self?.onHoverTip(inside ? btn : nil, inside ? "字号 \(sz) pt" : nil)
            }
            fontSizeButtons[sz] = btn
            fontSizeGroup.addArrangedSubview(btn)
        }
        contentStack.addArrangedSubview(fontSizeGroup)

        // 5) 马赛克智能打码按钮
        redactButton.target = self
        redactButton.action = #selector(redactTapped)
        redactButton.onHover = { [weak self] inside in
            guard let self else { return }
            self.onHoverTip(inside ? self.redactButton : nil, inside ? "自动识别并遮挡敏感信息 ⇧M" : nil)
        }
        contentStack.addArrangedSubview(redactButton)

        contentView = outer
    }

    func setBusy(_ busy: Bool) {
        redactButton.setBusy(busy)
    }

    func sync(
        tool: EditorSession.Tool,
        colorIndex: Int,
        strokeWidth: CGFloat,
        textFontSize: Int,
        animated: Bool,
        styleMode: Bool = false
    ) {
        let colorChanged = colorIndex != currentColorIndex
        currentTool = tool
        currentColorIndex = colorIndex

        // 样式模式（选中已有标注、当前是 .none 选择态）：只露「颜色 + 线宽」
        let showColors = styleMode || (tool != .none && tool != .mosaic)
        let showStroke = styleMode || (tool == .arrow || tool == .rect || tool == .ellipse || tool == .highlight || tool == .sequence || tool == .mosaic)
        let showFontSize = !styleMode && (tool == .text)
        let showRedact = !styleMode && (tool == .mosaic)

        colorsGroup.isHidden = !showColors
        strokeSlider.isHidden = !showStroke
        fontSizeGroup.isHidden = !showFontSize
        redactButton.isHidden = !showRedact
        colorSeparator.isHidden = !(showColors && (showStroke || showFontSize))
        redactSeparator.isHidden = !(showStroke && showRedact)

        for (i, btn) in colorButtons.enumerated() {
            let isSel = (i == colorIndex)
            btn.setSelected(isSel)
            if animated && colorChanged && isSel && showColors {
                btn.playSelectPop()
            }
        }
        strokeSlider.value = strokeWidth
        for (sz, btn) in fontSizeButtons {
            btn.setSelected(sz == textFontSize)
        }

        contentView?.layoutSubtreeIfNeeded()
        updateColorRing(show: showColors, colorIndex: colorIndex, animated: animated)
    }

    private func updateColorRing(show: Bool, colorIndex: Int, animated: Bool) {
        guard show, colorButtons.indices.contains(colorIndex) else {
            colorRingVisible = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            colorRing.opacity = 0
            CATransaction.commit()
            return
        }
        let btn = colorButtons[colorIndex]
        let rect = btn.convert(btn.bounds, to: foregroundHost)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let fromPos = colorRing.presentation()?.position ?? colorRing.position
        let wasVisible = colorRingVisible
        colorRingVisible = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorRing.borderColor = DesignTokens.hudForeground(0.86).cgColor
        colorRing.position = center
        colorRing.opacity = 1
        CATransaction.commit()
        if wasVisible && animated && !DesignTokens.Motion.reduceMotion && hypot(center.x - fromPos.x, center.y - fromPos.y) > 0.5 {
            let s = CASpringAnimation(keyPath: "position")
            s.fromValue = NSValue(point: fromPos)
            s.toValue = NSValue(point: center)
            s.stiffness = 420
            s.damping = 28
            s.mass = 0.85
            s.duration = s.settlingDuration
            colorRing.add(s, forKey: "attrColorGlide")
        }
    }

    func show(anchoredTo buttonRect: CGRect, barRect: CGRect, visible: CGRect, animated: Bool) {
        hideToken += 1
        contentView?.layoutSubtreeIfNeeded()
        let m = Self.shadowMargin
        let pillW = max(120, ceil(max(pillRoot.fittingSize.width, contentStack.fittingSize.width)))
        let pillH = Self.pillHeight

        lastAnchorGlobalX = buttonRect.midX
        var x = buttonRect.midX - pillW / 2
        if barRect.width >= pillW {
            x = max(barRect.minX, min(x, barRect.maxX - pillW))
        }
        x = max(visible.minX + 8, min(x, visible.maxX - pillW - 8))

        var y = barRect.maxY + Self.gapFromBar
        if y + pillH <= visible.maxY - 8 {
            openedBelowBar = false
        } else {
            y = barRect.minY - Self.gapFromBar - pillH
            openedBelowBar = true
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
            alphaValue = 1
            setFrame(targetFrame, display: true)
            contentView?.layoutSubtreeIfNeeded()
            outerShadowView.refreshGeometry()
            updateColorRing(show: !colorsGroup.isHidden, colorIndex: currentColorIndex, animated: false)
            if animated {
                IslandMotion.reset(motionHost)
                orderFrontRegardless()
                IslandMotion.expand(
                    motionHost,
                    anchorGlobalX: buttonRect.midX,
                    panelFrame: targetFrame,
                    openedBelowBar: openedBelowBar,
                    shadowMargin: m
                )
            } else {
                IslandMotion.reset(motionHost)
                orderFrontRegardless()
            }
        } else {
            if !animated && frame.size == targetFrame.size {
                // 选区实时拖拽跟随：仅平移窗口原点，避免 120Hz 拖动期重排布局或重建阴影几何
                if frame.origin != targetFrame.origin {
                    setFrameOrigin(targetFrame.origin)
                }
                if !isVisible { orderFrontRegardless() }
                if alphaValue != 1 { alphaValue = 1 }
                return
            }
            let sizeOrPosChanged = frame != targetFrame
            if animated && sizeOrPosChanged {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
                    ctx.timingFunction = DesignTokens.Motion.springTimingFunction
                    self.animator().setFrame(targetFrame, display: true)
                }
                IslandMotion.morphPulse(motionHost, shadowMargin: m, openedBelowBar: openedBelowBar)
            } else {
                setFrame(targetFrame, display: true)
            }
            contentView?.layoutSubtreeIfNeeded()
            outerShadowView.refreshGeometry()
            updateColorRing(show: !colorsGroup.isHidden, colorIndex: currentColorIndex, animated: animated)
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
        if immediate {
            IslandMotion.reset(motionHost)
            orderOut(nil)
            alphaValue = 1
            return
        }
        IslandMotion.collapse(
            motionHost,
            anchorGlobalX: lastAnchorGlobalX,
            panelFrame: frame,
            openedBelowBar: openedBelowBar,
            shadowMargin: Self.shadowMargin
        ) { [weak self] in
            guard let self, self.hideToken == token, !self.isShown else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            IslandMotion.reset(self.motionHost)
        }
    }

    @objc private func colorTapped(_ sender: NSButton) {
        onColorSelect(sender.tag)
    }

    @objc private func fontSizeTapped(_ sender: NSButton) {
        onFontSizeSelect(sender.tag)
    }

    @objc private func redactTapped() {
        onAutoRedact()
    }
}

@MainActor
private final class SmartRedactPillButton: NSButton {
    var onHover: ((Bool) -> Void)?
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
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SmartRedactPillButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth(), height: 24)
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        isEnabled = !busy
        invalidateIntrinsicContentSize()
        applyStyle()
    }

    func preferredWidth() -> CGFloat {
        isBusy ? 82 : 112
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
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
        onHover?(false)
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
            if (!animated || reduce) && frame.size == targetFrame.size {
                if frame.origin != targetFrame.origin {
                    setFrameOrigin(targetFrame.origin)
                }
                if !isVisible { orderFrontRegardless() }
                if alphaValue != 1 { alphaValue = 1 }
                return
            }
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

// MARK: - `•••` 灵动岛式玻璃展开菜单（锚定触发按钮下方/上方，永不遮挡主栏）

@MainActor
private final class MoreMenuOuterView: NSView {
    weak var pillRootView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pill = pillRootView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return pill.frame.contains(local) ? super.hitTest(point) : nil
    }
}

@MainActor
private final class SmartMoreMenuPanel: NSPanel {
    private static let shadowMargin: CGFloat = 20
    private static let gapFromBar: CGFloat = 8
    private static let panelWidth: CGFloat = 176
    private static let cornerRadius: CGFloat = 12

    private let onToggleBackdrop: () -> Void
    private let onOCR: () -> Void
    private let onToggleVisibility: () -> Void
    private let onRecordGIF: () -> Void

    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let motionHost = NSView()
    private let pillRoot = NSView()
    private let foregroundHost = NSView()
    private let contentStack = NSStackView()
    private let outerShadowView: OuterShadowView

    private let backdropRow: MoreMenuItemRowButton
    private let ocrRow: MoreMenuItemRowButton
    private let recordGIFRow: MoreMenuItemRowButton
    private let hideRow: MoreMenuItemRowButton

    private weak var triggerButton: NSView?
    private var localEventMonitor: Any?
    private var lastAnchorGlobalX: CGFloat = 0
    private var hideToken = 0
    private var isShown = false
    private var openedBelowBar = true

    var isShowing: Bool { isShown }

    init(
        onToggleBackdrop: @escaping () -> Void,
        onOCR: @escaping () -> Void,
        onToggleVisibility: @escaping () -> Void,
        onRecordGIF: @escaping () -> Void
    ) {
        self.onToggleBackdrop = onToggleBackdrop
        self.onOCR = onOCR
        self.onToggleVisibility = onToggleVisibility
        self.onRecordGIF = onRecordGIF
        self.glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: Self.cornerRadius,
            tintAlpha: 0.08
        )
        self.outerShadowView = OuterShadowView(spec: .pill, margin: Self.shadowMargin, cornerRadius: Self.cornerRadius)
        self.backdropRow = MoreMenuItemRowButton(icon: .backdrop, title: "画框美化", shortcut: "B")
        self.ocrRow = MoreMenuItemRowButton(icon: .ocr, title: "取字", shortcut: "O")
        self.recordGIFRow = MoreMenuItemRowButton(icon: .recordGIF, title: "录制 GIF", shortcut: "G")
        self.hideRow = MoreMenuItemRowButton(icon: .eye, title: "隐藏工具栏", shortcut: "H")

        let initH: CGFloat = 104
        let m = Self.shadowMargin
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth + m * 2, height: initH + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        appearance = NSAppearance(named: .aqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        buildUI()
    }

    private func buildUI() {
        let m = Self.shadowMargin
        let outer = MoreMenuOuterView()
        outer.wantsLayer = true

        motionHost.wantsLayer = true
        motionHost.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(motionHost)
        NSLayoutConstraint.activate([
            motionHost.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            motionHost.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            motionHost.topAnchor.constraint(equalTo: outer.topAnchor),
            motionHost.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
        ])

        outerShadowView.translatesAutoresizingMaskIntoConstraints = false
        motionHost.addSubview(outerShadowView)
        NSLayoutConstraint.activate([
            outerShadowView.leadingAnchor.constraint(equalTo: motionHost.leadingAnchor),
            outerShadowView.trailingAnchor.constraint(equalTo: motionHost.trailingAnchor),
            outerShadowView.topAnchor.constraint(equalTo: motionHost.topAnchor),
            outerShadowView.bottomAnchor.constraint(equalTo: motionHost.bottomAnchor),
        ])

        pillRoot.wantsLayer = true
        pillRoot.translatesAutoresizingMaskIntoConstraints = false
        motionHost.addSubview(pillRoot)
        outer.pillRootView = pillRoot
        NSLayoutConstraint.activate([
            pillRoot.leadingAnchor.constraint(equalTo: motionHost.leadingAnchor, constant: m),
            pillRoot.trailingAnchor.constraint(equalTo: motionHost.trailingAnchor, constant: -m),
            pillRoot.topAnchor.constraint(equalTo: motionHost.topAnchor, constant: m),
            pillRoot.bottomAnchor.constraint(equalTo: motionHost.bottomAnchor, constant: -m),
            pillRoot.widthAnchor.constraint(equalToConstant: Self.panelWidth),
        ])

        let glassHost = glassSurface.hostView
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        pillRoot.addSubview(glassHost)

        foregroundHost.wantsLayer = true
        foregroundHost.appearance = NSAppearance(named: .aqua)
        foregroundHost.translatesAutoresizingMaskIntoConstraints = false
        pillRoot.addSubview(foregroundHost)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 2
        contentStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
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

        backdropRow.target = self
        backdropRow.action = #selector(backdropTapped)
        ocrRow.target = self
        ocrRow.action = #selector(ocrTapped)
        recordGIFRow.target = self
        recordGIFRow.action = #selector(recordGIFTapped)
        hideRow.target = self
        hideRow.action = #selector(hideTapped)

        contentStack.addArrangedSubview(backdropRow)
        contentStack.addArrangedSubview(ocrRow)
        contentStack.addArrangedSubview(recordGIFRow)
        contentStack.addArrangedSubview(hideRow)
        backdropRow.widthAnchor.constraint(equalToConstant: Self.panelWidth - 12).isActive = true
        ocrRow.widthAnchor.constraint(equalToConstant: Self.panelWidth - 12).isActive = true
        recordGIFRow.widthAnchor.constraint(equalToConstant: Self.panelWidth - 12).isActive = true
        hideRow.widthAnchor.constraint(equalToConstant: Self.panelWidth - 12).isActive = true

        contentView = outer
    }

    func updateState(
        backdropEnabled: Bool,
        ocrShortcut: String,
        hideShortcut: String,
        gifShortcut: String,
        supportsRecording: Bool
    ) {
        backdropRow.setChecked(backdropEnabled)
        ocrRow.setShortcut(ocrShortcut.isEmpty ? "O" : ocrShortcut)
        hideRow.setShortcut(hideShortcut.isEmpty ? "H" : hideShortcut)
        recordGIFRow.setShortcut(gifShortcut.isEmpty ? "G" : gifShortcut)
        // 拼贴编辑器等不支持录制的场景隐藏「录制 GIF」行
        recordGIFRow.isHidden = !supportsRecording
    }

    func show(
        anchoredTo buttonRect: CGRect,
        barRect: CGRect,
        upperAvoidRect: CGRect?,
        visible: CGRect,
        triggerButton: NSView
    ) {
        self.triggerButton = triggerButton
        hideToken += 1
        contentView?.layoutSubtreeIfNeeded()

        let m = Self.shadowMargin
        let pillW = Self.panelWidth
        let pillH = max(68, ceil(contentStack.fittingSize.height))

        var x = buttonRect.midX - pillW / 2
        x = max(visible.minX + 8, min(x, visible.maxX - pillW - 8))

        let belowY = barRect.minY - Self.gapFromBar - pillH
        let y: CGFloat
        if belowY >= visible.minY + 8 {
            y = belowY
            openedBelowBar = true
        } else {
            var aboveY = barRect.maxY + Self.gapFromBar
            if let avoid = upperAvoidRect, avoid.minY >= barRect.maxY - 1 {
                aboveY = avoid.maxY + 6
            }
            y = min(aboveY, visible.maxY - pillH - 8)
            openedBelowBar = false
        }

        let targetFrame = CGRect(
            x: (x - m).rounded(),
            y: (y - m).rounded(),
            width: pillW + m * 2,
            height: pillH + m * 2
        )

        lastAnchorGlobalX = buttonRect.midX
        isShown = true
        installDismissMonitor()
        alphaValue = 1
        setFrame(targetFrame, display: true)
        contentView?.layoutSubtreeIfNeeded()
        outerShadowView.refreshGeometry()
        IslandMotion.reset(motionHost)
        orderFrontRegardless()
        IslandMotion.expand(
            motionHost,
            anchorGlobalX: buttonRect.midX,
            panelFrame: targetFrame,
            openedBelowBar: openedBelowBar,
            shadowMargin: m
        )
    }

    func hide(immediate: Bool) {
        removeDismissMonitor()
        guard isShown || isVisible else { return }
        isShown = false
        hideToken += 1
        let token = hideToken

        if immediate {
            IslandMotion.reset(motionHost)
            orderOut(nil)
            alphaValue = 1
            return
        }

        IslandMotion.collapse(
            motionHost,
            anchorGlobalX: lastAnchorGlobalX,
            panelFrame: frame,
            openedBelowBar: openedBelowBar,
            shadowMargin: Self.shadowMargin
        ) { [weak self] in
            guard let self, self.hideToken == token, !self.isShown else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            IslandMotion.reset(self.motionHost)
        }
    }

    private func installDismissMonitor() {
        removeDismissMonitor()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                let clickWin = event.window
                if clickWin === self { return }
                if let trigger = self.triggerButton, clickWin === trigger.window {
                    let ptInTrigger = trigger.convert(event.locationInWindow, from: nil)
                    if trigger.bounds.contains(ptInTrigger) {
                        return
                    }
                }
                self.hide(immediate: false)
            }
            return event
        }
    }

    private func removeDismissMonitor() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    @objc private func backdropTapped() {
        hide(immediate: false)
        onToggleBackdrop()
    }

    @objc private func recordGIFTapped() {
        hide(immediate: true)
        onRecordGIF()
    }

    @objc private func ocrTapped() {
        hide(immediate: true)
        onOCR()
    }

    @objc private func hideTapped() {
        hide(immediate: true)
        onToggleVisibility()
    }
}

@MainActor
private final class MoreMenuItemRowButton: NSButton {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView()
    private let kbdLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHot = false
    private var isPressed = false
    private var isChecked = false

    init(icon: TBIcon.Kind, title titleText: String, shortcut: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        iconView.image = TBIcon.image(icon, pointSize: 12.5)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.stringValue = titleText
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        checkView.image = TBIcon.symbolImage(named: "checkmark", pointSize: 10.5, weight: .bold, hierarchical: false)
        checkView.contentTintColor = DesignTokens.accent
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.isHidden = true
        addSubview(checkView)

        kbdLabel.stringValue = shortcut
        kbdLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        kbdLabel.alignment = .right
        kbdLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(kbdLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            kbdLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            kbdLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkView.trailingAnchor.constraint(equalTo: kbdLabel.leadingAnchor, constant: -6),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MoreMenuItemRowButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    func setChecked(_ checked: Bool) {
        isChecked = checked
        checkView.isHidden = !checked
        applyStyle()
    }

    func setShortcut(_ text: String) {
        kbdLabel.stringValue = text
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
        TactilePress.animate(view: self, pressed: true, scale: 0.97)
        super.mouseDown(with: event)
        isPressed = false
        TactilePress.animate(view: self, pressed: false)
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isPressed {
                layer?.backgroundColor = DesignTokens.fillPress.cgColor
            } else if isHot {
                layer?.backgroundColor = DesignTokens.fillHover.cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
            iconView.contentTintColor = isChecked ? DesignTokens.accent : (isHot ? DesignTokens.label1 : DesignTokens.label2)
            titleLabel.textColor = isChecked ? DesignTokens.accent : DesignTokens.label1
            kbdLabel.textColor = DesignTokens.label3
        }
    }
}
