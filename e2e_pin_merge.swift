// e2e_pin_merge.swift —— C3 Pin 合并手势（⌥拖成组进拼贴）实机验证脚本
//
// 前置（由主会话串行执行，worker 不跑 App）：
//   1. make dev 构建 C3 代码 + C2 拼贴画布已接线（AppCoordinatorShared.collageTarget 非空）
//   2. 用户连拍两张截图并 pin 到屏幕（⌘⇧A 框选 → 贴图），得到图 A（源）与图 B（目标）
//      或用拼贴窗口先打开（任意方式让 collageTarget 挂上）
//   3. 运行本脚本：swift e2e_pin_merge.swift [Ax Ay] [Bx By]
//      坐标为两张 pin 图中心点的 AppKit 全局坐标（Y 向上），默认 (400,400) / (1000,400)
//
// 验证点：
//   - ⌥拖图 A 到图 B 上松手 → unified log 出现 pin.merge.dragBegin → pin.merge.pair
//   - 两个 pin 窗关闭（pin.close 两条），两张图进拼贴画布相邻两格
//
// 关键：注入事件全程带 ⌥ 修饰（CGEventFlags.maskAlternate）——
// PinContentView.mouseDown 按 modifierFlags.contains(.option) 分流合并手势。

import AppKit
import CoreGraphics

let ax = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 400 : 400.0
let ay = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 400 : 400.0
let bx = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 1000 : 1000.0
let by = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 400 : 400.0

let source = CGPoint(x: ax, y: ay)   // 图 A 中心（被拖）
let target = CGPoint(x: bx, y: by)   // 图 B 中心（落点）

func cg(_ p: CGPoint) -> CGPoint {
    guard let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main else { return p }
    return CGPoint(x: p.x, y: s.frame.maxY - p.y)
}

func post(_ type: CGEventType, _ appKit: CGPoint, option: Bool, delayUs: useconds_t = 40_000) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cg(appKit), mouseButton: .left) else {
        fputs("e2e: event create failed\n", stderr); exit(2)
    }
    if option { e.flags = .maskAlternate } else { e.flags = [] }
    e.post(tap: .cghidEventTap)
    usleep(delayUs)
}

// ⌥拖：A 中心按下 → 分 12 步拖到 B 中心 → 松手（全程 ⌥）
post(.mouseMoved, source, option: true)
post(.leftMouseDown, source, option: true)
for i in 1...12 {
    let t = Double(i) / 12
    let p = CGPoint(x: source.x + (target.x - source.x) * t, y: source.y + (target.y - source.y) * t)
    post(.leftMouseDragged, p, option: true)
}
usleep(120_000) // 悬停一下，让 HUD「松手合并进拼贴」出现
post(.leftMouseUp, target, option: true)

// 捞 unified log：合并事件链是否打点
usleep(500_000)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
task.arguments = ["show", "--last", "1m", "--style", "compact",
                  "--predicate", #"subsystem == "app.snapcut""#]
let pipe = Pipe(); task.standardOutput = pipe
try? task.run(); task.waitUntilExit()
let out = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
let begin = out.contains("pin.merge.dragBegin")
let pair = out.contains("pin.merge.pair")
let closes = out.components(separatedBy: "pin.close").count - 1

print("dragBegin: \(begin ? "✓" : "✗")  pair: \(pair ? "✓" : "✗")  pin.close count: \(closes)")
if begin && pair {
    print("PASS：⌥拖合并事件链完整（两图成组进拼贴，pin 窗应已关闭）")
    exit(0)
} else {
    print("FAIL：检查 collageTarget 是否已接线 / 两张 pin 是否在指定坐标")
    exit(1)
}
