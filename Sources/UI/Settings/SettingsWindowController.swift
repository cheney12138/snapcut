import AppKit

/// 设置窗口（System Settings 同款玻璃分组卡观感）
///
/// - NSToolbar 三个可选中 tab：「通用」「快捷键」「关于」（toolbarStyle = .preference，
///   系统偏好同款居中布局）；三个等大小子视图叠在同一容器里切 isHidden，无闪烁。
/// - 无「确定/取消」按钮：任何控件改动立即 `store.save`，窗口关闭即生效。
/// - 视觉（延展设计真源 toolbar 的玻璃语言，真源无 settings 场景）：
///   窗体档 3 全窗磨砂（mat.sidebar，满铺含 titlebar，明暗自适应）+ 磨砂分组卡
///   radius 10 圆角 + 明暗自适应描边
///   （暗色 rgba(255,255,255,.12) / 亮色 rgba(0,0,0,.09)，对齐真源 --glass-stroke/--glass-edge）；
///   分组标题 11pt semibold secondary；行式设置左标签右控件，行高 36，8pt 栅格（间距 8/12）；
///   分隔线 0.5pt 暗色 rgba(255,255,255,.12) / 亮色 rgba(0,0,0,.085)（对齐 --hair）；
///   品牌色走 controlAccentColor（暗色即 #0A84FF），字体 SF Pro 体系。
/// - 六边形纪律：只依赖端口 `SettingsStoring`，适配器由合成根注入（主会话接线）。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSControlTextEditingDelegate {

    static let shared = SettingsWindowController()

    // MARK: - Tab 标识

    private static let tabGeneral = NSToolbarItem.Identifier("snapcut.settings.tab.general")
    private static let tabHotkeys = NSToolbarItem.Identifier("snapcut.settings.tab.hotkeys")
    private static let tabAbout = NSToolbarItem.Identifier("snapcut.settings.tab.about")

    // MARK: - 状态

    private var store: (any SettingsStoring)?
    private var settings = AppSettings.defaultSettings

    private var windowBuilt = false
    private var panesBuilt = false

    private let generalPane = NSView()
    private let hotkeyPane = NSView()
    private let aboutPane = NSView()
    private var permStatusDot: NSView?
    private var permButtonRef: NSButton?
    private var permHintRef: NSTextField?
    private var permStatusLabel: NSTextField?

    // 通用 tab 控件
    private var afterCapturePopup: NSPopUpButton!
    private var pathField: NSTextField!
    private var filenamePopup: NSPopUpButton!
    private var historyField: NSTextField!
    private var historyStepper: NSStepper!
    private var notifySwitch: NSSwitch!
    private var soundSwitch: NSSwitch!

    // 快捷键 tab 控件
    private var regionRecorder: HotkeyRecorderView!
    private var fullScreenRecorder: HotkeyRecorderView!
    /// 编辑器热键（工具栏后半段 8 动作）录制器，key = action key
    private var editorRecorders: [String: HotkeyRecorderView] = [:]
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

    func show(store: SettingsStoring) {
        self.store = store
        settings = store.load()
        ensureWindow()
        refreshControls()
        // 病例：权限状态只在 buildAboutPane 时刷过一次（首次 open），用户事后
        // 授权再开窗口仍显示「未授权」旧文案——每次 open 都要重刷
        refreshPermissionStatus()
        // LSUIElement（.accessory 策略）下，系统协作激活不会真正把 App 切到前台：
        // 设置窗看起来在前，但用户一点面板，焦点就被让回之前的 App（窗「退后台」
        // + toolbar tab 点不动）。设置窗打开期间临时切 .regular，关闭时还原。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // mat.window / mat.card：窗口类界面跟随系统外观（迁移差异 §10-6，
        // token 表给了暗/亮双值；不再钉 darkAqua）
        window?.center()
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

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: DesignTokens.Settings.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Snapcut 设置"
        win.isReleasedWhenClosed = false
        win.toolbarStyle = .preference
        // 档 3 三件套：全窗磨砂必须满铺含 titlebar 区域，否则 titlebar 透明带
        // 直接穿底（系统 fallback 到透）。
        //   ① .fullSizeContentView：contentView 延伸到 titlebar 下，磨砂视图才
        //      能满铺；内容顶部用 safeAreaLayoutGuide 避开 toolbar（见 pinStack）
        //   ② isOpaque = false + backgroundColor = .clear：让窗底透出磨砂视图
        win.titlebarAppearsTransparent = true
        win.isOpaque = false
        win.backgroundColor = .clear

        let toolbar = NSToolbar(identifier: "snapcut.settings.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar
        win.delegate = self  // 需要 NSWindowDelegate（windowWillClose）

        let container = NSView(frame: NSRect(origin: .zero, size: DesignTokens.Settings.windowSize))
        // 档 3 窗底：全窗磨砂铺底（内容三层之下，含 titlebar 区域）
        let windowGlass = NSVisualEffectView()
        windowGlass.material = DesignTokens.Mat.window
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
        for pane in [generalPane, hotkeyPane, aboutPane] {
            container.addSubview(pane)
            pane.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: container.topAnchor),
                pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        win.contentView = container
        window = win
        selectTab(0)
    }

    // MARK: - Tab 切换（motion.crossfade：0.15s fade + 新 pane rise 4pt，不再瞬切）

    private func selectTab(_ index: Int) {
        let panes = [generalPane, hotkeyPane, aboutPane]
        guard panes.indices.contains(index) else { return }
        let incoming = panes[index]
        let wasHidden = incoming.isHidden
        for (i, pane) in panes.enumerated() where i != index {
            pane.isHidden = true
        }
        if wasHidden {
            incoming.isHidden = false
            incoming.alphaValue = 0
            incoming.wantsLayer = true
            if let layer = incoming.layer {
                // rise 4pt 起步（layer 未翻转 y-up：-4 = 视觉在下方）
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
        let id: NSToolbarItem.Identifier = index == 0
            ? Self.tabGeneral : (index == 1 ? Self.tabHotkeys : Self.tabAbout)
        window?.toolbar?.selectedItemIdentifier = id
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier {
        case Self.tabGeneral: selectTab(0)
        case Self.tabHotkeys: selectTab(1)
        case Self.tabAbout: selectTab(2)
        default: break
        }
    }

    // MARK: NSToolbarDelegate

    private var tabIdentifiers: [NSToolbarItem.Identifier] {
        [Self.tabGeneral, Self.tabHotkeys, Self.tabAbout]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.tabGeneral:
            item.label = "通用"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "通用")
        case Self.tabHotkeys:
            item.label = "快捷键"
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "快捷键")
        case Self.tabAbout:
            item.label = "关于"
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "关于")
        default:
            return nil
        }
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    // MARK: - 窗口关闭：退出录制态（设置本身已即时保存，无需收尾）

    func windowWillClose(_ notification: Notification) {
        regionRecorder?.endRecordingIfNeeded()
        fullScreenRecorder?.endRecordingIfNeeded()
        for r in editorRecorders.values { r.endRecordingIfNeeded() }
        // 设置窗关闭：还原 LSUIElement 形态（show() 里临时切的 .regular）。
        // 策略还原即自动让出前台，焦点回之前的 App。
        NSApp.setActivationPolicy(.accessory)
        Log.event(.app, "settings.window.close")
    }

    // MARK: - 通用 tab

    private func buildPanes() {
        buildGeneralPane()
        buildHotkeyPane()
        buildAboutPane()
    }

    private func buildGeneralPane() {
        // 截图完成后
        afterCapturePopup = NSPopUpButton()
        afterCapturePopup.translatesAutoresizingMaskIntoConstraints = false
        afterCapturePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        for action in AppSettings.AfterCaptureAction.allCases {
            let item = NSMenuItem(title: Self.afterCaptureLabel(action), action: nil, keyEquivalent: "")
            item.representedObject = action.rawValue
            afterCapturePopup.menu?.addItem(item)
        }
        afterCapturePopup.target = self
        afterCapturePopup.action = #selector(afterCaptureChanged(_:))

        // 保存目录（只读展示 + 选择…）
        pathField = NSTextField(string: "~/Pictures/Snapcut")
        pathField.isEditable = false
        pathField.font = .systemFont(ofSize: 12)
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let chooseButton = NSButton(title: "选择…", target: self, action: #selector(chooseDirectory(_:)))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small

        // 文件名
        filenamePopup = NSPopUpButton()
        filenamePopup.translatesAutoresizingMaskIntoConstraints = false
        filenamePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        for style in AppSettings.FilenameStyle.allCases {
            let item = NSMenuItem(title: Self.filenameLabel(style), action: nil, keyEquivalent: "")
            item.representedObject = style.rawValue
            filenamePopup.menu?.addItem(item)
        }
        filenamePopup.target = self
        filenamePopup.action = #selector(filenameChanged(_:))

        // 历史保留：NSTextField + NSStepper 联动（1–200）
        historyField = NSTextField(string: "30")
        historyField.alignment = .right
        historyField.font = .systemFont(ofSize: 12)
        historyField.translatesAutoresizingMaskIntoConstraints = false
        historyField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        historyField.target = self
        historyField.action = #selector(historyFieldSubmitted(_:))

        historyStepper = NSStepper()
        historyStepper.minValue = Double(AppSettings.historyLimitRange.lowerBound)
        historyStepper.maxValue = Double(AppSettings.historyLimitRange.upperBound)
        historyStepper.increment = 1
        historyStepper.doubleValue = 30
        historyStepper.target = self
        historyStepper.action = #selector(historyStepperChanged(_:))

        let unitLabel = NSTextField(labelWithString: "条（1–200）")
        unitLabel.font = .systemFont(ofSize: 12)
        unitLabel.textColor = .secondaryLabelColor

        // 开关（NSSwitch：System Settings 同款，行式左标签右开关）
        notifySwitch = NSSwitch()
        notifySwitch.target = self
        notifySwitch.action = #selector(notifyToggled(_:))
        soundSwitch = NSSwitch()
        soundSwitch.target = self
        soundSwitch.action = #selector(soundToggled(_:))

        // 四张磨砂分组卡（8pt 栅格：卡间距 12，卡内边距 12/16）
        let captureCard = makeGroupCard(title: "截图", rows: [
            row("截图完成后", trailing: [afterCapturePopup]),
            row("保存目录", trailing: [pathField, chooseButton]),
        ])
        let fileCard = makeGroupCard(title: "文件", rows: [
            row("文件名", trailing: [filenamePopup]),
        ])
        let historyCard = makeGroupCard(title: "历史", rows: [
            row("历史保留", trailing: [historyField, historyStepper, unitLabel]),
        ])
        let notifyCard = makeGroupCard(title: "通知", rows: [
            row("复制后显示通知", trailing: [notifySwitch]),
            row("截图音效", trailing: [soundSwitch]),
        ])

        // 工具栏排序（用户裁定 2026-11-17）：行序 = toolbarOrder；▲▼ 调序即时生效
        let orderCard = makeGroupCard(title: "工具栏排序", rows: buildToolbarOrderRows())

        let outer = NSStackView(views: [captureCard, orderCard, fileCard, historyCard, notifyCard])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        pinStack(outer, to: generalPane)
    }

    /// 工具栏排序行（▲▼ 调序；改动即 persist + 工具栏重建在下次会话生效）
    private func buildToolbarOrderRows() -> [NSView] {
        var rows: [NSView] = []
        let order = settings.toolbarOrderSafe()
        for (idx, raw) in order.enumerated() {
            let name: String
            switch raw {
            case 206: name = "滚动截图"
            default:
                name = EditorSession.Tool(rawValue: raw)?.label ?? "未知(\(raw))"
            }
            let label = NSTextField(labelWithString: "\(idx + 1). \(name)")
            label.font = .systemFont(ofSize: 12)

            let up = NSButton(title: "▲", target: self, action: #selector(toolbarOrderTapped(_:)))
            up.bezelStyle = .inline
            up.controlSize = .small
            up.isEnabled = idx > 0
            up.tag = raw * 10 + 0   // delta=-1 编码为末位 0

            let down = NSButton(title: "▼", target: self, action: #selector(toolbarOrderTapped(_:)))
            down.bezelStyle = .inline
            down.controlSize = .small
            down.isEnabled = idx < order.count - 1
            down.tag = raw * 10 + 2   // delta=+1 编码为末位 2

            rows.append(row(label.stringValue, trailing: [up, down]))
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
        guard let idx = settings.toolbarOrder.firstIndex(of: raw) else { return }
        let target = idx + delta
        guard target >= 0, target < settings.toolbarOrder.count else { return }
        settings.toolbarOrder.swapAt(idx, target)
        Log.event(.app, "settings.toolbarOrder", ["moved": "\(raw)", "to": "\(target)"])
        persist()
        rebuildOrderCard()
    }

    /// 排序卡整卡重建（行序即时反映）：通用页清空重 build + 切回显示
    private func rebuildOrderCard() {
        generalPane.subviews.forEach { $0.removeFromSuperview() }
        buildGeneralPane()
        selectTab(0)
    }

    @objc private func afterCaptureChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let action = AppSettings.AfterCaptureAction(rawValue: raw) else { return }
        settings.afterCapture = action
        persist()
    }

    @objc private func filenameChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let style = AppSettings.FilenameStyle(rawValue: raw) else { return }
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

    // NSTextField 输入联动（controlTextDidChange，识别 control 用 tag 区分）
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

    @objc private func notifyToggled(_ sender: NSSwitch) {
        settings.showCopyNotification = sender.state == .on
        persist()
    }

    @objc private func soundToggled(_ sender: NSSwitch) {
        settings.playCaptureSound = sender.state == .on
        persist()
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

    private func buildHotkeyPane() {
        regionRecorder = HotkeyRecorderView()
        fullScreenRecorder = HotkeyRecorderView()

        hotkeyHint = NSTextField(labelWithString: "")
        hotkeyHint.font = .systemFont(ofSize: 11)
        hotkeyHint.textColor = .systemRed
        hotkeyHint.isHidden = true

        wireRecorder(regionRecorder, other: fullScreenRecorder)
        wireRecorder(fullScreenRecorder, other: regionRecorder)

        // 磨砂分组卡（与通用页同一玻璃语言）：两行录制行 + 红字提示
        let card = makeGroupCard(title: "全局热键", rows: [
            row("区域截图", trailing: [regionRecorder]),
            row("全屏截图", trailing: [fullScreenRecorder]),
        ])

        // 编辑器操作热键（工具栏后半段，仅截图编辑时生效）
        var editorRows: [NSView] = []
        for (actionKey, label) in Self.editorHotkeyRows {
            let rec = HotkeyRecorderView()
            rec.allowBare = true
            rec.setCombo(settings.editorHotkey(for: actionKey))
            wireEditorRecorder(rec, actionKey: actionKey)
            editorRecorders[actionKey] = rec
            editorRows.append(row(label, trailing: [rec]))
        }
        let editorCard = makeGroupCard(title: "编辑器操作（截图编辑时生效）", rows: editorRows)

        // 提示容器：左缘对齐卡内行（窗边 20 + 卡内 16），避免直接挂栈顶产生 16pt 错位
        let hintWrap = NSView()
        hintWrap.translatesAutoresizingMaskIntoConstraints = false
        hintWrap.widthAnchor.constraint(equalToConstant: 520).isActive = true
        hintWrap.addSubview(hotkeyHint)
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hotkeyHint.leadingAnchor.constraint(equalTo: hintWrap.leadingAnchor, constant: 16),
            hotkeyHint.topAnchor.constraint(equalTo: hintWrap.topAnchor),
            hotkeyHint.bottomAnchor.constraint(equalTo: hintWrap.bottomAnchor),
        ])

        let outer = NSStackView(views: [card, editorCard, hintWrap])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 0
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        outer.setCustomSpacing(8, after: card)
        outer.setCustomSpacing(8, after: editorCard)
        pinStack(outer, to: hotkeyPane)
    }

    /// 编辑器热键录制：进入录制时停掉所有其他录制器（全局两个 + 编辑器八个）
    private func wireEditorRecorder(_ recorder: HotkeyRecorderView, actionKey: String) {
        recorder.onStart = { [weak self, weak recorder] in
            self?.regionRecorder?.endRecordingIfNeeded()
            self?.fullScreenRecorder?.endRecordingIfNeeded()
            for (k, r) in self?.editorRecorders ?? [:] where k != actionKey {
                r.endRecordingIfNeeded()
            }
            self?.hotkeyHint.isHidden = true
            _ = recorder
        }
        recorder.onCombo = { [weak self, weak recorder] combo in
            guard let self, let recorder else { return }
            self.handleEditorCombo(from: recorder, actionKey: actionKey, combo: combo)
        }
    }

    private func handleEditorCombo(from recorder: HotkeyRecorderView, actionKey: String, combo: String?) {
        guard let combo else {
            hotkeyHint.stringValue = "组合无效：需含修饰键，或单个字母/数字键"
            hotkeyHint.isHidden = false
            return
        }
        // 冲突检查：其他编辑器动作 + 全局热键 + 内置保留键（S=滚动 / C=取色 / 空格=移动 / 1-6=工具 / ⌘⌥S=快存）
        for rowDef in Self.editorHotkeyRows where rowDef.key != actionKey {
            if settings.editorHotkey(for: rowDef.key) == combo {
                hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被「\(rowDef.label)」占用"
                hotkeyHint.isHidden = false
                return
            }
        }
        if combo == settings.hotkeyRegion {
            hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被「区域截图（全局）」占用"
            hotkeyHint.isHidden = false
            return
        }
        if combo == settings.hotkeyFullScreen {
            hotkeyHint.stringValue = "「\(HotkeySpec.display(combo))」已被「全屏截图（全局）」占用"
            hotkeyHint.isHidden = false
            return
        }
        let reserved: [String: String] = ["c": "取色", "space": "移动贴图", "cmd+opt+s": "快速保存"]
        // （s 不再内置保留：滚动截图已可自定义，同组冲突检查会指到「滚动截图」行）
        if let name = reserved[combo] {
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

    private func wireRecorder(_ recorder: HotkeyRecorderView, other: HotkeyRecorderView) {
        recorder.onStart = { [weak self, weak recorder, weak other] in
            other?.endRecordingIfNeeded()
            self?.hotkeyHint.isHidden = true
            _ = recorder
        }
        recorder.onCombo = { [weak self, weak recorder] combo in
            guard let self, let recorder else { return }
            self.handleCombo(from: recorder, combo)
        }
    }

    /// 录制结果落设置：nil = 非法（缺修饰键）→ 红字提示不崩；占用 → 红字提示
    private func handleCombo(from recorder: HotkeyRecorderView, _ combo: String?) {
        guard let combo else {
            hotkeyHint.stringValue = "组合无效：必须包含至少一个修饰键（⌘ / ⇧ / ⌥ / ⌃）"
            hotkeyHint.isHidden = false
            return
        }
        let isRegion = recorder === regionRecorder
        let otherCombo = isRegion ? settings.hotkeyFullScreen : settings.hotkeyRegion
        let otherName = isRegion ? "全屏截图" : "区域截图"
        if combo == otherCombo {
            hotkeyHint.stringValue = "「\(combo)」已被「\(otherName)」占用"
            hotkeyHint.isHidden = false
            return
        }
        hotkeyHint.isHidden = true
        if isRegion {
            settings.hotkeyRegion = combo
            regionRecorder.setCombo(combo)
        } else {
            settings.hotkeyFullScreen = combo
            fullScreenRecorder.setCombo(combo)
        }
        Log.event(.app, "settings.hotkey", [
            "slot": isRegion ? "region" : "fullScreen",
            "combo": combo,
        ])
        persist()
    }

    // MARK: - 关于 tab

    private func buildAboutPane() {
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let nameLabel = NSTextField(labelWithString: "Snapcut")
        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let versionLabel = NSTextField(labelWithString: "版本 \(version)")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let tagline = NSTextField(labelWithString: "本地运行 · 无账户 · 不联网")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor

        // 权限状态（用户裁定：权限情况放这里，不放托盘菜单）
        // 病例（用户实报「字都对不齐」）：旧实现 icon 栈 centerY 居中 + NSBox
        // 挂在栈底，box 高度不受约束 ⇒ 渲染重叠。重写为单一垂直栈，全部内容
        // 一起居中，行内用 leading/centerY 对齐，不再有第二套坐标系。
        let statusDot = NSView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        permStatusDot = statusDot

        let statusLabel = NSTextField(labelWithString: "检查中…")
        statusLabel.font = .systemFont(ofSize: 12)
        permStatusLabel = statusLabel

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let permButton = NSButton(title: "去授权…", target: self, action: #selector(openPermissionSettings))
        permButton.bezelStyle = .rounded
        permButton.controlSize = .small
        permButton.font = .systemFont(ofSize: 11, weight: .medium)
        permButtonRef = permButton

        let permRow = NSStackView(views: [statusDot, statusLabel, spacer, permButton])
        permRow.orientation = .horizontal
        permRow.alignment = .centerY
        permRow.spacing = 8
        permRow.translatesAutoresizingMaskIntoConstraints = false
        permRow.widthAnchor.constraint(equalToConstant: 292).isActive = true

        let permHint = NSTextField(labelWithString: "")
        permHint.font = .systemFont(ofSize: 11)
        permHint.textColor = .secondaryLabelColor
        permHintRef = permHint

        // 权限状态卡：与通用/快捷键页同一磨砂卡（玻璃语言统一，不再用 NSBox/分离 hairline）
        let permCard = makeGlassCard()
        let permStack = NSStackView(views: [permRow, permHint])
        permStack.orientation = .vertical
        permStack.alignment = .leading
        permStack.spacing = 8
        permStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        permStack.translatesAutoresizingMaskIntoConstraints = false
        permCard.addSubview(permStack)
        NSLayoutConstraint.activate([
            permStack.topAnchor.constraint(equalTo: permCard.topAnchor),
            permStack.bottomAnchor.constraint(equalTo: permCard.bottomAnchor),
            permStack.leadingAnchor.constraint(equalTo: permCard.leadingAnchor),
            permStack.trailingAnchor.constraint(equalTo: permCard.trailingAnchor),
        ])

        let stack = NSStackView(views: [
            iconView, nameLabel, versionLabel, tagline,
            permCard,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(4, after: versionLabel)
        stack.setCustomSpacing(24, after: tagline)
        stack.translatesAutoresizingMaskIntoConstraints = false
        aboutPane.addSubview(stack)
        // fullSizeContentView 下用 safeArea 居中，避免被 toolbar 高度带偏
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: aboutPane.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: aboutPane.safeAreaLayoutGuide.centerYAnchor),
        ])
        refreshPermissionStatus()
    }

    /// 权限状态刷新（打开窗口 / 每次 buildAbout 时调用）
    @MainActor
    private func refreshPermissionStatus() {
        let granted = AppCoordinatorShared.deps?.permission.isGranted() ?? false
        if granted {
            permStatusDot?.layer?.backgroundColor = NSColor.systemGreen.cgColor
            permStatusLabel?.stringValue = "已授权"
            permButtonRef?.isHidden = true
            permHintRef?.stringValue = "权限正常，⌘⇧A 随时可用"
            Log.event(.app, "settings.permission", ["state": "granted"])
        } else {
            permStatusDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
            permStatusLabel?.stringValue = "未授权（截屏不可用）"
            permButtonRef?.isHidden = false
            permHintRef?.stringValue = "未授权时无法截屏；授权后需重启 Snapcut"
            Log.event(.app, "settings.permission", ["state": "denied"])
        }
    }

    @objc private func openPermissionSettings() {
        TCCPermission.openSystemSettings()
    }

    // MARK: - 刷新（打开窗口时从设置回填控件）

    private func refreshControls() {
        selectPopup(afterCapturePopup, rawValue: settings.afterCapture.rawValue)
        selectPopup(filenamePopup, rawValue: settings.filenameStyle.rawValue)
        pathField.stringValue = settings.saveDirectoryPath
        historyField.stringValue = "\(settings.historyLimit)"
        historyStepper.doubleValue = Double(
            min(max(settings.historyLimit, AppSettings.historyLimitRange.lowerBound),
                AppSettings.historyLimitRange.upperBound)
        )
        notifySwitch.state = settings.showCopyNotification ? .on : .off
        soundSwitch.state = settings.playCaptureSound ? .on : .off
        regionRecorder?.setCombo(settings.hotkeyRegion)
        fullScreenRecorder?.setCombo(settings.hotkeyFullScreen)
        hotkeyHint?.isHidden = true
    }

    private func selectPopup(_ popup: NSPopUpButton?, rawValue: String) {
        guard let popup,
              let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == rawValue })
        else { return }
        popup.selectItem(at: index)
    }

    private func persist() {
        guard let store else { return }
        store.save(settings)  // 适配器内打 settings.save 日志
        // 即时回灌 + 全局热键重绑（病例「改完不生效」：全局键注册只在
        // 启动，改键后要重启——rebind 即时重注册 Carbon）
        AppCoordinatorShared.coordinator?.settings = settings
        AppCoordinatorShared.coordinator?.rebindCaptureHotkeys()
    }

    // MARK: - 布局助手（磨砂分组卡 / 行高 36 / 8pt 栅格）

    /// 磨砂分组卡基元：分组卡不再自带材质（窗底已档 3 磨砂），改为
    /// radius 10 + fillCard 底（白 .045/黑 .04）+ 0.5pt stroke + 顶缘 inset.hi
    private func makeGlassCard() -> GlassCardView {
        let card = GlassCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    /// 分组卡：11pt 灰字分组标题 + 行式设置行，行间 0.5pt 自适应分隔线
    private func makeGroupCard(title: String, rows: [NSView]) -> GlassCardView {
        let card = makeGlassCard()

        var content: [NSView] = [groupHeader(title)]
        for (i, rowView) in rows.enumerated() {
            if i > 0 {
                let hair = HairlineView()
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
        // 分组卡内距：4/16/6（tokens §9 设置窗规格）；标题自身承载上呼吸
        stack.edgeInsets = NSEdgeInsets(top: 4, left: DesignTokens.Settings.cardPaddingH,
                                        bottom: DesignTokens.Settings.cardPaddingBottom,
                                        right: DesignTokens.Settings.cardPaddingH)
        stack.setCustomSpacing(8, after: content[0])   // 标题 → 首行
        for (i, sub) in content.enumerated() where sub is HairlineView {
            stack.setCustomSpacing(0, after: sub)
            if i > 0 { stack.setCustomSpacing(0, after: content[i - 1]) }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    private func groupHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = DesignTokens.Font.noteSemibold
        label.textColor = DesignTokens.label2
        // gcard-title：padding 12 0 6（上呼吸由标题自己承载）
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

    /// 行式设置：左标签（左对齐 13pt）+ 弹性空隙 + 右侧控件（8pt 栅格，行高 38）
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

    private static let rowWidth: CGFloat = 488   // 560 − 窗边 20×2 − 卡内边距 16×2

    private func pinStack(_ stack: NSStackView, to pane: NSView) {
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            // fullSizeContentView：顶部用 safeArea（避开 toolbar/titlebar 区），
            // 否则卡片压进 titlebar 区（磨砂上叠 toolbar）
            stack.topAnchor.constraint(equalTo: pane.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
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

// MARK: - 玻璃基元（分组卡 / 分隔线；token：fillCard / stroke / hair，明暗双值）

/// 分组卡：radius 10 + fillCard 底（暗 白.045 / 亮 黑.04）+ 0.5pt 卡专属描边（暗 白.10 / 亮 黑.08）
/// （窗底已是档 3 磨砂，卡自身不再叠材质；跟随系统外观。
///  轻盈感审查：描边 白.14 → 白.10 ——卡是区域不是盒子；inset.hi 顶缘高光删除——
///  α.045 层级差上的高光是装饰不是信息，玻璃三档的卡容器才需要）
@MainActor
private final class GlassCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    override func layout() {
        super.layout()
        applyChrome()
    }

    private func applyChrome() {
        layer?.cornerRadius = DesignTokens.Radius.lg
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = DesignTokens.Settings.cardStroke.cgColor
        layer?.backgroundColor = DesignTokens.fillCard.cgColor
    }

    static var isDarkAppearance: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// 0.5pt 分隔线：暗 白.12 / 亮 黑.10（token hair），随明暗模式刷新
@MainActor
private final class HairlineView: NSView {

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

// MARK: - 热键录制控件（点击进入录制态，keyDown 捕获组合，Esc 取消）

@MainActor
private final class HotkeyRecorderView: NSButton {

    /// 录到合法组合回调；nil = 非法组合。
    /// allowBare = true（编辑器热键）：裸字母/数字合法（"o"），带修饰键的
    /// 命名键合法（"cmd+return"）；裸命名键仍非法（return/esc 与录制控件
    /// 自身的确认/取消语义冲突）。
    var allowBare = false
    var onCombo: (String?) -> Void = { _ in }
    /// 进入录制态回调（取消另一个录制器、隐藏红字提示）
    var onStart: () -> Void = {}

    private(set) var isRecording = false
    private var combo: String

    init() {
        self.combo = ""
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.sm
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 160).isActive = true
        heightAnchor.constraint(equalToConstant: DesignTokens.Control.recorderHeight).isActive = true
        installRecordingDot()
        updateDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// 录制态呼吸点（7pt accent，1s blink；tokens §7 热键录制器）
    private var recordingDot: NSView?

    private func installRecordingDot() {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = DesignTokens.accent.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        dot.isHidden = true
        addSubview(dot)
        recordingDot = dot
        // 点在文字左侧：布局用 leading 约束，updateDisplay 时启用/停用
        dotLeadingConstraint = dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        dotLeadingConstraint?.isActive = true
        NSLayoutConstraint.activate([
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.25
        anim.duration = 1.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(anim, forKey: "rec.blink")
    }

    private var dotLeadingConstraint: NSLayoutConstraint?
    func setCombo(_ combo: String) {
        self.combo = combo
        updateDisplay()
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: 录制态

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

    /// 录制成功确认（用户病例 2026-11-16 二报「输入完回车了还有蓝框，丑」：
    /// accent 底/边做确认脉冲会被误读成「还在录制态」且恢复链偶发不回）。
    /// 改用与录制态零歧义的反馈：文案「✓ 新组合」短暂显示（0.8s 后回正常值）
    /// + 整体透明度轻脉冲——状态色完全不参与，不可能残留蓝框
    private func flashConfirmed() {
        guard !isRecording else { return }
        attributedTitle = NSAttributedString(string: "✓ " + Self.symbolString(for: combo), attributes: [
            .font: DesignTokens.Font.kbd,
            .foregroundColor: DesignTokens.label1,
        ])
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
        let text = isRecording ? "按下新组合…" : Self.symbolString(for: combo)
        // t.kbd（11/medium）；录制态文字 label.1、常态 label.1（设计 .hk/.kk 同色）
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: DesignTokens.Font.kbd,
            .foregroundColor: isRecording ? DesignTokens.label1 : DesignTokens.label2,
        ])
        // 录制态：accent.ring 1.5pt 外环（审查：2.5pt 占 22pt 控件高 11% 比例失真，
        // 降到 1.5 阶内 + α.55 补偿）；常态透明 + 0.5pt stroke（审查：22pt 控件加底
        // 色显「块」，系统热键录制是空框语气）。描边变化 0.18s ease-out 过渡
        if let layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = isRecording ? 1.5 : 0.5
            layer.borderColor = (isRecording ? DesignTokens.accentRing : DesignTokens.stroke).cgColor
            CATransaction.commit()
        }
        recordingDot?.isHidden = !isRecording
    }

    // 覆盖按钮默认点击（不 sendAction，仅进录制态）
    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func mouseUp(with event: NSEvent) {
        // 吞掉按钮默认行为
    }

    // MARK: keyDown 捕获

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
            // 编辑器热键：裸字母/数字合法（原 O/P/H 语义）；裸命名键非法
            // 裸键白名单：字母/数字 + F 键（用户病例「f1 录不进去」——录制侧
            // 的裸键判定只认单字符，F1-F12 两字符被拒）
            // F 键白名单对两类录制器都放行（用户裁定 2026-11-17 终报「改不了
            // 我再给你最后一次机会」——全局热键行录 F1 也被「需含修饰键」拒）。
            // F 键无打字冲突，裸用作全局热键也安全
            let isBareFKey = key.count == 2 && key.hasPrefix("f") && (key.dropFirst().first?.isNumber == true)
            if isBareFKey {
                onCombo(key)
                isRecording = false
                updateDisplay()
                window?.makeFirstResponder(nil)
                flashConfirmed()
                return
            }
            if allowBare, (key.count == 1 && (key.first?.isLetter == true || key.first?.isNumber == true)) {
                onCombo(key)
                isRecording = false
                updateDisplay()
                // 录完立即交还焦点（病例三报「还有蓝框」：录完按钮仍是 first
                // responder——系统 keyboard focus ring 蓝框围着它，与 layer
                // border 无关，resign 才消）
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

    // MARK: 字符串 ⇄ 显示符号（"cmd+shift+a" ⇄ "⌘⇧A"）

    private static func keyName(for event: NSEvent) -> String {
        if let named = specialKeys[event.keyCode] { return named }
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 {
            return chars
        }
        return "key\(event.keyCode)"
    }

    static func symbolString(for combo: String) -> String {
        let parts = combo.split(separator: "+").map(String.init)
        guard let key = parts.last else { return combo }
        var prefix = ""
        for mod in parts.dropLast() {
            switch mod {
            case "cmd": prefix += "⌘"
            case "shift": prefix += "⇧"
            case "opt": prefix += "⌥"
            case "ctrl": prefix += "⌃"
            default: break
            }
        }
        return prefix + (key.count == 1 ? key.uppercased() : key)
    }

    private static let specialKeys: [UInt16: String] = [
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "esc",
        115: "home", 116: "pageup", 117: "forwarddelete", 119: "end", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        123: "left", 124: "right", 125: "down", 126: "up",
    ]
}
