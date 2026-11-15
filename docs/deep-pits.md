# 深坑病历（macOS 平台行为）

按需加载：AGENTS.md 只留触发索引，本文档是全文。改 macOS 平台行为相关代码前先读对应条目。
坑 1-25 的完整病历在 CHANGELOG 提交信息里（病例体：现象/证据/根因/否掉了什么）。

## 坑 33：CC 驱逐连坐终止（官方文档实锤）

MenuBarExtra 官方原文（`documentation/swiftui/menubarextra.json`）：

> "An app that only shows in the menu bar will be **automatically terminated**
> if the user removes the extra from the menu bar."

- CC（ControlCenter）对 status item 发隐藏动作时，AppKit 触发连坐终止——
  这不是 bug，是官方设计。我们的 `applicationShouldTerminate` 一律 Cancel +
  显式退出放行（`SnapcutQuitController.quit()` 热标记，UserDefaults 键
  `app.quit.allowed`）是对抗官方设计的代价方案。
- 官方正解候选：`.window` style + LSUIElement（数据丰富的 extra 用 popover 窗）。
  若图标/终止问题再发，优先评估迁移而不是继续打补丁。
- 降级形态：拦截生效后 App 永活但 item 被 CC 藏掉（图标消失 App 活着）——
  见坑 34。

## 坑 34：bundle id 被 CC 状态污染（图标持续被逐，2026-11-15）

- 现象：坑 33 拦截生效后，CC 对 `app.snapcut.macos` 的 item 在 ~1 分钟内
  反复驱逐（重启即回、随即再消失）。对照实验：同机全新 id（mb6 demo）
  的 item 稳定 → CC 对该 id 的注册/驱逐决策模型被几十次循环写坏，代码侧无解。
- 修复：换 id `app.snapcut.snapcut`（第五迁）。
- **id 迁移史**：dev.snapcut.app → dev.snapcut.app2 → com.snapcut.app →
  com.snapcut.desktop → app.snapcut.macos → **app.snapcut.snapcut（现行，
  TCC 已授权，2026-11-15 起不再动）**。
- 教训：换 id 后停手所有 LS/TCC/CC 折腾，让系统状态安定。

## MenuBarExtra `.menu` 快照刷新（2026-11-15 实锤）

- `.menuBarExtraStyle(.menu)` 的 content 是一次性快照：SwiftUI 转 NSMenu 后
  **不再重求 body**（onAppear/轮询改 @State 全部无效，tray.menu.built 日志
  一条不出现为证）。
- 动态切菜单形态（如授权门禁两项 ↔ 完整菜单）的唯一可靠路径：
  `@AppStorage`（官方定义："invalidates a view on a change in value in that
  user defaults"）。实现：权限状态镜像到 `app.perm.granted` 键，
  `AppCoordinator.syncPermissionMirror()` 翻转时写入。
- 未授权门禁语义（用户三次重申后落地）：无权限时菜单只剩「去授权…」+
  「退出」；快捷键不进截图流程直接弹引导卡（`ensureCaptureReadiness()`）。

## TCC 授权流程（2026-11-15 定稿）

- 「去授权」两个入口（引导卡 + 托盘菜单）统一语义：触发 CGRequest（让 App
  出现在列表）+ deep link 直开 系统设置→隐私与安全性→录屏 + 浮窗待命。
  **不依赖 TCC 确认框**（tccd 对反复弹过的 id 会吞框，用户点了没反应）。
- deep link 正确格式：`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
  （写错成 `system.preferences` 会弹「未设定应用程序」错误框）。
- 授权开关已开但进程未重启的窗口期：再触发截图 SCK 会再请求 → TCC 又弹。
  防弹闸：`permission.request` 后 5 分钟内截图触发改为通知提示「重启生效」。
- 屏幕录制授权必须重启进程才生效（`CGPreflightScreenCaptureAccess` 在旧
  进程恒 false）。

## 官方文档拉取接口（免登录）

```
curl -sL "https://developer.apple.com/tutorials/data/documentation/<path>.json"
```

例：`swiftui/menubarextra`、`appkit/nsstatusitem`、`swiftui/appstorage`。
正文在 `primaryContentSections` / `abstract`，type=text 的节点。
macOS 平台行为类问题先拉文档再动手，不要纯靠试。
