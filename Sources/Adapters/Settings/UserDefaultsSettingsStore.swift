import Foundation

/// UserDefaults 适配器（实现 `SettingsStoring` 端口）
///
/// - 存储格式：设置对象整体 JSON 编码，key = "app.settings.v1"
/// - load：缺失 / 解码失败一律回退 `.defaultSettings`，绝不抛错打断主流程
/// - save：只写 JSON；写失败只记日志
@MainActor
final class UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private let key = "app.settings.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = UserDefaults(suiteName: nil) ?? .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            Log.event(.app, "settings.load.default")
            return .defaultSettings
        }
        do {
            let settings = try decoder.decode(AppSettings.self, from: data)
            Log.event(.app, "settings.load.ok")
            return settings
        } catch {
            Log.error(.app, "settings.load.fallback", ["err": error.localizedDescription])
            return .defaultSettings
        }
    }

    func save(_ settings: AppSettings) {
        let data: Data
        do {
            data = try encoder.encode(settings)
        } catch {
            Log.error(.app, "settings.save.encodeFailed", ["err": error.localizedDescription])
            return
        }
        defaults.set(data, forKey: key)
        Log.event(.app, "settings.save", [
            "afterCapture": settings.afterCapture.rawValue,
            "historyLimit": "\(settings.historyLimit)",
        ])
    }
}
