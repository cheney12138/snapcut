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

    /// 滚动截图会话（S 键触发；非空时覆盖层显示滚动 HUD）
    private(set) var scrollFrames: [CGImage] = []
    private var scrollController: ScrollCaptureController?
    private var scrollTimer: Timer?
    private var scrollSelectionRect: CGRect?
    private var scrollScreen: NSScreen?
    /// 滚动会话专用热键（Enter 完成 / Esc 取消）
    /// ⚠️ 滚动模式下覆盖层 ignoresMouseEvents=true，焦点会落到被滚动的 App，
    /// 普通 keyDown 收不到——必须用系统级 Carbon 热键收尾（e2e 实测病例）
    private var scrollFinishHotKey: UInt32?
    private var scrollCancelHotKey: UInt32?

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
        unregisterScrollHotKeys()
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollController?.stop()
        scrollController = nil
        restoreFocus()
    }

    private func unregisterScrollHotKeys() {
        let center = CarbonHotKeyCenter.shared
        center.unregister(scrollFinishHotKey)
        center.unregister(scrollCancelHotKey)
        scrollFinishHotKey = nil
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
        }
    }

    // MARK: - OCR / 贴图（端口驱动）

    /// 取字：识别当前合成图（含标注）→ 浮层展示
    private func runOCR() {
        guard let session = editorSession else { return }
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

    // MARK: - 滚动截图（S 键，手动滚动模式）

    /// 编辑态下按 S：进入滚动采集（丢弃冻结底图，覆盖层切滚动 HUD）
    func beginScrollCapture() {
        guard editorSession != nil,
              scrollController == nil,
              let rect = selectionRectGlobal,
              let screen = selectionScreen else {
            Log.error(.scroll, "scroll.begin.guard", [
                "hasSession": "\(editorSession != nil)",
                "noController": "\(scrollController == nil)",
                "hasRect": "\(selectionRectGlobal != nil)",
                "hasScreen": "\(selectionScreen != nil)",
            ])
            return
        }
        // 退出编辑态 UI
        toolbar?.orderOut(nil)
        toolbar = nil
        editorSession = nil
        scrollFrames = []
        scrollSelectionRect = rect
        scrollScreen = screen

        let controller = ScrollCaptureController()
        controller.onFrame = { [weak self] frame in
            guard let self else { return }
            self.scrollFrames.append(frame)
            Log.event(.scroll, "scroll.frame", ["n": "\(self.scrollFrames.count)"])
            self.editorWindow()?.contentView?.needsDisplay = true
        }
        controller.onStop = { [weak self] count in
            guard let self else { return }
            Log.event(.scroll, "scroll.stop", ["frames": "\(count)"])
        }
        do {
            try controller.start(region: rect)
            scrollController = controller
            // 系统级收尾热键（焦点在别的 App 也能收到）
            scrollFinishHotKey = CarbonHotKeyCenter.shared.register(
                keyCode: kVK_Return, modifiers: []
            ) { [weak self] in self?.finishScrollForSelfTest() }
            scrollCancelHotKey = CarbonHotKeyCenter.shared.register(
                keyCode: kVK_Escape, modifiers: []
            ) { [weak self] in self?.perform(action: .cancel) }
            Log.event(.scroll, "scroll.begin", ["rect": "\(Int(rect.width))x\(Int(rect.height))"])
            // 编辑窗口切滚动 HUD
            for window in windows where window.owningScreen == screen {
                window.enterScrollMode()
            }
            // 帧 HUD 计数刷新
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.editorWindow()?.contentView?.needsDisplay = true
                }
            }
        } catch {
            Log.error(.scroll, "scroll.begin.fail", ["err": error.localizedDescription])
        }
    }

    /// Enter：结束采集 → 拼接 → 预览面板
    private func finishScrollCapture() {
        guard let controller = scrollController else { return }
        scrollTimer?.invalidate()
        scrollTimer = nil
        controller.stop()
        scrollController = nil

        let frames = scrollFrames
        let selection = scrollSelectionRect
        scrollFrames = []

        let screen = scrollScreen
        for window in windows { window.exitScrollMode() }

        guard frames.count > 0 else {
            Log.error(.scroll, "scroll.stitch.fail", ["err": "no frames"])
            perform(action: .cancel)
            return
        }
        Log.event(.scroll, "scroll.stitch.begin", ["frames": "\(frames.count)"])
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Stitcher.stitch(frames: frames)
                }.value
                Log.event(.scroll, "scroll.stitch.ok", [
                    "pxW": "\(result.image.width)",
                    "pxH": "\(result.image.height)",
                    "seams": "\(result.seams.count)",
                ])
                let completion = self.completion
                let action = self.pendingScrollExport ?? .copy
                self.end()
                self.completion = nil
                switch action {
                case .save, .quickSave: completion?(.save(result.image))
                case .cancel: break
                case .copy: completion?(.copy(result.image))
                }
            } catch {
                // 拼接失败：静止画面（无可信重叠）时退化为输出首帧，
                // 其余失败明确回退（产品承诺：绝不卡死）
                Log.error(.scroll, "scroll.stitch.fail", ["err": error.localizedDescription])
                if frames.count >= 1 {
                    let completion = self.completion
                    let action = self.pendingScrollExport ?? .copy
                    self.end()
                    self.completion = nil
                    Log.event(.scroll, "scroll.fallback", ["mode": "firstFrame"])
                    switch action {
                    case .save, .quickSave: completion?(.save(frames[0]))
                    case .cancel: break
                    case .copy: completion?(.copy(frames[0]))
                    }
                } else {
                    self.perform(action: .cancel)
                }
            }
        }
    }

    /// 滚动 HUD 里的导出意图（Enter 后默认复制）
    private var pendingScrollExport: Action?

    /// OverlayView 滚动 HUD 读取（选区全局矩形 / 已抓帧数）
    var scrollSelectionGlobal: CGRect? { scrollSelectionRect }
    var scrollFrameCount: Int { scrollFrames.count }

    /// 键盘 Enter / 自测驱动：结束滚动采集
    func finishScrollForSelfTest() {
        pendingScrollExport = .copy
        finishScrollCapture()
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
