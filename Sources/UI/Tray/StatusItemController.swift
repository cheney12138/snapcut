import AppKit

/// 菜单栏托盘（docs/03 §3：NSStatusItem + NSMenu 原生菜单）
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var coordinator: AppCoordinator?
    private var rootMenu: NSMenu?
    private var historyMenu: NSMenu?

    override init() {
        super.init()
    }

    func setup(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = IconFactory.statusIcon() // 品牌 mark 剪影（StatusMark.png 模板）
            button.imageScaling = .scaleProportionallyDown
            // 手动弹菜单：展开前重建历史子菜单（NSMenuDelegate 在 Swift 6 下跨隔离域
            // 传递 NSMenu 会触发并发检查，改用显式 popUpMenu）
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
        // ⚠️ 必须显式构建：改用「点击时 popUp」后不再有 item.menu = buildMenu()，
        // 少了这行 rootMenu/historyMenu 全为 nil（病例：托盘点击无反应、历史菜单空）
        _ = buildMenu()
        statusItem = item
        Log.event(.tray, "tray.icon.created", ["src": "mark-silhouette"])
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

        let captureItem = NSMenuItem(
            title: "截取区域",
            action: #selector(captureRegion(_:)),
            keyEquivalent: "a"
        )
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        menu.addItem(captureItem)

        let fullScreenItem = NSMenuItem(
            title: "截取全屏",
            action: #selector(captureFullScreen(_:)),
            keyEquivalent: "s"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .shift]
        fullScreenItem.target = self
        menu.addItem(fullScreenItem)

        // 历史记录子菜单（点击条目 = 复制该图；每次弹出前重建，保证实时）
        let historyItem = NSMenuItem(title: "历史记录", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        self.historyMenu = historyMenu
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionItem = NSMenuItem(
            title: "屏幕录制权限…",
            action: #selector(openPermissionSettings(_:)),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

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

    @objc private func statusItemClicked(_ sender: Any?) {
        if let historyMenu { rebuildHistoryMenu(historyMenu) }
        guard let rootMenu, let button = statusItem?.button else { return }
        rootMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
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

    @objc private func openSettings(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "openSettings"])
        SettingsWindowController.shared.show(store: UserDefaultsSettingsStore())
    }

    @objc private func openPermissionSettings(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "openPermission"])
        TCCPermission.openSystemSettings()
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
