// e2e_mosaic.swift —— 马赛克工具「点了没反应」修复的实机验证脚本
//
// 流程：⌘⇧A 开选区 → 拖选 → 点马赛克工具（tag=4）→ 选区内拖一块 → screencapture
//
// 用法（需辅助功能 + 屏幕录制权限，终端 App 必须已授权）：
//   swift e2e_mosaic.swift
// 产物：/tmp/e2e_mosaic_out.png（马赛克区域应呈现明显像素块，而非几乎不可见的淡罩）
//
// 坐标说明（屏幕 1728×1117，cgY = 1117 - appKitY）：
//   - 选区 / 马赛克拖拽坐标写死；
//   - 工具栏马赛克按钮中心：运行时从 unified log（editor 分类 toolbar.buttons 事件，
//     ToolbarPanel.dumpButtonCenters 打点）解析 panel=x,y,w,h → mosaic = (panelX+107, panelY+19)
//     （第 4 个工具按钮：inset 6 + 3×(28+1) + 14 = 107；垂直居中 38/2 = 19）；
//     解析失败时回退硬编码估算值 (467, 269)。
//   - 所有注入的鼠标事件显式 flags = []（防止 ⌘⇧A 的 Shift 残留触发选区 1:1 锁）。

import AppKit
import CoreGraphics

// MARK: - 坐标常量（AppKit 全局坐标，Y 向上）

let screenH: CGFloat = 1117

// 选区：从 (400,300) 拖到 (1000,700)（AppKit）→ 选区 600×400
let selStart = CGPoint(x: 400, y: 300)
let selEnd = CGPoint(x: 1000, y: 700)

// 马赛克拖拽：选区内 (600,500) → (850,620)（AppKit）
let mosaicStart = CGPoint(x: 600, y: 500)
let mosaicEnd = CGPoint(x: 850, y: 620)

// 工具栏 mosaic 按钮中心回退值（panel 宽估算 ≈ 680 → panelX = 700 - 340 = 360）
let mosaicButtonFallback = CGPoint(x: 467, y: 269)

func cg(_ p: CGPoint) -> CGPoint {  // AppKit → CG
    CGPoint(x: p.x, y: screenH - p.y)
}

// MARK: - 事件注入

func postMouse(_ type: CGEventType, _ appKit: CGPoint, clickCount: Int = 0, delayUs: useconds_t = 40_000) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cg(appKit), mouseButton: .left) else {
        fputs("e2e: mouse event create failed\n", stderr)
        exit(2)
    }
    // 关键：flags 显式清空——⌘⇧A 之后系统可能残留 modifier 状态，
    // Shift 残留会让选区拖拽触发 1:1 锁（rect 变正方形）
    e.flags = []
    e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    e.post(tap: .cghidEventTap)
    usleep(delayUs)
}

func drag(from: CGPoint, to: CGPoint, steps: Int = 10) {
    postMouse(.mouseMoved, from)
    postMouse(.leftMouseDown, from, clickCount: 1)
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        postMouse(.leftMouseDragged, p)
    }
    postMouse(.leftMouseUp, to)
}

func pressHotkeyCmdShiftA() {
    let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
    // kVK_ANSI_A = 0（Carbon HIToolbox；脚本不引 Carbon，直接用扫描码字面量）
    let keyA = CGKeyCode(0)
    guard
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyA, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyA, keyDown: false)
    else {
        fputs("e2e: key event create failed\n", stderr)
        exit(2)
    }
    down.flags = cmdShift
    up.flags = cmdShift
    down.post(tap: .cghidEventTap)
    usleep(60_000)
    up.post(tap: .cghidEventTap)
    usleep(400_000)
}

// MARK: - log tailer（editor 分类，解析 toolbar.buttons 的 panel 坐标）

final class LogTailer {
    private let proc = Process()
    private let q = DispatchQueue(label: "e2e.logtailer")
    private var buffer = ""
    private(set) var started = false

    func start() {
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream", "--style", "compact", "--level", "info",
            "--predicate", "subsystem == \"app.snapcut\" AND category == \"editor\"",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self?.q.async { self?.buffer += s }
        }
        do {
            try proc.run()
            started = true
        } catch {
            fputs("e2e: log stream 启动失败：\(error)\n", stderr)
        }
    }

    func snapshot() -> String { q.sync { buffer } }

    func stop() {
        if started, proc.isRunning {
            proc.terminate()
        }
    }
}

/// 从 log 里解析 evt=toolbar.buttons 的 panel=x,y,w,h → mosaic 按钮中心
func mosaicButtonCenter(from log: String) -> CGPoint? {
    guard let line = log.split(separator: "\n").last(where: { $0.contains("evt=toolbar.buttons") }),
          let panelRange = line.range(of: "panel=") else { return nil }
    let rest = line[panelRange.upperBound...]
    let fields = rest.prefix(while: { $0 != " " }).split(separator: ",")
    guard fields.count >= 3,
          let px = Double(fields[0]), let py = Double(fields[1]) else { return nil }
    // 第 4 个工具按钮（mosaic，tag=4）：stack edgeInsets L6 + 3×28 + 3×gap1 + 14 = 107
    return CGPoint(x: px + 107, y: py + 19)
}

// MARK: - 主流程

let tailer = LogTailer()
tailer.start()
usleep(300_000)

print("e2e: ① ⌘⇧A 开选区")
pressHotkeyCmdShiftA()
usleep(1_200_000)

print("e2e: ② 拖选 \(selStart) → \(selEnd)")
drag(from: selStart, to: selEnd)
usleep(1_800_000)  // 冻结 + 工具栏入场动画 + dumpButtonCenters（0.4s 后打点）

let center = mosaicButtonCenter(from: tailer.snapshot()) ?? {
    print("e2e: ⚠️ 未能从 toolbar.buttons 解析按钮坐标，回退硬编码 \(mosaicButtonFallback)")
    return mosaicButtonFallback
}()
print("e2e: ③ 点击马赛克工具（tag=4）@ \(center)")
postMouse(.mouseMoved, center)
postMouse(.leftMouseDown, center, clickCount: 1)
postMouse(.leftMouseUp, center)
usleep(600_000)

print("e2e: ④ 选区内拖马赛克 \(mosaicStart) → \(mosaicEnd)")
drag(from: mosaicStart, to: mosaicEnd)
usleep(800_000)

print("e2e: ⑤ screencapture → /tmp/e2e_mosaic_out.png")
let cap = Process()
cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
cap.arguments = ["-x", "/tmp/e2e_mosaic_out.png"]
try? cap.run()
cap.waitUntilExit()

tailer.stop()
print("e2e: 完成。检查 /tmp/e2e_mosaic_out.png 中选区 (600,500)-(850,620) 区域应有明显马赛克块。")
print("e2e: 日志核对：log show --info --last 1m --predicate 'subsystem==\"app.snapcut\" AND category==\"editor\"' | grep -E 'toolbar.buttons|shape.commit|annotate.tool.select'")
