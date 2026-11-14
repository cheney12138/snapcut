import os

/// 日志分类（对齐 docs/03 §7.1）
enum LogCategory: String {
    case app, capture, overlay, clipboard, hotkey, tray, permission, export, platform, editor, scroll
    case history, ocr, pin
}

/// 统一日志门面：subsystem = app.snapcut，事件结构 evt=xxx key=value
///
/// 用法：Log.event(.capture, "capture.display.ok", ["ms": "142", "pxW": "2560"])
enum Log {
    private static let subsystem = "app.snapcut"

    static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// 事件打点（info 级，落 unified logging）
    static func event(_ category: LogCategory, _ evt: String, _ fields: [String: String] = [:]) {
        let suffix = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        logger(category).info("evt=\(evt, privacy: .public) \(suffix, privacy: .public)")
    }

    /// 错误事件（error 级）
    static func error(_ category: LogCategory, _ evt: String, _ fields: [String: String] = [:]) {
        let suffix = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        logger(category).error("evt=\(evt, privacy: .public) \(suffix, privacy: .public)")
    }
}
