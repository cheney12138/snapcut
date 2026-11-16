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
    private var completion: ((Result) -> Void)?
    private var selectionScreen: NSScreen?
    private var selectionRectGlobal: CGRect?
    /// 会话开始时的前台 App（结束时把激活权还给它）
    private var previousApp: NSRunningApplication?
    /// 前台 App 的 pid（Int 永不失效；NSRunningApplication 引用在 App 挂起/
    /// 转后台时 isTerminated 语义不可靠——用户病例 7 次 prevAlive=false vs
    /// 2 次 restored 实锤）。归还时按 pid 从 runningApplications 重查活引用。
    private var previousAppPID: Int?
    /// 编辑会话（编辑态非空）
    private(set) var editorSession: EditorSession?
    private var toolbar: ToolbarPanel?
    /// 冻结帧（每显示器一张，截图时刻的静态画面）
    ///
    /// 架构决策（照 Snow Shot 主流程，docs/research/01-capture.md）：
    /// **先冻结整屏 → 再在静态帧上选区/标注**。收益：
    /// ① 选区期间内容不跳动（视频/动画/光标）；② 覆盖层永不可能入图（拍完才显示窗口）；
    /// ③ 选区调整/重拍/放大镜/取色全部离线可做；④ 松手进编辑态变零延迟（本地裁剪）。
    private(set) var frozenImages: [CGDirectDisplayID: CGImage] = [:]

    /// 滚动截图会话（编辑态 S / 工具栏按钮触发；非空时覆盖层显示采集 HUD）
    private(set) var scrollFrames: [CGImage] = []
    private var scrollController: ScrollCaptureController?
    private var scrollSelectionRect: CGRect?
    private var scrollScreen: NSScreen?
    /// 采集 HUD（档 1 玻璃面板：呼吸点 + tabular 帧数 + 44×3 进度条）
    private var scrollHUD: ScrollCaptureHUDPanel?
    /// 到底判定：连续两次采样无新增内容（§9 场景 06）
    private var scrollNoProgressCount = 0
    private var scrollBottomDetected = false
    private var scrollBottomWork: DispatchWorkItem?
    /// 拼接进度（最新帧净贡献占比，驱动 HUD 进度条）
    private var scrollProgress: CGFloat = 0
    /// 参考帧缓冲 = 最后一帧入拼接序列的帧（静止判定 / 区域生长的重叠检测基准）。
    /// ⚠️ 必须与「上一交付帧」区分：慢滚/滚动中停顿的交付帧与上一帧近似但与参
    /// 考帧有净贡献——拿上一交付帧做基准会把慢滚全部误判静止丢帧（病例：用户
    /// 滚动 11s 只有 2 帧，交 delivered=3 计 frames=2）。仅在入列时更新。
    private var scrollRefBuffer: PixelBuffer?
    /// 「滚动过快」HUD 提示的回落 work（1.2s）
    private var scrollDroppedHintWork: DispatchWorkItem?
    /// 本次采集是否观测到过真实滚动（净贡献 > 0）：到底自动合成的前置条件——
    /// 从未滚动就静止 ≠ 到底（用户在读屏定位），不能自动合成
    private var scrollEverScrolled = false
    /// 进入滚动采集时的原选区（grow 之前）：拼接失败回退单帧时恢复它，
    /// 而不是保留 grow 后的选区（病例：grow 扩到全屏 → compose 失败 →
    /// enter.fromScroll pxH=2098 pxW=3840 全屏选区，另一屏也被框住）
    private var scrollInitialSelection: CGRect?
    /// 滚动会话专用热键（采集态焦点在别的 App，普通 keyDown 收不到——e2e 实测病例）
    /// ⚠️ 终止键 = settings.editorHotkeys["scroll"]（默认 s）+ Enter；取消 = Esc
    private var scrollFinishHotKey: UInt32?
    private var scrollFinishReturnHotKey: UInt32?
    private var scrollCancelHotKey: UInt32?
    /// 收尾拼接进行中（stop 之后 → 合成结果回填编辑器之前的异步窗口期）：
    /// 此期间编辑器键全部吞掉（OverlayView.keyDown 检查）——editorSession 还挂着
    /// 旧单帧底图，Enter→done / Esc→cancel 会把会话销毁，合成结果将无处回填
    /// （病例：scroll.compose.begin 后 editor.hotkey action=done →
    ///  scroll.compose.fail → scroll.compose.noSession，长图丢失）
    private(set) var isScrollComposing = false

    // MARK: - 会话

    func begin(completion: @escaping (Result) -> Void, onShown: (() -> Void)? = nil) {
        self.completion = completion
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
        toolbar?.orderOut(nil)
        toolbar = nil
        dismissAll()
        frozenImages.removeAll()
        // 激活 App：保证覆盖层可靠接收键盘（Enter/Esc）与点击拖拽
        // （点击激活竞争对未激活窗口不可靠；结束时 restoreFocus 归还）
        ensureActivation(reason: "overlay.begin")
        NSApp.activate(ignoringOtherApps: true)

        // 冻结优先：窗口先不上屏（此刻若有窗口会被自己拍进去），
        // 全屏拍完再盖上去。单屏实测 ~90ms，符合「触发到冻结 ≤500ms」。
        Task { [weak self] in
            guard let self else { return }
            let start = DispatchTime.now()
            var frames: [CGDirectDisplayID: CGImage] = [:]
            await withTaskGroup(of: (CGDirectDisplayID, CGImage?).self) { group in
                for screen in NSScreen.screens {
                    guard let displayID = DisplayRegistry.displayID(of: screen) else { continue }
                    group.addTask {
                        do {
                            let image = try await SCKCapture.shared.captureDisplay(displayID: displayID)
                            return (displayID, image)
                        } catch {
                            Log.error(.capture, "freeze.fail", [
                                "display": "\(displayID)", "err": "\(error)",
                            ])
                            return (displayID, nil)
                        }
                    }
                }
                for await (displayID, image) in group {
                    if let image { frames[displayID] = image }
                }
            }
            self.frozenImages = frames
            let freezeMs = Int(
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            )
            self.showOverlayWindows()
            let elapsedMs = Int(
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            )
            Log.event(.overlay, "overlay.open", [
                "screens": "\(NSScreen.screens.count)",
                "ms": "\(elapsedMs)",
                "freezeMs": "\(freezeMs)",
                "frozen": "\(frames.count)",
            ])
            onShown?()
        }
    }

    /// 上屏：每屏一窗，带冻结帧的窗直接把静态画面铺满（用户看到"屏幕定住"）
    private func showOverlayWindows() {
        // 光标屏先建先 key（病例 2026-11-16「面板出现在另一个屏幕」：双屏各
        // 一窗是设计，但 key 窗按建窗顺序随机落屏——键盘事件/工具栏跟随全跟
        // 错屏。光标在哪个屏，哪个屏的窗是 key）
        let cursorScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let ordered = NSScreen.screens.sorted { a, b in
            if a == cursorScreen { return false }
            if b == cursorScreen { return true }
            return false
        }
        for screen in ordered {
            let window = OverlayWindow(screen: screen, controller: self)
            if let displayID = DisplayRegistry.displayID(of: screen),
               let frozen = frozenImages[displayID] {
                window.installFrozenImage(frozen)
            }
            window.orderFrontRegardless()
            windows.append(window)
        }
        // 光标屏的窗收 key（一次 makeKey，其他窗不抢——流畅）。
        // 起拖兜底已挪到窗层 sendEvent（beginDragIfNeeded），无需上屏补位。
        if let key = windows.first(where: { $0.screen == cursorScreen }) {
            key.makeKey()
        }
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
        dismissAll()
        editorSession = nil
        toolbar?.orderOut(nil)
        toolbar = nil
        ocrCloseObserver.map { NotificationCenter.default.removeObserver($0) }
        ocrCloseObserver = nil
        teardownScrollSession()
        // 焦点归还延后 ~80ms（用户病例 2026-11-16：「Esc 不退出，反倒操作了
        // 我的 TUI，会话 abort 了」）：cancel 同步 yieldActivation 时，触发
        // cancel 的那次按键（keyUp/重投递）跨过焦点边界落进前一个 App——
        // TUI 把半截 Esc 当输入执行。延后让按键完整落在已关闭的 overlay 上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.restoreFocusRobust()
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

    /// 无条件拆滚动会话资源（热键/HUD/采样器）；不影响编辑会话
    private func teardownScrollSession() {
        isScrollComposing = false
        unregisterScrollHotKeys()
        scrollBottomWork?.cancel()
        scrollBottomWork = nil
        scrollController?.stop()
        scrollController = nil
        scrollHUD?.hide()
        scrollHUD = nil
        scrollFrames = []
        scrollRefBuffer = nil
        scrollDroppedHintWork?.cancel()
        scrollDroppedHintWork = nil
        scrollInitialSelection = nil
        scrollBottomDetected = false
        scrollNoProgressCount = 0
        scrollProgress = 0
        // 焦点屏语义：滚动态只可能挂在 scrollScreen 上，其余屏窗口不换态
        // （防御：scrollScreen 为空时仍全量清扫，保证会话结束无残留）
        let focal = scrollScreen
        for window in windows where focal == nil || window.owningScreen == focal {
            window.exitScrollMode()
        }
    }

    private func unregisterScrollHotKeys() {
        let center = CarbonHotKeyCenter.shared
        center.unregister(scrollFinishHotKey)
        center.unregister(scrollFinishReturnHotKey)
        center.unregister(scrollCancelHotKey)
        scrollFinishHotKey = nil
        scrollFinishReturnHotKey = nil
        scrollCancelHotKey = nil
    }

    private func dismissAll() {
        for window in windows {
            window.orderOut(nil)
            window.close()
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

    /// 选区变更：尺寸变了就按新选区从冻结帧重裁底图；纯移动只换全局坐标。
    /// 标注按 `annotationOffset` 平移，保证它们"钉在屏幕原位置"。
    func adjustSelection(to newGlobal: CGRect, on screen: NSScreen, annotationOffset: CGSize) {
        guard let session = editorSession else { return }
        let old = session.selectionGlobal
        let sizeUnchanged = abs(newGlobal.width - old.width) < 0.5
            && abs(newGlobal.height - old.height) < 0.5

        var base = session.baseImage
        if !sizeUnchanged {
            guard let cropped = cropFrozenImage(selection: newGlobal, screen: screen) else {
                Log.error(.overlay, "selection.adjust.noFrozen")
                return
            }
            base = cropped
        }
        session.applySelectionChange(
            newSelection: newGlobal, newBase: base, annotationOffset: annotationOffset
        )
        selectionRectGlobal = newGlobal
        // 编辑画布跟随新选区（视图侧自己算过一次，这里以 controller 为准再同步）
        editorWindow()?.contentView?.needsDisplay = true
        toolbar?.place(below: newGlobal)
    }

    // MARK: - 编辑态

    private func enterEditor(base: CGImage, selection: CGRect, screen: NSScreen) {
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

        // 工具栏
        let toolbar = ToolbarPanel()
        toolbar.updateScreen(screen)
        toolbar.configure(
            session: session,
            onToolChange: { [weak self] in self?.editorWindow()?.contentView?.needsDisplay = true },
            onAction: { [weak self] action in
                self?.toolbarAction(action)
            }
        )
        toolbar.place(below: selection)
        toolbar.orderFrontRegardless()
        self.toolbar = toolbar
        Log.event(.editor, "editor.enter", ["pxW": "\(base.width)", "pxH": "\(base.height)"])
        // 确保编辑画布是 first responder（键盘路由确定性）。
        // ⚠️ ToolbarPanel 创建/orderFront 会让窗口 key 状态失效（病例：editor.focus
        // makeKey=false 且注入键盘事件丢失），延后一个 runloop tick 再夺回 key。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorSession != nil,
                  let editorWindow = self.editorWindow(),
                  let editorView = editorWindow.contentView else { return }
            // 病例（e2e 实测）：ToolbarPanel 创建后 App key 状态丢失且 appActive=false，
            // 无激活态的窗口无法成为 key ⇒ Enter/Esc 键盘事件全部丢失。activate+makeKey 夺回。
            self.ensureActivation(reason: "editor.enter")
            editorWindow.makeKeyAndOrderFront(nil)
            _ = editorWindow.makeFirstResponder(editorView)
            // 覆盖层 makeKey 之后必须把工具栏重新提到最前（否则点不到按钮）
            self.toolbar?.orderFrontRegardless()
            let keyOK = editorWindow.isKeyWindow
            let active = NSApp.isActive
            Log.event(.editor, "editor.focus", [
                "keyWin": "\(keyOK)", "active": "\(active)",
            ])
        }
    }

    /// 激活保障（病例：⌘⇧S 全屏路径**没有真实鼠标点击**触发激活，
    /// `NSApp.activate` 在 Carbon 热键回调里可能被系统忽略 ⇒ frontmost 仍是
    /// Chrome ⇒ Enter/Esc 全送给了 Chrome，编辑器僵死。区域路径靠点击掩盖了这个 bug）
    func ensureActivation(reason: String, attempt: Int = 0) {
        guard NSApp.isActive == false else { return }
        NSApp.activate(ignoringOtherApps: true)
        if attempt == 0 {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        }
        guard attempt < 3 else {
            Log.error(.app, "activate.fail", ["reason": reason])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, !NSApp.isActive else { return }
            self.ensureActivation(reason: reason, attempt: attempt + 1)
        }
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
            editorWindow()?.contentView?.needsDisplay = true
            Log.event(.editor, "annotate.undo", [
                "canUndo": "\(session.store.canUndo)", "canRedo": "\(session.store.canRedo)",
            ])
        case .redo:
            session.store.redo()
            toolbar?.refreshSelectionState()
            editorWindow()?.contentView?.needsDisplay = true
            Log.event(.editor, "annotate.redo", [
                "canUndo": "\(session.store.canUndo)", "canRedo": "\(session.store.canRedo)",
            ])
        case .toggleVisibility:
            session.toolbarVisible.toggle()
            if session.toolbarVisible {
                toolbar?.orderFrontRegardless()
            } else {
                toolbar?.orderOut(nil)
                toolbar?.hideTooltip()
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
        }
    }

    // MARK: - OCR / 贴图（端口驱动）

    /// 取字：识别当前合成图（含标注）→ 浮层展示
    private func runOCR() {
        guard let session = editorSession else { return }
        (editorWindow()?.contentView as? OverlayView)?.flushPendingAnnotationForExport()
        let image = session.renderFinalImage()
        let rect = session.selectionGlobal
        let screen = session.screen
        let recognizer = AppCoordinatorShared.deps?.textRecognizer
        let clipboard = AppCoordinatorShared.deps?.clipboard
        let history = AppCoordinatorShared.deps?.history
        history?.record(image)
        Log.event(.ocr, "ocr.start", ["pxW": "\(image.width)", "pxH": "\(image.height)"])
        Task { @MainActor in
            guard let recognizer else { return }
            let text = (try? await recognizer.recognize(image)) ?? ""
            clipboard.map { _ in () }
            OCRResultPanel.present(text: text, nearGlobalRect: rect, on: screen)
            restoreEditorFocusAfterOCRPanelCloses()
            Log.event(.ocr, "ocr.present", ["chars": "\(text.count)"])
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
                if let contentView = win.contentView {
                    _ = win.makeFirstResponder(contentView)
                }
                Log.event(.editor, "editor.focus.restored", [
                    "keyWin": "\(win.isKeyWindow)", "from": "ocr.close",
                ])
            }
        }
    }

    /// 贴图：把当前合成图钉在屏幕上
    private func pinCurrentImage() {
        guard let session = editorSession else { return }
        (editorWindow()?.contentView as? OverlayView)?.flushPendingAnnotationForExport()
        let image = session.renderFinalImage()
        let rect = session.selectionGlobal
        AppCoordinatorShared.deps?.history.record(image)
        AppCoordinatorShared.deps?.pinning.pin(image, atGlobalRect: rect)
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
        scrollFrames = []
        scrollSelectionRect = rect
        scrollInitialSelection = rect
        scrollScreen = screen
        scrollNoProgressCount = 0
        scrollBottomDetected = false
        scrollProgress = 0
        scrollRefBuffer = nil
        scrollEverScrolled = false

        // 编辑态 UI 退场（会话保留）
        toolbar?.orderOut(nil)
        toolbar?.hideTooltip()

        let controller = ScrollCaptureController()
        controller.onFrame = { [weak self] frame in self?.handleScrollFrame(frame) }
        controller.onStop = { count in
            Log.event(.scroll, "scroll.stop", ["frames": "\(count)"])
        }
        do {
            try controller.start(region: rect)
            scrollController = controller
            registerScrollHotKeys()
            // 编辑窗口切滚动模式（区域 outline + 光晕脉动；滚动事件穿透下层）
            for window in windows where window.owningScreen == screen {
                window.enterScrollMode()
            }
            // 采集 HUD（档 1 钉暗，贴选区下缘 8pt）
            let hud = ScrollCaptureHUDPanel()
            hud.show(below: rect, on: screen)
            scrollHUD = hud
            Log.event(.scroll, "scroll.enter", ["rect": "\(Int(rect.width))x\(Int(rect.height))"])
        } catch {
            Log.error(.scroll, "scroll.begin.fail", ["err": error.localizedDescription])
            CaptureToast.show(message: "滚动截图启动失败：\(error.localizedDescription)", status: .warn)
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
        scrollCancelHotKey = center.register(
            keyCode: kVK_Escape, modifiers: []
        ) { [weak self] in
            guard let self else { return }
            if self.isScrollComposing {
                Log.event(.scroll, "scroll.composing.ignoreKey", ["key": "esc"])
                return
            }
            self.cancelScrollCapture()
        }
    }

    /// 收尾热键公共入口：compose 期忽略，采集态手动收尾
    private func finishHotKeyFired() {
        if isScrollComposing {
            Log.event(.scroll, "scroll.composing.ignoreKey", ["key": "enter"])
            return
        }
        finishScrollCapture(mode: .manual)
    }

    // MARK: 采样帧处理：净贡献帧序列 + 到底判定

    /// 采样帧入列。拼接序列只收「净贡献帧」：
    /// ① 首帧直接入列；② 与参考帧（上一入列帧）近似 ⇒ 静止，不入列只累计到底判定；
    /// ③ 与参考帧能找到可信重叠（findOverlap 成功）⇒ 入列 + 区域生长；
    /// ④ 找不到可信重叠（跳屏/内容突变）⇒ 不入列——否则 compose 必败
    ///   （病例：1 静止帧 + 1 滚动新帧凑成 2 帧序列，中间内容全丢 ⇒ stitch.noOverlap）。
    /// 慢滚不再被 0.98 阈值误杀：判静止阈值降到 0.95，且基准是参考帧而不是上一
    /// 交付帧，滚动中停顿/慢滚的净贡献帧正常计入（HUD 帧数该涨）。
    private func handleScrollFrame(_ frame: CGImage) {
        // stop 之后在途帧不入列（拼接序列已定格；且 scrollFrames/refBuffer 已清空，
        // 此时入列会被当成下个会话的首帧污染状态）
        guard scrollController != nil else {
            Log.event(.scroll, "scroll.frame.dropAfterStop")
            return
        }
        let buffer = PixelBuffer(cgImage: frame)
        guard let ref = scrollRefBuffer else {
            scrollRefBuffer = buffer
            scrollFrames.append(frame)
            Log.event(.scroll, "scroll.frame.n", ["n": "1"])
            scrollHUD?.update(frames: scrollFrames.count, progress: 0)
            return
        }
        if Self.framesNearIdentical(ref, buffer) {
            // 静止帧（没滚动 / 已到底）：不入拼接序列。
            // ⚠️ 完全相同的帧会让 Stitcher.findOverlap 无解（它要求 cur 至少
            // 净贡献 1 行 ⇒ 排除 d=0 的真实对齐）⇒ stitch.noOverlap ——
            // 静止 ≠ 失败：丢弃重复帧继续采，只累计到底判定（病例：用户
            // 进采集态后先读了 0.8s 屏，帧 2/3 与帧 1 全同 ⇒ 拼接直接炸）。
            scrollNoProgressCount += 1
            scrollProgress = 0
            scrollHUD?.update(frames: scrollFrames.count, progress: scrollProgress)
            if scrollNoProgressCount >= DesignTokens.Scroll.bottomConfirmSamples {
                detectScrollBottom()
            }
            return
        }
        // 与参考帧找可信重叠：成功才入列（净贡献帧序列，stitch 的相邻对全部预验证）
        let overlap: Int
        do {
            overlap = try Stitcher.findOverlap(
                prev: ref, cur: buffer, options: Stitcher.Options(), frameIndex: scrollFrames.count
            ).overlap
        } catch {
            // 跳屏（0.4s 内滚超过一帧）/ 内容突变：与参考帧无重叠，本帧不可拼接，
            // 丢弃不计数（不算静止，不推进到底判定）
            Log.event(.scroll, "scroll.frame.skipNoOverlap", [
                "afterN": "\(scrollFrames.count)", "err": "\(error.localizedDescription)",
            ])
            scrollProgress = 0
            // 「滚动过快」提示（用户病例：快滚一屏 > 采样间隔 → 帧丢 HUD 恒 1）。
            // 提示 1.2s 后回落正常帧数文案
            scrollHUD?.update(frames: scrollFrames.count, progress: scrollProgress, droppedHint: true)
            scrollDroppedHintWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scrollHUD?.update(frames: self.scrollFrames.count, progress: self.scrollProgress)
            }
            scrollDroppedHintWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
            return
        }
        scrollNoProgressCount = 0
        scrollBottomDetected = false
        growRegionIfPossible(ref: ref, cur: buffer, frame: frame, overlap: overlap)
        scrollRefBuffer = buffer
        scrollFrames.append(frame)
        Log.event(.scroll, "scroll.frame.n", ["n": "\(scrollFrames.count)"])
        scrollHUD?.update(frames: scrollFrames.count, progress: scrollProgress)
    }

    /// 两帧是否几乎一致（抽 60 行签名比对，≥95% 行匹配 = 没滚动）。
    /// 0.98 病例：慢速滚动 / 滚动中停顿被误判静止 ⇒ 11s 采样只入列 2 帧
    /// （用户实测 2026-11-17 日志：sampler.stop delivered=3 vs frames=2），
    /// 降到 0.95 让真实新帧计入。
    private static let nearIdenticalRowRatio: CGFloat = 0.95

    private static func framesNearIdentical(_ a: PixelBuffer, _ b: PixelBuffer) -> Bool {
        guard a.height == b.height, a.width == b.width else { return false }
        let threshold = Stitcher.Options().rowDiffThreshold
        let stride = max(1, a.height / 60)
        var total = 0
        var matched = 0
        var row = 0
        while row < a.height {
            total += 1
            if PixelBuffer.rowMatches(a.signature[row], b.signature[row], threshold: threshold) {
                matched += 1
            }
            row += stride
        }
        return total > 0 && CGFloat(matched) / CGFloat(total) >= nearIdenticalRowRatio
    }

    /// 区域生长：用预计算的重叠行数 → 净贡献行数（px）→ pt，选区向下扩展；
    /// 同时更新覆盖层画布矩形与 HUD 位置。
    /// 焦点屏语义：grow 只允许在 selectionScreen 内（clamp 到 screen.frame），
    /// 绝不跨屏把相邻显示器算进选区。
    private func growRegionIfPossible(
        ref: PixelBuffer, cur: PixelBuffer, frame: CGImage, overlap: Int
    ) {
        guard let screen = scrollScreen, let rect = scrollSelectionRect else { return }
        let contributedPx = cur.height - overlap
        scrollProgress = CGFloat(contributedPx) / CGFloat(max(1, cur.height))
        guard contributedPx > 0 else { return }
        scrollEverScrolled = true
        // px → pt：实测比例（帧宽 px / 选区宽 pt），不信任 backingScale
        let scale = CGFloat(frame.width) / max(1, rect.width)
        let growPt = CGFloat(contributedPx) / max(scale, 0.001)
        var newRect = rect
        // 采集区域不能长出屏幕（SCK 裁剪会越界）；到屏底后交给到底判定；
        // x/宽 clamp 保证永不越出焦点屏（双屏病例：另一屏 1920 被算进选区宽）
        let bounds = screen.frame
        newRect.size.height = min(rect.height + growPt, bounds.maxY - rect.minY)
        newRect.origin.x = max(bounds.minX, min(newRect.origin.x, bounds.maxX - newRect.width))
        if abs(newRect.height - rect.height) >= 0.5 {
            scrollSelectionRect = newRect
            for window in windows where window.owningScreen == screen {
                window.updateScrollRegion(newRect)
            }
            scrollHUD?.reposition(below: newRect, on: screen)
            Log.event(.scroll, "scroll.region.grow", [
                "ptH": "\(Int(newRect.height))",
                "screen": "\(Int(bounds.width))x\(Int(bounds.height))@\(Int(bounds.minX)),\(Int(bounds.minY))",
            ])
        }
    }

    /// 到底：底缘 2pt 绿条 + HUD 切确认态 + 0.6s 后自动合成（无需用户动作）。
    /// 前置：本次采集观测到过真实滚动——从未滚动的静止只是用户在读屏定位，
    /// 不是到底（病例：静止 0.8s 就自动合成单帧收场）。
    private func detectScrollBottom() {
        guard !scrollBottomDetected else { return }
        guard scrollEverScrolled else {
            Log.event(.scroll, "scroll.bottom.skipNoScroll")
            return
        }
        scrollBottomDetected = true
        Log.event(.scroll, "scroll.bottom.detected", ["frames": "\(scrollFrames.count)"])
        for window in windows where window.owningScreen == scrollScreen {
            window.setScrollBottomReached()
        }
        scrollHUD?.setBottomState()
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

    /// Esc：已采集帧丢弃，回标注态（标注会话从未销毁）
    private func cancelScrollCapture() {
        teardownScrollSession()
        scrollSelectionRect = nil
        scrollScreen = nil
        if let session = editorSession {
            toolbar?.place(below: session.selectionGlobal)
            toolbar?.orderFrontRegardless()
        }
        restoreEditorFocus(reason: "scroll.cancel")
        Log.event(.scroll, "scroll.cancel")
    }

    /// OverlayView Esc 驱动：采集态取消（丢已采帧回标注态，编辑会话不动）。
    /// ⚠️ 不能走 perform(.cancel)——那会拆掉整个 overlay 会话（含编辑会话），
    /// 与设计语义「Esc 取消回标注态」相悖。
    func cancelScrollForUser() {
        cancelScrollCapture()
    }

    private enum ScrollFinishMode {
        case manual        // 再按 S / Enter
        case autoBottom    // 到底 0.6s 自动
    }

    /// 收尾：停采样 → 后台拼接（≤ composeTimeout，超时回退单帧）→ 合成长图进
    /// 标注编辑器（与普通截图同一条流：Enter/⌘S/工具 1–6/撤销栈含长图整体）。
    /// ⚠️ 收尾热键在 compose 期不撤（活到 enterEditorAfterScroll / teardown），
    /// 但回调里吞掉——用户在整个 compose 期按键不能无反应也不能破坏会话。
    private func finishScrollCapture(mode: ScrollFinishMode) {
        guard let controller = scrollController else { return }
        scrollBottomWork?.cancel()
        scrollBottomWork = nil
        controller.stop()
        scrollController = nil
        scrollHUD?.hide()
        scrollHUD = nil

        let frames = scrollFrames
        let selection = scrollSelectionRect
        let screen = scrollScreen
        scrollFrames = []
        scrollRefBuffer = nil
        scrollBottomDetected = false
        // 焦点屏语义：只退焦点屏窗口的滚动态（其余屏从未进入）
        let focal = scrollScreen
        for window in windows where focal == nil || window.owningScreen == focal {
            window.exitScrollMode()
        }

        guard frames.count > 0, let selection, let screen else {
            Log.error(.scroll, "scroll.compose.fail", ["err": "no frames"])
            cancelScrollCapture()
            return
        }
        Log.event(.scroll, "scroll.compose.begin", [
            "frames": "\(frames.count)", "mode": mode == .autoBottom ? "auto" : "manual",
        ])
        // 拼接窗口期：编辑器键全吞（OverlayView.keyDown 检查 isScrollComposing），
        // 防 Enter→done / Esc→cancel 在回填前销毁 editorSession；收尾热键同样吞
        isScrollComposing = true
        let timeoutNs = UInt64(DesignTokens.Scroll.composeTimeout * 1_000_000_000)
        let composeStart = DispatchTime.now()
        Task { @MainActor in
            enum ComposeOutcome {
                case done(Stitcher.Result)
                case timeout
                case failed
            }
            let outcome: ComposeOutcome = await withTaskGroup(of: ComposeOutcome.self) { group in
                group.addTask {
                    if let result = try? Stitcher.stitch(frames: frames) {
                        return .done(result)
                    }
                    return .failed
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
            switch outcome {
            case .done(let result):
                Log.event(.scroll, "scroll.compose.done", [
                    "pxW": "\(result.image.width)", "pxH": "\(result.image.height)",
                    "seams": "\(result.seams.count)", "ms": "\(elapsedMs)",
                ])
                self.enterEditorAfterScroll(image: result.image, selection: selection, screen: screen)
            case .timeout:
                // 卡死保险丝：拼帧超时（病例：10s 无反馈）⇒ 回退单帧，不让用户干等
                Log.error(.scroll, "scroll.compose.fail", [
                    "err": "compose.timeout", "timeoutMs": "\(Int(DesignTokens.Scroll.composeTimeout * 1000))",
                    "ms": "\(elapsedMs)",
                ])
                CaptureToast.show(message: "拼接超时，已回退为单帧", status: .warn)
                self.enterEditorAfterScroll(
                    image: frames[0], selection: self.scrollInitialSelection ?? selection, screen: screen)
            case .failed:
                // 拼接失败（静止画面/无可信重叠）：明确回退单帧进编辑器 + toast 告知。
                // ⚠️ 恢复 grow 前的原选区（scrollInitialSelection）——回退图 frames[0]
                // 就是以原选区尺寸抓的，保留 grown 选区会出现底图/选区尺寸错位，
                // 且用户看到选区被扩成全屏（另一屏也被框住）的假象。
                Log.error(.scroll, "scroll.compose.fail", [
                    "err": "stitch.noOverlap", "ms": "\(elapsedMs)",
                ])
                CaptureToast.show(message: "滚动拼接未找到重叠内容，已回退为单帧", status: .warn)
                self.enterEditorAfterScroll(
                    image: frames[0], selection: self.scrollInitialSelection ?? selection, screen: screen)
            }
        }
    }

    /// 合成长图回填标注会话：底图替换、选区随内容生长、画布矩形重算、
    /// 工具栏贴新选区下缘并夺回键盘焦点
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
        toolbar?.place(below: selection)
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
        if let contentView = win.contentView {
            _ = win.makeFirstResponder(contentView)
        }
        toolbar?.orderFrontRegardless()
        Log.event(.editor, "editor.focus.restored", [
            "keyWin": "\(win.isKeyWindow)", "from": reason,
        ])
    }

    /// OverlayView 滚动 HUD 读取（选区全局矩形 / 已抓帧数）
    var scrollSelectionGlobal: CGRect? { scrollSelectionRect }
    var scrollFrameCount: Int { scrollFrames.count }

    /// 键盘 Enter / 自测驱动：结束滚动采集（合成长图进标注编辑器）
    func finishScrollForSelfTest() {
        finishScrollCapture(mode: .manual)
    }

    // MARK: - 编辑器内标注落库（OverlayView 手势回调）

    func addAnnotation(_ annotation: AnnotationModel) {
        guard let session = editorSession else { return }
        session.store.add(annotation)
        toolbar?.refreshSelectionState()
        editorWindow()?.contentView?.needsDisplay = true
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
            (editorWindow()?.contentView as? OverlayView)?.flushPendingAnnotationForExport()
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
            AppCoordinatorShared.deps?.history.record(finalImage)   // 任何导出都写历史
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
