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

    /// 标注工具栏尺寸档位（适配快捷键党与鼠标党不同点击手感）
    public enum ToolbarSize: String, Codable, Sendable, CaseIterable {
        case compact    // 紧凑（30pt 按钮 / 44pt 高）
        case regular    // 标准（36pt 按钮 / 50pt 高，默认）
        case large      // 大号（42pt 按钮 / 58pt 高）
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
    /// key 取 ToolbarPanel.Action 的语义名：undo / redo / toggleVisibility /
    /// done / save / cancel / ocr / pin / scroll。值格式同 hotkeyRegion（"cmd+z"），
    /// 额外允许裸键（"o"/"s"）与命名键（"return" / "esc"）——编辑器作用域，
    /// 不注册 Carbon。scroll 清空则滚动截图无键（仅工具栏按钮入口）。
    public var editorHotkeys: [String: String]
    /// 工具栏标注工具自定义排序（仅包含可绑 1-7 数字快捷键的 `EditorSession.Tool`，滚动截图固定于取字前）。
    public var toolbarOrder: [Int]
    /// 工具栏尺寸档位（默认 regular 标准档，更好点击）
    public var toolbarSize: ToolbarSize
    /// 视觉记忆库 Spotlight 面板全局热键（默认 "opt+cmd+v"，即 ⌥⌘V）
    public var hotkeyHistorySpotlight: String
    /// 截图导出后是否自动后台执行本地 OCR 文本索引（默认 true）
    public var autoIndexHistoryOCR: Bool
    /// 视觉记忆库浮窗内快捷操作键位（copyImage / reopenEdit / pin / copyOCR）
    public var spotlightHotkeys: [String: String]

    /// 工具组出厂默认序（纯标注工具 1-7；滚动截图已独立置于后段「取字」前）
    public static let defaultToolbarOrder: [Int] = EditorSession.Tool.allCases
        .filter { $0 != .none }
        .map { $0.rawValue }

    /// 排序查找（兼容旧存档：自动剔除早期混在工具组里的 206 滚动截图并补全缺漏工具）
    public func toolbarOrderSafe() -> [Int] {
        let valid = Set(EditorSession.Tool.allCases.filter { $0 != .none }.map { $0.rawValue })
        var filtered = toolbarOrder.filter { valid.contains($0) }
        for raw in Self.defaultToolbarOrder where !filtered.contains(raw) {
            filtered.append(raw)
        }
        return filtered
    }

    public static let defaultEditorHotkeys: [String: String] = [
        "undo": "cmd+z",
        "redo": "cmd+shift+z",
        "toggleVisibility": "h",
        "done": "return",
        "save": "cmd+s",
        "cancel": "esc",
        "ocr": "o",
        "pin": "p",
        "scroll": "s",
    ]

    /// 编辑器热键查找（缺失/非法回落默认；解析失败也回落——永不误吞按键）
    public func editorHotkey(for action: String) -> String {
        editorHotkeys[action] ?? Self.defaultEditorHotkeys[action] ?? ""
    }

    public static let defaultSpotlightHotkeys: [String: String] = [
        "copyImage": "return",
        "reopenEdit": "cmd+e",
        "pin": "cmd+p",
        "copyOCR": "cmd+c",
    ]

    /// 视觉记忆面板内操作热键查找
    public func spotlightHotkey(for action: String) -> String {
        let stored = spotlightHotkeys[action] ?? ""
        return stored.isEmpty ? (Self.defaultSpotlightHotkeys[action] ?? "") : stored
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
        editorHotkeys: [String: String] = AppSettings.defaultEditorHotkeys,
        toolbarOrder: [Int] = AppSettings.defaultToolbarOrder,
        toolbarSize: ToolbarSize = .regular,
        hotkeyHistorySpotlight: String = "opt+cmd+v",
        autoIndexHistoryOCR: Bool = true,
        spotlightHotkeys: [String: String] = AppSettings.defaultSpotlightHotkeys
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
        self.toolbarOrder = toolbarOrder
        self.toolbarSize = toolbarSize
        self.hotkeyHistorySpotlight = hotkeyHistorySpotlight
        self.autoIndexHistoryOCR = autoIndexHistoryOCR
        self.spotlightHotkeys = spotlightHotkeys
    }

    /// 出厂默认值
    public static let defaultSettings = AppSettings()

    /// 兼容旧存档：editorHotkeys 是 2026-11-15 加的字段，旧 JSON 没有 →
    /// 合成 Codable 在缺 key 时抛错整体回落默认，会把用户改过的其他设置
    /// 一起洗掉。自定义 decode：缺字段 = 默认编辑器热键，其余照旧。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        afterCapture = try container.decodeIfPresent(AfterCaptureAction.self, forKey: .afterCapture) ?? .copy
        saveDirectoryPath = (try? container.decodeIfPresent(String.self, forKey: .saveDirectoryPath)) ?? "~/Pictures/Snapcut"
        filenameStyle = (try? container.decodeIfPresent(FilenameStyle.self, forKey: .filenameStyle)) ?? .timestamp
        historyLimit = (try? container.decodeIfPresent(Int.self, forKey: .historyLimit)) ?? 30
        showCopyNotification = (try? container.decodeIfPresent(Bool.self, forKey: .showCopyNotification)) ?? true
        playCaptureSound = (try? container.decodeIfPresent(Bool.self, forKey: .playCaptureSound)) ?? false
        hotkeyRegion = (try? container.decodeIfPresent(String.self, forKey: .hotkeyRegion)) ?? "cmd+shift+a"
        hotkeyFullScreen = (try? container.decodeIfPresent(String.self, forKey: .hotkeyFullScreen)) ?? "cmd+shift+s"
        editorHotkeys = (try? container.decodeIfPresent([String: String].self, forKey: .editorHotkeys)) ?? Self.defaultEditorHotkeys
        toolbarOrder = (try? container.decodeIfPresent([Int].self, forKey: .toolbarOrder)) ?? Self.defaultToolbarOrder
        toolbarSize = (try? container.decodeIfPresent(ToolbarSize.self, forKey: .toolbarSize)) ?? .regular
        hotkeyHistorySpotlight = (try? container.decodeIfPresent(String.self, forKey: .hotkeyHistorySpotlight)) ?? "opt+cmd+v"
        autoIndexHistoryOCR = (try? container.decodeIfPresent(Bool.self, forKey: .autoIndexHistoryOCR)) ?? true
        spotlightHotkeys = (try? container.decodeIfPresent([String: String].self, forKey: .spotlightHotkeys)) ?? Self.defaultSpotlightHotkeys
    }
}
