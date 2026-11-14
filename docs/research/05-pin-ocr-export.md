# Snow Shot 功能行为规格：贴图窗口 + OCR/取字 + 导出与历史

> 提炼自 Snow Shot（C++/Qt/Rust）源码，供 macOS 原生截图工具 Snapcut（Swift/AppKit）参考。
> 只描述功能与产品行为；所有行号均为相对仓库根目录的 `文件:行号`。

## 0. 一句话结论（这个域最核心的 3-5 个行为）

1. **贴图（Pin）是一个持久化实体**：每张贴图 = 无边框置顶 `Tool` 窗口 + 磁盘记录（`pinned_windows_v2/index.json` + 每 ID 载荷目录）；**重启后自动恢复**当前分组内未隐藏/未关闭的贴图（`snow_shot/src/presentation/selection/screenshotselectionexportuiservices.cpp:1484`，`snow_shot/src/storage/pinnedwindowstorageconstants_p.h:5`）。
2. **关闭 ≠ 删除**：普通「关闭」把记录标记为 `ignored` 保留在磁盘，可用 `Ctrl+F3`（默认）恢复最近关闭的一张；「销毁（Destroy）」才真正删除且需确认（`snow_shot/src/presentation/selection/screenshotselectionexportuiservices.cpp:2001`，`snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:10083`）。
3. **OCR 结果贴在原选区位置的可编辑浮层里**：识别窗口无边框、置顶、尺寸=选区，文字按识别行位渲染，可逐行编辑、可选中复制，支持 Ctrl+A/Ctrl+C/撤销重做；另有「识别并直接复制」的全局快捷键路径（`snow_shot/src/presentation/ocr/screenshotrecognitionwindow.cpp:456`，`snow_shot/src/presentation/ocr/screenshotocrcontroller.cpp:387`）。
4. **导出默认是复制到剪贴板**，保存文件是显式动作；文件名/目录由模板变量（`{YYYY-MM-DD_HH-mm-ss}`、`{AN}`应用名、`{WN}`窗口名）生成，默认 `SnowShot_{YYYY-MM-DD_HH-mm-ss}.png`、目录默认系统「图片」；所有导出路径（复制/保存/贴图/直拍）**都会自动写历史**（`snow_shot/src/storage/configurationschema.cpp:1715`，`snow_shot/src/presentation/services/screenshotcontroller.cpp:3724`）。
5. **剪贴板写入是多格式 + 重试兜底**：macOS 写 PNG+TIFF（+可选 FileURL），Windows 写 PNG+DIB+文件句柄；忙（Busy）时按 10/25/60/100ms 重试至多 5 次、总时长 300ms 封顶，失败仅记日志并回调错误（`snow_shot/src/platform/macos/imageclipboard.mm:189`，`snow_shot/src/presentation/services/screenshotclipboardservice.cpp:105`）。

## 1. 功能清单

| 功能 | 触发方式 | 行为细节 | 源码位置 |
|---|---|---|---|
| 选区贴图 | 截图工具栏「贴图」按钮 / 全局快捷键 `screenshot_fixed`（默认未绑键）/ 托盘快捷动作 | 完成选区后生成贴图窗口，出现在选区原位；可选「贴图同时复制」（`copy_after_pinning_to_screen`，默认 false）与「贴图后自动保存」 | `snow_shot/src/presentation/services/screenshotcontroller.cpp:3453`，`snow_shot/src/storage/settingsadapters.cpp:1164` |
| 剪贴板贴图 | 全局快捷键 `pin_clipboard_content`（默认 **F3**） | 读剪贴板：图片→贴图；文件路径（带自定义 placement/appearance MIME）→按原位置贴图；文本→文本贴图窗口；重复内容可配置（重贴/恢复上一张关闭/抖动提醒） | `snow_shot/src/storage/configurationschema.cpp:1060`，`snow_shot/src/presentation/services/screenshotcontroller.cpp:4111`，`snow_shot/src/presentation/selection/screenshotselectionexportuiservices.cpp:1963` |
| 贴图窗口外观 | — | 无边框、`Tool`、置顶（可切换）、半透明背景、无系统阴影；边框/阴影/圆角由选区样式自绘；`alwaysOnTop` 默认 true | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:943`，`snow_shot/include/snow_shot/storage/pinnedwindowtypes.h:158` |
| 缩放 | 滚轮 / 双指捏合 / 菜单+/- | 滚轮以光标为锚点缩放，范围 **10%–500%**；窗口内显示缩放百分比读数 | `snow_shot/src/presentation/pinned/screenshotpinnedinteraction.cpp:666`，`snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:1937` |
| 旋转/翻转/复位 | 快捷命令 `rotate_clockwise/counter_clockwise`、`flip_horizontal/vertical`、`reset_transform` | 90° 步进旋转（持久化 `quarter_turns` 0–3）、水平/垂直翻转、一键复位 | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:1384`，`snow_shot/src/storage/pinnedwindowrepository.cpp:682` |
| 透明度 | 菜单/快捷命令 `increase_opacity/decrease_opacity` | 1–100%（恢复时下限 25% 若处于隐藏模式）；穿透模式有独立不透明度（默认 50%），穿透时显示独立的不透明度编辑控件 | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:1984`，`snow_shot/include/snow_shot/storage/pinnedwindowtypes.h:144` |
| 鼠标穿透 | 快捷命令 `pinned.toggle_click_through` | 窗口设为输入穿透；在贴图旁悬浮「不透明度滑条+移动+退出穿透」控件；退出按钮几何按屏幕边界夹取 | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:1302`，`snow_shot/src/presentation/pinned/screenshotpinnedclickthroughgeometry.cpp:8` |
| 隐藏到屏幕顶边 | 快捷命令 `pinned.hide_to_top` | 收缩为屏幕顶边的一个小「手柄」，悬停/点击唤出；手柄几何与强调色持久化 | `snow_shot/src/presentation/pinned/screenshotpinnedhidetotopcontroller.h:33`，`snow_shot/src/storage/pinnedwindowrepository.cpp:684` |
| 缩略图模式 | 快捷命令 `pinned.thumbnail_mode` | 在缩略图与原尺寸间切换，原几何持久化（`preThumbnailPlacement`） | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:1280`，`snow_shot/src/storage/pinnedwindowrepository.cpp:495` |
| 锁定模式 | 快捷命令 `pinned.toggle_lock` | 锁定后禁止编辑类操作 | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:1319` |
| 关闭贴图 | `pinned.close` / 窗口关闭快捷键 | 可配置关闭前确认（弹窗「Close this pinned window?」）；关闭 = 记录标记 `ignored`+`lastClosedUtc`，可恢复 | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:9859`，`snow_shot/src/storage/pinnedwindowrepository.cpp:1288` |
| 销毁贴图 | `pinned.destroy` | 确认弹窗「This action cannot be undone」后从存储永久删除 | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:10083` |
| 恢复最近关闭 | 全局快捷键 `restore_last_closed_windows`（默认 **Ctrl+F3**）/ 重复贴图配置 | 按 `activitySequence`/`lastClosedUtc` 取最近一条未忽略记录恢复 | `snow_shot/src/presentation/selection/screenshotselectionexportuiservices.cpp:2001`，`snow_shot/src/storage/configurationschema.cpp:1066` |
| 重启恢复 | 应用启动（延迟恢复请求） | 读取当前分组内非隐藏/非忽略记录，按批次恢复且不抢焦点；恢复失败弹错误提示 | `snow_shot/src/presentation/selection/screenshotselectionexportuiservices.cpp:1484`，`snow_shot/src/presentation/services/screenshotcontroller.cpp:1616` |
| 贴图分组 | 托盘「窗口分组」子菜单 / `switch_window_group` 快捷键 | 默认组「Default」，可建多组；切组时其他组窗口关闭（记录保留），恢复当前组窗口 | `snow_shot/src/storage/pinnedwindowrepository.cpp:42`，`snow_shot/src/presentation/services/pinnedwindowgroupmanager.cpp:305` |
| 贴图管理页 | 主窗口「贴图管理」（托盘动作 `open_pin_to_screen_management`） | 浏览所有贴图记录、恢复/删除/分组管理 | `snow_shot/src/app/applicationcontroller.cpp:1807` |
| 贴图批量保存 | 贴图菜单「保存所有显示的贴图」 | 选目录后把所有可见贴图导出为文件（含复制贴图文件到剪贴板变体） | `snow_shot/src/presentation/pinned/screenshotpinnedbatchsave.cpp:532` |
| 贴图拖出 | 从贴图窗口拖拽 | `QDrag` CopyAction 导出图片/文件给其他应用，临时文件带保留期 | `snow_shot/src/presentation/pinned/screenshotpinneddragexport.cpp:141` |
| 活动窗口贴图 | 截图选到窗口时选择「实时贴图」 | 贴图内容跟随源窗口实时刷新；源窗口最小化/关闭时显示状态兜底视图 | `snow_shot/src/presentation/services/screenshotcontroller.cpp:3372`，`snow_shot/src/presentation/pinned/livewindowsource.cpp:30` |
| 贴图上标注 | 贴图编辑模式 / 快速文字标注工具栏 | 在贴图上绘制标注；可选「贴图后标注保持可编辑」 | `snow_shot/src/presentation/pinned/screenshotpinnededitcontroller.cpp`，`snow_shot/src/storage/settingsadapters.cpp:1180` |
| 打印贴图 | `pinned.print` | 调系统打印 | `snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:1167` |
| OCR（文字识别） | 工具栏 OCR 工具（选区后）/ 全局快捷键 `screenshot_ocr` / 托盘快捷动作「文字识别」 | 无选区时提示「Select an area to recognize」；选区（含非矩形区域）识别 | `snow_shot/src/presentation/ocr/screenshotocrcontroller.cpp:450`，`snow_shot/src/storage/configurationschema.cpp:1011` |
| OCR 识别并复制 | 全局快捷键 `screenshot_ocr_copy` | 识别完成后直接把文本写入剪贴板并结束截图会话 | `snow_shot/include/snow_shot/presentation/globalshortcuttypes.h:33`，`snow_shot/src/presentation/ocr/screenshotocrcontroller.cpp:391` |
| OCR 结果呈现 | — | 置顶无边框窗口精确覆盖选区；文本按行位渲染；可选文字高亮遮罩；可显示原图预览对比 | `snow_shot/src/presentation/ocr/screenshotocrcontroller.cpp:104`，`snow_shot/src/presentation/ocr/screenshotrecognitionwindow.cpp:1042` |
| OCR 文本编辑/复制 | Ctrl+C / Ctrl+A / 工具栏复制按钮 | 文本可选中、可逐行编辑（QTextEdit，支持撤销/重做）；复制支持「仅选区/全部」与文本后处理（智能去换行/强制去换行、全半角标点转换） | `snow_shot/src/presentation/ocr/screenshotrecognitionwindow.cpp:2007`，`snow_shot/src/presentation/ocr/screenshotocrtexttransform.cpp:75` |
| 表格识别 | 工具栏 Table 工具 | 识别为可编辑表格：合并/拆分单元格、重置、撤销/重做，复制为表格/文本 | `snow_shot/src/presentation/ocr/screenshotrecognitionwindow.cpp:1434` |
| 公式识别 | 工具栏 Latex 工具 | 识别为 LaTeX，可编辑并渲染预览 | `snow_shot/src/presentation/ocr/screenshotrecognitionwindow.cpp:1552` |
| 图片转 Markdown/HTML | 工具栏转换工具 | 图转 Markdown/HTML 文本 | `snow_shot/src/presentation/services/screenshotcontroller.cpp:2762` |
| 二维码识别 | 工具栏 QR 工具 / Table-QR 入口切换 | OpenCV WeChatQRCode 解码（多码支持），无二维码时降级一维条码；结果可全选复制 | `snow_shot/src/presentation/ocr/screenshotqrrecognitionservice.cpp:152`，`snow_shot/src/presentation/ocr/screenshotrecognitionwindow.cpp:2022` |
| 复制到剪贴板 | 截图完成默认动作 / 工具栏复制 / `Ctrl+F1`（默认） | 默认导出即复制（PNG 编码进剪贴板）；可配置复制后执行动作（含自动保存） | `snow_shot/src/storage/configurationschema.cpp:1021`，`snow_shot/src/presentation/services/screenshotcontroller.cpp:182` |
| 保存为文件 | 工具栏「保存」/ `screenshot_save` 快捷键 | 可选系统对话框或内置对话框（`save_as_file_dialog` 默认 `system`）；8 种格式；记住上次目录与格式 | `snow_shot/src/presentation/services/screenshotmanualsave.cpp:44`，`snow_shot/src/storage/configurationschema.cpp:1668` |
| 快速保存 | `screenshot_quick_save` 快捷键 | 跳过对话框，直接按模板写入 `image_save_directory`，文件名冲突自动避让 | `snow_shot/src/presentation/services/screenshotcontroller.cpp:4641`，`snow_shot/src/presentation/services/screenshotimagefileservice.cpp:143` |
| 自动保存 | `auto_save_after_execution_actions`（默认空） | 可配置在复制/贴图/长截图等动作后顺带落盘 | `snow_shot/src/storage/settingsadapters.cpp:1142`，`snow_shot/src/presentation/services/screenshotcontroller.cpp:3464` |
| 历史记录 | 托盘菜单 / 全局快捷键 `open_capture_history`（默认未绑）/ 主窗口历史页 | 每次复制/保存/贴图/直拍自动成档；条目含完整画布编辑会话，可重新编辑 | `snow_shot/src/storage/capturehistoryrepository.cpp:94`，`snow_shot/src/presentation/components/screenshothistorypagewidget.cpp:870` |
| 历史条目操作 | 条目按钮与「…」菜单 | 编辑、复制结果、贴图、拼图、拆图、图像编辑、复制文件路径、在文件夹中显示、删除；支持多选批量 | `snow_shot/src/presentation/components/screenshothistorypagewidget.cpp:870` |

## 2. 关键交互细节（用户可感知）

**贴图窗口**
- 窗口无系统边框与系统阴影，但可显示自绘边框（默认开）与阴影（默认关，可切换 `pinned.show_shadow`）；阴影/圆角继承截图选区样式（`screenshotpinnedwindow.cpp:1350`，`snow_shot/src/storage/pinnedwindowtypes.h:112`）。
- 贴图可跨过 macOS 菜单栏/刘海区域（显式关闭安全区内边距，`screenshotpinnedwindow.cpp:946`）。
- 点击贴图会提升其在贴图栈中的层级（多贴图互不遮死：栈协调器维护顺序，`screenshotpinnedwindow.cpp:935`）。
- 关闭确认/销毁确认均可在设置中关闭；关闭确认文案「Close this pinned window?」，销毁确认明确写「cannot be undone」且按钮为危险色（`screenshotpinnedwindow.cpp:2166`，`:10096`）。
- 重复贴同一内容（F3 连按）不产生新窗口：按「重复内容动作」设置执行重复动作/恢复最近关闭/抖动提醒已有窗口（`screenshotselectionexportuiservices.cpp:1983`）。
- 隐藏到顶边后，手柄悬停即可唤出，带动画；隐藏模式下恢复时透明度下限被钳到 25%（`screenshotpinnedwindow.cpp:1984`）。
- 穿透模式下贴图本身不接收鼠标，但悬浮控件（不透明度滑条、移动钮、退出穿透钮）始终可点；控件位置自动避让屏幕边缘（`screenshotpinnedclickthroughgeometry.cpp:20`）。
- 活动窗口贴图：源窗口最小化/关闭/暂不可用时显示状态提示卡片而非空白（`livewindowsource.cpp:30`）。
- 贴图记录同时保存识别结果与文字标注，恢复后 OCR 浮层照原样还原（`pinnedwindowtypes.h:128`）。
- 多显示器：记录保存屏幕名+序列号+逻辑几何；恢复时窗口单位与目标显示器 DPI 解耦，缩放比由几何重新推导而非沿用旧值（`pinnedwindowtypes.h:136`，`screenshotpinnedwindow.cpp:2462`）。

**OCR/取字**
- 入口共 4 类：选区后工具栏点击、全局快捷键（`screenshot_ocr` 默认未绑）、托盘菜单快捷动作、「识别并复制」快捷键（识别→复制→自动结束截图，不打断流程）。
- 无选区触发识别：不弹窗，只在工具栏位置提示「Select an area to recognize」（`screenshotocrcontroller.cpp:468`）。
- 识别窗口锁定为选区尺寸（`setFixedSize`），跟随选区调整实时同步几何；macOS 上被压在工具栏/气泡之下（`screenshotrecognitionwindow.cpp:573`，`:587`）。
- 文本流式更新期间编辑器只读，识别完成解锁；编辑器逐行对应识别行，可撤销/重做（`screenshotrecognitionwindow.cpp:2108`）。
- 复制行为：有选区复制选区，无选区复制全部可见文本；复制前可应用文本变换（去换行、全/半角标点，「smart」为默认智能整理）（`screenshotocrtexttransform.cpp:86`）。
- 识别失败：恢复之前激活的工具并提示，不会留下空白窗口（`screenshotocrcontroller.cpp:510`）。
- OCR 引擎为 PaddleOCR PP-OCRv6（默认 Small），CPU 推理、可选 GPU（Apple Silicon 用 Metal），模型 SHA-256 校验、常驻/热启动可配，置信度 <0.5 过滤（`snow_shot/packaging/ocr-models.md`）。
- 二维码：先 QR 后一维条码降级；模型缺失时打日志并优雅降级（`screenshotqrrecognitionservice.cpp:88`）。

**导出**
- 复制路径无对话框、无打断；保存路径才有对话框（系统/内置二选一）。
- 文件名模板变量：`{…}`内任意 Qt 日期格式（YYYY/YY/DD 映射）+ `{AN}`（应用名）+ `{WN}`（窗口名），可组合；非法字符替换为 `_`，Windows 保留名（CON/NUL…）前加 `_`，组件按 UTF-8 字节数截断且不产生结尾点/空格（`snow_shot/src/storage/screenshotexportvariables.cpp:14`，`snow_shot/src/storage/exportfilename.cpp:24`）。
- 快速保存/自动保存：目录不存在自动 `mkpath`；重名自动避让（`collisionSafePath`）；失败给出明确错误消息（`screenshotimagefileservice.cpp:137`）。
- 手动保存记住「上次目录 + 上次格式 + 格式选项」（`screenshotmanualsave.cpp:100`）。

**历史**
- 打开方式：托盘菜单项、全局快捷键、主窗口页签；条目预览用轮播展示「结果图 + 各显示器原图」。
- 记录默认保留 **7 天 / 100 条 / 1024 MiB**，超限按 activitySequence 从旧到新清理；可设「永久保留」（`snow_shot/src/storage/capturehistorypolicy_p.h:13`）。
- 「编辑」会把画布会话（元素 + 撤销/重做历史）还原进编辑器，等于从历史无缝续编（`snow_shot/src/presentation/services/screenshothistoryservice.cpp:30`）。
- 贴图历史独立成库（`pinned_windows_v2`），策略参数与截图历史相同（7 天/100 条/1024 MiB）；每 60 秒跑一次保留策略清理（`snow_shot/src/storage/applicationstorage.cpp:386`）。

**失败兜底**
- 剪贴板：忙重试 5 次（10/25/60/100ms，总 300ms 封顶），失败枚举区分 ClipboardUnavailable/Busy/ClearFailed/PublishFailed/InvalidPayload，全部进诊断日志并回调（`screenshotclipboardservice.cpp:105`，`:455`）。macOS 发布成功后主动同步 Qt 原生读取器并发射 `dataChanged`（`imageclipboard.mm:226`）。
- 贴图：即使后续剪贴板写入失败，贴图成功仍照常写入历史（`screenshotcontroller.cpp:3738`）。
- 恢复贴图失败：弹「The pinned window could not be restored」错误（`screenshotcontroller.cpp:1621`）。
- OCR 模型获取失败：报告所选模型的错误，不静默切换到别的模型（`ocr-models.md`）。

## 3. 实现要点（先定的技术决策）

1. **贴图几何与缩放比**：记录以「窗口原生像素几何 + 初始窗口尺寸」存储，恢复时缩放比 = 几何/初始尺寸重新推导，`scalePercent` 仅作参考快照；这样换显示器/换 DPI 恢复不变形（`snow_shot/src/presentation/pinned/screenshotpinnedwindow.cpp:2462`，`snow_shot/include/snow_shot/storage/pinnedwindowtypes.h:133`）。Snapcut 对应决策：贴图状态应存「相对比例 + 屏幕标识」而非绝对像素。
2. **屏幕标识**：`screenName + screenSerial + screenLogicalGeometry` 三元组定位屏幕（`pinnedwindowtypes.h:136`）。macOS 必须用 display UUID 而非索引。
3. **剪贴板格式矩阵**：macOS=PNG+TIFF（+自定义 `com.snowshot.screenshot-placement/-appearance` + 可选 FileURL）；Windows=注册格式 `PNG`+CF_DIB+CF_HDROP（`imageclipboard.mm:202`，`screenshotclipboardservice.cpp:493`）。Snapcut 至少要写 PNG+TIFF 双格式保证兼容。
4. **剪贴板重试阈值**：5 次 / 300ms / 指数化延迟，这是对抗剪贴板被其他应用占用（Busy）的实测参数（`screenshotclipboardservice.cpp:105`）。
5. **OCR 引擎与阈值**：PP-OCRv6 CPU 推理、置信度 <0.5 过滤、检测最大边自适应 960/1500/2000、识别宽对齐 32px；模型按 SHA-256 校验缓存（`snow_shot/packaging/ocr-models.md`）。Snapcut 选 Vision.framework 时行为对齐点：置信度过滤与空行过滤。
6. **OCR 坐标系**：识别服务返回原图坐标系的四边形+置信度+文本，呈现层再映射到画布坐标（`snow_shot/src/presentation/ocr/screenshotocrrecognitionservice.cpp:56`）；识别窗口几何 = 选区画布坐标经显示器映射到逻辑坐标（`screenshotocrcontroller.cpp:104`）。
7. **历史/贴图存储布局**：`<AppData>/capture_history/index.json`(v3)+每记录 `canvas_history.json`+图像文件；`<AppData>/pinned_windows_v2/index.json`+每 ID 载荷目录；原子写（QSaveFile）+后台工作线程（5s 空闲超时）（`capturehistoryrepository.cpp:586`，`pinnedwindowrepository.cpp:43`，`capturehistoryrepository.cpp:50`）。AppData 取 `QStandardPaths::AppDataLocation`，支持便携模式与目录切换（`applicationstorage.cpp:300`）。
8. **历史体量上限**：单画布 JSON ≤16 MiB、单图 ≤64M 像素、单记录 ≤128M 像素、≤32 显示器——写历史前先做这些硬校验，防止一张 8K 长图拖垮内存（`capturehistoryrepository.cpp:44`）。
9. **保留策略执行**：到期清理先于配额清理；只清理 `ignored`（已关闭）记录，活跃贴图永不被策略清掉；清理扫描与写入用读写锁互斥（`pinnedwindowrepository.cpp:3310`，`capturehistoryrepository.cpp:3178`）。
10. **置顶层级**：Qt `WindowStaysOnTopHint` + 平台层可动态开关（`pinnedwindowplatform.h:52`）；识别窗口在 macOS 上要压在工具栏之下，需要专门的层级行配置（`screenshotrecognitionwindow.cpp:577`）。Snapcut 注意：NSWindow level 需要区分「贴图级」与「截图遮罩级」。
11. **默认快捷键**：截图 F1、复制 Ctrl+F1、剪贴板贴图 F3、恢复最近关闭贴图 Ctrl+F3；OCR/保存等默认不绑键（`configurationschema.cpp:1005`，`kSchemaStrings20-23` at `:511`）。

## 4. 我们可以先不做的（非核心 / 平台相关 / 依赖网络）

- **多贴图分组系统**（组切换、按组恢复）——单列表足够起步。
- **活动窗口贴图（Live Pin）**——依赖窗口帧捕获与各平台窗口跟踪，且 macOS 实现细节待查。
- **贴图批量保存 / 打印 / AirDrop 分享**——低频辅助动作。
- **表格识别 / 公式(LaTeX)识别 / Markdown/HTML 图片转换 / 翻译**——依赖在线模型或重型管线，且编辑器成本高。
- **OCR 模型自托管**（PP-OCRv6 下载、SHA-256 校验、常驻 worker、GPU 加速）——Snapcut 用系统 Vision 即可，不必复制模型管理。
- **剪贴板自定义 placement/appearance MIME**（从剪贴板贴图时还原截图装饰）——属于自家闭环数据，非必需。
- **云上传、托盘换肤、MCP 接口、滚动截图**——超出本域或依赖网络。
- **Windows 专属**：DIB/CF_HDROP 剪贴板路径、`toggle_window_under_cursor_always_on_top`、资源管理器命令。

## 5. 验收标准（可实测）

**贴图**
1. 截图选区后点「贴图」，屏幕出现无边框置顶窗口，位置/尺寸与选区一致，默认带边框、无阴影。
2. 滚轮缩放时贴图以光标为锚点缩放，范围 10%–500%，窗口短暂显示百分比读数。
3. 菜单旋转 90° 四次回到原样；透明度调到 50% 时可透视下层内容；开启穿透后点击贴图落点直接作用于下层应用，且旁边出现可拖动的退出控件。
4. 关闭贴图（开确认设置时）先弹确认框；关闭后按 Ctrl+F3 能恢复最近关闭的那张；「销毁」弹「不可撤销」确认，确认后记录从磁盘删除。
5. 贴 3 张图后退出并重启应用：3 张（当前组内未关闭的）自动恢复原位置、原缩放、原透明度；杀掉一张所在屏幕的显示器后重启不崩溃、贴图回到有效屏幕。
6. F3 贴剪贴板文本出现文本贴图窗口；连续 F3 贴同一图片不产生重复窗口（默认按重复策略处理）。
7. 贴图可从窗口直接拖拽到 Finder/其他应用成为文件。

**OCR**
8. 选区后点 OCR：约选区大小的浮层出现，识别文本按原始行位对齐；点击文本可放置光标并修改，Ctrl+Z 可撤销。
9. 未选文本按 Ctrl+C 复制全部文本；选两行按 Ctrl+C 只复制这两行；Ctrl+A 全选。
10. 开启「识别并复制」快捷键：框选后无需任何额外点击，文本直接进剪贴板且截图会话结束。
11. 对二维码截图选区使用 QR 工具：解码出的文本可全选复制；对无二维码区域不崩溃并给出无结果状态。

**导出**
12. 截图完成默认已复制：粘贴到「预览」得到 PNG（含透明区域）；粘贴到「备忘录」等也接受（TIFF 兜底）。
13. 「保存」弹系统保存对话框，默认文件名 `SnowShot_YYYY-MM-DD_HH-mm-ss`、默认目录为「图片」；保存过一次后，下次默认目录/格式为上次选择。
14. 「快速保存」无对话框直接落盘到配置目录，同名文件自动加序号不覆盖。
15. 文件名模板 `{WN}` 能填入所截窗口标题；非法字符不出现在最终文件名。

**历史**
16. 任一导出（复制/保存/贴图）后打开历史页，出现对应新条目并带来源标签（复制/保存/贴图）。
17. 历史条目「编辑」能恢复完整标注内容与撤销栈；「贴图」能重新贴到屏幕；「删除」即从列表与磁盘移除。
18. 人为把系统时间 +8 天（或改保留期）后触发清理：过期条目被删、配额（100 条/1024 MiB）超限后最旧条目先删。

**剪贴板兜底**
19. 复制截图后立即被其他应用抢占剪贴板（模拟 Busy），300ms 内重试成功或最终给出失败回调且应用不崩溃。

---
