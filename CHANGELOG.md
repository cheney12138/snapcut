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

## 2026-11-14（晚）— v0.2 标注编辑器 + 滚动截图 + 设计原型（并行开发）

### ✅ 完成
- **v0.2 标注编辑器**：选区松手即冻结底图 → 玻璃工具栏（6 工具：箭头/矩形/文字/马赛克/序号/高亮，
  热键 1-6 直选，5 色 3 粗细，undo/redo）→ Enter 复制/⌘S 保存/Esc 取消/双击复制。
  **工具栏永不入图**（底图在工具栏出现前冻结——需求「截图时隐藏工具栏」的架构级解法），H 键隐藏工具栏。
- **滚动截图（v0.6 提前）**：S 键进入 → 手动滚动 + 400ms 抓帧 → Enter 拼接 → 导出；
  静止画面退化输出首帧（产品承诺：不卡死、明确回退）。
- **设计原型**（DeepSeek 设计 agent 并行）：`~/work/project/html-pages/snapcut-design/index.html`
  Apple 玻璃质感 8 场景交互原型 + 7 张自验截图。
- **e2e 自动化验证体系**：CGEvent 注入真实键盘/鼠标/滚动事件 + ScrollHost 滚动宿主窗口，
  全链路无人值守验证（不是 mock，全部真实管线）。

### 🕳️ 踩坑记录

**坑 7：make dev 构建失败仍显示 "ready"（rsync 无保护）**
- xcodebuild 失败 → tail 吞掉错误行 → rsync 把旧产物复制出去 → 屏幕上跑旧代码
- 修复：tee 完整日志 + grep BUILD SUCCEEDED 挡板；**新二进制用 strings 验证特征字符串**

**坑 8：编辑态键盘丢失（appActive=false + keyWin=nil）**
- 病例：ToolbarPanel 创建后 App 失活，无激活态窗口无法成为 key → Enter/Esc 全丢
- 修复：editor.enter 后 activate + makeKeyAndOrderFront + makeFirstResponder（延后一个 runloop tick）

**坑 9：SCK 返回分辨率与 NSScreen 物理像素不匹配（BetterDisplay/虚拟分辨率）**
- 病例：3456×2234 物理的屏，SCK 整屏图实测 1920×1080（不是 nominal 也不是 exact 能救的）
- 根因：backingScale 假设在虚拟分辨率模式下失效
- 修复：CoordinateConverter 一律用「实际图尺寸 ÷ 屏幕 point 尺寸」实测比例；EditorSession.scale 同理

**坑 10：滚动事件被覆盖层挡住（产品级 bug，不是测试问题）**
- 病例：滚动模式下用户滚鼠标 → 事件给 key window（我们的覆盖层）→ 底下内容不动 → 永远拼接失败
- 修复：scrollMode 时覆盖层 ignoresMouseEvents=true（事件穿透）

**坑 11：滚动收尾键盘收不到（焦点在别的 App）**
- 病例：滚动时焦点回到被滚动 App，Enter 普通键路径失效
- 修复：Enter/Esc 用系统级 Carbon 热键动态注册（会话期注册/结束注销）

**坑 12：CarbonHotKeyCenter 多实例（-9866 + 派发表查错实例）**
- 病例：滚动热键 new 了第二个实例 → InstallEventHandler 重复安装报 -9866，
  且事件派发查的是第一个实例的表 → 热键注册成功但永远不触发
- 修复：单例化（CarbonHotKeyCenter.shared）

**坑 13：Stitcher 默认容差在真实滚动帧上过严**
- 病例：真实帧（抗锯齿+滚动条+子像素位移）在正确对齐处行差 17-23，默认 threshold 16 + 2% 不匹配率直接误判
- 修复：threshold 24 + 10%（合成图与真实帧双验证）；同时修掉合成负向用例的伪对齐
 （行纯色页面在整数 seed 下只是行相位偏移——seed=7 ⇒ 伪重叠；改为反转色页）
