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
    @AppStorage("app.recording.active") private var isRecordingActive: Bool = false
    /// 剪贴板里有图片时（监控侧写的 UserDefaults 桥）才多出「贴图划词 / 识别文字」
    /// 两个入口，避免菜单常驻两个点了会提示「没图」的死项
    @AppStorage("app.clipboard.hasImage") private var hasClipboardImage: Bool = false

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
        if isRecordingActive {
            Button("■ 停止录制") {
                Log.event(.tray, "tray.action", ["item": "stopRecording"])
                AppCoordinatorShared.coordinator?.stopActiveRecording()
            }
            Button("✕ 放弃录制") {
                Log.event(.tray, "tray.action", ["item": "cancelRecording"])
                AppCoordinatorShared.coordinator?.cancelActiveRecording()
            }
            Divider()
        }

        if hasClipboardImage {
            Button("贴图剪贴板图片（实况划词）") {
                Log.event(.tray, "tray.action", ["item": "pinClipboard"])
                AppCoordinatorShared.coordinator?.pinClipboardImageWithLiveText()
            }

            Button("识别剪贴板图片文字…") {
                Log.event(.tray, "tray.action", ["item": "ocrClipboard"])
                AppCoordinatorShared.coordinator?.ocrClipboardImage()
            }

            Divider()
        }

        Button("截取区域  \(HotkeySpec.display(hotkeys.hotkeyRegion))") {
            Log.event(.tray, "tray.action", ["item": "captureRegion"])
            AppCoordinatorShared.coordinator?.beginRegionCapture()
        }

        Button("截取全屏  \(HotkeySpec.display(hotkeys.hotkeyFullScreen))") {
            Log.event(.tray, "tray.action", ["item": "captureFullScreen"])
            AppCoordinatorShared.coordinator?.beginFullScreenCapture()
        }

        Button("录制视频  \(HotkeySpec.display(hotkeys.hotkeyRecordVideo))") {
            Log.event(.tray, "tray.action", ["item": "recordVideo"])
            AppCoordinatorShared.coordinator?.beginRegionRecording(format: .mp4)
        }

        Button("录制 GIF  \(HotkeySpec.display(hotkeys.hotkeyRecordGIF))") {
            Log.event(.tray, "tray.action", ["item": "recordGIF"])
            AppCoordinatorShared.coordinator?.beginRegionRecording(format: .gif)
        }

        Button("延时 3 秒截图") {
            Log.event(.tray, "tray.action", ["item": "captureDelayed"])
            AppCoordinatorShared.coordinator?.beginDelayedCapture(seconds: 3)
        }

        Button("搜索视觉记忆  \(HotkeySpec.display(hotkeys.hotkeyHistorySpotlight))") {
            Log.event(.tray, "tray.action", ["item": "historySpotlight"])
            AppCoordinatorShared.coordinator?.toggleHistorySpotlight()
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
