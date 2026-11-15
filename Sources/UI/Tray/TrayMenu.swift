import SwiftUI

/// MenuBarExtra 菜单内容（SwiftUI 声明式；NSMenu 版本在 StatusItemController，
/// 服务于 ⌥⌘H 光标兜底菜单，两处动作语义保持一致）
///
/// 历史子菜单：每次展开时 body 重新求值 = 实时重建（对齐 NSMenu 的 rebuild 语义）
@MainActor
struct TrayMenuContent: View {
    @State private var history: [HistoryStore.Item] = []
    /// 权限门禁状态（@State 而非计算属性——Tahoe 的 MenuBarExtra 菜单 body
    /// 不会因外部非响应式调用重新求值，用户实报「授权完成菜单还是未授权态」；
    /// 菜单每次展开 onAppear + 1s 轮询双保险刷新）
    @State private var permissionGranted: Bool = false

    /// 实际注册的快捷键（用户可改；菜单显示跟实际一致）
    private var hotkeys: AppSettings {
        AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
    }

    private func refreshPermission() {
        permissionGranted = AppCoordinatorShared.deps?.permission.isGranted() ?? false
    }

    var body: some View {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        Text("Snapcut \(version)")

        Divider()

        if !permissionGranted {
            Button("去授权…") {
                Log.event(.tray, "tray.action", ["item": "authorize"])
                AppCoordinatorShared.deps?.permission.request()
            }
            Divider()
            Button("退出 Snapcut") {
                Log.event(.tray, "tray.action", ["item": "quit"])
                SnapcutQuitController.quit()
            }
        } else {
            fullMenu
        }
    }

    @ViewBuilder private var fullMenu: some View {
        Button("截取区域  \(HotkeySpec.display(hotkeys.hotkeyRegion))") {
            Log.event(.tray, "tray.action", ["item": "captureRegion"])
            AppCoordinatorShared.coordinator?.beginRegionCapture()
        }

        Button("截取全屏  \(HotkeySpec.display(hotkeys.hotkeyFullScreen))") {
            Log.event(.tray, "tray.action", ["item": "captureFullScreen"])
            AppCoordinatorShared.coordinator?.beginFullScreenCapture()
        }

        Button("延时 3 秒截图") {
            Log.event(.tray, "tray.action", ["item": "captureDelayed"])
            AppCoordinatorShared.coordinator?.beginDelayedCapture(seconds: 3)
        }

        Button("新建拼贴") {
            Log.event(.tray, "tray.action", ["item": "openCollage"])
            // C2 画布窗入口：空文档打开（已开则前置并重置为空文档）
            CollageWindowController.shared.openDocument(CollageDocument())
        }

        Menu("历史记录") {
            if history.isEmpty {
                Text("暂无记录")
            }
            ForEach(history) { item in
                Button(Self.historyTitle(item)) {
                    if HistoryStore.shared.copyToPasteboard(item) {
                        Log.event(.tray, "tray.action", ["item": "copyHistory", "id": item.id])
                    }
                }
            }
            if !history.isEmpty {
                Divider()
                Button("清空历史记录") {
                    HistoryStore.shared.clearAll()
                    Log.event(.tray, "tray.action", ["item": "clearHistory"])
                }
            }
        }

        Divider()

        Button("设置…") {
            Log.event(.tray, "tray.action", ["item": "openSettings"])
            SettingsWindowController.shared.show(store: UserDefaultsSettingsStore())
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("退出 Snapcut") {
            Log.event(.tray, "tray.action", ["item": "quit"])
            SnapcutQuitController.quit()
        }
        .keyboardShortcut("q", modifiers: [.command])
        .onAppear {
            history = HistoryStore.shared.items()
            refreshPermission()
            Log.event(.tray, "tray.menu.built", ["history": "\(history.count)", "granted": "\(permissionGranted)"])
        }
        // 授权窗口期（未授权→刚授权）每 1s 刷一次菜单形态；授权后停
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            let g = AppCoordinatorShared.deps?.permission.isGranted() ?? false
            if g != permissionGranted { permissionGranted = g }
        }
    }

    /// 历史条目标题：`11-14 23:07 · 680×680`
    private static func historyTitle(_ item: HistoryStore.Item) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let size = Int(item.pixelSize.width)
        let h = Int(item.pixelSize.height)
        return "\(f.string(from: item.date)) · \(size)×\(h)"
    }
}
