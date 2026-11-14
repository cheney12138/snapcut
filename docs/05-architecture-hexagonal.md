# 架构：六边形（Ports & Adapters）

> 状态：已落地骨架（v0.2，2026-11-14）。`make dev` 每次跑 `scripts/check-architecture.sh`，
> 依赖方向被破坏**直接构建失败**，不靠自觉。

## 1. 为什么现在做

功能面还要长（OCR / 贴图 / 历史 / 录屏…），每加一个都会碰「系统能力」。
如果系统能力被 UI 直接调用，功能越多，换实现越贵（比如窗口截图从「整屏裁剪」
换成「SCK 单窗口滤镜」，或 OCR 从 Vision 换成服务端）。
六边形把这件事变成**换一个适配器**，领域与用例不动。

## 2. 分层与依赖方向

```
        ┌────────────── 外圈：驱动/被驱动适配器 ──────────────┐
        │  UI（AppKit 覆盖层/编辑器/工具栏/托盘/贴图窗口）      │
        │  Adapters（ScreenCaptureKit、NSPasteboard、Vision、 │
        │            Carbon 热键、TCC、文件系统）              │
        └───────────────────────┬────────────────────────────┘
                                │ 只依赖端口协议
                    ┌───────────▼───────────┐
                    │  Core/Ports（协议）    │
                    └───────────┬───────────┘
                                │ 只依赖领域
                    ┌───────────▼───────────┐
                    │  Core/Domain（纯算法） │
                    └───────────────────────┘
```

**硬规则（脚本强制）**

1. `Sources/Core/**` 只允许 `Foundation` / `CoreGraphics` / `os`。
   禁止 `AppKit`、`ScreenCaptureKit`、`Vision`、`Carbon`、`UniformTypeIdentifiers`。
2. `Sources/UI/**` 禁止 import `ScreenCaptureKit` / `Vision`（必须走端口）。
3. 合成根只有一个：`Sources/App/AppCoordinator.swift`。只有它能 `new` 适配器。

## 3. 目录

```
Sources/
  App/                      合成根（main / AppDelegate / AppCoordinator）
  Core/
    Shared/Log.swift        os.Logger（跨层可用）
    Domain/
      AnnotationModel.swift 标注实体 + 存储 + undo/redo
      Stitcher.swift        滚动拼接纯算法
      RGBAColor.swift       领域颜色值类型（不带 NSColor）
      SelectionGeometry.swift  选区调整纯几何（缩放/移动/微调）
    Ports/Ports.swift       全部端口协议 + Dependencies 依赖容器
  Adapters/
    Capture/SCKCapture.swift        → ScreenCapturing
    Clipboard/ClipboardWriter.swift → ClipboardWriting（PasteboardClipboard）
    Hotkey/CarbonHotKeyCenter.swift → HotkeyRegistering
    Permission/TCCPermission.swift  → ScreenPermissionChecking
    Scroll/ScrollCaptureController.swift
    History/FileHistoryStore.swift  → HistoryRecording     （并行模块产出）
    OCR/VisionTextRecognizer.swift  → TextRecognizing      （并行模块产出）
    Pin/PinWindowController.swift   → PinningPresenting    （并行模块产出）
    PortConformances.swift          适配器薄包装
  UI/
    Overlay/   覆盖层（选区/编辑画布/窗口命中/放大镜）
    Editor/    编辑会话 + 工具栏
    Annotate/  CGRenderer（渲染适配器，AppKit 文本绘制）
    Tray/      状态栏
    Permission/ 权限拖拽引导
    Platform/  坐标换算、显示器注册、图标绘制
    Export/    保存面板
```

## 4. 端口一览

| 端口 | 职责 | 当前适配器 | 换实现的场景 |
|---|---|---|---|
| `ScreenCapturing` | 采集整块显示器 | ScreenCaptureKit | 改用 CGWindowList / 单窗口滤镜 |
| `ClipboardWriting` | 复制图片/文本 | NSPasteboard（PNG+TIFF） | 加 FileURL、写富文本 |
| `HistoryRecording` | 记录一次导出 | 本地文件索引 | 换 SQLite / 云同步 |
| `TextRecognizing` | 图片转文字 | Vision（本地离线） | 换在线 OCR |
| `HotkeyRegistering` | 全局热键 | Carbon RegisterEventHotKey | 换 NSEvent 全局监听 |
| `ScreenPermissionChecking` | 屏幕录制权限 | TCC（CGPreflight/Request） | — |
| `PinningPresenting` | 贴在屏幕上的图 | NSWindow | 换多屏分组/持久化恢复 |

## 5. 迁移状态（诚实清单）

| 项 | 状态 | 说明 |
|---|---|---|
| 目录分层 | ✅ | Core / Adapters / UI / App |
| Core 纯净性守卫 | ✅ | `scripts/check-architecture.sh`，`make dev` 强制 |
| 端口协议 | ✅ | 7 个端口 + `Dependencies` |
| 适配器 conformance | 🟡 | 采集/剪贴板/热键/权限已包；History/OCR/Pin 并行产出后接线 |
| 合成根注入 | 🟡 | `AppCoordinator` 仍是「单例 + 直连」；下一步改为持有 `Dependencies` 并向下传 |
| UI 只依赖端口 | 🟡 | 覆盖层仍直接调 `SCKCapture`（经 `CaptureService`）；下一步删除直连 |
| 用例层（UseCases） | ⬜ | 目前用例逻辑在 `OverlayController`/`EditorSession` 里，随功能增长再抽 |

**不追求一次改完**：每次动到一个文件，就把它顺手按方向归位；新代码必须端口优先。

## 6. 新功能落地流程（约束）

1. 先问：这块的「外部世界」是什么？→ 定义端口（加进 `Core/Ports`）。
2. 纯逻辑（几何/算法/状态机）写进 `Core/Domain`，只 import CoreGraphics。
3. 系统调用写成适配器，放 `Sources/Adapters/<能力>/`，conform 端口。
4. UI 只拿端口或用例，不拿具体适配器类型；构造在 `AppCoordinator`。
5. 交付前跑 `make dev`：架构守卫 + 编译 + 真机行为验证（不写单测/不打桩）。

## 7. 与「原型驱动 UI」的关系

UI 的外观仍以 `html-pages/snapcut-design/index.html` 为唯一真源
（见 `docs/design-brief.md`）。六边形只管**依赖方向**，不规定视觉；
UI 层可以自由用 AppKit/NSVisualEffectView，只要它不越过端口去碰系统能力。
