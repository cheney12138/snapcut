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

    private let tray = StatusItemController()
    private let hotkeyCenter = CarbonHotKeyCenter.shared
    private let exporter = ExportCoordinator()
    private var overlayController: OverlayController?

    func start() {
        AppCoordinatorShared.coordinator = self
        TCCPermission.preflight()
        scheduleSelfTestIfRequested()
        tray.setup(coordinator: self)
        hotkeyCenter.register(keyCode: kVK_ANSI_A, modifiers: [.command, .shift]) { [weak self] in
            self?.beginRegionCapture()
        }
    }

    func teardown() {
        hotkeyCenter.teardown()
    }

    // MARK: - 截图入口（热键 / 托盘菜单共用）

    func beginRegionCapture() {
        guard state == .idle else {
            Log.event(.app, "capture.ignored", ["state": state.rawValue])
            return
        }
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
                self.exporter.copyToClipboard(image)
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
