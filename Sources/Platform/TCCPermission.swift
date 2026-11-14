import AppKit
import CoreGraphics

/// 屏幕录制 TCC 权限（docs/03 §9）
///
/// 纪律（照 Glance PermissionMonitor/Snapshotter 病例）：
/// - `CGPreflightScreenCaptureAccess()` **不弹窗**，启动/后台随便查；
/// - `CGRequestScreenCaptureAccess()` 会弹系统授权框 —— **只在用户主动走引导流程时调**
///   （托盘菜单「屏幕录制权限…」或截图被拒后的引导），
///   否则用户每次启动都被骚扰（Glance 2026-09-19 病例：「怎么老是弹录屏授权」）。
@MainActor
enum TCCPermission {
    /// 启动时调用：**只查不弹**。未授权走托盘引导，不打扰。
    @discardableResult
    static func preflight() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        Log.event(.permission, "permission.preflight", ["granted": "\(granted)"])
        return granted
    }

    /// 用户主动触发（托盘菜单 / 截图被拒引导）：拉起设置页 + 贴身拖拽源浮窗。
    /// CGRequest 只在此处调 —— 弹窗属于引导流程，不属于后台路径。
    static func openSystemSettings() {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            _ = CGRequestScreenCaptureAccess() // 首次会弹系统框，用户点「打开系统设置」
            Log.event(.permission, "permission.request", [:])
        }
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
        Log.event(.permission, "permission.openSettings", ["granted": "\(granted)"])
        if !granted {
            PermissionDragOverlay.shared.show()
        }
    }
}
