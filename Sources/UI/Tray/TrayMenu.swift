import SwiftUI

/// MenuBarExtra 菜单内容（SwiftUI 声明式；NSMenu 版本在 StatusItemController，
/// 服务于 ⌥⌘H 光标兜底菜单，两处动作语义保持一致）
///
/// 历史子菜单：每次展开时 body 重新求值 = 实时重建（对齐 NSMenu 的 rebuild 语义）
@MainActor
struct TrayMenuContent: View {
    @State private var history: [HistoryStore.Item] = []

    /// 实际注册的快捷键（用户可改；菜单显示跟实际一致）
    private var hotkeys: AppSettings {
        AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
    }

    var body: some View {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        Text("Snapcut \(version)")

        Divider()

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
            Log.event(.tray, "tray.menu.built", ["history": "\(history.count)"])
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
