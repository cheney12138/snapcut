import SwiftUI

/// MenuBarExtra 菜单内容（SwiftUI 声明式；NSMenu 版本在 StatusItemController，
/// 服务于 ⌥⌘H 光标兜底菜单，两处动作语义保持一致）
@MainActor
struct TrayMenuContent: View {
    /// 权限门禁状态。@AppStorage（UserDefaults 响应式桥）：
    /// .menu 风格的 MenuBarExtra content 是一次性快照（转 NSMenu 后不再重求
    /// body，onAppear/轮询改 @State 都刷不动缓存的菜单——用户实报「授权完
    /// 成菜单卡死在未授权态」第二轮）。@AppStorage 的 UserDefaults 写入会让
    /// SwiftUI 重建 menu content。写入方：AppCoordinator 的 preflight 翻转。
    @AppStorage("app.perm.granted") private var permissionGranted: Bool = false

    /// 实际注册的快捷键（用户可改；菜单显示跟实际一致）
    private var hotkeys: AppSettings {
        AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
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

        Button("搜索视觉记忆  \(HotkeySpec.display(hotkeys.hotkeyHistorySpotlight))") {
            Log.event(.tray, "tray.action", ["item": "historySpotlight"])
            AppCoordinatorShared.coordinator?.toggleHistorySpotlight()
        }

        Button("隐藏/显示全部贴图  ⌥ ⌘ P") {
            Log.event(.tray, "tray.action", ["item": "togglePins"])
            AppCoordinatorShared.coordinator?.toggleAllPinsVisibility()
        }

        Divider()

        Button("设置…") {
            Log.event(.tray, "tray.action", ["item": "openSettings"])
            SettingsWindowController.shared.show(store: UserDefaultsSettingsStore())
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("检查更新…") {
            Log.event(.tray, "tray.action", ["item": "checkUpdates"])
            AppCoordinatorShared.deps?.updating.checkForUpdates()
        }

        Divider()

        Button("退出 Snapcut") {
            Log.event(.tray, "tray.action", ["item": "quit"])
            SnapcutQuitController.quit()
        }
        .keyboardShortcut("q", modifiers: [.command])
        .onAppear {
            Log.event(.tray, "tray.menu.built", ["granted": "\(permissionGranted)"])
        }
    }
}
