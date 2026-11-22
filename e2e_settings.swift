// e2e_settings.swift — 设置面板重设计 v2（晶透玻璃 + 自定义段选器四 tab）像素验证脚本
//
// 用法：先 `make dev` 构建，再（手动或由调用方）启动 build/Snapcut.app，
// 然后运行：swift e2e_settings.swift
// 流程：CGEvent 发 ⌥⌘,（打开设置热键，AppCoordinator 注册）→ 等窗口稳定 →
//       逐 tab（通用 → 工具栏 → 快捷键 → 关于）点击段选器按钮 + 窗口级截图：
//       /tmp/e2e_settings_general.png /tmp/e2e_settings_toolbar.png
//       /tmp/e2e_settings_hotkeys.png /tmp/e2e_settings_about.png
//
// tab 定位：AX API 在窗口树里找 AXTitle ∈ {通用,工具栏,快捷键,关于} 的 AXButton
// （v2 起 tab 是自绘 GlassSegmentedControl 内的普通 NSButton，不再是 NSToolbar 项）；
// AX 不可用时回退窗口居中估点（四段等宽，段选器居中于窗顶 ~34pt 处）。
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
func snapcutSettingsWindow() -> (id: CGWindowID, bounds: CGRect)? {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let title = w[kCGWindowName as String] as? String ?? ""
        if owner == "Snapcut", layer == 0, title.contains("设置") {
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let rect = CGRect(
                x: b["X"] ?? 0, y: b["Y"] ?? 0,
                width: b["Width"] ?? 560, height: b["Height"] ?? 640
            )
            if let id = w[kCGWindowNumber as String] as? CGWindowID {
                return (id, rect)
            }
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
        cap.arguments = ["-x", path]   // 兜底全屏（仍可人工目检）
    }
    try? cap.run()
    cap.waitUntilExit()
}

// MARK: - tab 按钮定位（AX 递归找标题匹配的普通按钮；v2 段选器 = 窗口树里的 NSButton）

func axFindTabButton(titled title: String) -> CGPoint? {
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == "app.snapcut.snapcut" && $0.isActive
    }
    guard let app = apps.first else { return nil }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement], let win = windows.first
    else { return nil }

    func walk(_ el: AXUIElement, depth: Int) -> CGPoint? {
        guard depth < 12 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if role == kAXButtonRole as String {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
            if (titleRef as? String) == title {
                var posRef: CFTypeRef?, sizeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
                      AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success
                else { return nil }
                var pos = CGPoint.zero, size = CGSize.zero
                if AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
                   AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) {
                    return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                }
                return nil
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }
        for child in children {
            if let found = walk(child, depth: depth + 1) { return found }
        }
        return nil
    }
    return walk(win, depth: 0)
}

/// 点击指定标题的 tab（AX 精确定位——左栏 GlassTabRail 的按钮带 accessibilityTitle；
/// 失败回退左栏估点：rail 宽 196，四项高 34 从顶部 52+标题28+20 起排）
func clickTab(titled title: String, index: Int) {
    if let center = axFindTabButton(titled: title) {
        click(center)
        return
    }
    if let win = snapcutSettingsWindow() {
        // 左栏按钮：x ≈ win.minX + 12 + 85（rail 12 + 按钮半宽），y ≈ win.minY + 100 + index×38
        let x = win.bounds.minX + 97
        let y = win.bounds.minY + 100 + CGFloat(index) * 38
        click(CGPoint(x: x, y: y))
    }
}

// MARK: - 主流程

let env = ProcessInfo.processInfo.environment
let launch = env["E2E_LAUNCH"] == "1"

if launch {
    let ws = NSWorkspace.shared
    let appURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/build/Snapcut.app")
    try? ws.launchApplication(at: appURL, options: [], configuration: [:])
    sleep(2)
} else {
    sleep(1)
}

// 1) ⌥⌘, 打开设置（AppCoordinator 注册的全局热键）
hotkey(43, flags: [.maskCommand, .maskAlternate])   // 43 = kVK_ANSI_Comma
sleep(2)

// 2) 逐 tab 点击 + 截图（通用页打开即默认，仍点一遍确认选中胶囊滑移无残影）
let shots: [(Int, String, String)] = [
    (0, "/tmp/e2e_settings_general.png", "通用"),
    (1, "/tmp/e2e_settings_toolbar.png", "工具栏"),
    (2, "/tmp/e2e_settings_hotkeys.png", "快捷键"),
    (3, "/tmp/e2e_settings_about.png",   "关于"),
]
for (index, path, name) in shots {
    clickTab(titled: name, index: index)
    sleep(1)
    let win = snapcutSettingsWindow()
    captureWindow(win?.id, to: path)
    print("e2e_settings: \(name) → \(path) (windowID: \(win.map { String($0.id) } ?? "full-screen-fallback"))")
}

print("检查点：")
print("  1) 通用页：左侧栏（标题「设置」+ 竖向 tab 蓝胶囊选中）+ 四张晶透玻璃卡，行内控件右缘对齐")
print("  2) 工具栏页：外观卡段选器（选中胶囊弹簧滑移）+ 排序卡 chevron 玻璃图标按钮")
print("  3) 快捷键页：全局 3 行 + 视觉记忆 4 行 + 编辑器双列网格 5 行；录制器 hover 提亮")
print("  4) 关于页：图标/名称/版本居中 + 权限状态晶透卡（状态点+文案+按钮整体居中）")
print("  5) 四 tab 切换：窗口高度随内容收放，侧栏选中胶囊竖向滑动无残影")
print("  6) 截图热键按下时：设置窗被拍进冻结图（可直接框选截设置面板本身），结束后回场")
