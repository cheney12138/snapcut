import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    override init() {
        super.init()
        // 坑 33 配套：接管 quit Apple event（osascript quit / 系统「退出」菜单等），
        // 置热标记后走标准 terminate——applicationShouldTerminate 只放行两类：
        // 本标记（用户显式退出）+ 菜单退出（SnapcutQuitController 同款标记）。
        // CC 驱逐 status item 的连坐 terminate 没有 Apple event，被拦。
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        UserDefaults.standard.set(true, forKey: "app.quit.allowed")
        NSApp.terminate(nil)
    }

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
        // 预激活（用户病例 2026-11-16「重启后第一次唤起卡手」）：accessory App
        // 的首次 NSApp.activate 由 macOS 冷启动激活流程，实测 ~1.7s——期间
        // overlay 已上屏但鼠标事件仍路由给前台 App（用户拖动选中的是 TUI 文字）。
        // 启动时激活一次并立刻退出，把首次激活成本留在启动刻，之后每次唤起
        // 都是热激活（<50ms）。
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.coordinator.releaseActivationAfterWarmup()
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
        Log.event(.app, "app.terminate.blocked")
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
