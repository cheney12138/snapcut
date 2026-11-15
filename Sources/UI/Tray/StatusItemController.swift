import AppKit

/// 托盘菜单的 NSMenu 版本（坑 29 后职责收窄）：
/// - 菜单栏图标已切 SwiftUI MenuBarExtra（Tahoe CC 会藏手写 NSStatusItem）
/// - 本类只保留 NSMenu 构建，服务 ⌥⌘H「光标处弹菜单」兜底 + selftest 钩子
@MainActor
final class StatusItemController: NSObject {
    
    private weak var coordinator: AppCoordinator?
    private var rootMenu: NSMenu?
    private var historyMenu: NSMenu?

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
        menu.addItem(captureItem)

        let fullScreenItem = NSMenuItem(
            title: "截取全屏  \(HotkeySpec.display(settings.hotkeyFullScreen))",
            action: #selector(captureFullScreen(_:)),
            keyEquivalent: ""
        )
        fullScreenItem.target = self
        menu.addItem(fullScreenItem)

        // 历史记录子菜单（点击条目 = 复制该图；每次弹出前重建，保证实时）
        let historyItem = NSMenuItem(title: "历史记录", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        self.historyMenu = historyMenu
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

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

    /// 图标被系统隐藏时的替代入口：在光标处弹出同一个菜单
    /// （⌥⌘H 触发；菜单内容、历史子菜单重建逻辑与图标点击完全一致）
    func showMenuAtCursor() {
        if let historyMenu { rebuildHistoryMenu(historyMenu) }
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

    /// 自测：重建历史子菜单并回报条目（不弹菜单）——验证接线用
    func selfTestDumpHistoryMenu() {
        guard let historyMenu else { return }
        rebuildHistoryMenu(historyMenu)
        Log.event(.tray, "tray.history.dump", [
            "count": "\(historyMenu.items.count)",
            "first": historyMenu.items.first?.title ?? "-",
        ])
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = HistoryStore.shared.items().first(where: { $0.id == id }) else { return }
        _ = HistoryStore.shared.copyToPasteboard(item)
        Log.event(.tray, "tray.action", ["item": "copyHistory", "id": id])
    }

    @objc private func clearHistory(_ sender: Any?) {
        HistoryStore.shared.clearAll()
        Log.event(.tray, "tray.action", ["item": "clearHistory"])
    }

    @objc private func captureFullScreen(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "captureFullScreen"])
        coordinator?.beginFullScreenCapture()
    }

    @objc private func captureDelayed(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "captureDelayed"])
        coordinator?.beginDelayedCapture(seconds: 3)
    }

    @objc private func openSettings(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "openSettings"])
        SettingsWindowController.shared.show(store: UserDefaultsSettingsStore())
    }

    @objc private func quit(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "quit"])
        NSApp.terminate(nil)
    }
}

// MARK: - 历史菜单（每次展开重建：缩略图 + 时间 + 尺寸）

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildHistoryMenu(menu)
}

private func rebuildHistoryMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    let items = HistoryStore.shared.items()
    if items.isEmpty {
        let empty = NSMenuItem(title: "（暂无记录）", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        menu.addItem(empty)
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm:ss"
    Log.event(.tray, "tray.history.menu", ["count": "\(items.count)"])
    for item in items.prefix(30) {
        let size = "\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))"
        let menuItem = NSMenuItem(
            title: "\(formatter.string(from: item.date))  ·  \(size)",
            action: #selector(copyHistoryItem(_:)),
            keyEquivalent: ""
        )
        menuItem.target = self
        menuItem.representedObject = item.id
        if let thumb = HistoryStore.shared.thumbnail(for: item, maxSize: 16) {
            menuItem.image = thumb
        }
        menu.addItem(menuItem)
    }
    menu.addItem(.separator())
    let clear = NSMenuItem(title: "清空历史", action: #selector(clearHistory(_:)), keyEquivalent: "")
    clear.target = self
    menu.addItem(clear)
}
}
