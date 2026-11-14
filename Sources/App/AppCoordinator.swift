import AppKit
import Carbon.HIToolbox

/// 应用状态机（docs/03 §4.1 的 v0.1 子集）
///
/// idle --热键/托盘--> overlay(选区中) --松手--> confirm(待 Enter/⌘S/Esc) --> exporting --> idle
enum AppState: String {
    case idle
    case overlay
    case confirm
    case exporting
}

@MainActor
final class AppCoordinator {
    private(set) var state: AppState = .idle {
        didSet {
            guard oldValue != state else { return }
            Log.event(.app, "state.\(state.rawValue)", ["from": oldValue.rawValue])
        }
    }

    /// 合成根：唯一构造适配器的地方（六边形架构的 composition root）
    let deps: Dependencies = {
        MainActor.assumeIsolated { Dependencies.live() }
    }()
    private let tray = StatusItemController()
    private let hotkeyCenter = CarbonHotKeyCenter.shared
    private let exporter = ExportCoordinator()
    private var overlayController: OverlayController?

    /// 用户设置（设置面板写入 UserDefaults，启动时读取；改动需重启生效）
    private(set) var settings: AppSettings = AppSettings.defaultSettings

    func start() {
        AppCoordinatorShared.coordinator = self
        AppCoordinatorShared.deps = deps
        TCCPermission.preflight()
        settings = UserDefaultsSettingsStore().load()
        HistoryStore.shared.maxItems = max(1, settings.historyLimit)
        Log.event(.app, "settings.applied", [
            "afterCapture": settings.afterCapture.rawValue,
            "historyLimit": "\(settings.historyLimit)",
            "hotkeyRegion": settings.hotkeyRegion,
            "hotkeyFullScreen": settings.hotkeyFullScreen,
        ])
        scheduleSelfTestIfRequested()
        tray.setup(coordinator: self)
        registerCaptureHotkeys()
        presentOnboardingIfNeeded()
    }

    // MARK: - 首次运行引导（权限前置）

    private var onboardingWindow: OnboardingWindow?
    private static let onboardingKey = "onboarding.completed"

    /// 首启或权限缺失时展示引导卡：把「授权」放在用户第一次想截图之前
    private func presentOnboardingIfNeeded() {
        let granted = deps.permission.isGranted()
        let completed = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        guard !granted || !completed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            var created: OnboardingWindow?
            created = OnboardingWindow(
                permissionGranted: granted,
                onPermissionTap: { [weak self] in
                    self?.deps.permission.request()
                    Log.event(.app, "onboarding.permissionTap")
                },
                onFinish: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.onboardingKey)
                    created?.orderOut(nil)
                    self?.onboardingWindow = nil
                    Log.event(.app, "onboarding.finish", ["granted": "\(self?.deps.permission.isGranted() ?? false)"])
                }
            )
            guard let window = created else { return }
            self.onboardingWindow = window
            window.showCentered(on: NSScreen.main ?? NSScreen.screens[0])
            Log.event(.app, "onboarding.show", ["granted": "\(granted)", "completed": "\(completed)"])
        }
    }

    /// 按用户设置注册两个截图热键（解析失败回落默认 ⌘⇧A / ⌘⇧S）
    private func registerCaptureHotkeys() {
        let region = HotkeySpec.parse(settings.hotkeyRegion) ?? HotkeySpec(keyCode: UInt32(kVK_ANSI_A), modifiers: [.command, .shift])
        let full = HotkeySpec.parse(settings.hotkeyFullScreen) ?? HotkeySpec(keyCode: UInt32(kVK_ANSI_S), modifiers: [.command, .shift])
        deps.hotkeys.register(keyCode: region.keyCode, modifiers: region.modifiers) { [weak self] in
            self?.beginRegionCapture()
        }
        deps.hotkeys.register(keyCode: full.keyCode, modifiers: full.modifiers) { [weak self] in
            self?.beginFullScreenCapture()
        }
        // 兜底可达性：菜单栏满时托盘图标可能被系统整体隐藏（tray.hidden.overflow 病例），
        // ⌥⌘, 直接打开设置窗口，保证无图标也能进设置
        deps.hotkeys.register(
            keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.option, .command]
        ) {
            Log.event(.hotkey, "hotkey.settings", ["key": "opt-cmd-comma"])
            SettingsWindowController.shared.show(store: UserDefaultsSettingsStore())
        }
    }

    func teardown() {
        hotkeyCenter.teardown()
    }

    // MARK: - 截图入口（热键 / 托盘菜单共用）

    func beginRegionCapture() {
        guard state == .idle else {
            Log.event(.app, "capture.ignored", ["state": state.rawValue])
            return
        }
        state = .overlay
        if overlayController == nil {
            overlayController = OverlayController()
        }
        let started = DispatchTime.now()
        overlayController?.begin { [weak self] result in
            guard let self else { return }
            switch result {
            case .copy(let image):
                self.state = .exporting
                if self.settings.afterCapture == .save {
                    self.exporter.savePanel(image)
                } else {
                    self.exporter.copyToClipboard(image)
                    // 复制反馈（设置可关）：右下角 toast，不抢焦点
                    if self.settings.showCopyNotification {
                        CaptureToast.show(image: image)
                    }
                }
            case .save(let image):
                self.state = .exporting
                self.exporter.savePanel(image)
            case .cancelled:
                break
            }
            self.state = .idle
        }
        let elapsedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        if elapsedMs > 50 {
            Log.error(.overlay, "overlay.open.slow", ["ms": "\(elapsedMs)"])
        }
    }

    /// 快速保存（编辑器内 ⌘⌥S）：按设置的目录与文件名规则直接落盘
    func quickSave(image: CGImage) {
        _ = exporter.quickSave(image, settings: settings)
        if settings.showCopyNotification {
            CaptureToast.show(image: image, message: "已保存到 \((settings.saveDirectoryPath as NSString).lastPathComponent)")
        }
    }

    /// 全屏截图（⌘⇧S）：不做选区，直接整屏进编辑态
    func beginFullScreenCapture() {
        guard state == .idle else {
            Log.event(.app, "capture.ignored", ["state": state.rawValue])
            return
        }
        state = .overlay
        if overlayController == nil {
            overlayController = OverlayController()
        }
        overlayController?.beginFullScreen { [weak self] result in
            guard let self else { return }
            switch result {
            case .copy(let image):
                self.state = .exporting
                self.exporter.copyToClipboard(image)
            case .save(let image):
                self.state = .exporting
                self.exporter.savePanel(image)
            case .cancelled:
                break
            }
            self.state = .idle
        }
    }

    // 供 OverlayController 汇报 confirm 态（松手后）
    func didEnterConfirm() {
        state = .confirm
    }
}


// MARK: - 自测钩子（--selftest：真实链路自动跑一轮，验证用，非 mock）

extension AppCoordinator {
    /// 用法：Snapcut.app/Contents/MacOS/Snapcut --selftest
    /// 流程：启动 2s 后自动开始选区会话 → 模拟拖选主屏 (100,100)-(500,400) → 1s 后 Enter
    /// 全链路真实（SCK 截屏 + 剪贴板写入），结束后记录焦点状态供日志验证。
    fileprivate func scheduleSelfTestIfRequested() {
        if CommandLine.arguments.contains("--selftest-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                Log.event(.app, "selftest.settings")
                SettingsWindowController.shared.show(store: UserDefaultsSettingsStore())
            }
            return
        }
        if CommandLine.arguments.contains("--selftest-tray") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.tray.selfTestDumpHistoryMenu()
            }
            return
        }
        guard CommandLine.arguments.contains("--selftest") else { return }
        Log.event(.app, "selftest.requested")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.state == .idle else { return }
            self.beginRegionCapture()
            // 等覆盖层出现后，模拟一次拖选 + Enter（走真实 didSelect/perform 管线）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                guard let overlay = self.overlayController,
                      let screen = NSScreen.main else { return }
                let rect = CGRect(x: 100, y: screen.frame.height - 400, width: 400, height: 300)
                overlay.simulateSelection(rect: rect, on: screen)
                // 等编辑态就绪（底图冻结 + 工具栏出现）后，落几个真实标注再导出
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, let session = self.overlayController?.editorSession else { return }
                    session.store.add(AnnotationModel(
                        shape: .arrow(from: CGPoint(x: 40, y: 30), to: CGPoint(x: 200, y: 180)),
                        colorIndex: 0, strokeWidth: 2, text: nil, index: nil))
                    session.store.add(AnnotationModel(
                        shape: .rect(CGRect(x: 50, y: 60, width: 120, height: 80)),
                        colorIndex: 1, strokeWidth: 2, text: nil, index: nil))
                    session.store.add(AnnotationModel(
                        shape: .text(anchor: CGPoint(x: 60, y: 100)), colorIndex: 0,
                        strokeWidth: 2, text: "Snapcut selftest", index: nil))
                    session.store.add(AnnotationModel(
                        shape: .sequence(anchor: CGPoint(x: 150, y: 50)), colorIndex: 4,
                        strokeWidth: 2, text: nil, index: session.store.consumeSequenceNumber()))
                    session.store.add(AnnotationModel(
                        shape: .mosaic(CGRect(x: 180, y: 120, width: 90, height: 60)),
                        colorIndex: 0, strokeWidth: 2, text: nil, index: nil))
                    Log.event(.app, "selftest.annotationsAdded", ["count": "5"])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        _ = self?.overlayController?.performForSelfTest(.copy)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            let active = NSApp.isActive
                            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                            Log.event(.app, "selftest.done", [
                                "isActive": "\(active)",
                                "frontmost": front,
                            ])
                        }
                    }
                }
            }
        }
    }
}
