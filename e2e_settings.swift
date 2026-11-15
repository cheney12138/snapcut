// e2e_settings.swift — 设置面板重设计（玻璃分组卡）三 tab 像素验证脚本
//
// 用法：先 `make dev` 构建，再（手动或由调用方）启动 build/Snapcut.app，
// 然后运行：swift e2e_settings.swift
// 流程：CGEvent 发 ⌥⌘,（打开设置热键，AppCoordinator 注册）→ 等窗口稳定 →
//       逐 tab（通用 → 快捷键 → 关于）点工具栏项 + 窗口级截图：
//       /tmp/e2e_settings_general.png /tmp/e2e_settings_hotkeys.png /tmp/e2e_settings_about.png
//
// 工具栏项定位：AX API（AXToolbar → AXButton）取真实位置；AX 不可用（未授权辅助
// 功能等）时回退到窗口居中估点（preference 样式三项居中，间距 ~66pt）。
// 坐标系：AX position 与 CGEvent 全局坐标同为左上原点 pt，直接换算。
// 鼠标事件一律 flags = []（不带修饰键），避免被热键/手势层截胡。
//
// 铁律：脚本只发事件 + 截屏，不 pkill、不 commit；验证产物 /tmp/e2e_settings_*.png

import AppKit
import CoreGraphics
import Foundation
import ApplicationServices

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

func click(_ p: CGPoint) {
    mouseMove(p); usleep(120_000)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                       mouseCursorPosition: p, mouseButton: .left)
    down?.flags = []
    post(down); usleep(60_000)
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                     mouseCursorPosition: p, mouseButton: .left)
    up?.flags = []
    post(up); usleep(60_000)
}

// MARK: - Snapcut 窗口定位（窗口级截图，避免桌面杂讯）

/// 取 Snapcut 前台窗口（layer 0，owner == "Snapcut"，标题含「设置」）
func snapcutSettingsWindowID() -> CGWindowID? {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let title = w[kCGWindowName as String] as? String ?? ""
        if owner == "Snapcut", layer == 0, title.contains("设置") {
            return w[kCGWindowNumber as String] as? CGWindowID
        }
    }
    return nil
}

func captureWindow(_ id: CGWindowID?, to path: String) {
    let cap = Process()
    cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    if let id {
        cap.arguments = ["-x", "-o", "-l\(id)", path]
    } else {
        // 兜底：窗口 ID 找不到就全屏（仍可人工目检）
        cap.arguments = ["-x", path]
    }
    try? cap.run()
    cap.waitUntilExit()
}

// MARK: - 工具栏项点击（AX 精确定位，回退估点）

func axToolbarButtonRects() -> [(CGPoint, CGSize)] {
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == "dev.snapcut.app" && $0.isActive
    }
    guard let app = apps.first else { return [] }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement], let win = windows.first
    else { return [] }

    var toolbarRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, kAXToolbarAttribute as CFString, &toolbarRef) == .success,
          let toolbar = toolbarRef
    else { return [] }

    var buttonsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(toolbar, kAXButtonsAttribute as CFString, &buttonsRef) == .success,
          let buttons = buttonsRef as? [AXUIElement]
    else { return [] }

    var rects: [(CGPoint, CGSize)] = []
    for b in buttons {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(b, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(b, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { continue }
        var pos = CGPoint.zero, size = CGSize.zero
        if AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
           AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) {
            rects.append((pos, size))
        }
    }
    return rects
}

/// 点击第 index 个工具栏 tab（0=通用 1=快捷键 2=关于）
func clickToolbarTab(_ index: Int) {
    let rects = axToolbarButtonRects()
    if rects.count == 3 {
        let (pos, size) = rects[index]
        click(CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2))
    } else {
        // 回退：preference 工具栏三项居中，单项 ~66pt，窗口 560pt 宽且居中
        let screenW = NSScreen.main?.frame.width ?? 1512
        let centerX = screenW / 2
        let topY = (NSScreen.main?.frame.height ?? 982) / 2 + 15   // 标题栏工具栏中心估算
        let offsets: [CGFloat] = [-66, 0, 66]
        click(CGPoint(x: centerX + offsets[index], y: topY))
    }
}

// MARK: - 主流程

let env = ProcessInfo.processInfo.environment
let launch = env["E2E_LAUNCH"] == "1"

if launch {
    let ws = NSWorkspace.shared
    if let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/build/Snapcut.app") {
        ws.launchApplication(at: url, configuration: [:]) { _ in }
        sleep(2)
    }
} else {
    sleep(1)
}

// 1) ⌥⌘, 打开设置（AppCoordinator 注册的全局热键）
hotkey(43, flags: [.maskCommand, .maskOption])   // 43 = kVK_ANSI_Comma
sleep(2)

// 2) 逐 tab 点击 + 截图
let shots: [(Int, String, String)] = [
    (0, "/tmp/e2e_settings_general.png", "通用"),
    (1, "/tmp/e2e_settings_hotkeys.png", "快捷键"),
    (2, "/tmp/e2e_settings_about.png",   "关于"),
]
for (index, path, name) in shots {
    clickToolbarTab(index)
    sleep(1)
    let winID = snapcutSettingsWindowID()
    captureWindow(winID, to: path)
    print("e2e_settings: \(name) → \(path) (windowID: \(winID.map(String.init) ?? "full-screen-fallback"))")
}

print("检查点：")
print("  1) 通用页：四张磨砂分组卡（截图/文件/历史/通知），圆角 12，左标签右控件，行高 36")
print("  2) 快捷键页：全局热键分组卡两行录制器，红字提示隐藏")
print("  3) 关于页：居中图标/名称/版本 + 权限状态磨砂卡（状态点/文案/去授权按钮）")
print("  4) 明暗模式各看一遍：卡描边暗色白 12% / 亮色黑 9%，分隔线随明暗自适应")
