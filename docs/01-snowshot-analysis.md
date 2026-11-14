# Snow Shot 源码分析 → Snapcut 功能取舍建议

> 分析对象：https://github.com/mg-chao/snow-shot（GPL-3.0，C++/Qt + Rust，Windows x64/ARM64 + macOS 15+）
> 分析时间：2025 年，基于仓库快照。行数为 `wc -l` 统计（.cpp/.h/.mm/.rs/.ts）。
> 结论先行：Snow Shot 是一个"全家桶"级截图套件（全仓库 80 万+ 行），其复杂度主要不是来自"截图"本身，而是来自**贴图（Pin to screen）、OCR/识别/翻译、录屏后期、自研 UI 框架与绘图引擎**四大子系统，以及 Windows/macOS 双平台 × 完整版/Mini 版的矩阵。Snapcut 若定位"极简、贴 macOS 原生、顺手"，应只取其截图+标注+贴图的内核（约占其代码的 1/4），其余全部砍掉。

---

## 0. 仓库全景与代码规模

```
snow-shot/
├── snow_shot/            # 主应用（GPL-3.0）  src ≈ 276k 行 + include 41k + tests 344k
│   └── src/
│       ├── presentation/ # 217,909 行 ← 巨无霸，所有 UI 与业务都在这层
│       ├── platform/     #  16,358 行  windows/ 与 macos/ 双后端
│       ├── storage/      #  14,944 行  配置/历史/贴图仓库/导出变量
│       ├── app/          #  14,757 行  启动、生命周期、MCP、账号、翻译服务
│       ├── image/        #   4,666 行  图片编解码桥接
│       ├── network/      #   2,824 行  在线服务客户端/翻译协议
│       ├── update/       #   1,824 行  自更新服务
│       ├── diagnostics/  #   1,809 行  崩溃采集、FFmpeg 诊断
│       └── shortcuts/    #   1,069 行  快捷键绑定模型
├── ant_design_qt/        # 190,039 行  自研 Ant Design 风格 Qt 组件库（Apache-2.0）
├── snow_draw_engine_qt/  # 214,994 行  自研 Canvas 绘图引擎（标注渲染核心）
├── snow-crates/          # 229,641 行  Rust 原生服务（31 个 crate）
│   ├── snow-capture/         60k  # 屏幕/窗口捕获（DXGI Duplication / WGC / GDI / ScreenCaptureKit）
│   ├── snow-recording-export/36k  # FFmpeg 封装导出（MP4/GIF/APNG/WebP，HEVC 硬编）
│   ├── snow-recording-runtime/28k # 录屏运行时（音频混音、鼠标跟随、webcam）
│   ├── snow-stitch-images/  15k   # 滚动截图拼接
│   ├── simd-paddle-ocr-rs/  submodule # 本地 PaddleOCR（GPU 可选）
│   └── …（selected-text / ui-selector / visual-region-detector / webcam / audio-recorder…）
├── snow_image/ (35k) + snow_image_viewer/ (24k) + snow-image-rs/ (27k)  # 独立看图器产品
├── snow-draw-engine-gpui/ # 40k 行  GPUI 版绘图引擎实验（未用于主产品）
└── snow_rust_ffi/ / cmake/ / scripts/  # 构建粘合
```

**规模判断**：仅主应用 `snow_shot/src` 就 27.6 万行、700+ 源文件；加上配套库全仓库超 80 万行、测试 34 万行。这不是个人项目体量能长期维护的形态——它有专职的工程规范（AGENTS.md、严格翻译流程、性能基准脚本、NSIS/MSIX/Store/DMG/Homebrew 五套分发），本质上是一个小团队的商业级产品（含会员/账号体系）。

---

## 1. 完整功能清单（含用户价值与入口）

### 1.1 截图（capture/）
| 功能 | 用户价值 | 入口交互 |
|---|---|---|
| 区域截图 | 最核心场景，框选屏幕任意区域 | 全局快捷键（默认 Print 类）、托盘菜单、悬浮工具条 |
| 窗口/焦点窗口截图 | 智能识别窗口边界，免手动对齐 | 框选时悬停自动高亮窗口；快捷键 `ScreenshotFocusedWindow` |
| 全屏/当前显示器截图 | 一键整屏 | 全局快捷键 `ScreenshotFullScreen` |
| 延时截图 | 抓弹层、下拉菜单等需要延迟出现的画面 | 快捷键 `ScreenshotDelay`，倒计时提示 |
| 滚动长截图 | 聊天记录/网页整页 | 快捷键 `ScreenshotScrolling`；选区内滚轮驱动 + 自动滚动，实时拼接缩略图预览，支持左右滚动、拼接后裁剪 |
| 重复截图/历史恢复 | 最近截图快速复用 | 截图历史页 + `OpenCaptureHistory` |
| 智能选区 | 自动吸附 UI 元素边界 | 选区时的 `smart_selection`（Rust `snow-ui-selector` / `visual-region-detector`） |
| 取色器 | 从屏幕取色 | 截图画布内取色窗口 `screenshotcolorpickerwindow` |

**实现位置**：`src/presentation/capture/`（7.8k 行）+ `src/presentation/overlay/`（13.6k 行，全屏遮罩选区窗口池）+ `src/presentation/selection/`（7k 行，选区几何/调整/导出流）+ `src/presentation/selector/`（1k 行，工作流调度）+ Rust `snow-capture`（60k 行）。合计 ~90k 行。
**复杂度：★★★★☆**。多显示器 DPI、窗口吸附、后端自动降级（DXGI→WGC→GDI）、macOS ScreenCaptureKit 权限链，都是硬骨头；滚动截图另有专门的诊断文档（`SCROLLING_DIAGNOSTICS.md` 事件表）说明其调试难度。

### 1.2 标注（tools/ + snow_draw_engine_qt）
| 工具（Tool 枚举共 33 项） | 用户价值 | 入口 |
|---|---|---|
| 矩形/椭圆/直线/箭头/画笔 | 基础标注 | 截图画布工具栏 |
| 文字、序号（步骤标记）、语音气泡、括号 | 讲解型标注 | 同上 |
| 马赛克（矩形/笔刷）、模糊（RectangleFilter/BrushFilter）、聚光灯 Spotlight | 隐私保护 | 同上 |
| 高亮 Highlight / 笔刷高亮 / 放大镜 Magnifier / 橡皮（矩形/笔刷） | 修饰 | 同上 |
| 距离 Distance、角度 Angle 测量 | 工程/设计场景 | 同上 |
| 水印 Watermark | 版权 | 同上 |
| 填充色/描边样式预设、样式控件 | 快速统一样式 | 工具样式面板 |

**实现位置**：`src/presentation/tools/`（29.4k 行，工具面板+命令流）+ `snow_draw_engine_qt`（215k 行绘图引擎，Canvas/SnowCanvasWidget/渲染运行时）+ `src/presentation/core/`（3k 行）。
**复杂度：★★★★★**（对自建引擎而言）。若复用 Qt QPainter/Skia 类现成方案可降到 ★★★。这是 Snow Shot 最重的自研资产，标注性能和 DPI 一致性全靠它。

### 1.3 贴图 / Pin to screen（pinned/ + services/pinned*）
| 功能 | 用户价值 | 入口 |
|---|---|---|
| 截图贴图 | 参考内容置顶悬浮，对照抄写 | 截图工具栏"贴图"按钮、快捷键 `ScreenshotPinToScreen` |
| 剪贴板/文件贴图 | 免打开看图器 | 快捷键 `PinClipboardContent` / `PinSelectedFiles`（批量） |
| 实时窗口贴图 Live window | 贴一个"活的"窗口，内容随源窗口更新 | 贴图右键菜单（Rust live-window 捕获 + `livewindownative`） |
| 贴图标注/文字/裁剪/缩放 | 二次加工 | 贴图窗口内工具 |
| 贴图分组/切换/全部隐藏显示/一键藏到顶 Hide-to-top、还原窗口组 | 管理多张贴图 | `WindowGroupSwitcher`、`HideShowAllWindows`、`RestoreLastClosedWindows` |
| 摇一摇手势、点击穿透、颜色样本、批量保存、置顶层级协调 | 高级交互 | 各自独立控制器 |
| 贴图 OCR / 贴图翻译 | 对贴图内容直接识别 | 贴图菜单 |

**实现位置**：`src/presentation/pinned/`（23.8k 行）+ `src/storage/pinnedwindowrepository.cpp` + `src/presentation/services/`（pinnedwindowgroupmanager、historypinplacement、pinnedcolorswatch 等）+ `src/platform/{windows,macos}/pinnedwindow*.mm`。合计 ~35k 行。
**复杂度：★★★★★**。窗口层级（点击穿透/置顶/失焦表现）、跨平台窗口管理、实时窗口流、可恢复会话仓库，是全仓库状态机最密集的模块之一，且有 10+ 个专门性能基准。

### 1.4 文字识别与转换（ocr/）
| 功能 | 用户价值 | 入口 |
|---|---|---|
| 本地 OCR 提取文字（PaddleOCR，离线） | 隐私安全、免费 | 截图工具栏 OCR 按钮、快捷键 `ScreenshotOcr` / `ScreenshotOcrCopy` |
| 识别结果编辑（文本布局重排、校对） | 直接可用 | 识别窗口 `screenshotrecognitionwindow` |
| 表格识别 → 可编辑表格 | Excel 场景 | 工具栏 Table 按钮 |
| 二维码识别 | 解码 | 工具栏 QR 按钮 |
| 转 Markdown / HTML / LaTeX（含 LaTeX 渲染器） | 笔记/文档场景 | 图像转换控制器 |
| 在线翻译（截图翻译、划词翻译、独立翻译窗口） | 多语言阅读 | 快捷键 `ScreenshotTranslation` / `TranslateSelectedText`，依赖配置的在线服务 |
| OCR 前景/背景识别、原图片预览对照 | 体验细节 | — |

**实现位置**：`src/presentation/ocr/`（22.8k 行）+ Rust `snow-ocr-process`、`simd-paddle-ocr-rs`（submodule）+ `src/app/translationlanguagedetector` + `src/presentation/services/selectedtexttranslation*`。合计 ~30k 行。
**复杂度：★★★★☆**。本地模型分发（OCR 资源按需下载清单）、六种导出格式转换、翻译协议适配，链条长。

### 1.5 录屏（recording/ + snow-crates/recording-*）
| 功能 | 用户价值 | 入口 |
|---|---|---|
| 区域录屏（MP4） | 演示操作 | 快捷键 `ScreenRecord` / `ScreenRecordCopy`、工具栏录制按钮、倒计时 |
| 跟随鼠标录制 | 聚焦光标区域 | 录制配置项 Follow mouse（平滑移动/减抖动） |
| 摄像头画中画、系统声音/麦克风（增益调节） | 教学录制 | 录制配置弹层 |
| 录制效果（鼠标高亮/点击效果等） | 教学观感 | Effect 选项 |
| 录制暂停/恢复、崩溃恢复 | 长录制安全 | 录制工具条 |
| 剪辑：裁剪 Trim + 0.25x–3x 变速 | 免第三方剪辑 | 录制完成后进入 trim 界面 |
| 导出 MP4(H.264 硬编/H.265 软硬编)/GIF/APNG/WebP | 多场景分发 | 导出对话框 |
| 录制文件夹快捷打开 | 整理产物 | 快捷键 `OpenScreenRecordingFolder` |

**实现位置**：`src/presentation/recording/`（11.3k 行 UI/几何/裁剪）+ Rust `snow-recording-runtime`(28.5k)、`snow-recording-export`(36k)、`snow-recording-effects`(11k)、`snow-screen-recorder`、`snow-audio-recorder`、`snow-webcam` + FFmpeg。合计 ~90k 行。
**复杂度：★★★★★**。整个录屏管线（捕获→组合→编码→封装→恢复→剪辑）是独立的重型工程，FFmpeg 硬件编码协商文档（`docs/recording-hevc.md`）就能看出门槛。

### 1.6 图片工具（杂项独立窗口）
| 功能 | 用户价值 | 入口 |
|---|---|---|
| 图片拼接 Collage（含 PDF 网格导出、模板） | 多图合一 | 快捷键 `StitchSelectedImages`、托盘 |
| 图片分割 Split（智能布局） | 拆长图 | 快捷键 `SplitSelectedImages` |
| 图片编辑器 Image Editing（编辑已有图片、智能擦除） | 二次加工已有图 | 主窗口 / 文件关联 |
| 全局画布 Global Canvas（全屏涂鸦讲解 + 激光笔） | 会议讲解 | 快捷键 `GlobalCanvas` |
| 独立看图器 snow_image_viewer | 产品附属 | 独立可执行 |

**实现位置**：`collage/` 10.2k、`imagesplit/` 5k、`imageediting/` 3.6k、`globalcanvas/` 1k（+绘图引擎）。
**复杂度：★★★☆☆**。每个都是独立窗口+文档模型+导出管线，互相独立但都依赖绘图引擎。

### 1.7 系统集成 / 生态
| 功能 | 用户价值 | 入口 |
|---|---|---|
| 全局快捷键系统（31 个可配置动作，分组：截图/贴图/录屏/其他） | 效率核心 | 设置首屏"全局快捷键"页 |
| 全局鼠标（组合键触发截图动作） | 快捷键的补充 | 设置"全局鼠标"页 |
| 托盘菜单（截图/录屏/贴图/工具入口、气泡通知） | 常驻入口 | 系统托盘 |
| 悬浮工具条 Floating toolbar（可拖拽、自动隐藏） | 免记快捷键 | 桌面常驻 |
| Windows 右键菜单集成（Shell 扩展 DLL） | 文件级入口 | 安装器注册 |
| Explorer 命令/文件管理器集成、打印、AirDrop(macOS)、邮件 | 导出通道 | 导出面板 |
| 截图历史（保留策略/压缩/磁盘上限/自动清理） | 管理 | 历史页 + 导出存储设置 |
| 云上传（S3 协议）、账号/会员/积分 | 商业化 | 账号页 |
| MCP Server（AI 客户端驱动截图全流程：begin→edit→recognize→export，带 revision 并发模型） | AI 工作流集成 | 设置→系统→启用 MCP（默认关） |
| 自更新（Rust updater，GitHub/Gitee 双源，Windows/Mac 事务式替换） | 维护 | 托盘/设置 |
| 皮肤/主题（Ant Design 亮暗、贴图皮肤、字体、缩放） | 个性化 | 外观设置 |
| 启动项注册、管理员权限启动、单实例协调、游戏窗口分类 | 系统健壮性 | — |

**实现位置**：`src/app/` 14.8k、`src/presentation/services/` 37k（这是最大的"杂项抽屉"）、`src/shortcuts/` 1k、`rust/snow-shot-updater/`、`src/app/mcp/`。
**复杂度：★★★★☆**。单点都不难，但数量巨大，且 `services/` 目录 37k 行里塞了 60+ 个彼此纠缠的控制器/服务，是"乱"的主要来源。

---

## 2. 每功能实现位置与复杂度汇总表

| 功能域 | 主要位置 | 规模（约） | 复杂度 |
|---|---|---|---|
| 区域/窗口/全屏截图 | presentation/{capture,overlay,selection,selector} + snow-capture | 90k | ★★★★☆ |
| 滚动长截图 | presentation/capture/scrolling* + snow-stitch-images | 20k | ★★★★★ |
| 标注工具（33 种） | presentation/tools + snow_draw_engine_qt | 245k | ★★★★★（自研引擎） |
| 贴图（含实时窗口贴图） | presentation/pinned + services + platform | 35k | ★★★★★ |
| OCR/表格/二维码/转 MD·HTML·LaTeX | presentation/ocr + snow-ocr-process | 30k | ★★★★☆ |
| 划词/截图翻译 | services/selectedtext* + network + app/translation* | 8k | ★★★☆☆ |
| 录屏（含跟随鼠标/webcam/剪辑/变速/多格式导出） | presentation/recording + snow-recording-* | 90k | ★★★★★ |
| 图片拼接/分割/编辑/全局画布 | collage, imagesplit, imageediting, globalcanvas | 20k | ★★★☆☆ |
| 截图历史与存储管理 | storage/ + services/ *history* | 8k | ★★☆☆☆ |
| 全局快捷键/鼠标手势/托盘/悬浮条 | shortcuts/ + services/ | 8k | ★★★☆☆ |
| 设置系统（195 项，15 页，含搜索/重置/迁移） | presentation/settings | 14k | ★★★★☆ |
| 自更新 | update/ + rust/snow-shot-updater | 6k | ★★★☆☆ |
| MCP Server | app/mcp/ + mcp-capabilities.json | 6k | ★★★★☆ |
| 双平台原生层（窗口管理/打印/右键菜单/权限/单实例…） | platform/{windows,macos} | 16k | ★★★★☆ |
| 主窗口/UI 框架/皮肤/组件库 | components/ + ant_design_qt | 214k | ★★★★★（自研） |
| 图片编解码 | image/ + snow_image(-rs) | 67k | ★★★☆☆ |

---

## 3. UX 流程梳理

### 3.1 入口矩阵
1. **全局快捷键（31 个动作）**：设置应用首屏即"全局快捷键"页，分四组（截图 / 贴图 / 录屏 / 其他），每组可整体重置；支持 `ToggleGlobalShortcuts` 一键停用全部、`ToggleDisableOnFocusedFullscreenWindow` 在全屏游戏/应用内自动停用。macOS 上按动作声明所需权限（Screen Recording / Accessibility / Input Monitoring / Microphone），有专门的权限引导页 `permissionguidewidget`。
2. **托盘**：QSystemTrayIcon + macOS 原生 NSStatusItem 包装（`systemtraymenu.mm`，处理 Qt 菜单与原生菜单的点击语义差异），左/中/右键可分别绑定动作，支持气泡通知（截图完成/更新/视频导出完成）。
3. **悬浮工具条**：桌面常驻可拖拽，截图中另有"画布内工具栏 + 选中后浮动工具条"两级。
4. **主窗口**：侧边栏（sidebarwidget）+ 路由式页面（settingscatalog 用 route 如 `/settings/screenshots`），15 个设置页：全局快捷键、截图历史、贴图管理、全局鼠标、翻译、通用、外观、截图、贴图、录屏、文字识别与翻译、应用内快捷键、托盘与悬浮条、导出与存储、网络与连接、（macOS）应用权限、账号、关于。
5. **Windows 右键菜单 / Explorer 命令**：文件级入口（图片直接贴图/编辑）。
6. **MCP**：面向 AI 客户端的程序化入口（begin→set_selection→edit→export→finish 会话协议）。

### 3.2 核心截图会话流程
全局快捷键 → 全屏遮罩窗口池（`screenshotoverlaypool`，按显示器预建）→ 智能窗口高亮 → 拖拽选区（十字准线/参考线/遮罩/中心引导线，均可在设置改色）→ 松开鼠标出现工具条（`mousereleaseactioncontroller` 可配置松开即复制/贴图等）→ 标注 → 确认键/取消键（Backspace 撤销、Enter 确认等，均有可配置绑定与快捷键提示面板 `screenshotshortcuthints`）→ 导出（复制/保存/快速保存/贴图/打印/AirDrop/PDF，`screenshotexportcoordinator` 统一调度）。

### 3.3 首选项体系
- `settingscatalog.cpp` 一个文件 7,189 行、195 个设置项、含别名（搜索）、页间链接、按 edition（完整版/Mini）条件编译裁剪。
- 设置有运行时会话层（`settingsruntimesession`，1.8k 行）负责即时生效/回滚，`configurationarchive` 支持配置迁移。
- 首选项粒度极细：选区边框色/遮罩色/准线色都是独立项；录屏有编码器级选项（H.264 硬编/H.265 软硬编/GIF 帧率等）。

**UX 评价**：入口多而全（快捷键 31 + 鼠标组合 + 托盘 + 悬浮条 + 右键菜单 + MCP），信息架构靠 15 页设置消化；对极简产品来说，这个 UX 面本身就是负担。

---

## 4. 复杂度热点：为什么它"功能太复杂太乱"

1. **自研全家桶基础设施**：`ant_design_qt`（19 万行组件库）+ `snow_draw_engine_qt`（21.5 万行绘图引擎）+ `snow_image`（3.5 万行图片库）。约一半代码在"造轮子"，业务功能反而只占另一半。还养着一个未上线的 `snow-draw-engine-gpui`（4 万行）实验分支。
2. **presentation 层 21.8 万行的扁平巨层**：18 个子目录、700+ 文件、无清晰分层。其中 `services/`（3.7 万行、60+ 控制器）是典型的"上帝目录"——导出、剪贴板、打印、通知、权限、皮肤、历史、翻译控制器混在一起，控制器间靠直接引用串联（`screenshotpresentationservices` 是巨型组装点）。
3. **贴图子系统状态机过重**：贴图不只是"置顶窗口"，而是分组/切换/恢复/点击穿透/摇一摇/实时窗口流/批量保存/几何记忆/无障碍的复合体（3.5 万行 + 10 个性能基准文件）。这是 Snow Shot 最有特色也最难维护的功能。
4. **识别-转换-翻译链条过长**：OCR 后接 6 种格式转换（文本/表格/MD/HTML/LaTeX/翻译），每种都有自己的布局、渲染器、导出器和设置项；且要同时支持"截图内识别""贴图识别""独立图片识别"三个宿主，同一逻辑三处适配。
5. **录屏是隐形的第二产品**：捕获、效果、音频、webcam、恢复、剪辑、变速、6 种导出格式、硬件编码协商——90k 行代码，功能密度不亚于一个独立录屏软件（OBS 级别的子集）。
6. **平台 × 版本矩阵**：windows/ 与 macos/ 各自实现托盘、打印、贴图层级、快捷键后端、文件管理器、权限引导；又有 完整版/Mini 版编译开关（`app::edition::isMini` 散落各处，还有 `mini_build_contract_tests.py` 守护）。每个功能天然 ×2 或 ×4 份心智负担。
7. **C++/Rust 双语言 FFI**：31 个 Rust crate 通过 `snow_*-c` FFI 层接回 C++，构建链（vcpkg + submodule OCR + 每平台 Qt 版本 + FFmpeg）是著名的编译噩梦（专属 Windows ARM64 构建文档、macOS 签名文档各一份）。
8. **设置爆炸**：195 个设置项意味着每加一个功能平均引入 8–10 个配置面，"自定义成顺手的样子"的代价是任何路径都至少有 3 层偏好影响。
9. **MCP/自动化会话模型**：为 AI 客户端单独设计了 session/revision/owner 的并发状态机（单写者、静默会话、断线语义），是应用内另一个独立状态维度。

---

## 5. 对 Snapcut 的功能取舍建议

Snapcut 定位：**极简、贴 macOS 原生、用起来顺手**。取舍原则：只保留"截图 → 标注 → 出结果（复制/保存/贴图）"闭环中每一环节里用户 80% 时间在用的那一档；能用系统 API 就不造轮子；不做平台矩阵（macOS-only 起步）。

### MVP 必做
| 功能 | 取自 Snow Shot 的什么 | 理由 |
|---|---|---|
| 区域截图（含窗口智能吸附） | capture/overlay/selection 的交互模型，**不要**其后端降级矩阵——直接用 ScreenCaptureKit | 核心场景。窗口吸附是"顺手"的最大来源，必须做；但 Snapcut 只要 SCK 单后端，复杂度从 90k 降到 ~10k |
| 延时截图 | `ScreenshotDelay` 交互 | 实现成本≈0（一个 timer），覆盖弹层/菜单场景 |
| 标注：矩形/椭圆/箭头/直线/画笔/文字/序号/马赛克 | Tool 枚举里的前 8 个 + Filter | 覆盖 95% 标注需求。**用系统绘制（AppKit/Canvas）而非自研引擎**——Snow Shot 为跨平台和极致性能才自研 21 万行引擎，Snapcut 单平台完全不需要 |
| 填充色/描边宽度等 3–4 个样式控件（不要样式预设面板） | toolpalettestyle* 的简化 | "顺手"要求改色零跳转，但不要求预设库 |
| 全局快捷键（≤6 个：截图、延时、贴剪贴板、录屏、历史、设置） | `GlobalShortcutAction` 精选 + CGEventTap/系统设置引导 | 快捷键是效率工具的灵魂；31 个动作是 Snow Shot 设置爆炸的源头，Snapcut 砍到个位数 |
| 复制到剪贴板 / 保存 PNG（自动命名） / 快速保存 | exportcoordinator 的三个出口 | 出口越少越顺手；Snow Shot 的 12 种导出（PDF/打印/AirDrop/云上传…）全部不做 |
| 贴图（基础版）：截图贴图 + 剪贴板贴图，缩放/关闭/半透明调节 | pinned/ 的核心窗口逻辑，砍掉分组/恢复/摇一摇/点击穿透/实时贴图 | Snow Shot 用户口碑最强的功能之一，但只需其 ~15% 的代码（窗口层级 + 透明度 + 拖拽）。实时窗口贴图和分组管理是它最乱的部分，坚决不做 |
| 菜单栏（托盘）图标 + 3 项菜单 | systemtray 思路，用 NSStatusItem 原生实现 | 常驻入口 + 唤出设置；Snow Shot 的皮肤化托盘菜单（TrayMenuSkinBinding）是为主题一致性，Snapcut 用原生菜单反而更"贴 macOS" |
| 首选项：1 页（快捷键 + 保存目录 + 默认动作） | settings 思路，砍掉 195 项 → ~10 项 | 单页原生 NSWindow 即可，不做路由式设置系统 |
| Retina/多显示器 DPI 正确 | overlay/selection 的几何模型 | 单平台也必须做对，这是截图工具的生死线 |

### 二期（有价值但非第一印象）
| 功能 | 理由与来源 |
|---|---|
| OCR（系统 VisionKit/Vision 框架） | macOS 系统自带 OCR，实现成本极低（对比 Snow Shot 30k 行 PaddleOCR 链路）；只做"识别→文本窗口"，不做表格/MD/HTML/LaTeX 转换 |
| 录屏（区域 + 系统声音 + 麦克风，导出 MP4） | 用 ScreenCaptureKit + AVFoundation 系统能力，只做"录制→保存"，不做跟随鼠标/webcam/剪辑/变速/GIF。录屏与截图共享选区 UI，边际成本低；但导出格式矩阵不要碰 |
| 滚动长截图 | 用户需求真实但实现复杂（Snow Shot 为此写了 15k 行拼接引擎 + 专门诊断系统）；二期再做，且先只支持滚动触发拼接、不做自动滚动 |
| 全屏截图 / 焦点窗口快捷键 | 简单，但 MVP 快捷键名额有限，二期补 |
| 取色器 | 画布内取色体验好，实现小；排在标注打磨之后 |
| 闪烁快门音/截图动画、通知反馈 | 体验细节，成本低 |
| 图片标注复用（对已有图片文件打开标注器） | Snow Shot 的 imageediting 是独立编辑器；Snapcut 只需"打开文件→进入同一画布"，不加编辑器专属功能 |

### 明确不要
| 功能 | 理由 |
|---|---|
| 自研 UI 组件库 / 绘图引擎 | Snow Shot 为双平台+主题系统+性能才自研；Snapcut 用 SwiftUI/AppKit，省下 40 万行 |
| 翻译（划词/截图翻译/独立翻译窗口/语言检测/在线服务协议） | 与截图核心无关，引入账号/网络/协议一整层（Snow Shot 为此有 8k+ 行和独立设置页） |
| 表格/二维码/Markdown/HTML/LaTeX 识别转换 | OCR 转换链条的"长尾"，每种都要独立解析渲染器；系统 VisionKit 已覆盖文本/二维码 |
| 云上传 / S3 / 账号 / 会员 | 商业化基础设施，与极简定位相悖 |
| MCP Server | 面向 AI 客户端的独立会话状态机；等有真实用户需求再说 |
| Windows 支持 / Mini 双版本 | 版本矩阵是 Snow Shot 复杂度的重要放大器（edition 开关散落全仓）。Snapcut 先把 macOS 做到极致 |
| 图片拼接 Collage / 分割 Split / 全局画布 / 独立看图器 | 独立产品级功能（各 5–10k 行），偏离截图主业 |
| 贴图分组/恢复/摇一摇/点击穿透/实时窗口贴图/贴图皮肤 | Snow Shot 贴图 3.5 万行里 85% 是这些高级交互；基础贴图 + 透明度已满足"参考资料放旁边"的核心价值 |
| 录屏剪辑/变速/跟随鼠标/webcam/多格式导出/崩溃恢复 | 录屏一旦加剪辑就变成第二个产品；坚持"录完即得" |
| 皮肤/主题/字体/缩放系统 | "贴 macOS 原生"就意味着跟随系统外观，不做自绘主题（Snow Shot 光托盘菜单皮肤绑定就写了 400 行） |
| 自更新器（双源/事务式替换） | macOS 用 Sparkle 或仅提示 App Store/网页下载，不需要 Rust 事务式更新器 |
| 游戏全屏自动停用/管理员启动/单实例协调/崩溃采集诊断系统 | Snow Shot 为 Windows 生态做的防御性工程，macOS 场景弱需求 |

### 一句话总结
**Snow Shot 的"复杂"= 自研基建（41 万行）× 双平台 × 双版本 × 高级交互长尾；Snapcut 应做的恰是它 2021 年最早的那 5%：快捷键 → 框选 → 标注 → 复制/保存/贴图，其余全部交给 macOS 系统能力。** 预估 MVP 代码量 ~8–12k 行（对比 Snow Shot 80 万行），复杂度重心应放在"选区交互手感 + DPI 正确 + 窗口吸附"三件事上，而不是功能数量上。
