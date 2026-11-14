import Foundation

/// 设置存储端口。适配器：`UserDefaultsSettingsStore`（UserDefaults + JSON）
///
/// 依赖方向：UI（SettingsWindowController）只认本协议，
/// 不直接碰 UserDefaults；换存储实现（文件/SQLite）不需要动 UI。
@MainActor
public protocol SettingsStoring {
    /// 读取设置；缺失/解码失败返回 `.defaultSettings`
    func load() -> AppSettings
    /// 立即写盘（设置面板无「确定」按钮，每次改动都会调用）
    func save(_ settings: AppSettings)
}
