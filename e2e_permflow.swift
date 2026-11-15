// e2e_permflow.swift — 权限引导流实机验证：⌘⇧A → TCC 确认框弹出 → 贴身浮窗不抢跑
//
// 用法：先 `make dev` 构建，再（手动或 E2E_LAUNCH=1）启动 build/Snapcut.app，
// 然后运行：swift e2e_permflow.swift
// 前提：本机屏幕录制权限**未授予**（ad-hoc 重签后 TCC 即重置，见 docs/03 §9）；
//       若系统设置主窗（≥500×320）已开着，浮窗贴上去属合法行为 → 结果记 INCONCLUSIVE。
//
// 验证原理（对应 PermissionDragOverlay.settingsWindowFrame 的修复）：
//   1. ⌘⇧A 触发截图路径 → SCK（SCShareableContent）未授权 → 系统弹 TCC 确认框
//      （「'Snapcut' 想要录制此电脑的屏幕和音频」）；引导卡可见时再 AX 点「去授权」
//      → requestSystemPrompt → dragOverlay.show（浮窗待命，tick 开始找目标窗）。
//   2. 断言：观察期内日志**不得出现** evt=dragOverlay.match hit=settings——
//      这是浮窗 orderFront 的唯一通路；TCC 确认框在屏期间浮窗必须保持隐藏。
//      修好的匹配只认「系统设置进程 + layer0 + 主窗尺寸（≥500×320）+ 标题含设置」，
//      TCC 确认框会被 dialogSuspect/titleMismatch 拒掉——打点同时记录被拒窗的
//      owner/title，即 Bug 1 误匹配根因的实机取证。
//   3. 全程截屏 /tmp/e2e_permflow_out.png 供人工目检（TCC 框右下角应无浮窗）。
//
// 纪律（AGENTS.md）：脚本只发事件 + 截屏 + 读日志，不 pkill、不 commit；
// 键盘事件 keyUp / 鼠标事件 flags=[]（防修饰键卡死误触全局热键）。
// GUI e2e 由主会话串行执行。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 常量

let bundleID = "app.snapcut.macos"
let keyA: CGKeyCode = 0x00       // kVK_ANSI_A
let keyEsc: CGKeyCode = 0x35     // kVK_ANSI_Escape
let screenWidthPt = NSScreen.main?.frame.width ?? 1512
let screenHeightPt = NSScreen.main?.frame.height ?? 982
let screenHeightPx = screenHeightPt * (NSScreen.main?.backingScaleFactor ?? 2)

// 观察窗口
let tccDialogWaitSec: UInt32 = 8      // 等 TCC 确认框出现
let overlayObserveSec: UInt32 = 4     // show() 后观察浮窗是否抢跑

// MARK: - 事件原语（鼠标/keyup 一律 flags=[]）

func post(_ e: CGEvent?) {
    guard let e else { fatalError("CGEvent 创建失败") }
    e.flags = []
    e.post(tap: .cghidEventTap)
}

func hotkey(_ keyCode: CGKeyCode) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    down?.flags = [.maskCommand, .maskShift]
    let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    up?.flags = []   // keyUp 不带修饰键 flags，避免修饰键「卡住」误触后续热键
    post2(down); usleep(80_000); post2(up)
    // 显式释放 ⌘/⇧（flagsChanged，flags 空）
    for code in [CGKeyCode(55), CGKeyCode(56)] {
        let f = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        f?.type = .flagsChanged
        f?.flags = []
        f?.post(tap: .cghidEventTap)
    }
}

/// 保留调用方 flags 的事件投递（hotkey 的 keyDown 需要）
func post2(_ e: CGEvent?) {
    guard let e else { fatalError("CGEvent 创建失败") }
    e.post(tap: .cghidEventTap)
}

func tapKey(_ keyCode: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    post(down); usleep(60_000); post(up)
}

// MARK: - 日志收集（log stream → 内存缓冲）

final class LogTailer {
    private let proc = Process()
    private let q = DispatchQueue(label: "e2e.logtailer")
    private var buffer = ""

    func start() {
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream", "--style", "compact", "--level", "info",
            "--predicate",
            "subsystem == \"app.snapcut\" AND (category == \"permission\" OR category == \"app\")",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self?.q.async { self?.buffer += s }
        }
        do { try proc.run() } catch { fputs("e2e: log stream 启动失败：\(error)\n", stderr) }
    }

    func snapshot() -> String { q.sync { buffer } }
    func stop() { if proc.isRunning { proc.terminate() } }
}

// MARK: - 窗口侦察（CGWindowList，根因取证：TCC 框的真实 owner/title/尺寸）

func onScreenWindows() -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter {
        ($0[kCGWindowLayer as String] as? Int) == 0
            && (($0[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01
    }
}

func windowDesc(_ w: [String: Any]) -> String {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
    let title = w[kCGWindowName as String] as? String ?? "(无标题/被裁剪)"
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
    let wd = b["Width"] as? Double ?? 0, ht = b["Height"] as? Double ?? 0
    return "owner=\(owner)(pid \(pid)) title=\(title) frame=\(Int(x)),\(Int(y)) \(Int(wd))×\(Int(ht))"
}

struct DialogHit {
    let owner: String
    let title: String
    let frame: String
    let ownerPID: Int32
}

/// 找 TCC 确认框：非本 App 的 layer0 小窗（300–700 × 100–350pt 量级）
func findTCCDialog(excludePID: Int32) -> DialogHit? {
    for w in onScreenWindows() {
        guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != excludePID,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let wd = b["Width"] as? Double, let ht = b["Height"] as? Double,
              (300...700).contains(wd), (100...350).contains(ht)
        else { continue }
        return DialogHit(
            owner: w[kCGWindowOwnerName as String] as? String ?? "?",
            title: w[kCGWindowName as String] as? String ?? "(裁剪)",
            frame: String(describing: b),
            ownerPID: pid
        )
    }
    return nil
}

/// 前置条件检查：系统设置主窗（≥500×320，修好的匹配门槛）是否已在屏
func settingsMainWindowOnScreen(settingsPID: Int32) -> [String: Any]? {
    onScreenWindows().first { w in
        guard (w[kCGWindowOwnerPID as String] as? Int32) == settingsPID else { return false }
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let wd = b["Width"] as? Double, let ht = b["Height"] as? Double
        else { return false }
        return wd >= 500 && ht >= 320
    }
}

// MARK: - AX 点「去授权」（引导卡未完成时首启自动弹出）

func pressAuthorizeButton() -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    else { return false }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return false }
    for win in windows {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { continue }
        for el in children {
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
                  (roleRef as? String) == "AXButton" else { continue }
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
            if (titleRef as? String) == "去授权" {
                return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
            }
        }
    }
    return false
}

// MARK: - 截屏

func screencapture(_ path: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", path]
    try? p.run()
    p.waitUntilExit()
}

// MARK: - 主流程

let env = ProcessInfo.processInfo.environment
let selfPID = ProcessInfo.processInfo.processIdentifier

guard let snapcut = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    if env["E2E_LAUNCH"] == "1" {
        let ws = NSWorkspace.shared
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/build/Snapcut.app")
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        sleep(3)
    }
    guard let again = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        print("e2e: ✗ Snapcut 未运行（make dev 后手动启动，或 E2E_LAUNCH=1）"); exit(2)
    }
    _ = again
}
let snapcutPID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first!.processIdentifier

// 前置：权限必须未授予（否则整条路径不触发）
let granted = CGPreflightScreenCaptureAccess()
print("e2e: 本机屏幕录制预检 granted=\(granted)")
if granted {
    print("e2e: ⚠️ INCONCLUSIVE —— 权限已授予，TCC 确认框不会弹出。请用重签后的构建（TCC 已重置）重跑。")
    exit(3)
}

// 前提检查：系统设置主窗已开 → 浮窗贴上去属合法，结果只能算存疑
let settingsSettingsApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
if let sa = settingsSettingsApp, let win = settingsMainWindowOnScreen(settingsPID: sa.processIdentifier) {
    print("e2e: ⚠️ INCONCLUSIVE —— 系统设置主窗已在屏，浮窗贴角属设计行为：")
    print("      \(windowDesc(win))")
    exit(3)
}
if settingsSettingsApp != nil {
    print("e2e: 注意：系统设置进程在跑但没有 ≥500×320 的在屏主窗（后台驻留，不影响判定）")
}

let tailer = LogTailer()
tailer.start()
usleep(500_000)

// 1) ⌘⇧A → SCK 未授权 → 系统 TCC 确认框
print("e2e: 发送 ⌘⇧A …")
hotkey(keyA)

// 2) 等 TCC 确认框出现（轮询 8s，顺带取证 owner/title/尺寸）
var dialog: DialogHit?
for _ in 0..<16 {
    usleep(500_000)
    if let d = findTCCDialog(excludePID: snapcutPID) { dialog = d; break }
}
if let d = dialog {
    print("e2e: TCC 确认框已出现（根因取证）：")
    print("      owner=\(d.owner) pid=\(d.ownerPID) title=\(d.title) bounds=\(d.frame)")
} else {
    print("e2e: ⚠️ 8s 内未观察到 TCC 确认框小窗——可能系统弹窗形态不同，以截图与日志为准")
}

// 3) 引导卡可见时点「去授权」→ requestSystemPrompt → dragOverlay.show（浮窗待命）
let pressed = pressAuthorizeButton()
print("e2e: 「去授权」按钮 \(pressed ? "已点（requestSystemPrompt → dragOverlay.show）" : "未找到（引导卡不在屏，跳过 request 路径）")")
sleep(overlayObserveSec)

// 4) 截屏（人工目检：TCC 框在屏时右下角应无浮窗）
screencapture("/tmp/e2e_permflow_out.png")

// 5) Esc 收尾（取消可能残留的截图 overlay 会话 / 允许用户自己处理 TCC 框）
tapKey(keyEsc)
usleep(300_000)

// 6) 日志断言
let log = tailer.snapshot()
tailer.stop()

let matchLines = log.split(separator: "\n").filter { $0.contains("evt=dragOverlay.match") }
let showLines = log.split(separator: "\n").filter { $0.contains("evt=dragOverlay.show") }
let hitLines = matchLines.filter { $0.contains("hit=settings") }

print("")
print("========== dragOverlay 打点（逐条） ==========")
for l in showLines { print("  \(l)") }
for l in matchLines { print("  \(l)") }
if matchLines.isEmpty { print("  （无 dragOverlay.match 打点——request 路径未触发或日志延迟）") }
print("")

print("========== 判定 ==========")
if dialog == nil {
    print("e2e: ⚠️ TCC 确认框未捕获，判定降级——请人工核对 /tmp/e2e_permflow_out.png 与上方日志")
}
if !hitLines.isEmpty {
    print("e2e: ✗ FAIL —— TCC 框在屏期间出现 hit=settings：浮窗会贴上去（bug 复现）")
    for l in hitLines { print("  \(l)") }
    exit(1)
}
if !showLines.isEmpty {
    print("e2e: ✓ PASS —— dragOverlay.show 已触发，观察期内无 hit=settings：TCC 框出现时浮窗保持隐藏")
    print("      被拒窗（dialogSuspect/titleMismatch）的 owner/title 见上方逐条打点，即 Bug 1 根因取证")
} else if pressed {
    print("e2e: ⚠️ 「去授权」已点但未见 dragOverlay.show——检查 App 日志（onboarding.permissionTap）")
    exit(1)
} else {
    print("e2e: ✓ PASS（弱判定）—— ⌘⇧A 路径无 hit=settings；request 路径未覆盖（引导卡不在屏），")
    print("      需在首启（onboarding.completed=false）机器上补跑以覆盖 dragOverlay.show 分支")
}
print("产物：/tmp/e2e_permflow_out.png（全屏截图）")
print("日志核对：log show --info --last 3m --predicate 'subsystem==\"app.snapcut\" AND category==\"permission\"' | grep dragOverlay")
