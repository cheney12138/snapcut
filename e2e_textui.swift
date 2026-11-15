// e2e_textui.swift — 文字输入 UI 重做（字号条+输入框玻璃视觉）实机验证脚本
//
// 前置（由主会话串行执行，AGENTS.md 实机纪律）：
//   make dev && make run   （或 build/Snapcut.app/Contents/MacOS/Snapcut 已在跑）
//   终端/Snapcut 已有屏幕录制 + 辅助功能（Accessibility）授权
//
// 流程：⌘⇧A 开选区 → 拖选 → 点工具栏「文字」→ 点画布出输入框（+浮动字号条）
//       → 点字号条「Aa21」档（验证点选高亮 + 输入框实时变字号）
//       → 键入 Snapcut → 不落字，保持编辑态
//       → screencapture /tmp/e2e_textui_out.png（验证字号条+输入框视觉）
//
// 坐标约定：脚本里一律给 AppKit 坐标（原点左下、Y 向上），发 CGEvent 时
// 换算 cgY = 1117 - appKitY（主屏 1117pt 高，与既有 e2e_* 脚本同约定）。
// 鼠标事件 flags=[]（不带修饰键）。

import AppKit
import CoreGraphics

let src = CGEventSource(stateID: .hidSystemState)
let screenH: CGFloat = 1117

func cg(_ appKitPoint: CGPoint) -> CGPoint {
    CGPoint(x: appKitPoint.x, y: screenH - appKitPoint.y)
}

func move(_ appKitPoint: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: cg(appKitPoint), mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(120_000)
}

/// flags=[] 的鼠标点击（任务要求：鼠标事件不带修饰键）
func click(_ appKitPoint: CGPoint) {
    move(appKitPoint)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: cg(appKitPoint), mouseButton: .left)!
    down.flags = []
    down.post(tap: .cghidEventTap); usleep(90_000)
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: cg(appKitPoint), mouseButton: .left)!
    up.flags = []
    up.post(tap: .cghidEventTap); usleep(350_000)
}

func drag(_ a: CGPoint, _ b: CGPoint) {
    move(a)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: cg(a), mouseButton: .left)!
    down.flags = []
    down.post(tap: .cghidEventTap); usleep(180_000)
    for t in stride(from: 0.1, through: 1.0, by: 0.1) {
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: cg(p), mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(70_000)
    }
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: cg(b), mouseButton: .left)!
    up.flags = []
    up.post(tap: .cghidEventTap); usleep(1_500_000)
}

func key(_ vk: CGKeyCode, _ flags: CGEventFlags = []) {
    let d = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)!
    d.flags = flags; d.post(tap: .cghidEventTap); usleep(70_000)
    let u = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)!
    u.flags = flags; u.post(tap: .cghidEventTap); usleep(150_000)
}

/// 用 CGEventKeyboardSetUnicodeString 注入任意文本（绕过键码布局问题）
func typeText(_ s: String) {
    for ch in s.unicodeScalars {
        let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
        var chars = [UniChar](String(ch).utf16)
        d.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        d.post(tap: .cghidEventTap); usleep(50_000)
        let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
        u.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        u.post(tap: .cghidEventTap); usleep(120_000)
    }
}

/// 从 unified log 抓最近一次 toolbar.buttons 打点，解析指定 tag 按钮的屏幕中心（AppKit 坐标）
func toolbarButtonCenter(tag: Int) -> CGPoint? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    proc.arguments = [
        "show", "--style", "compact", "--last", "2m",
        "--predicate", "subsystem == \"app.snapcut\" AND eventMessage CONTAINS \"toolbar.buttons\"",
    ]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    try? proc.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let out = String(data: data, encoding: .utf8) else { return nil }
    // 行形如：evt=toolbar.buttons centers=3@211,586 4@240,586 ... panel=...
    for line in out.split(separator: "\n").reversed() {
        guard let idx = line.range(of: "centers=") else { continue }
        let entries = line[idx.upperBound...].split(separator: " ")
        for entry in entries {
            let parts = entry.split(separator: "@")
            if parts.count == 2, let t = Int(parts[0]), t == tag {
                let xy = parts[1].split(separator: ",")
                if xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) {
                    return CGPoint(x: x, y: y)
                }
            }
        }
    }
    return nil
}

// MARK: - 流程

// 1) ⌘⇧A 开区域截图
key(0, [.maskCommand, .maskShift])
usleep(2_000_000)

// 2) 拖选（AppKit 坐标，屏幕中部：AppKit y 400→750 = CG y 717→367）
drag(CGPoint(x: 400, y: 400), CGPoint(x: 1000, y: 750))
usleep(1_000_000)

// 3) 点工具栏「文字」按钮（tag 3；坐标来自 toolbar.buttons 日志打点）
guard let textBtn = toolbarButtonCenter(tag: 3) else {
    print("FAIL: toolbar.buttons 里没找到文字按钮(tag=3)")
    exit(1)
}
print("text button at \(textBtn)")
click(textBtn)
usleep(400_000)

// 4) 点选区内部 → 出输入框 + 浮动字号条（贴输入框上方 8pt）
click(CGPoint(x: 550, y: 520))
usleep(800_000)

// 5) 点字号条第 4 档「Aa21」（条贴输入框上方 8pt）
//    点击点 AppKit y=520 → 本地 Y-down y=597 → 输入框顶 581 → 条 541..573（中心 557）
//    ⇒ 条中心 AppKit y = 1117-557 = 560；条宽 150，第 4 档按钮中心 x = 550+4+17+3*36 = 679
click(CGPoint(x: 679, y: 560))
usleep(500_000)

// 6) 键入 Snapcut（保持编辑态，不落字；输入框实时预览 21pt）
typeText("Snapcut")
usleep(500_000)

// 7) 成图留证（编辑态截图：玻璃字号条 + 玻璃输入框 + 选中档蓝胶囊）
let cap = Process()
cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
cap.arguments = ["-x", "/tmp/e2e_textui_out.png"]
try? cap.run()
cap.waitUntilExit()
print("done: /tmp/e2e_textui_out.png（应有玻璃字号条 Aa12/14/17/21 + Aa21 蓝胶囊选中 + 玻璃输入框内 21pt Snapcut）")

// 8) Esc 取消文字，退出编辑态（不留标注，保持现场干净）
key(53)
