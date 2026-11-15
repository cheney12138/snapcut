// e2e_glass.swift — 工具栏玻璃质感（NSVisualEffectView 毛玻璃）像素验证脚本
//
// 用法：先 `make dev` 构建，再（手动或 E2E_LAUNCH=1）启动 build/Snapcut.app，
// 然后运行：swift e2e_glass.swift
// 流程：CGEvent 发 ⌘⇧A（区域截图热键）→ 拖选出选区 → 冻结画面 + 编辑器 + 工具栏弹出 →
//       screencapture 全屏到 /tmp/e2e_glass_out.png → 对工具栏区域做像素统计。
//
// 验证原理（「底下内容透出」）：
//   - 玻璃容器 = NSVisualEffectView(.hudWindow/.behindWindow/.active) + 60% 深色着色，
//     冻结画面会以「模糊 + 60% 压暗」的形式透进工具栏本体。
//   - 取样区：面板底部 8pt padding 带（y: panelMinY+2 .. +7，x 避开圆角）——
//     这一条是**纯玻璃**（按钮都在其上方，面板高 44 = 8 padding + 28 按钮 + 8 padding），
//     它的亮度方差只来自透出的背景内容。
//   - 判定：若面板是不透明纯色（改造前的病灶），这条带的 std ≈ 0（≤ 抖动噪声 ~0.4）；
//     真玻璃透出模糊背景时 std 明显更高。PASS 阈值 std > 1.2（0.6–1.2 为可疑，
//     多半是背后内容恰好均匀，请换内容丰富的背景重跑）。
//   - 同时裁出工具栏区域 /tmp/e2e_glass_crop.png 供人工目检。
//
// 坐标系约定（与 e2e_toolbar.swift 相同）：
//   - *_appKitY 是 AppKit 屏幕坐标（左下原点，pt）
//   - CGEvent 全局坐标是「左上原点 + 像素」，主屏换算：cgY = 1117 - appKitY
//   - 截图像素 = pt × 2（Retina 2x，主屏 1728×1117pt → 3456×2234px）；
//     px 里 y 轴翻转：pxY = (screenHeightPt - appKitY) × 2
//
// 铁律：脚本只发事件 + 截屏，不 pkill、不 commit；产物 /tmp/e2e_glass_out.png、
//       /tmp/e2e_glass_crop.png。GUI e2e 由主会话串行执行（AGENTS.md 纪律）。

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - 常量（按真机分辨率校准；主屏高 1117px ⇒ cgY = 1117 - appKitY）

let hotkeyCmdShiftA_keycode: CGKeyCode = 0x00   // A
let screenHeightPx: CGFloat = 1117              // 像素高（CGEvent 用）
let screenHeightPt: CGFloat = 1117 / 2          // pt 高（主屏 Retina 2x）
let retinaScale: CGFloat = 2                    // 主屏 2x

// 投影留白 = ToolbarPanel.TBStyle.shadowMargin（log 里的 panel= 是窗口 frame，含留白）
let shadowMargin: CGFloat = 40

// 选区（AppKit pt）：屏幕中部一块 400×300，给工具栏留下方空间
let selStart = CGPoint(x: 300, y: 750)
let selEnd   = CGPoint(x: 700, y: 450)

func cgY(_ appKitY: CGFloat) -> CGFloat { screenHeightPx - appKitY }

// MARK: - 事件原语

func post(_ e: CGEvent?) {
    guard let e else { fatalError("CGEvent 创建失败") }
    e.post(tap: .cghidEventTap)
}

func hotkey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    post(down); usleep(60_000); post(up)
}

func mouseMove(_ p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
}
func mouseDown(_ p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
}
func mouseDrag(_ p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
}
func mouseUp(_ p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
}

func dragSelection(from: CGPoint, to: CGPoint) {
    let startCG = CGPoint(x: from.x, y: cgY(from.y))
    let endCG = CGPoint(x: to.x, y: cgY(to.y))
    mouseMove(startCG); usleep(120_000)
    mouseDown(startCG); usleep(120_000)
    for i in 1...20 {
        let t = CGFloat(i) / 20
        mouseDrag(CGPoint(x: startCG.x + (endCG.x - startCG.x) * t,
                          y: startCG.y + (endCG.y - startCG.y) * t))
        usleep(16_000)
    }
    usleep(120_000)
    mouseUp(endCG)
}

// MARK: - log tailer（解析 evt=toolbar.buttons 的 panel= 窗口 frame）

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
        if started, proc.isRunning { proc.terminate() }
    }
}

/// 解析最后一条 toolbar.buttons 的 panel=x,y,w,h（AppKit pt，窗口 frame，含投影留白）
func panelFrame(from log: String) -> CGRect? {
    guard let line = log.split(separator: "\n").last(where: { $0.contains("evt=toolbar.buttons") }),
          let range = line.range(of: "panel=") else { return nil }
    let fields = line[range.upperBound...].prefix(while: { $0 != " " }).split(separator: ",")
    guard fields.count >= 4,
          let x = Double(fields[0]), let y = Double(fields[1]),
          let w = Double(fields[2]), let h = Double(fields[3]) else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

// MARK: - 像素统计

func loadPixels(_ path: String) -> (data: [UInt8], w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
}

/// 区域亮度均值 / 标准差（AppKit pt 矩形 → Retina 2x 像素，y 翻转）
func lumStats(_ px: (data: [UInt8], w: Int, h: Int), rect pt: CGRect)
    -> (mean: Double, std: Double, samples: Int) {
    // pt → 像素行（截图坐标，y 从顶部数）
    let x0 = max(0, Int(pt.minX * retinaScale)), x1 = min(px.w - 1, Int(pt.maxX * retinaScale))
    let pyTop = Int((screenHeightPt - pt.maxY) * retinaScale)
    let pyBot = Int((screenHeightPt - pt.minY) * retinaScale)
    let y0 = max(0, min(px.h - 1, pyTop)), y1 = max(0, min(px.h - 1, pyBot))
    var vals: [Double] = []
    guard x1 > x0, y1 > y0 else { return (0, 0, 0) }
    for yy in stride(from: y0, to: y1, by: 1) {
        for xx in stride(from: x0, to: x1, by: 2) {
            let i = (yy * px.w + xx) * 4
            vals.append(Double(px.data[i]) * 0.299 + Double(px.data[i+1]) * 0.587 + Double(px.data[i+2]) * 0.114)
        }
    }
    guard !vals.isEmpty else { return (0, 0, 0) }
    let m = vals.reduce(0, +) / Double(vals.count)
    let v = vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count)
    return (m, v.squareRoot(), vals.count)
}

/// 裁出工具栏区域存 PNG（含周围 40pt 余量）——逐行拷贝源像素（行距不同）
func saveCrop(_ px: (data: [UInt8], w: Int, h: Int), rect pt: CGRect, to path: String) {
    let x0 = max(0, Int((pt.minX - 40) * retinaScale)), x1 = min(px.w, Int((pt.maxX + 40) * retinaScale))
    let y0 = max(0, Int((screenHeightPt - pt.maxY - 40) * retinaScale))
    let y1 = min(px.h, Int((screenHeightPt - pt.minY + 40) * retinaScale))
    let w = x1 - x0, h = y1 - y0
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    for row in 0..<h {
        let srcOff = (y0 + row) * px.w * 4 + x0 * 4
        px.data.withUnsafeBytes { $0.baseAddress!.advanced(by: srcOff) }.withMemoryRebound(to: UInt8.self,
            capacity: w * 4) { src in
            ctx.data!.advanced(by: row * w * 4).copyMemory(from: src, byteCount: w * 4)
        }
    }
    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                    "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - 主流程

let tailer = LogTailer()
tailer.start()
usleep(300_000)

print("e2e: ① ⌘⇧A 开选区")
hotkey(hotkeyCmdShiftA_keycode, flags: [.maskCommand, .maskShift])
usleep(1_200_000)

print("e2e: ② 拖选 \(selStart) → \(selEnd)")
dragSelection(from: selStart, to: selEnd)
usleep(2_000_000)  // 冻结 + 工具栏 spring 入场 + dumpButtonCenters 打点

let frame = panelFrame(from: tailer.snapshot()) ?? {
    print("e2e: ⚠️ 未能从日志解析 panel=，回退硬编码（选区 (300,450)-(700,750) 下方）")
    return CGRect(x: 300, y: 394, width: 584, height: 108)  // 584=面板宽+2×32, 108=44+2×32
}()
tailer.stop()

// 面板本体 = 窗口 frame 内缩投影留白（AppKit pt）
let panel = frame.insetBy(dx: shadowMargin, dy: shadowMargin)
print("e2e: ③ 工具栏窗口 frame=\(frame) → 面板本体=\(panel)")

print("e2e: ④ screencapture → /tmp/e2e_glass_out.png")
let cap = Process()
cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
cap.arguments = ["-x", "/tmp/e2e_glass_out.png"]
try? cap.run()
cap.waitUntilExit()

guard let px = loadPixels("/tmp/e2e_glass_out.png") else {
    print("e2e: ✗ 截图读取失败"); exit(1)
}
print("e2e: 截图 \(px.w)x\(px.h)")

// 纯玻璃取样带：面板底部 8pt padding（y: panel.minY+2 .. panel.minY+7），
// x 避开两端圆角（各 16pt）。按钮最低点在 panel.minY+8 之上，这条带只有玻璃。
let glassStrip = CGRect(x: panel.minX + 16, y: panel.minY + 2,
                        width: panel.width - 32, height: 5)
let glass = lumStats(px, rect: glassStrip)

// 对照组 1：面板顶部 8pt padding（同样纯玻璃，另一条高度上的取样）
let topStrip = CGRect(x: panel.minX + 16, y: panel.maxY - 7,
                      width: panel.width - 32, height: 5)
let top = lumStats(px, rect: topStrip)

// 对照组 2：面板正上方同宽背景条（未被面板遮挡的遮罩+画面内容，作「内容方差」参照）
let contentRef = CGRect(x: panel.minX + 16, y: panel.maxY + shadowMargin + 10,
                        width: panel.width - 32, height: 14)
let ref = lumStats(px, rect: contentRef)

print("")
print("========== 玻璃透出验证 ==========")
print(String(format: "纯玻璃取样带（底部 padding） mean=%.1f std=%.2f (n=%d) rect=%@",
             glass.mean, glass.std, glass.samples, NSStringFromRect(glassStrip)))
print(String(format: "纯玻璃取样带（顶部 padding） mean=%.1f std=%.2f", top.mean, top.std))
print(String(format: "面板上方背景参照           mean=%.1f std=%.2f", ref.mean, ref.std))
print("")
print("判定：不透明纯色面板的取样带 std ≈ 0（抖动噪声 ≤ ~0.4）；")
print("      真玻璃透出模糊背景时 std 显著更高。")
if glass.std > 1.2 {
    print("e2e: ✓ PASS —— 工具栏底部玻璃带 std=\(String(format: "%.2f", glass.std)) > 1.2，底下内容透出")
} else if glass.std > 0.6 {
    print("e2e: ⚠️ SUSPECT —— std=\(String(format: "%.2f", glass.std)) 处于可疑区（0.6~1.2）：")
    print("      可能是工具栏背后恰好是均匀画面。请在内容丰富的背景下重跑，")
    print("      并人工检查 /tmp/e2e_glass_crop.png。")
} else {
    print("e2e: ✗ FAIL —— std=\(String(format: "%.2f", glass.std)) ≤ 0.6，玻璃带接近纯色：")
    print("      面板不透明或背后无内容可透（检查 NSVisualEffectView/.behindWindow/appearance）。")
}
print("")
print("人工目检：裁图 /tmp/e2e_glass_crop.png（面板区域含 40pt 余量）")
saveCrop(px, rect: panel, to: "/tmp/e2e_glass_crop.png")
print("产物：/tmp/e2e_glass_out.png（全屏）、/tmp/e2e_glass_crop.png（裁图）、面板 rect(pt)=\(panel)")
print("日志核对：log show --info --last 2m --predicate 'subsystem==\"app.snapcut\" AND category==\"editor\"' | grep toolbar.buttons")
