import CoreGraphics
import Foundation

/// 六边形架构 · 端口（Ports）
///
/// ## 依赖方向铁律
/// ```
///        ┌──────────────── UI / Adapters（AppKit、SCK、Vision、Carbon、文件系统）──┐
///        │                             ↓ 只依赖端口                              │
///        │                        Core/Ports（本文件）                            │
///        │                             ↓ 只依赖领域                                │
///        └──────────────────────  Core/Domain（纯数据 + 纯算法）───────────────────┘
/// ```
/// - `Sources/Core/**` 只允许 import Foundation / CoreGraphics / os。
///   **禁止** AppKit / ScreenCaptureKit / Vision / Carbon / UniformTypeIdentifiers。
///   由 `scripts/check-architecture.sh` 强制，`make dev` 会跑。
/// - 领域与用例不知道「屏幕是 ScreenCaptureKit 拍的」「文字是 Vision 识的」，
///   只认这些协议。换实现（比如窗口截图改 CGWindowList）不需要动 Core。
/// - 测试替身不进代码库：验证走真实运行（项目纪律），端口的存在是为了**边界清晰**，
///   不是为了 mock。

// MARK: - 屏幕采集

/// 屏幕/窗口采集端口。适配器：`SCKCapture`（ScreenCaptureKit）
public protocol ScreenCapturing: Sendable {
    /// 采集整块显示器（物理像素，不缩放）
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage
}

// MARK: - 剪贴板

/// 剪贴板写入端口。适配器：`ClipboardWriter`（NSPasteboard）
@MainActor
public protocol ClipboardWriting {
    /// 写入图片，返回是否至少写入一种格式
    @discardableResult
    func writeImage(_ image: CGImage) -> Bool
    /// 写入纯文本（OCR 取字用）
    @discardableResult
    func writeText(_ text: String) -> Bool
}

// MARK: - 历史

/// 历史记录端口。适配器：`FileHistoryStore`（~/Library/Application Support）
@MainActor
public protocol HistoryRecording {
    /// 记录一次导出（复制/保存/贴图/OCR 原图都算）
    func record(_ image: CGImage)
}

// MARK: - OCR

/// 文字识别端口。适配器：`VisionTextRecognizer`（Vision 框架，本地离线）
public protocol TextRecognizing: Sendable {
    /// 识别图中文字，按阅读顺序拼接；未识别到返回空串
    func recognize(_ image: CGImage) async throws -> String
}

// MARK: - 全局热键

/// 热键修饰符（领域自己的取值，不泄漏 Carbon/NSEvent 类型）
public struct HotkeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let shift = HotkeyModifiers(rawValue: 1 << 1)
    public static let option = HotkeyModifiers(rawValue: 1 << 2)
    public static let control = HotkeyModifiers(rawValue: 1 << 3)
}

/// 全局热键端口。适配器：`CarbonHotKeyCenter`（RegisterEventHotKey）
@MainActor
public protocol HotkeyRegistering {
    @discardableResult
    func register(keyCode: UInt32, modifiers: HotkeyModifiers, action: @escaping @MainActor () -> Void) -> UInt32?
    func unregister(_ id: UInt32?)
}

// MARK: - 权限

/// 屏幕录制权限端口。适配器：`TCCPermission`（CoreGraphics TCC）
@MainActor
public protocol ScreenPermissionChecking {
    /// 只查不弹
    func isGranted() -> Bool
    /// 弹系统确认窗（由系统引导用户去设置页）
    func request()
    /// 用户主动打开设置页
    func openSettings()
}

// MARK: - 贴图

/// 贴图展示端口。适配器：`PinWindowController`（NSWindow）
@MainActor
public protocol PinningPresenting {
    /// 把图片钉在屏幕上（rect 为 AppKit 全局坐标）
    func pin(_ image: CGImage, atGlobalRect rect: CGRect)
}

// MARK: - 依赖容器（合成根用）

/// 依赖集合：只在合成根（`AppCoordinator`）构造一次，向下注入。
/// 领域/用例不允许直接 new 适配器，也不允许读单例。
@MainActor
public struct Dependencies {
    public let screen: ScreenCapturing
    public let clipboard: ClipboardWriting
    public let history: HistoryRecording
    public let textRecognizer: TextRecognizing
    public let hotkeys: HotkeyRegistering
    public let permission: ScreenPermissionChecking
    public let pinning: PinningPresenting

    public init(
        screen: ScreenCapturing,
        clipboard: ClipboardWriting,
        history: HistoryRecording,
        textRecognizer: TextRecognizing,
        hotkeys: HotkeyRegistering,
        permission: ScreenPermissionChecking,
        pinning: PinningPresenting
    ) {
        self.screen = screen
        self.clipboard = clipboard
        self.history = history
        self.textRecognizer = textRecognizer
        self.hotkeys = hotkeys
        self.permission = permission
        self.pinning = pinning
    }
}
