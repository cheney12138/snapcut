import AppKit
import CoreGraphics

/// 屏幕录制 TCC 权限预检（docs/03 §9）
enum TCCPermission {
    /// 启动时调用：预检 + 未授权则触发系统弹窗（CGRequestScreenCaptureAccess）
    @discardableResult
    static func preflight() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        Log.event(.permission, "permission.preflight", ["granted": "\(granted)"])
        if !granted {
            // 触发系统授权弹窗（用户点“打开系统设置”后完成授权）
            let requested = CGRequestScreenCaptureAccess()
            Log.event(.permission, "permission.request", ["requested": "\(requested)"])
        }
        return granted
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
        Log.event(.permission, "permission.openSettings")
    }
}
