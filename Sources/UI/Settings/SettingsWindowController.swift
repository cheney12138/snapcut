import AppKit

/// 设置窗口（左栏导航 + 右侧晶透玻璃分组卡片体系）
///
/// 布局纪律（740 × 600 恒定窗口，零高度跳变）：
/// - 左侧栏（196pt）：微冷灰半透衬底 + 标题「设置」+ 严格左对齐导航栏（固定 18pt 图标列）+
///   浮起白晶选中胶囊（CASpring 420/28/0.85 弹簧滑移）+ 底端静默版本号
/// - 右侧内容区（544pt）：页眉标题/副标题（与侧栏标题同基准线）+ 分组标题外置于卡片上方 +
///   `SettingsGlassCard` 晶透玻璃卡（56% 白晶透 + 0.5pt 细边 + 1pt 顶缘高光，零脏阴影）
/// - 控件统一 26pt 高 / 7pt 连续圆角节奏；编辑器热键双列严格右对齐；工具栏页自带实时迷你预览
/// - 六边形纪律：只依赖端口 `SettingsStoring`，适配器由合成根注入
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

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

    // 关于 tab 控件
    private var permDot: NSView?
    private var permPill: NSView?
    private var permBadgeLabel: NSTextField?
    private var permButtonRef: GlassMiniButton?
    private var permSubtitleLabel: NSTextField?
    // 辅助功能权限（智能框选表格/控件/网页元素用）
    private var axPermDot: NSView?
    private var axPermPill: NSView?
    private var axPermBadgeLabel: NSTextField?
    private var axPermButtonRef: GlassMiniButton?
    private var axPermSubtitleLabel: NSTextField?
    private var updateSwitch: GlassSwitch!
    private var updateSubtitleLabel: NSTextField!

    // 通用 tab 控件
    private var launchAtLoginSwitch: GlassSwitch!
    private var launchAtLoginHintRow: NSView!
    private var launchAtLoginHintLabel: NSTextField!
    private var launchAtLoginOpenBtn: GlassMiniButton!
    private var afterCapturePopup: GlassPopUpButton!
    private var pathSubtitleLabel: NSTextField!
    private var filenamePopup: GlassPopUpButton!
    private var historyStepper: GlassStepperControl!
    private var autoIndexOCRSwitch: GlassSwitch!
    private var smartClipboardSwitch: GlassSwitch!
    private var notifySwitch: GlassSwitch!
    private var soundSwitch: GlassSwitch!

    // 工具栏 tab 控件
    private var toolbarSizeSegment: GlassSegmentedControl!
    private var toolbarPreview: ToolbarMiniPreviewView!
    private var toolbarOrderCardStack: NSStackView?

    // 快捷键 tab 控件
    private var regionRecorder: GlassHotkeyRecorderView!
    private var fullScreenRecorder: GlassHotkeyRecorderView!
    private var recordVideoRecorder: GlassHotkeyRecorderView!
    private var recordGIFRecorder: GlassHotkeyRecorderView!
    private var historySpotlightRecorder: GlassHotkeyRecorderView!
    private var editorRecorders: [String: GlassHotkeyRecorderView] = [:]
    private var spotlightRecorders: [String: GlassHotkeyRecorderView] = [:]
    private var hotkeyHintBanner: NSView!
    private var hotkeyHintLabel: NSTextField!

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: - 尺寸规格

    private static let sidebarWidth: CGFloat = 196
    private static let contentWidth: CGFloat = 544
    private static let windowHeight: CGFloat = 600
    private static let contentPaddingH: CGFloat = 28
    private static let cardWidth: CGFloat = contentWidth - contentPaddingH * 2   // 488
    private static let cardInnerPaddingH: CGFloat = 14
    private static let rowWidth: CGFloat = cardWidth - cardInnerPaddingH * 2    // 460

    // MARK: - 公开生命周期

    var isVisible: Bool { window?.isVisible ?? false }

    func orderOutForCapture() {
        window?.orderOut(nil)
        Log.event(.app, "settings.window.orderOutForCapture")
    }

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
        refreshPermissionStatus()
        refreshUpdateStatus()
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

    private func ensureWindow() {
        if !panesBuilt {
            panesBuilt = true
            buildPanes()
        }
        guard !windowBuilt else { return }
        windowBuilt = true

        let initialSize = CGSize(
            width: Self.sidebarWidth + Self.contentWidth,
            height: Self.windowHeight
        )
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Snapcut 设置"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .aqua)
        win.titlebarAppearsTransparent = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        container.wantsLayer = true

        // 全窗澄澈磨砂铺底（.aqua + .menu behindWindow）
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

        // 左侧栏：略沉一层（黑 2.5%）区分导航区与内容区
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.025).cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
        ])

        let titleLabel = NSTextField(labelWithString: "设置")
        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.textColor = DesignTokens.label1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            titleLabel.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 46),
        ])

        tabRail = GlassTabRail(items: [
            .init(title: "通用", symbol: "gearshape.fill", tint: NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)),
            .init(title: "工具栏", symbol: "menubar.rectangle", tint: NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)),
            .init(title: "快捷键", symbol: "command", tint: NSColor(srgbRed: 0.92, green: 0.55, blue: 0.04, alpha: 1)),
            .init(title: "关于", symbol: "info.circle.fill", tint: NSColor(srgbRed: 0.05, green: 0.58, blue: 0.53, alpha: 1)),
        ])
        tabRail.onSelect = { [weak self] index in self?.selectTab(index) }
        tabRail.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tabRail)
        NSLayoutConstraint.activate([
            tabRail.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tabRail.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabRail.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
        ])

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.2.0"
        let sidebarFooter = NSTextField(labelWithString: "Snapcut \(version)")
        sidebarFooter.font = DesignTokens.Font.note
        sidebarFooter.textColor = DesignTokens.label3
        sidebarFooter.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarFooter)
        NSLayoutConstraint.activate([
            sidebarFooter.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            sidebarFooter.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
        ])

        // 侧栏与内容区间的 0.5pt 分隔线
        let divider = SettingsHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.5),
        ])

        // 右侧内容底薄白纱提亮，与左侧栏拉出层次
        let contentBackdrop = NSView()
        contentBackdrop.wantsLayer = true
        contentBackdrop.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        contentBackdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentBackdrop)
        NSLayoutConstraint.activate([
            contentBackdrop.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentBackdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentBackdrop.topAnchor.constraint(equalTo: container.topAnchor),
            contentBackdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

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

    // MARK: - Tab 切换（0.15s ease-out 淡入 + 轻上浮）

    private func selectTab(_ index: Int, animated: Bool = true) {
        let panes = [generalPane, toolbarPane, hotkeyPane, aboutPane]
        guard panes.indices.contains(index) else { return }
        tabRail?.setSelectedIndex(index, animated: animated)
        let incoming = panes[index]
        let wasHidden = incoming.isHidden
        for (i, pane) in panes.enumerated() where i != index {
            pane.isHidden = true
        }
        guard wasHidden else { return }
        incoming.isHidden = false
        guard animated, !DesignTokens.Motion.reduceMotion else {
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
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            incoming.animator().alphaValue = 1
        }
        if let layer = incoming.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.crossfadeDuration)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    // MARK: - 窗口代理

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
        for r in spotlightRecorders.values { r.endRecordingIfNeeded() }
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

    // MARK: - 1. 通用 Tab

    private func buildGeneralPane() {
        let header = makePageHeader(
            title: "通用",
            subtitle: "启动方式、默认导出行为与历史记录"
        )

        // 启动
        launchAtLoginSwitch = GlassSwitch()
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginToggled(_:))

        launchAtLoginHintLabel = NSTextField(labelWithString: "")
        launchAtLoginHintLabel.font = DesignTokens.Font.note
        launchAtLoginHintLabel.lineBreakMode = .byWordWrapping
        launchAtLoginHintLabel.translatesAutoresizingMaskIntoConstraints = false

        launchAtLoginOpenBtn = GlassMiniButton(title: "打开登录项…")
        launchAtLoginOpenBtn.target = self
        launchAtLoginOpenBtn.action = #selector(openLoginItemsSettings)

        let hintSpacer = makeHorizontalSpacer()
        let hintStack = NSStackView(views: [launchAtLoginHintLabel, hintSpacer, launchAtLoginOpenBtn])
        hintStack.orientation = .horizontal
        hintStack.alignment = .centerY
        hintStack.spacing = 8
        hintStack.translatesAutoresizingMaskIntoConstraints = false
        hintStack.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        launchAtLoginHintRow = hintStack
        launchAtLoginHintRow.isHidden = true

        let launchRow = settingRow(
            "登录时自动启动",
            subtitle: "开机后在菜单栏静默待命",
            trailing: [launchAtLoginSwitch]
        )
        let startupStack = NSStackView(views: [launchRow, launchAtLoginHintRow])
        startupStack.orientation = .vertical
        startupStack.alignment = .leading
        startupStack.spacing = 6
        let startupSection = makeSection(
            title: "启动",
            symbol: "power",
            tint: NSColor(srgbRed: 0.06, green: 0.68, blue: 0.44, alpha: 1),
            rows: [startupStack]
        )

        // 截图与保存
        afterCapturePopup = GlassPopUpButton()
        afterCapturePopup.widthAnchor.constraint(equalToConstant: 156).isActive = true
        afterCapturePopup.configure(
            items: AppSettings.AfterCaptureAction.allCases.map { (Self.afterCaptureLabel($0), $0.rawValue) },
            selectedRawValue: settings.afterCapture.rawValue
        )
        afterCapturePopup.onSelect = { [weak self] raw in self?.afterCaptureChanged(raw) }

        let chooseButton = GlassMiniButton(title: "更改…")
        chooseButton.target = self
        chooseButton.action = #selector(chooseDirectory(_:))

        let (saveDirRow, saveDirSub) = settingRowWithMutableSubtitle(
            "保存目录",
            initialSubtitle: settings.saveDirectoryPath,
            subtitleSymbol: "folder.fill",
            subtitleTint: DesignTokens.accent,
            trailing: [chooseButton]
        )
        pathSubtitleLabel = saveDirSub
        pathSubtitleLabel.lineBreakMode = .byTruncatingMiddle

        filenamePopup = GlassPopUpButton()
        filenamePopup.widthAnchor.constraint(equalToConstant: 156).isActive = true
        filenamePopup.configure(
            items: AppSettings.FilenameStyle.allCases.map { (Self.filenameLabel($0), $0.rawValue) },
            selectedRawValue: settings.filenameStyle.rawValue
        )
        filenamePopup.onSelect = { [weak self] raw in self?.filenameChanged(raw) }

        let captureSection = makeSection(
            title: "截图与保存",
            symbol: "camera.viewfinder",
            tint: DesignTokens.accent,
            rows: [
                settingRow("截图完成后", trailing: [afterCapturePopup]),
                saveDirRow,
                settingRow("文件命名", trailing: [filenamePopup]),
            ]
        )

        // 视觉记忆历史
        historyStepper = GlassStepperControl(
            value: settings.historyLimit,
            minValue: AppSettings.historyLimitRange.lowerBound,
            maxValue: AppSettings.historyLimitRange.upperBound,
            unitSuffix: "条"
        )
        historyStepper.onValueChange = { [weak self] newValue in
            guard let self else { return }
            if self.settings.historyLimit != newValue {
                self.settings.historyLimit = newValue
                self.persist()
            }
        }

        autoIndexOCRSwitch = GlassSwitch()
        autoIndexOCRSwitch.target = self
        autoIndexOCRSwitch.action = #selector(autoIndexOCRToggled(_:))

        smartClipboardSwitch = GlassSwitch()
        smartClipboardSwitch.target = self
        smartClipboardSwitch.action = #selector(smartClipboardToggled(_:))

        let historySection = makeSection(
            title: "视觉记忆历史",
            symbol: "clock.arrow.circlepath",
            tint: NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1),
            rows: [
                settingRow("历史保留数量", trailing: [historyStepper]),
                settingRow("后台自动识别文字", subtitle: "为截图建立本地 OCR 索引以便快速搜索", trailing: [autoIndexOCRSwitch]),
                settingRow(
                    "外部复制含文字图片时轻提示",
                    subtitle: "在微信、飞书等软件复制图片后，仅检测到文字或二维码时浮现贴图划词与提取入口",
                    subtitleLines: 2,
                    trailing: [smartClipboardSwitch]
                ),
            ]
        )

        // 反馈
        notifySwitch = GlassSwitch()
        notifySwitch.target = self
        notifySwitch.action = #selector(notifyToggled(_:))
        soundSwitch = GlassSwitch()
        soundSwitch.target = self
        soundSwitch.action = #selector(soundToggled(_:))

        let notifySection = makeSection(
            title: "反馈",
            symbol: "bell.badge.fill",
            tint: NSColor(srgbRed: 0.92, green: 0.55, blue: 0.04, alpha: 1),
            rows: [
                settingRow("复制后显示通知", trailing: [notifySwitch]),
                settingRow("截图音效", trailing: [soundSwitch]),
            ]
        )

        installFixedHeaderPage(header: header, sections: [
            startupSection,
            captureSection,
            historySection,
            notifySection,
        ], into: generalPane)
    }

    // MARK: - 2. 工具栏 Tab

    private func buildToolbarPane() {
        let resetButton = GlassMiniButton(title: "恢复默认")
        resetButton.target = self
        resetButton.action = #selector(resetToolbarDefaults)

        let header = makePageHeader(
            title: "工具栏",
            subtitle: "调整悬浮工具栏尺寸与标注工具排序",
            trailing: resetButton
        )

        // 外观 + 实时预览
        toolbarSizeSegment = GlassSegmentedControl(titles: ["紧凑", "标准", "大号"])
        toolbarSizeSegment.onSelect = { [weak self] index in
            self?.toolbarSizeChanged(index)
        }

        toolbarPreview = ToolbarMiniPreviewView()
        toolbarPreview.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        toolbarPreview.update(order: settings.toolbarOrderSafe(), size: settings.toolbarSize)

        let previewWrapper = NSStackView(views: [toolbarPreview])
        previewWrapper.orientation = .vertical
        previewWrapper.alignment = .centerX
        previewWrapper.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        previewWrapper.translatesAutoresizingMaskIntoConstraints = false
        previewWrapper.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true

        let appearanceSection = makeSection(
            title: "外观与预览",
            symbol: "slider.horizontal.3",
            tint: NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1),
            rows: [
                settingRow("工具栏大小", trailing: [toolbarSizeSegment]),
                previewWrapper,
            ]
        )

        // 工具排序
        let orderCard = SettingsGlassCard()
        let orderStack = NSStackView()
        orderStack.orientation = .vertical
        orderStack.alignment = .leading
        orderStack.spacing = 0
        orderStack.edgeInsets = NSEdgeInsets(top: 0, left: Self.cardInnerPaddingH, bottom: 0, right: Self.cardInnerPaddingH)
        orderStack.translatesAutoresizingMaskIntoConstraints = false
        orderCard.contentContainer.addSubview(orderStack)
        NSLayoutConstraint.activate([
            orderStack.topAnchor.constraint(equalTo: orderCard.contentContainer.topAnchor),
            orderStack.bottomAnchor.constraint(equalTo: orderCard.contentContainer.bottomAnchor),
            orderStack.leadingAnchor.constraint(equalTo: orderCard.contentContainer.leadingAnchor),
            orderStack.trailingAnchor.constraint(equalTo: orderCard.contentContainer.trailingAnchor),
        ])
        toolbarOrderCardStack = orderStack
        populateToolbarOrderRows(into: orderStack)

        let orderSection = wrapSectionHeader(
            title: "工具排序（数字键 1–7）",
            symbol: "list.number",
            tint: DesignTokens.accent,
            card: orderCard
        )

        installFixedHeaderPage(header: header, sections: [
            appearanceSection,
            orderSection,
        ], into: toolbarPane)
    }

    private func populateToolbarOrderRows(into stack: NSStackView) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let order = settings.toolbarOrderSafe()
        for (idx, raw) in order.enumerated() {
            if idx > 0 {
                stack.addArrangedSubview(makeCardHairline())
            }
            let tool = EditorSession.Tool(rawValue: raw)
            let name = tool?.label ?? "未知(\(raw))"

            // 键位徽标 (1–7)：外框 20×20 + 内部 label centerY 垂直严格居中
            let keyBadge = NSView()
            keyBadge.wantsLayer = true
            keyBadge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.86).cgColor
            keyBadge.layer?.borderWidth = 0.5
            keyBadge.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
            keyBadge.layer?.cornerRadius = 5.5
            keyBadge.layer?.cornerCurve = .continuous
            keyBadge.layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
            keyBadge.layer?.shadowOpacity = 1
            keyBadge.layer?.shadowRadius = 0.5
            keyBadge.layer?.shadowOffset = CGSize(width: 0, height: -0.8)
            keyBadge.translatesAutoresizingMaskIntoConstraints = false

            let keyLabel = NSTextField(labelWithString: "\(idx + 1)")
            keyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            keyLabel.textColor = DesignTokens.label2
            keyLabel.alignment = .center
            keyLabel.translatesAutoresizingMaskIntoConstraints = false
            keyBadge.addSubview(keyLabel)
            NSLayoutConstraint.activate([
                keyBadge.widthAnchor.constraint(equalToConstant: 20),
                keyBadge.heightAnchor.constraint(equalToConstant: 20),
                keyLabel.centerXAnchor.constraint(equalTo: keyBadge.centerXAnchor),
                keyLabel.centerYAnchor.constraint(equalTo: keyBadge.centerYAnchor),
            ])

            // 工具图标（24×24 柔和色底微徽标 + TBIcon）
            let toolTint = tool.map { Self.accentColor(for: $0) } ?? DesignTokens.label1
            let toolBadge = NSView()
            toolBadge.wantsLayer = true
            toolBadge.layer?.backgroundColor = toolTint.withAlphaComponent(0.12).cgColor
            toolBadge.layer?.cornerRadius = 6.5
            toolBadge.layer?.cornerCurve = .continuous
            toolBadge.translatesAutoresizingMaskIntoConstraints = false

            let iconView = NSImageView()
            if let tool, let kind = Self.iconKind(for: tool) {
                iconView.image = TBIcon.image(kind, pointSize: 12.5)
            }
            iconView.contentTintColor = toolTint
            iconView.translatesAutoresizingMaskIntoConstraints = false
            toolBadge.addSubview(iconView)
            NSLayoutConstraint.activate([
                toolBadge.widthAnchor.constraint(equalToConstant: 24),
                toolBadge.heightAnchor.constraint(equalToConstant: 24),
                iconView.centerXAnchor.constraint(equalTo: toolBadge.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: toolBadge.centerYAnchor),
            ])

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = DesignTokens.Font.body
            nameLabel.textColor = DesignTokens.label1

            let up = GlassIconButton(symbolName: "chevron.up")
            up.target = self
            up.action = #selector(toolbarOrderTapped(_:))
            up.isEnabled = idx > 0
            up.tag = raw * 10 + 0

            let down = GlassIconButton(symbolName: "chevron.down")
            down.target = self
            down.action = #selector(toolbarOrderTapped(_:))
            down.isEnabled = idx < order.count - 1
            down.tag = raw * 10 + 2

            let rowStack = NSStackView(views: [keyBadge, toolBadge, nameLabel, makeHorizontalSpacer(), up, down])
            rowStack.orientation = .horizontal
            rowStack.alignment = .centerY
            rowStack.spacing = 8
            rowStack.setCustomSpacing(10, after: keyBadge)
            rowStack.setCustomSpacing(9, after: toolBadge)
            rowStack.setCustomSpacing(6, after: up)
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
            rowStack.heightAnchor.constraint(equalToConstant: 38).isActive = true
            stack.addArrangedSubview(rowStack)
        }
    }

    private static func accentColor(for tool: EditorSession.Tool) -> NSColor {
        switch tool {
        case .none: return DesignTokens.label1
        case .rect: return NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
        case .ellipse: return NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)
        case .arrow: return NSColor(srgbRed: 0.94, green: 0.25, blue: 0.22, alpha: 1)
        case .text: return NSColor(srgbRed: 0.90, green: 0.52, blue: 0.04, alpha: 1)
        case .mosaic: return NSColor(srgbRed: 0.05, green: 0.58, blue: 0.72, alpha: 1)
        case .sequence: return NSColor(srgbRed: 0.65, green: 0.28, blue: 0.82, alpha: 1)
        case .highlight: return NSColor(srgbRed: 0.78, green: 0.50, blue: 0.02, alpha: 1)
        }
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

    @objc private func toolbarOrderTapped(_ sender: NSButton) {
        let raw = sender.tag / 10
        let delta = (sender.tag % 10) - 1
        moveToolbarOrder(raw, delta: delta)
    }

    private func moveToolbarOrder(_ raw: Int, delta: Int) {
        var normalized = settings.toolbarOrderSafe()
        guard let idx = normalized.firstIndex(of: raw) else { return }
        let target = idx + delta
        guard target >= 0, target < normalized.count else { return }
        normalized.swapAt(idx, target)
        settings.toolbarOrder = normalized
        Log.event(.app, "settings.toolbarOrder", ["moved": "\(raw)", "to": "\(target)"])
        persist()
        if let stack = toolbarOrderCardStack {
            populateToolbarOrderRows(into: stack)
        }
        toolbarPreview?.update(order: normalized, size: settings.toolbarSize)
    }

    @objc private func resetToolbarDefaults() {
        settings.toolbarSize = AppSettings.defaultSettings.toolbarSize
        settings.toolbarOrder = AppSettings.defaultToolbarOrder
        persist()
        refreshControls()
        if let stack = toolbarOrderCardStack {
            populateToolbarOrderRows(into: stack)
        }
        toolbarPreview?.update(order: settings.toolbarOrderSafe(), size: settings.toolbarSize)
    }

    // MARK: - 3. 快捷键 Tab

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
        ("record", "录制视频"),
        ("recordGIF", "录制 GIF"),
    ]

    private static let spotlightHotkeyRows: [(key: String, label: String)] = [
        ("copyImage", "复制原图"),
        ("reopenEdit", "重新编辑"),
        ("pin", "贴图"),
        ("copyOCR", "复制文字"),
    ]

    private func buildHotkeyPane() {
        let resetButton = GlassMiniButton(title: "恢复默认")
        resetButton.target = self
        resetButton.action = #selector(resetHotkeyDefaults)

        let header = makePageHeader(
            title: "快捷键",
            subtitle: "点击录制框后按下新组合，按 Esc 取消",
            trailing: resetButton
        )

        // 冲突/非法提示条（胶囊样式）
        let hintBanner = NSView()
        hintBanner.wantsLayer = true
        hintBanner.layer?.backgroundColor = DesignTokens.statusError.withAlphaComponent(0.10).cgColor
        hintBanner.layer?.cornerRadius = 8
        hintBanner.layer?.cornerCurve = .continuous
        hintBanner.layer?.borderWidth = 0.5
        hintBanner.layer?.borderColor = DesignTokens.statusError.withAlphaComponent(0.28).cgColor
        hintBanner.translatesAutoresizingMaskIntoConstraints = false
        hintBanner.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        hintBanner.isHidden = true

        let warnIcon = NSImageView()
        warnIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold))
        warnIcon.contentTintColor = DesignTokens.statusError
        warnIcon.translatesAutoresizingMaskIntoConstraints = false

        hotkeyHintLabel = NSTextField(labelWithString: "")
        hotkeyHintLabel.font = DesignTokens.Font.note
        hotkeyHintLabel.textColor = DesignTokens.statusError
        hotkeyHintLabel.lineBreakMode = .byWordWrapping
        hotkeyHintLabel.translatesAutoresizingMaskIntoConstraints = false

        hintBanner.addSubview(warnIcon)
        hintBanner.addSubview(hotkeyHintLabel)
        NSLayoutConstraint.activate([
            warnIcon.leadingAnchor.constraint(equalTo: hintBanner.leadingAnchor, constant: 12),
            warnIcon.centerYAnchor.constraint(equalTo: hintBanner.centerYAnchor),
            hotkeyHintLabel.leadingAnchor.constraint(equalTo: warnIcon.trailingAnchor, constant: 6),
            hotkeyHintLabel.trailingAnchor.constraint(equalTo: hintBanner.trailingAnchor, constant: -12),
            hotkeyHintLabel.topAnchor.constraint(equalTo: hintBanner.topAnchor, constant: 7),
            hotkeyHintLabel.bottomAnchor.constraint(equalTo: hintBanner.bottomAnchor, constant: -7),
        ])
        hotkeyHintBanner = hintBanner

        // 全局热键
        regionRecorder = GlassHotkeyRecorderView(width: 136)
        fullScreenRecorder = GlassHotkeyRecorderView(width: 136)
        recordVideoRecorder = GlassHotkeyRecorderView(width: 136)
        recordGIFRecorder = GlassHotkeyRecorderView(width: 136)
        historySpotlightRecorder = GlassHotkeyRecorderView(width: 136)
        wireGlobalRecorder(regionRecorder)
        wireGlobalRecorder(fullScreenRecorder)
        wireGlobalRecorder(recordVideoRecorder)
        wireGlobalRecorder(recordGIFRecorder)
        wireGlobalRecorder(historySpotlightRecorder)

        let globalSection = makeSection(
            title: "全局热键",
            symbol: "globe",
            tint: DesignTokens.accent,
            rows: [
                settingRow("区域截图", trailing: [regionRecorder]),
                settingRow("全屏截图", trailing: [fullScreenRecorder]),
                settingRow("录制视频", trailing: [recordVideoRecorder]),
                settingRow("录制 GIF", trailing: [recordGIFRecorder]),
                settingRow("视觉记忆搜索", trailing: [historySpotlightRecorder]),
            ]
        )

        // 视觉记忆面板
        var spotlightRows: [NSView] = []
        for (actionKey, label) in Self.spotlightHotkeyRows {
            let rec = GlassHotkeyRecorderView(width: 136)
            rec.allowReturnKey = true
            rec.setCombo(settings.spotlightHotkey(for: actionKey))
            wireSpotlightRecorder(rec, actionKey: actionKey)
            spotlightRecorders[actionKey] = rec
            spotlightRows.append(settingRow(label, trailing: [rec]))
        }
        let spotlightSection = makeSection(
            title: "视觉记忆面板（搜索浮窗内生效）",
            symbol: "magnifyingglass",
            tint: NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1),
            rows: spotlightRows
        )

        // 编辑器操作（严格对齐双列网格：221 | 18(中间细线) | 221）
        var editorRows: [NSView] = []
        var pendingCells: [NSView] = []
        for (actionKey, label) in Self.editorHotkeyRows {
            let rec = GlassHotkeyRecorderView(width: 96)
            rec.allowBare = true
            rec.setCombo(settings.editorHotkey(for: actionKey))
            wireEditorRecorder(rec, actionKey: actionKey)
            editorRecorders[actionKey] = rec
            pendingCells.append(makeHotkeyGridCell(label: label, recorder: rec))
            if pendingCells.count == 2 {
                editorRows.append(makeHotkeyGridRow(left: pendingCells[0], right: pendingCells[1]))
                pendingCells = []
            }
        }
        if let leftover = pendingCells.first {
            editorRows.append(makeHotkeyGridRow(left: leftover, right: nil))
        }
        let editorSection = makeSection(
            title: "编辑器操作（截图编辑时生效）",
            symbol: "pencil.and.outline",
            tint: NSColor(srgbRed: 0.90, green: 0.52, blue: 0.04, alpha: 1),
            rows: editorRows
        )

        installFixedHeaderPage(header: header, sections: [
            hintBanner,
            globalSection,
            spotlightSection,
            editorSection,
        ], into: hotkeyPane)
    }

    /// 双列热键单元：固定 221pt 宽，左侧标签 + 弹性空隙 + 右对齐 96pt 录制器（列内严格对齐）
    private static let hotkeyCellWidth: CGFloat = 221

    private func makeHotkeyGridCell(label text: String, recorder: GlassHotkeyRecorderView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = DesignTokens.Font.body
        label.textColor = DesignTokens.label1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [label, makeHorizontalSpacer(), recorder])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.hotkeyCellWidth).isActive = true
        return stack
    }

    private func makeHotkeyGridRow(left: NSView, right: NSView?) -> NSView {
        let rowContainer = NSView()
        rowContainer.translatesAutoresizingMaskIntoConstraints = false
        rowContainer.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        rowContainer.heightAnchor.constraint(equalToConstant: 38).isActive = true

        rowContainer.addSubview(left)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor),
            left.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
        ])

        if let right {
            let vDivider = SettingsHairlineView()
            vDivider.translatesAutoresizingMaskIntoConstraints = false
            rowContainer.addSubview(vDivider)
            rowContainer.addSubview(right)
            NSLayoutConstraint.activate([
                vDivider.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 9),
                vDivider.topAnchor.constraint(equalTo: rowContainer.topAnchor, constant: 9),
                vDivider.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor, constant: -9),
                vDivider.widthAnchor.constraint(equalToConstant: 0.5),
                right.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                right.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
            ])
        }
        return rowContainer
    }

    @objc private func resetHotkeyDefaults() {
        stopOtherRecorders(except: nil)
        let def = AppSettings.defaultSettings
        settings.hotkeyRegion = def.hotkeyRegion
        settings.hotkeyFullScreen = def.hotkeyFullScreen
        settings.hotkeyRecordVideo = def.hotkeyRecordVideo
        settings.hotkeyRecordGIF = def.hotkeyRecordGIF
        settings.hotkeyHistorySpotlight = def.hotkeyHistorySpotlight
        settings.editorHotkeys = AppSettings.defaultEditorHotkeys
        settings.spotlightHotkeys = AppSettings.defaultSpotlightHotkeys
        hideHotkeyHint()
        persist()
        refreshControls()
    }

    // MARK: - 4. 关于 Tab

    private func buildAboutPane() {
        let header = makePageHeader(
            title: "关于",
            subtitle: "应用信息、系统权限与版本更新"
        )

        // Hero 品牌信息卡（与全部卡片等宽 488，横向精炼排版）
        let heroCard = SettingsGlassCard()
        let iconWrap = NSView()
        iconWrap.wantsLayer = true
        iconWrap.layer?.shadowColor = DesignTokens.accent.withAlphaComponent(0.28).cgColor
        iconWrap.layer?.shadowOpacity = 1
        iconWrap.layer?.shadowRadius = 10
        iconWrap.layer?.shadowOffset = CGSize(width: 0, height: -4)
        iconWrap.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.widthAnchor.constraint(equalToConstant: 56).isActive = true
        iconWrap.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 13
        iconView.layer?.cornerCurve = .continuous
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: iconWrap.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: iconWrap.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: iconWrap.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconWrap.trailingAnchor),
        ])

        let nameLabel = NSTextField(labelWithString: "Snapcut")
        nameLabel.font = .systemFont(ofSize: 18, weight: .bold)
        nameLabel.textColor = DesignTokens.label1

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.2.0"
        let verPill = NSTextField(labelWithString: "v\(version)")
        verPill.font = DesignTokens.Font.monoDigit(11)
        verPill.textColor = DesignTokens.accent
        verPill.alignment = .center
        verPill.wantsLayer = true
        verPill.layer?.backgroundColor = DesignTokens.accentSoft.cgColor
        verPill.layer?.cornerRadius = 5
        verPill.layer?.cornerCurve = .continuous
        verPill.translatesAutoresizingMaskIntoConstraints = false

        let verContainer = NSView()
        verContainer.wantsLayer = true
        verContainer.layer?.backgroundColor = DesignTokens.accentSoft.cgColor
        verContainer.layer?.cornerRadius = 5
        verContainer.layer?.cornerCurve = .continuous
        verContainer.translatesAutoresizingMaskIntoConstraints = false
        verPill.layer?.backgroundColor = NSColor.clear.cgColor
        verContainer.addSubview(verPill)
        NSLayoutConstraint.activate([
            verPill.leadingAnchor.constraint(equalTo: verContainer.leadingAnchor, constant: 7),
            verPill.trailingAnchor.constraint(equalTo: verContainer.trailingAnchor, constant: -7),
            verPill.topAnchor.constraint(equalTo: verContainer.topAnchor, constant: 2),
            verPill.bottomAnchor.constraint(equalTo: verContainer.bottomAnchor, constant: -2),
        ])

        let titleRow = NSStackView(views: [nameLabel, verContainer])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let tagline = NSTextField(labelWithString: "本地运行 · 无账户 · 不联网")
        tagline.font = DesignTokens.Font.note
        tagline.textColor = DesignTokens.label2

        let infoCol = NSStackView(views: [titleRow, tagline])
        infoCol.orientation = .vertical
        infoCol.alignment = .leading
        infoCol.spacing = 4

        let heroRow = NSStackView(views: [iconWrap, infoCol, makeHorizontalSpacer()])
        heroRow.orientation = .horizontal
        heroRow.alignment = .centerY
        heroRow.spacing = 14
        heroRow.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        heroRow.translatesAutoresizingMaskIntoConstraints = false
        heroRow.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        heroCard.contentContainer.addSubview(heroRow)
        NSLayoutConstraint.activate([
            heroRow.topAnchor.constraint(equalTo: heroCard.contentContainer.topAnchor),
            heroRow.bottomAnchor.constraint(equalTo: heroCard.contentContainer.bottomAnchor),
            heroRow.leadingAnchor.constraint(equalTo: heroCard.contentContainer.leadingAnchor),
            heroRow.trailingAnchor.constraint(equalTo: heroCard.contentContainer.trailingAnchor),
        ])

        // 权限状态卡（整行左文案右状态胶囊，彻底消除居中偏斜）
        let (permPillView, permDotView, permBadge) = makeStatusPill(initialText: "检查中…")
        permDot = permDotView
        permBadgeLabel = permBadge
        permPill = permPillView

        let permButton = GlassMiniButton(title: "去授权…")
        permButton.target = self
        permButton.action = #selector(openPermissionSettings)
        permButtonRef = permButton

        let (permRow, permSub) = settingRowWithMutableSubtitle(
            "屏幕录制权限",
            initialSubtitle: "权限正常，全局热键随时可用",
            trailing: [permPillView, permButton]
        )
        permSubtitleLabel = permSub

        // 辅助功能权限行（智能框选表格/控件/网页元素的 AX 探测用；
        // 未授权不影响截图，只降级为纯视觉识别，所以文案要说明后果而不是「必须」）
        let (axPillView, axDotView, axBadge) = makeStatusPill(initialText: "检查中…")
        axPermDot = axDotView
        axPermBadgeLabel = axBadge
        axPermPill = axPillView

        let axButton = GlassMiniButton(title: "去授权…")
        axButton.target = self
        axButton.action = #selector(openAccessibilityPermissionSettings)
        axPermButtonRef = axButton

        let (axRow, axSub) = settingRowWithMutableSubtitle(
            "辅助功能权限",
            initialSubtitle: "开启后可识别表格与网页元素；未开启仅用视觉识别",
            trailing: [axPillView, axButton]
        )
        axPermSubtitleLabel = axSub

        let permSection = makeSection(
            title: "系统权限",
            symbol: "checkmark.shield.fill",
            tint: NSColor(srgbRed: 0.06, green: 0.68, blue: 0.44, alpha: 1),
            rows: [permRow, axRow]
        )

        // 更新卡
        let checkButton = GlassMiniButton(title: "检查更新…")
        checkButton.target = self
        checkButton.action = #selector(checkForUpdatesClicked)

        let (checkRow, updateSub) = settingRowWithMutableSubtitle(
            "检查更新",
            initialSubtitle: "",
            trailing: [checkButton]
        )
        updateSubtitleLabel = updateSub

        updateSwitch = GlassSwitch()
        updateSwitch.target = self
        updateSwitch.action = #selector(updateAutoToggled(_:))

        let autoCheckRow = settingRow(
            "每日自动检查",
            subtitle: "自动检测 GitHub Releases 新版本",
            trailing: [updateSwitch]
        )
        let updateSection = makeSection(
            title: "软件更新",
            symbol: "arrow.down.circle.fill",
            tint: DesignTokens.accent,
            rows: [checkRow, autoCheckRow]
        )

        installFixedHeaderPage(header: header, sections: [
            heroCard,
            permSection,
            updateSection,
        ], into: aboutPane)
        refreshPermissionStatus()
    }

    // MARK: - 通用 & 工具栏 & 关于动作

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
        toolbarPreview?.update(order: settings.toolbarOrderSafe(), size: chosen)
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
            pathSubtitleLabel?.stringValue = url.path
            persist()
        }
    }

    @objc private func autoIndexOCRToggled(_ sender: GlassSwitch) {
        settings.autoIndexHistoryOCR = sender.isOn
        Log.event(.app, "settings.autoIndexOCR", ["enabled": "\(settings.autoIndexHistoryOCR)"])
        persist()
    }

    @objc private func smartClipboardToggled(_ sender: GlassSwitch) {
        settings.smartClipboardImagePrompt = sender.isOn
        Log.event(.app, "settings.smartClipboardPrompt", ["enabled": "\(settings.smartClipboardImagePrompt)"])
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

    @objc private func checkForUpdatesClicked() {
        AppCoordinatorShared.deps?.updating.checkForUpdates()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshUpdateStatus()
        }
    }

    @objc private func updateAutoToggled(_ sender: GlassSwitch) {
        AppCoordinatorShared.deps?.updating.automaticallyChecksForUpdates = sender.isOn
        refreshUpdateStatus()
    }

    @objc private func openPermissionSettings() {
        TCCPermission.openSystemSettings()
    }

    /// 用户主动点击「去授权…」才请求（全局纪律：绝不在启动/悬停路径弹系统模态框）
    @objc private func openAccessibilityPermissionSettings() {
        AccessibilityPermission.requestAndOpenSettings()
    }

    /// 状态胶囊（7pt 圆点 + 11.5pt 文案，22pt 高）。圆点/文案由调用方持引用动态刷新。
    private func makeStatusPill(initialText: String) -> (pill: NSView, dot: NSView, label: NSTextField) {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        let badgeLabel = NSTextField(labelWithString: initialText)
        badgeLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 11
        pill.layer?.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(dot)
        pill.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 22),
            dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            badgeLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return (pill, dot, badgeLabel)
    }

    @MainActor
    private func refreshPermissionStatus() {
        let granted = AppCoordinatorShared.deps?.permission.isGranted() ?? false
        if granted {
            permDot?.layer?.backgroundColor = DesignTokens.statusOK.cgColor
            permBadgeLabel?.stringValue = "已授权"
            permBadgeLabel?.textColor = NSColor(srgbRed: 0.08, green: 0.56, blue: 0.22, alpha: 1)
            permPill?.layer?.backgroundColor = DesignTokens.statusOK.withAlphaComponent(0.14).cgColor
            permButtonRef?.isHidden = true
            permSubtitleLabel?.stringValue = "权限正常，全局热键随时可用"
            Log.event(.app, "settings.permission", ["state": "granted"])
        } else {
            permDot?.layer?.backgroundColor = DesignTokens.statusWarn.cgColor
            permBadgeLabel?.stringValue = "未授权"
            permBadgeLabel?.textColor = NSColor(srgbRed: 0.72, green: 0.40, blue: 0.0, alpha: 1)
            permPill?.layer?.backgroundColor = DesignTokens.statusWarn.withAlphaComponent(0.15).cgColor
            permButtonRef?.isHidden = false
            permSubtitleLabel?.stringValue = "未授权时无法截屏；授权后需重启 Snapcut"
            Log.event(.app, "settings.permission", ["state": "denied"])
        }

        // 辅助功能权限：只查不弹（AXIsProcessTrusted 不触发任何系统弹窗）
        let axGranted = AccessibilityPermission.isTrusted()
        if axGranted {
            axPermDot?.layer?.backgroundColor = DesignTokens.statusOK.cgColor
            axPermBadgeLabel?.stringValue = "已授权"
            axPermBadgeLabel?.textColor = NSColor(srgbRed: 0.08, green: 0.56, blue: 0.22, alpha: 1)
            axPermPill?.layer?.backgroundColor = DesignTokens.statusOK.withAlphaComponent(0.14).cgColor
            axPermButtonRef?.isHidden = true
            axPermSubtitleLabel?.stringValue = "权限正常，智能框选可精准识别表格、控件与网页区块"
        } else {
            axPermDot?.layer?.backgroundColor = DesignTokens.statusWarn.cgColor
            axPermBadgeLabel?.stringValue = "未授权"
            axPermBadgeLabel?.textColor = NSColor(srgbRed: 0.72, green: 0.40, blue: 0.0, alpha: 1)
            axPermPill?.layer?.backgroundColor = DesignTokens.statusWarn.withAlphaComponent(0.15).cgColor
            axPermButtonRef?.isHidden = false
            axPermSubtitleLabel?.stringValue = "开启后可识别表格与网页元素；未开启仅用视觉识别"
        }
        Log.event(.app, "settings.permission.accessibility", ["state": axGranted ? "granted" : "denied"])
    }

    @MainActor
    private func refreshUpdateStatus() {
        guard let updating = AppCoordinatorShared.deps?.updating else {
            updateSwitch?.setOn(false, animated: false)
            updateSubtitleLabel?.stringValue = "更新服务未就绪"
            return
        }
        updateSwitch?.setOn(updating.automaticallyChecksForUpdates, animated: false)
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        updateSubtitleLabel?.stringValue = updating.lastCheckDescription
            .map { "当前 \(version) · \($0)" } ?? "当前 \(version) · 每日自动检查一次"
    }

    // MARK: - 快捷键录制与冲突校验

    private func stopOtherRecorders(except current: GlassHotkeyRecorderView?) {
        for other in [regionRecorder, fullScreenRecorder, recordVideoRecorder, recordGIFRecorder, historySpotlightRecorder] {
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
        hideHotkeyHint()
    }

    private func showHotkeyHint(_ message: String) {
        hotkeyHintLabel?.stringValue = message
        hotkeyHintBanner?.isHidden = false
    }

    private func hideHotkeyHint() {
        hotkeyHintBanner?.isHidden = true
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
            showHotkeyHint("组合无效：需含修饰键（如 ⌘E）、F 功能键或 Return")
            return
        }
        for rowDef in Self.spotlightHotkeyRows where rowDef.key != actionKey {
            if combosConflict(combo, settings.spotlightHotkey(for: rowDef.key)) {
                showHotkeyHint("「\(HotkeySpec.display(combo))」已被视觉记忆「\(rowDef.label)」占用")
                return
            }
        }
        let globalSlots: [(combo: String, label: String)] = [
            (settings.hotkeyRegion, "区域截图（全局）"),
            (settings.hotkeyFullScreen, "全屏截图（全局）"),
            (settings.hotkeyRecordVideo, "录制视频（全局）"),
            (settings.hotkeyRecordGIF, "录制 GIF（全局）"),
            (settings.hotkeyHistorySpotlight, "视觉记忆搜索（全局）"),
        ]
        for slot in globalSlots where combosConflict(combo, slot.combo) {
            showHotkeyHint("「\(HotkeySpec.display(combo))」已被「\(slot.label)」占用")
            return
        }
        hideHotkeyHint()
        var hotkeys = settings.spotlightHotkeys
        if hotkeys.isEmpty { hotkeys = AppSettings.defaultSpotlightHotkeys }
        hotkeys[actionKey] = combo
        settings.spotlightHotkeys = hotkeys
        recorder.setCombo(combo)
        Log.event(.app, "settings.spotlightHotkey", ["action": actionKey, "combo": combo])
        persist()
    }

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
            showHotkeyHint("组合无效：需含修饰键，或单个字母/数字键")
            return
        }
        for rowDef in Self.editorHotkeyRows where rowDef.key != actionKey {
            if combosConflict(combo, settings.editorHotkey(for: rowDef.key)) {
                showHotkeyHint("「\(HotkeySpec.display(combo))」已被「\(rowDef.label)」占用")
                return
            }
        }
        let globalSlots: [(combo: String, label: String)] = [
            (settings.hotkeyRegion, "区域截图（全局）"),
            (settings.hotkeyFullScreen, "全屏截图（全局）"),
            (settings.hotkeyRecordVideo, "录制视频（全局）"),
            (settings.hotkeyRecordGIF, "录制 GIF（全局）"),
            (settings.hotkeyHistorySpotlight, "视觉记忆搜索（全局）"),
        ]
        for slot in globalSlots where combosConflict(combo, slot.combo) {
            showHotkeyHint("「\(HotkeySpec.display(combo))」已被「\(slot.label)」占用")
            return
        }
        let reserved: [String: String] = ["c": "取色", "space": "移动贴图", "cmd+opt+s": "快速保存"]
        if let name = reserved.first(where: { combosConflict(combo, $0.key) })?.value {
            showHotkeyHint("「\(HotkeySpec.display(combo))」是内置功能「\(name)」的按键，请换一个")
            return
        }
        hideHotkeyHint()
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

    private func handleCombo(from recorder: GlassHotkeyRecorderView, _ combo: String?) {
        guard let combo else {
            showHotkeyHint("组合无效：必须包含至少一个修饰键（⌘ / ⇧ / ⌥ / ⌃）")
            return
        }
        let allSlots: [(recorder: GlassHotkeyRecorderView?, slot: String, combo: String, label: String)] = [
            (regionRecorder, "region", settings.hotkeyRegion, "区域截图"),
            (fullScreenRecorder, "fullScreen", settings.hotkeyFullScreen, "全屏截图"),
            (recordVideoRecorder, "recordVideo", settings.hotkeyRecordVideo, "录制视频"),
            (recordGIFRecorder, "recordGIF", settings.hotkeyRecordGIF, "录制 GIF"),
            (historySpotlightRecorder, "historySpotlight", settings.hotkeyHistorySpotlight, "视觉记忆搜索"),
        ]
        let slot = allSlots.first(where: { $0.recorder === recorder })?.slot ?? "historySpotlight"
        for other in allSlots where other.recorder !== recorder && combosConflict(combo, other.combo) {
            showHotkeyHint("「\(HotkeySpec.display(combo))」已被「\(other.label)」占用")
            return
        }
        for rowDef in Self.editorHotkeyRows where combosConflict(combo, settings.editorHotkey(for: rowDef.key)) {
            showHotkeyHint("「\(HotkeySpec.display(combo))」已被编辑器「\(rowDef.label)」占用")
            return
        }
        hideHotkeyHint()
        if recorder === regionRecorder {
            settings.hotkeyRegion = combo
            regionRecorder.setCombo(combo)
        } else if recorder === fullScreenRecorder {
            settings.hotkeyFullScreen = combo
            fullScreenRecorder.setCombo(combo)
        } else if recorder === recordVideoRecorder {
            settings.hotkeyRecordVideo = combo
            recordVideoRecorder.setCombo(combo)
        } else if recorder === recordGIFRecorder {
            settings.hotkeyRecordGIF = combo
            recordGIFRecorder.setCombo(combo)
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

    private func combosConflict(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        if let l = HotkeySpec.parse(lhs, allowBare: true),
           let r = HotkeySpec.parse(rhs, allowBare: true) {
            return l == r
        }
        return false
    }

    // MARK: - 刷新与持久化

    private func refreshControls() {
        refreshLaunchAtLoginStatus()
        if let idx = AppSettings.ToolbarSize.allCases.firstIndex(of: settings.toolbarSize) {
            toolbarSizeSegment?.setSelectedIndex(idx, animated: false)
        }
        afterCapturePopup?.select(rawValue: settings.afterCapture.rawValue)
        filenamePopup?.select(rawValue: settings.filenameStyle.rawValue)
        pathSubtitleLabel?.stringValue = settings.saveDirectoryPath
        historyStepper?.setValue(settings.historyLimit)
        autoIndexOCRSwitch?.setOn(settings.autoIndexHistoryOCR, animated: false)
        smartClipboardSwitch?.setOn(settings.smartClipboardImagePrompt, animated: false)
        notifySwitch?.setOn(settings.showCopyNotification, animated: false)
        soundSwitch?.setOn(settings.playCaptureSound, animated: false)
        regionRecorder?.setCombo(settings.hotkeyRegion)
        fullScreenRecorder?.setCombo(settings.hotkeyFullScreen)
        recordVideoRecorder?.setCombo(settings.hotkeyRecordVideo)
        recordGIFRecorder?.setCombo(settings.hotkeyRecordGIF)
        historySpotlightRecorder?.setCombo(settings.hotkeyHistorySpotlight)
        for (actionKey, recorder) in editorRecorders {
            recorder.setCombo(settings.editorHotkey(for: actionKey))
        }
        for (actionKey, recorder) in spotlightRecorders {
            recorder.setCombo(settings.spotlightHotkey(for: actionKey))
        }
        toolbarPreview?.update(order: settings.toolbarOrderSafe(), size: settings.toolbarSize)
        hideHotkeyHint()
    }

    private func persist() {
        guard let store else { return }
        store.save(settings)
        AppCoordinatorShared.coordinator?.settings = settings
        AppCoordinatorShared.coordinator?.rebindCaptureHotkeys()
        AppCoordinatorShared.coordinator?.invalidateToolbar()
    }

    // MARK: - 布局积木（外置分组标题 + 晶透卡片 + 一致行高节奏）

    private func makePageHeader(title: String, subtitle: String, trailing: NSView? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.textColor = DesignTokens.label1

        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = DesignTokens.Font.note
        subLabel.textColor = DesignTokens.label2

        let textCol = NSStackView(views: [titleLabel, subLabel])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 3

        var views: [NSView] = [textCol, makeHorizontalSpacer()]
        if let trailing { views.append(trailing) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        // 宽度不在这里钉死：页头现在被 installFixedHeaderPage 直接左右贴 pane
        // （pane 宽 544 - 两侧 28 = 488 = cardWidth），再叠一条常量宽度只会白多一条等价约束。
        return row
    }

    private func makeSection(
        title: String,
        symbol: String? = nil,
        tint: NSColor? = nil,
        rows: [NSView]
    ) -> NSView {
        let card = SettingsGlassCard()
        var content: [NSView] = []
        for (i, rowView) in rows.enumerated() {
            if i > 0 {
                content.append(makeCardHairline())
            }
            content.append(rowView)
        }
        let stack = NSStackView(views: content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.cardInnerPaddingH, bottom: 0, right: Self.cardInnerPaddingH)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
        ])
        return wrapSectionHeader(title: title, symbol: symbol, tint: tint, card: card)
    }

    private func wrapSectionHeader(
        title: String,
        symbol: String? = nil,
        tint: NSColor? = nil,
        card: NSView
    ) -> NSView {
        var headerViews: [NSView] = []
        if let symbol {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
            icon.contentTintColor = tint ?? DesignTokens.label2
            icon.translatesAutoresizingMaskIntoConstraints = false
            headerViews.append(icon)
        }
        let headerLabel = NSTextField(labelWithString: title)
        headerLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        headerLabel.textColor = DesignTokens.label2
        headerViews.append(headerLabel)

        let headerWrap = NSStackView(views: headerViews)
        headerWrap.orientation = .horizontal
        headerWrap.alignment = .centerY
        headerWrap.spacing = 5
        headerWrap.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        let group = NSStackView(views: [headerWrap, card])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        group.translatesAutoresizingMaskIntoConstraints = false
        return group
    }

    private func makeCardHairline() -> NSView {
        let hair = SettingsHairlineView()
        hair.translatesAutoresizingMaskIntoConstraints = false
        hair.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        hair.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return hair
    }

    private func settingRow(
        _ labelText: String,
        subtitle: String? = nil,
        subtitleLines: Int = 1,
        trailing: [NSView]
    ) -> NSStackView {
        let label = NSTextField(labelWithString: labelText)
        label.font = DesignTokens.Font.body
        label.textColor = DesignTokens.label1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let leadingView: NSView
        let height: CGFloat
        if let subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = DesignTokens.Font.note
            sub.textColor = DesignTokens.label2
            // 长副文案（超过一行）允许换行，避免末尾被截成「…」读不懂语义
            if subtitleLines > 1 {
                sub.maximumNumberOfLines = subtitleLines
                sub.lineBreakMode = .byWordWrapping
                sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            let col = NSStackView(views: [label, sub])
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 2
            leadingView = col
            height = subtitleLines > 1 ? 58 : 50
        } else {
            leadingView = label
            height = 38
        }

        let stack = NSStackView(views: [leadingView, makeHorizontalSpacer()] + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Spacing.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        stack.heightAnchor.constraint(equalToConstant: height).isActive = true
        return stack
    }

    private func settingRowWithMutableSubtitle(
        _ labelText: String,
        initialSubtitle: String,
        subtitleSymbol: String? = nil,
        subtitleTint: NSColor? = nil,
        trailing: [NSView]
    ) -> (NSStackView, NSTextField) {
        let label = NSTextField(labelWithString: labelText)
        label.font = DesignTokens.Font.body
        label.textColor = DesignTokens.label1

        let sub = NSTextField(labelWithString: initialSubtitle)
        sub.font = DesignTokens.Font.note
        sub.textColor = DesignTokens.label2
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitleView: NSView
        if let subtitleSymbol {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: subtitleSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10.5, weight: .medium))
            icon.contentTintColor = subtitleTint ?? DesignTokens.label2
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            let subRow = NSStackView(views: [icon, sub])
            subRow.orientation = .horizontal
            subRow.alignment = .centerY
            subRow.spacing = 4
            subRow.translatesAutoresizingMaskIntoConstraints = false
            subRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            subtitleView = subRow
        } else {
            subtitleView = sub
        }

        let col = NSStackView(views: [label, subtitleView])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false
        col.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in trailing {
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: [col, makeHorizontalSpacer()] + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Spacing.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        stack.heightAnchor.constraint(equalToConstant: 50).isActive = true
        return (stack, sub)
    }

    private func makeHorizontalSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return spacer
    }

    /// 固定页头 + 只滚卡片区。
    ///
    /// 页头（大标题 / 副标题 / 可选右侧按钮）钉死在 pane 顶部 `46pt`——与左侧栏「设置」
    /// 大标题（`titleLabel.top == sidebar.top + 46`）严格同一基线，四个 Tab 切来切去顶部都不跑；
    /// 页头下方 14pt 一条 0.5pt 发丝线，再往下才是 `NSScrollView`，只有设置卡片会滚，
    /// 长页面滚到顶也不会把标题推进红绿灯区域。
    private func installFixedHeaderPage(header: NSView, sections: [NSView], into pane: NSView) {
        header.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(header)

        let hairline = SettingsHairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(hairline)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // .fullSizeContentView 窗口下系统会自动往 scrollView 顶部塞约 28pt contentInset，
        // 不关掉的话卡片区凭空下坠一截，页头与卡片之间的间距就变成「随系统版本漂移」的量。
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        pane.addSubview(scroll)

        let content = NSStackView(views: sections)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(
            top: 14,
            left: Self.contentPaddingH,
            bottom: 24,
            right: Self.contentPaddingH
        )
        content.translatesAutoresizingMaskIntoConstraints = false

        let doc = SettingsFlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        scroll.documentView = doc

        NSLayoutConstraint.activate([
            // 页头：与左侧「设置」大标题（46pt）水平齐平
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: 46),
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: Self.contentPaddingH),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Self.contentPaddingH),

            hairline.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            hairline.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: Self.contentPaddingH),
            hairline.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Self.contentPaddingH),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            scroll.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),

            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            content.topAnchor.constraint(equalTo: doc.topAnchor),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    // MARK: - 文案映射

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

// MARK: - 玻璃分隔线

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

private final class SettingsFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
