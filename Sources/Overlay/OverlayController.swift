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

    /// 开始一次选区会话
    func begin(completion: @escaping (Result) -> Void) {
        self.completion = completion
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

    /// 结束会话（无论结果如何，清掉所有窗口）
    func end() {
        dismissAll()
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
