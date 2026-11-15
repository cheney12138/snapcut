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
    /// 编辑器内操作热键（工具栏后半段：action key → 组合串）
    /// key 取 ToolbarPanel.Action 的 rawValue：undo / redo / toggleVisibility /
    /// done / save / cancel / ocr / pin。值格式同 hotkeyRegion（"cmd+z"），
    /// 额外允许裸键（"o"）与命名键（"return" / "esc"）——编辑器作用域，
    /// 不注册 Carbon。
    public var editorHotkeys: [String: String]

    /// 编辑器热键的出厂默认（= 原 keyDown 硬编码，迁移零感知）
    public static let defaultEditorHotkeys: [String: String] = [
        "undo": "cmd+z",
        "redo": "cmd+shift+z",
        "toggleVisibility": "h",
        "done": "return",
        "save": "cmd+s",
        "cancel": "esc",
        "ocr": "o",
        "pin": "p",
    ]

    /// 编辑器热键查找（缺失/非法回落默认；解析失败也回落——永不误吞按键）
    public func editorHotkey(for action: String) -> String {
        editorHotkeys[action] ?? Self.defaultEditorHotkeys[action] ?? ""
    }

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
        hotkeyFullScreen: String = "cmd+shift+s",
        editorHotkeys: [String: String] = AppSettings.defaultEditorHotkeys
    ) {
        self.afterCapture = afterCapture
        self.saveDirectoryPath = saveDirectoryPath
        self.filenameStyle = filenameStyle
        self.historyLimit = historyLimit
        self.showCopyNotification = showCopyNotification
        self.playCaptureSound = playCaptureSound
        self.hotkeyRegion = hotkeyRegion
        self.hotkeyFullScreen = hotkeyFullScreen
        self.editorHotkeys = editorHotkeys
    }

    /// 出厂默认值
    public static let defaultSettings = AppSettings()

    /// 兼容旧存档：editorHotkeys 是 2026-11-15 加的字段，旧 JSON 没有 →
    /// 合成 Codable 在缺 key 时抛错整体回落默认，会把用户改过的其他设置
    /// 一起洗掉。自定义 decode：缺字段 = 默认编辑器热键，其余照旧。
    public init(from decoder: Decoder) throws {
        afterCapture = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(AfterCaptureAction.self, forKey: .afterCapture) ?? .copy
        saveDirectoryPath = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(String.self, forKey: .saveDirectoryPath)) ?? "~/Pictures/Snapcut"
        filenameStyle = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(FilenameStyle.self, forKey: .filenameStyle)) ?? .timestamp
        historyLimit = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(Int.self, forKey: .historyLimit)) ?? 30
        showCopyNotification = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .showCopyNotification)) ?? true
        playCaptureSound = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .playCaptureSound)) ?? false
        hotkeyRegion = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(String.self, forKey: .hotkeyRegion)) ?? "cmd+shift+a"
        hotkeyFullScreen = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(String.self, forKey: .hotkeyFullScreen)) ?? "cmd+shift+s"
        editorHotkeys = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent([String: String].self, forKey: .editorHotkeys)) ?? Self.defaultEditorHotkeys
    }
}
