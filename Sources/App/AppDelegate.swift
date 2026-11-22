import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?


    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        Log.event(.app, "app.start", [
            "version": version,
            "build": build,
            "displays": "\(NSScreen.screens.count)",
        ])
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
        // 静默预热 SCK XPC 与可复用工具栏（不抢前台焦点、不做 activate 重试风暴）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak coordinator] in
            coordinator?.warmupAfterLaunch()
        }
    }

    /// 坑 33（启动即退·根因）：ControlCenter 对 status item 发隐藏动作时，
    /// AppKit 触发「StatusBar terminating on removal」自动终止（sudden/
    /// automatic termination 通道，disable 标志拦不住）。
    /// 菜单栏 App 的 item 被 CC 驱逐不该连坐整个 App——拦截所有非用户发起的
    /// 终止：只放行「托盘菜单退出」（NSApp.terminate 由 QuitItem 触发时
    /// presentQuit 路径）。简单起见：一律 Cancel，用户退出走 terminate(nil)
    /// 的专用标记。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 用户显式退出放行：① SnapcutQuitController（菜单退出）的热标记；
        // ② Apple event quit（osascript/系统「退出」）：此时距离用户上次交互
        //    通常 < 数秒，而 CC 驱逐连坐发生在启动后 ~3s 且无任何用户交互——
        //    用「本会话至今无鼠标/键盘事件」区分（冷启动即被逐 = 纯系统行为）。
        if UserDefaults.standard.bool(forKey: "app.quit.allowed") {
            UserDefaults.standard.set(false, forKey: "app.quit.allowed")
            return .terminateNow
        }
        // ⑦ 2026-11-22 病例：这里原本靠 NSAppleEventManager 自装 quit 事件 handler
        //    置标记，实测**不会触发**（AppKit 内置的 quit handler 先接走了），于是
        //    `osascript ... quit` 报 -128「用户已取消」，更要命的是 **Sparkle 自动更新
        //    下载完成后要求 App 退出以替换 .app，被这里拦死** —— 表现是更新窗自己
        //    消失、版本号不动、Autoupdate 常驻不退（用户视角：更新功能坏了）。
        //    判据改到 terminate 现场：正在处理 quit Apple Event ⇒ 放行。
        //    ControlCenter 驱逐 status item 的连坐 terminate **没有** Apple Event
        //    （坑 33 的原判据），仍然被拦。
        let current = NSAppleEventManager.shared().currentAppleEvent
        if let current,
           current.eventClass == AEEventClass(kCoreEventClass),
           current.eventID == AEEventID(kAEQuitApplication) {
            Log.event(.app, "app.terminate.allow", ["src": "appleevent"])
            return .terminateNow
        }
        Log.event(.app, "app.terminate.blocked", [
            "ae": current.map { "\($0.eventClass)/\($0.eventID)" } ?? "none",
        ])
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.event(.app, "app.exit")
        coordinator?.teardown()
    }
}


/// 用户主动退出的唯一放行通道（坑 33 配套）：
/// 先置 allowNextTerminate 标记，再触发 terminate，applicationShouldTerminate
/// 放行一次后自动清标记。
@MainActor
enum SnapcutQuitController {
    static func quit() {
        UserDefaults.standard.set(true, forKey: "app.quit.allowed")
        NSApp.terminate(nil)
    }
}
