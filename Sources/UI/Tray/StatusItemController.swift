import AppKit

/// 托盘菜单的 NSMenu 版本（坑 29 后职责收窄）：
/// - 菜单栏图标已切 SwiftUI MenuBarExtra（Tahoe CC 会藏手写 NSStatusItem）
/// - 本类只保留 NSMenu 构建，服务 ⌥⌘H「光标处弹菜单」兜底 + selftest 钩子
@MainActor
final class StatusItemController: NSObject {
    
    private weak var coordinator: AppCoordinator?
    private var rootMenu: NSMenu?
    private var captureItem: NSMenuItem?
    private var fullScreenItem: NSMenuItem?
    private var historySpotlightItem: NSMenuItem?

    override init() {
        super.init()
    }

    func setup(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _ = buildMenu()
        Log.event(.tray, "tray.setup.menuOnly", [:])
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let versionItem = NSMenuItem(
            title: "Snapcut \(version)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        // 快捷键显示跟随实际设置（Carbon 注册的真值；菜单里只是展示）
        let settings = coordinator?.settings ?? AppSettings.defaultSettings
        let captureItem = NSMenuItem(
            title: "截取区域  \(HotkeySpec.display(settings.hotkeyRegion))",
            action: #selector(captureRegion(_:)),
            keyEquivalent: ""
        )
        captureItem.target = self
        self.captureItem = captureItem
        menu.addItem(captureItem)

        let fullScreenItem = NSMenuItem(
            title: "截取全屏  \(HotkeySpec.display(settings.hotkeyFullScreen))",
            action: #selector(captureFullScreen(_:)),
            keyEquivalent: ""
        )
        fullScreenItem.target = self
        self.fullScreenItem = fullScreenItem
        menu.addItem(fullScreenItem)

        let historySpotlightItem = NSMenuItem(
            title: "搜索视觉记忆  \(HotkeySpec.display(settings.hotkeyHistorySpotlight))",
            action: #selector(openHistorySpotlight(_:)),
            keyEquivalent: ""
        )
        historySpotlightItem.target = self
        self.historySpotlightItem = historySpotlightItem
        menu.addItem(historySpotlightItem)

        let togglePinsItem = NSMenuItem(
            title: "隐藏/显示全部贴图  ⌥ ⌘ P",
            action: #selector(toggleAllPins(_:)),
            keyEquivalent: ""
        )
        togglePinsItem.target = self
        menu.addItem(togglePinsItem)

        menu.addItem(.separator())

        let delayItem = NSMenuItem(
            title: "延时 3 秒截图",
            action: #selector(captureDelayed(_:)),
            keyEquivalent: ""
        )
        delayItem.target = self
        menu.addItem(delayItem)

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        // 与 SwiftUI 菜单栏版本保持同一语义（两处动作必须一致，否则 ⌥⌘H 兜底菜单
        // 会少一项功能）
        let updateItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 Snapcut",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        self.rootMenu = menu
        return menu
    }

    /// 图标被系统隐藏时的替代入口：在光标处弹出同一个菜单（⌥⌘H 触发）
    func showMenuAtCursor() {
        if let settings = coordinator?.settings {
            captureItem?.title = "截取区域  \(HotkeySpec.display(settings.hotkeyRegion))"
            fullScreenItem?.title = "截取全屏  \(HotkeySpec.display(settings.hotkeyFullScreen))"
            historySpotlightItem?.title = "搜索视觉记忆  \(HotkeySpec.display(settings.hotkeyHistorySpotlight))"
        }
        guard let rootMenu else { return }
        let mouse = NSEvent.mouseLocation
        // accessory App 在后台时 popUp 不会显示，必须先激活自己
        NSApp.activate(ignoringOtherApps: true)
        Log.event(.tray, "tray.menu.atCursor", ["x": "\(Int(mouse.x))", "y": "\(Int(mouse.y))"])
        DispatchQueue.main.async {
            rootMenu.popUp(positioning: nil, at: NSPoint(x: mouse.x, y: mouse.y), in: nil)
        }
    }

    // MARK: - 菜单动作

    @objc private func captureRegion(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "captureRegion"])
        coordinator?.beginRegionCapture()
    }

    /// 自测：回报托盘菜单项（不弹菜单）——验证接线用
    func selfTestDumpHistoryMenu() {
        guard let rootMenu else { return }
        Log.event(.tray, "tray.menu.dump", [
            "count": "\(rootMenu.items.count)",
            "first": rootMenu.items.first?.title ?? "-",
        ])
    }

    @objc private func captureFullScreen(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "captureFullScreen"])
        coordinator?.beginFullScreenCapture()
    }

    @objc private func openHistorySpotlight(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "historySpotlight"])
        coordinator?.toggleHistorySpotlight()
    }

    @objc private func toggleAllPins(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "togglePins"])
        AppCoordinatorShared.coordinator?.toggleAllPinsVisibility()
    }

    @objc private func captureDelayed(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "captureDelayed"])
        coordinator?.beginDelayedCapture(seconds: 3)
    }

    @objc private func openSettings(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "openSettings"])
        SettingsWindowController.shared.show(store: UserDefaultsSettingsStore())
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "checkUpdates"])
        coordinator?.deps.updating.checkForUpdates()
    }

    @objc private func quit(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "quit"])
        SnapcutQuitController.quit()
    }
}
