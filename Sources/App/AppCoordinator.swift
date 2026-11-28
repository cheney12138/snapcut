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

    /// 启动静默预热（不抢焦点）：
    /// 1. 已授权时预热 SCShareableContent XPC 连接（消除重启后首次 F1 115ms 冷启动开销）；
    /// 2. 预建 OverlayController 与可复用 ToolbarPanel（消除首次框选松手时的工具栏冷构建卡顿）。
    func warmupAfterLaunch() {
        if overlayController == nil {
            overlayController = OverlayController()
        }
        overlayController?.warmup()
        if deps.permission.isGranted() {
            Task.detached(priority: .utility) {
                await SCKCapture.shared.warmup()
            }
        }
        Log.event(.app, "app.warmup.ready", ["granted": "\(deps.permission.isGranted())"])
        // 视觉记忆首屏静默预热：延迟 1.2s 才开（冷启动不抢开机 CPU），
        // 首次 ⌘⌃V 时前 9 张缩略图已就位，面板打开无需现场解码
        Task(priority: .background) { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            HistoryStore.shared.prewarmThumbnails(limit: 9, maxSize: 440)
        }
        if settings.autoIndexHistoryOCR {
            Task(priority: .background) { @MainActor [weak self] in
                guard let self, self.settings.autoIndexHistoryOCR else { return }
                HistoryStore.shared.backfillMissingOCRIfNeeded()
            }
        }
    }

    func start() {
        AppCoordinatorShared.coordinator = self
        AppCoordinatorShared.deps = deps
        UserDefaults.standard.set(false, forKey: "app.recording.active")
        TCCPermission.preflight()
        // 菜单门禁初值（@AppStorage 桥；翻转时写 → 菜单重建）
        syncPermissionMirror()
        settings = UserDefaultsSettingsStore().load()
        HistoryStore.shared.maxItems = max(1, settings.historyLimit)
        HistoryStore.shared.textRecognizer = deps.textRecognizer
        HistoryStore.shared.autoIndexOCREnabled = settings.autoIndexHistoryOCR
        HistoryStore.shared.onItemsChanged = {
            HistorySpotlightPanel.shared.reloadIfVisible()
        }
        Log.event(.app, "settings.applied", [
            "afterCapture": settings.afterCapture.rawValue,
            "historyLimit": "\(settings.historyLimit)",
            "autoIndexOCR": "\(settings.autoIndexHistoryOCR)",
            "hotkeyRegion": settings.hotkeyRegion,
            "hotkeyFullScreen": settings.hotkeyFullScreen,
            "hotkeyHistorySpotlight": settings.hotkeyHistorySpotlight,
        ])
        // 外部剪贴板智能感知：微信/飞书里复制的含文字图片 → 轻提示「贴图划词 / 提取文字」
        startClipboardImageWatcher()
        scheduleSelfTestIfRequested()
        tray.setup(coordinator: self)
        registerCaptureHotkeys()
        presentOnboardingIfNeeded()
        ensureKeepAlive()
        // 坑 33 终极形态：AppKit「StatusBar 0 terminating on removal」——MenuBarExtra
        // 的 status item 被 ControlCenter 驱逐（assertion invalidated）时，AppKit
        // 走 sudden termination 路径自动终止 App。ProcessInfo 禁用后，即使 item
        // 被逐，App 持续运行，item 通常会被 CC 重新接纳（assertion 重建）。
        // 禁止系统 App Nap / 定时合并：防止后台菜单栏 App 进入低功耗休眠后
        // 延迟或堆积 Carbon 全局热键事件（解决「按好几次 F1 没反应、随后瞬间连发」病例）
        keepAwakeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Global screenshot hotkeys require instant wakeup"
        )
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("snapcut-menubar")
    }

    private var keepAwakeActivity: NSObjectProtocol?

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
            window.showCentered(on: DisplayRegistry.screenAtMouse() ?? NSScreen.main ?? NSScreen.screens[0])
            Log.event(.app, "onboarding.show", ["granted": "\(granted)"])
        }
    }

    /// 按用户设置注册截图与视觉记忆全局热键（解析失败回落默认 ⌘⇧A / ⌘⇧S / ⌥⌘V）
    /// 热键 id（设置保存后重注册用——病例「改完不生效」：
    /// 注册只在启动，改键要重启才生效）
    private var regionHotKeyID: UInt32?
    /// 兜底热键只注册一次（rebind 重跑 registerCaptureHotkeys 时防 -9878 重复）
    private var everRegisteredFallbacks = false
    private var fullHotKeyID: UInt32?
    private var historySpotlightHotKeyID: UInt32?
    private var recordGIFHotKeyID: UInt32?
    private var recordVideoHotKeyID: UInt32?

    /// 设置保存后立即重建工具栏（工具栏大小档位 / 按钮排序即时生效，无需重启）
    func invalidateToolbar() {
        overlayController?.invalidateToolbar()
    }

    /// 设置保存后重绑定（SettingsWindowController.persist 回灌时调）
    func rebindCaptureHotkeys() {
        hotkeyCenter.unregister(regionHotKeyID)
        hotkeyCenter.unregister(fullHotKeyID)
        hotkeyCenter.unregister(historySpotlightHotKeyID)
        hotkeyCenter.unregister(recordGIFHotKeyID)
        hotkeyCenter.unregister(recordVideoHotKeyID)
        regionHotKeyID = nil
        fullHotKeyID = nil
        historySpotlightHotKeyID = nil
        recordGIFHotKeyID = nil
        recordVideoHotKeyID = nil
        registerCaptureHotkeys()

        HistoryStore.shared.maxItems = max(1, settings.historyLimit)
        HistoryStore.shared.autoIndexOCREnabled = settings.autoIndexHistoryOCR
        if settings.autoIndexHistoryOCR {
            HistoryStore.shared.backfillMissingOCRIfNeeded()
        }
        // 设置面板切换「外部复制含文字图片时轻提示」后即时生效（无需重启）
        ClipboardImageWatcher.shared.isEnabled = settings.smartClipboardImagePrompt

        Log.event(.hotkey, "hotkey.rebind", [
            "region": settings.hotkeyRegion,
            "full": settings.hotkeyFullScreen,
            "spotlight": settings.hotkeyHistorySpotlight,
            "recVideo": settings.hotkeyRecordVideo,
            "recGIF": settings.hotkeyRecordGIF,
        ])
    }

    private func registerCaptureHotkeys() {
        let region = HotkeySpec.parse(settings.hotkeyRegion) ?? HotkeySpec(keyCode: UInt32(kVK_ANSI_A), modifiers: [.command, .shift])
        let full = HotkeySpec.parse(settings.hotkeyFullScreen) ?? HotkeySpec(keyCode: UInt32(kVK_ANSI_S), modifiers: [.command, .shift])
        let spotlight = HotkeySpec.parse(settings.hotkeyHistorySpotlight) ?? HotkeySpec(keyCode: UInt32(kVK_ANSI_V), modifiers: [.option, .command])
        let recVideo = HotkeySpec.parse(settings.hotkeyRecordVideo) ?? HotkeySpec(keyCode: UInt32(kVK_ANSI_R), modifiers: [.option, .command])
        let recGIF = HotkeySpec.parse(settings.hotkeyRecordGIF) ?? HotkeySpec(keyCode: UInt32(kVK_ANSI_G), modifiers: [.option, .command])
        regionHotKeyID = hotkeyCenter.register(keyCode: region.keyCode, modifiers: region.modifiers) { [weak self] in
            self?.beginRegionCapture()
        }
        fullHotKeyID = hotkeyCenter.register(keyCode: full.keyCode, modifiers: full.modifiers) { [weak self] in
            self?.beginFullScreenCapture()
        }
        historySpotlightHotKeyID = hotkeyCenter.register(keyCode: spotlight.keyCode, modifiers: spotlight.modifiers) { [weak self] in
            self?.toggleHistorySpotlight()
        }
        recordVideoHotKeyID = hotkeyCenter.register(keyCode: recVideo.keyCode, modifiers: recVideo.modifiers) { [weak self] in
            self?.beginRegionRecording(format: .mp4)
        }
        recordGIFHotKeyID = hotkeyCenter.register(keyCode: recGIF.keyCode, modifiers: recGIF.modifiers) { [weak self] in
            self?.beginRegionRecording(format: .gif)
        }
        // ⚠️ 兜底热键（⌥⌘H / ⌃⌥D / ⌥⌘, / ⌥⌘P）只注册一次——rebind 不会走这里
        guard !everRegisteredFallbacks else { return }
        everRegisteredFallbacks = true
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
        // 贴图 Boss Key（一键隐藏/恢复全部贴图）：⌥⌘P
        deps.hotkeys.register(
            keyCode: UInt32(kVK_ANSI_P), modifiers: [.option, .command]
        ) { [weak self] in
            self?.toggleAllPinsVisibility()
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

    /// 滚动长图的保存面板入口（ScrollController 调；exporter 私有经此转发）
    func quickSaveScroll(image: CGImage) {
        exporter.savePanel(image)
    }

    func beginRegionCapture() {
        if state == .overlay {
            // 已在选区态时再次按 F1：若光标移到了另一块屏则直接切换屏幕重开，
            // 若在同屏则立刻提至最前并刷新十字准星与放大镜，绝不静默丢弃让用户以为卡死
            overlayController?.refocusOrSwitchScreenForCapture()
            return
        }
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
                    // 复制反馈（设置可关）：右下角 toast，不抢焦点。
                    // 点击 toast → 恢复干净底图 + 矢量标注继续重编
                    let snapshot = self.overlayController?.lastExportSnapshot
                    self.showCopyToast(image: image, snapshot: snapshot)
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

    // MARK: - 屏幕录制与 GIF 录制

    private(set) var isRecordingActive = false

    /// 托盘/全局热键直接进入框选录制（再次触发热键可停止正在进行的录制）
    func beginRegionRecording(format: RecordingFormat) {
        if isRecordingActive {
            stopActiveRecording()
            return
        }
        guard state == .idle else {
            Log.event(.recording, "recording.ignored", ["state": state.rawValue])
            return
        }
        guard ensureCaptureReadiness() else { return }
        state = .overlay
        if overlayController == nil {
            overlayController = OverlayController()
        }
        overlayController?.beginForRecording(format: format) { [weak self] _ in
            self?.state = .idle
        }
    }

    func stopActiveRecording() {
        overlayController?.stopRecordingFromBar()
    }

    func cancelActiveRecording() {
        overlayController?.cancelRecordingSession()
    }

    func setRecordingActiveState(_ active: Bool) {
        isRecordingActive = active
        if UserDefaults.standard.bool(forKey: "app.recording.active") != active {
            UserDefaults.standard.set(active, forKey: "app.recording.active")
        }
    }

    func updateRecordingOptions(_ options: RecordingOptions) {
        settings.recordingOptions = options
        UserDefaultsSettingsStore().save(settings)
    }

    func handleRecordingCompleted(_ result: RecordingResult) {
        exporter.finalizeAskEveryTimeRecording(result) { [weak self] finalResult in
            guard let self, let finalResult else { return }
            CaptureSoundPlayer.play()

            let copyFile: @MainActor (URL) -> Void = { [weak self] url in
                _ = self?.deps.clipboard.writeFileURL(url)
                CaptureToast.show(message: "已复制文件到剪贴板", status: .ok)
            }
            let revealInFinder: @MainActor (URL) -> Void = { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            let discardFile: @MainActor (URL) -> Void = { url in
                do {
                    try FileManager.default.removeItem(at: url)
                    Log.event(.recording, "recording.discard.ok")
                    CaptureToast.show(message: "已删除本次录制", status: .ok)
                } catch {
                    Log.error(.recording, "recording.discard.fail", ["err": error.localizedDescription])
                    CaptureToast.show(message: "删除失败：\(error.localizedDescription)", status: .warn)
                }
            }

            CaptureToast.showRecording(
                finalResult,
                onCopyFile: copyFile,
                onRevealInFinder: revealInFinder,
                onOpen: { _ in
                    if finalResult.format == .gif {
                        GIFPreviewPanel.shared.show(
                            result: finalResult,
                            callbacks: GIFPreviewPanel.Callbacks(
                                onCopyFile: copyFile,
                                onRevealInFinder: revealInFinder,
                                onDiscard: discardFile
                            )
                        )
                    } else {
                        // 裁剪 / 转 GIF 都在本机文件层面完成：
                        // - MP4 原地原子替换（导出会话自己先写临时文件，不留任何垃圾）；
                        // - GIF 与源文件同目录同名（`foo.mp4` → `foo.gif`，重名才追加时间戳）。
                        let deps = self.deps
                        let recordingOptions = self.settings.recordingOptions
                        let gifOptions = GIFConversionOptions(
                            fps: max(10, min(20, recordingOptions.gifFPS)),
                            maxDimension: recordingOptions.gifScale1x ? 960 : 1440
                        )
                        let gifDestination: @MainActor (URL) -> URL = { sourceURL in
                            let base = sourceURL.deletingPathExtension()
                            let plain = base.appendingPathExtension("gif")
                            guard FileManager.default.fileExists(atPath: plain.path) else { return plain }
                            let suffix = "\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
                            return base.deletingLastPathComponent()
                                .appendingPathComponent("\(base.lastPathComponent)-\(suffix)")
                                .appendingPathExtension("gif")
                        }
                        let openGIFPreview: @MainActor (RecordingResult) -> Void = { gifResult in
                            GIFPreviewPanel.shared.show(
                                result: gifResult,
                                callbacks: GIFPreviewPanel.Callbacks(
                                    onCopyFile: copyFile,
                                    onRevealInFinder: revealInFinder,
                                    onDiscard: discardFile
                                )
                            )
                        }
                        VideoPreviewPanel.shared.show(
                            result: finalResult,
                            callbacks: VideoPreviewPanel.Callbacks(
                                onCopyFile: copyFile,
                                onRevealInFinder: revealInFinder,
                                onDiscard: discardFile,
                                onTrim: { result, range in
                                    let trimmed = try await deps.videoPostProcessor.trimMP4(
                                        sourceURL: result.fileURL,
                                        range: range,
                                        destinationURL: result.fileURL
                                    )
                                    Log.event(.recording, "recording.trim.rewrite", [
                                        "duration": String(format: "%.2f", trimmed.duration),
                                        "bytes": "\(trimmed.fileSizeBytes)",
                                    ])
                                    return trimmed
                                },
                                onConvertToGIF: { result, range, progress in
                                    let destination = gifDestination(result.fileURL)
                                    let gifResult = try await deps.videoPostProcessor.convertMP4ToGIF(
                                        sourceURL: result.fileURL,
                                        range: range,
                                        options: gifOptions,
                                        destinationURL: destination,
                                        onProgress: progress
                                    )
                                    Log.event(.recording, "recording.convertGIF.write", [
                                        "bytes": "\(gifResult.fileSizeBytes)",
                                        "frames": "\(gifResult.frameCount)",
                                    ])
                                    return gifResult
                                },
                                onOpenGIFPreview: openGIFPreview
                            )
                        )
                    }
                },
                onDiscard: discardFile
            )
        }
    }

    /// 呼出或收起视觉记忆库 Spotlight 搜索面板（⌥⌘V / 托盘入口共用）
    func toggleHistorySpotlight() {
        if HistorySpotlightPanel.shared.isVisible {
            HistorySpotlightPanel.shared.dismiss()
            return
        }
        guard state == .idle else {
            Log.event(.history, "history.spotlight.ignored", ["state": state.rawValue])
            return
        }
        let callbacks = HistorySpotlightPanel.Callbacks(
            loadRecords: {
                HistoryStore.shared.records()
            },
            cachedThumbnail: { record, maxSize in
                HistoryStore.shared.cachedThumbnail(forRecordID: record.id, maxSize: maxSize)
            },
            loadThumbnailAsync: { record, maxSize in
                await HistoryStore.shared.loadThumbnailAsync(
                    forRecordID: record.id,
                    pixelSize: CGSize(width: record.width, height: record.height),
                    maxSize: maxSize
                )
            },
            onCopyImage: { [weak self] record in
                guard let self else { return }
                let copied = HistoryStore.shared.copyToPasteboard(id: record.id)
                guard copied else {
                    CaptureToast.show(message: "无法读取历史截图", status: .warn)
                    return
                }
                guard self.settings.showCopyNotification else { return }
                if let fullImage = HistoryStore.shared.loadFullImage(for: record.id) {
                    let recordID = record.id
                    CaptureToast.show(image: fullImage, onClick: { [weak self] in
                        guard let self else { return }
                        if let editable = HistoryStore.shared.loadEditableSession(for: recordID) {
                            self.reopenEditor(
                                image: editable.baseImage,
                                initialAnnotations: editable.payload.annotations,
                                savedCanvasSize: editable.payload.canvasSize
                            )
                        } else {
                            self.reopenEditor(image: fullImage)
                        }
                    })
                } else {
                    CaptureToast.show(message: "已复制到剪贴板", status: .ok)
                }
            },
            onReopenEdit: { [weak self] record in
                guard let self else { return }
                if let editable = HistoryStore.shared.loadEditableSession(for: record.id) {
                    self.reopenEditor(
                        image: editable.baseImage,
                        initialAnnotations: editable.payload.annotations,
                        savedCanvasSize: editable.payload.canvasSize
                    )
                } else if let fullImage = HistoryStore.shared.loadFullImage(for: record.id) {
                    self.reopenEditor(image: fullImage)
                } else {
                    CaptureToast.show(message: "无法读取历史截图", status: .warn)
                }
            },
            onPin: { [weak self] record in
                guard let self else { return }
                guard let img = HistoryStore.shared.loadFullImage(for: record.id) else {
                    CaptureToast.show(message: "无法读取历史截图", status: .warn)
                    return
                }
                let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                    ?? NSScreen.main ?? NSScreen.screens.first
                guard let screen else { return }
                let visible = screen.visibleFrame
                let backing = max(1, screen.backingScaleFactor)
                let logicalW = max(1, CGFloat(img.width) / backing)
                let logicalH = max(1, CGFloat(img.height) / backing)
                let fit = min(1.0, min((visible.width * 0.75) / logicalW, (visible.height * 0.75) / logicalH))
                let w = max(1, (logicalW * fit).rounded())
                let h = max(1, (logicalH * fit).rounded())
                let rect = CGRect(
                    x: (visible.midX - w / 2).rounded(),
                    y: (visible.midY - h / 2).rounded(),
                    width: w,
                    height: h
                )
                self.deps.pinning.pin(img, atGlobalRect: rect)
            },
            onCopyOCRText: { [weak self] record in
                guard let self else { return }
                if !record.ocrText.isEmpty {
                    self.deps.clipboard.writeText(record.ocrText)
                    CaptureToast.show(message: "已复制识别文字")
                } else {
                    CaptureToast.show(message: "该截图暂无可复制文字", status: .warn)
                }
            },
            // 拖出到 Finder/飞书等：只给文件路径，UI 层不直连 HistoryStore
            fileURLForRecord: { record in
                HistoryStore.shared.imageFileURL(for: record.id)
            }
        )
        HistorySpotlightPanel.shared.toggle(callbacks: callbacks)
    }

    /// 全局隐藏/恢复全部贴图（Boss Key ⌥⌘P / 托盘入口共用）
    func toggleAllPinsVisibility() {
        guard PinWindowController.hasLivePins else {
            Log.event(.pin, "pin.bossKey.noop")
            return
        }
        let hidden = PinWindowController.toggleAllVisibility()
        CaptureToast.show(message: hidden ? "已隐藏全部贴图（再按 ⌥⌘P 唤回）" : "已恢复全部贴图")
    }

    // MARK: - 外部剪贴板图片智能感知（微信/飞书复制图片的轻提示入口）

    /// 启动外部剪贴板监听：只监听粘贴板计数变化，命中「图片 + 文字/二维码」才提示，
    /// 截图/编辑进行中（state != idle）直接跳过，绝不打断手上的活
    private func startClipboardImageWatcher() {
        let watcher = ClipboardImageWatcher.shared
        watcher.isEnabled = settings.smartClipboardImagePrompt
        watcher.isBusyProvider = { [weak self] in (self?.state ?? .idle) != .idle }
        watcher.onDetected = { [weak self] detected in
            self?.handleClipboardImageDetected(detected)
        }
        watcher.start()
        Log.event(.clipboard, "clipboard.watch.start", [
            "enabled": "\(settings.smartClipboardImagePrompt)",
        ])
    }

    /// 检测到外部剪贴板图片：右下角轻提示（贴图划词 / 提取文字两个入口）
    private func handleClipboardImageDetected(_ detected: ClipboardDetectedImage) {
        guard state == .idle else {
            Log.event(.clipboard, "clipboard.detected.ignored", ["state": state.rawValue])
            return
        }
        Log.event(.clipboard, "clipboard.detected", [
            "hasText": "\(detected.hasText)",
            "hasQR": "\(detected.hasQR)",
            "chars": "\(detected.charCount)",
            "pxW": "\(detected.image.width)",
            "pxH": "\(detected.image.height)",
        ])
        CaptureToast.showClipboardImageDetected(
            thumbnail: detected.image,
            pixelSize: CGSize(width: detected.image.width, height: detected.image.height),
            hasText: detected.hasText,
            hasQR: detected.hasQR,
            charCount: detected.charCount,
            onPinLiveText: { [weak self] in
                self?.pinDetectedClipboardImage(detected)
            },
            onExtractOCR: { [weak self] in
                self?.openStructuredOCR(for: detected.image)
            }
        )
    }

    /// 托盘 / 兜底菜单入口：把剪贴板图片贴到屏幕上并立刻进入实况文本划词态
    func pinClipboardImageWithLiveText() {
        guard let image = ClipboardImageReader.readImage() else {
            CaptureToast.show(message: "剪贴板中无可用图片", status: .warn)
            return
        }
        guard let screen = clipboardTargetScreen() else { return }
        let rect = centeredPinRect(for: image, on: screen)
        PinWindowController.pin(
            image,
            atGlobalRect: rect,
            on: screen,
            initialLiveTextAnalysis: nil,
            activateLiveTextImmediately: true
        )
        Log.event(.clipboard, "clipboard.pin", [
            "src": "clipboard",
            "pxW": "\(image.width)",
            "pxH": "\(image.height)",
        ])
    }

    /// 轻提示「贴图划词」：直接透传已经分析好的实况文本结果，避免二次跑 Vision
    private func pinDetectedClipboardImage(_ detected: ClipboardDetectedImage) {
        guard let screen = clipboardTargetScreen() else { return }
        let rect = centeredPinRect(for: detected.image, on: screen)
        PinWindowController.pin(
            detected.image,
            atGlobalRect: rect,
            on: screen,
            initialLiveTextAnalysis: detected.analysis,
            activateLiveTextImmediately: true
        )
        Log.event(.clipboard, "clipboard.pin.detected", [
            "hasText": "\(detected.hasText)",
            "chars": "\(detected.charCount)",
        ])
    }

    /// 托盘 / 兜底菜单入口：直接对剪贴板图片做结构化 OCR（识别结果浮层）
    func ocrClipboardImage() {
        guard let image = ClipboardImageReader.readImage() else {
            CaptureToast.show(message: "剪贴板中无可用图片", status: .warn)
            return
        }
        openStructuredOCR(for: image)
    }

    /// 结构化 OCR 统一出口（克隆贴图取字面板同款浮层语义）
    private func openStructuredOCR(for image: CGImage) {
        guard let screen = clipboardTargetScreen() else { return }
        let visible = screen.visibleFrame
        let anchorRect = CGRect(
            x: (visible.midX - 160).rounded(),
            y: (visible.midY - 120).rounded(),
            width: 320,
            height: 240
        )
        Log.event(.ocr, "ocr.start", [
            "pxW": "\(image.width)",
            "pxH": "\(image.height)",
            "src": "clipboard",
        ])
        Task { @MainActor in
            do {
                let result = try await deps.textRecognizer.recognizeStructured(image)
                NSApp.activate()
                OCRResultPanel.present(
                    result: result,
                    nearGlobalRect: anchorRect,
                    on: screen,
                    avoidRect: nil
                )
            } catch {
                Log.error(.ocr, "ocr.fail", ["src": "clipboard", "err": error.localizedDescription])
                CaptureToast.show(message: "文字识别失败：\(error.localizedDescription)", status: .warn)
            }
        }
    }

    /// 光标所在屏（兜底主屏 / 首屏）——与视觉记忆面板贴图同一判据
    private func clipboardTargetScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 屏幕可见区居中、按 75% 上限缩放后的初始贴图矩形（像素 → 逻辑点）
    private func centeredPinRect(for image: CGImage, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let backing = max(1, screen.backingScaleFactor)
        let logicalW = max(1, CGFloat(image.width) / backing)
        let logicalH = max(1, CGFloat(image.height) / backing)
        let fit = min(1.0, min((visible.width * 0.75) / logicalW, (visible.height * 0.75) / logicalH))
        let w = max(1, (logicalW * fit).rounded())
        let h = max(1, (logicalH * fit).rounded())
        return CGRect(
            x: (visible.midX - w / 2).rounded(),
            y: (visible.midY - h / 2).rounded(),
            width: w,
            height: h
        )
    }

    private func showCopyToast(image: CGImage, snapshot: EditableExportSnapshot?) {
        guard settings.showCopyNotification else { return }
        CaptureToast.show(image: image, onClick: { [weak self] in
            if let snapshot, !snapshot.annotations.isEmpty {
                self?.reopenEditor(
                    image: snapshot.baseImage,
                    initialAnnotations: snapshot.annotations,
                    savedCanvasSize: snapshot.canvasSize
                )
            } else {
                self?.reopenEditor(image: image)
            }
        })
    }

    /// 外源图 / 拼贴合成图统一无边框标注编辑器入口（复用 overlay + Liquid Glass 工具栏）
    func openStandaloneEditor(
        image: CGImage,
        preferredScreen: NSScreen? = nil,
        preferredRect: CGRect? = nil
    ) {
        reopenEditor(image: image, preferredScreen: preferredScreen, preferredRect: preferredRect)
    }

    /// toast 点击重开编辑 / 历史重编 / 拼贴合并编辑（复用 overlay 生命周期，回车/导出走同一 completion 链）
    private func reopenEditor(
        image: CGImage,
        initialAnnotations: [AnnotationModel]? = nil,
        savedCanvasSize: CGSize? = nil,
        preferredScreen: NSScreen? = nil,
        preferredRect: CGRect? = nil
    ) {
        guard state == .idle else {
            Log.event(.app, "toast.reopen.ignored", ["state": state.rawValue])
            return
        }
        state = .confirm
        if overlayController == nil {
            overlayController = OverlayController()
        }
        overlayController?.openEditor(
            image: image,
            initialAnnotations: initialAnnotations,
            savedCanvasSize: savedCanvasSize,
            preferredScreen: preferredScreen,
            preferredRect: preferredRect,
            completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .copy(let img):
                self.state = .exporting
                self.exporter.copyToClipboard(img)
                let snapshot = self.overlayController?.lastExportSnapshot
                self.showCopyToast(image: img, snapshot: snapshot)
            case .save(let img):
                self.state = .exporting
                self.exporter.savePanel(img)
            case .cancelled:
                break
            }
            self.state = .idle
        })
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
                let snapshot = self.overlayController?.lastExportSnapshot
                self.showCopyToast(image: image, snapshot: snapshot)
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
