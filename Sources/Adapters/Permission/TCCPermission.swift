import AppKit
import ApplicationServices
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
    /// macOS 进程一旦获得屏幕录制权限，运行期间不会在无重启的情况下撤销；
    /// 缓存 granted=true 可消除每次按 F1 时 2 次同步 TCCAccessRequest() IPC 开销。
    private static var cachedGranted = false

    /// 启动时调用：**只查不弹**。
    @discardableResult
    static func preflight() -> Bool {
        if cachedGranted { return true }
        let granted = CGPreflightScreenCaptureAccess()
        if granted { cachedGranted = true }
        Log.event(.permission, "permission.preflight", ["granted": "\(granted)"])
        return granted
    }

    /// 触发系统确认窗（仅此而已——用户点「打开系统设置」由系统自己拉起列表页；
    /// 我们的贴身浮窗在检测到系统设置窗口出现后自动跟上）。
    static func requestSystemPrompt() {
        // 用户裁定（2026-11-15）：「去授权」两个入口（引导卡 + 托盘菜单）
        // 都直接唤起权限 list + 打开浮窗——不再依赖 TCC 确认框的
        // 「打开系统设置」按钮（用户实报：点了去授权没打开权限面板）。
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            // 触发一次 TCC 注册（让 Snapcut 出现在录屏列表里；
            // 框若弹出属于系统行为，我们不依赖它）
            _ = CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
        Log.event(.permission, "permission.request", ["granted": "\(granted)"])
        // 浮窗待命：tick 找到系统设置窗口后自动显示
        PermissionDragOverlay.shared.show(for: .screenRecording)
    }

    /// 托盘菜单手动入口（用户主动要求看设置页）
    static func openSystemSettings() {
        let granted = CGPreflightScreenCaptureAccess()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
        Log.event(.permission, "permission.openSettings", ["granted": "\(granted)"])
        if !granted {
            PermissionDragOverlay.shared.show(for: .screenRecording)
        }
    }
}

/// 辅助功能权限（智能框选表格 / 控件 / 网页元素用）
/// 纪律：isTrusted() 只查不弹；requestAndOpenSettings() 仅在用户主动点击「去授权」时调用。
@MainActor
enum AccessibilityPermission {
    /// 只查不弹。macOS 的 AX 授权要求 App 在系统设置里重新勾选才生效（运行期不撤销），
    /// 但用户可能中途手动关掉，所以这里不做缓存。
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// **仅用户主动点击时调用**：先让系统把 Snapcut 登记进辅助功能列表（可能弹一次
    /// 系统确认框），再打开「隐私与安全性 → 辅助功能」页。
    static func requestAndOpenSettings() {
        // 用字面量而不是 kAXTrustedCheckOptionPrompt：后者是全局 CFString 变量，
        // Swift 6 strict concurrency 下会被判为共享可变状态而报并发告警（两者等价）。
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue as Any] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
            // 贴身浮窗：系统设置窗口出现后自动贴到右下角，图标可直接拖进列表
            PermissionDragOverlay.shared.show(for: .accessibility)
        }
        Log.event(.permission, "accessibility.request", ["trusted": "\(trusted)"])
    }

    /// 只打开设置页，不触发系统确认框（已在列表里的场景无副作用）
    static func openSettings() {
        let trusted = isTrusted()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        Log.event(.permission, "accessibility.openSettings", ["trusted": "\(trusted)"])
        if !trusted {
            PermissionDragOverlay.shared.show(for: .accessibility)
        }
    }
}
