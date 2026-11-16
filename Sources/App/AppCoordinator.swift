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
    /// 设置（启动加载 + 面板保存后回写；引导窗/托盘读它显示实际快捷键）
    var settings: AppSettings = AppSettings.defaultSettings

    /// 权限门禁镜像到 UserDefaults（@AppStorage 桥）：Tahoe MenuBarExtra .menu
    /// content 是快照，只有 @AppStorage 写入能触发菜单重建。翻转时才写。
    private func syncPermissionMirror() {
        let g = deps.permission.isGranted()
        if UserDefaults.standard.bool(forKey: "app.perm.granted") != g {
            UserDefaults.standard.set(g, forKey: "app.perm.granted")
            Log.event(.permission, "permission.mirror", ["granted": "\(g)"])
        }
    }

    /// 启动预激活后的释放（AppDelegate 启动 warmup 用）：退出激活态但不
    /// 还给任何 App（此刻没记录过前台归属），前台自然回用户当前 App。
    func releaseActivationAfterWarmup() {
        NSApp.deactivate()
        Log.event(.app, "app.warmup.released")
    }

    func start() {
        AppCoordinatorShared.coordinator = self
        AppCoordinatorShared.deps = deps
        TCCPermission.preflight()
        // 菜单门禁初值（@AppStorage 桥；翻转时写 → 菜单重建）
        syncPermissionMirror()
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
        ensureKeepAlive()
        // 坑 33 终极形态：AppKit「StatusBar 0 terminating on removal」——MenuBarExtra
        // 的 status item 被 ControlCenter 驱逐（assertion invalidated）时，AppKit
        // 走 sudden termination 路径自动终止 App。ProcessInfo 禁用后，即使 item
        // 被逐，App 持续运行，item 通常会被 CC 重新接纳（assertion 重建）。
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("snapcut-menubar")
    }

    /// 坑 33（启动即退·第三形态）：MenuBarExtra-only + LSUIElement 的 SwiftUI App，
    /// 在「无可见窗口」（权限已 granted、引导跳过）时 run loop 自动结束退出——
    /// 之前所有"活着"的实例都是因为碰巧有引导窗/设置窗挂着。
    /// 解法：常驻一枚 1×1 全透明工具窗（不抢焦点、不进任务切换）钉住 run loop。
    private var keepAliveWindow: NSWindow?
    private func ensureKeepAlive() {
        guard keepAliveWindow == nil else { return }
        let w = NSWindow(
            contentRect: NSRect(x: -10, y: -10, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.alphaValue = 0
        w.level = .floating
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.orderFrontRegardless()
        keepAliveWindow = w
        Log.event(.app, "app.keepAlive")
    }

    // MARK: - 首次运行引导（权限前置）

    private var onboardingWindow: OnboardingWindow?
    private var onboardingPollTimer: Timer?
    private static let onboardingKey = "onboarding.completed"

    /// 首启或权限缺失时展示引导卡：把「授权」放在用户第一次想截图之前
    /// 引导卡展示逻辑（用户裁定 2026-11-15，对齐 glance）：
    /// **未授权就弹**——completed 标记只用于「授权完成后别再打扰」，不作为豁免条件。
    /// 用户授权被系统重置（tccutil / requirement 变化）时引导会重新出现，这是正确行为。
    private func presentOnboardingIfNeeded() {
        let granted = deps.permission.isGranted()
        guard !granted else {
            Log.event(.app, "onboarding.skip", ["reason": "granted"])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            var created: OnboardingWindow?
            created = OnboardingWindow(
                permissionGranted: granted,
                onPermissionTap: { [weak self] in
                    self?.deps.permission.request()
                    Log.event(.app, "onboarding.permissionTap")
                    // 去授权后引导卡已让位（orderOut）；轮询授权结果：
                    // granted → 自动完成引导（用户不用再点「开始使用」——
                    // 隐藏中的卡对用户是「点完就没了」的轻体验）；
                    // 注意屏幕录制授权需重启进程才生效，轮询到的是 request()
                    // 触发的 TCC 判定（未重启恒 false）→ 90s 未变即停轮询，
                    // 下次启动引导卡会再出现（glance 式）提示重启生效。
                    var tick = 0
                    let pollTimer = Timer(timeInterval: 2.0, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            tick += 1
                            guard let self, let t = self.onboardingPollTimer else { return }
                            if self.deps.permission.isGranted() {
                                t.invalidate()
                                self.onboardingPollTimer = nil
                                UserDefaults.standard.set(true, forKey: Self.onboardingKey)
                                self.onboardingWindow?.dismissAnimated()
                                self.onboardingWindow = nil
                                Log.event(.app, "onboarding.finish", ["granted": "true", "via": "poll"])
                            } else if tick > 45 {
                                t.invalidate()
                                self.onboardingPollTimer = nil
                            }
                        }
                    }
                    RunLoop.main.add(pollTimer, forMode: .common)
                    self?.onboardingPollTimer = pollTimer
                },
                onFinish: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.onboardingKey)
                    created?.dismissAnimated()
                    self?.onboardingWindow = nil
                    Log.event(.app, "onboarding.finish", ["granted": "\(self?.deps.permission.isGranted() ?? false)"])
                }
            )
            guard let window = created else { return }
            self.onboardingWindow = window
            window.showCentered(on: NSScreen.main ?? NSScreen.screens[0])
            Log.event(.app, "onboarding.show", ["granted": "\(granted)"])
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
        // 兜底可达性（菜单栏满时图标会被系统隐藏，实测连最小 App 也不显示）：
        // ⌥⌘H 在光标处弹出完整菜单，⌥⌘, 直接开设置
        deps.hotkeys.register(keyCode: UInt32(kVK_ANSI_H), modifiers: [.option, .command]) { [weak self] in
            self?.tray.showMenuAtCursor()
        }
        // 延时截图（默认 3 秒）：⌃⌥D
        deps.hotkeys.register(keyCode: UInt32(kVK_ANSI_D), modifiers: [.control, .option]) { [weak self] in
            self?.beginDelayedCapture(seconds: 3)
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

    /// TCC 防重弹闸（用户实报「点打开系统设置后框还要弹 1-2 次」）：
    /// 授权后未重启进程期间，再触发截图会让 SCK/WindowServer 再次请求录屏
    /// 权限 → TCC 又弹一次。此时直接用系统通知提示重启，不进截图流程。
    private func ensureCaptureReadiness() -> Bool {
        // 门禁语义（用户三次重申，TCCPermission.swift 注释里早写了但没实现）：
        // **未授权时快捷键/菜单不进截图流程，直接弹引导卡**（引导卡上
        // 「去授权」才是唯一的授权入口）——而不是唤起选区面板再让 SCK
        // 在半路弹 TCC 框（用户实报「快捷键唤起了面板、TCC 框又弹」）。
        let granted = deps.permission.isGranted()
        if granted {
            syncPermissionMirror()
            return true
        }

        // 系统设置里已开但进程未重启：提示重启（防 TCC 重弹）
        if permissionPromptWindowActive {
            Log.event(.app, "capture.blocked.pendingRestart")
            let notif = NSUserNotification()
            notif.title = "Snapcut"
            notif.informativeText = "权限已开启，重启 Snapcut 后生效"
            return false
        }

        // 未授权 → 弹引导卡（唯一授权路径），拦下截图
        Log.event(.app, "capture.blocked.unauthorized")
        presentOnboardingForce()
        return false
    }

    /// 托盘「去授权」入口：弹引导卡（引导卡上的「去授权」按钮是唯一授权路径）
    func presentOnboardingFromTray() {
        presentOnboardingForce()
    }

    /// 强制弹引导卡（未授权门禁触发；已开着则前置聚焦）
    private func presentOnboardingForce() {
        if let window = onboardingWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        presentOnboardingIfNeeded()
    }

    private var permissionPromptWindowActive = false
    /// 由 permission.request 路径调用：标记 TCC 弹框窗口期（5 分钟）
    func markPermissionPromptShown() {
        permissionPromptWindowActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.permissionPromptWindowActive = false
        }
    }

    func beginRegionCapture() {
        guard state == .idle else {
            Log.event(.app, "capture.ignored", ["state": state.rawValue])
            return
        }
        guard ensureCaptureReadiness() else { return }
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

    /// 延时截图（F8）：倒计时结束后走区域截图（屏幕在倒计时结束时才冻结）
    func beginDelayedCapture(seconds: Int) {
        guard state == .idle else {
            Log.event(.app, "capture.ignored", ["state": state.rawValue])
            return
        }
        CountdownHUD.start(seconds: seconds) { [weak self] in
            Log.event(.app, "countdown.finished")
            self?.beginRegionCapture()
        } onCancel: { [weak self] in
            Log.event(.app, "countdown.cancelled")
            self?.state = .idle
        }
    }

    /// 全屏截图（⌘⇧S）：不做选区，直接整屏进编辑态
    func beginFullScreenCapture() {
        guard state == .idle else {
            Log.event(.app, "capture.ignored", ["state": state.rawValue])
            return
        }
        guard ensureCaptureReadiness() else { return }
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
        if CommandLine.arguments.contains("--selftest-collage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Log.event(.app, "selftest.collage")
                // 新拼贴自测（贴图磁吸链）：种两张纯色贴图 pin，手动落位到磁吸阈值内，
                // 验证 PinMagnetRegistry snap → 组框 → （不自动 assemble，视觉验收人工判）
                func sample(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, w: Int, h: Int) -> CGImage? {
                    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let ctx = CGContext(
                        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else { return nil }
                    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    return ctx.makeImage()
                }
                let screen = NSScreen.main?.frame ?? .zero
                let ptScale = NSScreen.main?.backingScaleFactor ?? 2
                if let a = sample(0.20, 0.55, 0.95, w: 640, h: 400) {
                    AppCoordinatorShared.deps?.pinning.pin(a, atGlobalRect: CGRect(
                        x: screen.midX - 330, y: screen.midY - 100,
                        width: 320, height: 200))
                }
                if let b = sample(0.95, 0.62, 0.18, w: 520, h: 360) {
                    AppCoordinatorShared.deps?.pinning.pin(b, atGlobalRect: CGRect(
                        // 预贴边：b 左缘 = a 右缘 + 16pt gutter（屏 point）
                        x: screen.midX - 330 + 320 + 16, y: screen.midY - 100,
                        width: 260, height: 180))
                }
                _ = ptScale
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
