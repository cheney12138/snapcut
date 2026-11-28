# Snapcut Changelog

本文件记录 Snapcut 的所有重要功能演进、体验打磨与缺陷修复，按时间倒序归档，便于回溯决策脉络与定位代码改动。  
规划中的下一阶段需求与代码级任务拆解见：[docs/07-v0.3-roadmap-design.md](docs/07-v0.3-roadmap-design.md)。

---

## [0.3.0] — 2026-11-28（区域录屏 GIF/MP4、双路实时混音、结构化 OCR 与贴图实况文本）

### 新增功能（Added）
- **外部剪贴板图片智能感知 & 工具栏瘦身**
  - 新增 [ClipboardImageWatcher.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Clipboard/ClipboardImageWatcher.swift) 与全链路 `ClipboardWriter.markOwnWrite()` 自写过滤：0.6s 轻量监听系统剪贴板外部复制图片（兼容像素图与 Finder 静态图片文件，排除 GIF 动图与 `< 48px` 小图标），复用共享 `VisionKit` 后台静默探测，**仅当检测到文字或二维码时**轻浮提示（纯表情包/照片 0 打扰）。
  - 扩展 [CaptureToast.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Notification/CaptureToast.swift) 新增外部图片轻提示卡片（缩略图 +「贴图划词」/「提取排版」双钮 + 4.5s 自动淡出与悬停暂停）；点「贴图划词」直接透传预分析 `ImageAnalysis` 给 [PinWindowController.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Pin/PinWindowController.swift)，0ms 瞬间直达原生实况文本划词态。
  - [ToolbarPanel.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Editor/ToolbarPanel.swift)：从主栏移除「取字 (`O`)」按钮保持精简，将其收进 `•••` 更多菜单留后门并保留快捷键 `O`。
  - [AppSettings.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Core/Domain/AppSettings.swift)、[SettingsWindowController.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Settings/SettingsWindowController.swift)、[TrayMenu.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Tray/TrayMenu.swift)、[StatusItemController.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Tray/StatusItemController.swift) 与 [AppCoordinator.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/App/AppCoordinator.swift)：新增「通用 ▸ 外部复制含文字图片时轻提示」开关，以及托盘与 `⌥⌘H` 光标菜单的动态剪贴板图片快捷入口。
- **桌面贴图原生实况文本（macOS VisionKit Live Text）**
  - 新增 [PinLiveTextOverlay.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Pin/PinLiveTextOverlay.swift) 并升级 [PinWindow.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Pin/PinWindow.swift)、[PinContentView.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Pin/PinContentView.swift) 与 [PinWindowController.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Pin/PinWindowController.swift)：贴图弹出后后台共享 `ImageAnalyzer` 静默分析文字与二维码；检测到文字时右上角悬停按钮组于关闭键左侧柔显同源 `text.viewfinder` 圆钮（或按 `T` / 右键切换），0ms 瞬间开启非翻转坐标像素级贴合的原生 `ImageAnalysisOverlayView` 图上逐字划词与 Data Detectors。
  - 划词态保留滚轮/双指缩放与 `⌘+拖` 移动，窗口级 `performKeyEquivalent` 兜底无主菜单栏下的 `⌘C` 复制选中文字、`⌘A` 全选与 `Esc` 先退出划词再关贴图；右键菜单同步直达「结构化取字…」呼出 Markdown/真表格面板。
- **结构化 OCR 文档识别、原生富文本预览与多格式剪贴板（零 WebView）**
  - **纯 Core 结构化文档引擎**：扩展 [StructuredOCR.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Core/Domain/StructuredOCR.swift) 与 [TextRecognizer.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/OCR/TextRecognizer.swift)，基于 Vision 归一化包围盒 0ms 本地解析出 `OCRDocument` AST（`H1/H2` 标题、自然段软换行合并与空行/缩进/短行拆段、无序/有序列表含二级嵌套与悬挂折行归并、以及**图文/表格混排局部表格切片**），一键输出 GFM Markdown、安全转义语义 HTML 与干净纯文本；新增独立自动化验证脚本 [test-structured-ocr.sh](file:///Users/qianyuchen/work/screenshot/snapcut/scripts/test-structured-ocr.sh)（Release & Debug 9×2 场景全绿）。
  - **原生富文本渲染与双格式剪贴板**：新建 [OCRDocumentRenderer.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/OCR/OCRDocumentRenderer.swift) 并升级 [OCRResultPanel.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/OCR/OCRResultPanel.swift)，直接复用原生 `NSTextView`（`NSAttributedString` + `NSTextList` + `NSTextTable`）呈现所见即所得排版；仅在检出真实文档结构时于标题栏右侧显示明暗自适应 `[ 排版 | Markdown ]` 切换胶囊（支持 `⌘M` 瞬切，普通单段纯文本零打扰）；「排版」态整篇或**局部划选 `⌘C`** 均原子写入 `HTML + RTF + 纯文本`（粘进飞书 / Notion / Word / 备忘录直接还原真表格与真列表），底部双按钮支持一步直出排版或 Markdown 且完整保留手动编辑修订。
- **区域 GIF 录制与带双路实时混音的 MP4 录屏（六边形完整闭环，Wave 1–3）**
  - **Core 领域与端口**：新增纯 Core 模型 [RecordingModel.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Core/Domain/RecordingModel.swift)（`RecordingFormat` / `RecordingOptions` / `RecordingPhase` / `RecordingResult` / `RecordingGeometry` 偶数像素与 1x 缩放对齐），扩展 [AppSettings.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Core/Domain/AppSettings.swift) 持久化录制参数与全局/编辑器热键（默认 `⌥⌘R` / `⌥⌘G`、编辑器 `R` / `G`），并在 [Ports.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Core/Ports/Ports.swift) 定义 `ScreenRecording`、`ScreenRecordingEvent.audioLevels(system:microphone:)` 与 `ClipboardWriting.writeFileURL(_:)`。
  - **采集、归一化与双路实时混音适配器**：新增 [SCKScreenRecorder.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Recording/SCKScreenRecorder.swift)、[AudioFormatNormalizer.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Recording/AudioFormatNormalizer.swift) 与 [AudioTrackMixer.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Recording/AudioTrackMixer.swift)：
    - 基于 `SCStream` 进程级排除 Snapcut 自身浮层不入镜；GIF 走独立串行编码队列 `gifEncodeQueue` + `CGImageDestination` 流式写盘（`10–24 fps`、1x 轻量 / 原画质、真实帧间时长）；
    - MP4 走 `AVAssetWriter` H.264 硬件编码（`30/60 fps`、偶数像素铺满、静止画面尾帧补齐）；支持自由独立开关系统声音与麦克风，任意源设备经 `AudioFormatNormalizer` 归一化为 `48kHz / 2ch / Float32`（单声道双耳居中、热插拔自动重建转换器）；
    - **Wave 3 双路实时混音 & 主时钟校准**：系统声与麦克风同时开启时，由 `AudioTrackMixer` 基于首帧视频 `anchorPTS` 以整数采样索引实时混成**单条全平台兼容 160kbps Stereo AAC 音轨**（1024-sample AAC 原生帧长连续输出、60ms 非阻塞抖动窗热插拔静音兜底、`±2.5ms` 包边界微抖动吸附、`knee=0.85 → ceiling=0.99` `tanh` 软削波防爆音）；完善 `pause()` 尾音冲刷、`resume()` 跨暂停滞留包拦截 + 重采样器 `flushState()` 以及 `finalizeMP4()` 音画联合收口；新增独立自动化验证脚本 [test-audio-mixer.sh](file:///Users/qianyuchen/work/screenshot/snapcut/scripts/test-audio-mixer.sh)（Release & Debug 8×2 真实 PCM 波形场景全绿）。
  - **多入口、统一视觉控制栏与实时波形动效**：主工具栏动作区提供「录制视频 (`R`)」、`•••` 更多菜单提供「录制 GIF (`G`)」（拼贴编辑器通过 `Capabilities.supportsRecording` 屏蔽），托盘菜单与 `⌥⌘H` 兜底菜单提供直接入口与录制中「停止/放弃」项，设置 ▸ 快捷键面板补齐全部录屏热键配置；[RecordingControlBar.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Recording/RecordingControlBar.swift) 全面 1:1 对齐 `ToolbarPanel` 视觉 token（同心圆角、无边框尺寸标签、等宽定宽防 `30/60 fps` 切换位移、`TBIconButton` 同款内嵌高亮）；录制态配备手机风格红环红方停止按钮与加宽 5 柱对称灵动岛声波徽章（混音前独立采集系统声蓝 / 麦克风绿电平，互不污染）。
  - **内置 HUD 预览窗与可点击动作 Toast**：新增深色 HUD 磨砂玻璃内置播放器 [GIFPreviewPanel.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Recording/GIFPreviewPanel.swift) 与 [VideoPreviewPanel.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Recording/VideoPreviewPanel.swift)（MP4 支持 `AVPlayer` 循环播放、进度条拖拽寻址、`Space`/`←`/`→`/`M`/`Esc` 快捷键，以及关闭/丢弃前立即释放文件句柄）；[CaptureToast.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Notification/CaptureToast.swift) 弹出可点击展开的完成卡片，提供「复制文件」「访达」「预览」「丢弃」快捷操作。
  - 涉及文件：`Sources/Core/Domain/RecordingModel.swift`、`Sources/Core/Domain/AppSettings.swift`、`Sources/Core/Ports/Ports.swift`、`Sources/Core/Shared/Log.swift`、`Sources/Adapters/Recording/SCKScreenRecorder.swift`、`Sources/Adapters/Recording/AudioFormatNormalizer.swift`、`Sources/Adapters/Recording/AudioTrackMixer.swift`、`Sources/Adapters/Clipboard/ClipboardWriter.swift`、`Sources/Adapters/PortConformances.swift`、`Sources/UI/Recording/RecordingControlBar.swift`、`Sources/UI/Recording/RecordingOverlayViews.swift`、`Sources/UI/Recording/GIFPreviewPanel.swift`、`Sources/UI/Recording/VideoPreviewPanel.swift`、`Sources/UI/Editor/TBIcon.swift`、`Sources/UI/Editor/ToolbarPanel.swift`、`Sources/UI/Editor/EditorKeyRouter.swift`、`Sources/UI/CollageEditor/CollageEditorWindowController.swift`、`Sources/UI/Overlay/OverlayWindow.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/Export/ExportCoordinator.swift`、`Sources/UI/Notification/CaptureToast.swift`、`Sources/UI/Tray/TrayMenu.swift`、`Sources/UI/Tray/StatusItemController.swift`、`Sources/UI/Settings/SettingsWindowController.swift`、`Sources/App/AppCoordinator.swift`、`scripts/TestAudioMixerMain.swift`、`scripts/test-audio-mixer.sh`、`project.yml`

### 缺陷修复（Fixed）
- **视觉记忆（Spotlight）冷启动首开卡顿与连按秒关根治（1.46s → < 30ms）**：
  - [HistoryStore.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/History/HistoryStore.swift)、[HistorySpotlightPanel.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/History/HistorySpotlightPanel.swift)、[AppCoordinator.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/App/AppCoordinator.swift)：将弹窗同步遍历解码 30 张 4K/长图 PNG 改为「纯内存缓存 0 I/O 瞬弹 + 后台 4 并发首屏前 9 张优先异步渐进补图（`kCGImageSourceShouldCacheImmediately`）+ 冷启动 1.2s 后后台低优先级静默预热首屏 9 张缩略图」，彻底消除首次唤起卡顿 1.5s 及卡顿期间重复按键导致的闪退感。
- **录制控制栏分隔线显色与光学间距优化**：
  - [RecordingControlBar.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Recording/RecordingControlBar.swift)：分隔线改为明暗自适应 `BarHairlineView`（修复深色系统下在浅色玻璃上画出隐身白线的问题），将录制态控制键收进紧凑 `actionsRow` 并按光学留白平衡声波胶囊与暂停键间距。
- **滚动截图来回滚动防重复拼接、触底自动完成加固与防跳顶闪屏**：
  - [Stitcher.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Core/Domain/Stitcher.swift)：废除用剥离顶栏后的 `CanvasWindow` 切片作为主参考，改为维护原始关键帧档案（上限 12 帧，保留顶/底锚点）+ 主位移估计始终基于相邻原始帧（保留 sticky header/sidebar 屏蔽）+ 顶/底边界防重闸门与向下滚动后严格 `Prepend` 守卫，彻底消除固定侧栏与高重复表格页来回滚动时的位置漂移与重复拼接。
  - [OverlayController.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Overlay/OverlayController.swift) & [OverlayWindow.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Overlay/OverlayWindow.swift)：修复 4K 60fps 队列持续非空导致触底自动完成饿死的问题（改为 `0.36s` 零增长 + 静态撞墙帧蓄力触发）；放宽边界容差（64–220px 兼容橡皮筋回弹）；退出滚动完成/清理时不再恢复冻结的页面顶部背景，彻底消除触底自动完成瞬间“跳回页面顶部再闪回底部”的闪烁；同时支持拖拽框选期间直接按 `Enter`/`⌘S`/编辑热键即时提交选区（绕开 macOS 三指拖移抬手延迟）。
  - [TestStitchMain.swift](file:///Users/qianyuchen/work/screenshot/snapcut/scripts/TestStitchMain.swift)：新增用例 13（固定顶栏 + 固定左侧栏 + 重复表格剧烈来回滚动），Release & Debug 13 个用例全部通过。

---

## [0.2.0] — 2026-11-22（可分发：发版流水线 + 自动更新）

### 新增功能（Added）
- **自动更新（Sparkle 2 + EdDSA appcast）**：新增 `AppUpdating` 端口与 `SparkleUpdater` 适配器（appcast 走 GitHub Releases 的 `latest` 指针，公钥写死 `SUPublicEDKey`，私钥在本机钥匙串 account `snapcut`），入口三处：菜单栏「检查更新…」、⌥⌘H 光标兜底菜单、设置 ▸ 关于「检查更新 / 每日自动检查」卡。
  - 后台 App（`LSUIElement`）必须显式声明 gentle reminders，否则 Sparkle 会警告"用户不会注意到更新提示"且后台发现的更新弹不出来 —— `GentleReminderDelegate` 补齐并逐事件落日志（`update.scheduled` / `update.willShow` / `update.sessionFinished`）。
  - 涉及文件：`Sources/Core/Ports/Ports.swift`、`Sources/Adapters/Update/SparkleUpdater.swift`、`Sources/Adapters/PortConformances.swift`、`Sources/UI/Settings/SettingsWindowController.swift`、`Sources/UI/Tray/TrayMenu.swift`、`Sources/UI/Tray/StatusItemController.swift`、`project.yml`
- **发版流水线（一条命令出可分发包）**：`scripts/release.sh <版本号>` = 架构守卫 → 写版本号进 `project.yml`（唯一真源）+ 构建号用时间戳 → `xcodegen generate` → Release(arm64) 构建 + 本地证书重签名（含内嵌 Sparkle.framework）→ DMG → `sign_update` EdDSA 签名 → 自写 `appcast.xml`；`scripts/make-dmg.sh` 单独出包并断言版本号/公钥长度/签名有效性；`make release VERSION=x.y.z` 收口。
  - 不用 Sparkle 的 `generate_appcast`：它会在缺公钥时**静默**生成没有 `edSignature` 的 appcast（更新永远"已是最新"且查不出原因）。
  - 文档：`docs/08-release-and-autoupdate.md`（发版四步 / 版本号口径 / 两道签名校验 / 密钥管理 / 症状→排查表 / 本地端到端验证）。

---

## [Unreleased] — 2026-11-20 ~ 2026-11-21（v0.2 体验精修与架构收口）

### 新增功能（Added）
- **M4 · 贴图工作台 & 结构化取字（完成 `T4.1`–`T4.4`）**
  - **贴图全局隐藏/唤回（Boss Key `⌥⌘P`）**：新增 `PinWindowController.toggleAllVisibility()` 与 `PinMagnetRegistry.setAllGroupPanelsHidden(_:)`，一键隐藏/原位恢复全部桌面贴图、拼贴磨砂玻璃托盘与顶栏（完整保留分组、坐标与透明度），同步接入全局热键 `⌥⌘P` 及托盘菜单入口。
  - **拼贴顶栏一键复制拼图**：在 `GroupBorderPanel` 顶栏新增「复制」快捷按钮（`doc.on.doc`），复用 `PinAssembleEngine.compose` 一步合成写入剪贴板与历史记录并弹出可点开重编的 Toast，不销毁桌面拼贴组。
  - **贴图 50% 重叠对比模式**：新增 `PinWindowController.toggleCompareOpacity()` / `resetOpacity()`，支持右键菜单「对比模式 50% (D)」及快捷键 `D` / `5` 瞬切 50%↔100% 透明度、`0` 复位 100%（带 HUD 反馈）。
  - **取字结构化识别（二维码直达 + Markdown 表格复制）**：新增纯 Core `StructuredOCR`（安全协议 URL 校验 + 几何列聚类 GFM Markdown 表格识别，7/7 单测通过）；`TextRecognizer.recognizeStructured` 单次并发执行文本 OCR 与 QR 码检测；`OCRResultPanel` 自动展示二维码动作条（打开链接 / 复制二维码，纯二维码截图紧凑无空正文）与底部「复制 Markdown 表格」按钮。
  - 涉及文件：`Sources/Core/Domain/StructuredOCR.swift`、`Sources/Core/Ports/Ports.swift`、`Sources/Adapters/PortConformances.swift`、`Sources/Adapters/OCR/TextRecognizer.swift`、`Sources/Adapters/OCR/OCRResultPanel.swift`、`Sources/Adapters/Pin/PinWindowController.swift`、`Sources/Adapters/Pin/PinMagnetRegistry.swift`、`Sources/Adapters/Pin/GroupBorderPanel.swift`、`Sources/Adapters/Pin/PinContentView.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/CollageEditor/CollageEditorWindowController.swift`、`Sources/UI/Tray/TrayMenu.swift`、`Sources/UI/Tray/StatusItemController.swift`、`Sources/App/AppCoordinator.swift`
- **M3 · 克制的一键画框美化（Smart Backdrop，完成 `T3.1`–`T3.4`）**
  - 新增纯 Core `BackdropStyle` 模型与 `BackdropLayout` 画布几何引擎（6 套 Apple 风格克制预设：浅雾灰/柔白/深曜石/暖霞/森海/冰蓝，3 档边距 24/40/64pt，`自动`/`16:9`/`4:3` 精确居中，偏好记忆且新截图默认关闭不打扰极速裸截图；独立单测通过）。
  - 扩展 `CGRenderer` 新增边缘主色采样均衡（`detectEdgeColor` + `effectiveBalanceInset`）与 1x/2x Retina 无锯齿画框渲染管线（`renderWithBackdrop`：线性渐变底 + 双层 Apple 柔影 + 连续圆角裁切 + 0.5pt 发丝边，预览与导出共用同一几何与绘制路径）。
  - 编辑器工具栏新增 `sparkles.rectangle.stack` 画框美化按钮与快捷键 `B` 瞬切，并仅在开启时于主栏上方轻浮展示 `.clear` Liquid Glass 单行微调胶囊 `SmartBackdropPillPanel`（色板圆点 / 边距 / 比例 / 均衡留白开关，智能避让智能打码胶囊），标注交互仍在原图坐标零偏移工作且所见即所得导出。
  - 涉及文件：`Sources/Core/Domain/BackdropStyle.swift`、`Sources/UI/Annotate/CGRenderer.swift`、`Sources/UI/Editor/TBIcon.swift`、`Sources/UI/Editor/ToolbarPanel.swift`、`Sources/UI/Editor/EditorSession.swift`、`Sources/UI/Overlay/OverlayWindow.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/CollageEditor/CollageEditorWindowController.swift`
- **M2 · 视觉记忆库 & 可反悔矢量重编（Visual Memory，完成 `T2.1`–`T2.5`）**
  - 扩展纯 Core `AnnotationModel` 与全部 7 种 `Shape` 支持 `Codable`/`Sendable` 往返无损序列化，并在 `AnnotationStore` 新增 `restore(annotations:)` 逐条重建撤销栈；新增纯 Core `HistoryRecord`、`EditableSessionPayload`、`HistoryCaptureMetadata` 与 `HistorySearch`（多词 AND 过滤 + 相关度/时间排序 + 命中摘要提取，独立单测通过）。
  - 升级 `HistoryStore`：完整兼容存量 30 条旧历史索引，最近 20 条带标注导出自动保存 `<id>.base.png` + `<id>.annotations.json` 可重编 sidecar；新增低优先级串行后台 Vision OCR 索引队列与启动后低优先级存量补齐（不抢占前台截屏与启动 CPU）。
  - 新增明暗自适应 Liquid Glass 速搜浮窗 `HistorySpotlightPanel`（默认全局热键 `⌥⌘V` 及托盘入口）：3 列缩略图流、可重编角标、命中文本强调高亮与全键盘导航（`↑↓←→` 选卡、`↩` 复制原图、`⌘E` 重新编辑、`⌘P` 贴图、`⌘C` 复制识别文字、`Esc` 退出并归还焦点）。
  - 实现非破坏性矢量重编：点击刚复制的 Toast 或从视觉记忆按 `⌘E` 重开时自动按比例还原干净底图与全部矢量标注层，支持直接 `⌘Z` 逐条撤销与继续追加。
  - 设置窗口「通用 → 历史」新增「后台自动识别历史文字」开关，「快捷键 → 全局热键」新增「视觉记忆搜索」自定义录制与全量热键冲突检测（即时重绑生效）。
  - 涉及文件：`Sources/Core/Domain/AnnotationModel.swift`、`Sources/Core/Domain/HistoryRecord.swift`、`Sources/Core/Domain/AppSettings.swift`、`Sources/Core/Ports/Ports.swift`、`Sources/Adapters/History/HistoryStore.swift`、`Sources/UI/History/HistorySpotlightPanel.swift`、`Sources/UI/Editor/EditorSession.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/Settings/SettingsWindowController.swift`、`Sources/UI/Tray/TrayMenu.swift`、`Sources/UI/Tray/StatusItemController.swift`、`Sources/App/AppCoordinator.swift`
- **M1 · 智能一键脱敏（Auto-Redact，完成 `T1.1`–`T1.4`）**
  - 新增纯 Core 本地敏感信息检测引擎 `SensitiveTextDetector`（覆盖邮箱、中国/国际手机号、OpenAI/Anthropic/GitHub/AWS/阿里云/腾讯云/Slack API Key、Bearer Token、JWT、URL/配置密钥值、IPv4 地址与 18 位身份证号，排除 `127.0.0.1` / `0.0.0.0` 及占位示例，重叠自动去重；独立 7/7 单测通过）。
  - 扩展 `TextRecognizing` 端口与 `TextRecognizer.detectSensitiveRegions`：本地离线 Vision OCR 关闭语言纠错以原样保留密钥串，通过 `candidate.boundingBox(for:)` 精准定位词级包围盒，不误盖同行正常文字。
  - 扩展 `AnnotationStore` 批处理提交 `addBatch(_:)` 与单项点消 `removeAutoRedacted(at:)`：一次 `⌘Z` 整体撤销整轮自动脱敏，也支持在马赛克工具下悬停虚线高亮 + 单击取消某处误遮（同样可 `⌘Z` 恢复）。
  - 新增仅在选中马赛克工具时于其上方轻浮出现的 Liquid Glass 胶囊 `✦ 智能打码 ⇧M`（亦可在编辑态任意时刻按 `⇧M` 直接触发），命中后短暂闪现轻蓝轮廓并弹出顶部结果提示，不入导出图。
  - 涉及文件：`Sources/Core/Domain/SensitiveTextDetector.swift`、`Sources/Core/Ports/Ports.swift`、`Sources/Adapters/OCR/TextRecognizer.swift`、`Sources/Adapters/PortConformances.swift`、`Sources/Core/Domain/AnnotationModel.swift`、`Sources/UI/Editor/ToolbarPanel.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/Overlay/OverlayWindow.swift`、`Sources/UI/CollageEditor/CollageEditorWindowController.swift`
- **开机自动启动设置项（原生登录项）**
  - 新增基于 macOS `SMAppService.mainApp` 的登录项适配器，以系统真实登录项状态为唯一真相源；若处于 `.requiresApproval` 则展示一键跳转「系统设置 → 登录项」。
  - 在设置窗口「通用」页顶部新增「启动 · 登录时自动启动」卡片，并为设置页补齐透明 `NSScrollView` 顶部对齐滚动容器。
  - 涉及文件：`Sources/Adapters/Settings/LaunchAtLoginManager.swift`、`Sources/UI/Settings/SettingsWindowController.swift`
- **贴图与拼贴交互重构（松手吸附 + 柔和智能对齐 + 磨砂玻璃托盘）**
  - 彻底移除拖中位置劫持与磁滞死区：单卡拖动全程 1:1 自由跟随；靠近他卡进入吸附区仅展示不拦截鼠标的纯视觉鬼影框与参考线，松手后 `160ms easeOutStrong` 顺滑滑入成组。
  - 新增柔和边/中线对齐（上/下/中 Y、左/右/中 X 仅在 `≤16pt` 内轻吸对齐并显示参考线，用户刻意错位时不强行拉齐）。
  - 组内单卡直接拖离超过 `44pt` 自动自然脱离组（托盘柔淡提示），不再强依赖 `⌥+拖`。
  - 取消单卡 9pt 不透明白垫与成组尺寸跳变，改为底层统一 `.popover` 通透磨砂玻璃托盘（`GroupBackdropPanel`，透明度 `0.72` + 独立 `0.5pt` 发丝边框）+ 顶部悬浮玻璃胶囊（`已拼贴 · N 张 | 合并拼图 | 拆分 | ×`），支持 `Esc` 关闭整组。
  - 点击「合并拼图」改为原位无缝进入一体化无边框 Apple 编辑器（替代旧版暗色标题栏 `CollageEditorWindowController`）。
  - 涉及文件：`Sources/Core/Domain/MagnetGroup.swift`、`Sources/Adapters/Pin/SnapFeel.swift`、`Sources/Adapters/Pin/GroupBorderPanel.swift`、`Sources/Adapters/Pin/PinMagnetRegistry.swift`、`Sources/Adapters/Pin/PinWindowController.swift`、`Sources/Adapters/Pin/PinContentView.swift`、`Sources/Adapters/Pin/PinAssembleEngine.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/App/AppCoordinator.swift`
- **单屏聚焦唤起 & 边缘触发全屏**
  - 唤起区域截图时仅锁定鼠标当前所在显示器（不再打扰另一块外接/内建屏），且默认不自动框选全屏，仅当鼠标贴近屏幕边缘时平滑变形进入整屏预览。
  - 涉及文件：`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/Overlay/OverlayWindow.swift`

### 视觉与交互优化（Changed）
- **唤起窗口多屏居中、视觉记忆面板快捷键自定义、托盘精简与延时倒计时去白角**
  - 新增 `DisplayRegistry.screenAtMouse()` / `centerOrigin(for:on:)`：`HistorySpotlightPanel`、`SettingsWindowController`、`CountdownHUD` 与 `OnboardingWindow` 统一在光标当前所在显示器上正居中唤起。
  - `AppSettings` 新增 `spotlightHotkeys`（`copyImage` / `reopenEdit` / `pin` / `copyOCR`），设置窗口「快捷键」页新增「视觉记忆面板（搜索浮窗内生效）」分组支持自定义录入与冲突校验（支持 `Return` 与 `F1`–`F12`），`HistorySpotlightPanel` 底部键帽提示、右键菜单与按键分发实时同步用户自定义配置。
  - 移除托盘菜单中与视觉记忆面板重复的「历史记录」30 条文本子菜单，保留更丰富的「搜索视觉记忆」入口。
  - 重构 `CountdownHUD` 为 `DesignTokens.Mat.liquidGlass` + `OuterShadowView`（`hasShadow = false`），彻底消除延时倒计时卡片圆角四周残留的白色直角伪影，改用明暗自适应文本色保证白底/暗底皆清晰可读。
  - 视觉记忆面板升级为**高晶液态玻璃**（`DesignTokens.Mat.crystalGlassTint` `α=0.42` 对齐工具栏通透度并锁定 `.aqua` 明亮质感，去除所有外沿白线，纯靠 `OuterShadowView` 双层投影与原生玻璃折射切分明暗背景，卡片改用清透纯白晶面衬底）；底部快捷键键帽徽章（`SpotlightKbdCapsule`）、快捷操作按钮与条数徽标保持不透明实底胶囊（`α=0.96~0.98` + 高对比深墨字色），保证底层文字不透字干扰阅读。
  - **补全真实「截图音效」实现**：新增 `CaptureSoundPlayer` 优先加载 macOS 原生系统截图快门音 `Screen Capture.aif`（回落 `Grab.aif` / `Tink`），在区域/全屏/滚动/拼贴的复制、保存、快速保存与贴图导出完成时刻读取 `AppSettings.playCaptureSound` 播控，在设置开启开关时同时触发一次试听反馈。
  - **滚动截图引擎升级为 `SCStream` 60fps 连续流（根治高速滚动「滚动过快」断层）**：
    - 重构 [ScrollCaptureController.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/Adapters/Scroll/ScrollCaptureController.swift) 放弃早期的 `SCScreenshotManager.captureImage` 120ms 串行轮询（实测仅 ~7fps），改用 ScreenCaptureKit **`SCStream` 60fps 连续视频流**（GPU 侧按 `sourceRect` 直接裁剪、进程级排除自身浮层、`CVPixelBuffer` sRGB 零阻塞拷贝），静止时 0 推帧 0 功耗，滑动瞬间跑满 60fps，允许的滑动速度上限提升约 8 倍。
    - [OverlayController.swift](file:///Users/qianyuchen/work/screenshot/snapcut/Sources/UI/Overlay/OverlayController.swift) 将单槽 `scrollPendingFrame` 升级为有界 FIFO 队列（上限 `24` 帧）承接高速甩屏突发帧、在 `finishScrollCapture` 收尾时先排空尾部缓冲帧再合成，并为 60fps 边界撞墙自动收尾新增 `0.32s + ≥4 帧` 时间门控防误触。
    - 修复长图/独立编辑器双指缩放时工具栏随非居中缩放锚点不断向左/侧方漂移的问题：`zoomStandaloneSelection(to:)` 缩放与平移过程中保持工具栏稳妥锚定不动，同时 `ToolbarPanel.originBelow` 对跨屏超大画布改用可视交集中心定位。
  - **工具栏排版与连续线宽回归（滚动截图移至取字前 + 无极粗细滑杆）**：
    - 将「滚动截图」（`206`）从标注工具区移至工具栏后段「取字（OCR）」按钮正前方，`AppSettings.defaultToolbarOrder` / `toolbarOrderSafe()` 与设置页「工具栏排序」同步精简为纯标注工具 `1–7`。
    - 将线宽控件由细/中/粗 3 档圆点重构为自定义苹果风格连续无极滑杆 `TBStrokeSlider`（下限保持 `2.0pt` 对齐原「细」档，连续调节上限至 `10.0pt`，支持点击跳转、顺滑拖拽与滚轮精细微调并实时浮显 `线宽 X.X pt`），序号徽标 `CGRenderer.drawSequenceBadge` 同步改为连续线宽缩放映射。
  - **工具栏与悬浮浮层彻底告别深浅变化与闪烁并恢复 `1/2/3/4` 滑移动效**：
    - 移除 `ToolbarPanel` 根据截屏背景亮度实时切换 `.aqua`/`.darkAqua` 的逻辑；针对 macOS 26 原生 `NSGlassEffectView` 内部硬编码 `CABackdropLayer.tracksLuma = 1` 引起的跨 App（Antigravity → CatPaw IDE）首帧闪跳，改用基于 `.aqua` `.menu` 澄澈模糊 + `.continuous` 超椭圆 9-slice 蒙版 + 微白晶透提亮（`tintAlpha: 0.08`）的 `DesignTokens.Mat.fixedLightCrystalBlur`，并将工具栏及附属胶囊交互前景置入同级 `.aqua` 前景宿主，兼顾高通透晶体质感、零闪烁、零图标反色。
    - 排查发现系统「减弱动态效果」开启时 `TBSelectionIndicatorView` 与 `playSelectPop()` 屏蔽了所有工具切滑动效：现将工具栏内微小选中滑移胶囊（`toolPill` / `colorRing` / `strokePill`）与微弹反馈解耦于全局 `reduceMotion`，并提升浅色态 `toolPill` 对比度（`α=0.20 / 0.34`），`1/2/3/4` 切换工具的物理弹簧滑移动效全面恢复。
  - 涉及文件：`Sources/Core/Domain/HotkeySpec.swift`、`Sources/Core/Domain/AppSettings.swift`、`Sources/UI/DesignTokens.swift`、`Sources/UI/Platform/DisplayRegistry.swift`、`Sources/UI/History/HistorySpotlightPanel.swift`、`Sources/UI/Settings/SettingsWindowController.swift`、`Sources/App/AppCoordinator.swift`、`Sources/UI/Tray/TrayMenu.swift`、`Sources/UI/Tray/StatusItemController.swift`、`Sources/UI/Notification/CountdownHUD.swift`、`Sources/UI/Export/CaptureSoundPlayer.swift`、`Sources/UI/Export/ExportCoordinator.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/Overlay/OverlayWindow.swift`、`Sources/UI/Editor/ToolbarPanel.swift`、`Sources/UI/CollageEditor/CollageEditorWindowController.swift`
- **工具栏与悬浮胶囊 Liquid Glass 光学悬浮升级（紧贴接触影 + 柔和抬升影 + 稳定主题锁定）**
  - 移除人造黑色边框线与遮罩底色层，保持 `.clear` 原生液态玻璃的纯粹光学通透感，不靠画线强化边框；适度提升 `floatingGlassTint`（亮/暗 `α=0.42`）让通透玻璃本体与浅灰遮罩清晰拉开层次。
  - 修复 AppKit `NSViewBackingLayer` 在 `addSubview` 时按 `NSView.shadow == nil` 强制将 `layer.shadowOpacity` 清零导致投影完全失效的根因：新增 `OuterShadowView`，改由独立子 `CALayer` 承载阴影并覆盖全窗口外围留白区，以 `RoundedRectangle(style: .continuous)` `.evenOdd` 蒙版把玻璃圆角内部 100% 镂空。
  - 双层真实光学阴影参数：**紧贴接触影**（`radius 1.2pt / offset(0, -0.5) / 亮 α=0.34 暗 α=0.54`）紧贴 `.continuous` 边缘形成物理接触微缝，**柔和抬升影**（`radius 8.5pt / offset(0, -3) / 内收 1.5×1pt / 亮 α=0.18 暗 α=0.34`）收拢在底部托起玻璃，避免阴影向顶缘与两侧过度扩散，圆角零多余灰边、内部 100% 纯净不染黑。
  - 修复主题明暗跳变：在进入编辑态时对原始未压暗屏幕冻结帧做 `8×8` 快速亮度采样，一次性锁定本次会话的 `appearance`（浅色画面锁 `.aqua`、深色画面锁 `.darkAqua`），消除 `OverlayWindow` 半透明压暗把浅色页面推到 `CABackdropLayer.tracksLuma` 50% 阈值附近导致的深浅主题反复横跳。
  - 涉及文件：`Sources/UI/DesignTokens.swift`、`Sources/UI/Editor/ToolbarPanel.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/Overlay/OverlayWindow.swift`、`Sources/Adapters/Pin/GroupBorderPanel.swift`
- **macOS 26 原生 Liquid Glass 玻璃态重构与工具栏三档尺寸（`NSGlassEffectView`）**
  - 在 `DesignTokens.Mat` 新增 `liquidGlass(cornerRadius:style:tintColor:fallbackMaterial:)` 与 `floatingGlassTint`：macOS 26+ 使用原生 `NSGlassEffectView` 的 **`.clear` 清透液态玻璃** + 极淡明暗自适应微着色，并移除非激活浮窗上的 `contentView.layer.transform` 缩放（解决 `.regular` 在 `nonactivatingPanel` 下退化为不透明实色雾面的问题）；macOS 15 自动回退 `AdaptiveGlassView`。
  - 新增 `AppSettings.ToolbarSize` 三档尺寸设置：**紧凑（`30pt` 按钮 / `44pt` 高）· 标准（默认，`36pt` 按钮 / `50pt` 高）· 大号（`42pt` 按钮 / `58pt` 高）**，在设置窗口「通用 → 截图」提供分段开关，修改后通过 `invalidateToolbar()` 下次唤起即时生效（无需重启）。
  - 同步升级主工具栏 `ToolbarPanel`、马赛克上下文胶囊 `SmartRedactPillPanel`、文字浮动字号条 `FontSizeBarView`、拼贴顶栏 `GroupBorderPanel` 与拼贴磨砂玻璃托盘 `GroupBackdropPanel` 为 `.clear` 原生液态玻璃。
  - 涉及文件：`Sources/Core/Domain/AppSettings.swift`、`Sources/UI/DesignTokens.swift`、`Sources/UI/Editor/ToolbarPanel.swift`、`Sources/UI/Overlay/OverlayWindow.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/Adapters/Pin/GroupBorderPanel.swift`、`Sources/UI/Settings/SettingsWindowController.swift`、`Sources/App/AppCoordinator.swift`
- **全产品 Apple Liquid Glass 质感与动效体系**
  - 引入 `AdaptiveGlassView`（缓存 9-slice `maskImage` 消除磨砂圆角白块、自适应 0.5pt 发丝边、对称顶缘镜面高光）、`TactilePress` 按压触觉反馈与 `Motion.easeOutStrong` 曲线，清除全仓拖沓 `.easeIn` 退场动画。
  - 工具栏 16 枚手绘位图全面替换为原生 Apple SF Symbols；线宽滑块升级为 Apple Markup 风格 3 档圆点（`2/4/6pt`）；新增工具/颜色/粗细 3 组弹性滑动选中指示器；修正 macOS 26 `NSButton.alignmentRectInsets` 导致的蓝底选中块竖向拉高问题。
  - 涉及文件：`Sources/UI/DesignTokens.swift`、`Sources/UI/Editor/TBIcon.swift`、`Sources/UI/Editor/ToolbarPanel.swift`、`Sources/UI/Notification/CaptureToast.swift`、`Sources/UI/Scroll/ScrollCaptureViews.swift`、`Sources/UI/Overlay/FrozenSampler.swift`
- **取字（OCR）浮层重做**
  - 窗口层级升至 `.screenSaver + 3` 并精准避让工具栏可视区域（单行矮选区顺排工具栏下方或选区上方，高选区底缘避开工具栏），支持拖拽标题栏挪开对照原文；重构卡片排版、舒适行距与局部选词复制逻辑。
  - 涉及文件：`Sources/Adapters/OCR/OCRResultPanel.swift`、`Sources/UI/Editor/ToolbarPanel.swift`、`Sources/UI/Overlay/OverlayController.swift`
- **序号与文字标注视觉升级**
  - 序号徽章改为联动 3 档粗细（`24 / 28 / 32pt`）的 Apple / CleanShot 风格圆标（外白隔离环 + 向下柔影 + 微渐变 + `SF Pro Rounded Bold` 基于 `useGlyphPathBounds` 精确光学居中）。
  - 文字工具浮动字号条改为 `30pt` Liquid Glass 胶囊（`12 · 14 · 17 · 21` + 弹性滑块）；输入框支持自适应宽高、柔和对比衬底、虚线语义边框、实时同步工具栏改色与零基线跳动落盘；落盘文字增加克制可读性微影。
  - 涉及文件：`Sources/UI/Annotate/CGRenderer.swift`、`Sources/UI/Overlay/OverlayWindow.swift`、`Sources/UI/Editor/ToolbarPanel.swift`

### 性能与缺陷修复（Fixed）
- **视觉记忆库（`HistorySpotlightPanel`）搜索框宽度塌缩、无光标与外阴影缺失修复**
  - 修复搜索框 `trailingAnchor` 误用 `lessThanOrEqualTo` 导致空文本时宽度塌缩至 `~10pt`（占位符不可见、输入中文被裁切、右侧点击无法命中输入框）的问题：改为 `equalTo` 铺满整栏并降低水平拥挤优先级，右侧徽标与清除按钮收拢进自适应 `NSStackView`。
  - 移除 `SpotlightPanelWindow` 冗余 `.nonactivatingPanel` 标记，改用 `NSApp.activate(ignoringOtherApps: true)` + 次 tick 焦点兜底 + 整栏点击聚焦与 `iBeam` 光标，并显式设置高亮插入点光标色；同时接入 `OuterShadowView`（`Spec.spotlight`）为视觉记忆浮窗补齐 `.continuous` 镂空双层阴影。
  - 涉及文件：`Sources/UI/History/HistorySpotlightPanel.swift`、`Sources/UI/DesignTokens.swift`
- **滚动长图与贴图缩放拉伸模糊**
  - 重写 `PinWindow.constrainFrameRect`、新增 WindowServer `14400px` 位图安全上限与等比缩放几何；独立外源图（Toast 重开/长图/拼图）支持等比 8 手柄缩放、光标锚点滚轮/捏合缩放与双击 `适配 ↔ 1:1`。
  - 涉及文件：`Sources/Core/Domain/AnnotationModel.swift`、`Sources/Core/Domain/SelectionGeometry.swift`、`Sources/UI/Editor/EditorSession.swift`、`Sources/Adapters/Pin/PinWindow.swift`、`Sources/Adapters/Pin/PinWindowController.swift`、`Sources/UI/Overlay/OverlayWindow.swift`
- **重启后首次热键唤起卡顿 & Esc 关不掉**
  - 新增会话级 Carbon `Esc` 热键接管、禁用后台 App Nap（`ProcessInfo.beginActivity`）、缓存已授权 TCC 结果、离屏预热并按 `displayID` 池化复用 `OverlayWindow`、后移 `NSApp.activate()` 避免冷启动 ViewBridge 阻塞截帧、冻结底图改为 GPU `CALayer` 托管。
  - 涉及文件：`Sources/Adapters/Permission/TCCPermission.swift`、`Sources/Adapters/Capture/SCKCapture.swift`、`Sources/Adapters/Hotkey/CarbonHotKeyCenter.swift`、`Sources/App/AppCoordinator.swift`、`Sources/App/AppDelegate.swift`、`Sources/UI/Overlay/OverlayController.swift`、`Sources/UI/Overlay/OverlayWindow.swift`
- **移动/缩放选区框时背后文字轻微变形**
  - 移除拖动选框期间 `liveFrozenCrop()` 逐帧 CPU 裁剪与 `.none` 最近邻重采样，改由蒙层 `.clear` 挖空直接透出底层绝对静止的 GPU `frozenBackdropView`（过滤改为 `.linear`），并保持标注/边框/手柄全程稳定显示。
  - 涉及文件：`Sources/UI/Overlay/OverlayWindow.swift`
- **工具栏数字快捷键与视觉顺序错位（按 `2→3` 跳到第 4 项）**
  - 改为按 `toolbarOrderSafe()` 从左到右动态映射 `1–7`，并同步 Tooltip 快捷键编号。
  - 涉及文件：`Sources/UI/Editor/EditorKeyRouter.swift`、`Sources/UI/Editor/ToolbarPanel.swift`
- **文字工具回车落盘后 `⌘Z` 无法撤销**
  - 在 `OverlayView` 重写 `performKeyEquivalent(with:)` 优先接管编辑器 `⌘` 组合热键，避免被 `NSTextField` 激活过的系统菜单 `Edit → Undo` 吞键；提交时优先读取 `fieldEditor.string` 并显式 `endEditing(for:)` 稳妥归还焦点。
  - 涉及文件：`Sources/UI/Overlay/OverlayWindow.swift`

---

## [0.2.0-wip] — 2026-11-14 ~ 2026-11-19（基础闭环与滚动引擎）

- 完成六边形架构搭建（`Core/Domain`、`Core/Ports`、`Adapters`、`UI`）与固定证书签名流程。
- 实现区域/全屏/延时截图、7 种标注工具、Vision 本地 OCR、贴图 Pin、历史记录、自定义快捷键与工具栏排序、首次权限引导卡、Toast 点击重开编辑。
- 完成流式增量滚动截图拼接引擎（`Stitcher` + `TileMotionEstimator` + `ScrollCaptureController`）与 12 项回归单测。
