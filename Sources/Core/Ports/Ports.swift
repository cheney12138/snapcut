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
    /// 写入纯文本（OCR 取字 / 复制文件路径用）
    @discardableResult
    func writeText(_ text: String) -> Bool
    /// 写入文件引用（以及 GIF 动图数据），支持直接粘贴到访达或聊天工具
    @discardableResult
    func writeFileURL(_ url: URL) -> Bool
}

// MARK: - 历史

/// 历史记录端口。适配器：`FileHistoryStore`（~/Library/Application Support）
@MainActor
public protocol HistoryRecording {
    /// 记录一次导出（复制/保存/贴图/OCR 原图都算）
    func record(_ image: CGImage)
    /// 记录一次导出并附带元数据（应用名/窗口标题/原始底图/可编辑矢量标注层）
    func record(_ image: CGImage, metadata: HistoryCaptureMetadata?)
}

public extension HistoryRecording {
    func record(_ image: CGImage, metadata: HistoryCaptureMetadata?) {
        record(image)
    }
}

// MARK: - OCR

/// 文字识别端口。适配器：`VisionTextRecognizer`（Vision 框架，本地离线）
public protocol TextRecognizing: Sendable {
    /// 识别图中文字，按阅读顺序拼接；未识别到返回空串
    func recognize(_ image: CGImage) async throws -> String
    /// 结构化识别图中文字、二维码与 Markdown 表格
    func recognizeStructured(_ image: CGImage) async throws -> StructuredOCRResult
    /// 检测图中全部敏感信息（邮箱/手机/API Key/JWT/密钥参数/IP/身份证）的精确归一化坐标框（Y-down）
    func detectSensitiveRegions(_ image: CGImage) async throws -> [DetectedSensitiveRegion]
}

public extension TextRecognizing {
    func recognizeStructured(_ image: CGImage) async throws -> StructuredOCRResult {
        let text = try await recognize(image)
        return StructuredOCRResult(
            plainText: text,
            qrCodes: [],
            markdownTable: nil,
            tableRowCount: 0,
            tableColumnCount: 0
        )
    }
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

// MARK: - 屏幕录制（MP4 / GIF）

/// 录制启动请求（领域与 UI 只传坐标、屏幕参数与偏好，不感知 SCStream / AVAssetWriter）
public struct ScreenRecordingRequest: Sendable {
    public let regionGlobal: CGRect
    public let displayID: CGDirectDisplayID
    public let screenFrame: CGRect
    public let backingScale: CGFloat
    public let preferDisplayP3: Bool
    public let options: RecordingOptions
    public let outputURL: URL
    public let isTemporaryFile: Bool

    public init(
        regionGlobal: CGRect,
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        backingScale: CGFloat,
        preferDisplayP3: Bool,
        options: RecordingOptions,
        outputURL: URL,
        isTemporaryFile: Bool = false
    ) {
        self.regionGlobal = regionGlobal
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.backingScale = backingScale
        self.preferDisplayP3 = preferDisplayP3
        self.options = options
        self.outputURL = outputURL
        self.isTemporaryFile = isTemporaryFile
    }
}

/// 录制运行期事件（回传给控制条更新计时、音频电平动效与状态）
public enum ScreenRecordingEvent: Sendable {
    case started
    case progress(elapsed: TimeInterval)
    /// 实时音频收录归一化电平（0.0...1.0；静音或未启用轨为 0）
    case audioLevels(system: Float, microphone: Float)
    case paused(elapsed: TimeInterval)
    case resumed
    case failed(String)
}

/// 屏幕录制端口。适配器：`SCKScreenRecorder`（SCStream + AVAssetWriter / CGImageDestination）
@MainActor
public protocol ScreenRecording: AnyObject {
    var isRecording: Bool { get }
    var isPaused: Bool { get }
    func start(
        request: ScreenRecordingRequest,
        onEvent: @escaping @MainActor (ScreenRecordingEvent) -> Void
    ) async throws
    func pause() async
    func resume() async
    func stop() async throws -> RecordingResult
    func cancel() async
}

// MARK: - 自动更新

/// 应用更新端口。适配器：`SparkleUpdater`（Sparkle 2 + EdDSA 签名的 appcast）
///
/// 为什么不自写：macOS 上「替换正在运行的 .app」这件事有既定做法（appcast +
/// EdDSA 签名 + 独立的 Installer 辅助进程），自写必然在「签名校验 / 半途失败 /
/// 权限提升 / 退场时机」上翻车。
@MainActor
public protocol AppUpdating: AnyObject {
    /// 手动检查一次更新（会自己弹 Sparkle 的进度/结果窗）
    func checkForUpdates()
    /// 每日后台自动检查（默认开，落盘在 Sparkle 自己的 UserDefaults 键里）
    var automaticallyChecksForUpdates: Bool { get set }
    /// 最近一次检查的时间（nil = 从未）
    var lastCheckDescription: String? { get }
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
    public let updating: AppUpdating
    public let recording: ScreenRecording

    public init(
        screen: ScreenCapturing,
        clipboard: ClipboardWriting,
        history: HistoryRecording,
        textRecognizer: TextRecognizing,
        hotkeys: HotkeyRegistering,
        permission: ScreenPermissionChecking,
        pinning: PinningPresenting,
        updating: AppUpdating,
        recording: ScreenRecording
    ) {
        self.screen = screen
        self.clipboard = clipboard
        self.history = history
        self.textRecognizer = textRecognizer
        self.hotkeys = hotkeys
        self.permission = permission
        self.pinning = pinning
        self.updating = updating
        self.recording = recording
    }
}
