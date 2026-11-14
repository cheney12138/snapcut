import AppKit

/// 设置窗口（macOS 原生偏好面板观感）
///
/// - NSToolbar 三个可选中 tab：「通用」「快捷键」「关于」（toolbarStyle = .preference，
///   系统偏好同款居中布局）；三个等大小子视图叠在同一容器里切 isHidden，无闪烁。
/// - 无「确定/取消」按钮：任何控件改动立即 `store.save`，窗口关闭即生效。
/// - 视觉：NSStackView + 分组小号灰字标题，行高 32，左右 20pt 边距，系统控件原生皮肤
///   （与 ToolbarPanel 一致走 controlAccentColor，不自绘皮肤）。
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
    private var permBox: NSBox?
    private var permStatusDot: NSView?
    private var permStatusLabel: NSTextField?

    // 通用 tab 控件
    private var afterCapturePopup: NSPopUpButton!
    private var pathField: NSTextField!
    private var filenamePopup: NSPopUpButton!
    private var historyField: NSTextField!
    private var historyStepper: NSStepper!
    private var notifyCheck: NSButton!
    private var soundCheck: NSButton!

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
        NSApp.activate(ignoringOtherApps: true)
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
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

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
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
        pathField.widthAnchor.constraint(equalToConstant: 300).isActive = true

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

        // 复选框
        notifyCheck = NSButton(checkboxWithTitle: "复制后显示通知", target: self, action: #selector(notifyToggled(_:)))
        notifyCheck.font = .systemFont(ofSize: 13)
        soundCheck = NSButton(checkboxWithTitle: "截图音效", target: self, action: #selector(soundToggled(_:)))
        soundCheck.font = .systemFont(ofSize: 13)

        let stack = makeVerticalStack(rows: [
            groupHeader("截图"),
            row(fieldLabel("截图完成后"), afterCapturePopup),
            row(fieldLabel("保存目录"), pathField, chooseButton),
            groupHeader("文件"),
            row(fieldLabel("文件名"), filenamePopup),
            groupHeader("历史"),
            row(fieldLabel("历史保留"), historyField, historyStepper, unitLabel),
            groupHeader("通知"),
            row(notifyCheck),
            row(soundCheck),
        ])
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[1])   // 组内紧凑
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[4])
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[6])
        generalPane.addSubview(stack)
        pinStack(stack, to: generalPane)
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

    @objc private func notifyToggled(_ sender: NSButton) {
        settings.showCopyNotification = sender.state == .on
        persist()
    }

    @objc private func soundToggled(_ sender: NSButton) {
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

        let stack = makeVerticalStack(rows: [
            groupHeader("全局热键"),
            row(fieldLabel("区域截图"), regionRecorder),
            row(fieldLabel("全屏截图"), fullScreenRecorder),
            hotkeyHint,
        ])
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(2, after: stack.arrangedSubviews[2])
        hotkeyPane.addSubview(stack)
        pinStack(stack, to: hotkeyPane)
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

        let stack = NSStackView(views: [iconView, nameLabel, versionLabel, tagline])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(4, after: versionLabel)
        stack.setCustomSpacing(20, after: tagline)
        stack.translatesAutoresizingMaskIntoConstraints = false
        aboutPane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: aboutPane.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: aboutPane.centerYAnchor),
        ])

        // 权限状态卡片（用户裁定：权限情况放这里，不放托盘菜单）
        let permCard = NSBox()
        permCard.title = "屏幕录制权限"
        permCard.titlePosition = .noTitle
        permBox = permCard
        let permRow = NSStackView(views: [])
        permRow.orientation = .horizontal
        permRow.spacing = 10
        permRow.alignment = .centerY

        let statusDot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        permStatusDot = statusDot
        permRow.addArrangedSubview(statusDot)

        let statusLabel = NSTextField(labelWithString: "检查中…")
        statusLabel.font = .systemFont(ofSize: 12)
        permStatusLabel = statusLabel
        permRow.addArrangedSubview(statusLabel)

        let permButton = NSButton(title: "去授权…", target: self, action: #selector(openPermissionSettings))
        permButton.bezelStyle = .rounded
        permButton.controlSize = .regular
        permRow.addArrangedSubview(permButton)

        let permHint = NSTextField(labelWithString: "无权限时无法截屏；授权后需重启 Snapcut")
        permHint.font = .systemFont(ofSize: 10.5)
        permHint.textColor = .secondaryLabelColor

        let permStack = NSStackView(views: [permRow, permHint])
        permStack.orientation = .vertical
        permStack.alignment = .leading
        permStack.spacing = 6
        permStack.translatesAutoresizingMaskIntoConstraints = false
        permCard.contentView = permStack
        permCard.translatesAutoresizingMaskIntoConstraints = false
        aboutPane.addSubview(permCard)
        NSLayoutConstraint.activate([
            permCard.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            permCard.centerXAnchor.constraint(equalTo: aboutPane.centerXAnchor),
            permCard.widthAnchor.constraint(equalToConstant: 300),
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
            Log.event(.app, "settings.permission", ["state": "granted"])
        } else {
            permStatusDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
            permStatusLabel?.stringValue = "未授权（截屏不可用）"
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
        notifyCheck.state = settings.showCopyNotification ? .on : .off
        soundCheck.state = settings.playCaptureSound ? .on : .off
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

    // MARK: - 布局助手（分组标题小号灰字 / 行高 32 / 左右 20pt）

    private func makeVerticalStack(rows: [NSView]) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func pinStack(_ stack: NSStackView, to pane: NSView) {
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
        ])
    }

    private func groupHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        return label
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true  // 560 − 左右 20×2
        stack.heightAnchor.constraint(equalToConstant: 32).isActive = true  // 行高 32
        return stack
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
