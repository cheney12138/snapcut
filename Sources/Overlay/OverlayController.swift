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

    func begin(completion: @escaping (Result) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        editorSession = nil
        toolbar?.orderOut(nil)
        toolbar = nil
        dismissAll()
        let start = DispatchTime.now()
        // 激活 App：保证覆盖层可靠接收键盘（Enter/Esc）与点击拖拽
        // （点击激活竞争对未激活窗口不可靠；结束时 restoreFocus 归还）
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, controller: self)
            window.orderFrontRegardless()
            window.makeKey()
            windows.append(window)
        }
        let elapsedMs = Int(
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        )
        Log.event(.overlay, "overlay.open", [
            "screens": "\(NSScreen.screens.count)",
            "ms": "\(elapsedMs)",
        ])
    }

    func end() {
        dismissAll()
        editorSession = nil
        toolbar?.orderOut(nil)
        toolbar = nil
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
    func didSelect(rect: CGRect, on screen: NSScreen) {
        selectionScreen = screen
        selectionRectGlobal = rect
        let px = CoordinateConverter.pixelRect(selection: rect, onScreen: screen)
        Log.event(.overlay, "overlay.commit", [
            "rectPt": "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
            "rectPx": "\(Int(px.minX)),\(Int(px.minY)),\(Int(px.width)),\(Int(px.height))",
            "displayId": "\(DisplayRegistry.displayID(of: screen).map(String.init) ?? "?")",
        ])
        AppCoordinatorShared.didEnterConfirm()

        // ⚡ 底图冻结：此刻工具栏还没出现 —— 编辑 UI 永不入图的关键
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
            NSApp.activate(ignoringOtherApps: true)
            editorWindow.makeKeyAndOrderFront(nil)
            _ = editorWindow.makeFirstResponder(editorView)
        }
    }

    private func editorWindow() -> OverlayWindow? {
        guard let screen = selectionScreen else { return nil }
        return windows.first { $0.owningScreen == screen }
    }

    private func toolbarAction(_ action: ToolbarPanel.Action) {
        guard let session = editorSession else { return }
        switch action {
        case .undo:
            session.store.undo()
            toolbar?.refreshSelectionState()
            editorWindow()?.contentView?.needsDisplay = true
        case .redo:
            session.store.redo()
            toolbar?.refreshSelectionState()
            editorWindow()?.contentView?.needsDisplay = true
        case .toggleVisibility:
            session.toolbarVisible.toggle()
            if session.toolbarVisible {
                toolbar?.orderFrontRegardless()
            } else {
                toolbar?.orderOut(nil)
            }
            Log.event(.editor, "editor.toolbar.\(session.toolbarVisible ? "show" : "hide")")
        case .done:
            perform(action: .copy)
        case .save:
            perform(action: .save)
        case .cancel:
            perform(action: .cancel)
        }
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
                case .save: completion?(.save(result.image))
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
                    case .save: completion?(.save(frames[0]))
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
        case .copy, .save:
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
                        case .save: completion?(.save(image))
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
            let completion = self.completion
            end()
            self.completion = nil
            switch action {
            case .copy: completion?(.copy(finalImage))
            case .save: completion?(.save(finalImage))
            case .cancel: break
            }
        }
    }
}

/// v0.1 简化桥：OverlayView → AppCoordinator（避免循环持有）
@MainActor
enum AppCoordinatorShared {
    static weak var coordinator: AppCoordinator?
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
