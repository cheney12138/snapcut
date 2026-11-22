import AppKit
import Sparkle

/// 自动更新适配器：把 Sparkle 2 收成 `AppUpdating` 这一个端口。
///
/// ## 为什么是 Sparkle 而不是自写
/// macOS 上「下载新包 → 替换正在运行的 .app → 重启」这件事有既定做法：
/// appcast.xml（更新源）+ EdDSA 签名（更新包可信）+ 独立 Installer 辅助进程
/// （替换时不需要我们自己处理权限提升与退场时机）。自己写必然在这三处翻车。
///
/// 关键点：**Sparkle 的安全性独立于 Apple 开发者账号** —— 它用 Ed25519 自己签，
/// 公钥写死在 `Info.plist` 的 `SUPublicEDKey`，私钥在本机钥匙串（account `snapcut`）。
/// 所以不需要 $99 账号；代价只有一个：**首次安装**的 DMG 会被浏览器打上
/// quarantine 标记（要用户在「系统设置 ▸ 隐私与安全性」放行一次），
/// 而 Sparkle 自己下载的更新**不会**被隔离。
///
/// ## 生命周期
/// `SPUStandardUpdaterController` 必须在**进程生命周期内存活**（它持有 schedule
/// timer 与 delegate），所以这里放一个 `shared` 单例；`Dependencies.live()` 只做
/// 端口注入，不负责持有。
///
/// ## 调试
/// Sparkle 的日志进 Console（subsystem 里带 `(Sparkle)`）；启动阶段的致命错
/// （比如 `SUPublicEDKey` 不是 44 字符 base64）会直接弹窗并拒绝启动更新器，
/// 而「没有更新源」只在手动检查时报错 —— 两者不是一回事。
@MainActor
final class SparkleUpdater: AppUpdating {
    static let shared = SparkleUpdater()

    /// `startingUpdater: true` = 启动就开始每日后台检查（`SUEnableAutomaticChecks`）。
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: gentleReminders
    )

    /// 后台 App（LSUIElement / 菜单栏）必须显式声明「支持温和提醒」，否则 Sparkle
    /// 会在控制台警告一句 *"Background app automatically schedules for update checks
    /// but does not implement gentle reminders"*，并且后台发现的更新**弹不出来也点不到**
    /// （菜单栏 App 没有前台窗口，模态窗会被压在别的 App 后面）。
    /// 声明之后：后台检查发现新版本不抢焦点，等用户下一次主动操作时才展示。
    private let gentleReminders = GentleReminderDelegate()

    private var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        Log.event(.app, "update.check", ["trigger": "manual", "version": current])
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            updater.automaticallyChecksForUpdates = newValue
            Log.event(.app, "update.autoChecks", ["on": "\(newValue)"])
        }
    }

    var lastCheckDescription: String? {
        guard let date = updater.lastUpdateCheckDate else { return nil }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚检查过" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前检查过" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前检查过" }
        return "\(Int(seconds / 86_400)) 天前检查过"
    }
}

/// 温和提醒代理：只做「声明 + 记账」，不改 Sparkle 的任何决策。
///
/// `supportsGentleScheduledUpdateReminders = true` 是后台 App 的**必填项**：
/// Sparkle 靠它判断「这个 App 自己知道怎么在不抢焦点的情况下提示用户」。
/// 返回 true 让 Sparkle 照常弹它自己的更新窗（在用户主动点菜单时才算"立即焦点"），
/// 我们只把事件写进日志，方便事后从 Console 复盘「为什么不弹/弹了没」。
/// 注意：**不能**整体标 @MainActor —— Sparkle 的 `SPUStandardUserDriverDelegate`
/// 是 Objective-C 协议（非隔离），Swift 6 会报「conformance crosses into main
/// actor-isolated code」。Sparkle 保证这些回调都在主线程调，所以内部用
/// `MainActor.assumeIsolated` 进隔离域打日志（写错隔离就是崩溃，这条是硬约束）。
private final class GentleReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            Log.event(.app, "update.scheduled", [
                "version": update.displayVersionString ?? "?",
                "immediateFocus": "\(immediateFocus)",
            ])
        }
        return true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            Log.event(.app, "update.willShow", [
                "version": update.displayVersionString ?? "?",
                "handledByUs": "\(handleShowingUpdate)",
                "userInitiated": "\(state.userInitiated)",
            ])
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            Log.event(.app, "update.sessionFinished", [:])
        }
    }
}
