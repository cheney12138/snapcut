# Snow Shot 功能行为规格 —— 截图后的工具栏与工具集

> 源码：`snow_shot/src/presentation/toolbar`（工具栏窗口/位置）与 `snow_shot/src/presentation/tools`（工具面板/各工具参数 UI）。
> 所有行号基于当前仓库工作区。

## 0. 一句话结论（核心 5 个行为）

1. 工具栏是一条单行圆角面板，默认出现在选区右下角外侧、间隙 4 逻辑像素；放不下时整体翻转到选区上方（右上角对齐），再不行就在显示器范围内水平钳制；无出现/切换动画（`snow_shot/src/presentation/core/screenshotgeometry.cpp:1135-1211`、`snow_shot/src/presentation/toolbar/screenshottoolbarpresenter.cpp:16,194-197`）。
2. 工具栏按钮分三段：固定前导（移动/编辑选区）→ 可自定义的绘图工具区（相邻工具自动"堆叠"成一个带弹出层的组按钮）→ 动作区（识别/贴图/保存/取消/复制等）；整条布局用户可在设置里重排，默认顺序由 `defaultPositions()` / `actionDefaultPositions()` 定义（`snow_shot/include/snow_shot/presentation/screenshottoolbarlayoutmodel.h:440-487`）。
3. 截图会话开始时默认工具是「编辑选区 (Move)」；再次点击当前已激活的工具会回落到默认工具（Move/Select），没有"画完一笔自动回默认"的一次性工具；可选设置"记住上次使用的工具"（默认关）（`snow_shot/src/presentation/tools/screenshottoolpalette.cpp:5460-5484`、`snow_shot/src/storage/configurationschema.cpp:1221`）。
4. 每个工具的样式参数在工具栏下方的第二行"样式面板"中展示（色板、粗细、线型、填充、字号 S/M/L/XL 等），按工具持久化到 `drawing/<tool>_style`，下次会话沿用（`snow_shot/src/presentation/tools/screenshottoolpalettestylecontrols.cpp:271-323`、`snow_shot/src/storage/configurationschema.cpp:1226-1247`）。
5. Enter / Ctrl+C = 复制到剪贴板并结束截图，Esc = 取消（保留键位，仅 Esc 可绑），右键点击空白处也是取消；另有贴图 (Ctrl+F)、保存 (Ctrl+S)、快速保存 (Ctrl+Shift+S)、OCR (Ctrl+D)、录屏 (Ctrl+R) 等动作（`snow_shot/src/storage/configurationschema.cpp:605-608,1330-1363`、`snow_shot/src/presentation/services/screenshotcontroller.cpp:5406-5487`）。

## 1. 功能清单

### 1.1 主工具栏按钮（默认顺序，从左到右）

绘图工具区默认布局 `defaultPositions()`（`screenshottoolbarlayoutmodel.h:440-456`）。存储的堆叠组"自上而下"，**最底部的一个是该组按钮的默认工具（触发图标）**，点击组按钮即激活它；点组按钮上的小箭头弹出 popover 横向列出其余工具（`screenshottoolbarlayoutmodel.h:106-121`、`snow_shot/src/presentation/tools/screenshottoolpalette.cpp:6289-6350`）。

| # | 按钮 | 含义 | 快捷键（默认） | 组合/堆叠 | 源码位置 |
|---|------|------|----------------|-----------|----------|
| 前导 | 移动/编辑选区 (Move) | 调整选区边框、窗口；图像编辑器中为 Pan（平移） | M 或 Ctrl+E（`move_tool`，configurationschema.cpp:576,1285） | — | `screenshottoolpalette.cpp:6526-6540`；Pan: `imageeditingwindow.cpp:156` |
| 1 | 选择元素 (Select) | 选取/框选画布上的已绘元素 | V（drawing_shortcuts/select，configurationschema.cpp:565,1249） | — | `screenshottoolbarlayoutmodel.h:157` |
| — | 分隔符（select 后的竖线） | — | — | — | `screenshottoolbarlayoutmodel.h:325-333` |
| 2 | 形状 (Shape) | 矩形/椭圆等形状 | 1 | — | configurationschema.cpp:566,1251 |
| 3 | 箭头线组（触发=箭头） | 弹出：箭头 Arrow / 直线 Line / 距离 Distance / 角度 Angle / 括号 Bracket | Arrow=2；Line/Distance/Angle/Bracket 无默认键（emptyArrayDefault，configurationschema.cpp:1253-1263） | 组按钮 | `screenshottoolbarlayoutmodel.h:446`、堆叠逻辑 `:106-121` |
| 4 | 画笔 (FreeDraw/Brush) | 自由绘制 | 3 或 P | — | configurationschema.cpp:568,1269 |
| 5 | 荧光笔组（触发=高亮 Highlight） | 弹出：放大镜 Magnifier / 聚光灯 Spotlight / 高亮 RectangleHighlight | Highlight=4 或 H；Spotlight/Magnifier 无默认键 | 组按钮 | `screenshottoolbarlayoutmodel.h:449` |
| 6 | 文本 (Text) | 插入文字 | 5 或 T | — | configurationschema.cpp:570,1273 |
| 7 | 气泡序号组（触发=序号 SerialNumber） | 弹出：对话气泡 SpeechBubble / 序号 SequenceNumber | 序号=6 或 N；气泡无默认键 | 组按钮 | `screenshottoolbarlayoutmodel.h:451` |
| 8 | 滤镜 (Filter/RectangleFilter) | 给选区加滤镜 | 7 或 F | — | configurationschema.cpp:572,1277 |
| 9 | 橡皮擦 (Eraser) | 擦除元素 | 8 或 E | — | configurationschema.cpp:573,1279 |
| 10 | 水印 (Watermark) | 平铺水印 | 9 | — | configurationschema.cpp:574,1283 |
| — | 分隔符 | — | — | — | `screenshottoolbarlayoutmodel.h:454` |
| 11 | 撤销 Undo | 撤销画布操作 | Ctrl+Z（screenshot_shortcuts/undo，configurationschema.cpp:607,1361） | — | `screenshottoolpalette.cpp:5514-5533` |
| 12 | 重做 Redo | 重做 | Ctrl+Y（configurationschema.cpp:608,1363） | — | 同上 |

布局可完全自定义（含分隔符位置），通过设置里的"工具栏编辑器"拖拽；未知项按默认迁移（`screenshottoolbarlayoutmodel.h:544-880`）。

### 1.2 动作区按钮（默认顺序 `actionDefaultPositions()`，`screenshottoolbarlayoutmodel.h:471-487`）

| 按钮 | 含义 | 快捷键（默认） | 行为 | 源码位置 |
|------|------|----------------|------|----------|
| 识别组（触发=表格识别 Table） | 弹出：转 HTML / 转 Markdown / LaTeX 公式 / 条码识别 / 表格识别 | Table=Ctrl+X，QR=Ctrl+Q（configurationschema.cpp:594-595,1330-1334）；HTML/MD/LaTeX 无默认键 | 打开识别窗口，结果可编辑可复制 | `screenshottoolpalette.cpp:6169-6230`（表格/条码共用触发按钮 `m_tableButton` + `m_tableQrPopover`） |
| 录屏 Record screen | 区域录屏 | Ctrl+R（configurationschema.cpp:596,1337） | 启动录屏会话 | `screenshottoolbarwindow.cpp:348-350`、`screenshotcontroller.cpp:5861` |
| 贴图组（触发=Pin to screen） | 弹出：Pin window to screen / Pin to screen | Pin=Ctrl+F，Pin window=Alt+W（configurationschema.cpp:603-604,1353-1355） | 选区生成为置顶贴图窗口；可配置贴图后是否同时复制/自动保存 | `screenshotcontroller.cpp:3455-3500` |
| 文字识别 OCR | OCR 选区文本 | Ctrl+D（configurationschema.cpp:597,1339） | 打开识别结果窗口；此后"复制"复制的是识别文本而非图像（`screenshotcontroller.cpp:5487-5497`） | `screenshotocrcontroller.cpp`（ocr 目录） |
| 文本翻译 | 翻译选区文本 | Ctrl+T（configurationschema.cpp:598,1342） | 联网翻译，按钮 busy 时仍可点击，结果进入识别窗口 | `screenshottoolpalette.cpp:4806-4845` |
| 长截图 Scrolling screenshot | 滚动拼接长图 | L（configurationschema.cpp:599,1345） | 进入滚动捕获模式 | `screenshottoolbarwindow.cpp:519-544` |
| 保存组（触发=另存为 Save as file） | 弹出：上传云盘 / AirDrop / 打印 / 快速保存 / 另存为 | 保存=Ctrl+S，快速保存=Ctrl+Shift+S，打印=Ctrl+P（configurationschema.cpp:600-602,1347-1351）；云盘/AirDrop 无默认键 | 另存为弹系统文件对话框（可选内置对话框）；快速保存静默写入默认目录 | `screenshotcontroller.cpp:4979-5010`（save）、`:4641-4690`（quickSave） |
| — | 分隔符 | — | — | `screenshottoolbarlayoutmodel.h:482` |
| 取消 Cancel | 关闭截图 | Esc（保留键，仅允许 Esc 绑定，settingsadapters.cpp:1556-1558） | 立即隐藏覆盖层、恢复焦点、重置会话 | `screenshotcontroller.cpp:5406-5433` |
| 复制 Copy | 复制图像到剪贴板 | Ctrl+C 或 Enter（configurationschema.cpp:606,1359） | 导出选区图像入剪贴板并结束截图 | `screenshotcontroller.cpp:5435-5487` |
| 确认编辑 Confirm | 仅"贴图编辑/图像编辑"布局出现（PinnedActionTools） | — | 结束对贴图/图片的编辑，把画布结果写回 | `screenshottoolbarlayoutmodel.h:502-515`、`screenshotpinnededitcontroller.cpp` |

另有上下文按钮：显示鼠标指针 (Show cursor)、重新截图 (Recapture, Alt+R)、裁切行列 (crop rows/columns，图像编辑器)、录屏导出设置行、全屏画布激光笔/点击穿透/退出（`screenshottoolpalette.cpp:4965-4995,6441-6460,6464-6490`）。动作区全部按钮受版本开关 `app::editionActionToolAvailable` 门控（`screenshottoolbarlayoutmodel.h:254-257`）。

### 1.3 样式面板（第二行，随激活工具变化）

激活任一绘图工具后，工具栏下追加第二行样式面板（host 把 mainPanel/actionPanel/stylePanel 纵向堆叠；`screenshottoolpalettehost.cpp:167`）。每个工具暴露的控件角色（`screenshottoolpalettestylecontrols.cpp:271-323`）：

| 工具 | 样式控件 |
|------|----------|
| 形状/气泡 | 形状种类、描边颜色、描边粗细、填充色、圆角 |
| 直线 | 描边色、粗细、线型（实/虚线）、填充 |
| 画笔 | 颜色、粗细、笔刷模式、填充 |
| 箭头 | 颜色、粗细、箭头样式、箭头比例、起点/终点箭头 |
| 距离 | 颜色、粗细、数值、单位、小数位、比例尺、端点样式 |
| 角度 | 颜色、粗细、角度类型、单位、小数位 |
| 括号 | 颜色、粗细 |
| 高亮(矩形/笔刷) | 高亮模式、颜色、边框/笔刷粗细 |
| 聚光灯 | 形状、遮罩颜色、不透明度、圆角 |
| 文本 | 字色、字体、强调样式、对齐、描边、填充、圆角 |
| 序号 | 字色、序号样式（数字/字母…）、当前值、字体、填充 |
| 滤镜(矩形/画笔/自动) | 滤镜模式、类型、强度 |
| 橡皮擦 | 擦除模式；（笔刷橡皮另加粗细） |
| 水印 | 字色、水印文本、字体、模板、角度、间距、不透明度 |

字号/粗细预设：S/M/L/XL = 24/30/42/54；笔刷粗细 2/4/8；形状粗细 = 各自默认/4/8（`screenshottoolpalettestylepresets.cpp:25-53`）。颜色为色板行（描边色/填充色/高亮色三组预设，`screenshottoolpalettestylepresets.cpp:11-23`）+ 自定义取色器（含画布取色管 `ColorPickerSamplerButton`，`screenshottoolpalettebuttons.h:296-330`）。

## 2. 关键交互细节

- **出现位置**：截图选区完成（松开鼠标）后工具栏出现，右下角与选区右下角对齐、间隙 4 逻辑像素（`screenshottoolbarpresenter.cpp:16`；几何计算 `screenshotgeometry.cpp:1135-1211`）。垂直方向：下方放得下就放下方；放不下且上方放得下 → 翻到选区上方（右上角对齐），并令样式面板出现在主工具栏**上方**（`setStyleToolbarAboveMain(placement.usesTopRightPlacement)`，`screenshottoolbarpresenter.cpp:197`、`screenshottoolpalettehost.cpp:258-270`）。两者都放不下：优先底部并钳制进显示器范围（`screenshotgeometry.cpp:1213-1219`）。
- **无动画**：显示路径中未发现任何 QPropertyAnimation/淡入；仅 `QTimer::singleShot(0)` 用于把窗口 raise 到顶层（`screenshottoolbarpresenter.cpp:150-155`）。
- **手动拖拽记忆**：工具栏两端有拖拽把手（"Drag toolbar"），用户拖动后本会话内不再自动跟随选区重定位（`m_manuallyDragged`，`screenshottoolbarwindow.cpp:510-517,560`）。
- **工具切换/回落**：点击工具栏按钮或按快捷键激活工具；若点击的正是当前激活工具，则回落到默认工具（录屏绘图模式→显示导出设置；普通模式→Move，无 Move 时→Select）（`screenshottoolpalette.cpp:5460-5484`）。**没有画完一笔自动回默认的"一次性工具"**（代码中无此逻辑，rg "one-shot/oneShot" 仅命中无关代码）。
- **默认工具**：每次新截图重置为 Move（"编辑选区"），并按设置可选恢复"上次使用的绘图工具"（`drawing/remember_last_used_tool`，默认 false）（`screenshottoolbarwindow.cpp:551-581`、`configurationschema.cpp:1221`）。
- **快捷键**：所有按钮 tooltip 会显示当前绑定的快捷键列表（`applyScreenshotShortcutTooltip`，`screenshottoolpalette.cpp:752-769`）；默认键位见 §1。绘图工具键：Select=V, Shape=1, Arrow=2, Brush=3/P, Highlight=4/H, Text=5/T, 序号=6/N, 滤镜=7/F, 橡皮=8/E, 水印=9（`configurationschema.cpp:565-574,1249-1283`）；Ctrl+Shift+Z = 清空画布（reset_canvas，一次撤销历史项）。
- **Esc 语义**：Esc 是保留键只能绑定取消（`settingsadapters.cpp:1556-1558`）；取消 = 立即隐藏覆盖层、恢复先前焦点、递增 capture epoch、关闭未完成保存对话框、重置 OCR/自动滤镜/历史导航（`screenshotcontroller.cpp:5406-5433`）。录屏绘图模式下 Esc 先关闭弹出层/清除激活工具，再按才退出（`screenshottoolpalette.cpp:4779-4803`）。**右键点击选区外 = 取消**（`screenshotoverlaywindow.cpp:1285-1294`）。
- **Enter 语义**：Enter 与 Ctrl+C 同为"复制到剪贴板"（`copy_to_clipboard` 默认绑定 {Ctrl+C, Return}，`configurationschema.cpp:606`）。复制时会：可选自动保存副本（`autoSaveAfterExecution("copy_screenshot")`）、可选复制文件而非位图、写入截图历史；若 OCR 处于激活态，复制的识别文本，无结果时报错兜底（`screenshotcontroller.cpp:5487-5560`）。**双击不是"完成"**：双击仅用于结束自定义多边形/自由选区的绘制（`screenshotoverlayinputhandler.cpp:1923-1937`）。
- **组按钮记忆**：表格识别/条码识别的入口切换持久化（`m_tableQrEntryTool`，`screenshottoolpalette.cpp:6145-6153`）；每个堆叠组的入口在会话内随选择切换（`selectDrawingToolGroupEntry`，`screenshottoolpalette.cpp:5536-5545`）。可选设置"始终显示组内第一个工具"（`drawing/always_show_first_toolbar_group_button`，configurationschema.cpp:1224）。
- **撤销/重做可用性随上下文**：OCR/表格/LaTeX 编辑器有各自独立的历史栈；QR/MD/HTML 结果不支持撤销；普通画布用画布历史（`historyActionEnabled`，`screenshottoolpalette.cpp:5486-5505`）。
- **识别中按钮防误触**：翻译进行中按钮保持可点但走导航逻辑，Space/Enter 也可触发（`screenshottoolpalette.cpp:4806-4845`）。
- **失败兜底**：复制无识别结果→错误提示"No recognition result is available to copy"；滚动截图准备失败→报错并结束导出（`screenshotcontroller.cpp:5490-5496,5528-5538`）；自动保存失败→toast 警告（`screenshotcontroller.cpp:5455-5472`）。
- **样式记忆**：所有工具样式按工具持久化（`drawing/shape_style`、`drawing/text_style`…共 17 项，`configurationschema.cpp:1226-1247`）；可选"同步工具颜色/共享颜色"跨工具统一（`configurationschema.cpp:1222-1223`）；颜色预设（描边/填充/高亮三组）本身也是用户设置。

## 3. 实现要点（做之前必须先定的技术决策）

1. **坐标系与放置算法**：工具栏位置用"锚点+内容矩形"计算——锚点=选区右下角（下方）或右上角（上方），对齐工具栏内容矩形对应边，再减 gap；全屏可见性判断后再水平钳制。需要区分逻辑/物理像素与 DPR（`screenshotgeometry.cpp:1135-1219`、`screenshottoolbarplacement.h:12-25`）。Snapcut 建议：先定"选区右下外侧、gap 4、翻转、钳制"四步管线。
2. **布局是数据不是代码**：按钮顺序、堆叠分组、分隔符全部是持久化的 `positions: [[ids]]` 数据，渲染时按"底部元素=组入口"折叠成单按钮+popover（`screenshottoolbarlayoutmodel.h:106-121,440-515`）。Snapcut 若要对应"可自定义工具栏"，应先定布局 JSON 结构。
3. **样式面板与主工具栏联动翻转**：样式行相对主行的上下关系取决于工具栏在选区上方还是下方（`screenshottoolpalettehost.cpp:258-270`）；host 尺寸 = 各面板几何并集（`screenshottoolpalettehost.cpp:135-176`）。
4. **缩放体系**：整条工具栏有独立 physicalScale（DPR×内容缩放），所有尺寸经 `scaledMetric()` 缩放并按累计宽度重排（`screenshottoolbarmainpanel.cpp:46-58,541-640`）。基础尺寸：按钮 32px、图标 24px、拖拽把手 18px、分隔线 1×16px（`screenshottoolbarmainpanel.cpp:24-36`）。
5. **保留键位约束**：Esc 不可被改绑为其他功能；Ctrl+C/Enter 作为复制默认绑定有专门的保留校验（`settingsadapters.cpp:1552-1569`）。
6. **动作与工具解耦**：按钮只发信号（copyRequested/saveRequested/pinRequested…），由命令层（ScreenshotToolbarCommands→ScreenshotController）决定去留；"复制"和"贴图"等动作可带自动保存/历史快照副作用，需在实现前定副作用矩阵（`screenshottoolbarwindow.cpp:337-362`、`screenshotcontroller.cpp:3455,4641,4979,5435`）。
7. **历史快照点**：复制/贴图/保存前都要 `resetCanvasEditingState()` + `prepareHistoryCandidate()` 做一次历史快照，且识别工具结果不算截图历史（`screenshotcontroller.cpp:5512-5520`）。
8. **性能**：工具栏显示/水合有专门打点（`screenshottoolbarperfinstrumentation.h`）；显示为同步无动画路径，`resetForNewCapture` 全量重置状态（`screenshottoolbarwindow.cpp:551-581`）。

## 4. 我们可以先不做的

- **布局编辑器/完全自定义顺序**（`screenshottoolbarlayoutmodel.h:544-880` 的迁移逻辑复杂，v1 用固定默认序即可）。
- **皮肤/换肤系统**（工具栏皮肤贴图+透明度，`screenshottoolbarmainpanel.cpp:63-190`）。
- **联网动作**：上传云盘、文本翻译、AirDrop（Windows 无 AirDrop）。
- **版本门控的识别类**：LaTeX/表格/条码/Markdown/HTML 转换（依赖 OCR 引擎与版式还原，成本高；可先只做基础 OCR）。
- **长截图（Scrolling screenshot）**：独立滚动捕获状态机（`screenshottoolbarwindow.cpp:519-544`），建议单独立项。
- **录屏工具栏**（RecordingActionTools 布局、导出格式设置行、麦克风/系统音频开关，`screenshottoolbarlayoutmodel.h:342-370`）。
- **全屏画布的激光笔/点击穿透/退出按钮**（global canvas 域）。
- **绘图工具里的高级项**：距离/角度/括号标注、放大镜、水印模板、序号编辑器（v1 可先做 形状/箭头/画笔/高亮/文本/序号/橡皮/滤镜 的最小集）。
- **Windows 专用**：窗口元素选择/枚举（msaa/uia）相关按钮态。

## 5. 验收标准（可实测）

1. 框选完成后 ≤1 帧内工具栏出现在选区右下角外侧，与选区边缘间隙为 4 逻辑像素（±1px）；截图窗口上肉眼无渐显/位移动画。
2. 把选区拖到屏幕底部使下方空间不足 → 工具栏整体翻到选区上方且右缘对齐选区右上角；此时若激活绘图工具，样式面板出现在主工具栏上方。
3. 选区跨越屏幕左右边缘 → 工具栏水平方向完全在显示器可用范围内，不溢出。
4. 默认选中"移动/编辑选区"工具；点击已激活的绘图工具按钮一次 → 该工具激活；再点同一按钮一次 → 回到默认工具。
5. 设置开启"记住上次使用的工具"后：用画笔画一笔→取消截图→重新截图 → 默认工具为画笔；关闭该设置 → 重新截图默认回到 Move。
6. 将形状→箭头→直线→距离→角度→括号排进一个堆叠组：组按钮图标为列表最底部工具，长按/点箭头弹出其余工具；选择"直线"后组图标变为直线，且下次截图该组入口仍为直线。
7. 每个绘图工具激活后第二行出现对应样式控件（形状=颜色/粗细/填充/圆角/形状种类，文本=字色/字体/字号 S/M/L/XL 等）；修改形状描边为红色 8px → 取消并重新截图 → 新形状默认仍为红色 8px。
8. 调整颜色预设列表（描边色板）→ 下次会话色板行按自定义顺序/集合展示。
9. 按 Enter 或 Ctrl+C → 剪贴板内为选区图像（按导出缩放比渲染），截图窗口关闭，历史记录新增一条"已复制"条目；OCR 激活时按 Ctrl+C 得到文本而非图像。
10. 按 Esc 或右键点击选区外 → 截图窗口立即关闭，焦点恢复到之前应用，无残留遮罩窗口。
11. Ctrl+F 贴图 → 桌面出现置顶贴图窗口（内容=选区图像）；若开启"贴图后复制"，剪贴板同时有图像。
12. Ctrl+S → 弹出保存对话框（格式/文件名模板生效）；Ctrl+Shift+S → 无对话框静默保存到默认目录并提示成功。
13. 工具栏可在其两端拖拽把手拖动；拖动后移动/缩放选区，工具栏不再自动重定位；重新截图后恢复自动定位。
14. 无可撤销操作时撤销按钮置灰；画一笔后 Ctrl+Z 撤销、Ctrl+Y 重做，按钮状态与画布历史一致；OCR 结果编辑有自己的独立撤销栈。
15. 所有按钮 tooltip 显示其功能名与当前快捷键；改绑快捷键后 tooltip 同步更新。
