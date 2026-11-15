import AppKit

/// 设置窗口（System Settings 同款玻璃分组卡观感）
///
/// - NSToolbar 三个可选中 tab：「通用」「快捷键」「关于」（toolbarStyle = .preference，
///   系统偏好同款居中布局）；三个等大小子视图叠在同一容器里切 isHidden，无闪烁。
/// - 无「确定/取消」按钮：任何控件改动立即 `store.save`，窗口关闭即生效。
/// - 视觉（延展设计真源 toolbar 的玻璃语言，真源无 settings 场景）：
///   磨砂分组卡 NSVisualEffectView .underWindowBackground + 圆角 12 + 明暗自适应描边
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
    private var hotkeyHint: NSTextField!

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: - 打开

    func show(store: SettingsStoring) {
        self.store = store
        settings = store.load()
        ensureWindow()
        refreshControls()
        // 病例：权限状态只在 buildAboutPane 时刷过一次（首次 open），用户事后
        // 授权再开窗口仍显示「未授权」旧文案——每次 open 都要重刷
        refreshPermissionStatus()
        NSApp.activate(ignoringOtherApps: true)
        // 玻璃语言钉暗色（浅色系统主题下 underWindowBackground/hudWindow 会解析成
        // 亮材质，白底白字不可读；与 ToolbarPanel 的 darkAqua 同源决策）
        window?.appearance = NSAppearance(named: .darkAqua)
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Snapcut 设置"
        win.isReleasedWhenClosed = false
        win.toolbarStyle = .preference

        let toolbar = NSToolbar(identifier: "snapcut.settings.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar
        win.delegate = self  // 需要 NSWindowDelegate（windowWillClose）

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
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

    // MARK: - Tab 切换（等大小子视图切 isHidden，无闪烁）

    private func selectTab(_ index: Int) {
        generalPane.isHidden = index != 0
        hotkeyPane.isHidden = index != 1
        aboutPane.isHidden = index != 2
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

        let outer = NSStackView(views: [captureCard, fileCard, historyCard, notifyCard])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        pinStack(outer, to: generalPane)
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

        let outer = NSStackView(views: [card, hintWrap])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 0
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        outer.setCustomSpacing(8, after: card)
        pinStack(outer, to: hotkeyPane)
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
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: aboutPane.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: aboutPane.centerYAnchor),
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
    }

    // MARK: - 布局助手（磨砂分组卡 / 行高 36 / 8pt 栅格）

    /// 磨砂玻璃卡基元：.underWindowBackground 磨砂 + 圆角 12 + 明暗自适应描边
    private func makeGlassCard() -> GlassCardView {
        let card = GlassCardView()
        card.material = .underWindowBackground
        card.blendingMode = .behindWindow
        card.state = .active
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
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.setCustomSpacing(10, after: content[0])   // 标题 → 首行
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
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 行式设置：左标签（左对齐 13pt）+ 弹性空隙 + 右侧控件（8pt 栅格，行高 36）
    private func row(_ labelText: String, trailing: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [label, spacer] + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        stack.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return stack
    }

    private static let rowWidth: CGFloat = 488   // 560 − 窗边 20×2 − 卡内边距 16×2

    private func pinStack(_ stack: NSStackView, to pane: NSView) {
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
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

// MARK: - 玻璃基元（磨砂分组卡 / 明暗自适应分隔线）

/// 磨砂分组卡：.underWindowBackground 磨砂 + 圆角 12 + 描边随明暗模式切换
/// （暗色 rgba(255,255,255,.12) / 亮色 rgba(0,0,0,.09)，对齐设计真源 glass-stroke/glass-edge）
@MainActor
private final class GlassCardView: NSVisualEffectView {

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
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = Self.edgeColor.cgColor
    }

    private static var edgeColor: NSColor {
        isDarkAppearance ? NSColor.white.withAlphaComponent(0.12)
                         : NSColor.black.withAlphaComponent(0.09)
    }

    static var isDarkAppearance: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// 0.5pt 分隔线：暗色 rgba(255,255,255,.12) / 亮色 rgba(0,0,0,.085)，随明暗模式刷新
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
        layer?.backgroundColor = (GlassCardView.isDarkAppearance
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.085)).cgColor
    }
}

// MARK: - 热键录制控件（点击进入录制态，keyDown 捕获组合，Esc 取消）

@MainActor
private final class HotkeyRecorderView: NSButton {

    /// 录到合法组合（含修饰键）回调；nil = 非法组合
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
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 160).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        updateDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

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

    private func updateDisplay() {
        let text = isRecording ? "按下新组合…" : Self.symbolString(for: combo)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .medium : .regular),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
        ])
        layer?.backgroundColor = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.black.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = isRecording ? 1.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
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
        // 非法：必须含至少一个修饰键（红字提示，保持录制态可重按）
        guard !mods.isEmpty else {
            onCombo(nil)
            return
        }
        let key = Self.keyName(for: event)
        onCombo((mods + [key]).joined(separator: "+"))
        isRecording = false
        updateDisplay()
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
        122: "f1", 120: "f2", 99: "f3", 100: "f4", 101: "f5", 109: "f6",
        123: "left", 124: "right", 125: "down", 126: "up",
    ]
}
