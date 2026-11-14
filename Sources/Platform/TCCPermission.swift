import AppKit
import CoreGraphics

/// 屏幕录制 TCC 权限（docs/03 §9）
///
/// 纪律（照 Glance PermissionMonitor/Snapshotter 病例 + 用户产品决策 2026-11-14）：
/// - `CGPreflightScreenCaptureAccess()` **不弹窗**，随便查；
/// - `CGRequestScreenCaptureAccess()` 弹系统确认窗（用户点「打开系统设置」才进列表）——
///   **不要替用户直接打开设置页**（病例：系统窗+设置页同时弹，确认窗被压底变孤儿）；
/// - 权限引导**前置**：首启即引导，未授权不唤起截图（门禁语义）。
@MainActor
enum TCCPermission {
    /// 启动时调用：**只查不弹**。
    @discardableResult
    static func preflight() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        Log.event(.permission, "permission.preflight", ["granted": "\(granted)"])
        return granted
    }

    /// 触发系统确认窗（仅此而已——用户点「打开系统设置」由系统自己拉起列表页；
    /// 我们的贴身浮窗在检测到系统设置窗口出现后自动跟上）。
    static func requestSystemPrompt() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
        Log.event(.permission, "permission.request", [:])
        // 浮窗待命：tick 找到系统设置窗口后自动显示
        PermissionDragOverlay.shared.show()
    }

    /// 托盘菜单手动入口（用户主动要求看设置页）
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
