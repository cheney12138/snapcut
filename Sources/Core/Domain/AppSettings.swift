import Foundation

/// 应用设置（纯领域数据：不含任何系统类型，可 JSON 编解码）
///
/// 热键用字符串编码（如 "cmd+shift+a"），是纯数据——
/// NSEvent/Carbon 的类型翻译属于适配器职责，不进领域。
public struct AppSettings: Equatable, Sendable, Codable {
    /// 截图完成后的默认动作
    public enum AfterCaptureAction: String, Codable, Sendable, CaseIterable {
        case copy      // 复制到剪贴板
        case save      // 保存到文件
        case pin       // 贴到屏幕
    }

    /// 导出文件名风格
    public enum FilenameStyle: String, Codable, Sendable, CaseIterable {
        case timestamp      // 时间戳
        case appAndTime     // 应用名 + 时间
        case askEveryTime   // 每次询问
    }

    /// 截图完成后默认动作（默认 copy）
    public var afterCapture: AfterCaptureAction
    /// 默认保存目录（默认 ~/Pictures/Snapcut）
    public var saveDirectoryPath: String
    /// 文件名风格（默认 timestamp）
    public var filenameStyle: FilenameStyle
    /// 历史保留条数（默认 30，取值范围 historyLimitRange）
    public var historyLimit: Int
    /// 复制后显示系统通知（默认 true）
    public var showCopyNotification: Bool
    /// 截图音效（默认 false）
    public var playCaptureSound: Bool
    /// 区域截图热键（默认 "cmd+shift+a"，字符串编码纯数据）
    public var hotkeyRegion: String
    /// 全屏截图热键（默认 "cmd+shift+s"）
    public var hotkeyFullScreen: String

    /// 历史保留条数的合法范围
    public static let historyLimitRange: ClosedRange<Int> = 1...200

    public init(
        afterCapture: AfterCaptureAction = .copy,
        saveDirectoryPath: String = "~/Pictures/Snapcut",
        filenameStyle: FilenameStyle = .timestamp,
        historyLimit: Int = 30,
        showCopyNotification: Bool = true,
        playCaptureSound: Bool = false,
        hotkeyRegion: String = "cmd+shift+a",
        hotkeyFullScreen: String = "cmd+shift+s"
    ) {
        self.afterCapture = afterCapture
        self.saveDirectoryPath = saveDirectoryPath
        self.filenameStyle = filenameStyle
        self.historyLimit = historyLimit
        self.showCopyNotification = showCopyNotification
        self.playCaptureSound = playCaptureSound
        self.hotkeyRegion = hotkeyRegion
        self.hotkeyFullScreen = hotkeyFullScreen
    }

    /// 出厂默认值
    public static let defaultSettings = AppSettings()
}
