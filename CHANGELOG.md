# Changelog

## 2026-11-14 — v0.1 开发首日（M0 骨架 + v0.1 区域截图闭环）

### ✅ 完成
- M0：xcodegen 工程（project.yml 唯一源）、Makefile、os.Logger 结构化日志、托盘、⌘⇧A 全局热键（Carbon，免辅助功能权限）
- v0.1：区域截图闭环（覆盖层蒙层/橡皮筋选区/尺寸角标 → ScreenCaptureKit 截屏 → 像素裁剪 → PNG+TIFF 剪贴板 / 原生保存面板）
- 贴身拖拽源浮窗 Pattern（anchor-following drag-source overlay，照 glance 的 pattern 文档实现）
- 状态栏图标 + AppIcon（蓝底白括号，代码绘制唯一真源）
- AGENTS.md（实机纪律 / TCC 纪律 / 图标管线 / bundle ID 纪律）

### 🕳️ 当天踩坑记录（全部进了 AGENTS.md 防再踩）

**坑 1：qlmanage 转 SVG → 100% 纯白不透明 PNG（排障 ~1h）**
- 现象：菜单栏图标不可见
- 根因：qlmanage 渲染 SVG 产物是全白不透明图（0 个黑色笔画像素），template 渲染下 = 看不见
- 修复：IconFactory 代码绘制（NSBitmapImageRep 显式位图上下文），SVG 只作设计参考
- 教训：外部工具转换的像素产物必须先做像素级验证再上屏

**坑 2：启动即 CGRequestScreenCaptureAccess → 每次启动弹 TCC 授权窗（用户被烦到）**
- 根因：把"会弹窗的申请 API"写进了启动路径
- 修复：preflight 只查不弹（CGPreflight 不弹窗）；CGRequest 只留给用户主动触发的引导流程
- 出处：Glance 2026-09-19 同款病例，没提前看它的代码，重踩

**坑 3：ad-hoc 签名 → TCC 授权每次构建后失效重弹**
- 根因：ad-hoc 签名 cdhash 每次构建都变，TCC 视为新 App
- 修复：构建固定 Apple Development 证书（Makefile SIGN_ID）

**坑 4：bundle ID `com.snapcut.app` 在 LS/TCC 库中损坏 → 状态栏图标零渲染（排障 ~2h，最贵的一坑）**
- 现象：tray.icon.created 日志正常，菜单栏却无任何像素；二进制、图标绘制、代码全对
- 定位：换 bundle ID 对照实验——同一二进制装最小 bundle（com.poc.status）图标正常；只改
  CFBundleIdentifier 为 com.snapcut.app 立即消失；换成 com.snapcut.desktop 恢复
- 根因：坑 2+坑 3 的叠加伤害（几十次 TCC 弹窗反复授权/撤销 + 签名反复变更）把该
  bundle ID 的系统注册记录搞脏（macOS 26）
- 修复：换 bundle ID `com.snapcut.desktop`
- 教训：① 开发第一版就把签名身份和 bundle ID 定死；② "系统说没问题但现象不对"时，
  先做最小对照实验排除系统状态，再怀疑代码
- 排障方法论：像素簇计数会被时钟秒数/天气小组件/录屏指示器污染，不可信；
  可信的是 on/off 像素 diff（排除小组件区）+ 换 bundle 对照实验

**坑 5：xcassets/actool 在本工程中静默不产出（AppIcon 打不进 bundle）**
- 现象：pbxproj 有 Resources 阶段引用，构建却从不调 actool，Assets.car 不存在
- 修复：弃用 xcassets 路线，走经典 CFBundleIconFile + AppIcon.icns（iconutil 生成），
  resources copy 阶段工作正常
- 教训：最小可行链路 > 时髦链路；xcassets 排障成本高时直接退回 icns

**坑 6（小）：调试用例把用户带进"实例空窗期"**
- 用户 18:27:48 退出实例、18:27:52 新实例才起来，中间拍的菜单栏截图当然没图标
- 教训：对照实验要钉死"进程活着"的前提（pgrep + 日志时间戳对齐）
