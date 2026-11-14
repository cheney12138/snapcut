# Snow Shot 标注工具行为规格（供 Snapcut / Swift + AppKit 借鉴）

> 调研范围：`snow_shot/src/presentation/tools`、`snow_shot/src/presentation/imageediting`，以及实际承载标注引擎的 Rust crate `snow_draw_engine_qt/crates/*`（Snow Shot 的标注核心逻辑在 Rust 引擎中，Qt/Rust 通过 FFI 串接；不涉及架构分析，只提行为）。所有行号以仓库根 `/Users/qianyuchen/work/screenshot/snow-shot` 为准。

## 0. 一句话结论（这个域最核心的 3-5 个行为）

1. **标注 = 文档对象模型 + 事务历史**：每种标注（矩形/箭头/画笔/文字/序号/高亮/滤镜等）都是一个带 id 的元素，任何改动（创建/移动/缩放/旋转/删除/样式）都是一个可撤销事务，撤销栈无实际容量上限，只在数据校验时限制 10 万条（snow_draw_engine_qt/crates/snow-draw-engine/src/history.rs:124）。
2. **选中即编辑**：单击选最上层元素、Shift 加选/减选、空白拖拽框选；选中后可整体移动、四角缩放、旋转柄旋转、Delete/Backspace 删除（含级联删除绑定文字），z 序支持置顶/上移/下移/置底。
3. **马赛克/模糊是"滤镜区域"而非贴图**：强度 0–1 映射为马赛克块 2–22 逻辑像素、高斯 σ 0.5–36.5，默认强度 0.5 → 块 7px；渲染时块大小按 `zoom × devicePixelRatio` 换算，导出时按输出分辨率重绘保证清晰。
4. **序号徽章自动递增 + 可绑定文字**：每次放置后计数器 +1，按数字类型（阿拉伯/罗马/中文/大小写字母）各自取"现有最大值+1"，删除徽章连带删除其引导文字，连续步进合并为一条撤销记录。
5. **文字工具的键盘约定**：编辑态 Enter=换行、Ctrl+Enter 或 Esc=提交、空文本提交即删除；输入法 preedit 由草稿层专门承接（中文输入不丢字、不误提交）。

## 1. 功能清单

| 功能 | 触发方式 | 行为细节 | 源码位置 |
|---|---|---|---|
| 箭头 | 快捷键 `2`；拖拽=两点箭头；单击-移动-单击=折线多点箭头；双击或再次点击终点结束 | 默认曲线（三次贝塞尔，控制点取线段 1/3、2/3 处）、默认末端 Arrow 箭头、起始无箭头、线宽 2、箭头比例 1.0；提交最短长度 10px，不足则丢弃；支持直线/曲线/肘形（正交布线）三种、笔杆 Plain/Tapered、两端 15 种箭头、虚线/点线、手绘描边风格（Architect/Artist/Cartoonist + 随机种子）；端点可吸附绑定到图形/放大镜/序号等元素，被绑元素移动时箭头跟随重算 | snow_draw_engine_qt/crates/snow-draw-engine-editor/src/defaults.rs:95-107；snow-draw-engine-core/src/arrow.rs:53-147；snow-draw-engine-editor/src/arrow_ops.rs:25-29；snow-draw-engine-document/src/arrow/data.rs:58-115, 977-1010；snow-draw-engine-document/src/arrow/elbow_router.rs |
| 直线 | 工具面板"Line" | 复用箭头数据（无箭头端），两端无箭头，默认颜色 #1E1E1E、宽 2；单击加点阈值 8px，最短提交 8px | snow-draw-engine-editor/src/defaults.rs:108-125；snow-draw-engine-editor/src/arrow_ops.rs:26,29；snow-draw-engine-editor/src/creation_workflow.rs:439-460 |
| 矩形/椭圆/菱形 | 快捷键 `1`，拖拽 | 居中矩形存储（center/width/height/rotation），圆角默认 6px；`highlight_shape` 可切 Rectangle/Ellipse/Diamond/ThoughtBubble；填充四种风格：Line（斜线）、CrossLine（交叉线）、Solid、Border（仅边框，不渲染填充） | snow-draw-engine-editor/src/defaults.rs:83-94；snow-draw-engine-document/src/document.rs:486-508, 815-827；snow-draw-engine-scene/src/item_conversions.rs:134-153 |
| 矩形高亮 | 快捷键 `4`/`H` | 默认填充=描边色、无边框、不透明度 1，渲染用 **Multiply 混合模式**叠加在截图上（视觉上是半透明荧光笔效果，色板色即最终叠加色） | snow-draw-engine-editor/src/defaults.rs:126-147；snow-draw-engine-scene/src/item_conversions.rs:148-153 |
| 画笔高亮 | "Pen Highlight" | 沿绘制路径的 30px 宽度描边，Multiply 混合，同荧光笔语义 | snow-draw-engine-editor/src/defaults.rs:148-169；snow-draw-engine-scene/src/item_conversions.rs:210-216 |
| 画笔（Free draw） | 快捷键 `3`/`P` | 折线点集；笔刷模式 Regular / PressureSensitive（压感）；无压感笔时按 perfect-freehand 1.2 算法模拟压力（按速度缓动），半径公式 `width×0.5×sin((0.2+0.6p)π/2)/√2`；路径做 RDP 简化 | snow-draw-engine-core/src/pressure.rs:11-32；snow-draw-engine-editor/src/free_draw_pressure.rs:25-110；snow-draw-engine-editor/src/polyline_simplification.rs |
| 文字 | 快捷键 `5`/`T`，点击画布出现草稿输入框 | 默认字号 30、颜色=描边色板、背景透明（可选填充色+圆角 6）、水平左对齐/垂直居中；`auto_resize` 决定自动宽度还是固定宽度换行；文档存"换行矩形+实测 ink"双重尺寸；支持加粗/斜体/字体族 | snow-draw-engine-editor/src/defaults.rs:170-186；snow-draw-engine-document/src/document.rs:871-917；snow-draw-engine-editor/src/creation_workflow.rs:245-281 |
| 序号徽章 | 快捷键 `6`/`N`，单击放置 | 自动递增（见 §2）；5 种外形（描边圆/实心圆/描边方/实心方/纯圆点），纯圆点不带数字；数字格式阿拉伯/罗马/中文/小写/大写字母；直径由字号推导（带数字=徽章直径，纯圆点=字号×0.5）；可拖动；可挂一条引导线+绑定文字 | snow-draw-engine-editor/src/creation_workflow.rs:300-336；snow-draw-engine-document/src/document.rs:831-841, 898-916；snow-draw-engine-document/src/document_geometry.rs:190-214, 957-962 |
| 矩形滤镜（马赛克/模糊等） | 快捷键 `7`/`F`，拖拽出区域 | 滤镜类型 Mosaic/GaussianBlur/Grayscale/Inversion/Emboss/SmartErase/Brightness；强度默认 0.5，映射见 §2；矩形区域渲染 | snow-draw-engine-document/src/document.rs:513-555；snow-draw-engine-editor/src/defaults.rs（FilterStyle::default） |
| 画笔滤镜（路径马赛克/模糊） | "Pen Filter" 工具，沿路径涂抹 | 马赛克/模糊**跟随绘制路径**：存储归一化路径点 + 笔宽（默认 30px），渲染时按路径 mask 应用滤镜 | snow-draw-engine-document/src/document.rs:626-660；snow-draw-engine-editor/src/defaults.rs（pen_filter stroke_width 30） |
| 橡皮擦（Eraser） | 快捷键 `8`/`E` | 元素级擦除：指针路径命中到的整个元素被删除，松开时一次性提交为一条 "erase elements" 撤销记录 | snow-draw-engine-editor/src/eraser_workflow.rs:84-166 |
| 矩形/画笔还原擦 | RectangleEraser / BrushEraser | 擦除标注还原原始截图背景（RestoreBackground 通道），画笔笔宽档位 1–72 | snow-draw-engine-editor/src/input/policy.rs:159-166；snow-draw-engine-editor/src/style.rs:1051-1061；snow-draw-engine-document/src/document.rs:521（RestoreBackground） |
| 聚光灯 Spotlight | Spotlight 工具 | 形状外压暗，遮罩默认黑色、不透明度 0.64；不透明度连续变化 220ms 内合并撤销 | snow-draw-engine-document/src/document.rs:575-607；snow-draw-engine/src/history.rs:476-498 |
| 放大镜 Magnifier | Magnifier 工具 | 镜内放大显示原图，可拖动（"move magnifier lens"） | snow-draw-engine-document/src/document.rs MagnifierData；snow-draw-engine-editor/src/magnifier.rs:450 |
| 对话气泡 / 角度 / 距离 / 括号标注 | 面板对应工具 | 均为箭头/矩形的特化（LinearElementKind / HighlightShape::ThoughtBubble），气泡带尾巴与绑定文字 | snow-draw-engine-document/src/document.rs:1083-1101；snow-draw-engine-document/src/speech_bubble.rs |
| 裁剪 | 无独立工具 | Snow Shot 的"裁剪"即截图选区本身：选区确认后画布=选区，导出只含选区内标注 | snow_shot/src/presentation/overlay/screenshotoverlayshortcutcontroller.cpp:214-230（confirm_selection） |
| 水印 | 快捷键 `9` | 平铺文字水印，模板/字号 12/16/24/30/角度/间距/不透明度 | snow-draw-engine/src/history.rs（WatermarkConfig coalesce）；snow_shot/src/presentation/tools/screenshottoolpalettestylepresets.cpp:66-70 |
| 重置画布 | 面板按钮（设置默认 `Ctrl+Shift+Z`，与重做冲突，待查实际绑定） | 删除所有元素（deleteAllElements） | snow_shot/src/storage/configurationschema.cpp:575, 1275-1276；snow_shot/src/presentation/globalcanvas/globalcanvascontroller.cpp:815-817 |

## 2. 关键交互细节（用户能感知的每一个细节）

### 工具切换快捷键（默认值，可在设置改，每项最多 2 键）
选择 `V`、形状 `1`、箭头 `2`、画笔 `3`/`P`、高亮 `4`/`H`、文字 `5`/`T`、序号 `6`/`N`、滤镜 `7`/`F`、橡皮 `8`/`E`、水印 `9`（snow_shot/src/storage/configurationschema.cpp:566-575, 1249-1298）。

### 选中/多选/编辑
- 点击选中最上层命中元素（带 hit_tolerance 容差）；`Shift+点击` 在多选中加/减（snow-draw-engine-editor/src/selection.rs:91-105；snow-draw-engine-editor/src/input/quick_selection.rs:83-88）。
- 空白处按下拖拽 = 框选（marquee），松开提交（snow-draw-engine-editor/src/input/pointer_selection.rs:30,192）；右键拖拽保持现有组、Shift 切换选择且不抢占捕获（quick_selection.rs:429）。
- 选中后出现编辑框：整体移动、角点缩放、旋转柄旋转、矩形单独有圆角柄（SelectionEditMode: Move/Resize/Rotate/CornerRadius，snow-draw-engine-editor/src/geometry/cursors.rs:3-9；旋转柄中心 handles.rs:228）。
- 新建元素立即进入选中态（selecting_created，creation_workflow.rs:279）。
- `Escape` 取消当前交互；`Backspace`/`Delete` 删除选中（snow-draw-engine-editor/src/input/non_pointer.rs:168-177）。
- 删除级联：删序号徽章/箭头会连带删除其绑定文字（append_delete_dependencies，snow-draw-engine-editor/src/document_ops.rs:158-170）。
- 复制选中：整体复制并偏移，undo 该操作时**恢复原选中态**（history.rs:460, 496 的 restore_selection 特判）。
- 对齐/分布：左中右/上中下对齐 + 水平/垂直分布（最少元素数门槛），通过面板触发（document_ops.rs:1090+；globalcanvascontroller.cpp:795-806）。
- 选中态可批量改不透明度（Spotlight 除外，document_ops.rs:1228-1250）。

### z 顺序
- 四档操作：置顶/上移一层/下移一层/置底（reorder_selected action 0-3，document_ops.rs:1030-1086）。
- 箭头与其标签文字在 z 序中作为一层移动（含未选中但被穿越的配对，document_ops.rs:1040-1046）。

### 箭头细节
- 拖拽距离 < 10px 的"箭头"、< 8px 的"直线"直接丢弃，不进历史（creation_workflow.rs:358, 1465）。
- 折线模式下，距上一个点 ≥ 8px 才算确认新点；双击结束且不产生重复端点；重复单击终点也可结束（arrow_ops.rs:26；creation_workflow.rs:1506,1550,1635）。
- 端点吸附到其他元素（可绑定矩形/放大镜/序号等）后被绑元素移动/缩放时箭头重排；肘形箭头有专门正交布线器，支持固定段（snow-draw-engine-model/src/model.rs:208-230；snow-draw-engine-document/src/arrow/binding_geometry.rs）。
- 箭头标签：可拖到路径任意位置，记录 `text_path_fraction`；拖动标签是一条独立撤销记录 "move arrow text"（snow-draw-engine-document/src/arrow/data.rs:66-71；geometry/cursors.rs:15）。

### 文字编辑态
- 编辑中显示草稿（draft），草稿内自带独立的 undo/redo（Cmd+Z / Cmd+Shift+Z 在草稿层消化，snow_draw_engine_qt/src/text/snow_canvas_text_editor_input.cpp:46-52）。
- `Enter`/`Return` = 插入换行；`Ctrl+Enter` 或 `Esc` = 提交（text_editor_input.cpp:36-43, 131-135）。
- 提交时空文本 → 不创建元素/删除原空元素（snow-draw-engine-editor/src/text/commit.rs:85-131）。
- 编辑态 `Delete` 键删光标后字符；非编辑态 `Delete` 删除整个元素（text_editor_input.cpp:86-93 的 deleteTextAfterCursor 分支）。
- 编辑态支持全选/复制/剪切/粘贴、←→单字符、Ctrl+←→按词、Home/End（Ctrl 变体跳到全文首尾）、↑↓跨行（text_editor_input.cpp:99-128）。
- **IME 中文输入**：`QInputMethodEvent` 的 preedit 串进入草稿并替换选区，preedit 光标位置从 attribute 解析，preedit 期间选区被清空防误操作（snow_draw_engine_qt/src/text/snow_canvas_text_draft.cpp:51-145）。
- 编辑文字/序号工具时，鼠标滚轮直接步进字号（无需 Ctrl/Shift，text_editor_input.cpp:158-180）。

### 序号细节
- 放置后计数器自动 +1（仅带数字外形）；改数字格式或清空画布后按"同数字类型的现有最大值+1"重算（creation_workflow.rs:328-336；document_ops.rs:141-155）。
- 右键点击空白处 = 重置当前数字格式的计数器（quick_selection.rs:231-265 测试项 "right_blank_serial_resets_only_current_numeric_type"）。
- 徽章可拖动，拖动时显示预览矩形并吸附；徽章可挂文字，引导线两端自动跟随（SerialNumberTextConnection，document.rs:458-464）。
- 连续步进（+1/-1）合并为一条撤销记录；步回到原值时撤销记录被移除；改颜色等其他样式不合并（history.rs:530-558, serial_number_step_coalesce_key）。

### 滤镜细节
- 马赛克：块大小 = `2 + 20×强度²`（逻辑像素），默认强度 0.5 → 7px；网格锚定到图像原点（不是绘制起点），采样取块中心像素；屏幕渲染时块实际像素 = `round(块 × 相机缩放 × dpr)`（snow-draw-engine-display/src/lib.rs:229-232；snow_draw_engine_qt/src/rendering/snow_canvas_filter_render.cpp:278-307；snow_canvas_renderer.cpp:1756）。
- 高斯模糊：σ = `0.5 + 36×强度²`，用 3 次盒滤波近似；σ≥2 时先按 2/4/8/16/32/128 档降采样再模糊+双线性上采样（filter_render.cpp:966-990）；有 AVX2/NEON SIMD 路径（snow_canvas_filter_avx2.cpp / filter_neon.cpp）。
- 滤镜只有"单属性变化"（类型/强度/不透明度）且 220ms 内连续时合并撤销（history.rs:411-474）。

### 撤销/重做
- `Ctrl+Z` 撤销 / `Ctrl+Y` 重做（截图快捷键默认，configurationschema.cpp:607-608, 1361-1364）；画布键盘流同时硬编码 `Ctrl+Z` / `Ctrl+Shift+Z`（non_pointer.rs:151-158）。
- 粒度：创建、移动（"move selection"）、缩放（"resize selection"）、旋转（"rotate selection"）、圆角调整、箭头端点拖拽（"drag arrow endpoint"）、标签移动、样式修改、删除、复制、重排、画笔一笔（"free draw"）各为一条；**贴纸/元素移动算一条**（geometry/cursors.rs:3-18）。
- 合并策略（220ms 时间窗）：角度滚轮、聚光灯不透明度、水印文字、滤镜单属性；序号步进见上；其余每次松手一条。
- 无容量上限：撤销/重做为两个 Vec，新提交清空重做栈；仅文档校验时要求 ≤ 100,000 条、单条 ≤ 100 万操作（history.rs:124-131, 558-570）。
- 主图修改（截图阶段的 host edit）与标注历史共用一个栈，通过 host_state 令牌穿插（history.rs:117-138）。
- undo/redo 应用失败时条目回推不丢失（history.rs:443-451, 487-494）。

### 颜色与线宽档位
- 描边/填充/高亮各 5 个色槽，用户可在设置改（存 `#RRGGBBAA`）；默认值：描边 `#F5222D #52C41A #1677FF #FADB14 #000000`，填充 `#FFFFFF00(透明) #FFCCC7 #D9F7BE #BAE0FF #FFF1B8`，高亮 `#FF7875 #D3F261 #69B1FF #FFF566 #B37FEB`（snow_shot/src/storage/configurationschema.cpp:452-457；settingsadapters.cpp:324-368）。
- 文字颜色用描边色板、文字背景用填充色板（screenshottoolpalettestylepresets.cpp:25-30）。
- 线宽：形状 [默认(2), 4, 8]；画笔/线 [2, 4, 8]；字号/序号直径共用 S/M/L/XL = 24/30/42/54（screenshottoolpalettestylepresets.cpp:33-63）。
- 画笔还原擦笔宽范围 1–72（style.rs:1058）。

### 失败兜底
- 过短拖拽不创建元素也不进历史；非法数值（NaN/超界）在引擎层被 clamp 或拒绝（如 FilterData::normalized_strength、serial 校验）。
- 删除未选中元素时从选中集移除；撤销失败条目不丢。
- 空画布时部分工具进入"空画布动作"分支（policy.rs:159-166）。

## 3. 实现要点（动手前必须先定的技术决策）

1. **坐标系**：文档坐标（canvas space）与视图坐标（view space）分离，相机 `{center, zoom}`，所有输入先经 `view_to_canvas`；所有阈值（8px 加点、10px 最短箭头）都除以 zoom，保证不同缩放下手感一致（snow-draw-engine-editor/src/creation_workflow.rs:101-110；snapping.rs:114-125）。
2. **元素身份与失效**：`ElementId { index, generation }`，删除后复用 index 但 generation +1，旧引用自动失效防脏引用（snow-draw-engine-model/src/model.rs:301-321 测试）。
3. **双尺寸文字测量**：文字同时存"换行矩形（wrap）"和"实测 ink"，由宿主测字体；序号引导线锚在实测 ink 上，只存 wrap 会错位（snow-draw-engine-document/src/document.rs:875-885 注释；text/commit.rs:196-214）。Snapcut 若用 NSAttributedString 测量，同样要同时保留包裹框与实际绘制框。
4. **渲染清晰度（两条路径都要）**：
   - 屏幕上：矢量标注按设备像素比绘制；滤镜参数乘 `cameraZoom × dpr`（snow_canvas_renderer.cpp:1022, 1756-1758）。
   - 导出时：**矢量重绘**而非位图缩放——`rasterScale = max(1, min(outputW/canvasW, outputH/canvasH))`，painter 先 scale 再画，输出位图 `setDevicePixelRatio(rasterScale)`，马赛克/模糊的物理参数同样按 rasterScale 放大（snow_draw_engine_qt/src/rendering/snow_canvas_export.cpp:30-59, 260-263；filter_render.cpp:942-945）。
5. **命中测试**：每个元素实现 `hit_test(point, tolerance)`，多元素命中取"最上层"（paint_rank 缓存维护 z 序，避免每次遍历文档序）（snow-draw-engine-document/src/document.rs:977-995；snow-draw-engine-model/src/model.rs:170-176）。
6. **撤销栈结构**：条目 = `{label, undo 事务, redo 事务, undo/redo 时的选择态快照}`；恢复选中态需要快照而不只是逆事务（history.rs:19-28）。若 Snapcut 用 NSUndoManager，注意"undo 时恢复选中"和"连续步进合并"两个行为要在 undo target 外单独记录。
7. **性能护栏**：空间查询缓存（QueryStore）+ 脏区域（dirty_regions）+ 滤镜 tile 缓存 + SIMD 滤波；文字用宿主字体缓存（snow-draw-engine-model/src/query.rs；snow-draw-engine-scene/src/dirty_regions.rs；snow_draw_engine_qt/src/rendering/snow_canvas_filter_tile_cache.cpp）。
8. **持久化**：文档与撤销栈均可 serde JSON 序列化（历史里 host 状态跳过序列化，history.rs:49-59），Snapcut 若要"关闭窗口恢复标注"可参考。
9. **权限**：标注本身无权限；截图入口的屏幕录制权限在别的域。

## 4. 我们可以先不做的（非核心 / 平台相关 / 依赖网络）

- 放大镜、聚光灯、对话气泡、角度/距离/括号标注（低频特化）。
- 手绘描边风格 Architect/Artist/Cartoonist 与 crowfoot 系列 ER 箭头（database 图专用）。
- 肘形（Elbow）自动正交布线器——先用直线+曲线即可。
- SmartErase（AI 智能消除）、AutoFilter（自动识别 UI 元素区域后一键打码）、亮度/浮雕/反色/灰度滤镜。
- 水印、绘制模板（draw_templates）、MCP 自动化接口（mcpdocumentservice.cpp:146-163 是给自动化用的工具名映射）。
- 主图编辑与标注共栈的 host_state 机制（Snapcut 可简化为单一标注历史）。
- 云上传/打印/钉在屏幕（Pin）等导出目标。

## 5. 验收标准（可观测、可实测）

1. 拖拽创建箭头：拖动 <10px 松手后画布无新元素、撤销栈无新条目；正常拖拽松手后元素处于选中态。
2. 单击-单击折线：第二点距第一点 <8px 时不落点；双击结束，终点不重复。
3. Shift+点击同一元素两次 = 加入又移出多选；框选可同时选中多个元素；拖动多选整体移动且箭头标签随箭头一起动。
4. Delete 键删除选中序号徽章后，其引导文字一并消失；一次撤销两者同时回来。
5. z 序：置顶/置底后视觉层级立即变化，且与命中测试一致（点击重叠处选中最上层）。
6. 文字编辑：按 Enter 换行、Ctrl+Enter 提交、Esc 提交、空文本提交后无残留元素；中文输入法拼音预编辑期间不产生换行/提交，候选上屏后文本完整；滚轮在文字工具下改变字号。
7. 序号：连续放置 5 个徽章编号 1→5；删除第 3 个后再放新徽章编号为 6（max+1 语义）；右键空白重置后下一个从 1 开始；连续 ±1 步进只占一条撤销记录。
8. 马赛克：默认强度下块大小 ≈7 逻辑像素；把窗口放大到 200% 缩放再截，块像素数 ≈7×缩放×dpr（网格对齐图像原点，不随绘制起点漂移）；模糊默认 σ≈9.5。
9. 撤销/重做：移动一个矩形 = 1 条记录；Ctrl+Y 重做后再画新笔，重做栈被清空；undo 应用中途出错不丢栈。
10. 导出清晰度：1x 画布导出 2x 尺寸 PNG，文字/箭头边缘无锯齿（矢量重绘），马赛克块与屏幕一致。
11. Retina 屏（dpr=2）下标注线宽、字号与 1x 屏视觉一致（逻辑像素坐标系）。
