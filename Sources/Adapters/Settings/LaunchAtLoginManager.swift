import Foundation
import ServiceManagement

/// macOS 登录项（开机自动启动）状态
enum LaunchAtLoginStatus: String, Sendable {
    case enabled
    case requiresApproval
    case disabled
}

/// 开机自动启动适配器（基于 macOS 13+ 原生 SMAppService.mainApp）：
///
/// - 始终以系统 `SMAppService.mainApp.status` 为唯一真相源（用户在「系统设置 → 通用 → 登录项」
///   里手动改动后，重新打开 Snapcut 设置窗口会自动同步）；
/// - 处于 `.requiresApproval` 时提供一键跳转「系统设置 → 登录项」。
@MainActor
enum LaunchAtLoginManager {
    static var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    static var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enable: Bool) -> Result<LaunchAtLoginStatus, Error> {
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            }
            let current = status
            Log.event(.app, "settings.launchAtLogin", [
                "requested": "\(enable)",
                "status": current.rawValue,
            ])
            return .success(current)
        } catch {
            Log.error(.app, "settings.launchAtLogin.fail", [
                "requested": "\(enable)",
                "err": error.localizedDescription,
            ])
            return .failure(error)
        }
    }

    static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
