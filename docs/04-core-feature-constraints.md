# Snapcut 核心功能约束（覆盖 80% 截图场景）

> 来源：Snow Shot 源码功能提炼（`docs/research/01-capture.md` … `05-pin-ocr-export.md`）
> + 自身 `docs/02-product-spec.md`。本文档是**开发约束**：每条都是可实测的验收条件。
> 纪律：功能先跑通再谈视觉；每个功能必须能在真实屏幕上复现验证，不写单测不打桩。

---

## 0. 结论：哪 8 个功能覆盖 80% 场景

| # | 能力 | 覆盖场景 | 状态 |
|---|---|---|---|
| 1 | 区域截图（拖选 → 标注 → Enter） | 一切场景的地基 | ✅ v0.1 |
| 2 | 冻结屏幕 + 窗口悬停/整屏 | 精确框选、发整窗截图 | ✅ 本轮（⌘⇧S / 悬停 / 单击整窗 / 双击全屏） |
| 3 | 标注 6 件套（箭头/矩形/文字/马赛克/序号/高亮） | 指问题、藏隐私、写步骤 | ✅ v0.2 |
| 4 | **选区可反复调整** | 手抖框歪了不用重来（最高频的挫败点） | 🔨 本轮 |
| 5 | **放大镜 + 像素取色** | 精确切边、取色值 | 🔨 本轮 |
| 6 | **历史记录 + 快速保存** | 「刚截的图哪去了/忘了保存」 | 📤 子系统 |
| 7 | **OCR 取字** | 截图转文字（macOS Vision 本地，零依赖） | 📤 子系统 |
| 8 | **贴图 Pin** | 对照稿钉在屏幕上 | 📤 子系统 |

已具备但需补细节：滚动长截图 ✅、复制到剪贴板（PNG+TIFF）✅、保存面板 ✅。

本轮**明确不做**：录屏/GIF、AI 修图、云上传、贴图分组持久化、多区域布尔运算、折线/曲线选区。

---

## 1. 架构约束（已落地，后续功能必须遵守）

| 约束 | 说明 | 代码位置 |
|---|---|---|
| **先冻结再选区** | 触发截图 → 拍全部显示器（单屏 ~82ms）→ 才创建覆盖层窗口。窗口上铺的是静态帧 | `OverlayController.begin` |
| **覆盖层永不入图** | 结构保证：截图发生在任何窗口存在之前。禁止在 begin() 里提前 orderFront | 同上 |
| **松手不再二次屏捕** | 用冻结帧本地裁剪（`cropFrozenImage`），保证「所见=所得」 | `didSelect` |
| **像素比例实测** | 一律 `CoordinateConverter.pixelRect(imageWidth:imageHeight:)`，不信任 `backingScaleFactor` | `CoordinateConverter` |
| **激活必须兜底重试** | 无鼠标点击的入口（热键）必须 `ensureActivation()` 重试，否则 Enter/Esc 全丢 | `ensureActivation` |
| **导出所见即所得** | 编辑画布与导出共用 `CGRenderer`，`contextIsYDown` 区分坐标系 | `CGRenderer` |

---

## 2. 待实现功能的行为约束

### 2.1 选区调整（P0，本轮）

用户松手后**不需要重来**：选区可以继续改。

| 行为 | 约束 |
|---|---|
| 8 向手柄 | 选区四角 + 四边中点，悬停变对应缩放光标；命中容差 8pt |
| 整体移动 | 在选区内拖拽（非手柄区）平移选区 |
| 空格临时移动 | 拖拽中按空格切换为整体移动，松开恢复 |
| Shift 锁比例 | 框选/改尺寸时强制 1:1 |
| 方向键微调 | ↑↓←→ 逐 1px（按 Shift 逐 10px）移动选区，改完后底图重裁 |
| 尺寸标签 | 拖拽/调整中实时显示 `宽×高`（像素），选区 >40pt 才显示手柄 |
| 最小尺寸 | 1px 也有效（点击不拖动不算截图，仍走「单击=窗口/无操作」） |
| Esc | 任何调整中 Esc 直接取消整个过程 |

**验收**：拖选 → 松手 → 拖右下手柄改大小 → 方向键微调 → Enter，导出的像素尺寸等于最终选区。

### 2.2 放大镜 + 像素取色（P0，本轮）

| 行为 | 约束 |
|---|---|
| 触发 | 选区阶段（含拖拽中）跟随光标自动显示 |
| 内容 | 光标周围 11×11 源像素，12 倍放大（132×132pt），中心像素描边标记 |
| 读数 | 第一行 `X: n  Y: n`（屏幕点坐标），第二行 `#RRGGBB` |
| 定位 | 光标右下 16pt，贴屏幕边缘自动翻到另一侧 |
| 性能 | 抽样自冻结帧（禁止实时屏捕），每帧只重绘 121 个像素 |
| 取色复制 | 选区阶段按 `C` → 复制 hex 到剪贴板并结束截图 |

**验收**：选区阶段移动光标，放大镜跟随且读数与「系统 Digital Color Meter」一致（±1 色阶）。

### 2.3 历史记录（P0，子系统）

| 行为 | 约束 |
|---|---|
| 写入 | **任何导出都写历史**：复制、保存、贴图、OCR 原图 |
| 存储 | `~/Library/Application Support/Snapcut/history/`，PNG + `index.json` |
| 保留 | 最近 30 条，超出删除最旧（含文件） |
| 打开 | 托盘菜单一级子菜单：缩略图 + 时间 + 尺寸 |
| 点击 | 复制该图到剪贴板 |
| 清空 | 菜单项「清空历史」 |
| 失败 | 写盘失败只记日志，绝不打断截图主流程 |

**验收**：连截 3 张 → 托盘菜单出现 3 条 → 点第 2 条 → 剪贴板内容 = 第 2 张的像素。

### 2.4 OCR 取字（P1，子系统）

| 行为 | 约束 |
|---|---|
| 引擎 | macOS Vision `VNRecognizeTextRequest`（`.accurate`），语言 zh-Hans/en，本地离线 |
| 入口 | 编辑器工具栏「取字」按钮 + 快捷键 `O` |
| 结果 | 浮层窗口贴在选区原位，可编辑文本视图，自动全选，⌘C 可复制 |
| 复制 | 「复制文字」按钮 + Enter 直接复制并关窗 |
| 失败 | 未识别到文字 → 浮层提示「未识别到文字」，不关窗 |
| 性能 | 500×500 图 ≤ 300ms |

**验收**：截一段中文终端文字 → 按 O → 浮层文字与截图一致，Enter 后剪贴板是纯文本。

### 2.5 贴图 Pin（P1，子系统）

| 行为 | 约束 |
|---|---|
| 入口 | 工具栏「贴图」按钮 + 快捷键 `P` |
| 窗口 | 无边框、无阴影、`level = .floating`、尺寸 = 选区像素、出现在选区原位 |
| 移动 | 整窗拖拽 |
| 缩放 | 滚轮以光标为锚 10%–500% |
| 透明度 | ⌥+滚轮 20%–100% |
| 关闭 | Esc / 右键菜单「关闭」；不支持持久化恢复（本轮不做） |
| 多张 | 同时存在多张贴图，互不影响 |

**验收**：截图按 P → 出现贴图 → 拖动改变位置 → 滚轮放大 → 切换到别的 App 后贴图仍在最前。

### 2.6 延时截图（P2，本轮可选）

| 行为 | 约束 |
|---|---|
| 入口 | 托盘「延时 3 秒截图」 |
| 行为 | 倒计时 HUD（半透明卡片，显示剩余秒数，跟进鼠标屏）；到点走区域截图流程 |
| 取消 | 倒计时期间 Esc 取消 |

---

## 3. 子系统接口契约（并行开发用，签名固定）

```swift
// Sources/History/HistoryStore.swift
@MainActor final class HistoryStore {
    static let shared: HistoryStore
    struct Item: Identifiable { let id: String; let date: Date; let pixelSize: CGSize; let url: URL }
    func record(_ image: CGImage)                       // 任何导出后调用；失败只记日志
    func items() -> [Item]                              // 新→旧
    func copyToPasteboard(_ item: Item) -> Bool
    func clearAll()
}

// Sources/OCR/TextRecognizer.swift
enum TextRecognizer {
    static func recognize(_ image: CGImage) async throws -> String   // 空字符串 = 无文字
}
// Sources/OCR/OCRResultPanel.swift
@MainActor enum OCRResultPanel {
    static func present(text: String, nearGlobalRect rect: CGRect, on screen: NSScreen)
}

// Sources/Pin/PinWindowController.swift
@MainActor final class PinWindowController {
    static func pin(_ image: CGImage, atGlobalRect rect: CGRect, on screen: NSScreen)
}
```

**并行纪律**：子任务只创建自己目录下的新文件，**不得修改** `OverlayWindow.swift / ToolbarPanel.swift / AppCoordinator.swift / StatusItemController.swift`——这些集成点由主会话统一接线，避免并发写冲突。

---

## 4. 验证方式（禁止单测/打桩）

| 层级 | 手段 |
|---|---|
| 行为 | 真实屏捕 + `CGEvent` 注入 + 录屏回放（`screencapture -v`） |
| 像素正确性 | 导出图 vs `screencapture` 同区域逐像素 diff（平均差 <0.02） |
| 性能 | os_log 计时打点（`overlay.open freezeMs`、`editor.export ms`） |
| 交互手感 | 子任务交付后由主会话实机跑一遍全流程，并截图存档 |
