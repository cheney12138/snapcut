# Snapcut 功能行为规格 · 选区交互体验（提炼自 Snow Shot）

> 来源仓库：`snow-shot`（C++/Qt）。所有 `file:line` 均相对 `snow-shot/` 仓库根。
> 本文档只描述**用户可感知的行为**，不涉及架构。行号为撰写时快照，可能随上游演进漂移。

## 0. 一句话结论（这个域最核心的 3-5 个行为）

1. **进入截图 = 全屏遮罩 + 十字光标 + 智能窗口预览**：默认进入「智能选区」，鼠标悬停即通过系统辅助功能命中测试出窗口/子元素，画蓝色边框预览 + 只读尺寸条（`screenshottoolbarpresenter.cpp:121`、`screenshotoverlaycanvaspresenter.cpp:401`）。
2. **"放大镜"以取色器面板形态存在**：光标旁 16px 处跟随一个 132×132px 面板（11×11 源像素 @12 倍放大），中心像素描边 + 显示 X/Y 坐标和颜色值（hex/rgb/hsl），Shift 单击循环格式，C 复制颜色（`screenshotcolorpickerwindow.cpp:15-17,38`、`screenshotcolorpickerwindow.cpp:454-530`）。
3. **选区拖拽全程显示实时尺寸条**：宽×高 + 单位（macOS 默认"逻辑像素 dp"，Windows 默认"物理像素 px"），选区确认后才变成可编辑的完整工具条（`screenshotselectiondisplayunit.h:13-17`、`screenshotselectiontoolbarwidget.cpp:1109`）。
4. **调整手段极其丰富**：8 向手柄/边框（容差 8px）拖拽改尺寸、按住 Space 临时变整体移动、Shift 锁 1:1、Q 吸附到常用宽高比、滚轮以中心等量缩放选区、WASD/方向键逐像素移动**光标**（光标再驱动选区/框选）、R/Shift+R 唤起**上一次/下一次选区**历史（`screenshotoverlayinputhandler.cpp:26,988-1128`、`screenshotselectionlimits.h:7`、`screenshotcontroller.cpp:6435`）。
5. **点击不拖动 ≠ 截图，Esc 取消、Enter 确认、双击=可配置完成动作（默认复制）**（`screenshotselectiongeometry.cpp:203-210`、`screenshotoverlayshortcutcontroller.cpp:209-224`、`configurationschema.cpp:1642`）。

## 1. 功能清单

| 功能 | 触发方式 | 行为细节 | 源码位置 |
|---|---|---|---|
| 智能选区（窗口/元素预览） | 截图启动后默认模式，移动鼠标 | 实时对光标所在位置做 UI 命中测试（含显示器维度），高亮命中的窗口/子元素矩形；点击该区域=直接确认选区 | `snow_shot/src/presentation/overlay/screenshotoverlayinputhandler.cpp:509,601-617,753-769`；`snow_shot/include/snow_shot/presentation/screenshotintelligentselectionmodel.h:8-10` |
| 手动框选 | 智能模式下按住拖动（超过系统 startDragDistance）或点空白处拖动 | 转为经典矩形框选；拖拽中以整像素单元格对齐，起点像素始终包含在选区内 | `screenshotoverlayinputhandler.cpp:601-612`；`snow_shot/src/presentation/selection/screenshotselectiongeometry.cpp:203-210` |
| 遮罩 | 进入截图自动出现 | 选区外覆盖半透明遮罩，默认色 `#00000080`（可设置）；按整像素对齐四条矩形填充，避免抗锯齿接缝 | `snow_shot/src/storage/configurationschema.cpp:1505`；`snow_shot/src/presentation/overlay/screenshotcanvasrenderer.cpp:1229-1265` |
| 选区边框与手柄 | 选区存在即绘制 | 边框 2px、默认 `#4096FF`（可设置）；角手柄在选区最小边 >32px 时出现，四边中点手柄 >64px 时出现，手柄半径 4px、描边 1.5px | `screenshotcanvasrenderer.cpp:1156-1160`、`2796-2797`、`4219-4231` |
| 十字光标 | 选区阶段 | 选区/编辑阶段使用系统 crosshair 光标（macOS 映射为 NSCursor.crosshairCursor） | `snow_shot/src/presentation/core/crosshaircursor.cpp:81`；`snow_shot/tests/macos_cursor_native_tests.mm:170` |
| 快捷键提示卡 | 选区阶段自动显示在左下角 | 半透明黑底圆角卡片列出当前阶段可用的快捷键（移动光标、滚轮切换元素层级、Tab 切窗口/子元素、Shift 锁比例、Q 比例吸附、复制颜色、坐标切换、历史切换等）；鼠标悬停其上或被选区/光标遮挡时自动隐藏 | `snow_shot/src/presentation/overlay/screenshotoverlayuihost.cpp:59-88,660-693`；`snow_shot/include/snow_shot/presentation/screenshotshortcuthints.h:88-100,233-310` |
| 取色/放大镜面板 | 选区阶段跟随光标 | 11×11 源像素以 12 倍放大（132×132px 网格），中心像素 1px 描边框 + 十字准线；下方两行：`X: n Y: n` 与颜色值（hex/rgb/hsl，默认 hex）；面板不可点击、不抢焦点；距光标 16px 并自动避让屏幕边缘 | `snow_shot/src/presentation/services/screenshotcolorpickerwindow.cpp:15-17,24-38,454-530` |
| 尺寸实时显示 | 拖拽框选/智能预览/移动选区时 | 选区工具条以 SizeOnly（只读、点击穿透）模式显示 W/H 数值 + 单位；macOS 默认逻辑像素（dp），Windows 默认物理像素（px） | `snow_shot/src/presentation/toolbar/screenshottoolbarpresenter.cpp:121`；`snow_shot/src/presentation/selection/screenshotselectiondisplayunit.h:13-17,72-79` |
| 确认选区 | 松开鼠标 / Enter | 选区≥1×1 像素即有效；确认后进入编辑态，弹出完整截图工具条（可编辑 W/H、比例预设等） | `screenshotoverlayinputhandler.cpp:1339-1396`；`snow_shot/src/presentation/overlay/screenshotoverlayshortcutcontroller.cpp:209-224` |
| 8 向拖拽改尺寸 | 拖选区边/角（容差 8px） | 命中测试按 8 方位返回拖拽模式；拖动位移吸附到整像素单元格；选区不可小于 1px；可选"follow_mouse_position"模式：按下时先把被抓的边吸附到指针位置 | `snow_shot/src/presentation/selection/screenshotselectiongeometry.cpp:223-270`、`425-468`；`screenshotoverlayinputhandler.cpp:26,462-468` |
| 整体移动选区 | 按住 Space（默认）或在选区内部拖动 | 按下鼠标后中途按 Space 可把"改尺寸"手势无缝切换为"整体移动"，松开 Space 恢复原手势；移动时选区保持尺寸、平移并被画布边界夹住 | `screenshotoverlayinputhandler.cpp:988-1022,684-709`；`screenshotselectiongeometry.cpp:360-365` |
| 锁定 1:1 | 按住 Shift（默认）拖拽 | 框选或改尺寸时强制宽=高；框选时以按下点为锚、扩展较小的一轴保持比例 | `screenshotoverlayinputhandler.cpp:1023-1052`；`screenshotselectiongeometry.cpp:158-188` |
| 宽高比吸附 | 按住 Q（默认）拖拽 | 拖拽矩形时吸附到最接近的预设比例（如 1:1、4:3、16:9…），并记住为偏好；已吸附状态下再按 Q 解除并从当前矩形继续拖 | `screenshotoverlayinputhandler.cpp:1053-1128,1530-1560`；`snow_shot/include/snow_shot/presentation/screenshotselectionaspectratio.h` |
| 滚轮等比缩放选区 | 选区存在且未拖拽时滚动滚轮 | 四边同时内缩/外扩整数像素，中心固定、不缩放内容；受画布边界与最小尺寸约束 | `screenshotoverlayinputhandler.cpp:863-920` |
| 全选当前屏幕 | Ctrl+A / Cmd+A（SelectAll） | 选整个当前显示器；选区已是整屏时再按一次扩为全部屏幕桌面 | `screenshotoverlayinputhandler.cpp:1231-1270` |
| 上次选区记忆 | R（上一次）/ Shift+R（下一次） | 在截图历史条目中保存的选区参数间循环浏览，恢复的选区自动确认并弹出工具条；含显示器适配与边界钳制 | `screenshotcontroller.cpp:6435-6450`；`snow_shot/src/presentation/services/screenshothistoryservice.cpp:707-740`；`screenshotoverlayinputhandler.cpp:1311-1333` |
| 双击完成动作 | 双击选区 | 执行可配置动作，默认 `copy`（复制到剪贴板）；可选 save/quick_save/pin/ocr/ocr_copy/cancel | `screenshotoverlayinputhandler.cpp:1397-1463`；`configurationschema.cpp:1642-1645` |
| 中键完成动作 | 中键点击 | 可配置，默认 `pin`（贴图）；智能预览下中键仅当点在预览选区内才生效 | `screenshotoverlayinputhandler.cpp:1402-1463`；`configurationschema.cpp:1644` |
| 右键 | 右键点击 | 尚无选区（预选阶段）→ 取消整个截图；手动选区/移动中 → 回到智能选区模式重新检测；用画笔类工具时先恢复 Move 工具再重选；可取消区域布尔运算/效果拖拽 | `screenshotoverlayinputhandler.cpp:705-770` |
| Esc 取消 | Esc（key release 触发） | 依次尝试：取消效果拖拽 → 取消区域布尔运算 → 取消截图；macOS 上标准关闭键（Cmd+W）同样取消 | `screenshotoverlayshortcutcontroller.cpp:448-450,178-183` |
| 区域类型切换 | 快捷键（next/previous_selection_type） | 在 Rectangle / Polyline / Curve / Freehand 四种区域类型间循环；折线模式下双击收尾、Backspace 撤销顶点 | `screenshotoverlayinputhandler.cpp:1817-1832`；`snow_shot/include/snow_shot/image/screenshotregiongeometry.h:19` |
| 多区域编辑与布尔运算 | 加选/减选（add/subtract region） | 在已有选区上叠加/挖除区域；减选拖拽预览为红色虚线框；移动单个区域时按 Ctrl 显示对齐吸附参考线 | `screenshotoverlayinputhandler.cpp:1699-1779`；`screenshotcanvasrenderer.cpp:4206-4213`；`snow_shot/src/presentation/selection/screenshotselectionmodel.cpp:309-325` |
| 快速改选区（画笔工具中） | 设置 quick_selection_modification（默认开） | 即使激活了某个绘图工具，把鼠标放到选区边框上仍可直接拖拽改选区（临时切到 Move，完成后恢复原工具） | `screenshotoverlayinputhandler.cpp:366-392,884-886`；`configurationschema.cpp:1646-1647` |
| 十字参考线 | Alt（默认）切换；默认关闭 | 过光标的水平/垂直虚线（dash 10 / gap 3），对齐像素中心；颜色可配置 | `configurationschema.cpp:1325,1511-1517`；`snow_shot/include/snow_shot/presentation/screenshotguidelinerendering.h:14-34` |
| 光标逐像素移动 | W/A/S/D 或方向键（默认），支持自动重复 | 原生移动物理光标 1px；光标移动会自然驱动框选/选区拖拽与取色器更新 | `snow_shot/src/storage/configurationschema.cpp:1287-1293`；`screenshotcontroller.cpp:2196-2244` |
| 复制颜色 / 坐标切换 | C / Shift+P（默认） | C：复制当前取色值并结束截图；Shift+P：全局/相对坐标切换 | `screenshotoverlayshortcutcontroller.cpp:437-442`；`screenshotcolorpickerwindow.cpp:393-417` |

## 2. 关键交互细节（用户能感知的每一个细节）

### 2.1 进入选区状态的屏幕样子
- 全屏幕被 `#00000080`（50% 黑）遮罩覆盖，多显示器为一张连续画布，选区外全部变暗；遮罩颜色可在设置中改（`configurationschema.cpp:1505`，`screenshotcanvasrenderer.cpp:1229`）。
- 光标变为十字准线 crosshair（`crosshaircursor.cpp:81`）。
- 智能选区默认开启：光标下窗口/子元素实时显示蓝色边框预览（同一 `#4096FF` 强调色），下方出现只读尺寸条（`screenshottoolbarpresenter.cpp:121`）。
- 左下角出现快捷键提示卡（黑 64% 底、白字、键帽样式 chip；鼠标悬停到卡片上或被选区覆盖时消失，`screenshotoverlayuihost.cpp:59-88`，`screenshotshortcuthints.h:88-100`）。
- 取色放大镜面板跟随光标（默认 `hide_outside_selection`：光标在选区外时显示，进入选区后隐藏；显示模式可配置，`configurationschema.cpp:1497-1501`）。
- 没有传统意义上的"独立放大镜"控件：放大能力全部由取色器面板的 12× 像素网格预览承担；注解工具栏中另有一个 Magnifier 放大镜工具，但那是画布标注工具，不会在选区阶段自动出现（`screenshotinteractionstate.h:29`，`globalcanvascontroller.cpp:62-63`）。

### 2.2 拖选过程中
- **尺寸标签**：工具条以 SizeOnly 只读模式实时显示 宽 × 高，带单位后缀 `px`（Windows/物理像素）或 `dp`（macOS/逻辑像素）（`screenshotselectiondisplayunit.h:13-17,72-79`，`screenshotselectiontoolbarwidget.cpp:1109-1117`）。
- **数值为整像素**：拖拽 delta 吸附到整像素单元格，起点像素恒被包含（1px 拖动 = 1×1 选区）（`screenshotselectiongeometry.cpp:190-205,355-357`）。
- **放大镜/取色器**：拖拽期间持续采样光标下颜色并更新预览与色值（`screenshotcolorpickercontroller.cpp:166-186`）。放大倍率固定 12×，预览范围 11×11 源像素，中心像素带 1px 边框标记与准线；显示 X/Y（可切全局/相对坐标）与颜色值 hex/rgb/hsl（`screenshotcolorpickerwindow.cpp:15-17,454-530`）。
- 按住 Shift 拖拽 → 实时锁 1:1；按住 Q → 实时吸附常用宽高比；两者都作用于框选与 8 向改尺寸（`screenshotoverlayinputhandler.cpp:930-955,1258-1276`）。

### 2.3 选区完成后的调整
- **拖动整体**：鼠标按住选区内部拖动即整体移动；或任何改尺寸手势中按住 **Space** 临时切换为移动、松开恢复（`screenshotoverlayinputhandler.cpp:988-1022`）。
- **八向改尺寸**：边框/四角 8px 容差命中，光标随方位变化；选区最小 1×1px；"follow_mouse_position"设置下按下瞬间边框先吸附到指针（`screenshotselectiongeometry.cpp:223-270,425-468`）。
- **键盘微调**：方向键/WASD 移动的是**物理光标**（1px，支持长按连发），由光标带动选区/框选——不是直接对选区做 nudge（`screenshotcontroller.cpp:2196-2244`）。
- **滚轮**：选区上滚轮 = 以中心等量扩缩（整数像素，防越界）；智能选区模式下滚轮 = 切换光标下堆叠元素层级（`screenshotoverlayinputhandler.cpp:800-845,850-880`）。
- **Enter** 确认；确认后工具条变 Full 模式（宽/高可点击编辑、比例预设选择、圆角/阴影控件）（`screenshotoverlayshortcutcontroller.cpp:209-224`，`screenshotselectiontoolbarwidget.cpp:453-527`）。

### 2.4 智能吸附
- **窗口/元素吸附**：智能选区的 hover 命中测试即"吸附"——选区总是吸附到窗口或其子元素的精确矩形（`screenshotintelligentselectionmodel.h:8-10`）。
- **比例吸附**：Q 键拖拽时吸附到预设宽高比（`screenshotoverlayinputhandler.cpp:1530-1560`）。
- **多区域对齐**：多区域编辑移动单个区域时按 Ctrl 显示与其他区域/边界的对齐参考线（snap guides）（`screenshotoverlayinputhandler.cpp:665-682`，`screenshotselectionmodel.cpp:309-325`）。
- **无**独立的"屏幕边缘磁吸"：普通矩形框选不吸附屏幕边缘，仅被画布边界 clamp（`screenshotselectiongeometry.cpp:264-294`）。

### 2.5 单击 / 双击 / Esc / 右键
- **单击不拖动**：不算选区——框选算法对 1×1 单元格返回空矩形（"A click is not a selection"），确认时宽或高 <1 直接失败，不进入编辑态（`screenshotselectiongeometry.cpp:203-210`，`screenshotoverlayinputhandler.cpp:1345-1348`）。
- **单击智能预览区**：等于确认该窗口/元素为选区（`screenshotoverlayinputhandler.cpp:753-769`）。
- **双击**：执行可配置完成动作，默认复制到剪贴板（`configurationschema.cpp:1642`）。
- **中键**：默认贴图 pin（`configurationschema.cpp:1644`）。
- **Esc**：取消截图（key release 触发，避免吞掉编辑；先逐级取消进行中的手势）（`screenshotoverlayshortcutcontroller.cpp:305-312`）。
- **右键**：预选阶段=取消截图；手动选区/移动中=回到智能选区重选；区域布尔运算中=取消该运算；绘图工具中=先恢复移动工具（`screenshotoverlayinputhandler.cpp:705-770`）。

### 2.6 极小选区与边界
- 最小选区 1×1 物理像素（`kScreenshotSelectionMinimumSize = 1.0`，`screenshotselectionlimits.h:7`），没有 5px 下限。
- 改尺寸/移动被夹在画布（全部屏幕联合）边界内；移动保持尺寸、整体平移（`screenshotselectiongeometry.cpp:264-294`）。
- 选区太小（<32px）时角手柄不显示、<64px 中点手柄不显示，但边框仍可拖（`screenshotcanvasrenderer.cpp:1159-1160`）。

### 2.7 上次选区
- 存在：R = 恢复上一次选区，Shift+R = 下一次；数据来自截图历史条目中保存的选区参数，恢复时做显示器适配 + 边界钳制，成功后直接确认并弹工具条（`screenshotcontroller.cpp:6435-6450`，`screenshothistoryservice.cpp:707-740`，`screenshotoverlayinputhandler.cpp:1311-1333`）。
- 另有截图历史整体回溯（`,` / `.`，恢复上一张截图的内容与选区）。

## 3. 实现要点（先定的技术决策）

1. **坐标系**：所有几何用"canvas 虚拟坐标系"（跨显示器连续），与各显示器的物理/逻辑坐标互相映射；选区最终落为像素矩形（half-open rect）（`screenshotoverlayinputhandler.cpp:1465-1476`，`screenshotselectiongeometry.cpp:207-210`）。
2. **单位（px vs dp）**：显示单位按平台默认——macOS 逻辑像素（dp）、Windows 物理像素（px），可由用户覆盖；内部最小尺寸判定用 canvas 单位 1.0（`screenshotselectiondisplayunit.h:13-17`，`screenshotselectionlimits.h:7`）。
3. **整像素契约**：指针位置 round 到像素单元格；拖拽 delta、marquee 起终点、边界全部按半开区间整像素处理，避免高分屏亚像素漂移（`screenshotselectiongeometry.cpp:183-210,360-365`）。
4. **最小尺寸与确认门槛**：确认要求宽、高均 ≥1px，否则静默失败不进入编辑态（`screenshotoverlayinputhandler.cpp:1345-1348`）。
5. **命中容差**：边/角命中容差 8 逻辑单位；手柄显示阈值 32/64 视图单位（`screenshotoverlayinputhandler.cpp:26`，`screenshotcanvasrenderer.cpp:1159-1160`）。
6. **权限**：智能选区（窗口/元素命中）依赖系统辅助功能/UI 选择器服务；截图本身依赖屏幕录制权限——Snapcut 需自行设计等效的 Accessibility 命中（`screenshotoverlayinputhandler.cpp:1207-1221`）。
7. **取色器性能**：面板预览为 11×11 邻域直接从捕获图取像素放大（无缩放滤波），隐藏时预分配 backing store，光标像素用 cursor patch 修正（光标不混入取色）（`screenshotcolorpickerwindow.cpp:181-217,436-470`）。
8. **手势状态机**：Marquee / All(移动) / 8 个方向 / None 的显式枚举驱动一切手势；Space/Shift/Q 都通过"rebase 当前手势为新模式"实现无缝切换，而不是重开手势（`screenshotinteractionstate.h:56-63`，`screenshotoverlayinputhandler.cpp:445-508`）。
9. **快捷键全部可配置**：默认键见 §1；Esc/关闭在 key release 触发、Enter 任意修饰组合均确认、光标移动键带 auto-repeat（`configurationschema.cpp:1287-1345`，`screenshotoverlayshortcutcontroller.cpp:179-224,287-317`）。
10. **提示卡不挡操作**：提示卡/取色器/SizeOnly 工具条全部 `WA_TransparentForMouseEvents` + 输入穿透，选区拖拽不被 UI 面板截断（`screenshotoverlayuihost.cpp:48-52`，`screenshotcolorpickerwindow.cpp:166-172`）。

## 4. 我们可以先不做的（非核心 / 平台相关 / 依赖网络的部分）

- **多区域布尔运算（加选/减选）与区域类型（Polyline/Curve/Freehand）**：v1 矩形 + 智能窗口选区即可覆盖 90% 场景（`screenshotoverlayinputhandler.cpp:1699+`）。
- **选区圆角/阴影实时编辑控件**（effect editors、拖拽改圆角/阴影宽度）：属导出美化，非选区核心（`screenshotoverlayinputhandler.cpp:31-227`）。
- **滚动截图、OCR/翻译/表格/二维码识别入口**：依赖识别引擎与网络/模型。
- **Windows 特有行为**：DIB 剪贴板解码、RedrawWindow 首帧隐藏等平台细节（`screenshotoverlayuihost.cpp:222-250`）。
- **滚轮改画笔宽度/滤镜强度等画布工具行为**：属于标注域。
- **取色器全部显示模式/坐标模式设置项**：可先实现默认 `hide_outside_selection` + hex。
- **快捷键自定义 UI**：先内置默认键位，后续再暴露配置。

## 5. 验收标准（可实测）

1. 启动截图后：整屏出现 50% 黑遮罩（#00000080），光标为十字准线；光标悬停在窗口上时该窗口矩形出现 2px #4096FF 边框预览，且出现只读尺寸条（宽×高+单位）。
2. 取色放大镜：跟随光标（间距约 16px），面板内可见 12× 放大的像素网格、中心像素描边；面板文本显示 `X: n Y: n` 与 hex 色值；按住 Shift 后松开（单独 Shift 单击）色值格式在 hex ↔ 无#hex ↔ rgb ↔ hsl 间循环；按 C 复制当前色值且截图结束。
3. 空白处按下并拖动：出现矩形框选边框 + 实时尺寸；拖动 1px 起步即得 1px 宽选区；尺寸数值随拖动逐像素变化且始终为整数。
4. 点击不拖动：不产生选区、不进入编辑态（遮罩与十字光标保持）。
5. 选区 >32px 出现四角手柄、>64px 再出现四边中点手柄；手柄与边框 8px 内光标变为对应方位的缩放光标，拖拽可改尺寸；选区不可拖到小于 1×1。
6. 选区内部按下拖动 = 整体移动，移动中尺寸不变、不能拖出屏幕边界。
7. 框选中途按住 Space：拖拽立即变为整体移动；松开 Space 恢复原来的改尺寸手势且矩形无跳变。
8. 拖拽中按住 Shift：选区强制 1:1；按住 Q：吸附到最近预设比例（如拖到近似 16:9 时自动锁定）；已吸附后再按 Q 解除。
9. 选区存在时滚动滚轮：选区以中心对称扩大/缩小整数像素，不出屏、不小于 1px。
10. 按 W/A/S/D 或方向键：光标每次移动 1px（长按连发），框选/选区随之更新，取色器同步刷新。
11. 按 R：恢复上一次使用的选区并直接进入编辑态（弹出完整工具条）；Shift+R 在历史中向后切换。
12. 按 Enter（含带修饰键）：确认选区进入编辑态；按 Esc（松开时）：取消截图回到原屏幕；在预选阶段（尚无选区）右键 = 取消截图，有选区后右键 = 回到智能选区重选。
13. 双击选区：执行默认动作"复制到剪贴板"（导出的图与选区像素一致）。
14. 左下角快捷键提示卡：内容随阶段变化（智能选区 vs 手动选区），鼠标移到卡片上或选区覆盖它时隐藏。
15. Ctrl/Cmd+A：选区变为整个当前显示器；再按一次变为所有屏幕的桌面范围。
