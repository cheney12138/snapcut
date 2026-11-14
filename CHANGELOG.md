# Changelog

## 2026-11-14 — 视觉收口轮（工具栏重做 / 状态栏图标 / 提示条）

### 🕳️ 病例

**坑 26：工具栏做成了文字按钮，跟设计真源（HTML 原型）完全不是一个东西**
- 现象：用户实拍对比原型 —— 原型是 SF Symbols 图标 + 玻璃胶囊，实机是「箭头 矩形 文字…」文字标签
- 根因：原型定稿后没做「设计值 → AppKit 实现值」的对照表，凭印象写控件
- 修复：按 `.toolbar/.tb-btn/.tb-colors/.tb-widths/.tb-primary` 逐条移植（尺寸、圆角、透明度、阴影、hover 位移）
- 纪律：**任何界面元素落地前先列 CSS 值对照表**，交付时附对照表 + 真机截图

**坑 27：编辑器长提示条压住工具栏按钮（"对齐在哪"）**
- 现象：`Snapcut · 框选完成，可直接标注…` 黑色长条盖在工具栏上，按钮被挡
- 根因：提示条与工具栏各自定位，没有互斥规则；原型 scene 03 根本没有这条提示
- 修复：删除长提示（快捷键教学归设置面板/首启引导）

**坑 28：状态栏图标"消失"——其实是菜单栏拥挤被系统挤到不可见区**
- 诊断：`tray.icon.created img=20x20 visible=true` 正常，但 `button.window.frame = x:1690 y:1095 w:38`
  （屏幕 1728 宽）⇒ 和时钟区重叠，即被系统判为放不下而隐藏
- 试过无效：`autosaveName`、`behavior = .removalAllowed`、`withLength: 24`（frame 仍 38-40）、
  +1.2s 重断言 `isVisible = true`
- 结论：macOS 菜单栏空间不足时应用无法强制占位；产品兜底 = 检测隐藏 + 一次性 toast 告知
  「⌘⇧A 仍可用」

### ✅ 同时完成
- 复制反馈 toast（原型右下角卡片：缩略图 + 已复制到剪贴板 + W × H · PNG，2s 淡出，不抢焦点）
- 尺寸角标改原型样式（`452 × 323 @2x` 黑胶囊 11pt semibold）
- 快速保存 ⌘⌥S（免面板直落设置目录，文件名规则走设置）
- 选区 Shift 锁 1:1、取色器 C 键（hex 写剪贴板）

---

## 2026-11-14 — 功能面扩张（Snow Shot 对标）+ 六边形架构

### ✅ 完成
- **读 Snow Shot 源码**（C++/Qt/Rust）提炼 5 份功能规格（docs/research/01~05，全带 file:line 证据）
- **核心功能约束**（docs/04）：8 项能力覆盖 80% 场景 + 接口契约 + 验收标准
- **F2 全屏 / 窗口截图**：⌘⇧S 全屏、悬停命中窗口高亮（蓝描边 + 白底深字角标）、单击整窗、双击全屏
- **先冻结再选区**（Snow Shot 主流程）：拍完所有显示器（~82ms）才上覆盖层 ⇒ 覆盖层结构上不可能入图；
  松手用冻结帧本地裁剪，零延迟进编辑态
- **选区可反复调整**：8 向手柄改尺寸、空格整体移动、方向键 1pt/Shift 10pt 微调；
  改完从冻结帧重裁底图 + 标注平移（钉在屏幕原位置）
- **放大镜取色**：11×11 源像素 @12×，中心像素描边 + 坐标/色值，离线采样冻结帧
- **历史记录 / OCR 取字 / 贴图 Pin**：三个并行子模块（1065 行），按端口接线；
  工具栏「取字 O」「贴图 P」，任何导出都写历史，托盘历史子菜单
- **设置面板**：通用/快捷键/关于三个 tab，设置真正生效（热键解析、历史上限、默认动作）
- **六边形架构**：Core（Domain/Ports/Shared）/ Adapters / UI / App 分层 + 7 个端口 +
  `scripts/check-architecture.sh`（make dev 强制，破坏即失败）

### 🕳️ 本轮病例（新坑）

**坑 17：SCStreamConfiguration 默认输出 1920×1080 ⇒ 截图模糊（用户实报"截完变模糊/有蒙层"）**
- 根因：SCStreamConfiguration.width/height 默认 1920/1080（SCStream.h 头文件实锤），整屏被降采样
- 加深坑：CGDisplayPixelsWide 在缩放模式返回"当前模式像素"(1728) 而非面板物理像素(3456)
- 修复：`config.width = screen.frame.width * backingScale`
- 验证：导出 1400×400 vs screencapture 同区域，平均亮度差 0.0103、显著差异 1.26%

**坑 18：编辑器预览底图竖向颠倒**
- 根因：CGContext.draw 假设 Y-up，而 isFlipped 视图上下文是 Y-down ⇒ 底图二次翻转
- 修复：局部 translate+scale(1,-1) 镜像后再 draw，且用像素尺寸矩形（NSImage.draw 会按 point 尺寸重采样 ⇒ 模糊）

**坑 19：无鼠标点击的入口（⌘⇧S）App 不激活 ⇒ Enter/Esc 全丢**
- 现象：全屏截图进编辑态后键盘彻底失效（frontmost 仍是别的 App）
- 根因：区域路径靠真实点击激活，掩盖了 NSApp.activate 在 Carbon 热键回调里可能被忽略
- 修复：ensureActivation() 每 60ms 重试（最多 3 次，含 NSRunningApplication.activate）

**坑 20：拖手柄调整选区后 App 失去激活 ⇒ 编辑器"僵死"**
- 修复：reclaimKeyboard()（activate + makeKey + makeFirstResponder + 端口级 ensureActivation）

**坑 21：NSColor.labelColor 在 dark appearance 下解析成白色 ⇒ 白底胶囊里画白字不可读**
- 修复：角标固定 `NSColor(calibratedWhite: 0.12, alpha: 1)`

**坑 22：改用「点击时 popUp 菜单」后 buildMenu() 调用丢失 ⇒ 托盘点击毫无反应、历史菜单永远空**
- 现象：状态栏图标点了没反应；selfTestDumpHistoryMenu 静默返回（historyMenu == nil）
- 教训：替换 `item.menu = buildMenu()` 这类"顺带调用"时，必须显式保留副作用

**坑 23：OCR 结果面板 .floating 被覆盖层（.screenSaver）压住 ⇒ 用户完全看不到识别结果**
- 修复：同级 .screenSaver + orderFrontRegardless + makeKey

**坑 24：多实例（worktree 构建）同时运行 ⇒ unified log 混流 + Carbon 热键被抢，验证结论全错**
- 现象：明明逻辑对，Enter 就是不生效；日志里冒出没见过的事件（settings.window.open）
- 纪律：每次真机验证前 `pkill -9 -f Snapcut`，并 `ps aux | grep Snapcut` 确认只剩一个实例

**坑 25：OCR 对低对比度/深色背景文字识别率明显下降**
- 实测：亮部文字（`cd ./snapcut && python3 - <<'PYEOF'（+88 Lines）`）一字不差；
  暗历史行出现 `Hppwooraznacoronared` 这类误读
- 试过无效：反相、放大 2x、automaticallyDetectsLanguage —— 无改善
- 结论：Vision 已知特性，暂记为限制（不是管线问题，已用同区域 screencapture 对照排除）

### 📌 架构与纪律增补
- 新代码端口优先：先定义 Core/Ports，再写 Adapters，UI 只拿端口
- 并行子任务用 worktree 隔离；**worker 不会自动 commit**，主会话需从 worktree 目录搬运文件
- 子任务契约里要显式给 LogCategory 现有 case，否则 agent 会造垫片（已在并入时清理）

---

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
