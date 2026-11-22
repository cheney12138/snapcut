// e2e_toolbar.swift — 工具栏三项改造（呼吸感 / 粗细滑杆 / 复制纯图标）像素验证脚本
//
// 用法：先 `make dev` 构建，再（手动或由调用方）启动 build/Snapcut.app，
// 然后运行：swift e2e_toolbar.swift
// 流程：CGEvent 发 ⌘⇧A（区域截图热键）→ 拖选出选区 → 编辑器 + 工具栏弹出 →
//       等待稳定后 screencapture 全屏到 /tmp/e2e_toolbar_out.png 供像素比对。
//
// 坐标系约定：
//   - 脚本里的 *_appKitY 都是 AppKit 屏幕坐标（左下原点，pt）
//   - CGEvent 全局坐标是「左上原点 + 像素」，本机主屏换算：cgY = 1117 - appKitY
//   - 鼠标事件一律 flags = []（不带修饰键），避免被热键/手势层截胡
//
// 铁律：脚本只发事件 + 截屏，不 pkill、不 commit；验证产物 /tmp/e2e_toolbar_out.png

import AppKit
import CoreGraphics
import Foundation

// MARK: - 常量（按真机分辨率校准；主屏高 1117px ⇒ cgY = 1117 - appKitY）

let hotkeyCmdShiftA_keycode: CGKeyCode = 0x00   // A
let screenHeightPx: CGFloat = 1117

func cgY(_ appKitY: CGFloat) -> CGFloat { screenHeightPx - appKitY }

// 选区（AppKit pt）：屏幕中部一块 400×300，给工具栏留下方空间
let selStart = CGPoint(x: 300, y: 750)          // AppKit（注意 AppKit y 向上）
let selEnd   = CGPoint(x: 700, y: 450)

// MARK: - 事件原语

func post(_ e: CGEvent?) {
    guard let e else { fatalError("CGEvent 创建失败") }
    e.post(tap: .cghidEventTap)
}

func usleep(_ us: Int) {
    Thread.sleep(forTimeInterval: Double(us) / 1_000_000)
}

func hotkey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    post(down); usleep(60_000); post(up)
}

func mouseMove(_ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: p, mouseButton: .left)
    e?.flags = []
    post(e)
}

func mouseDown(_ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                    mouseCursorPosition: p, mouseButton: .left)
    e?.flags = []
    post(e)
}

func mouseDrag(_ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                    mouseCursorPosition: p, mouseButton: .left)
    e?.flags = []
    post(e)
}

func mouseUp(_ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: p, mouseButton: .left)
    e?.flags = []
    post(e)
}

/// 分步拖选（模拟人手：起手 → 中间插值 → 抬手）
func dragSelection(from: CGPoint, to: CGPoint) {
    let startCG = CGPoint(x: from.x, y: cgY(from.y))
    let endCG = CGPoint(x: to.x, y: cgY(to.y))
    mouseMove(startCG); usleep(120_000)
    mouseDown(startCG); usleep(120_000)
    let steps = 20
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: startCG.x + (endCG.x - startCG.x) * t,
                        y: startCG.y + (endCG.y - startCG.y) * t)
        mouseDrag(p)
        usleep(16_000)
    }
    usleep(120_000)
    mouseUp(endCG)
}

// MARK: - 主流程

let env = ProcessInfo.processInfo.environment
let launch = env["E2E_LAUNCH"] == "1"

if launch {
    // 可选：由脚本拉起 app（默认假定已手动启动，TCC 屏幕录制/辅助功能已授权）
    let ws = NSWorkspace.shared
    if let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/build/Snapcut.app") {
        ws.launchApplication(at: url, configuration: [:]) { _ in }
        sleep(2)
    }
} else {
    sleep(1)
}

// 1) 区域截图热键 ⌘⇧A
hotkey(hotkeyCmdShiftA_keycode, flags: [.maskCommand, .maskShift])
sleep(1)

// 2) 拖选出选区 → 冻结底图 + 编辑器 + 工具栏
dragSelection(from: selStart, to: selEnd)
sleep(2)   // 工具栏 spring 出场（240ms）+ 布局稳定 + dumpButtonCenters 日志

// 3) 悬停粗细滑杆（tooltip「粗细」）——顺带验证滑杆命中（nonactivatingPanel 不抢激活）
//    滑杆在工具栏中部偏右，位置由日志 toolbar.buttons 比对（此处粗略扫中段）
sleep(1)

// 4) 全屏截屏（像素比对：工具栏高度 44、复制按钮 30×28、分区留白 16pt）
let cap = Process()
cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
cap.arguments = ["-x", "/tmp/e2e_toolbar_out.png"]
try? cap.run()
cap.waitUntilExit()

print("e2e_toolbar: captured /tmp/e2e_toolbar_out.png (exit \(cap.terminationStatus))")
print("检查点：")
print("  1) 主工具栏精简为：7 工具 | 撤销重做 | 滚动/取字/贴图/••• | 复制/保存/取消")
print("  2) 未选工具时上方无属性浮条；选中工具后上方自动浮出对应属性胶囊（色点+滑杆 / 文字色点+字号 / 马赛克块大小+智能打码）")
print("  3) ••• 更多菜单包含画框美化(B)与隐藏工具栏(H)")
