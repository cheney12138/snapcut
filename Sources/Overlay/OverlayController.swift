import AppKit
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

    // MARK: - 会话

    func begin(completion: @escaping (Result) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        editorSession = nil
        toolbar?.orderOut(nil)
        toolbar = nil
        dismissAll()
        let start = DispatchTime.now()
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, controller: self)
            window.orderFrontRegardless()
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
        restoreFocus()
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
        let session = EditorSession(
            baseImage: base,
            scale: screen.backingScaleFactor,
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
