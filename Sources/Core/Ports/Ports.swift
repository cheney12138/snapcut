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

// MARK: - 录屏后处理（头尾裁剪 / MP4 → GIF）

/// 录制产物后处理端口（裁剪与转 GIF 都是「拿一个文件换另一个文件」）。
/// 适配器：`VideoPostProcessor`（AVFoundation + ImageIO）
///
/// 为什么独立于 `ScreenRecording`：录制会话有生命周期与实时状态，后处理是纯文件变换，
/// 可以在录制结束很久之后（甚至对历史文件）独立调用，两者混在一个端口里会让
/// 内存录制器背上传导出责任。
public protocol VideoPostProcessing: Sendable {
    /// 裁剪 MP4 头尾：输出新文件到 destinationURL
    ///
    /// - 若 `destinationURL` 与 `sourceURL` 相同：实现必须先写同目录临时文件再原子替换
    ///   （直接就地写会读到正在被自己截断的文件，产出损坏视频）
    /// - 优先无损快裁（passthrough），失败时实现可降级重导出
    func trimMP4(
        sourceURL: URL,
        range: VideoTrimRange,
        destinationURL: URL
    ) async throws -> RecordingResult

    /// 将 MP4（或其中指定裁剪区间）转为循环 GIF，回调进度 0...1
    func convertMP4ToGIF(
        sourceURL: URL,
        range: VideoTrimRange,
        options: GIFConversionOptions,
        destinationURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> RecordingResult
}

public extension VideoPostProcessing {
    /// 不关心进度的调用点用这个重载（协议要求不能带默认参数，
    /// 所以用协议扩展把 `onProgress` 变成真正可选）
    func convertMP4ToGIF(
        sourceURL: URL,
        range: VideoTrimRange,
        options: GIFConversionOptions,
        destinationURL: URL
    ) async throws -> RecordingResult {
        try await convertMP4ToGIF(
            sourceURL: sourceURL,
            range: range,
            options: options,
            destinationURL: destinationURL,
            onProgress: nil
        )
    }
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

// MARK: - 智能框选

/// 视觉识别快照：一次截屏后 Vision 给出的文本行与视觉矩形（均为 AppKit 全局坐标，Y 向上）。
///
/// 为什么打成快照而不是让端口按需回调：智能框选要靠鼠标移动高频取候选，
/// 每次移动都重新跑一遍 Vision 会卡主线程；正确做法是「截一次屏 → 出一份快照 →
/// 之后纯几何查询」。快照只承载坐标，不承载图像，跨并发安全。
public struct SmartVisionSnapshot: Sendable, Equatable {
    /// 文本行矩形（全局 Y-up）
    public let textLines: [CGRect]
    /// 版面视觉矩形（全局 Y-up）
    public let visualRects: [CGRect]
    /// 视觉表格结构（整表 / 行 / 列 / 单元格，全局 Y-up）
    public let visualTables: [DetectedVisualTable]

    public init(
        textLines: [CGRect],
        visualRects: [CGRect],
        visualTables: [DetectedVisualTable] = []
    ) {
        self.textLines = textLines
        self.visualRects = visualRects
        self.visualTables = visualTables
    }

    public static let empty = SmartVisionSnapshot(textLines: [], visualRects: [])
}

/// 辅助功能元素探测端口。适配器：`AXElementProber`（ApplicationServices / AXUIElement）
///
/// 会话纪律：`beginSession()` / `endSession()` 成对包住一次框选交互（拖动期间
/// 高频 hit-test 不该每次都重新建立 AX 连接；退出交互必须及时释放，否则会影响
/// 目标 App 的响应）。
public protocol SmartElementProbing: Sendable {
    /// 是否已获得辅助功能授权（只查不弹，弹窗由引导流程负责）
    func isAccessibilityTrusted() -> Bool
    /// 开始一次交互会话（可重复调用，实现需幂等）
    func beginSession()
    /// 结束会话并释放资源
    func endSession()
    /// 探测光标处的 AX 元素链（由内到外），返回全局 Y-up 坐标候选。
    /// - Parameters:
    ///   - point: 全局坐标（Y 向上）
    ///   - mainScreenHeight: 主屏高度，用于把 AX 的 Y-down 转成 Y-up（多屏/异形屏由适配器统一处理）
    ///   - pid: 需要排除的进程（通常是 Snapcut 自己，避免框到自己）
    func probe(
        atGlobalPoint point: CGPoint,
        mainScreenHeight: CGFloat,
        excludingPID pid: Int32
    ) async -> [SmartSelectionCandidate]
}

/// 视觉版面识别端口。适配器：`VisionLayoutDetector`（Vision，本地离线）
///
/// 返回的矩形一律是 AppKit 全局坐标（Y 向上），像素 → 全局的换算在适配器内完成。
public protocol SmartVisionDetecting: Sendable {
    /// 识别文本行（用于「先选一行字」的默认层级）
    func detectTextLines(in image: CGImage, screenFrame: CGRect) async -> [CGRect]
    /// 识别版面视觉矩形（卡片/图片/分区块，用于 AX 不可用时的兜底）
    func detectVisualRects(in image: CGImage, screenFrame: CGRect) async -> [CGRect]
    /// 识别表格结构（整表 / 行 / 列 / 单元格）。
    /// - Parameters:
    ///   - image: 整屏截图
    ///   - screenFrame: 该屏全局 frame（像素 → 全局坐标换算用）
    ///   - candidateRects: 候选区域（视觉矩形），限定在这些区域内找横竖线，避免全图开销与误检
    /// - Returns: 全局 Y-up 坐标的表格结构；未识别到返回空数组
    func detectVisualTables(
        in image: CGImage,
        screenFrame: CGRect,
        candidateRects: [CGRect]
    ) async -> [DetectedVisualTable]
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
    public let smartElementProber: SmartElementProbing
    public let smartVisionDetector: SmartVisionDetecting
    public let videoPostProcessor: any VideoPostProcessing

    public init(
        screen: ScreenCapturing,
        clipboard: ClipboardWriting,
        history: HistoryRecording,
        textRecognizer: TextRecognizing,
        hotkeys: HotkeyRegistering,
        permission: ScreenPermissionChecking,
        pinning: PinningPresenting,
        updating: AppUpdating,
        recording: ScreenRecording,
        smartElementProber: SmartElementProbing,
        smartVisionDetector: SmartVisionDetecting,
        videoPostProcessor: any VideoPostProcessing
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
        self.smartElementProber = smartElementProber
        self.smartVisionDetector = smartVisionDetector
        self.videoPostProcessor = videoPostProcessor
    }
}
