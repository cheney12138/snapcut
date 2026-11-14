import AppKit

/// 菜单栏托盘（docs/03 §3：NSStatusItem + NSMenu 原生菜单）
@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private weak var coordinator: AppCoordinator?

    func setup(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapcut")
            button.imageScaling = .scaleProportionallyDown
        }
        item.menu = buildMenu()
        statusItem = item
        Log.event(.tray, "tray.icon.created")
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
        return menu
    }

    // MARK: - 菜单动作

    @objc private func captureRegion(_ sender: Any?) {
        Log.event(.tray, "tray.action", ["item": "captureRegion"])
        coordinator?.beginRegionCapture()
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
