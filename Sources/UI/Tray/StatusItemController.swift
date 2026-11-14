import AppKit

/// 菜单栏托盘（docs/03 §3：NSStatusItem + NSMenu 原生菜单）
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var coordinator: AppCoordinator?
    private var rootMenu: NSMenu?
    private var historyMenu: NSMenu?
    /// 「菜单栏已满被挤掉」提示只弹一次（每次启动最多提醒，不轮播）
    private var overflowToastShown = false

    override init() {
        super.init()
    }

    func setup(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        // ⚠️ 不能用 variableLength：实测按钮占 38pt，菜单栏一挤就被系统隐藏
        // （病例：图标"消失"，butt.frame 落在时钟区 x=1690 即被挤出可见区）
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "SnapcutStatusItem"
        item.behavior = [.removalAllowed]
        if let button = item.button {
            button.image = IconFactory.statusIcon() // 品牌 mark 剪影（StatusMark.png 模板）
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.title = ""
            // 手动弹菜单：展开前重建历史子菜单（NSMenuDelegate 在 Swift 6 下跨隔离域
            // 传递 NSMenu 会触发并发检查，改用显式 popUpMenu）
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
        // ⚠️ 必须显式构建：改用「点击时 popUp」后不再有 item.menu = buildMenu()，
        // 少了这行 rootMenu/historyMenu 全为 nil（病例：托盘点击无反应、历史菜单空）
        _ = buildMenu()
        statusItem = item
        // 诊断：按钮在屏幕上的实际位置（验证图标是否真的上屏、是否被挤出菜单栏）
        // ⚠️ 病例：菜单栏拥挤时，早期创建的 status item 会被系统判为「放不下」
        // 而整体隐藏（button.frame 落到时钟区 x≈1690 且不可见）。
        // 补救：启动后重新断言可见性并重置图标，让系统重新布局一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            item.isVisible = true
            if let button = item.button {
                button.image = IconFactory.statusIcon()
                button.imageScaling = .scaleProportionallyDown
                button.needsDisplay = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            self.checkTrayVisibility(reason: "t2.4")
        }
        // 布局再稳定一轮后复检（菜单栏 item 增删会触发重排）
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            self.checkTrayVisibility(reason: "t6.0")
        }
        Log.event(.tray, "tray.icon.created", [
            "src": "mark-silhouette",
            "img": item.button?.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil",
            "visible": "\(item.button?.isHidden == false)",
            "length": "\(item.length)",
        ])
    }

    /// 判定「图标是否真正可见」：窗口 frame 落到屏幕最右（时钟区）即被系统挤入不可见区。
    /// 病例：菜单栏拥挤时 button.window.frame = x:1690 w:38 ⇒ maxX 贴住屏幕右缘，图标不可见。
    /// 判定口径（任一命中即隐藏）：
    /// 1. frame.maxX > screen.maxX - 40（贴住右缘，压进时钟区）
    /// 2. frame 与时钟区域（右缘 130pt × 菜单栏条带）重叠
    /// 命中时：Log.error(.tray, "tray.hidden.overflow") + 一次性 CaptureToast 提示。
    /// ⌘⇧A / ⌘⇧S 走 Carbon 热键（AppCoordinator.registerHotkeys），不依赖托盘，始终可用。
    func checkTrayVisibility(reason: String) {
        guard let item = statusItem, let button = item.button else {
            Log.error(.tray, "tray.hidden.nobutton", ["reason": reason])
            return
        }
        guard let window = button.window else {
            Log.error(.tray, "tray.hidden.nowindow", ["reason": reason])
            return
        }
        let frame = window.frame
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        let nearRightEdge = frame.maxX > screen.frame.maxX - 40
        let menuBarStrip = CGRect(x: screen.frame.maxX - 130, y: screen.frame.maxY - 24,
                                  width: 130, height: 24)
        let overlapsClock = menuBarStrip.intersects(frame)
        // 诊断打点（保留原 frame 日志语义）
        Log.event(.tray, "tray.button.frame", [
            "reason": reason,
            "x": "\(Int(frame.minX))", "y": "\(Int(frame.minY))",
            "w": "\(Int(frame.width))", "h": "\(Int(frame.height))",
            "maxX": "\(Int(frame.maxX))", "screenMaxX": "\(Int(screen.frame.maxX))",
        ])
        guard nearRightEdge || overlapsClock else {
            if overflowToastShown {
                // 之前被判隐藏，现在恢复正常（例如用户清理了菜单栏）
                overflowToastShown = false
                Log.event(.tray, "tray.visible.recovered", ["reason": reason])
            }
            return
        }
        Log.error(.tray, "tray.hidden.overflow", [
            "reason": reason,
            "nearRightEdge": "\(nearRightEdge)", "overlapsClock": "\(overlapsClock)",
        ])
        // 尝试自救：重新断言可见性 + 重设图标，让系统重排一次
        item.isVisible = true
        button.image = IconFactory.statusIcon()
        button.imageScaling = .scaleProportionallyDown
        button.needsDisplay = true
        // 一次性兜底提示：图标可能已被系统挤掉，但热键仍可用
        if !overflowToastShown {
            overflowToastShown = true
            CaptureToast.show(
                image: Self.placeholderThumb(),
                message: "菜单栏已满，Snapcut 图标被系统隐藏；⌘⇧A 仍可用"
            )
        }
    }

    /// CaptureToast 需要一张 CGImage 缩略图：画一张品牌色圆角占位块
    private static func placeholderThumb() -> CGImage {
        let size = NSSize(width: 72, height: 46)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8).addClip()
        NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.9).setFill()
        rect.fill()
        let mark = NSAttributedString(
            string: "S",
            attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
        )
        let markSize = mark.size()
        mark.draw(at: NSPoint(x: (size.width - markSize.width) / 2,
                              y: (size.height - markSize.height) / 2))
        image.unlockFocus()
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if let cg { return cg }
        // 兜底：1×1 黑像素（几乎不可能走到）
        var pixel: [UInt8] = [0, 0, 0, 255]
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
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
