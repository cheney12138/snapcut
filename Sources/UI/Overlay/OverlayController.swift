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
    /// 前一帧行签名缓存（到底判定 / 区域生长的重叠检测用）
    private var scrollPrevBuffer: PixelBuffer?
    /// 本次采集是否观测到过真实滚动（净贡献 > 0）：到底自动合成的前置条件——
    /// 从未滚动就静止 ≠ 到底（用户在读屏定位），不能自动合成
    private var scrollEverScrolled = false
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
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, controller: self)
            if let displayID = DisplayRegistry.displayID(of: screen),
               let frozen = frozenImages[displayID] {
                window.installFrozenImage(frozen)
            }
            window.orderFrontRegardless()
            window.makeKey()
            windows.append(window)
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
        restoreFocus()
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
        scrollPrevBuffer = nil
        scrollBottomDetected = false
        scrollNoProgressCount = 0
        scrollProgress = 0
        for window in windows { window.exitScrollMode() }
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
        scrollScreen = screen
        scrollNoProgressCount = 0
        scrollBottomDetected = false
        scrollProgress = 0
        scrollPrevBuffer = nil
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

    /// 采集态收尾热键：editorHotkeys["scroll"]（默认 s，可自定义/清空）+ Enter 兕底
    private func registerScrollHotKeys() {
        unregisterScrollHotKeys()
        let center = CarbonHotKeyCenter.shared
        let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
        let combo = settings.editorHotkey(for: "scroll")
        if !combo.isEmpty, let spec = HotkeySpec.parse(combo, allowBare: true) {
            scrollFinishHotKey = center.register(
                keyCode: Int(spec.keyCode), modifiers: EditorKeyRouter.nsEventFlags(spec.modifiers)
            ) { [weak self] in self?.finishScrollCapture(mode: .manual) }
        }
        scrollFinishReturnHotKey = center.register(
            keyCode: kVK_Return, modifiers: []
        ) { [weak self] in self?.finishScrollCapture(mode: .manual) }
        scrollCancelHotKey = center.register(
            keyCode: kVK_Escape, modifiers: []
        ) { [weak self] in self?.cancelScrollCapture() }
    }

    // MARK: 采样帧处理：区域生长 + 到底判定

    private func handleScrollFrame(_ frame: CGImage) {
        let buffer = PixelBuffer(cgImage: frame)
        defer { scrollPrevBuffer = buffer }

        if let prev = scrollPrevBuffer {
            if Self.framesNearIdentical(prev, buffer) {
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
            scrollNoProgressCount = 0
            scrollBottomDetected = false
            growRegionIfPossible(prev: prev, cur: buffer, frame: frame)
        }
        scrollFrames.append(frame)
        Log.event(.scroll, "scroll.frame.n", ["n": "\(scrollFrames.count)"])
        scrollHUD?.update(frames: scrollFrames.count, progress: scrollProgress)
    }

    /// 两帧是否几乎一致（抽 60 行签名比对，≥98% 行匹配 = 没滚动）
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
        return total > 0 && CGFloat(matched) / CGFloat(total) >= 0.98
    }

    /// 区域生长：与上一帧找可信重叠 → 净贡献行数（px）→ pt，选区向下扩展；
    /// 同时更新覆盖层画布矩形与 HUD 位置。找不到可信重叠的本帧不生长。
    private func growRegionIfPossible(prev: PixelBuffer, cur: PixelBuffer, frame: CGImage) {
        guard let screen = scrollScreen, let rect = scrollSelectionRect else { return }
        let overlap: Int
        do {
            overlap = try Stitcher.findOverlap(
                prev: prev, cur: cur, options: Stitcher.Options(), frameIndex: scrollFrames.count
            ).overlap
        } catch {
            scrollProgress = 0
            return
        }
        let contributedPx = cur.height - overlap
        scrollProgress = CGFloat(contributedPx) / CGFloat(max(1, cur.height))
        guard contributedPx > 0 else { return }
        scrollEverScrolled = true
        // px → pt：实测比例（帧宽 px / 选区宽 pt），不信任 backingScale
        let scale = CGFloat(frame.width) / max(1, rect.width)
        let growPt = CGFloat(contributedPx) / max(scale, 0.001)
        var newRect = rect
        // 采集区域不能长出屏幕（SCK 裁剪会越界）；到屏底后交给到底判定
        newRect.size.height = min(rect.height + growPt, screen.frame.maxY - rect.minY)
        if abs(newRect.height - rect.height) >= 0.5 {
            scrollSelectionRect = newRect
            for window in windows where window.owningScreen == screen {
                window.updateScrollRegion(newRect)
            }
            scrollHUD?.reposition(below: newRect, on: screen)
            Log.event(.scroll, "scroll.region.grow", ["ptH": "\(Int(newRect.height))"])
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

    /// 收尾：停采样 → 后台拼接 → 合成长图进标注编辑器（与普通截图同一条流：
    /// Enter/⌘S/工具 1–6/撤销栈含长图整体）
    private func finishScrollCapture(mode: ScrollFinishMode) {
        guard let controller = scrollController else { return }
        scrollBottomWork?.cancel()
        scrollBottomWork = nil
        controller.stop()
        scrollController = nil
        unregisterScrollHotKeys()
        scrollHUD?.hide()
        scrollHUD = nil

        let frames = scrollFrames
        let selection = scrollSelectionRect
        let screen = scrollScreen
        scrollFrames = []
        scrollPrevBuffer = nil
        scrollBottomDetected = false
        for window in windows { window.exitScrollMode() }

        guard frames.count > 0, let selection, let screen else {
            Log.error(.scroll, "scroll.compose.fail", ["err": "no frames"])
            cancelScrollCapture()
            return
        }
        Log.event(.scroll, "scroll.compose.begin", [
            "frames": "\(frames.count)", "mode": mode == .autoBottom ? "auto" : "manual",
        ])
        // 拼接窗口期：编辑器键全吞（OverlayView.keyDown 检查 isScrollComposing），
        // 防 Enter→done / Esc→cancel 在回填前销毁 editorSession
        isScrollComposing = true
        Task { @MainActor in
            let result = try? await Task.detached(priority: .userInitiated) {
                try Stitcher.stitch(frames: frames)
            }.value
            if let result {
                Log.event(.scroll, "scroll.compose.done", [
                    "pxW": "\(result.image.width)", "pxH": "\(result.image.height)",
                    "seams": "\(result.seams.count)",
                ])
                self.enterEditorAfterScroll(image: result.image, selection: selection, screen: screen)
            } else {
                // 拼接失败（静止画面/无可信重叠）：明确回退单帧进编辑器 + toast 告知
                Log.error(.scroll, "scroll.compose.fail", ["err": "stitch.noOverlap"])
                CaptureToast.show(message: "滚动拼接未找到重叠内容，已回退为单帧", status: .warn)
                self.enterEditorAfterScroll(image: frames[0], selection: selection, screen: screen)
            }
        }
    }

    /// 合成长图回填标注会话：底图替换、选区随内容生长、画布矩形重算、
    /// 工具栏贴新选区下缘并夺回键盘焦点
    private func enterEditorAfterScroll(image: CGImage, selection: CGRect, screen: NSScreen) {
        isScrollComposing = false
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
