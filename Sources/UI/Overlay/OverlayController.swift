import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 覆盖层控制器：每屏一窗，管理 选区 → 编辑 → 导出 全会话
///
/// 会话流（v0.2 起）：
/// 1. begin：蒙层 + 拖选
/// 2. 松手 didSelect：**立即冻结底图**（工具栏出现前，保证 UI 不入图）
/// 3. 进入编辑态：选区显示冻结底图 + 标注交互 + 工具栏
/// 4. Enter/双击/按钮：底图+标注合成 → 剪贴板/保存
@MainActor
final class OverlayController {
    enum Result {
        case copy(CGImage)
        case save(CGImage)
        case cancelled
    }

    enum Action {
        case copy
        case save
        case quickSave
        case cancel
    }

    private var windows: [OverlayWindow] = []
    /// 屏幕级 OverlayWindow 复用池（按 displayID 缓存；彻底消除重启后首次建窗及每次 F1 重建 33MB 4K backing-store 的开销）
    private var windowPool: [CGDirectDisplayID: OverlayWindow] = [:]
    private var completion: ((Result) -> Void)?
    private var selectionScreen: NSScreen?
    private var selectionRectGlobal: CGRect?
    /// 会话开始时的前台 App（结束时把激活权还给它）
    private var previousApp: NSRunningApplication?
    /// 前台 App 的 pid（Int 永不失效；NSRunningApplication 引用在 App 挂起/
    /// 转后台时 isTerminated 语义不可靠——用户病例 7 次 prevAlive=false vs
    /// 2 次 restored 实锤）。归还时按 pid 从 runningApplications 重查活引用。
    private var previousAppPID: Int?
    /// 截图开始时设置窗是否开着（用户裁定 2026-11-22：开着就拍进冻结图，
    /// 可框选截设置面板本身；冻结后让它退场，end() 时按此标记回场）
    private var settingsWasVisibleAtCaptureBegin = false
    /// 编辑会话（编辑态非空）
    private(set) var editorSession: EditorSession?
    /// 最近一次编辑态导出快照（在 end() 清空 editorSession 前保存，供上层读写可重编矢量层）
    private(set) var lastExportSnapshot: EditableExportSnapshot?
    private var toolbar: ToolbarPanel?
    /// 冻结帧（每显示器一张，截图时刻的静态画面）
    ///
    /// 架构决策（照 Snow Shot 主流程，docs/research/01-capture.md）：
    /// **先冻结整屏 → 再在静态帧上选区/标注**。收益：
    /// ① 选区期间内容不跳动（视频/动画/光标）；② 覆盖层永不可能入图（拍完才显示窗口）；
    /// ③ 选区调整/重拍/放大镜/取色全部离线可做；④ 松手进编辑态变零延迟（本地裁剪）。
    private(set) var frozenImages: [CGDirectDisplayID: CGImage] = [:]

    /// 滚动截图会话（编辑态 S / 工具栏按钮触发；串行流式增量拼接）
    private var scrollController: ScrollCaptureController?
    private var scrollSelectionRect: CGRect?
    private var scrollScreen: NSScreen?
    /// 采集 HUD（档 1 玻璃面板：呼吸点 + 等宽屏数/像素读数 + 状态提示）
    private var scrollHUD: ScrollCaptureHUDPanel?
    private var scrollBottomDetected = false
    private var scrollBottomWork: DispatchWorkItem?
    /// 双向真实触底/触顶检测（通过全局 scrollWheel 监听区分「主动继续滚却撞墙不增长」与「中途停下来看屏」）：
    /// 中途停顿无滚轮输入时绝不自动结束；无论是从上往下滚到底，还是从下往上滚到顶，只要撞墙即自动合成
    private var scrollWheelMonitor: Any?
    private var scrollWheelLocalMonitor: Any?
    private var scrollWheelEverReceived = false
    private var scrollDownSign: CGFloat = -1
    private var scrollDownSignCalibrated = false
    private var lastScrollEventDeltaY: CGFloat = 0
    private var lastDownScrollTime: CFAbsoluteTime = 0
    private var lastUpScrollTime: CFAbsoluteTime = 0
    private var scrollDownEventsSinceGrowth = 0
    private var scrollUpEventsSinceGrowth = 0
    private var boundaryWallStaticFrames = 0
    private var boundaryWallStartTime: CFAbsoluteTime?
    private var scrollViewportHeightPx = 1
    private var scrollInContainedRegion = false
    /// 串行流式增量拼接管线（actor 隔离，保证严格按采集顺序处理）
    private var scrollPipeline: ScrollStitchPipeline?
    private var scrollFrameInFlight = false
    /// 60fps 突发甩屏防丢帧队列（上限 24 帧，彻底避免高速惯性滚动丢掉中间重叠帧）
    private var scrollFrameQueue: [CGImage] = []
    private static let maxBufferedScrollFrames = 24
    private var scrollSessionToken = 0
    private var scrollAcceptedCount = 0
    private var scrollStitchedHeightPx = 0
    /// 「滚动过快」HUD 提示的回落 work（1.2s）
    private var scrollDroppedHintWork: DispatchWorkItem?
    /// compose 期 Esc 连按计数（3 次 = 强制取消逃生）
    private var scrollEscForceCount = 0
    /// overlay 会话代际（begin/end 各 +1）：compose 异步回填必须同代才有效
    private var overlaySessionEpoch = 0
    /// 本次采集是否观测到过真实滚动（净贡献 > 0）：到底自动合成的前置条件——
    /// 从未滚动就静止 ≠ 到底（用户在读屏定位），不能自动合成
    private var scrollEverScrolled = false
    private var scrollInitialSelection: CGRect?
    /// 会话级 Carbon Esc 拦截：在 HIToolbox/WindowServer 层直接接管 Esc，
    /// 彻底不依赖 macOS 14+ 协作激活（NSApp.isActive / keyWindow）是否放行，
    /// 重启后首次唤起 0ms 也能一按 Esc 立刻关闭，且绝不漏给底层 App。
    private var overlayEscHotKey: UInt32?
    /// 滚动会话专用热键（终止键 = settings.editorHotkeys["scroll"] + Enter；Esc 由会话级 overlayEscHotKey 统一路由）
    private var scrollFinishHotKey: UInt32?
    private var scrollFinishReturnHotKey: UInt32?
    /// 收尾拼接进行中（stop 之后 → 合成结果回填编辑器之前的异步窗口期）：
    /// 此期间编辑器键全部吞掉（OverlayView.keyDown 检查）——editorSession 还挂着
    /// 旧单帧底图，Enter→done / Esc→cancel 会把会话销毁，合成结果将无处回填
    /// （病例：scroll.compose.begin 后 editor.hotkey action=done →
    ///  scroll.compose.fail → scroll.compose.noSession，长图丢失）
    private(set) var isScrollComposing = false

    // MARK: - 会话

    /// 启动后离屏静默预热（绝不抢前台焦点）：
    /// 1. 预建可复用 ToolbarPanel；
    /// 2. 预建当前鼠标所在屏的 OverlayWindow（orderOut 不显示，消除首次 4K backing-store 分配）；
    /// 3. 轻触输入源/CoreGraphics 像素管线，提前在后台完成冷元数据加载。
    func warmup() {
        if toolbar == nil {
            toolbar = ToolbarPanel()
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first {
            _ = acquireOverlayWindow(for: screen)
        }
        // 轻量触发输入源元数据加载（不激活 App、不抢焦点），缓解重启首次 key 窗时的 IMK 冷加载阻塞
        _ = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    private func acquireOverlayWindow(for screen: NSScreen) -> OverlayWindow {
        if let displayID = DisplayRegistry.displayID(of: screen) {
            if let pooled = windowPool[displayID] {
                pooled.prepareForReuse(screen: screen)
                return pooled
            }
            let win = OverlayWindow(screen: screen, controller: self)
            windowPool[displayID] = win
            return win
        }
        return OverlayWindow(screen: screen, controller: self)
    }

    /// 设置中修改了工具栏大小或按钮排序后立即失效缓存工具栏，下次按 F1 即刻生效（无需重启）
    func invalidateToolbar() {
        toolbar?.hideTooltip()
        toolbar?.orderOut(nil)
        toolbar = nil
    }

    private func registerOverlayEscapeHotKey() {
        guard overlayEscHotKey == nil else { return }
        overlayEscHotKey = CarbonHotKeyCenter.shared.register(
            keyCode: kVK_Escape, modifiers: []
        ) { [weak self] in
            self?.handleSessionEscape()
        }
    }

    private func unregisterOverlayEscapeHotKey() {
        CarbonHotKeyCenter.shared.unregister(overlayEscHotKey)
        overlayEscHotKey = nil
    }

    /// 会话级 Esc 统一路由（优先级：拼接逃生 > 滚动取消 > OCR 浮层 > 文字输入 > 退出截图会话）
    private func handleSessionEscape() {
        if isScrollComposing {
            scrollEscForceCount += 1
            Log.event(.scroll, "scroll.composing.ignoreKey", [
                "key": "esc", "force": "\(scrollEscForceCount)/3",
            ])
            if scrollEscForceCount >= 3 {
                teardownScrollSession()
                perform(action: .cancel)
            }
            return
        }
        if scrollController != nil {
            cancelScrollCapture()
            return
        }
        if OCRResultPanel.isPresented {
            OCRResultPanel.dismissIfPresented()
            return
        }
        for window in windows {
            if window.overlayView.cancelActiveTextEditingIfNeeded() {
                return
            }
        }
        perform(action: .cancel)
    }

    /// 从外源图片重开编辑器（toast 点击重开 / 拼贴合并后直接编辑共用）：
    /// 不拍屏（图已有）——若传入原位 `preferredRect` 且完整落在可视区内，直接原位无缝切换为无边框 Apple 标注画布；
    /// 否则按屏幕 backingScale 与可视区居中适配，并弹出一体化 Liquid Glass 工具栏（彻底告别笨重黑标题栏窗）。
    func openEditor(
        image: CGImage,
        initialAnnotations: [AnnotationModel]? = nil,
        savedCanvasSize: CGSize? = nil,
        preferredScreen: NSScreen? = nil,
        preferredRect: CGRect? = nil,
        completion: @escaping (Result) -> Void
    ) {
        self.completion = completion
        lastExportSnapshot = nil
        overlaySessionEpoch += 1
        teardownScrollSession()
        editorSession = nil
        toolbar?.hideTooltip()
        toolbar?.orderOut(nil)
        dismissAll()
        frozenImages.removeAll()
        previousApp = NSWorkspace.shared.frontmostApplication
        previousAppPID = previousApp.map { Int($0.processIdentifier) }
        registerOverlayEscapeHotKey()
        ensureActivation(reason: "toast.reopen")

        let screen = preferredScreen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        // 按屏幕原生点尺寸适配可视区（留出下方工具栏空间），若传入 preferredRect 则优先原位无缝衔接
        let visible = screen.visibleFrame
        let backing = max(1, screen.backingScaleFactor)
        let logicalW = CGFloat(image.width) / backing
        let logicalH = CGFloat(image.height) / backing
        let toolbarReserve = DesignTokens.Toolbar.height + 20
        let maxW = visible.width * 0.88
        let maxH = max(200, visible.height * 0.84 - toolbarReserve)
        let fit = min(1.0, min(maxW / max(1, logicalW), maxH / max(1, logicalH)))
        let w = max(80, (logicalW * fit).rounded())
        let h = max(80, (logicalH * fit).rounded())

        let selection: CGRect
        if let pref = preferredRect {
            let minX = visible.minX + 16
            let maxX = max(minX, visible.maxX - w - 16)
            let minY = visible.minY + toolbarReserve
            let maxY = max(minY, visible.maxY - h - 16)
            let x = min(max(pref.midX - w / 2, minX), maxX).rounded()
            let y = min(max(pref.midY - h / 2, minY), maxY).rounded()
            selection = CGRect(x: x, y: y, width: w, height: h)
        } else {
            let centerY = visible.midY + DesignTokens.Toolbar.height * 0.4
            let minY = max(visible.minY + toolbarReserve, centerY - h / 2)
            let clampedMinY = min(minY, visible.maxY - h - 16)
            selection = CGRect(
                x: (visible.midX - w / 2).rounded(),
                y: clampedMinY.rounded(),
                width: w,
                height: h
            )
        }

        let window = acquireOverlayWindow(for: screen)
        window.orderFrontRegardless()
        windows.append(window)
        window.makeKey()

        selectionScreen = screen
        selectionRectGlobal = selection
        AppCoordinatorShared.didEnterConfirm()
        enterEditor(base: image, selection: selection, screen: screen)
        if let initialAnnotations, !initialAnnotations.isEmpty, let session = editorSession {
            session.restoreAnnotations(initialAnnotations, savedCanvasSize: savedCanvasSize)
            toolbar?.refreshSelectionState()
            editorWindow()?.overlayView.needsDisplay = true
            Log.event(.editor, "editor.restore.annotations", ["count": "\(initialAnnotations.count)"])
        }
        Log.event(.app, "toast.reopen.editor", [
            "pxW": "\(image.width)", "pxH": "\(image.height)",
            "ptW": "\(Int(w))", "ptH": "\(Int(h))",
        ])
    }

    func begin(completion: @escaping (Result) -> Void, onShown: (() -> Void)? = nil) {
        self.completion = completion
        lastExportSnapshot = nil
        overlaySessionEpoch += 1
        // 补丁 E（reviewer）：防御性清滚动残留（不依赖 coordinator state 门禁——
        // 缺失边①：任何绕过路径留下的吞键/采样/HUD 状态一律清零）
        teardownScrollSession()
        // 用户裁定 2026-11-22：设置窗在冻结期间保持可见——它会被一起拍进冻结图，
        // 用户可以直接框选截设置面板本身（旧实现 begin 时先退场 ⇒ 永远截不到）。
        // 冻结完成后、覆盖层上屏前再退场（见下方 Task 内 restoreSettingsAfterCapture），
        // 避免 live 设置窗浮在覆盖层上挡交互。
        settingsWasVisibleAtCaptureBegin = SettingsWindowController.shared.isVisible
        previousApp = NSWorkspace.shared.frontmostApplication
        if let prev = previousApp {
            previousAppPID = Int(prev.processIdentifier)
            Log.event(.app, "focus.begin.record", [
                "pid": "\(previousAppPID ?? -1)",
                "bundle": prev.bundleIdentifier ?? "?",
                "active": "\(NSApp.isActive)",
            ])
        } else {
            previousAppPID = nil
            Log.event(.app, "focus.begin.record", ["pid": "-1", "bundle": "nil"])
        }
        editorSession = nil
        toolbar?.hideTooltip()
        toolbar?.orderOut(nil)
        dismissAll()
        frozenImages.removeAll()
        // 立刻注册会话级 Carbon Esc 热键：即使 macOS 14+ 暂未授予激活态，Esc 也能 0ms 可靠退出
        registerOverlayEscapeHotKey()

        // 仅锁定鼠标当前所在屏幕（不覆盖另一块外接/内建屏，冻结耗时也减半）
        // 注意：不再在 captureDisplay 之前同步调用 NSApp.activate()，消除首次冷启动 ViewBridgeAuxiliary 35ms 抢跑阻塞
        let targetScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        // 冻结优先：窗口先不上屏（此刻若有窗口会被自己拍进去），拍完立刻上屏（零 sleep 门闩）
        let epoch = overlaySessionEpoch
        Task { [weak self] in
            guard let self else { return }
            let start = DispatchTime.now()
            var frames: [CGDirectDisplayID: CGImage] = [:]
            if let screen = targetScreen, let displayID = DisplayRegistry.displayID(of: screen) {
                do {
                    let image = try await SCKCapture.shared.captureDisplay(displayID: displayID)
                    frames[displayID] = image
                } catch {
                    Log.error(.capture, "freeze.fail", [
                        "display": "\(displayID)", "err": "\(error)",
                    ])
                }
            }
            // 若用户在冻结几十毫秒内已按 Esc 取消，直接丢弃，绝不迟到弹窗
            guard epoch == self.overlaySessionEpoch else { return }
            self.frozenImages = frames
            // 冻结已完成：设置窗（若开着）已被拍进冻结图。现在让它退场，
            // 避免 live 窗口浮在即将上屏的覆盖层上（见 begin 顶部用户裁定）。
            if SettingsWindowController.shared.isVisible {
                SettingsWindowController.shared.orderOutForCapture()
            }
            let freezeMs = Int(
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            )
            if let screen = targetScreen {
                self.showOverlayWindow(on: screen)
            }
            let elapsedMs = Int(
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            )
            Log.event(.overlay, "overlay.open", [
                "screens": "1/\(NSScreen.screens.count)",
                "ms": "\(elapsedMs)",
                "freezeMs": "\(freezeMs)",
                "frozen": "\(frames.count)",
            ])
            onShown?()
        }
    }

    /// 已处于选区态时再次按下区域截图热键：
    /// - 若光标已移至另一台显示器，自动切到光标当前屏重冻并展示；
    /// - 若仍在当前屏，立刻把覆盖层提到最前并刷新光标位置、十字准星与放大镜。
    func refocusOrSwitchScreenForCapture() {
        guard editorSession == nil, scrollController == nil else { return }
        let targetScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let targetScreen, let existing = windows.first, existing.owningScreen != targetScreen,
           let savedCompletion = completion {
            Log.event(.overlay, "overlay.switchScreen")
            begin(completion: savedCompletion)
            return
        }
        for win in windows {
            win.orderFrontRegardless()
            win.makeKey()
            win.syncInitialCursor()
        }
        Log.event(.overlay, "overlay.refocus")
    }

    /// 上屏：仅在鼠标所在屏复用覆盖窗并挂载 GPU 冻结帧（其余屏幕完全不打扰）
    private func showOverlayWindow(on targetScreen: NSScreen) {
        let window = acquireOverlayWindow(for: targetScreen)
        if let displayID = DisplayRegistry.displayID(of: targetScreen),
           let frozen = frozenImages[displayID] {
            window.installFrozenImage(frozen)
        }
        window.orderFrontRegardless()
        windows.append(window)
        ensureActivation(reason: "overlay.show")
        window.makeKey()
        window.syncInitialCursor()
    }

    /// 从冻结帧本地裁剪（零延迟、零二次屏捕）
    func cropFrozenImage(selection: CGRect, screen: NSScreen) -> CGImage? {
        guard let displayID = DisplayRegistry.displayID(of: screen),
              let frozen = frozenImages[displayID] else { return nil }
        let px = CoordinateConverter.pixelRect(
            selection: selection, onScreen: screen,
            imageWidth: frozen.width, imageHeight: frozen.height
        )
        return frozen.cropping(to: px)
    }

    /// 全屏截图入口（⌘⇧S / 托盘「截取全屏」）：覆盖层一出现就命中鼠标所在显示器整屏
    func beginFullScreen(completion: @escaping (Result) -> Void) {
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        begin(completion: completion) { [weak self] in
            guard let self, let target else { return }
            for window in self.windows where window.owningScreen == target {
                window.pickFullDisplay()
            }
            // 其他屏的蒙层立刻撤掉（全屏会话只覆盖一块屏）
            for window in self.windows where window.owningScreen != target {
                window.orderOut(nil)
                window.close()
            }
            self.windows.removeAll { $0.owningScreen != target }
            Log.event(.overlay, "overlay.fullscreen.begin", [
                "screen": "\(Int(target.frame.width))x\(Int(target.frame.height))",
            ])
        }
    }

    func end() {
        overlaySessionEpoch += 1
        let endEpoch = overlaySessionEpoch
        unregisterOverlayEscapeHotKey()
        dismissAll()
        editorSession = nil
        // 保留 toolbar 实例供下次 0ms 复用（仅执行退场隐藏，不再 nil 销毁重建）
        toolbar?.dismiss()
        ocrCloseObserver.map { NotificationCenter.default.removeObserver($0) }
        ocrCloseObserver = nil
        teardownScrollSession()
        // 设置窗回场：截图开始时它若开着（被拍进了冻结图），覆盖层上屏前我们
        // 让它退过场（见 begin 内用户裁定）；会话结束后原样回场，现场不丢
        if settingsWasVisibleAtCaptureBegin, !SettingsWindowController.shared.isVisible {
            SettingsWindowController.shared.restoreAfterCapture()
        }
        settingsWasVisibleAtCaptureBegin = false
        // 仅当 80ms 后未开启新截图会话时才归还焦点，杜绝快速 Esc→F1 场景旧回调抢走新会话焦点
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.overlaySessionEpoch == endEpoch, self.windows.isEmpty else { return }
            self.restoreFocusRobust()
        }
    }

    /// 焦点归还的诊断 + 修正（用户病例 2026-11-16：「Esc 退出后应把焦点还给
    /// 台前 App」却走了 deactivate 兜底）——begin 时记录的 frontmost 在归
    /// 还时可能已失效（挂起/无窗口的 App yield 无效果）。改为：归还时优先
    /// 取「当时的」frontmostApplication（若 Snapcut 已 inactive 则它就是该
    /// 还给的人），record 兜底。
    private func restoreFocusRobust() {
        // 延后窗口内若用户已手动切换 App，不打扰（frontmost 已不是自己）
        guard NSApp.isActive else { return }
        // 病例（hadPrev=true prevAlive=false 二报）：记录的前台 App 引用已失效
        // （TUI 重启/pid 复用）——失效时回落「当前」frontmost（Snapcut 退激活
        // 后它就是正主），而不是直接 deactivate 吞掉焦点
        let prev: NSRunningApplication? = {
            // ① pid 重查（记录值永真：pid 不随 App 状态变化失效）
            let ownPID = Int(NSRunningApplication.current.processIdentifier)
            if let pid = previousAppPID, pid != ownPID,
               let live = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
               !live.isTerminated {
                return live
            }
            // ② 引用兜底
            if let p = previousApp, !p.isTerminated,
               p.processIdentifier != NSRunningApplication.current.processIdentifier {
                return p
            }
            // ③ 当前 frontmost（App inactive 后它是正主）
            if let c = NSWorkspace.shared.frontmostApplication, !c.isTerminated,
               c.processIdentifier != NSRunningApplication.current.processIdentifier {
                return c
            }
            return nil
        }()
        if let prev {
            // 窗口级归还（用户病例 2026-11-16 终报「红绿灯都没亮」）：yieldActivation
            // 只把 App 激活，prev 的窗口不变 key（红绿灯灰、TUI 收不到键盘）。
            // activate() 走完整激活链（App + key 窗），实测把 TUI 连窗拉回。
            _ = prev.activate()
            Log.event(.app, "focus.restored", ["to": prev.bundleIdentifier ?? "?", "via": "activate"])
        } else {
            NSApp.deactivate()
            let pidMatched = previousAppPID.flatMap { pid in
                NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == pid }
            } ?? false
            Log.event(.app, "focus.deactivated", [
                "hadPrev": "\(previousApp != nil)",
                "prevAlive": "\(previousApp?.isTerminated ?? false)",
                "pid": "\(previousAppPID ?? -1)",
                "pidMatched": "\(pidMatched)",
            ])
        }
    }

    /// 无条件拆滚动会话资源（热键/HUD/采样器/滚轮监听）；不影响编辑会话
    private func teardownScrollSession() {
        isScrollComposing = false
        scrollEscForceCount = 0
        scrollSessionToken += 1
        scrollFrameInFlight = false
        scrollFrameQueue.removeAll()
        scrollPipeline = nil
        boundaryWallStaticFrames = 0
        boundaryWallStartTime = nil
        unregisterScrollHotKeys()
        removeScrollWheelMonitor()
        scrollBottomWork?.cancel()
        scrollBottomWork = nil
        scrollController?.stop()
        scrollController = nil
        scrollHUD?.hide()
        scrollHUD = nil
        scrollAcceptedCount = 0
        scrollStitchedHeightPx = 0
        scrollViewportHeightPx = 1
        scrollDroppedHintWork?.cancel()
        scrollDroppedHintWork = nil
        scrollInitialSelection = nil
        scrollBottomDetected = false
        scrollWheelEverReceived = false
        scrollDownSign = -1
        scrollDownSignCalibrated = false
        lastScrollEventDeltaY = 0
        lastDownScrollTime = 0
        lastUpScrollTime = 0
        scrollDownEventsSinceGrowth = 0
        scrollUpEventsSinceGrowth = 0
        boundaryWallStaticFrames = 0
        scrollInContainedRegion = false
        scrollEverScrolled = false
        // 焦点屏语义：滚动态只可能挂在 scrollScreen 上，其余屏窗口不换态
        // （防御：scrollScreen 为空时仍全量清扫，保证会话结束无残留）
        let focal = scrollScreen
        for window in windows where focal == nil || window.owningScreen == focal {
            window.exitScrollMode()
        }
    }

    private func installScrollWheelMonitor() {
        removeScrollWheelMonitor()
        scrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let deltaY = event.scrollingDeltaY
            guard abs(deltaY) >= 0.25 else { return }
            MainActor.assumeIsolated {
                self?.handleGlobalScrollWheel(deltaY: deltaY)
            }
        }
        scrollWheelLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let deltaY = event.scrollingDeltaY
            if abs(deltaY) >= 0.25 {
                MainActor.assumeIsolated {
                    self?.handleGlobalScrollWheel(deltaY: deltaY)
                }
            }
            return event
        }
    }

    private func removeScrollWheelMonitor() {
        if let monitor = scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
            scrollWheelMonitor = nil
        }
        if let local = scrollWheelLocalMonitor {
            NSEvent.removeMonitor(local)
            scrollWheelLocalMonitor = nil
        }
    }

    /// 监听全局滚轮/触控板手势（支持双向：从上往下滑触底 & 从下往上滑触顶）：
    /// 中途停下来看屏（无滚轮输入）绝不误判到底，随时允许按 Enter 结束。
    private func handleGlobalScrollWheel(deltaY: CGFloat) {
        guard scrollController != nil else { return }
        if !scrollWheelEverReceived {
            scrollWheelEverReceived = true
            Log.event(.scroll, "scroll.wheel.first", ["deltaY": String(format: "%.2f", deltaY)])
        }
        lastScrollEventDeltaY = deltaY
        let now = CFAbsoluteTimeGetCurrent()
        let orientedDown = deltaY * scrollDownSign
        if orientedDown > 0 {
            lastDownScrollTime = now
            scrollDownEventsSinceGrowth += 1
            scrollUpEventsSinceGrowth = 0
        } else if orientedDown < 0 {
            lastUpScrollTime = now
            scrollUpEventsSinceGrowth += 1
            scrollDownEventsSinceGrowth = 0
        }
    }

    private func unregisterScrollHotKeys() {
        let center = CarbonHotKeyCenter.shared
        center.unregister(scrollFinishHotKey)
        center.unregister(scrollFinishReturnHotKey)
        scrollFinishHotKey = nil
        scrollFinishReturnHotKey = nil
    }

    private func dismissAll() {
        for window in windows {
            window.orderOut(nil)
            let isPooled = windowPool.values.contains { $0 === window }
            if isPooled {
                window.prepareForReuse(screen: window.owningScreen)
            } else {
                window.close()
            }
        }
        windows.removeAll()
        selectionScreen = nil
        selectionRectGlobal = nil
    }

    /// 焦点归还：accessory App 保持激活却无窗口会吞掉全局键盘事件
    private func restoreFocus() {
        guard NSApp.isActive else { return }
        if let prev = previousApp, !prev.isTerminated,
           prev.processIdentifier != NSRunningApplication.current.processIdentifier {
            NSApp.yieldActivation(to: prev)
            Log.event(.app, "focus.restored", ["to": prev.bundleIdentifier ?? "?"])
        } else {
            // selftest 直跑（previousApp=自己）等边缘情况：无条件退出激活，
            // 保证结束后键盘焦点不悬空
            NSApp.deactivate()
            Log.event(.app, "focus.deactivated")
        }
    }

    // MARK: - 拖选完成（OverlayView 回调）

    /// 松手确认：冻结底图并进入编辑态
    func didSelect(rect: CGRect, on screen: NSScreen, windowID: CGWindowID? = nil) {
        selectionScreen = screen
        selectionRectGlobal = rect
        let px = CoordinateConverter.pixelRect(selection: rect, onScreen: screen)
        Log.event(.overlay, "overlay.commit", [
            "rectPt": "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
            "rectPx": "\(Int(px.minX)),\(Int(px.minY)),\(Int(px.width)),\(Int(px.height))",
            "displayId": "\(DisplayRegistry.displayID(of: screen).map(String.init) ?? "?")",
        ])
        AppCoordinatorShared.didEnterConfirm()

        // 窗口截图：走 SCK 单窗口滤镜（拿窗口自身内容，被遮挡也正确）
        // ⚡ 其余走冻结帧本地裁剪（零延迟，所见=所得）
        if let windowID {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let base = try await SCKCapture.shared.captureWindow(windowID: windowID)
                    self.enterEditor(base: base, selection: rect, screen: screen)
                } catch {
                    Log.error(.capture, "capture.window.fail", ["err": "\(error.localizedDescription)"])
                    // 回退：冻结帧本地裁剪（窗口被遮挡时会截到遮挡物，但至少有结果）
                    if let frozen = self.cropFrozenImage(selection: rect, screen: screen) {
                        self.enterEditor(base: frozen, selection: rect, screen: screen)
                    } else {
                        TCCPermission.openSystemSettings()
                    }
                }
            }
            return
        }
        if let frozen = cropFrozenImage(selection: rect, screen: screen) {
            Log.event(.overlay, "overlay.commit.frozen", [
                "pxW": "\(frozen.width)", "pxH": "\(frozen.height)",
            ])
            enterEditor(base: frozen, selection: rect, screen: screen)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let base = try await CaptureService.captureRegion(rect, on: screen)
                self.enterEditor(base: base, selection: rect, screen: screen)
            } catch {
                // 截屏失败（权限等）：走引导
                TCCPermission.openSystemSettings()
            }
        }
    }

    // MARK: - 选区调整（编辑态拖手柄 / 方向键）

    /// 选区变更：
    /// - 冻结桌面态：从冻结帧重裁底图，标注按 `annotationOffset` 平移「钉在屏幕原位置」；
    /// - 独立外源图态（Toast 重开 / 长图编辑，frozenImages 为空）：等比缩放/平移视口，
    ///   底图像素保持完整原图分辨率、既有标注随视口等比缩放，彻底杜绝 `selection.adjust.noFrozen` 与拉伸模糊。
    func adjustSelection(to newGlobal: CGRect, on screen: NSScreen, annotationOffset: CGSize) {
        guard let session = editorSession else { return }
        if frozenImages.isEmpty {
            session.applyViewportTransform(newSelection: newGlobal)
            selectionRectGlobal = newGlobal
            editorWindow()?.overlayView.needsDisplay = true
            toolbar?.reposition(below: toolbarAnchorRectGlobal(for: session))
            return
        }
        let old = session.selectionGlobal
        let sizeUnchanged = abs(newGlobal.width - old.width) < 0.5
            && abs(newGlobal.height - old.height) < 0.5

        // 始终重裁（用户病例 2026-11-17「移动框直接给我移动贴图了」：尺寸不变
        // 时跳过重裁 → 底图保持旧位置内容跟着框平移 = 一张贴图在屏上飘。
        // 冻结帧是全屏的——框移到哪就裁哪的真实画面）
        var base = session.baseImage
        if let cropped = cropFrozenImage(selection: newGlobal, screen: screen) {
            base = cropped
        } else if !sizeUnchanged {
            Log.error(.overlay, "selection.adjust.noFrozen")
            return
        }
        session.applySelectionChange(
            newSelection: newGlobal, newBase: base, annotationOffset: annotationOffset
        )
        selectionRectGlobal = newGlobal
        // 编辑画布跟随新选区（视图侧自己算过一次，这里以 controller 为准再同步）
        editorWindow()?.overlayView.needsDisplay = true
        toolbar?.reposition(below: toolbarAnchorRectGlobal(for: session))
    }

    /// 独立外源图编辑态实时滚轮/捏合缩放：同步视口与标注缩放；工具栏保持原位稳妥锚定，不随缩放锚点左右漂移
    func zoomStandaloneSelection(to newGlobal: CGRect) {
        guard let session = editorSession, frozenImages.isEmpty else { return }
        session.applyViewportTransform(newSelection: newGlobal)
        selectionRectGlobal = newGlobal
    }

    /// 工具栏定位与贴图落位参考的全局矩形（开启画框时返回画框外沿全局矩形，否则返回选区全局矩形）
    private func toolbarAnchorRectGlobal(for session: EditorSession) -> CGRect {
        let selection = session.selectionGlobal
        guard let layout = session.currentBackdropLayout(for: selection.size) else {
            return selection
        }
        return CGRect(
            x: selection.minX - layout.imageRect.minX,
            y: selection.maxY + layout.imageRect.minY - layout.canvasSize.height,
            width: layout.canvasSize.width,
            height: layout.canvasSize.height
        )
    }

    // MARK: - 编辑态

    private func enterEditor(base: CGImage, selection: CGRect, screen: NSScreen) {
        // 幂等清理（病例 2026-11-16：enter.fromScroll 在 compose 回退链被调两次
        // ——旧工具栏不拆、双面板 + panel 负坐标）：重入先撤旧编辑视觉。
        // ⚠️ toolbar 实例保留（dismiss 视觉退场后复用——构建 440ms 太贵）
        if editorSession != nil {
            toolbar?.orderOut(nil)
            for window in windows {
                window.exitScrollMode()
                window.overlayView.exitEditorIfNeeded()
            }
        }
        // scale 用实测比例（px/pt），不信任 backingScale（BetterDisplay 病例）
        let realScale = CGFloat(base.width) / max(1, selection.width)
        let session = EditorSession(
            baseImage: base,
            scale: realScale,
            selectionGlobal: selection,
            screen: screen
        )
        editorSession = session

        // 找到选区所在屏的覆盖层窗口，切编辑模式（其他屏维持蒙层）
        for window in windows where window.owningScreen == screen {
            window.enterEditorMode(session: session)
        }

        // 先确保 App 激活与编辑覆盖窗成为 key（避免工具栏先于激活态出场、16ms 后再二次 activate + orderFront 导致玻璃闪一下）
        ensureActivation(reason: "editor.enter")
        if let editorWindow = self.editorWindow() {
            editorWindow.makeKeyAndOrderFront(nil)
            _ = editorWindow.makeFirstResponder(editorWindow.overlayView)
        }

        // 工具栏（复用实例——病例 2026-11-17「回车之后才出现工具栏」：每次
        // 新建 ToolbarPanel 的构建 ~440ms（20 按钮+玻璃+布局），松手→工具栏
        // 可见之间空窗长到用户以为工具栏是回车触发的。复用上次会话的工具栏
        // （configure 重绑 session/place 新位置），首次构建后即 0ms 就位）
        let toolbar = self.toolbar ?? ToolbarPanel()
        toolbar.updateScreen(screen)
        toolbar.configure(
            session: session,
            onToolChange: { [weak self] in
                self?.editorWindow()?.overlayView.syncActiveTextColor()
                self?.editorWindow()?.overlayView.needsDisplay = true
            },
            onAction: { [weak self] action in
                self?.toolbarAction(action)
            }
        )
        toolbar.updateBackdropStyle(session.backdropStyle)
        toolbar.onBackdropStyleChange = { [weak self] newStyle in
            guard let self, let session = self.editorSession else { return }
            session.backdropStyle = newStyle
            self.editorWindow()?.overlayView.needsDisplay = true
            self.toolbar?.reposition(below: self.toolbarAnchorRectGlobal(for: session))
        }
        toolbar.place(below: toolbarAnchorRectGlobal(for: session))
        self.toolbar = toolbar
        Log.event(.editor, "editor.enter", ["pxW": "\(base.width)", "pxH": "\(base.height)"])
        // 次帧键焦兜底：仅在窗口意外失焦时补回 key，正常情况下不重复调用 orderFrontRegardless 惊扰玻璃层
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorSession != nil,
                  let editorWindow = self.editorWindow() else { return }
            let editorView = editorWindow.overlayView
            if !NSApp.isActive || !editorWindow.isKeyWindow || editorWindow.firstResponder !== editorView {
                self.ensureActivation(reason: "editor.enter")
                editorWindow.makeKeyAndOrderFront(nil)
                _ = editorWindow.makeFirstResponder(editorView)
                self.toolbar?.orderFrontRegardless()
            }
            Log.event(.editor, "editor.focus", [
                "keyWin": "\(editorWindow.isKeyWindow)", "active": "\(NSApp.isActive)",
            ])
        }
    }

    /// 单次轻量激活请求（不轮询、不 sleep；Esc 已由会话级 Carbon 热键独立兜底）
    func ensureActivation(reason: String, attempt: Int = 0) {
        guard NSApp.isActive == false else { return }
        NSApp.activate()
    }

    private func editorWindow() -> OverlayWindow? {
        guard let screen = selectionScreen else { return nil }
        return windows.first { $0.owningScreen == screen }
    }

    func toolbarAction(_ action: ToolbarPanel.Action) {
        guard let session = editorSession else { return }
        switch action {
        case .undo:
            session.store.undo()
            toolbar?.refreshSelectionState()
            editorWindow()?.overlayView.needsDisplay = true
            Log.event(.editor, "annotate.undo", [
                "canUndo": "\(session.store.canUndo)", "canRedo": "\(session.store.canRedo)",
            ])
        case .redo:
            session.store.redo()
            toolbar?.refreshSelectionState()
            editorWindow()?.overlayView.needsDisplay = true
            Log.event(.editor, "annotate.redo", [
                "canUndo": "\(session.store.canUndo)", "canRedo": "\(session.store.canRedo)",
            ])
        case .toggleVisibility:
            session.toolbarVisible.toggle()
            // 键盘高频切换（H）不做入退场动画，零延迟响应（Emil Animation Standards）
            toolbar?.hideTooltip()
            toolbar?.setVisibleInstant(session.toolbarVisible)
            if session.toolbarVisible {
                toolbar?.reposition(below: toolbarAnchorRectGlobal(for: session))
            }
            // 显隐按钮图标同步：隐藏态 = eye.slash，再次点/按 H 唤回时表达「当前收起」
            toolbar?.setToolbarHidden(!session.toolbarVisible)
            Log.event(.editor, "editor.toolbar.\(session.toolbarVisible ? "show" : "hide")")
        case .done:
            perform(action: .copy)
        case .save:
            perform(action: .save)
        case .cancel:
            perform(action: .cancel)
        case .ocr:
            runOCR()
        case .pin:
            pinCurrentImage()
        case .scroll:
            beginScrollCapture()
        case .autoRedact:
            runAutoRedact()
        case .toggleBackdrop:
            session.backdropStyle.enabled.toggle()
            toolbar?.updateBackdropStyle(session.backdropStyle)
            toolbar?.reposition(below: toolbarAnchorRectGlobal(for: session))
            editorWindow()?.overlayView.needsDisplay = true
            Log.event(.editor, "backdrop.toggle", [
                "enabled": "\(session.backdropStyle.enabled)",
                "preset": session.backdropStyle.preset.rawValue,
            ])
        }
    }

    private var isAutoRedacting = false

    /// 智能一键脱敏（M1）：本地 Vision 词级定位敏感信息 → 批量生成 `.mosaic` 标注（一次 ⌘Z 整体撤销）
    private func runAutoRedact() {
        guard !isAutoRedacting, let session = editorSession else { return }
        guard let recognizer = AppCoordinatorShared.deps?.textRecognizer else { return }
        editorWindow()?.overlayView.flushPendingAnnotationForExport()

        isAutoRedacting = true
        toolbar?.setAutoRedactBusy(true)
        let baseImage = session.baseImage
        let canvasSize = session.selectionGlobal.size
        let epoch = overlaySessionEpoch

        Task { @MainActor [weak self] in
            defer {
                self?.isAutoRedacting = false
                self?.toolbar?.setAutoRedactBusy(false)
            }
            let regions = (try? await recognizer.detectSensitiveRegions(baseImage)) ?? []
            guard let self, self.overlaySessionEpoch == epoch, let liveSession = self.editorSession else { return }

            let existingMosaics: [CGRect] = liveSession.store.annotations.compactMap { ann in
                if case .mosaic(let r) = ann.shape { return r }
                return nil
            }

            var newItems: [AnnotationModel] = []
            var flashRects: [CGRect] = []
            let mosaicStroke = max(3.5, liveSession.strokeWidth)

            for region in regions {
                let rect = SensitiveTextDetector.localRect(
                    fromNormalizedTopLeft: region.normalizedRect,
                    canvasSize: canvasSize
                )
                guard rect.width >= 4, rect.height >= 4 else { continue }
                let alreadyCovered = existingMosaics.contains {
                    SensitiveTextDetector.overlapRatio(rect, $0) >= 0.65
                } || flashRects.contains {
                    SensitiveTextDetector.overlapRatio(rect, $0) >= 0.65
                }
                if alreadyCovered { continue }

                newItems.append(AnnotationModel(
                    shape: .mosaic(rect),
                    colorIndex: liveSession.colorIndex,
                    strokeWidth: mosaicStroke,
                    text: nil,
                    index: nil,
                    isAutoRedacted: true
                ))
                flashRects.append(rect)
            }

            if !newItems.isEmpty {
                liveSession.store.addBatch(newItems)
                self.toolbar?.refreshSelectionState()
                self.editorWindow()?.overlayView.flashAutoRedactRects(flashRects)
                self.editorWindow()?.overlayView.showEditorToast("已自动脱敏 \(newItems.count) 处 · 单击可取消")
                Log.event(.editor, "redact.applied", [
                    "added": "\(newItems.count)",
                    "detected": "\(regions.count)",
                ])
            } else if !regions.isEmpty {
                self.editorWindow()?.overlayView.showEditorToast("敏感信息已全部脱敏")
            } else {
                self.editorWindow()?.overlayView.showEditorToast("未检测到敏感信息")
            }
        }
    }

    // MARK: - OCR / 贴图（端口驱动）

    private func makeHistoryMetadata(for session: EditorSession) -> HistoryCaptureMetadata {
        HistoryCaptureMetadata(
            sourceApp: previousApp?.localizedName,
            windowTitle: nil,
            baseImage: session.baseImage,
            canvasSize: session.selectionGlobal.size,
            annotations: session.store.annotations,
            strokeWidth: session.strokeWidth
        )
    }

    /// 取字：结构化识别当前合成图（文字 / 二维码 / Markdown 表格）→ 浮层展示
    private func runOCR() {
        guard let session = editorSession else { return }
        editorWindow()?.overlayView.flushPendingAnnotationForExport()
        let image = session.renderFinalImage()
        let rect = session.selectionGlobal
        let screen = session.screen
        let recognizer = AppCoordinatorShared.deps?.textRecognizer
        let history = AppCoordinatorShared.deps?.history
        history?.record(image, metadata: makeHistoryMetadata(for: session))
        Log.event(.ocr, "ocr.start", ["pxW": "\(image.width)", "pxH": "\(image.height)"])
        Task { @MainActor in
            guard let recognizer else { return }
            let result = (try? await recognizer.recognizeStructured(image))
                ?? StructuredOCRResult(
                    plainText: "",
                    qrCodes: [],
                    markdownTable: nil,
                    tableRowCount: 0,
                    tableColumnCount: 0
                )
            let toolbarRect = (self.toolbar?.isVisible == true) ? self.toolbar?.visibleBarFrameGlobal : nil
            OCRResultPanel.present(result: result, nearGlobalRect: rect, on: screen, avoidRect: toolbarRect)
            restoreEditorFocusAfterOCRPanelCloses()
            Log.event(.ocr, "ocr.present", [
                "chars": "\(result.plainText.count)",
                "qrs": "\(result.qrCodes.count)",
                "table": result.markdownTable != nil ? "\(result.tableRowCount)x\(result.tableColumnCount)" : "none",
            ])
        }
    }

    /// OCR 浮层 makeKey 会拿走编辑器的键盘焦点；浮层关闭（Enter 复制/Esc/orderOut）后
    /// 必须把 key 还给编辑画布，否则随后的 Enter 复制可能失效。
    /// ⚠️ OCR 面板 close() 走 orderOut，不触发 willCloseNotification（只在 NSWindow.close()
    /// 才发），所以监听 didResignKey + isVisible 判断「面板真的收走了」。
    private var ocrCloseObserver: Any?

    private func restoreEditorFocusAfterOCRPanelCloses() {
        ocrCloseObserver.map { NotificationCenter.default.removeObserver($0) }
        ocrCloseObserver = nil
        guard let editorWin = editorWindow() else { return }
        guard let ocrPanel = NSApp.keyWindow, ocrPanel !== editorWin else {
            Log.event(.editor, "editor.focus.ocrNoPanel")
            return
        }
        ocrCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: ocrPanel, queue: .main
        ) { [weak self, weak ocrPanel] _ in
            MainActor.assumeIsolated {
                // 只有面板真正收走（orderOut / close）时才把焦点还给编辑器；
                // 面板只是暂时失去 key（如用户点了别的窗口）不动作
                guard let panel = ocrPanel, !panel.isVisible else { return }
                guard let self, let win = self.editorWindow() else { return }
                self.ocrCloseObserver.map { NotificationCenter.default.removeObserver($0) }
                self.ocrCloseObserver = nil
                win.makeKeyAndOrderFront(nil)
                _ = win.makeFirstResponder(win.overlayView)
                Log.event(.editor, "editor.focus.restored", [
                    "keyWin": "\(win.isKeyWindow)", "from": "ocr.close",
                ])
            }
        }
    }

    /// 贴图：把当前合成图钉在屏幕上
    private func pinCurrentImage() {
        guard let session = editorSession else { return }
        editorWindow()?.overlayView.flushPendingAnnotationForExport()
        let image = session.renderFinalImage()
        let rect = toolbarAnchorRectGlobal(for: session)
        AppCoordinatorShared.deps?.history.record(image, metadata: makeHistoryMetadata(for: session))
        AppCoordinatorShared.deps?.pinning.pin(image, atGlobalRect: rect)
        CaptureSoundPlayer.play()
        Log.event(.pin, "pin.wire", ["pxW": "\(image.width)", "pxH": "\(image.height)"])
        perform(action: .cancel)   // 贴图后结束截图会话（图像已经在屏幕上）
    }

    /// 工具栏可见性切换（快捷键 H 走这里）
    func toggleToolbarVisibility() {
        toolbarAction(.toggleVisibility)
    }

    // MARK: - 滚动截图（编辑态 S / 工具栏按钮入口；场景 06 规格）

    /// 编辑态进采集态：保留标注会话（Esc 取消要回标注态），工具栏退场，
    /// 覆盖层切滚动模式（区域 outline + 光晕脉动 + 采集 HUD）。
    /// 用户手动滚动下层内容（覆盖层 ignoresMouseEvents 穿透），控制器周期采样。
    func beginScrollCapture() {
        guard editorSession != nil,
              scrollController == nil,
              let rect = selectionRectGlobal,
              let screen = selectionScreen else {
            Log.error(.scroll, "scroll.enter.guard", [
                "hasSession": "\(editorSession != nil)",
                "noController": "\(scrollController == nil)",
                "hasRect": "\(selectionRectGlobal != nil)",
                "hasScreen": "\(selectionScreen != nil)",
            ])
            return
        }
        scrollSessionToken += 1
        scrollFrameInFlight = false
        scrollFrameQueue.removeAll()
        scrollPipeline = ScrollStitchPipeline()
        scrollAcceptedCount = 0
        scrollStitchedHeightPx = 0
        scrollViewportHeightPx = max(1, Int(rect.height * screen.backingScaleFactor))
        scrollSelectionRect = rect
        scrollInitialSelection = rect
        scrollScreen = screen
        scrollBottomDetected = false
        scrollWheelEverReceived = false
        scrollDownSign = -1
        scrollDownSignCalibrated = false
        lastScrollEventDeltaY = 0
        lastDownScrollTime = 0
        lastUpScrollTime = 0
        scrollDownEventsSinceGrowth = 0
        scrollUpEventsSinceGrowth = 0
        boundaryWallStaticFrames = 0
        boundaryWallStartTime = nil
        scrollInContainedRegion = false
        scrollEverScrolled = false

        // 编辑态 UI 退场（会话保留；motion.exit 替代 orderOut 直切）
        toolbar?.hideTooltip()
        toolbar?.dismiss()

        let controller = ScrollCaptureController()
        controller.onFrame = { [weak self] frame in self?.handleScrollFrame(frame) }
        controller.onStop = { count in
            Log.event(.scroll, "scroll.stop", ["frames": "\(count)"])
        }
        controller.onError = { [weak self] error in
            guard let self, self.scrollController != nil else { return }
            CaptureToast.show(message: "滚动截图采集中断：\(error.localizedDescription)", status: .warn)
            self.teardownScrollSession()
            self.scrollSelectionRect = nil
            self.scrollScreen = nil
            if let session = self.editorSession {
                self.toolbar?.place(below: self.toolbarAnchorRectGlobal(for: session))
                self.toolbar?.orderFrontRegardless()
            }
        }
        do {
            try controller.start(region: rect)
            scrollController = controller
            registerScrollHotKeys()
            installScrollWheelMonitor()
            // 编辑窗口切滚动模式（区域 outline + 光晕脉动；滚动事件穿透下层；采集框固定在真实视口 rect）
            for window in windows where window.owningScreen == screen {
                window.enterScrollMode()
            }
            // 采集 HUD 全程驻留（SCK 已按进程级排除 Snapcut 自身窗口，不会入镜）
            let hud = ScrollCaptureHUDPanel()
            hud.show(below: rect, on: screen)
            hud.update(state: .waiting)
            scrollHUD = hud
            Log.event(.scroll, "scroll.enter", ["rect": "\(Int(rect.width))x\(Int(rect.height))"])
        } catch {
            Log.error(.scroll, "scroll.begin.fail", ["err": error.localizedDescription])
            CaptureToast.show(message: "滚动截图启动失败：\(error.localizedDescription)", status: .warn)
            // reviewer 补丁 D：工具栏/焦点在 try 前已退场——不还原则编辑器
            // 只剩蒙层无 UI（残态僵死）。回滚：清滚动状态 + 恢复工具栏与焦点
            teardownScrollSession()
            scrollSelectionRect = nil
            scrollScreen = nil
            if let session = editorSession {
                toolbar?.place(below: session.selectionGlobal)
                toolbar?.orderFrontRegardless()
            }
        }
    }

    /// 采集态收尾热键：editorHotkeys["scroll"]（默认 s，可自定义/清空）+ Enter 兕底。
    /// ⚠️ 热键活到 compose 完/失败为止（unregister 挪到 enterEditorAfterScroll /
    /// teardownScrollSession）——compose 是 stop 之后的异步窗口期（卡 10s 病例），
    /// stop 时就撤会让用户在整个 compose 期按 Enter/Esc 全无反应。
    /// compose 期间（isScrollComposing）S/Enter/Esc 一律吞掉：Enter=手动收尾只在
    /// 采集态有效；此时 editorSession 还挂着旧底图，任何收尾/取消动作都会把
    /// 合成结果弄丢（病例：scroll.compose.begin 后 editor.hotkey done → noSession）。
    private func registerScrollHotKeys() {
        unregisterScrollHotKeys()
        let center = CarbonHotKeyCenter.shared
        let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
        let combo = settings.editorHotkey(for: "scroll")
        if !combo.isEmpty, let spec = HotkeySpec.parse(combo, allowBare: true) {
            scrollFinishHotKey = center.register(
                keyCode: Int(spec.keyCode), modifiers: EditorKeyRouter.nsEventFlags(spec.modifiers)
            ) { [weak self] in self?.finishHotKeyFired() }
        }
        scrollFinishReturnHotKey = center.register(
            keyCode: kVK_Return, modifiers: []
        ) { [weak self] in self?.finishHotKeyFired() }
    }

    /// 收尾热键公共入口：compose 期忽略，采集态手动收尾
    private func finishHotKeyFired() {
        if isScrollComposing {
            Log.event(.scroll, "scroll.composing.ignoreKey", ["key": "enter"])
            return
        }
        finishScrollCapture(mode: .manual)
    }

    // MARK: 采样帧处理：串行流式增量拼接 + 到底判定

    /// 采样帧串行入口：确保同一时刻仅有一帧进入拼接管线，同时用有界 FIFO 缓冲（上限 24 帧）
    /// 承接 60fps 高速甩屏突发帧，绝不随意覆盖中间重叠帧。
    private func handleScrollFrame(_ frame: CGImage) {
        guard scrollController != nil, let pipeline = scrollPipeline else {
            Log.event(.scroll, "scroll.frame.dropAfterStop")
            return
        }
        if scrollFrameInFlight {
            if scrollFrameQueue.count >= Self.maxBufferedScrollFrames {
                scrollFrameQueue.removeFirst()
            }
            scrollFrameQueue.append(frame)
            return
        }
        scrollFrameInFlight = true
        let token = scrollSessionToken
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await pipeline.push(frame)
            await MainActor.run {
                guard let self else { return }
                self.scrollFrameInFlight = false
                guard token == self.scrollSessionToken, self.scrollController != nil else {
                    self.scrollFrameQueue.removeAll()
                    return
                }
                self.applyScrollStepOutcome(outcome)
                if !self.scrollFrameQueue.isEmpty {
                    let next = self.scrollFrameQueue.removeFirst()
                    self.handleScrollFrame(next)
                }
            }
        }
    }

    private func currentHUDState() -> ScrollCaptureHUDPanel.State {
        guard scrollEverScrolled else { return .waiting }
        let screens = Double(scrollStitchedHeightPx) / Double(max(1, scrollViewportHeightPx))
        if scrollInContainedRegion {
            return .contained(screens: screens, heightPx: scrollStitchedHeightPx)
        }
        return .capturing(screens: screens, heightPx: scrollStitchedHeightPx)
    }

    private enum ScrollBoundaryEdge {
        case bottom
        case top
    }

    /// 双向边界撞墙检测：
    /// - 向下滑到底：位于画布最底缘 + 最近 0.65s 内有持续向下滚动输入；
    /// - 从下往上滑到顶：位于画布最顶缘（posY ≤ 16）+ 最近 0.65s 内有持续向上滚动输入；
    /// 中途停下来看屏无滚动输入时恒返 nil，绝不误触发自动结束。
    private func activeBoundaryWallEdge(_ outcome: ScrollStitchPipeline.StepOutcome) -> ScrollBoundaryEdge? {
        guard scrollEverScrolled else { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        let atBottomEdge = outcome.viewportPosition >= outcome.maxViewportPosition - 16
        if atBottomEdge && (now - lastDownScrollTime) <= 0.65 && scrollDownEventsSinceGrowth >= 2 {
            return .bottom
        }
        let atTopEdge = outcome.viewportPosition <= 16
        if atTopEdge && (now - lastUpScrollTime) <= 0.65 && scrollUpEventsSinceGrowth >= 2 {
            return .top
        }
        return nil
    }

    private func applyScrollStepOutcome(_ outcome: ScrollStitchPipeline.StepOutcome) {
        scrollAcceptedCount = outcome.frameCount
        scrollStitchedHeightPx = outcome.canvasHeight
        if outcome.viewportHeight > 0 {
            scrollViewportHeightPx = outcome.viewportHeight
        }
        scrollEverScrolled = outcome.hasScrolled

        switch outcome.status {
        case .firstFrame:
            boundaryWallStaticFrames = 0
            boundaryWallStartTime = nil
            scrollInContainedRegion = false
            Log.event(.scroll, "scroll.frame.n", [
                "n": "1", "pxH": "\(outcome.canvasHeight)", "prepMs": "\(outcome.prepMs)",
            ])
            scrollHUD?.update(state: .waiting)

        case .staticFrame:
            // 仅当用户在底缘继续下滚或顶缘继续上滚撞墙不增长时累计（60fps 下需帧数 ≥ 4 且持续 ≥ 0.32s，防误触）
            if let edge = activeBoundaryWallEdge(outcome) {
                let now = CFAbsoluteTimeGetCurrent()
                if boundaryWallStartTime == nil { boundaryWallStartTime = now }
                boundaryWallStaticFrames += 1
                if boundaryWallStaticFrames >= 4,
                   let start = boundaryWallStartTime,
                   (now - start) >= 0.32 {
                    detectScrollBottom(isTop: edge == .top)
                }
            } else {
                boundaryWallStaticFrames = 0
                boundaryWallStartTime = nil
            }

        case .skipped:
            boundaryWallStaticFrames = 0
            boundaryWallStartTime = nil
            var fields: [String: String] = [
                "afterN": "\(outcome.frameCount)",
                "prepMs": "\(outcome.prepMs)",
                "estMs": "\(outcome.estMs)",
            ]
            if let est = outcome.estimate {
                fields["dy"] = "\(est.dy)"
                fields["conf"] = String(format: "%.2f", est.confidence)
                fields["tex"] = "\(est.texturedTiles)"
                fields["mov"] = "\(est.movingTiles)"
                fields["err"] = String(format: "%.3f", est.preciseError)
            }
            Log.event(.scroll, "scroll.frame.skipNoOverlap", fields)
            scrollHUD?.update(state: .dropped)
            scrollDroppedHintWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.scrollController != nil else { return }
                self.scrollHUD?.update(state: self.currentHUDState())
            }
            scrollDroppedHintWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)

        case .appended(let growthRows, let totalHeight):
            // 首次向下扩展时自动校准向下滚轮方向符号（兼容自然滚动/反向滚动/第三方鼠标工具）
            if !scrollDownSignCalibrated && abs(lastScrollEventDeltaY) >= 0.5 {
                scrollDownSign = lastScrollEventDeltaY > 0 ? 1 : -1
                scrollDownSignCalibrated = true
                Log.event(.scroll, "scroll.wheel.calibrated", ["downSign": "\(Int(scrollDownSign))", "via": "down"])
            }
            scrollDownEventsSinceGrowth = 0
            scrollUpEventsSinceGrowth = 0
            boundaryWallStaticFrames = 0
            boundaryWallStartTime = nil
            scrollInContainedRegion = false
            revokeBottomIfNeeded()
            Log.event(.scroll, "scroll.frame.n", [
                "n": "\(outcome.frameCount)",
                "pxH": "\(totalHeight)",
                "growth": "\(growthRows)",
                "prepMs": "\(outcome.prepMs)",
                "estMs": "\(outcome.estMs)",
                "conf": String(format: "%.2f", outcome.estimate?.confidence ?? 0),
                "err": String(format: "%.3f", outcome.estimate?.preciseError ?? 0),
            ])
            scrollHUD?.update(state: currentHUDState())
            scrollHUD?.pulseOnGrowth()

        case .prepended(let growthRows, let totalHeight):
            // 首次向上扩展（从下往上滑）时自动校准向下符号 = 当前滚轮符号取反
            if !scrollDownSignCalibrated && abs(lastScrollEventDeltaY) >= 0.5 {
                scrollDownSign = lastScrollEventDeltaY > 0 ? -1 : 1
                scrollDownSignCalibrated = true
                Log.event(.scroll, "scroll.wheel.calibrated", ["downSign": "\(Int(scrollDownSign))", "via": "up"])
            }
            scrollDownEventsSinceGrowth = 0
            scrollUpEventsSinceGrowth = 0
            boundaryWallStaticFrames = 0
            boundaryWallStartTime = nil
            scrollInContainedRegion = false
            revokeBottomIfNeeded()
            Log.event(.scroll, "scroll.frame.n", [
                "n": "\(outcome.frameCount)",
                "pxH": "\(totalHeight)",
                "growth": "\(growthRows)",
                "dir": "up",
                "prepMs": "\(outcome.prepMs)",
                "estMs": "\(outcome.estMs)",
            ])
            scrollHUD?.update(state: currentHUDState())
            scrollHUD?.pulseOnGrowth()

        case .contained(let positionY, let totalHeight):
            // 若是在画布底缘继续下滚或顶缘继续上滚（例如 macOS 边界橡皮筋回弹），视作触底/触顶而非回滚
            if let edge = activeBoundaryWallEdge(outcome) {
                let now = CFAbsoluteTimeGetCurrent()
                if boundaryWallStartTime == nil { boundaryWallStartTime = now }
                boundaryWallStaticFrames += 1
                if boundaryWallStaticFrames >= 4,
                   let start = boundaryWallStartTime,
                   (now - start) >= 0.32 {
                    detectScrollBottom(isTop: edge == .top)
                }
                return
            }
            boundaryWallStaticFrames = 0
            boundaryWallStartTime = nil
            scrollInContainedRegion = true
            revokeBottomIfNeeded()
            Log.event(.scroll, "scroll.frame.contained", [
                "posY": "\(positionY)",
                "maxPosY": "\(outcome.maxViewportPosition)",
                "pxH": "\(totalHeight)",
                "prepMs": "\(outcome.prepMs)",
                "estMs": "\(outcome.estMs)",
            ])
            scrollHUD?.update(state: currentHUDState())
        }
    }

    private func revokeBottomIfNeeded() {
        if scrollBottomDetected {
            scrollBottomWork?.cancel()
            scrollBottomWork = nil
            for window in windows where window.owningScreen == scrollScreen {
                window.clearScrollBottomReached()
            }
            scrollHUD?.setCapturingState()
            Log.event(.scroll, "scroll.bottom.revoked", [:])
        }
        scrollBottomDetected = false
    }

    /// 到底/到顶：底缘 2pt 绿条 + HUD 切确认态 + 0.6s 后自动合成（无需用户动作）。
    private func detectScrollBottom(isTop: Bool = false) {
        guard !scrollBottomDetected else { return }
        guard scrollEverScrolled else {
            Log.event(.scroll, "scroll.bottom.skipNoScroll")
            return
        }
        scrollBottomDetected = true
        Log.event(.scroll, "scroll.bottom.detected", [
            "edge": isTop ? "top" : "bottom",
            "frames": "\(scrollAcceptedCount)",
            "pxH": "\(scrollStitchedHeightPx)",
        ])
        for window in windows where window.owningScreen == scrollScreen {
            window.setScrollBottomReached()
        }
        scrollHUD?.setBottomState(isTop: isTop)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.scrollBottomDetected else { return }
            self.finishScrollCapture(mode: .autoBottom)
        }
        scrollBottomWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DesignTokens.Scroll.bottomAutoComposeDelay, execute: work
        )
    }

    // MARK: 取消 / 收尾

    /// Esc：直接取消并关闭整个截图会话（不再退回普通框选/编辑面板，一步退出）
    private func cancelScrollCapture() {
        teardownScrollSession()
        scrollSelectionRect = nil
        scrollScreen = nil
        Log.event(.scroll, "scroll.cancel")
        perform(action: .cancel)
    }

    /// OverlayView Esc 驱动：采集态取消并关闭整个截图会话
    func cancelScrollForUser() {
        cancelScrollCapture()
    }

    private enum ScrollFinishMode {
        case manual        // 再按 S / Enter
        case autoBottom    // 到底 0.6s 自动
    }

    /// 收尾：停采样 → 增量管线毫秒级出图 → 按 afterCapture 单次导出完成
    private func finishScrollCapture(mode: ScrollFinishMode) {
        guard let controller = scrollController, let pipeline = scrollPipeline else { return }
        scrollBottomWork?.cancel()
        scrollBottomWork = nil
        scrollDroppedHintWork?.cancel()
        scrollDroppedHintWork = nil
        removeScrollWheelMonitor()
        scrollSessionToken += 1
        let trailingFrames = scrollFrameQueue
        scrollFrameQueue.removeAll()
        scrollFrameInFlight = false
        controller.stop()
        scrollController = nil
        scrollPipeline = nil
        scrollHUD?.hide()
        scrollHUD = nil

        let selection = scrollSelectionRect
        let screen = scrollScreen
        let recordedFrames = scrollAcceptedCount
        scrollBottomDetected = false
        let focal = scrollScreen
        for window in windows where focal == nil || window.owningScreen == focal {
            window.exitScrollMode()
        }

        guard let selection, let screen else {
            Log.error(.scroll, "scroll.compose.fail", ["err": "no session geometry"])
            cancelScrollCapture()
            return
        }
        Log.event(.scroll, "scroll.compose.begin", [
            "frames": "\(recordedFrames)", "mode": mode == .autoBottom ? "auto" : "manual",
        ])
        isScrollComposing = true
        scrollEscForceCount = 0
        let timeoutNs = UInt64(DesignTokens.Scroll.composeTimeout * 1_000_000_000)
        let composeStart = DispatchTime.now()
        let epoch = overlaySessionEpoch

        Task { @MainActor in
            enum ComposeOutcome {
                case done(Stitcher.Result)
                case timeout
                case failed(CGImage?)
            }
            let outcome: ComposeOutcome = await withTaskGroup(of: ComposeOutcome.self) { group in
                group.addTask {
                    await Task.detached(priority: .userInitiated) {
                        for frame in trailingFrames {
                            _ = await pipeline.push(frame)
                        }
                        guard await pipeline.hasContent() else {
                            return .failed(nil)
                        }
                        if let result = try? await pipeline.finish() {
                            return .done(result)
                        }
                        let fallback = await pipeline.fallbackFirstFrame()
                        return .failed(fallback)
                    }.value
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    return .timeout
                }
                let first = await group.next() ?? ComposeOutcome.timeout
                group.cancelAll()
                return first
            }
            let elapsedMs = Int(
                Double(DispatchTime.now().uptimeNanoseconds - composeStart.uptimeNanoseconds)
                    / 1_000_000
            )
            guard epoch == self.overlaySessionEpoch else {
                self.isScrollComposing = false
                Log.event(.scroll, "scroll.compose.stale", ["ms": "\(elapsedMs)"])
                return
            }
            switch outcome {
            case .done(let result):
                Log.event(.scroll, "scroll.compose.done", [
                    "pxW": "\(result.image.width)", "pxH": "\(result.image.height)",
                    "seams": "\(result.seams.count)", "ms": "\(elapsedMs)",
                ])
                self.finishScrollWithResult(image: result.image)
            case .timeout:
                Log.error(.scroll, "scroll.compose.fail", [
                    "err": "compose.timeout", "timeoutMs": "\(Int(DesignTokens.Scroll.composeTimeout * 1000))",
                    "ms": "\(elapsedMs)",
                ])
                if let fallback = await pipeline.fallbackFirstFrame() {
                    CaptureToast.show(message: "拼接超时，已回退为单帧", status: .warn)
                    self.enterEditorAfterScroll(
                        image: fallback, selection: self.scrollInitialSelection ?? selection, screen: screen)
                } else {
                    self.cancelScrollCapture()
                }
            case .failed(let fallback):
                Log.error(.scroll, "scroll.compose.fail", [
                    "err": "stitch.noFrames", "ms": "\(elapsedMs)",
                ])
                if let fallback {
                    CaptureToast.show(message: "滚动拼接未找到重叠内容，已回退为单帧", status: .warn)
                    self.enterEditorAfterScroll(
                        image: fallback, selection: self.scrollInitialSelection ?? selection, screen: screen)
                } else {
                    self.cancelScrollCapture()
                }
            }
        }
    }

    /// 滚动合成结果单次完成流（统一交由 completion / 单处收口，杜绝双次导出与双弹窗）
    private func finishScrollWithResult(image: CGImage) {
        isScrollComposing = false
        unregisterScrollHotKeys()
        scrollSelectionRect = nil
        scrollScreen = nil
        scrollInitialSelection = nil
        Log.event(.scroll, "scroll.compose.autoFinish", [
            "pxW": "\(image.width)", "pxH": "\(image.height)",
        ])
        AppCoordinatorShared.deps?.history.record(image)
        let settings = AppCoordinatorShared.coordinator?.settings ?? .defaultSettings
        let pinRect = sessionPinRect() ?? .zero
        let completion = self.completion
        end()
        self.completion = nil
        switch settings.afterCapture {
        case .copy:
            if let completion {
                completion(.copy(image))
            } else {
                AppCoordinatorShared.deps?.clipboard.writeImage(image)
                CaptureSoundPlayer.play()
                if settings.showCopyNotification {
                    CaptureToast.show(image: image, message: "长图已复制")
                }
            }
        case .save:
            if let completion {
                completion(.save(image))
            } else {
                AppCoordinatorShared.coordinator?.quickSaveScroll(image: image)
            }
        case .pin:
            AppCoordinatorShared.deps?.pinning.pin(image, atGlobalRect: pinRect)
            CaptureSoundPlayer.play()
            completion?(.cancelled)
        }
    }

    /// 滚动前编辑会话的选区（贴图落位用）
    private func sessionPinRect() -> CGRect? {
        editorSession?.selectionGlobal
    }

    private func enterEditorAfterScroll(image: CGImage, selection: CGRect, screen: NSScreen) {
        isScrollComposing = false
        // 收尾热键活到 compose 完/失败为止：现在会话已定型，撤掉
        unregisterScrollHotKeys()
        scrollSelectionRect = nil
        scrollScreen = nil
        scrollInitialSelection = nil
        guard let session = editorSession else {
            Log.error(.scroll, "scroll.compose.noSession")
            // 会话已被外部销毁（如拼接窗口期用户开了新截图会话）：拼接结果不能丢，
            // 落剪贴板兜底 + toast 告知
            let deps = AppCoordinatorShared.deps
            if deps?.clipboard.writeImage(image) == true {
                deps?.history.record(image)
                CaptureToast.show(message: "编辑会话已关闭，长图已复制到剪贴板", status: .warn)
            }
            return
        }
        session.applySelectionChange(
            newSelection: selection, newBase: image, annotationOffset: .zero
        )
        selectionRectGlobal = selection
        for window in windows where window.owningScreen == screen {
            window.enterEditorMode(session: session)   // 重算 editorRectLocal（生长后的画布）
        }
        toolbar?.place(below: toolbarAnchorRectGlobal(for: session))
        toolbar?.orderFrontRegardless()
        restoreEditorFocus(reason: "scroll.compose")
        Log.event(.editor, "editor.enter.fromScroll", [
            "pxW": "\(image.width)", "pxH": "\(image.height)",
        ])
    }

    /// 编辑器焦点夺回（ToolbarPanel orderFront 会偷 key 态；同 enterEditor 收尾）
    private func restoreEditorFocus(reason: String) {
        ensureActivation(reason: reason)
        guard let win = editorWindow() else { return }
        win.makeKeyAndOrderFront(nil)
        _ = win.makeFirstResponder(win.overlayView)
        toolbar?.orderFrontRegardless()
        Log.event(.editor, "editor.focus.restored", [
            "keyWin": "\(win.isKeyWindow)", "from": reason,
        ])
    }

    /// OverlayView 滚动 HUD 读取（选区全局矩形 / 已抓帧数）
    var scrollSelectionGlobal: CGRect? { scrollSelectionRect }
    var scrollFrameCount: Int { scrollAcceptedCount }

    /// 键盘 Enter / 自测驱动：结束滚动采集（合成长图进标注编辑器）
    func finishScrollForSelfTest() {
        finishScrollCapture(mode: .manual)
    }

    // MARK: - 编辑器内标注落库（OverlayView 手势回调）

    func addAnnotation(_ annotation: AnnotationModel) {
        guard let session = editorSession else { return }
        session.store.add(annotation)
        toolbar?.refreshSelectionState()
        editorWindow()?.overlayView.needsDisplay = true
    }

    func undoAnnotation() { toolbarAction(.undo) }
    func redoAnnotation() { toolbarAction(.redo) }

    /// 热键切工具后刷新工具栏选中态
    func refreshToolbar() {
        toolbar?.refreshSelectionState()
    }

    // MARK: - 导出

    func perform(action: Action) {
        switch action {
        case .cancel:
            Log.event(.overlay, "overlay.cancel")
            let completion = self.completion
            end()
            completion?(.cancelled)
            self.completion = nil
        case .copy, .save, .quickSave:
            guard let session = editorSession else {
                // 无编辑会话（还在拖选/确认阶段）：直接按选区导出
                guard let rect = selectionRectGlobal, let screen = selectionScreen else {
                    Log.error(.overlay, "overlay.action.noSelection")
                    let completion = self.completion
                    end()
                    completion?(.cancelled)
                    self.completion = nil
                    return
                }
                let completion = self.completion
                end()
                self.completion = nil
                Task {
                    do {
                        let image = try await CaptureService.captureRegion(rect, on: screen)
                        switch action {
                        case .copy: completion?(.copy(image))
                        case .save, .quickSave: completion?(.save(image))
                        case .cancel: break
                        }
                    } catch {
                        completion?(.cancelled)
                    }
                }
                return
            }
            // 编辑态：合成导出（编辑器所见 = 导出所得）
            // 病例收口（2026-11-15）：拖拽标注 + 立即导出的 mouseUp/keyDown
            // 竞态——渲染前 flush pending，三个导出点共用同一兜底
            editorWindow()?.overlayView.flushPendingAnnotationForExport()
            lastExportSnapshot = session.makeExportSnapshot(
                sourceApp: previousApp?.localizedName,
                windowTitle: nil
            )
            let start = DispatchTime.now()
            let finalImage = session.renderFinalImage()
            let elapsedMs = Int(
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            )
            Log.event(.editor, "editor.export", [
                "shapes": "\(session.store.annotations.count)",
                "ms": "\(elapsedMs)",
                "pxW": "\(finalImage.width)",
                "pxH": "\(finalImage.height)",
            ])
            AppCoordinatorShared.deps?.history.record(finalImage, metadata: makeHistoryMetadata(for: session))   // 任何导出都写历史
            if case .quickSave = action {
                AppCoordinatorShared.coordinator?.quickSave(image: finalImage)
                let completion = self.completion
                end()
                self.completion = nil
                completion?(.cancelled)
                return
            }
            let completion = self.completion
            end()
            self.completion = nil
            switch action {
            case .copy: completion?(.copy(finalImage))
            case .save: completion?(.save(finalImage))
            case .quickSave, .cancel: break
            }
        }
    }
}

/// v0.1 简化桥：OverlayView → AppCoordinator（避免循环持有）
@MainActor
enum AppCoordinatorShared {
    static weak var coordinator: AppCoordinator?
    /// C3⇄C2 拼贴合并挂点（协议见 Sources/UI/Collage/CollageMergeTarget.swift）：
    /// 合成根注入的依赖（端口集合）；只有 AppCoordinator 写，其余只读
    @MainActor static var deps: Dependencies?
    static func didEnterConfirm() {
        coordinator?.didEnterConfirm()
    }
}

// MARK: - 自测入口（真实管线，仅供 --selftest 驱动）

extension OverlayController {
    /// 模拟一次拖选完成（走与真实 mouseUp 相同的 didSelect 管线）
    func simulateSelection(rect: CGRect, on screen: NSScreen) {
        Log.event(.app, "selftest.simulateSelection")
        didSelect(rect: rect, on: screen)
    }

    func performForSelfTest(_ action: Action) {
        perform(action: action)
    }
}

/// 串行流式滚动拼接管线：actor 隔离保证任意时刻只处理一帧且严格保序。
private actor ScrollStitchPipeline {
    struct StepOutcome: Sendable {
        let status: Stitcher.PushStatus
        let frameCount: Int
        let canvasHeight: Int
        let viewportHeight: Int
        let viewportPosition: Int
        let maxViewportPosition: Int
        let frameHeight: Int
        let hasScrolled: Bool
        let prepMs: Int
        let estMs: Int
        let estimate: TileMotionEstimator.Estimate?
    }

    private let session = Stitcher.Session()

    func push(_ frame: CGImage) -> StepOutcome {
        let status = session.push(frame)
        return StepOutcome(
            status: status,
            frameCount: session.contributingFrameCount,
            canvasHeight: session.canvasHeight,
            viewportHeight: session.viewportHeight,
            viewportPosition: session.viewportPosition,
            maxViewportPosition: session.maxViewportPosition,
            frameHeight: frame.height,
            hasScrolled: session.hasScrolled,
            prepMs: session.lastPrepMs,
            estMs: session.lastEstMs,
            estimate: session.lastEstimate
        )
    }

    func finish() throws -> Stitcher.Result {
        try session.finish()
    }

    func hasContent() -> Bool {
        session.contributingFrameCount > 0
    }

    func fallbackFirstFrame() -> CGImage? {
        session.firstFrameImage
    }
}
