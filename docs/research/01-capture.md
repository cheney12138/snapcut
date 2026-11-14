# Snow Shot 功能行为规格 —— 截图的采集方式（capture / overlay / platform）

> 面向 Snapcut（Swift/AppKit）的功能提炼。只描述「用户可感知的行为」与「实现时必须先定的技术决策」，不涉及架构与设计模式。
> 源码位置均相对仓库根 `snow-shot/`。未找到证据的条目标「待查」。

## 0. 一句话结论（这个域最核心的行为）

1. **截图主流程 = 「先拍全部屏幕 → 再冻结屏幕选区」**：按下快捷键后，程序先把所有显示器当前画面拍下来（含鼠标光标），然后用逐显示器铺满的全屏覆盖窗把这帧静态画面盖在真实桌面上（用户感觉"屏幕被冻结"），在静态画面上做选区/编辑（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:74-134,648`；`snow_shot/include/snow_shot/presentation/screenshottypes.h:37-47`）。
2. **采集入口分两类**：① 交互式截图（进覆盖层选区）：区域截图、延时截图、滚动长截图、截图并钉到屏幕/OCR/复制/翻译/录屏等"选完再做 X"的变体；② 免交互直拍（不弹覆盖层）：截当前显示器、截前台窗口（`snow_shot/src/app/applicationcontroller.cpp:1692-1753`）。
3. **多显示器 / 混合 DPI 的核心规则**：macOS 上采集画布用"桌面点"坐标（每个显示器带 `backingScale`），像素尺寸 = 点 × backingScale；跨屏区域截图按每个被覆盖显示器各自裁切再拼成一张像素图，输出像素比例取所有相交显示器中最大的 scale（`snow-crates/crates/snow-macos/src/desktop.rs:265-302`；`snow_shot/src/presentation/capture/screenshotcaptureworker.cpp:228-232`）。
4. **窗口级截图走 ScreenCaptureKit 单窗口滤镜**，`setIgnoreShadowsSingleWindow(true)` 不带阴影，圆角/透明由带 alpha 的图像本身保留（`snow-crates/crates/snow-macos/src/capture.rs:229,268`）。
5. **智能选区默认开启**：鼠标悬停即高亮"窗口 / 窗口内 UI 子元素"（macOS 用 AX `AXUIElementCopyElementAtPosition` 命中测试），点击即完成选区，也可随时改为手动拖拽（`snow_shot/src/storage/configurationschema.cpp:1598`；`snow-crates/crates/snow-ui-selector/src/macos/native.rs:462`）。

## 1. 功能清单

| 功能 | 触发方式 | 行为细节 | 源码位置 |
|---|---|---|---|
| 区域截图（交互式） | 全局快捷键 `screenshot`（默认见设置）；托盘菜单"截图"；主窗口快捷操作 | 拍全部屏幕→覆盖层冻结屏幕→光标处智能选区或拖拽画矩形→确认后按动作出口（复制/保存/钉住等） | `snow_shot/src/app/applicationcontroller.cpp:1692-1696`；`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:74-134` |
| 延时截图 | 全局快捷键 `screenshot_delay`；延时秒数设置 `screenshot/delay_seconds` 默认 3 | 到点后走与区域截图完全相同的流程；请求期间被其它动作挤掉则丢弃、不排队重试 | `snow_shot/src/app/applicationcontroller.cpp:1697-1701`；`snow_shot/src/storage/configurationschema.cpp:1638`；`snow_shot/src/presentation/services/screenshotdelayedcapture_p.h:44-70` |
| 截图并钉到屏幕 | 快捷键 `screenshot_fixed` | 区域截图流程，选区确认后生成置顶贴图 | `snow_shot/src/app/applicationcontroller.cpp:1702-1706` |
| 截图 OCR / OCR 并复制 / 选中翻译 | 快捷键 `screenshot_ocr` / `screenshot_ocr_copy` / `screenshot_translation` | 同一区域截图流程，仅"选区确认后的后续动作"不同 | `snow_shot/src/app/applicationcontroller.cpp:1707-1724` |
| 滚动长截图 | 快捷键 `screenshot_scrolling` | 区域截图→选定区域内启动滚动采集：合成滚轮事件驱动页面滚动，逐帧拼接，缩略图实时预览、可裁剪 | `snow_shot/src/app/applicationcontroller.cpp:1725-1730`；`snow_shot/src/presentation/capture/screenshotscrollingcapturecontroller.cpp:146-238` |
| 截图并复制 / 保存 / 快速保存 | 快捷键 `screenshot_copy` / `screenshot_save` / `screenshot_quick_save` | 区域截图流程的变体出口 | `snow_shot/src/app/applicationcontroller.cpp:1731-1747` |
| 截当前显示器（免交互直拍） | 快捷键 `screenshot_full_screen`（注意：名字叫全屏，实际只拍**光标所在显示器**） | 不弹覆盖层；后台线程拍 CGGetDisplaysWithPoint 命中的显示器；按设置自动保存/复制文件/进历史；失败弹 toast | `snow_shot/src/app/applicationcontroller.cpp:1748-1750`；`snow_shot/src/presentation/capture/directcapturecontroller.cpp:306-317`；`snow_shot/src/platform/macos/screenshotnative.mm:761-771` |
| 截前台窗口（免交互直拍） | 快捷键 `screenshot_focused_window` | 取最前应用 layer 0 的窗口，整窗截取（含 alpha，无阴影）；同样自动保存/复制 | `snow_shot/src/app/applicationcontroller.cpp:1751-1753`；`snow_shot/src/presentation/capture/directcapturecontroller.cpp:285-298`；`snow_shot/src/platform/macos/screenshotwindowtarget_p.h:51-60` |
| 窗口截图（交互式，悬停选窗） | 区域截图覆盖层内移动鼠标 | 智能选区默认 `window_sub_element`：悬停高亮整窗或 UI 子元素，点击确认；可在覆盖层内用快捷键在"窗口/子元素"间切换 | `snow_shot/src/storage/configurationschema.cpp:1598`；`snow_shot/src/presentation/selector/screenshotselectorworkflow.cpp:114-118` |
| 重拍（Recapture） | 覆盖层内快捷键 `recapture`（需在移动工具下） | 保持现有选区，把除自身覆盖窗以外的屏幕重新拍一遍并替换底图；失败保留旧图并报错 | `snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:133-169,506-548`；`snow_shot/src/presentation/settings/settingscatalog.cpp:2733` |
| 复制上次选区（Duplicate latest region） | 覆盖层内快捷键 `duplicate_latest_region` | 在光标位置重建上一次会话的选区并直接确认；会话内还可用 `select_previously_selected_area` / `select_next_previously_selected_area` 在历史选区间切换 | `snow_shot/src/presentation/overlay/screenshotoverlayinputhandler.cpp:1730-1754`；`snow_shot/src/presentation/settings/settingscatalog.cpp:2723-2732` |
| 取消截图 | 覆盖层内 Esc（本地快捷键 `cancel_screenshot`） | 立即隐藏全部覆盖窗、释放采集会话与缓存、回到待命态；布局已脏则顺便刷新 | `snow_shot/src/presentation/overlay/screenshotoverlayshortcutcontroller.cpp:288-324`；`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:171-196` |

## 2. 关键交互细节

### 触发与准入
- **单实例准入**：开始截图前检查 `canBeginCapture()`——正在关闭、正在准备、采集挂起（suspend）、已有会话进行中、交互未复位、会话状态非 Idle 均拒绝；延时请求到期时同样二次检查，忙则**直接丢弃**（`snow_shot/src/presentation/services/screenshotcontroller.cpp:6333-6343`；`snow_shot/src/presentation/services/screenshotdelayedcapture_p.h:63-68`）。
- **弹窗清理**：开始前先关闭所有活动弹窗/模态（popup→modal 顺序关），关不掉就放弃本次截图（`snow_shot/src/presentation/services/screenshotcontroller.cpp:6364-6371`；`snow_shot/src/presentation/capture/screenshotcaptureinputblockers.h:13-26`）。
- **延时截图无倒计时 UI**：仅对外发出 `captureActivityChanged("delay")` 活动信号（托盘等可据此显示状态）；期间用户做了历史编辑等显式动作会 `invalidateDelayedCapture()` 取消未触发的请求（`snow_shot/src/presentation/services/screenshotcontroller.cpp:767-775,1844-1845,6313-6319,7020-7021`）。
- **延时范围钳制 1~10 秒**，超出设置值会被夹住（`snow_shot/src/presentation/services/screenshotdelayedcapture_p.h:50`）。
- **macOS 全局鼠标手势（按住拖拽启动截图）在 macOS 上被禁用**（配置为空对象，仅 Windows 可用）（`snow_shot/src/storage/configurationschema.cpp:1078-1096`）。
- **前台全屏窗口（游戏/视频）时全局快捷键可被禁用**：有 `disable_on_focused_fullscreen_window` 开关与过滤策略（`snow_shot/src/storage/configurationschema.cpp:1075-1077`）。

### 覆盖层（冻结屏幕后的行为）
- **覆盖窗逐显示器铺满**，内容是该显示器的采集帧（含拍下的鼠标光标贴片，`cursorPatch`），不是"半透明蒙层看实时桌面"（`snow_shot/include/snow_shot/presentation/screenshotoverlaywindow.h:64-68`；`snow_shot/src/presentation/capture/screenshotcaptureworker.cpp:236-249`）。
- **首次显示时机**：所有显示器的帧 + 初始智能选区结果都就绪才一次性显示完整第一帧，避免"选区跳动"；若期间显示器布局变化则整个取消重拍（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:613-663`）。
- **默认底图外无压暗**（`background_opacity_percent` 默认 0），选区尺寸显示单位默认"逻辑像素"（macOS 上另有物理像素选项）（`snow_shot/src/storage/configurationschema.cpp:1600,1488-1491`）。
- **选区类型默认矩形**，覆盖层内可切下一/上一类型（`snow_shot/src/storage/configurationschema.cpp:1595-1597`；`snow_shot/src/presentation/settings/settingscatalog.cpp:2711-2722`）。
- **双击行为默认"复制"**（`screenshot/double_click_action` 默认 `copy`）（`snow_shot/src/storage/configurationschema.cpp:1640`）。
- **光标处理**：采集帧内嵌真实光标（Windows 直接合成；macOS 通过 cursor patch），覆盖层上显示由设置 `showCursor` 控制的假光标，可切换光标可见性快捷键（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:104-107`；`snow_shot/src/presentation/settings/settingscatalog.cpp:2733-2734` 附近）。

### 失败与兜底
- **采集失败 → 自动取消整次截图**：底层报错（如会话创建失败、布局快照无效、返回帧无效）时打日志并 `cancelCapture()`，用户看到覆盖层根本不出现或立即消失（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:479-496`；`snow_shot/src/presentation/capture/screenshotcaptureworker.cpp:170-196`）。
- **布局漂移兜底**：捕获结果与启动时的 Qt 显示器布局不一致（stableId 对不上、屏幕 geometry 变了、物理矩形对不上）→ 判定布局脏并取消，等待刷新后再试（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:498-520,613-622`）。
- **显示器热插拔**：准备阶段发生变化直接取消；空闲期触发异步布局刷新（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:302-329`）。
- **重拍失败**：保留旧图回滚（旧 displays 快照恢复），并报"recapture returned invalid data / geometry is invalid"（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:506-548`）。
- **直拍失败**：托盘/主窗口弹 toast「Capture failed: <原因>」；资源超限时报 `resource_limit`（`snow_shot/src/presentation/capture/directcapturecontroller.cpp:118-122`；`snow_shot/src/presentation/capture/directcapturenative.cpp:83-88`）。
- **权限不足（macOS）**：截图动作触发时先做权限准入；缺屏幕录制权限会打开主窗口的权限引导页（`snow_shot/src/app/applicationcontroller.cpp:1608-1616,1680-1683`）。权限检测用 `CGPreflightScreenCaptureAccess` 预检、`CGRequestScreenCaptureAccess` 触发系统弹窗，并直接跳到系统设置的 `Privacy_ScreenCapture` 面板；每 2 秒轮询权限状态（`snow_shot/src/platform/macos/apppermissionbackend.mm:15-16,39,50,72`；`snow_shot/src/presentation/services/apppermissionservice.cpp:73-78`）。

### 滚动长截图细节
- 在覆盖层选定一个区域后启动；程序向目标窗口的 PID **定向投递合成滚轮事件**（像素级，不移动用户指针），按自适应节奏逐帧截取并拼接（`snow_shot/src/presentation/capture/screenshotscrollingcapturecontroller.cpp:229-238`；`snow_shot/src/platform/macos/screenshotnative.mm:784-846`；`snow_shot/src/presentation/capture/adaptivescrollingcapturecadence.h`）。
- 目标窗口下缘显示**实时缩略图**，悬停可预览已拼接内容并支持裁剪（trim）；滚动方向反转会重置采集与拼接状态；可切换手动滚轮/自动滚动模式，可暂停导出（`snow_shot/src/presentation/capture/screenshotscrollingcapturecontroller.cpp:182-206,254-266,293-295`）。
- 采集期间会把自身相关窗口从后续截帧里排除，避免缩略图被拍进素材（`excludeScrollingWindowsFromCapture`，`snow_shot/src/presentation/capture/screenshotscrollingcapturecontroller.cpp:177-181`）。
- 滚轮注入需要**辅助功能（Accessibility）权限**，无权限直接返回失败状态（`snow_shot/src/platform/macos/screenshotnative.mm:781-783`）。

## 3. 实现要点（必须先定的技术决策）

### 坐标系与 DPI（最重要）
- **双坐标系并存**：macOS 上采集画布用**桌面点**（`canvasUsesPoints = true`），图像用像素；每个显示器记录 `backingScale`（SCContentFilter 的 `pointPixelScale()`）与 `capturedLogicalRect`。`physicalRect` 仍是跨平台统一的"像素坐标契约"，macOS 上其原点对齐逻辑点、尺寸为像素（`snow_shot/include/snow_shot/presentation/screenshottypes.h:83-92`；`snow_shot/src/presentation/capture/screenshotcaptureworker.cpp:211-234`；`snow-crates/crates/snow-macos/src/capture.rs:232`）。
- **换算规则**：像素 = 点 × backingScale；逻辑→物理换算按"目标矩形中心落在哪个显示器"选该屏的 dpr，而不是全局一个 scale；Qt 侧 `physicalRectForScreen` 在 Windows 用原生显示器矩形（小数 DPI 不能靠圆整的逻辑尺寸反推），macOS 用 `geometry × devicePixelRatio`（`snow_shot/src/presentation/core/screenshotgeometry.cpp:860-906`）。
- **跨屏区域截图**：区域与每个相交显示器求交，输出像素比例取 `max(像素宽/点宽)`（各屏取最大），每个显示器的相交部分由系统各自渲染再按投影拼进同一张输出图（`snow-crates/crates/snow-macos/src/desktop.rs:265-302`）。跨屏选区因此能得到一张"混合 DPI 但视觉连续"的图。
- **HiDPI 导出缩放**：`auto` 模式——选区只落在单个屏且该屏 scale>1 时按 `1/dpr` 缩回逻辑尺寸导出；多屏混合 scale 一律 1:1 像素导出；手动模式 125%~350%（步进 25%）按 `100/percentage` 缩放（`snow_shot/include/snow_shot/presentation/screenshothidpiimagescaling.h:19-38`）。

### 采集 API 与参数
- macOS 统一走 **ScreenCaptureKit**：`SCShareableContent` 枚举显示器/窗口 → `SCContentFilter`（整屏 = `initWithDisplay:excludingApplications:exceptingWindows:`；单窗 = `initWithDesktopIndependentWindow:`）→ `SCScreenshotManager::captureSampleBufferWithFilter:configuration:completionHandler:`（`snow-crates/crates/snow-macos/src/capture.rs:211-232,344-350`）。
- **单窗截屏 `setIgnoreShadowsSingleWindow(true)`：不含阴影**；`setShowsCursor` 按模式控制；HDR 可开 `SCCaptureDynamicRange::HDRCanonicalDisplay` + 64RGBAHalf；普通为 BGRA/sRGB（`snow-crates/crates/snow-macos/src/capture.rs:266-279`）。
- **圆角/透明**：窗口帧按 `Premultiplied` alpha 处理（SCK 后端），圆角处保持透明（`snow_shot/src/presentation/capture/directcapturenative.cpp:155-159`）。
- **窗口定位**：前台窗口 = `NSWorkspace.frontmostApplication` 的 PID → `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements)` 中取该 PID 且 **layer==0** 的第一个窗口（只取根层窗口，不含子窗口层级概念）；光标处显示器 = `CGGetDisplaysWithPoint`（`snow_shot/src/platform/macos/screenshotnative.mm:581-591,761-775`；`snow_shot/src/platform/macos/screenshotwindowtarget_p.h:51-60`）。
- **悬停选窗/子元素**：整窗用 SC 窗口边界；UI 子元素用 `AXUIElementCopyElementAtPosition`（AX 命中测试），并对自己进程的窗口跳过 AX 以避免非 GUI 线程进 AppKit（`snow-crates/crates/snow-ui-selector/src/macos.rs:99-137`；`snow-crates/crates/snow-ui-selector/src/macos/native.rs:462`）。
- **排除自身窗口**：截图会话创建时传入要排除的窗口 ID 列表（覆盖窗、缩略图等），后端按 `SCContentFilter ... exceptingWindows:` 排除；排除列表在会话创建时固定，改动需重建会话（`snow_shot/src/presentation/capture/screenshotcaptureworker.cpp:286-310`；`snow-crates/crates/snow-macos/src/capture.rs:199-228`；`snow_shot/src/presentation/capture/windowcaptureexclusion.h:33-57`）。
- **会话复用与重试**：桌面采集会话按后端+排除集缓存复用，`capture_retry_count = 1`；失败后重置到 prepared 态或销毁重建（`snow_shot/src/presentation/capture/screenshotcaptureworker.cpp:286-330,172-181`）。
- **离屏窗口**：窗口目标必须 `isOnScreen`，否则报 `TargetUnavailable`（持久跟随模式例外）（`snow-crates/crates/snow-macos/src/desktop.rs:355-360`）。
- **区域必须在桌面点空间**（Points），传入像素空间直接拒绝； raster 准入（超大图拒绝）在原生层做（`snow-crates/crates/snow-macos/src/desktop.rs:269-271`；`snow-crates/crates/snow-macos/src/capture.rs:252-256`）。

### 显示层（freeze）实现要点
- **为什么冻结**：截图过程中若直接看实时桌面，选区下的内容会变化（动画、视频、光标移动），且覆盖层自身必须不能被拍进图。所以先把"干净的最后一帧"（已排除自身窗口）拍下来，再把逐显示器的全屏覆盖窗盖上去编辑——编辑对象是静态帧，天然一致且可重拍（recapture）。
- 覆盖窗为非激活面板（不抢焦点）、逐屏一窗、统一 canvas 原点跨屏连续（`snow_shot/include/snow_shot/platform/screenshotnative.h:14-16`；`snow_shot/include/snow_shot/presentation/screenshotgeometry.h:119-146`）。
- **显示前的就绪门槛**：Qt 屏 geometry、物理矩形、捕获帧三方一致才 reveal；smart selection 初始结果未返回时延迟 reveal（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:613-663`）。
- **显示前激活本应用**：macOS 在开始会话前 `m_sessionFocus->prepare()`，保证覆盖层能盖在目标空间上（`snow_shot/src/presentation/services/screenshotcontroller.cpp:6360-6363`）。

### 快捷键体系
- 全局快捷键动作清单（截图相关）：Screenshot、ScreenshotDelay、ScreenshotPinToScreen、ScreenshotOcr、ScreenshotOcrCopy、ScreenshotTranslation、ScreenshotScrolling、ScreenshotCopy、ScreenshotSave、ScreenshotQuickSave、ScreenshotFullScreen、ScreenshotFocusedWindow（`snow_shot/src/presentation/services/globalshortcutmanager.cpp:28-59`）。
- 覆盖层本地快捷键（示例）：cancel_screenshot、recapture、duplicate_latest_region、select_previously_selected_area、switch_selection_between_window_and_window_sub_element、next/previous_selection_type、toggle_cursor_visibility（`snow_shot/src/presentation/settings/settingscatalog.cpp:2699-2740`）。

### 声音与通知
- 可选快门音（设置 `shutterSoundNotification`，区域与直拍都触发）（`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp:128-131`；`snow_shot/src/presentation/capture/directcapturecontroller.cpp:217`）。

## 4. 我们可以先不做的（Snapcut 初版可裁剪）

1. **全局鼠标手势触发截图**：Snow Shot 在 macOS 上本身就未启用（配置为空）——Snapcut 不需要（`snow_shot/src/storage/configurationschema.cpp:1078-1096`）。
2. **Windows 专属分支**：GDI/DXGI/WGC 三后端切换、屏幕色彩还原（`restore_original_screen_colors` 是 Windows-only 的色彩校正，macOS 端为 no-op）、游戏窗口分类（`snow-crates/crates/snow-capture-c/src/lib.rs:1777-1800,2100-2115`；`snow_shot/src/storage/configurationschema.cpp:1075-1077`）。
3. **HDR 采集**（`SCCaptureDynamicRange::HDRCanonicalDisplay` + half-float 管线）——初版 sRGB/BGRA 即可（`snow-crates/crates/snow-macos/src/capture.rs:281-287`）。
4. **UI 子元素级智能选区（AX 遍历 + 预算控制）**：macOS 实现重（AX 超时 50ms、traversal budget、进程白名单）；初版只做"整窗悬停高亮"即可覆盖主场景（`snow-crates/crates/snow-ui-selector/src/macos.rs:99-143`；`snow-crates/crates/snow-ui-selector/src/macos/traversal.rs`）。
5. **重拍（recapture）期间的 GPU 资源复用、live window 持续采集（1~30fps 跟踪窗口）**：属于性能/钉图高级特性（`snow-crates/crates/snow-capture/src/platform/macos.rs:178-192`）。
6. **滚动长截图的自动滚动 + 反向重置 + 裁剪编辑器全家桶**：可以后置；但"合成滚轮事件"这一步在 macOS 需要 Accessibility 权限并要用 `CGEventPostToPid` + 未公开的 `CGEventSetWindowLocation` 桥接，若初版不做可整体推迟（`snow_shot/src/platform/macos/screenshotnative.mm:806-846`）。
7. **MCP/自动化截图接口**（`mcpCapture`、target/scale 参数）——非核心（`snow_shot/src/presentation/capture/directcapturecontroller.cpp:320-462`）。
8. **直拍的 PDF 导出、复制图片文件（copy file to clipboard）等出口变体**——属导出域（`snow_shot/src/presentation/capture/directcapturecontroller.cpp:217-224`）。

## 5. 验收标准（可实测）

1. **区域截图冻结屏幕**：触发快捷键后 ≤500ms（冷启动可放宽）屏幕"定住"——动画/视频画面不再变化，显示的是按下瞬间的帧；Esc 立即恢复真实桌面，桌面上无残留窗口。
2. **光标入图**：截取的帧中包含按下快捷键时的鼠标光标图像。
3. **像素尺寸换算**：在 2x Retina 屏上框选逻辑 200×100pt 的区域，导出图像为 400×200px；设置 HiDPI=auto 时导出 200×100px。
4. **跨屏选区**：选区横跨两台不同 DPI 的显示器时，能产出一张视觉连续的拼合图，每屏部分的清晰度不低于该屏原生像素密度。
5. **窗口截图无阴影带透明**：对前台窗口做窗口截图，结果图不含投影阴影，圆角外像素 alpha=0。
6. **只截光标所在显示器**：`截当前显示器` 动作在多屏环境把结果保存/复制后，检查图像尺寸与光标所在屏物理像素一致，另一屏内容不出现。
7. **前台窗口截图**：切到某应用按 `截前台窗口`，结果恰为该应用最前窗口的 bounding box 内容（layer 0，不含菜单栏/其它 app 悬浮窗）。
8. **延时截图**：设 3 秒延时触发后 3 秒才进入冻结态；期间做其它显式动作（如打开历史）则延时被取消，不会在操作中途突然弹出截图。
9. **自身窗口不入图**：覆盖层显示期间触发 recapture，新底图中不包含覆盖层自己的任何窗口内容。
10. **权限引导**：首次使用且未授予屏幕录制权限时触发截图 → 打开权限引导页并可一键跳到系统设置「屏幕录制」面板；授权后 2 秒内状态刷新、无需重启。
11. **失败兜底**：人为让采集失败（如冷启动即断开显示器），应用不崩溃、无半渲染的覆盖层残留，托盘/日志可见失败记录。
12. **滚动长截图**：在长页面区域启动后，页面自动按节奏滚动，缩略图持续增长；停止后输出拼接图，接缝无明显错位；反向滚动后重新正向滚动不产生重影（Snow Shot 会重置拼接状态）。

## 附：证据索引（本档引用的关键文件）

- 工作流/会话：`snow_shot/src/presentation/capture/screenshotcaptureworkflow.cpp`、`screenshotcaptureworker.cpp`
- 直拍：`snow_shot/src/presentation/capture/directcapturecontroller.cpp`、`directcapturenative.cpp`
- 延时：`snow_shot/src/presentation/services/screenshotdelayedcapture_p.h`、`screenshotcontroller.cpp`
- 平台（macOS）：`snow_shot/src/platform/macos/screenshotnative.mm`、`screenshotwindowtarget_p.h`、`apppermissionbackend.mm`
- 原生采集（Rust）：`snow-crates/crates/snow-macos/src/desktop.rs`、`capture.rs`、`content.rs`；`snow-crates/crates/snow-capture/src/platform/macos.rs`
- 智能选区：`snow-crates/crates/snow-ui-selector/src/macos.rs`、`macos/native.rs`
- 滚动长截图：`snow_shot/src/presentation/capture/screenshotscrollingcapturecontroller.cpp`、`adaptivescrollingcapturecadence.h`
