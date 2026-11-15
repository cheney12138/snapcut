import SwiftUI

/// 入口（SwiftUI 生命周期）
///
/// 坑 29（菜单栏图标三重根因，真机全验证）：
/// 1. macOS 26 (Tahoe) 菜单栏由 ControlCenter 接管，手写 NSStatusItem 会被排进
///    「虚拟停车位」（frame 存在但 onScreen=false；20 行最小 App / 全新 autosaveName
///    均复现）。SwiftUI MenuBarExtra 路径畅通（同机 glance 同款，A/B 实测剪刀图标
///    显示在 x≈1170pt）。
/// 2. 更狠的是 **bundle id `dev.snapcut.app` 本身被系统记死**：同二进制换 plist
///    里的 bundleId → SwiftUI run loop 正常存活 + 图标显示；不换 → 启动即
///    exit(0)（NSStatusItem 时代反复 pkill×20+ 把 LS/TCC/CC 的 per-app 状态写坏，
///    病例链：坑 4 曾换过一次 id，同一灾难二次复发）。故本次换 `dev.snapcut.app2`，
///    TCC 屏幕录制权限需重新授权一次（onboarding 引导会接住）。
/// 3. 托盘菜单内容因此切 SwiftUI（TrayMenuContent），NSMenu 版保留在
///    StatusItemController 服务 ⌥⌘H 光标兜底。
@main
struct SnapcutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            TrayMenuContent()
        } label: {
            // 品牌标记剪影（IconFactory 同源，template 渲染 = 跟随菜单栏明暗；
            // 15pt = 比系统默认 18 略小一圈，视觉与相邻系统图标更协调）
            Image(nsImage: IconFactory.statusIcon(pointSize: 15))
        }
        .menuBarExtraStyle(.menu)

        // 坑 33（启动即退·第四形态实锤）：MenuBarExtra-only + LSUIElement 的
        // SwiftUI App 无窗口场景时 run loop 自动结束（对照：mb2 demo 与本 App
        // 在同一时间一起死，同新 id 的 mb6 活——并非 id 记死，是场景生命周期）。
        // glance 同机常活的场景结构 = MenuBarExtra + 常驻 Window 场景。
        // 这枚窗口永不显示，只为让 SwiftUI 场景组保持「有潜在窗口」。
        Window("Snapcut", id: "keepalive") {
            EmptyView()
        }
        .windowResizability(.contentSize)
    }
}
