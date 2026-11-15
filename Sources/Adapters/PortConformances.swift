import AppKit
import CoreGraphics

/// 适配器实现端口（六边形架构的「外圈 → 内圈」侧）
///
/// 这里只做**类型适配**（把 AppKit/Carbon/SCK 的类型翻成领域端口签名），
/// 不承载业务逻辑。已有类型保持原样，用薄包装/extension 补 conformance，
/// 迁移零行为变化，调用点可逐步改成只依赖端口。

// MARK: - 屏幕采集

/// SCK 适配器：领域只看到 `captureDisplay(_:)`
struct ScreenCaptureAdapter: ScreenCapturing {
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        try await SCKCapture.shared.captureDisplay(displayID: displayID)
    }
}

// MARK: - 剪贴板

/// NSPasteboard 适配器（PNG+TIFF 双格式，含文本写入）
@MainActor
final class PasteboardClipboard: ClipboardWriting {
    @discardableResult
    func writeImage(_ image: CGImage) -> Bool {
        ClipboardWriter.writeImage(image)
    }

    @discardableResult
    func writeText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        Log.event(.clipboard, "clipboard.write", [
            "fmts": "text", "bytes": "\(text.utf8.count)", "ok": "\(ok)",
        ])
        return ok
    }
}

// MARK: - 热键

extension CarbonHotKeyCenter: HotkeyRegistering {
    /// 领域热键修饰符 → NSEvent 修饰符（纯适配）
    static func eventFlags(from modifiers: HotkeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: HotkeyModifiers,
        action: @escaping @MainActor () -> Void
    ) -> UInt32? {
        register(keyCode: Int(keyCode), modifiers: Self.eventFlags(from: modifiers)) {
            MainActor.assumeIsolated { action() }
        }
    }
}

// MARK: - 屏幕录制权限

/// TCC 适配器（enum 静态工具 → 端口实例）
@MainActor
final class ScreenPermissionAdapter: ScreenPermissionChecking {
    func isGranted() -> Bool { TCCPermission.preflight() }
    func request() {
        TCCPermission.requestSystemPrompt()
        AppCoordinatorShared.coordinator?.markPermissionPromptShown()
    }
    func openSettings() { TCCPermission.openSystemSettings() }
}

// MARK: - 历史 / OCR / 贴图
// 由各自模块提供（History / OCR / Pin），落地后在 AppCoordinator 的
// Dependencies 合成里接线。

// MARK: - 历史记录 / OCR / 贴图（并行模块产出的适配器）

extension HistoryStore: HistoryRecording {}

/// Vision OCR 适配器：领域只看到 `recognize(_:) async throws -> String`
struct VisionTextRecognizerAdapter: TextRecognizing {
    func recognize(_ image: CGImage) async throws -> String {
        try await TextRecognizer.recognize(image)
    }
}

/// 贴图适配器：领域不知道「贴图靠 NSWindow 实现」
@MainActor
final class PinPresenterAdapter: PinningPresenting {
    func pin(_ image: CGImage, atGlobalRect rect: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        guard let screen else { return }
        PinWindowController.pin(image, atGlobalRect: rect, on: screen)
    }
}

// MARK: - 合成根

extension Dependencies {
    /// 唯一允许 new 适配器的地方（AppCoordinator 启动时调用一次）
    @MainActor
    static func live() -> Dependencies {
        Dependencies(
            screen: ScreenCaptureAdapter(),
            clipboard: PasteboardClipboard(),
            history: HistoryStore.shared,
            textRecognizer: VisionTextRecognizerAdapter(),
            hotkeys: CarbonHotKeyCenter.shared,
            permission: ScreenPermissionAdapter(),
            pinning: PinPresenterAdapter()
        )
    }
}
