# Snapcut 技术架构与验证方案（docs/03-architecture.md）

> 版本：v2.0（全文重写，取代 v1.0）｜ 状态：定稿待评审 ｜ 前置文档：01-snowshot-analysis.md、02-product-spec.md（已对齐）
> v1.0 版基于“尽量用 Go”前提（cgo shim + Gio 自绘），该前提已作废。本文为**纯 Swift 单语言单进程**方案。
> 硬约束回顾：① 纯 Swift 单语言单进程，macOS 15+；② UI = SwiftUI + AppKit 混合，边界明确；③ 捕获 = ScreenCaptureKit（`SCScreenshotManager` / `SCShareableContent`，窗口 hover 高亮依赖 `SCWindow.frame`）；④ 不写单测、不做 mock，验证 = 实机跑 + 结构化日志（os.Logger / unified logging，schema 见 §7）；⑤ 里程碑与 docs/02 迭代路线逐期对齐（v0.1→v1.0）。

---

## 0. 结论速览（TL;DR）

| 领域 | 结论 | 关键理由 |
|---|---|---|
| 语言/进程 | **纯 Swift，单进程单二进制**，无任何脚本语言、无 IPC | 全部系统 API（AppKit/SwiftUI/SCK/Carbon）Swift 一等公民，零桥接损耗；TCC 权限归属同一 bundle |
| 最低系统 | macOS 15+ | `SCScreenshotManager`（14+）+ SwiftUI 成熟度 + deployment target 收敛 |
| 工程形态 | **Xcode 工程，由 xcodegen 从 `project.yml` 生成**，CLI 驱动（`xcodegen generate && xcodebuild …`） | pbxproj 不手工维护、可 diff/review；Swift/SwiftUI 必须走 Xcode 工具链，xcodegen 使工程文件成为“产物”而非“源码” |
| 屏幕捕获 | **ScreenCaptureKit**：静态截图 `SCScreenshotManager.captureImage`，窗口枚举 `SCShareableContent`，单窗口 `SCContentFilter(desktopIndependentWindow:)` | 老 `CGWindowListCreateImage`/`CGDisplayCreateImage` 已弃用；`SCWindow.frame` 直接支撑 hover 高亮；未来扩展（如有）无需换地基 |
| UI 分工 | **AppKit**：全屏覆盖层、编辑器画布等自绘窗口（NSView + Core Graphics 直绘）、托盘、贴图窗；**SwiftUI**：工具条、属性 Popover、设置页、首次运行引导 | 自绘场景（透明全屏蒙层、像素级画布）必须 NSView 精确控制；表单/声明式场景 SwiftUI 最快且最原生 |
| 标注渲染 | **Core Graphics 渲染器 = 唯一真相源**：标注模型（几何+样式）→ `CGRenderer` 一处渲染；编辑器画布每帧调用同一渲染器，导出复用同一渲染器 | 编辑器所见 = 导出所得，消灭双后端漂移——标注功能最常见的返工点 |
| 全局快捷键 | Carbon `RegisterEventHotKey`（Swift 封装 ~100 行） | 免辅助功能/输入监控权限；NSEvent global monitor 需要权限，否决 |
| 剪贴板 | NSPasteboard 写 **PNG + TIFF 双表示**（`public.png` + `public.tiff`） | PNG 通用，TIFF 保证 Preview/Pages/Keynote 无损保真 |
| 验证 | **无单测、无 mock**；os.Logger 结构化日志（unified logging）+ 每期实机验证清单 + shell 脚本（`log stream` 断言、osascript 剪贴板校验） | 验收走真机，日志即测试断言的证据链 |
| 权限/分发 | 非沙盒、`LSUIElement`、屏幕录制 TCC 预检引导；开发期 ad-hoc 签名实机跑，发布期 Developer ID + notarytool 公证 + staple | 不上 App Store（Non-goal），沙盒只增加摩擦 |

**对 docs/02 的一处显式对齐说明**：docs/02 将“贴图（钉在桌面）”列为 Non-goal。本文按任务要求保留 **Pin（贴图）模块的架构位置**（§4），但**不排入任何里程碑**（§8），作为“架构已预留、产品观察后再议”的状态，两文档不冲突。

---

## 1. 工程形态决策：xcodegen 管理的 Xcode 工程

### 1.1 决策

用 [xcodegen](https://github.com/yonaskolb/XcodeGen) 以声明式 `project.yml` 生成 `Snapcut.xcodeproj`；工程文件视为构建产物，随时可 `xcodegen generate` 重建，永不手工编辑。

```yaml
# project.yml（骨架示意）
name: Snapcut
options:
  bundleIdPrefix: app.snapcut
  deploymentTarget:
    macOS: "15.0"
settings:
  base:
    SWIFT_VERSION: "5.10"
    MARKETING_VERSION: "0.1.0"
targets:
  Snapcut:
    type: application
    platform: macOS
    sources: [Sources, Resources]
    info:
      path: Resources/Info.plist
      properties:
        LSUIElement: true
        NSHighResolutionCapable: true
    entitlements:
      path: build/entitlements.plist
      properties: {}        # 非沙盒，无 App Sandbox key
```

### 1.2 理由（为什么不是其他）

| 备选 | 否决/采用理由 |
|---|---|
| 手工维护 .pbxproj | 二进制噪声 diff、团队协作灾难、CLI 不可复现。否决 |
| SwiftPM 纯 `swift build` | **无法声明 LSUIElement、entitlements、Info.plist、icon 等 app target 语义**，做不了可双击的 .app（需手工组 bundle，等于重新发明 xcodegen）。否决 |
| Tuist | 能力够但体量重、版本迭代快；Snapcut 单 target 无需其图/缓存能力。xcodegen 足够。否决（超配） |
| **xcodegen** | 单文件 YAML → 确定性工程；`git diff` 友好；生成后 `xcodebuild`/Instruments/SwiftUI 预览全链路可用；社区成熟。**采用** |

### 1.3 CLI 驱动开发流

```
make gen      # xcodegen generate
make dev      # xcodebuild -scheme Snapcut -configuration Debug build + 拷贝到 build/
make run      # 启动 build/Snapcut.app/Contents/MacOS/Snapcut（ad-hoc 签名，终端直跑看日志）
make dist     # Release 构建 → scripts/sign-notarize.sh
```

开发期签名：`CODE_SIGN_IDENTITY="-"`（ad-hoc），实机可跑；TCC 屏幕录制授权以 bundle 为单位，ad-hoc 与正式签名之间切换会重置授权，**验证清单固定用同一构建方式**（见 §9）。

---

## 2. 进程与线程模型

- **单进程**：TCC 权限、剪贴板、托盘、快捷键生命周期与主进程同生共死；Swift `actor`/`MainActor` 取代跨进程协调。
- **主线程铁律**：所有 AppKit 窗口创建/层级操作、NSPasteboard 写入、SCScreenshotManager 调用，均在 `@MainActor` 隔离；`SCShareableContent` 枚举可后台，但结果回主线程消费。
- Swift 并发模型：`AppStateMachine` 为 `@MainActor` 的 ObservableObject；捕获、窗口枚举走 `async` 后台任务；**禁止**在非主线程触碰 NSWindow/NSView——这是崩溃的第一来源，写入 `Sources/Platform/README` 铁律注释。
- 覆盖层窗口池按显示器预建，触发快捷键时只做 show + 抓帧，把“按下→蒙层出现”压进 150ms 以内（§8 v0.1/v0.9 打点验证）。

---

## 3. SwiftUI 与 AppKit 边界（硬边界表）

| 场景 | 技术 | 理由 |
|---|---|---|
| 全屏选区覆盖层（每屏一窗：蒙层/选框/尺寸角标/十字光标/hover 描边） | **AppKit**：NSWindow（borderless、`level = .screenSaver`、透明）+ NSView + CG 直绘 | 透明全屏、跨屏窗口定位、像素级 1px 对齐、鼠标跟踪全在自绘层，NSView 是唯一可靠路径 |
| 编辑器画布（标注图 + 手柄 + 拖拽预览） | **AppKit**：NSView + CG，**每帧调用 CGRenderer** | 画布 = 渲染器输出 + 交互预览叠加，见 §6 |
| 编辑器工具条（6 工具、热键 1–6、色/粗细 Popover） | **SwiftUI**（NSPanel 承载，`NSHostingView` 挂 NSPanel，非激活不失焦） | 声明式小控件最速路径，天然原生质感（P0） |
| 设置页 / 首次运行引导窗 / 保存面板外壳 | **SwiftUI**（NSWindow/NSHostingView） | 表单场景 SwiftUI 最快；NSSavePanel 用 `NSPanel`/`beginSheetModal` 系统原生（R4） |
| 托盘 | **AppKit**：NSStatusItem + NSMenu（模板图标自动适配深浅色） | 菜单交互语义必须 AppKit 原生 |
| 历史列表（菜单栏点开：缩略图 + 时间） | **AppKit**：NSMenu + 自绘 NSMenuItem view（缩略图 NSImage） | 菜单内嵌 SwiftUI 需 hosting 且交互受限，直接 NSView 更稳 |
| 贴图窗（架构预留，当前 Non-goal） | **AppKit**：NSWindow（`NSFloatingWindowLevel`、`isMovableByWindowBackground`）+ NSImageView | 若立项，60 行内可落地，不需 UI 框架 |

**边界总规则**：凡“全屏透明自绘 / 像素级画布 / 窗口层级控制 / 菜单栏” → AppKit；凡“表单、弹出面板、属性控件” → SwiftUI。禁止 SwiftUI 承载覆盖层或画布（性能与层级不可控），禁止 AppKit 手写表单（违背 P0 原生感之外还徒增代码）。

---

## 4. 模块划分与目录结构

```
Snapcut/
├── project.yml                  # xcodegen 源
├── Makefile                     # gen/dev/run/dist
├── Sources/
│   ├── App/                     # main.swift、AppDelegate、AppStateMachine、SceneCoordinator
│   ├── Platform/                # DisplayRegistry（NSScreen 枚举/缓存）、CoordinateConverter、TCCPreflight
│   ├── Capture/                 # CaptureEngine 协议、SCKCapture（SCScreenshotManager）、WindowEnumerator（SCShareableContent）、RegionCropper
│   ├── Overlay/                 # OverlayWindowPool、OverlayView（蒙层/选框/角标）、SelectionGesture、HoverHighlighter
│   ├── Editor/                  # EditorWindow、EditorCanvasView、ToolbarPanel(SwiftUI)、StylePopover(SwiftUI)、KeyboardRouter
│   ├── Annotate/                # AnnotationModel、AnnotationStore（undo/redo）、CGRenderer（唯一真相源）、MosaicPixelator
│   ├── Clipboard/               # ClipboardWriter（PNG+TIFF）
│   ├── Hotkey/                  # CarbonHotKeyCenter、ActionRegistry、ConflictReporter
│   ├── Tray/                    # StatusItemController、MenuBuilder
│   ├── Pin/                     # PinnedWindowController（架构预留，未排期，见 §0 说明）
│   ├── History/                 # HistoryStore（30 条上限）、ThumbnailCache、HistoryMenuProvider
│   ├── Scroll/                  # ScrollCaptureController、Stitcher（v0.6）
│   ├── Export/                  # ExportCoordinator（复制/保存/贴图出口统一调度）、FileNamer
│   └── Logging/                 # Log.swift（os.Logger 封装）、事件常量
├── Resources/
│   ├── Info.plist / AppIcon.iconset
├── build/
│   └── entitlements.plist       # 非沙盒，hardened runtime 基线
├── scripts/
│   ├── make-app.sh / sign-notarize.sh / verify-sign.sh
│   ├── verify-clipboard.sh      # osascript clipboard info 断言 PNGf
│   └── tail-log.sh              # log stream --predicate 'subsystem == "app.snapcut"'
└── docs/
```

### 4.1 状态机（App/AppStateMachine）

```
needPermission ──授权──▶ idle ──热键──▶ overlay(选区) ──松手──▶ annotating(编辑器)
                          ▲  ▲              │Esc                 │Enter/Cmd+S/双击/Esc
                          │  └──(v0.7)delay──┘                    ▼
                          └──────────── exporting(复制/保存/贴图) ─┘ → idle
（v0.6 增加 scrolling 子态；v0.7 增加 delayCountdown 子态；overlay/annotating 任何时刻 Esc 归 idle 且零残留）
```

依赖方向：feature 模块只准向下依赖 Platform/Annotate/Logging；App 层做装配，禁止横向 import（评审硬标准）。

---

## 5. 捕获层（ScreenCaptureKit）

- **静态截图**：`SCScreenshotManager.captureImage(contentFilter:configuration:)`——区域用 `SCContentFilter(filter:excludingWindows:)` 按显示器构造后裁剪；全屏用整显示器 filter。
- **窗口枚举**：`SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` → `[SCWindow]`（frame / owningApplication / layer / windowID），**触发截图会话时一次性预取并缓存**，供 HoverHighlighter 用 `SCWindow.frame` 做鼠标下窗口命中测试与蓝色描边（F2，延迟 <100ms 验收）。单窗口截图用 `SCContentFilter(desktopIndependentWindow:)`。
- **坐标系**：`SCWindow.frame` 与 NSScreen/CG 的原点方向差异是高危坑——换算收敛在 `Platform/CoordinateConverter` **单点**；不靠文档拍板，列入 v0.2 实机专项（§8）。
- **Retina/多屏**：出图宽度 = points × scale，`DisplayRegistry` 维护每屏 scale 缓存；选区像素换算唯一入口。
- 权限被拒：捕获入口先 `CGPreflightScreenCaptureAccess()` 预检，未授权走引导页（SwiftUI），授权后重试 `SCShareableContent`（首次可能仍失败，带重试）。

---

## 6. 标注渲染唯一真相源（CGRenderer）

```
AnnotationModel（struct：Arrow/Rect/Text/Mosaic/Sequence/Highlight，几何+样式，Codable）
        │  存入 AnnotationStore（undo/redo 栈，Cmd+Z / Cmd+Shift+Z，R8）
        ▼
CGRenderer.render(shapes:in:context:scale:)   ← 唯一绘制实现
        │                                │
        ▼                                ▼
EditorCanvasView.drawRect（编辑器所见）   ExportCoordinator → CGImage → PNG/TIFF（导出所得）
```

- **交互预览层**：拖拽中的未确认形状由 CanvasView 叠加绘制（不进 Store）；松手确认后转正式 Annotation 对象进 Store，下一帧即由渲染器统一绘制。
- **马赛克**：`MosaicPixelator` 对底图区域做块平均像素化，结果缓存为位图层（避免每帧重算），参数随模型走；“像素化而非模糊、不可还原”是 F5 验收项。
- **文字**：文本框走系统输入（NSTextField 于画布内联或 SwiftUI Popover 承接），定稿后由渲染器以 `CTLine`/NSAttributedString 绘制，字体随系统。
- **导出**：ExportCoordinator 调同一渲染器按最终画布尺寸重绘 → `NSBitmapImageRep` → PNG（剪贴板+落盘）与 TIFF（剪贴板第二表示）。任何视觉改动只改 CGRenderer 一处。

---

## 7. 验证体系：结构化日志（os.Logger / unified logging）

无单测、无 mock 的补偿：**日志即断言证据链**。所有关键路径必须打点，验收清单逐条对照日志。

### 7.1 基础设施（Logging/Log.swift）

- subsystem：`app.snapcut`；category 按模块：`app / capture / overlay / editor / annotate / clipboard / hotkey / tray / history / scroll / delay / permission / export`。
- 封装 `Log.capture.info("capture.ok", ...)`；敏感字段（窗口标题、保存路径）用 `privacy: .private`，几何/耗时用 `.public`。
- 关键路径加 `OSSignposter` 区间（capture.begin/end、overlay.open/commit），供 Instruments 对照。

### 7.2 事件 schema（每条日志固定结构）

| 字段 | 类型 | 说明 | 示例 |
|---|---|---|---|
| `evt` | String | 事件名，`模块.动作.结果` 三段式 | `capture.display.ok` |
| `ms` | Int | 关键路径耗时 | `142` |
| `displayId` | CGDirectDisplayID | 涉及显示器 | `69731234` |
| `scale` | Double | 像素比 | `2.0` |
| `rectPt / rectPx` | String | 选区几何（points/pixels） | `"100,50,400,300"` |
| `windowOwner` | String（private） | hover 命中的窗口归属 | — |
| `fmts / bytes` | String / Int | 剪贴板表示与字节数 | `"png+tiff", 281232` |
| `err` | String | 失败原因（含 NSCocoaErrorDomain） | `"hotKeyConflict"` |

事件名清单（最小集）：`app.start / app.exit`、`permission.preflight`、`hotkey.registered / hotkey.conflict`、`overlay.open / overlay.commit / overlay.cancel`、`capture.display.ok / capture.window.ok / capture.denied`、`editor.export / editor.undo`、`annotate.tool.select`、`clipboard.write`、`export.save.ok`、`tray.action`、`history.append / history.pruned`、`scroll.begin / scroll.stitch.ok / scroll.fallback`、`delay.start / delay.fire`。

### 7.3 采集命令

```
log stream --level debug --predicate 'subsystem == "app.snapcut"'          # 实时（make run 配套）
log show --last 1h --predicate 'subsystem == "app.snapcut"' --info          # 事后
scripts/tail-log.sh                                                         # 封装 + 事件名高亮
```

---

## 8. 里程碑（与 docs/02 §5 迭代路线逐期对齐）

每期含“新增功能 / 工程产出 / 实机验证清单 / 验收标准”。验证通用基线（每期默认复跑）：macOS 15 实机、双显示器（含 Retina 混合）、Esc 任何阶段零残留窗口、日志链路闭环无 error。

### M0 —— 工程骨架（v0.1 的前置，不对应功能期）
产出：xcodegen 工程、Makefile、os.Logger 基础设施、托盘空菜单、权限引导页、ad-hoc .app 可双击。
验证：`make gen && make dev` 出 .app；双击启动无 Dock 图标（LSUIElement 生效）；`log stream` 出现 `app.start`；首次运行触发 `permission.preflight` 引导页。
验收：干净机器上 ad-hoc 构建 Finder 双击可启动、日志落盘可采集。

### v0.1 —— 区域截图 + 复制/保存双通道（F1 + F4）
产出：状态机 idle/overlay 两态、覆盖层蒙层+选框+尺寸角标、SCKCapture 区域截图、ClipboardWriter、NSSavePanel 保存、热键 ⌘⇧A。
实机验证清单：
1. ⌘⇧A → 蒙层出现（日志 `overlay.open`，`ms` < 150）；拖拽松手 → `overlay.commit`（rectPt/rectPx）→ `capture.display.ok`（pxW/pxH/scale 正确）。
2. Enter → `clipboard.write`（fmts=png+tiff）→ Pages/浏览器/Finder 三处粘贴出图、Retina 2x 清晰；`scripts/verify-clipboard.sh` 断言 `«class PNGf»`。
3. Cmd+S → NSSavePanel 原生弹出 → `export.save.ok`（路径 privacy .private 记录存在性）。
4. 多显示器 + 不同 scale：分别框选，PNG 尺寸 = points × scale，内容对应正确。
5. Esc 于选区中/蒙层上：`overlay.cancel`，无残留窗口（Mission Control 目检）。
验收：冷态按 ⌘⇧A → 框选 → Enter → 粘贴成功，全链路 ≤ 2s；响应 <300ms 无卡顿（日志 ms 统计）。

### v0.2 —— 全屏与窗口截图（F2）
产出：⌘⇧S 全屏、WindowEnumerator + HoverHighlighter（SCWindow.frame 命中 + 蓝描边）、点击选中整窗、`SCContentFilter(desktopIndependentWindow:)` 单窗截图。
实机验证清单：
1. **坐标专项**：hover 高亮框与真实窗口边缘逐像素贴合——主屏 / 副屏 / Retina 外接屏分别实测；错位则在 CoordinateConverter 单点修正并回归。延迟 <100ms（日志 overlay.open 到 hover.firstHit）。
2. ⌘⇧S → 整屏进标注态（复用 v0.1 出口）。
3. hover 点击 → `capture.window.ok`：出图仅含该窗口内容，被遮挡部分为系统底色（SC 特性，目检记录行为）。
4. 菜单栏/壁纸等 layer 窗口命中行为明确（高亮或忽略，记录决策）。
验收：双屏 Retina 下窗口高亮像素级贴合；⌘⇧S 全屏出图 ≤ 300ms。

### v0.3 —— 基础标注：箭头 / 矩形 / 文字（F3）
产出：EditorWindow + EditorCanvasView、CGRenderer 三种形状、工具条（SwiftUI NSPanel）、色/粗细 Popover、AnnotationStore undo/redo、KeyboardRouter（Enter/Esc/Cmd+S/双击）。
实机验证清单：
1. 热键 1/2/3 切换工具（日志 `annotate.tool.select`）；箭头拖拽定向、矩形拖拽定尺寸、文字点击出系统输入框（中英文 + emoji）。
2. **一致性专项**：每种工具标注后 Enter 导出，与编辑器所见逐像素目检（同一渲染器，理论零偏差）。
3. Cmd+Z / Cmd+Shift+Z 连续 20 步：模型与画布一致，`editor.undo` 序列无异常。
4. 双击选区内 = 复制退出（R5）；Esc = 丢弃退出（R4）。
验收：“编辑器所见 = 导出所得”零已知偏差；标注全程零弹窗（R7）。

### v0.4 —— 马赛克 + 工具条定型（F5 + R6 冻结前半）
产出：MosaicPixelator（像素化，两档块大小）、工具条 4 工具定型并预留 2 个扩展位（序号/高亮在 v0.8 补满后彻底冻结）。
实机验证清单：
1. 热键 4，涂抹即打码；放大 4x 目检：块大小两档正确、边缘无偏移、**不可还原**（放大看无原像素信息）。
2. 马赛克撤销/重做正常；与矩形/箭头叠加顺序正确。
3. 打码性能：Retina 大选区涂抹不掉帧（帧耗时打点 <16ms 样本）。
4. 工具条在选区下方放不下时自动翻转到上方（R3）。
验收：打码后无法通过像素还原；工具条布局冻结，新增工具须走评审。

### v0.5 —— 历史记录（F6）
产出：HistoryStore（最近 30 条、超限裁剪）、缩略图缓存、菜单栏 NSMenu 列表、一键清空；每次输出自动入史。
实机验证清单：
1. 每次复制/保存后 `history.append`；第 31 条触发 `history.pruned` 且最早一条移除。
2. 菜单栏点开：缩略图 + 时间原生渲染；点击历史项 = 复制该图到剪贴板（`clipboard.write`）。
3. 历史落盘目录（`~/Library/Application Support/Snapcut/history`）权限正确，一键清空后目录为空且菜单刷新。
4. 重启 app 历史仍在（持久化验证）。
验收：手滑丢图可从菜单栏一击找回；历史零配置（R10）。

### v0.6 —— 滚动长截图（F7）
产出：ScrollCaptureController（选区内驱动滚动 + 定时抓帧）、Stitcher（重合区域去重拼接）、失败回退路径。
实机验证清单：
1. Safari/聊天窗口内触发：`scroll.begin` → 边滚边拼（拼接缩略预览）→ `scroll.stitch.ok` → 结果进标注态。
2. 重合区域去重：拼接缝无重影/错位（不同 DPI 与深浅色窗口各测一次）。
3. **失败回退**：不识别滚动容器 → 明确提示 → `scroll.fallback` → 退回普通截图，绝不卡死、绝不崩溃。
4. 长页（>10000px）内存稳定（Activity Monitor 对比）。
验收：浏览器整页拼接成功率高、缝不可见；失败路径有明确反馈且回退可用。

### v0.7 —— 延迟截图 + 稳定性打磨（F8）
产出：菜单栏 3s/5s 倒计时入口、倒计时原生 HUD、Esc 可取消；全链路性能收口。
实机验证清单：
1. 3s/5s 倒计时 HUD 显示剩余秒数；Esc 取消零副作用；倒计时结束自动进框选（`delay.fire`）。
2. 抓弹层实测：下拉菜单、右键菜单延迟 5s 可截到。
3. 性能回归基线：热键按下→蒙层出现 P95 < 150ms、冷启动→可截图 P95 < 500ms（日志 ms 统计）。
4. 连续 50 次截图-退出循环：无窗口泄漏（内存不单调增长）、无崩溃。
验收：延迟截图覆盖弹层场景；性能基线达标并记录为后续回归参照。

### v0.8 —— 序号标注 + 高亮（R6 剩余两工具）
产出：Sequence（自动递增序号气泡）、Highlight（高亮笔），工具条补满 6 个并**彻底冻结**。
实机验证清单：
1. 热键 5/6 直选；序号从 1 自动递增、跨本次截图会话内连续、样式（色/字号）Popover 可调。
2. 高亮笔半透明叠加、与马赛克/矩形叠加视觉正确；导出与所见一致（复跑 v0.3 一致性专项）。
3. undo/redo 覆盖新工具；Esc/Enter/双击语义不受影响。
验收：6 工具全通过一致性专项；工具条与热键映射冻结。

### v0.9 —— 公测打磨
产出：功能冻结；只修 bug、调手感（框选边缘吸附手感、通知缩略图体验、快捷键说明小窗 R12）。
实机验证清单：
1. 公测机（≥3 台不同硬件/显示器配置）全量复跑 v0.1–v0.8 验证清单。
2. 高频路径打点统计：框选响应、捕获耗时、崩溃率（崩溃日志 via `app.exit` + 系统崩溃报告目录巡检）。
3. R11 专项：与系统 Cmd+Shift+3/4/5 全共存互不干扰；其他常用快捷键 app（输入法/终端）无冲突。
4. 首次运行引导窗一屏三行（R12）验证于全新用户目录。
验收：公测反馈的 P0/P1 bug 清零；手感指标（响应/高亮延迟）达标；功能面零新增。

### v1.0 —— 正式发布
产出：Developer ID 签名 + notarytool 公证 + staple、DMG、版本元数据。
实机验证清单：
1. `codesign --verify --deep --strict`、`spctl -a -vv Snapcut.app` = accepted、`stapler validate` 通过。
2. 公证 DMG 在**未开任何来源、无开发者工具**的干净 Mac 上安装启动，复跑 v0.1–v0.8 关键清单（冒烟集）。
3. 版本承诺验证：安装即用、无账户、无订阅提醒、离线可用（断网跑全流程）。
验收：公证 DMG 为唯一对外发布物；冒烟集全绿。

---

## 9. 权限与分发

- **非沙盒**：不上 App Store（docs/02 Non-goal），entitlements 只保留 hardened runtime 基线；任意路径保存、剪贴板、登录项均无摩擦。
- **Info.plist**：`LSUIElement=true`（菜单栏 agent 应用，无 Dock 图标）、`NSHighResolutionCapable=true`。屏幕录制 TCC 弹窗对 LSUIElement 应用照常工作。
- **屏幕录制 TCC**：启动 `CGPreflightScreenCaptureAccess()` 预检 → 未授权走 SwiftUI 引导页（用途说明 + “打开系统设置” + `CGRequestScreenCaptureAccess()`）+ 2s 轮询预检，授权成功自动进 idle；全程 `permission.preflight` 打点。
- **辅助功能：不需要**——Carbon `RegisterEventHotKey` 免权限（相对竞品的体验优势，产品可强调）。冲突时注册失败 → `hotkey.conflict` 日志 + 托盘菜单置灰提示。
- **剪贴板双表示**：`NSPasteboard.clearContents` → `setData:forType:` 写 `public.png` + `public.tiff`；TIFF 保 Preview/Pages/Keynote 无损，PNG 保通用性。
- **开发期**：ad-hoc 签名（`CODE_SIGN_IDENTITY=-`）实机跑；注意签名身份变更会重置 TCC 授权，验证清单固定同一签名方式。
- **发布期**：`codesign --options runtime --timestamp --sign "Developer ID Application: …"` → `xcrun notarytool submit --keychain-profile snapcut-notary` → `xcrun stapler staple` → DMG 同流程公证。

---

## 10. 风险与回退

| 风险 | 等级 | 对策 / 回退 |
|---|---|---|
| SCWindow.frame 与 AppKit 坐标系差异（Y 方向/缩放） | 高 | 换算收敛 CoordinateConverter 单点；v0.2 专项实测三屏形态，错位即修单点后回归 |
| SCShareableContent 预取慢导致 hover 高亮超 100ms | 中 | 会话触发时后台预取 + idle 期预缓存；日志 ms 打点定位 |
| SwiftUI 工具条 NSPanel 失焦/层级问题 | 中 | NSPanel `nonactivatingPanel` styleMask + `level` 与编辑器窗协调；若不可行回退 AppKit NSView 工具条（自绘 ~200 行） |
| 画布内文字 IME 体验不佳 | 中 | 优先系统输入路径；回退方案：文字工具临时弹原生 NSTextField 小窗（AppKit），定稿后仍由 CGRenderer 渲染 |
| Carbon hotkey 未来被移除 | 低 | 快捷键只在 Hotkey 模块一层，可换 NSEvent global monitor + 权限引导；当前 macOS 15 完全可用 |
| 非 CGRenderer 双后端漂移（如临时在 CanvasView 手绘形状） | 中 | 评审硬规则：CanvasView 禁止出现形状绘制逻辑，只调渲染器 + 交互预览叠加；code review 检查项 |
| 滚动截图拼接质量（F7 是第一重量级功能） | 高 | v0.6 独立成期专门打磨；失败回退普通截图是产品承诺，不做“硬拼” |
| 无单测导致回归靠人工 | 中（既定约束） | os.Logger 打点 + 每期可复跑实机清单 + scripts/*.sh 断言 + OSSignposter/Instruments 兜底；v0.7 建立性能基线 |
| TCC 授权在 ad-hoc ↔ Developer ID 切换间重置 | 低 | 验证清单固定签名方式；文档化提醒 |
| 未来上 App Store（需沙盒） | 低 | 明确不上架；届时专项评估 RegisterEventHotKey / 剪贴板 / 任意路径在沙盒下行为，另行立项 |

---

## 11. 附录：环境基线

- macOS 15+（开发机 15.x），Xcode 16+（Swift 5.10 工具链、SwiftUI/SCK 全量可用）。
- xcodegen ≥ 2.4；`make gen` 后 `Snapcut.xcodeproj` 不入 git（.gitignore），`project.yml` 是唯一源。
- 直接依赖：**零第三方运行时依赖**（Swift 标准库 + 系统框架：AppKit、SwiftUI、ScreenCaptureKit、CoreGraphics、Carbon（仅 HOTKEY 胶囊头）、AVFoundation（如 v0.6 需要））。
- 发布物：公证 DMG；承诺安装即用、无账户、离线可用（docs/02 v1.0 承诺）。

---
