// e2e_seq2.swift — 序号工具第二轮修复实机验证（textMatrix 乱序实锤 + 撤销派生序号）
//
// 前置（由主会话串行执行，AGENTS.md 实机纪律）：
//   make dev && make run   （build/Snapcut.app/Contents/MacOS/Snapcut 已在跑）
//   终端/Snapcut 已有屏幕录制 + 辅助功能（Accessibility）授权
//
// 流程：⌘⇧A 开选区 → 拖选 → 点序号工具 → 画布点 4 个点（序号 1,2,3,4）
//       → ⌘Z 撤销 2 次（剩 1,2）→ 再点 2 个点（派生序号应重新是 3,4）
//       → screencapture /tmp/e2e_seq2_out.png
//
// 【期望的最终数字序列】
//   画布上应可见 4 个序号徽章：先点的两个位置显示 1、2（未被撤销的两个），
//   ⌘Z×2 后新点的两个位置显示 3、4（nextSequenceNumber 派生：撤销后最大可见
//   序号 2 + 1 = 3，不跳号不撞号）。且每个数字必须画在自己的圆圈正中——
//   修复前 CTLineDraw 累加 context.textMatrix（tx += 行宽，gstate 恢复不了），
//   同帧画第 N 个文字标注时数字右漂 10.4pt×N，出现「圆里没数字/数字漂进
//   别的圆」的乱序假象；修复后 textMatrix 每次画字前置 identity。
//
// 坐标约定：脚本里一律给 AppKit 坐标（原点左下、Y 向上），发 CGEvent 时
// 换算 cgY = 1117 - appKitY（主屏 1117pt 高，与既有 e2e_* 脚本同约定）。
// 任务给的 CG 坐标：拖选 (400,367)→(1000,717)，序号按钮 (453,751)。
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

// MARK: - 流程

// 1) ⌘⇧A 开区域截图
key(0, [.maskCommand, .maskShift])
usleep(2_000_000)

// 2) 拖选：任务给 CG (400,367)→(1000,717) = AppKit (400,750)→(1000,400)
//    （选区 AppKit x 400-1000, y 400-750；工具栏出现在选区下缘 AppKit y≈366）
drag(CGPoint(x: 400, y: 750), CGPoint(x: 1000, y: 400))
usleep(1_000_000)

// 3) 点序号工具按钮（tag 5）：任务给 CG (453,751) = AppKit (453,366)
click(CGPoint(x: 453, y: 366))
usleep(500_000)

// 4) 画布点 4 个点：自上而下点击（视觉可核对序号方向），得序号 1,2,3,4
click(CGPoint(x: 520, y: 680))   // 序号 1
usleep(400_000)
click(CGPoint(x: 640, y: 620))   // 序号 2
usleep(400_000)
click(CGPoint(x: 760, y: 560))   // 序号 3
usleep(400_000)
click(CGPoint(x: 880, y: 500))   // 序号 4
usleep(600_000)

// 5) ⌘Z 撤销 2 次：撤掉序号 4、3 → 画布剩 1、2
key(6, [.maskCommand])
usleep(600_000)
key(6, [.maskCommand])
usleep(600_000)

// 6) 再点 2 个点：派生序号应为 3、4（撤销不跳号）
click(CGPoint(x: 580, y: 460))   // 应显示 3
usleep(400_000)
click(CGPoint(x: 900, y: 430))   // 应显示 4
usleep(800_000)

// 7) 成图留证
let cap = Process()
cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
cap.arguments = ["-x", "/tmp/e2e_seq2_out.png"]
try? cap.run()
cap.waitUntilExit()

// 8) 结果核对提示
print("done: /tmp/e2e_seq2_out.png")
print("期望：画布 6 个点位中可见 4 个徽章 = 1,2（520,680 / 640,620）+ 3,4（580,460 / 900,430，撤销后新点）")
print("判废：任何圆内无数字、数字漂进相邻圆、或新点跳号为 5,6")
print("日志核对：log show --info --last 2m --predicate 'subsystem==\"app.snapcut\" AND category==\"editor\"' | grep -E 'editor.mousedown|editor.undo|editor.draw'")
