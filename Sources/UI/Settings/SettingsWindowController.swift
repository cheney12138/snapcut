import AppKit

/// 设置窗口（重设计 v2：工具栏同款「恒定浅色高晶玻璃」语言）
///
/// 设计决策（对齐 ToolbarPanel 已实锤稳定的配方，真源 tokens.md §2/§9）：
/// - 窗体钉 `.aqua` 浅色 + 全窗 `.menu` 澄澈磨砂铺底（含 titlebar），
///   分组卡 = `CrystalGlassContainer`（晶透玻璃 + OuterShadowView 双层光学影）
///   ——与工具栏同一条玻璃曲线，深色桌面背景下不再是一坨灰泥
/// - 四 tab 不用系统 NSToolbar（icon+label 的 system chrome 与本套玻璃语言不搭）：
///   窗顶居中玻璃槽段选器（GlassSegmentedControl，选中胶囊 CASpring 420/28/0.85
///   滑移，与工具栏选中指示层同物理）；窗口高度随 tab 内容动画收放
/// - 控件全套玻璃化（SettingsGlassControls.swift）：
///   NSSwitch→GlassSwitch（玻璃轨道+晶透旋钮）、NSPopUpButton→GlassPopUpButton、
///   NSSegmentedControl→GlassSegmentedControl、按钮→GlassMiniButton/GlassIconButton、
///   热键录制器→GlassHotkeyRecorderView（录制态 accent 环+呼吸点，逻辑不变）
/// - 信息架构重排（旧版通用页 6 卡一坨滚动表单）：
///   「通用」= 启动/截图/历史/通知（4 卡 8 行，一屏放下不滚动）
///   「工具栏」= 大小档位 + 排序（独立 tab，排序不再挤通用页）
///   「快捷键」= 全局 3 + 视觉记忆 4 + 编辑器 9（编辑器热键双列网格，行数 9→5）
///   「关于」= 图标/版本/权限状态卡
/// - 无「确定/取消」：任何控件改动立即 store.save，窗口关闭即生效（沿用旧语义）
/// - 六边形纪律：只依赖端口 `SettingsStoring`，适配器由合成根注入（主会话接线）
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSControlTextEditingDelegate {

    static let shared = SettingsWindowController()

    // MARK: - 状态

    private var store: (any SettingsStoring)?
    private var settings = AppSettings.defaultSettings

    private var windowBuilt = false
    private var panesBuilt = false

    private var tabRail: GlassTabRail!
    private let generalPane = NSView()
    private let toolbarPane = NSView()
    private let hotkeyPane = NSView()
    private let aboutPane = NSView()
    private var permStatusDot: NSView?
    private var permButtonRef: GlassMiniButton?
    private var permHintRef: NSTextField?
    private var permStatusLabel: NSTextField?
    private var updateSwitch: GlassSwitch!
    private var updateNoteLabel: NSTextField!

    // 通用 tab 控件
    private var launchAtLoginSwitch: GlassSwitch!
    private var launchAtLoginHintRow: NSView!
    private var launchAtLoginHintLabel: NSTextField!
    private var launchAtLoginOpenBtn: GlassMiniButton!
    private var afterCapturePopup: GlassPopUpButton!
    private var pathField: NSTextField!
    private var filenamePopup: GlassPopUpButton!
    private var historyField: NSTextField!
    private var historyStepper: NSStepper!
    private var autoIndexOCRSwitch: GlassSwitch!
    private var notifySwitch: GlassSwitch!
    private var soundSwitch: GlassSwitch!

    // 工具栏 tab 控件
    private var toolbarSizeSegment: GlassSegmentedControl!

    // 快捷键 tab 控件
    private var regionRecorder: GlassHotkeyRecorderView!
    private var fullScreenRecorder: GlassHotkeyRecorderView!
    private var historySpotlightRecorder: GlassHotkeyRecorderView!
    /// 编辑器热键（工具栏后半段 9 动作）录制器，key = action key
    private var editorRecorders: [String: GlassHotkeyRecorderView] = [:]
    /// 视觉记忆面板操作热键录制器，key = action key
    private var spotlightRecorders: [String: GlassHotkeyRecorderView] = [:]
    private var hotkeyHint: NSTextField!

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: - 打开

    /// 截图期间退场（OverlayController.begin 调用；窗可见时 orderOut——
    /// .regular App 的 activate 会把设置窗顶到 overlay 上挡截图内容）
    var isVisible: Bool { window?.isVisible ?? false }

    func orderOutForCapture() {
        window?.orderOut(nil)
        Log.event(.app, "settings.window.orderOutForCapture")
    }

    /// 截图会话结束回场（OverlayController.end 调用；仅恢复可见性，不重建）
    func restoreAfterCapture() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        window.orderFront(nil)
        Log.event(.app, "settings.window.restoreAfterCapture")
    }

    func show(store: SettingsStoring) {
        self.store = store
        settings = store.load()
        ensureWindow()
        refreshControls()
        // 病例：权限状态只在 buildAboutPane 时刷过一次（首次 open），用户事后
        // 授权再开窗口仍显示「未授权」旧文案——每次 open 都要重刷
        refreshPermissionStatus()
        refreshUpdateStatus()
        // LSUIElement（.accessory 策略）下，系统协作激活不会真正把 App 切到前台：
        // 设置窗看起来在前，但用户一点面板，焦点就被让回之前的 App（窗「退后台」）。
        // 设置窗打开期间临时切 .regular，关闭时还原。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            let origin = DisplayRegistry.centerOrigin(for: window.frame.size)
            window.setFrameOrigin(origin)
        }
        window?.makeKeyAndOrderFront(nil)
        Log.event(.app, "settings.window.open")
    }

    // MARK: - 窗口构建

    /// 布局：左导航栏（196pt）+ 右内容区（行宽 448）。
    /// 窗高随 tab 内容收放；pane 高按内容实测量身定制
    /// （通用 4 卡 8 行 ~585 / 工具栏 2 卡 ~450 / 快捷键 3 卡 ~700 / 关于 ~320）
    private static let sidebarWidth: CGFloat = 196
    private static let contentWidth: CGFloat = 560
    private static let paneHeights: [CGFloat] = [600, 470, 710, 380]
    /// 内容区上下边距
    private static let contentInsetV: CGFloat = 24

    private func ensureWindow() {
        if !panesBuilt {
            panesBuilt = true
            buildPanes()
        }
        guard !windowBuilt else { return }
        windowBuilt = true

        let totalWidth = Self.sidebarWidth + Self.contentWidth
        let initialSize = CGSize(
            width: totalWidth,
            height: Self.paneHeights[0] + Self.contentInsetV * 2
        )
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Snapcut 设置"
        win.isReleasedWhenClosed = false
        // 恒定浅色高晶玻璃（工具栏同配方）：钉 .aqua 让前景控件解析亮外观动态色；
        // titlebar 透明 + fullSizeContentView 让磨砂满铺含 titlebar；
        // title 只留给 WindowServer/AX（e2e 靠它定位），视觉隐藏由自定义侧栏接管
        win.appearance = NSAppearance(named: .aqua)
        win.titlebarAppearsTransparent = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        container.wantsLayer = true

        // 档 3 窗底：全窗澄澈磨砂铺底（含 titlebar 区域）——`.aqua` 下 .menu 高通透
        let windowGlass = AdaptiveGlassView(
            cornerRadius: 0,
            strokeWidth: 0,
            dynamicStrokeColor: .clear
        )
        windowGlass.appearance = NSAppearance(named: .aqua)
        windowGlass.material = .menu
        windowGlass.blendingMode = .behindWindow
        windowGlass.state = .active
        windowGlass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(windowGlass)
        NSLayoutConstraint.activate([
            windowGlass.topAnchor.constraint(equalTo: container.topAnchor),
            windowGlass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            windowGlass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            windowGlass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // 左侧栏：窗口标题（顶部，红绿灯同高呼吸）+ 竖向 tab 栏（选中胶囊弹簧滑移）
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
        ])

        let titleLabel = NSTextField(labelWithString: "设置")
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = DesignTokens.label1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
        ])

        tabRail = GlassTabRail(items: [
            .init(title: "通用", symbol: "gearshape"),
            .init(title: "工具栏", symbol: "menubar.rectangle"),
            .init(title: "快捷键", symbol: "command"),
            .init(title: "关于", symbol: "info.circle"),
        ])
        tabRail.onSelect = { [weak self] index in self?.selectTab(index) }
        tabRail.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tabRail)
        NSLayoutConstraint.activate([
            tabRail.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tabRail.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabRail.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
        ])

        // 侧栏与内容区间的 0.5pt hairline（token hair，满高）
        let divider = SettingsHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.5),
        ])

        // 内容区四个 pane（等大小叠放切 isHidden，无闪烁）
        for pane in [generalPane, toolbarPane, hotkeyPane, aboutPane] {
            container.addSubview(pane)
            pane.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
                pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                pane.topAnchor.constraint(equalTo: container.topAnchor),
                pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        win.contentView = container
        window = win
        selectTab(0, animated: false)
    }

    // MARK: - Tab 切换（motion.crossfade：0.15s fade + 新 pane rise 4pt；窗口高度顺滑跟随）

    private func selectTab(_ index: Int, animated: Bool = true) {
        let panes = [generalPane, toolbarPane, hotkeyPane, aboutPane]
        guard panes.indices.contains(index) else { return }
        tabRail?.setSelectedIndex(index, animated: animated)
        let incoming = panes[index]
        let wasHidden = incoming.isHidden
        for (i, pane) in panes.enumerated() where i != index {
            pane.isHidden = true
        }
        // 窗口高度跟随 tab 内容（宽度恒定，顶缘锚定，底部收放；出屏夹回）
        if let window, Self.paneHeights.indices.contains(index) {
            let targetHeight = Self.paneHeights[index] + Self.contentInsetV * 2
            if abs(window.frame.height - targetHeight) > 0.5 {
                var frame = window.frame
                frame.origin.y += frame.height - targetHeight
                frame.size.height = targetHeight
                // 出屏夹回：变高后底缘低于可见区时整体上移；顶缘越界再压回
                if let screen = window.screen ?? NSScreen.main {
                    let visible = screen.visibleFrame
                    if frame.minY < visible.minY + 12 {
                        frame.origin.y = visible.minY + 12
                    }
                    if frame.maxY > visible.maxY - 8 {
                        frame.origin.y = min(frame.origin.y, visible.maxY - 8 - frame.height)
                    }
                }
                if animated {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = DesignTokens.Motion.crossfadeDuration
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        window.animator().setFrame(frame, display: true)
                    }
                } else {
                    window.setFrame(frame, display: false)
                }
            }
        }
        guard wasHidden else { return }
        incoming.isHidden = false
        guard animated else {
            incoming.alphaValue = 1
            return
        }
        incoming.alphaValue = 0
        incoming.wantsLayer = true
        if let layer = incoming.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeTranslation(0, -4, 0)
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.crossfadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            incoming.animator().alphaValue = 1
        }
        if let layer = incoming.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.crossfadeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    // MARK: - 窗口关闭：退出录制态（设置本身已即时保存，无需收尾）

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermissionStatus()
        refreshUpdateStatus()
        refreshLaunchAtLoginStatus()
    }

    func windowWillClose(_ notification: Notification) {
        regionRecorder?.endRecordingIfNeeded()
        fullScreenRecorder?.endRecordingIfNeeded()
        historySpotlightRecorder?.endRecordingIfNeeded()
        for r in editorRecorders.values { r.endRecordingIfNeeded() }
        // 设置窗关闭：还原 LSUIElement 形态（show() 里临时切的 .regular）
        NSApp.setActivationPolicy(.accessory)
        Log.event(.app, "settings.window.close")
    }

    // MARK: - Panes 构建

    private func buildPanes() {
        buildGeneralPane()
        buildToolbarPane()
        buildHotkeyPane()
        buildAboutPane()
    }

    // MARK: - 通用 tab（启动 / 截图 / 历史 / 通知，4 卡 8 行一屏放下）

    private func buildGeneralPane() {
        // 登录时自动启动（SMAppService.mainApp 原生登录项）
        launchAtLoginSwitch = GlassSwitch()
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginToggled(_:))

        launchAtLoginHintLabel = NSTextField(labelWithString: "")
        launchAtLoginHintLabel.font = DesignTokens.Font.note
        launchAtLoginHintLabel.textColor = .secondaryLabelColor
        launchAtLoginHintLabel.lineBreakMode = .byWordWrapping
        launchAtLoginHintLabel.translatesAutoresizingMaskIntoConstraints = false

        launchAtLoginOpenBtn = GlassMiniButton(title: "打开登录项…")
        launchAtLoginOpenBtn.target = self
        launchAtLoginOpenBtn.action = #selector(openLoginItemsSettings)

        let hintSpacer = NSView()
        hintSpacer.translatesAutoresizingMaskIntoConstraints = false
        hintSpacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let hintStack = NSStackView(views: [launchAtLoginHintLabel, hintSpacer, launchAtLoginOpenBtn])
        hintStack.orientation = .horizontal
        hintStack.alignment = .centerY
        hintStack.spacing = 8
        hintStack.translatesAutoresizingMaskIntoConstraints = false
        hintStack.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        launchAtLoginHintRow = hintStack
        launchAtLoginHintRow.isHidden = true

        let startupRowStack = NSStackView(views: [
            row("登录时自动启动", trailing: [launchAtLoginSwitch]),
            launchAtLoginHintRow,
        ])
        startupRowStack.orientation = .vertical
        startupRowStack.alignment = .leading
        startupRowStack.spacing = 6

        let startupCard = makeGroupCard(title: "启动", rows: [startupRowStack])

        // 截图完成后
        afterCapturePopup = GlassPopUpButton()
        afterCapturePopup.translatesAutoresizingMaskIntoConstraints = false
        afterCapturePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        afterCapturePopup.configure(
            items: AppSettings.AfterCaptureAction.allCases.map { (Self.afterCaptureLabel($0), $0.rawValue) },
            selectedRawValue: settings.afterCapture.rawValue
        )
        afterCapturePopup.onSelect = { [weak self] raw in
            self?.afterCaptureChanged(raw)
        }

        // 保存目录（只读展示 + 选择…）
        pathField = NSTextField(string: "~/Pictures/Snapcut")
        pathField.isEditable = false
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.font = DesignTokens.Font.note
        pathField.textColor = DesignTokens.label2
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let chooseButton = GlassMiniButton(title: "选择…")
        chooseButton.target = self
        chooseButton.action = #selector(chooseDirectory(_:))

        // 文件名
        filenamePopup = GlassPopUpButton()
        filenamePopup.translatesAutoresizingMaskIntoConstraints = false
        filenamePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        filenamePopup.configure(
            items: AppSettings.FilenameStyle.allCases.map { (Self.filenameLabel($0), $0.rawValue) },
            selectedRawValue: settings.filenameStyle.rawValue
        )
        filenamePopup.onSelect = { [weak self] raw in
            self?.filenameChanged(raw)
        }

        // 历史保留：输入框 + NSStepper 联动（1–200）
        historyField = NSTextField(string: "30")
        historyField.alignment = .center
        historyField.font = DesignTokens.Font.monoDigit(12)
        historyField.isBezeled = true
        historyField.bezelStyle = .roundedBezel
        historyField.translatesAutoresizingMaskIntoConstraints = false
        historyField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        historyField.target = self
        historyField.action = #selector(historyFieldSubmitted(_:))

        historyStepper = NSStepper()
        historyStepper.minValue = Double(AppSettings.historyLimitRange.lowerBound)
        historyStepper.maxValue = Double(AppSettings.historyLimitRange.upperBound)
        historyStepper.increment = 1
        historyStepper.doubleValue = 30
        historyStepper.target = self
        historyStepper.action = #selector(historyStepperChanged(_:))

        let unitLabel = NSTextField(labelWithString: "条")
        unitLabel.font = DesignTokens.Font.note
        unitLabel.textColor = DesignTokens.label2

        // 开关
        autoIndexOCRSwitch = GlassSwitch()
        autoIndexOCRSwitch.target = self
        autoIndexOCRSwitch.action = #selector(autoIndexOCRToggled(_:))
        notifySwitch = GlassSwitch()
        notifySwitch.target = self
        notifySwitch.action = #selector(notifyToggled(_:))
        soundSwitch = GlassSwitch()
        soundSwitch.target = self
        soundSwitch.action = #selector(soundToggled(_:))

        // 四张晶透分组卡（8pt 栅格：卡间距 14，卡内边距 16）
        let captureCard = makeGroupCard(title: "截图", rows: [
            row("截图完成后", trailing: [afterCapturePopup]),
            row("保存目录", trailing: [pathField, chooseButton]),
            row("文件名", trailing: [filenamePopup]),
        ])
        let historyCard = makeGroupCard(title: "历史", rows: [
            row("历史保留", trailing: [historyField, unitLabel, historyStepper]),
            row("后台自动识别历史文字", trailing: [autoIndexOCRSwitch]),
        ])
        let notifyCard = makeGroupCard(title: "通知", rows: [
            row("复制后显示通知", trailing: [notifySwitch]),
            row("截图音效", trailing: [soundSwitch]),
        ])

        let outer = NSStackView(views: [startupCard, captureCard, historyCard, notifyCard])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 14
        outer.edgeInsets = NSEdgeInsets(top: Self.contentInsetV, left: 24, bottom: Self.contentInsetV, right: 24)
        pinStack(outer, to: generalPane)
    }

    // MARK: - 工具栏 tab（大小档位 + 排序）

    private func buildToolbarPane() {
        // 工具栏大小档位（玻璃段选器，弹簧滑动选中胶囊，即时生效）
        toolbarSizeSegment = GlassSegmentedControl(titles: ["紧凑", "标准", "大号"])
        toolbarSizeSegment.onSelect = { [weak self] index in
            self?.toolbarSizeChanged(index)
        }

        let appearanceCard = makeGroupCard(title: "外观", rows: [
            row("工具栏大小", trailing: [toolbarSizeSegment]),
        ])

        // 工具栏排序（行序 = toolbarOrder；chevron 玻璃图标按钮调序即时生效）
        let orderCard = makeGroupCard(title: "排序", rows: buildToolbarOrderRows())

        let outer = NSStackView(views: [appearanceCard, orderCard])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 14
        outer.edgeInsets = NSEdgeInsets(top: Self.contentInsetV, left: 24, bottom: Self.contentInsetV, right: 24)
        pinStack(outer, to: toolbarPane)
    }

    /// 工具栏排序行（chevron 玻璃图标按钮调序；改动即 persist + 工具栏重建在下次会话生效）
    private func buildToolbarOrderRows() -> [NSView] {
        var rows: [NSView] = []
        let order = settings.toolbarOrderSafe()
        for (idx, raw) in order.enumerated() {
            let name = EditorSession.Tool(rawValue: raw)?.label ?? "未知(\(raw))"

            let indexLabel = NSTextField(labelWithString: "\(idx + 1)")
            indexLabel.font = DesignTokens.Font.monoDigit(11)
            indexLabel.textColor = DesignTokens.label3
            indexLabel.alignment = .right
            indexLabel.translatesAutoresizingMaskIntoConstraints = false
            indexLabel.widthAnchor.constraint(equalToConstant: 16).isActive = true

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = DesignTokens.Font.body
            nameLabel.textColor = DesignTokens.label1

            let up = GlassIconButton(symbolName: "chevron.up")
            up.target = self
            up.action = #selector(toolbarOrderTapped(_:))
            up.isEnabled = idx > 0
            up.tag = raw * 10 + 0   // delta=-1 编码为末位 0

            let down = GlassIconButton(symbolName: "chevron.down")
            down.target = self
            down.action = #selector(toolbarOrderTapped(_:))
            down.isEnabled = idx < order.count - 1
            down.tag = raw * 10 + 2   // delta=+1 编码为末位 2

            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)

            let stack = NSStackView(views: [indexLabel, nameLabel, spacer, up, down])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
            stack.heightAnchor.constraint(equalToConstant: DesignTokens.Settings.rowHeight).isActive = true
            rows.append(stack)
        }
        return rows
    }

    @objc private func toolbarOrderTapped(_ sender: NSButton) {
        let raw = sender.tag / 10
        let delta = (sender.tag % 10) - 1   // 编码：末位 0=-1，2=+1
        moveToolbarOrder(raw, delta: delta)
    }

    /// 调序：toolbarOrder 里把 raw 上/下移，persist 即时生效
    private func moveToolbarOrder(_ raw: Int, delta: Int) {
        var normalized = settings.toolbarOrderSafe()
        guard let idx = normalized.firstIndex(of: raw) else { return }
        let target = idx + delta
        guard target >= 0, target < normalized.count else { return }
        normalized.swapAt(idx, target)
        settings.toolbarOrder = normalized
        Log.event(.app, "settings.toolbarOrder", ["moved": "\(raw)", "to": "\(target)"])
        persist()
        rebuildToolbarPane()
    }

    /// 排序卡整页重建（行序即时反映）：工具栏页清空重 build + 切回显示
    private func rebuildToolbarPane() {
        toolbarPane.subviews.forEach { $0.removeFromSuperview() }
        buildToolbarPane()
        refreshControls()
        selectTab(1, animated: false)
    }

    // MARK: - 通用 tab 动作

    @objc private func launchAtLoginToggled(_ sender: GlassSwitch) {
        let wantEnable = sender.isOn
        switch LaunchAtLoginManager.setEnabled(wantEnable) {
        case .success(let status):
            applyLaunchAtLoginStatus(status, errorMessage: nil)
        case .failure(let error):
            applyLaunchAtLoginStatus(LaunchAtLoginManager.status, errorMessage: "设置失败：\(error.localizedDescription)")
        }
    }

    @objc private func openLoginItemsSettings() {
        LaunchAtLoginManager.openSystemSettingsLoginItems()
    }

    private func refreshLaunchAtLoginStatus() {
        guard launchAtLoginSwitch != nil else { return }
        applyLaunchAtLoginStatus(LaunchAtLoginManager.status, errorMessage: nil)
    }

    private func applyLaunchAtLoginStatus(_ status: LaunchAtLoginStatus, errorMessage: String?) {
        launchAtLoginSwitch.setOn(status == .enabled || status == .requiresApproval, animated: false)
        if let errorMessage {
            launchAtLoginHintLabel.stringValue = errorMessage
            launchAtLoginHintLabel.textColor = DesignTokens.statusError
            launchAtLoginOpenBtn.isHidden = false
            launchAtLoginHintRow.isHidden = false
        } else if status == .requiresApproval {
            launchAtLoginHintLabel.stringValue = "需在「系统设置 → 通用 → 登录项」中允许 Snapcut"
            launchAtLoginHintLabel.textColor = DesignTokens.statusWarn
            launchAtLoginOpenBtn.isHidden = false
            launchAtLoginHintRow.isHidden = false
        } else {
            launchAtLoginHintRow.isHidden = true
        }
    }

    private func toolbarSizeChanged(_ index: Int) {
        let all = AppSettings.ToolbarSize.allCases
        guard all.indices.contains(index) else { return }
        let chosen = all[index]
        guard settings.toolbarSize != chosen else { return }
        settings.toolbarSize = chosen
        Log.event(.app, "settings.toolbarSize", ["size": chosen.rawValue])
        persist()
    }

    private func afterCaptureChanged(_ raw: String) {
        guard let action = AppSettings.AfterCaptureAction(rawValue: raw) else { return }
        settings.afterCapture = action
        persist()
    }

    private func filenameChanged(_ raw: String) {
        guard let style = AppSettings.FilenameStyle(rawValue: raw) else { return }
        settings.filenameStyle = style
        persist()
    }

    @objc private func chooseDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: (settings.saveDirectoryPath as NSString).expandingTildeInPath
        )
        panel.message = "选择截图默认保存目录"
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectoryPath = url.path
            pathField.stringValue = url.path
            persist()
        }
    }

    @objc private func historyFieldSubmitted(_ sender: NSTextField) {
        syncHistoryField()
    }

    @objc private func historyStepperChanged(_ sender: NSStepper) {
        let value = Int(sender.doubleValue)
        historyField.stringValue = "\(value)"
        if settings.historyLimit != value {
            settings.historyLimit = value
            persist()
        }
    }

    // NSTextField 输入联动（controlTextDidChange，识别 control 用引用比对）
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === historyField else { return }
        syncHistoryField()
    }

    private func syncHistoryField() {
        guard let value = Int(historyField.stringValue) else { return }  // 输入未成形，不落盘
        let clamped = min(
            max(value, AppSettings.historyLimitRange.lowerBound),
            AppSettings.historyLimitRange.upperBound
        )
        historyStepper.doubleValue = Double(clamped)
        if settings.historyLimit != clamped {
            settings.historyLimit = clamped
            persist()
        }
    }

    @objc private func autoIndexOCRToggled(_ sender: GlassSwitch) {
        settings.autoIndexHistoryOCR = sender.isOn
        Log.event(.app, "settings.autoIndexOCR", ["enabled": "\(settings.autoIndexHistoryOCR)"])
        persist()
    }

    @objc private func notifyToggled(_ sender: GlassSwitch) {
        settings.showCopyNotification = sender.isOn
        persist()
    }

    @objc private func soundToggled(_ sender: GlassSwitch) {
        settings.playCaptureSound = sender.isOn
        persist()
        if settings.playCaptureSound {
            CaptureSoundPlayer.play(force: true)
        }
    }

    // MARK: - 快捷键 tab

    /// 编辑器热键行定义（顺序 = 工具栏后半段按钮序；scroll 键用户裁定并入本体系）
    private static let editorHotkeyRows: [(key: String, label: String)] = [
        ("undo", "撤销"),
        ("redo", "重做"),
        ("save", "保存"),
        ("done", "复制完成"),
        ("cancel", "取消截图"),
        ("ocr", "文字识别"),
        ("pin", "贴图"),
        ("toggleVisibility", "隐藏贴图"),
        ("scroll", "滚动截图"),
    ]

    /// 视觉记忆搜索面板操作热键行定义
    private static let spotlightHotkeyRows: [(key: String, label: String)] = [
        ("copyImage", "复制原图"),
        ("reopenEdit", "重新编辑"),
        ("pin", "贴图"),
        ("copyOCR", "复制文字"),
    ]

    private func buildHotkeyPane() {
        regionRecorder = GlassHotkeyRecorderView()
        fullScreenRecorder = GlassHotkeyRecorderView()
        historySpotlightRecorder = GlassHotkeyRecorderView()

        hotkeyHint = NSTextField(labelWithString: "")
        hotkeyHint.font = DesignTokens.Font.note
        hotkeyHint.textColor = DesignTokens.statusError
        hotkeyHint.isHidden = true

        wireGlobalRecorder(regionRecorder)
        wireGlobalRecorder(fullScreenRecorder)
        wireGlobalRecorder(historySpotlightRecorder)

        // 全局热键三行
        let card = makeGroupCard(title: "全局热键", rows: [
            row("区域截图", trailing: [regionRecorder]),
            row("全屏截图", trailing: [fullScreenRecorder]),
            row("视觉记忆搜索", trailing: [historySpotlightRecorder]),
        ])

        // 视觉记忆搜索浮窗内快捷键
        var spotlightRows: [NSView] = []
        for (actionKey, label) in Self.spotlightHotkeyRows {
            let rec = GlassHotkeyRecorderView()
            rec.allowReturnKey = true
            rec.setCombo(settings.spotlightHotkey(for: actionKey))
            wireSpotlightRecorder(rec, actionKey: actionKey)
            spotlightRecorders[actionKey] = rec
            spotlightRows.append(row(label, trailing: [rec]))
        }
        let spotlightCard = makeGroupCard(title: "视觉记忆面板（搜索浮窗内生效）", rows: spotlightRows)

        // 编辑器操作热键（双列网格：9 项 → 5 行，行高一致、录制器对齐）
        var editorRows: [NSView] = []
        var pendingUnits: [NSView] = []
        for (actionKey, label) in Self.editorHotkeyRows {
            let rec = GlassHotkeyRecorderView(width: Self.editorRecorderWidth)
            rec.allowBare = true
            rec.setCombo(settings.editorHotkey(for: actionKey))
            wireEditorRecorder(rec, actionKey: actionKey)
            editorRecorders[actionKey] = rec
            pendingUnits.append(hotkeyGridUnit(label: label, recorder: rec))
            if pendingUnits.count == 2 {
                editorRows.append(hotkeyGridRow(units: pendingUnits))
                pendingUnits = []
            }
        }
        if !pendingUnits.isEmpty {
            editorRows.append(hotkeyGridRow(units: pendingUnits))
        }
        let editorCard = makeGroupCard(title: "编辑器操作（截图编辑时生效）", rows: editorRows)

        // 提示容器：左缘对齐卡内行
        let hintWrap = NSView()
        hintWrap.translatesAutoresizingMaskIntoConstraints = false
        hintWrap.widthAnchor.constraint(equalToConstant: Self.rowWidth + 32).isActive = true
        hintWrap.addSubview(hotkeyHint)
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hotkeyHint.leadingAnchor.constraint(equalTo: hintWrap.leadingAnchor, constant: 16),
            hotkeyHint.topAnchor.constraint(equalTo: hintWrap.topAnchor),
            hotkeyHint.bottomAnchor.constraint(equalTo: hintWrap.bottomAnchor),
        ])

        let outer = NSStackView(views: [card, spotlightCard, editorCard, hintWrap])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 0
        outer.edgeInsets = NSEdgeInsets(top: Self.contentInsetV, left: 24, bottom: Self.contentInsetV, right: 24)
        outer.setCustomSpacing(14, after: card)
        outer.setCustomSpacing(14, after: spotlightCard)
        outer.setCustomSpacing(10, after: editorCard)
        pinStack(outer, to: hotkeyPane)
    }

    /// 双列热键网格单元：label(固定宽) + 录制器，单元等宽让两列录制器严格对齐
    private static let editorRecorderWidth: CGFloat = 132

    private func hotkeyGridUnit(label text: String, recorder: GlassHotkeyRecorderView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = DesignTokens.Font.body
        label.textColor = DesignTokens.label1
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, recorder])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.editorGridUnitWidth).isActive = true
        return stack
    }

    /// (448 − 列间距 16) / 2 = 216
    private static let editorGridUnitWidth: CGFloat = 216

    private func hotkeyGridRow(units: [NSView]) -> NSView {
        let stack = NSStackView(views: units)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: DesignTokens.Settings.rowHeight).isActive = true
        return stack
    }

    private func stopOtherRecorders(except current: GlassHotkeyRecorderView) {
        for other in [regionRecorder, fullScreenRecorder, historySpotlightRecorder] {
            if let other, other !== current {
                other.endRecordingIfNeeded()
            }
        }
        for r in editorRecorders.values where r !== current {
            r.endRecordingIfNeeded()
        }
        for r in spotlightRecorders.values where r !== current {
            r.endRecordingIfNeeded()
        }
        hotkeyHint.isHidden = true
    }

    private func wireSpotlightRecorder(_ recorder: GlassHotkeyRecorderView, actionKey: String) {
        recorder.onStart = { [weak self, weak recorder] in
            guard let self, let recorder else { return }
            self.stopOtherRecorders(except: recorder)
        }
        recorder.onCombo = { [weak self, weak recorder] combo in
            guard let self, let recorder else { return }
            self.handleSpotlightCombo(from: recorder, actionKey: actionKey, combo: combo)
        }
    }

    private func handleSpotlightCombo(from recorder: GlassHotkeyRecorderView, actionKey: String, combo: String?) {
        guard let combo else {
            hotkeyHint.stringValue = "组合无效：需含修饰键（如 ⌘E）、F 功能键或 Return"
            hotkeyHint.isHidden = false
            return
        }
        for rowDef in Self.spotlightHotkeyRows where rowDef.key != actionKey {
            if combosConflict(combo, settings.spotlightHotkey(for: rowDef.key)) {
                hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被视觉记忆「\(rowDef.label)」占用"
                hotkeyHint.isHidden = false
                return
            }
        }
        let globalSlots: [(combo: String, label: String)] = [
            (settings.hotkeyRegion, "区域截图（全局）"),
            (settings.hotkeyFullScreen, "全屏截图（全局）"),
            (settings.hotkeyHistorySpotlight, "视觉记忆搜索（全局）"),
        ]
        for slot in globalSlots where combosConflict(combo, slot.combo) {
            hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被「\(slot.label)」占用"
            hotkeyHint.isHidden = false
            return
        }
        hotkeyHint.isHidden = true
        var hotkeys = settings.spotlightHotkeys
        if hotkeys.isEmpty { hotkeys = AppSettings.defaultSpotlightHotkeys }
        hotkeys[actionKey] = combo
        settings.spotlightHotkeys = hotkeys
        recorder.setCombo(combo)
        Log.event(.app, "settings.spotlightHotkey", ["action": actionKey, "combo": combo])
        persist()
    }

    /// 编辑器热键录制：进入录制时停掉所有其他录制器
    private func wireEditorRecorder(_ recorder: GlassHotkeyRecorderView, actionKey: String) {
        recorder.onStart = { [weak self, weak recorder] in
            guard let self, let recorder else { return }
            self.stopOtherRecorders(except: recorder)
        }
        recorder.onCombo = { [weak self, weak recorder] combo in
            guard let self, let recorder else { return }
            self.handleEditorCombo(from: recorder, actionKey: actionKey, combo: combo)
        }
    }

    private func handleEditorCombo(from recorder: GlassHotkeyRecorderView, actionKey: String, combo: String?) {
        guard let combo else {
            hotkeyHint.stringValue = "组合无效：需含修饰键，或单个字母/数字键"
            hotkeyHint.isHidden = false
            return
        }
        // 冲突检查：其他编辑器动作 + 全局热键 + 内置保留键（C=取色 / 空格=移动 / ⌘⌥S=快存）
        for rowDef in Self.editorHotkeyRows where rowDef.key != actionKey {
            if combosConflict(combo, settings.editorHotkey(for: rowDef.key)) {
                hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被「\(rowDef.label)」占用"
                hotkeyHint.isHidden = false
                return
            }
        }
        let globalSlots: [(combo: String, label: String)] = [
            (settings.hotkeyRegion, "区域截图（全局）"),
            (settings.hotkeyFullScreen, "全屏截图（全局）"),
            (settings.hotkeyHistorySpotlight, "视觉记忆搜索（全局）"),
        ]
        for slot in globalSlots where combosConflict(combo, slot.combo) {
            hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被「\(slot.label)」占用"
            hotkeyHint.isHidden = false
            return
        }
        let reserved: [String: String] = ["c": "取色", "space": "移动贴图", "cmd+opt+s": "快速保存"]
        if let name = reserved.first(where: { combosConflict(combo, $0.key) })?.value {
            hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」是内置功能「\(name)」的按键，请换一个"
            hotkeyHint.isHidden = false
            return
        }
        hotkeyHint.isHidden = true
        var hotkeys = settings.editorHotkeys
        if hotkeys.isEmpty { hotkeys = AppSettings.defaultEditorHotkeys }
        hotkeys[actionKey] = combo
        settings.editorHotkeys = hotkeys
        recorder.setCombo(combo)
        Log.event(.app, "settings.editorHotkey", ["action": actionKey, "combo": combo])
        persist()
    }

    private func wireGlobalRecorder(_ recorder: GlassHotkeyRecorderView) {
        recorder.onStart = { [weak self, weak recorder] in
            guard let self, let recorder else { return }
            self.stopOtherRecorders(except: recorder)
        }
        recorder.onCombo = { [weak self, weak recorder] combo in
            guard let self, let recorder else { return }
            self.handleCombo(from: recorder, combo)
        }
    }

    /// 录制结果落设置：nil = 非法（缺修饰键）→ 红字提示不崩；占用 → 红字提示
    private func handleCombo(from recorder: GlassHotkeyRecorderView, _ combo: String?) {
        guard let combo else {
            hotkeyHint.stringValue = "组合无效：必须包含至少一个修饰键（⌘ / ⇧ / ⌥ / ⌃）"
            hotkeyHint.isHidden = false
            return
        }
        let slot: String
        let otherGlobals: [(combo: String, label: String)]
        if recorder === regionRecorder {
            slot = "region"
            otherGlobals = [
                (settings.hotkeyFullScreen, "全屏截图"),
                (settings.hotkeyHistorySpotlight, "视觉记忆搜索"),
            ]
        } else if recorder === fullScreenRecorder {
            slot = "fullScreen"
            otherGlobals = [
                (settings.hotkeyRegion, "区域截图"),
                (settings.hotkeyHistorySpotlight, "视觉记忆搜索"),
            ]
        } else {
            slot = "historySpotlight"
            otherGlobals = [
                (settings.hotkeyRegion, "区域截图"),
                (settings.hotkeyFullScreen, "全屏截图"),
            ]
        }
        for other in otherGlobals where combosConflict(combo, other.combo) {
            hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被「\(other.label)」占用"
            hotkeyHint.isHidden = false
            return
        }
        for rowDef in Self.editorHotkeyRows where combosConflict(combo, settings.editorHotkey(for: rowDef.key)) {
            hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被编辑器「\(rowDef.label)」占用"
            hotkeyHint.isHidden = false
            return
        }
        hotkeyHint.isHidden = true
        if recorder === regionRecorder {
            settings.hotkeyRegion = combo
            regionRecorder.setCombo(combo)
        } else if recorder === fullScreenRecorder {
            settings.hotkeyFullScreen = combo
            fullScreenRecorder.setCombo(combo)
        } else {
            settings.hotkeyHistorySpotlight = combo
            historySpotlightRecorder.setCombo(combo)
        }
        Log.event(.app, "settings.hotkey", [
            "slot": slot,
            "combo": combo,
        ])
        persist()
    }

    /// 语义化热键比较：兼容修饰键顺序差异（如 "opt+cmd+v" 与 "cmd+opt+v"）
    private func combosConflict(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        if let l = HotkeySpec.parse(lhs, allowBare: true),
           let r = HotkeySpec.parse(rhs, allowBare: true) {
            return l == r
        }
        return false
    }

    // MARK: - 关于 tab

    private func buildAboutPane() {
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let nameLabel = NSTextField(labelWithString: "Snapcut")
        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.textColor = DesignTokens.label1

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let versionLabel = NSTextField(labelWithString: "版本 \(version)")
        versionLabel.font = DesignTokens.Font.body
        versionLabel.textColor = DesignTokens.label2

        let tagline = NSTextField(labelWithString: "本地运行 · 无账户 · 不联网")
        tagline.font = DesignTokens.Font.note
        tagline.textColor = DesignTokens.label3

        // 权限状态行（状态点 + 文案 + 玻璃按钮，整体居中于卡内）
        let statusDot = NSView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        permStatusDot = statusDot

        let statusLabel = NSTextField(labelWithString: "检查中…")
        statusLabel.font = DesignTokens.Font.body
        statusLabel.textColor = DesignTokens.label1
        permStatusLabel = statusLabel

        let permButton = GlassMiniButton(title: "去授权…")
        permButton.target = self
        permButton.action = #selector(openPermissionSettings)
        permButtonRef = permButton

        let leftSpring = NSView()
        leftSpring.translatesAutoresizingMaskIntoConstraints = false
        leftSpring.setContentHuggingPriority(.init(1), for: .horizontal)
        let rightSpring = NSView()
        rightSpring.translatesAutoresizingMaskIntoConstraints = false
        rightSpring.setContentHuggingPriority(.init(1), for: .horizontal)

        let permRow = NSStackView(views: [leftSpring, statusDot, statusLabel, permButton, rightSpring])
        permRow.orientation = .horizontal
        permRow.alignment = .centerY
        permRow.spacing = 8
        permRow.translatesAutoresizingMaskIntoConstraints = false

        let permHint = NSTextField(labelWithString: "")
        permHint.font = DesignTokens.Font.note
        permHint.textColor = DesignTokens.label2
        permHint.alignment = .center
        permHintRef = permHint

        // 权限状态卡：与通用/快捷键页同一晶透玻璃卡（宽度贴合内容，居中）
        let permCard = CrystalGlassContainer(cornerRadius: 12, tintAlpha: 0.08, shadowMargin: 10)
        let permStack = NSStackView(views: [permRow, permHint])
        permStack.orientation = .vertical
        permStack.alignment = .centerX
        permStack.spacing = 6
        permStack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        permStack.translatesAutoresizingMaskIntoConstraints = false
        permCard.contentContainer.addSubview(permStack)
        NSLayoutConstraint.activate([
            permStack.topAnchor.constraint(equalTo: permCard.contentContainer.topAnchor),
            permStack.bottomAnchor.constraint(equalTo: permCard.contentContainer.bottomAnchor),
            permStack.leadingAnchor.constraint(equalTo: permCard.contentContainer.leadingAnchor),
            permStack.trailingAnchor.constraint(equalTo: permCard.contentContainer.trailingAnchor),
            permStack.widthAnchor.constraint(equalToConstant: 320),
        ])

        let stack = NSStackView(views: [
            iconView, nameLabel, versionLabel, tagline,
            permCard,
            buildUpdateCard(),
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(4, after: versionLabel)
        stack.setCustomSpacing(28, after: tagline)
        stack.setCustomSpacing(12, after: permCard)
        stack.translatesAutoresizingMaskIntoConstraints = false
        aboutPane.addSubview(stack)
        // 关于页内容垂直居中于 pane（sidebar 布局下 top 锚定会显秃）
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: aboutPane.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: aboutPane.centerYAnchor, constant: -10),
        ])
        refreshPermissionStatus()
    }

    /// 权限状态刷新（打开窗口 / 每次 buildAbout 时调用）
    @MainActor
    private func refreshPermissionStatus() {
        let granted = AppCoordinatorShared.deps?.permission.isGranted() ?? false
        if granted {
            permStatusDot?.layer?.backgroundColor = DesignTokens.statusOK.cgColor
            permStatusLabel?.stringValue = "已授权"
            permButtonRef?.isHidden = true
            permHintRef?.stringValue = "权限正常，全局热键随时可用"
            Log.event(.app, "settings.permission", ["state": "granted"])
        } else {
            permStatusDot?.layer?.backgroundColor = DesignTokens.statusWarn.cgColor
            permStatusLabel?.stringValue = "未授权（截屏不可用）"
            permButtonRef?.isHidden = false
            permHintRef?.stringValue = "未授权时无法截屏；授权后需重启 Snapcut"
            Log.event(.app, "settings.permission", ["state": "denied"])
        }
    }

    /// 更新卡（与权限卡同宽 320）：手动检查 + 每日自动检查开关 + 上次检查时间
    ///
    /// 反馈全部交给 Sparkle 自己的窗口/弹窗（进度、已是最新、发现新版本），
    /// 我们只负责起点和开关——自己再画一套「正在检查…」的状态机，等于把
    /// Sparkle 已经做对的事重做一遍，且状态一定会对不上。
    private func buildUpdateCard() -> CrystalGlassContainer {
        updateSwitch = GlassSwitch()
        updateSwitch.target = self
        updateSwitch.action = #selector(updateAutoToggled(_:))

        let checkButton = GlassMiniButton(title: "检查更新…")
        checkButton.target = self
        checkButton.action = #selector(checkForUpdatesClicked)

        let updateNoteLabel = NSTextField(labelWithString: "")
        updateNoteLabel.font = DesignTokens.Font.note
        updateNoteLabel.textColor = DesignTokens.label3
        updateNoteLabel.lineBreakMode = .byWordWrapping
        updateNoteLabel.alignment = .center
        self.updateNoteLabel = updateNoteLabel

        let card = CrystalGlassContainer(cornerRadius: 12, tintAlpha: 0.08, shadowMargin: 10)
        let rows = NSStackView(views: [
            aboutRow("检查更新", trailing: [checkButton]),
            SettingsHairlineView(),
            aboutRow("每日自动检查", trailing: [updateSwitch]),
            updateNoteLabel,
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        rows.setCustomSpacing(6, after: rows.views[0])
        rows.setCustomSpacing(6, after: rows.views[1])
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
            rows.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
            rows.widthAnchor.constraint(equalToConstant: 320),
        ])
        return card
    }

    /// 关于页的行（宽度由卡片固定 320 决定，不像通用页那样写死 448）
    private func aboutRow(_ labelText: String, trailing: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: labelText)
        label.font = DesignTokens.Font.body
        label.textColor = DesignTokens.label1

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [label, spacer] + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Spacing.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return stack
    }

    @objc private func checkForUpdatesClicked() {
        AppCoordinatorShared.deps?.updating.checkForUpdates()
        // Sparkle 的窗口是异步出现的，回来刷一下上次检查时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshUpdateStatus()
        }
    }

    @objc private func updateAutoToggled(_ sender: GlassSwitch) {
        AppCoordinatorShared.deps?.updating.automaticallyChecksForUpdates = sender.isOn
        refreshUpdateStatus()
    }

    /// 更新状态回填（打开窗口 / 切换 tab 时调用）
    @MainActor
    private func refreshUpdateStatus() {
        guard let updating = AppCoordinatorShared.deps?.updating else {
            updateSwitch?.setOn(false, animated: false)
            updateNoteLabel?.stringValue = "更新服务未就绪"
            return
        }
        updateSwitch?.setOn(updating.automaticallyChecksForUpdates, animated: false)
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        updateNoteLabel?.stringValue = updating.lastCheckDescription
            .map { "当前 \(version) · \($0)" } ?? "当前 \(version) · 每日自动检查一次"
    }

    @objc private func openPermissionSettings() {
        TCCPermission.openSystemSettings()
    }

    // MARK: - 刷新（打开窗口时从设置回填控件）

    private func refreshControls() {
        refreshLaunchAtLoginStatus()
        if let idx = AppSettings.ToolbarSize.allCases.firstIndex(of: settings.toolbarSize) {
            toolbarSizeSegment?.setSelectedIndex(idx, animated: false)
        }
        afterCapturePopup?.select(rawValue: settings.afterCapture.rawValue)
        filenamePopup?.select(rawValue: settings.filenameStyle.rawValue)
        pathField.stringValue = settings.saveDirectoryPath
        historyField.stringValue = "\(settings.historyLimit)"
        historyStepper.doubleValue = Double(
            min(max(settings.historyLimit, AppSettings.historyLimitRange.lowerBound),
                AppSettings.historyLimitRange.upperBound)
        )
        autoIndexOCRSwitch?.setOn(settings.autoIndexHistoryOCR, animated: false)
        notifySwitch.setOn(settings.showCopyNotification, animated: false)
        soundSwitch.setOn(settings.playCaptureSound, animated: false)
        regionRecorder?.setCombo(settings.hotkeyRegion)
        fullScreenRecorder?.setCombo(settings.hotkeyFullScreen)
        historySpotlightRecorder?.setCombo(settings.hotkeyHistorySpotlight)
        for (actionKey, recorder) in editorRecorders {
            recorder.setCombo(settings.editorHotkey(for: actionKey))
        }
        for (actionKey, recorder) in spotlightRecorders {
            recorder.setCombo(settings.spotlightHotkey(for: actionKey))
        }
        hotkeyHint?.isHidden = true
    }

    private func persist() {
        guard let store else { return }
        store.save(settings)  // 适配器内打 settings.save 日志
        // 即时回灌 + 全局热键重绑（病例「改完不生效」：全局键注册只在
        // 启动，改键后要重启——rebind 即时重注册 Carbon）
        AppCoordinatorShared.coordinator?.settings = settings
        AppCoordinatorShared.coordinator?.rebindCaptureHotkeys()
        AppCoordinatorShared.coordinator?.invalidateToolbar()
    }

    // MARK: - 布局助手（晶透分组卡 / 行高 38 / 8pt 栅格）

    /// 晶透玻璃分组卡基元：radius 12 连续圆角 + 晶透提亮 0.08 + 双层光学影
    private func makeGlassCard() -> CrystalGlassContainer {
        let card = CrystalGlassContainer(cornerRadius: 12, tintAlpha: 0.08, shadowMargin: 8)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    /// 分组卡：11pt 灰字分组标题 + 行式设置行，行间 0.5pt hairline
    private func makeGroupCard(title: String, rows: [NSView]) -> CrystalGlassContainer {
        let card = makeGlassCard()

        var content: [NSView] = [groupHeader(title)]
        for (i, rowView) in rows.enumerated() {
            if i > 0 {
                let hair = SettingsHairlineView()
                hair.translatesAutoresizingMaskIntoConstraints = false
                hair.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
                hair.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                content.append(hair)
            }
            content.append(rowView)
        }
        let stack = NSStackView(views: content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Settings.cardPaddingTop,
            left: DesignTokens.Settings.cardPaddingH,
            bottom: DesignTokens.Settings.cardPaddingBottom,
            right: DesignTokens.Settings.cardPaddingH
        )
        stack.setCustomSpacing(8, after: content[0])   // 标题 → 首行
        for (i, sub) in content.enumerated() where sub is SettingsHairlineView {
            stack.setCustomSpacing(0, after: sub)
            if i > 0 { stack.setCustomSpacing(0, after: content[i - 1]) }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
        ])
        return card
    }

    private func groupHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = DesignTokens.Font.noteSemibold
        label.textColor = DesignTokens.label2
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        return box
    }

    /// 行式设置：左标签（13pt）+ 弹性空隙 + 右侧控件（8pt 栅格，行高 38）
    private func row(_ labelText: String, trailing: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: labelText)
        label.font = DesignTokens.Font.body
        label.textColor = DesignTokens.label1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [label, spacer] + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Spacing.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        stack.heightAnchor.constraint(equalToConstant: DesignTokens.Settings.rowHeight).isActive = true
        return stack
    }

    /// 448 = 560 − 内容边距 24×2 − 卡投影留白 8×2 − 卡内边距 16×2
    private static let rowWidth: CGFloat = 448

    private func pinStack(_ stack: NSStackView, to pane: NSView) {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let doc = SettingsFlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = doc
        pane.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: pane.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),

            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    // MARK: - 文案

    private static func afterCaptureLabel(_ action: AppSettings.AfterCaptureAction) -> String {
        switch action {
        case .copy: return "复制到剪贴板"
        case .save: return "保存到文件"
        case .pin: return "贴到屏幕"
        }
    }

    private static func filenameLabel(_ style: AppSettings.FilenameStyle) -> String {
        switch style {
        case .timestamp: return "时间戳"
        case .appAndTime: return "应用名 + 时间"
        case .askEveryTime: return "每次询问"
        }
    }
}

// MARK: - 玻璃基元（分隔线；token hair 明暗双值）

/// 0.5pt 分隔线：暗 白.12 / 亮 黑.10（token hair），随明暗模式刷新
@MainActor
private final class SettingsHairlineView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        layer?.backgroundColor = DesignTokens.hair.cgColor
    }
}

/// 顶部对齐的滚动文档视图（确保设置页卡片从顶部向下自然滚动，不倒挂底部）
private final class SettingsFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
