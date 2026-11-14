import AppKit
import CoreGraphics

/// 覆盖层控制器：每屏一个全屏窗口，管理选区会话（docs/03 §3 Overlay 行）
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
    /// 会话开始时的前台 App（结束时把激活权还给它 —— 否则无窗口的激活态会吞掉
    /// 全局键盘事件，用户实报：截图完别的按键都没反应）
    private var previousApp: NSRunningApplication?

    /// 开始一次选区会话
    func begin(completion: @escaping (Result) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        dismissAll()
        let start = DispatchTime.now()
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, controller: self)
            window.orderFrontRegardless()
            windows.append(window)
        }
        // 选区发生所在窗口会成为 key window（OverlayView mouseDown 时申请）
        let elapsedMs = Int(
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        )
        Log.event(.overlay, "overlay.open", [
            "screens": "\(NSScreen.screens.count)",
            "ms": "\(elapsedMs)",
        ])
    }

    /// 结束会话（清窗口 + 把键盘焦点还给原 App）
    func end() {
        dismissAll()
        restoreFocus()
    }

    /// 焦点归还：accessory App 若保持激活却无任何窗口，系统键盘事件会被它吞掉
    private func restoreFocus() {
        guard NSApp.isActive else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let prev = previousApp, !prev.isTerminated,
           prev.processIdentifier != NSRunningApplication.current.processIdentifier {
            NSApp.yieldActivation(to: prev)
            Log.event(.app, "focus.restored", ["to": prev.bundleIdentifier ?? "?"])
        } else if front == nil || front?.processIdentifier == NSRunningApplication.current.processIdentifier {
            NSApp.deactivate()
            Log.event(.app, "focus.deactivated")
        }
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

    // MARK: - OverlayView 回调

    /// 松手确认（confirm 态）：全局选区矩形与所在屏幕
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
    }

    /// 确认动作（Enter / 双击 / ⌘S / Esc）
    func perform(action: Action) {
        switch action {
        case .cancel:
            Log.event(.overlay, "overlay.cancel")
            end()
            completion?(.cancelled)
            completion = nil
        case .copy, .save:
            guard let rect = selectionRectGlobal, let screen = selectionScreen else {
                Log.error(.overlay, "overlay.action.noSelection")
                end()
                completion?(.cancelled)
                completion = nil
                return
            }
            end()
            let completion = self.completion
            self.completion = nil
            Task {
                do {
                    let image = try await CaptureService.captureRegion(rect, on: screen)
                    switch action {
                    case .copy: completion?(.copy(image))
                    case .save: completion?(.save(image))
                    case .cancel: break
                    }
                } catch let error as CaptureError where error == .denied {
                    // 截图被拒：拉起系统设置 + 贴身拖拽源浮窗引导授权
                    TCCPermission.openSystemSettings()
                    completion?(.cancelled)
                } catch {
                    completion?(.cancelled)
                }
            }
        }
    }
}

/// v0.1 简化：OverlayView → AppCoordinator 的桥（避免循环持有）
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
