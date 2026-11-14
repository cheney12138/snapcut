import AppKit
import CoreGraphics

/// 屏幕录制 TCC 权限预检与引导（docs/03 §9）
@MainActor
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

    /// 打开系统设置的屏幕录制页；未授权时同步拉起「贴身拖拽源浮窗」引导
    static func openSystemSettings() {
        let granted = CGPreflightScreenCaptureAccess()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
        Log.event(.permission, "permission.openSettings", ["granted": "\(granted)"])
        if !granted {
            PermissionDragOverlay.shared.show()
        }
    }
}
