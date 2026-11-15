// e2e_collage.swift — 拼贴画布窗口（C2）最小实机验证脚本
//
// 前置（由主会话串行执行，AGENTS.md 实机纪律）：
//   make dev   （构建通过；worktree 构建勿与常驻实例并行抢 ⌘⇧A）
//   终端/Snapcut 已有屏幕录制授权（screencapture -l 需要）
//
// 流程：优雅退出旧实例（坑 30：禁 kill -9）→ 带 --selftest-collage 启动
//       → 等 4s（AppCoordinator 自动开「Snapcut 拼贴」窗 + 种两块样例贴片）
//       → CGWindowList 定位「Snapcut 拼贴」窗口 → screencapture -l 截窗
//       → /tmp/e2e_collage_out.png
//
// 通过判据：脚本 exit 0 且截图里有深色画布 + 两块带分镜框的色块贴片
//         （蓝 #3395F2 与橙 #F29E2E，nextGridSlot 光栅排布、16pt 间隙）。
// 日志旁证：log show --predicate 'subsystem == "app.snapcut"' 里
//         evt=collage.open / collage.piece.added / collage.window.created。

import AppKit
import CoreGraphics

let bundleID = "app.snapcut.macos"
let binaryPath = "build/Snapcut.app/Contents/MacOS/Snapcut"
let outPath = "/tmp/e2e_collage_out.png"

// 1. 优雅退出旧实例（进程生命周期纪律：只许 osascript quit）
let quit = Process()
quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
quit.arguments = ["-e", "tell application id \"\(bundleID)\" to quit"]
try? quit.run()
quit.waitUntilExit()
sleep(1)

// 2. 带 selftest 钩子启动（AppCoordinator.scheduleSelfTestIfRequested 分支：
//    1.5s 后 openDocument(空文档) + addPiece × 2 样例贴片）
let run = Process()
run.executableURL = URL(fileURLWithPath: binaryPath)
run.arguments = ["--selftest-collage"]
do {
    try run.run()
} catch {
    print("FAIL: 启动失败 \(error)")
    exit(1)
}
sleep(4)

// 3. 定位「Snapcut 拼贴」窗口（CGWindowName 需屏幕录制授权，主会话已具备）
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] else {
    print("FAIL: CGWindowList 拿不到")
    exit(1)
}
let collageWindow = list.first { info in
    guard let owner = info[kCGWindowOwnerName as String] as? String, owner == "Snapcut",
          let title = info[kCGWindowName as String] as? String else { return false }
    return title.contains("拼贴")
}
guard let windowNumber = collageWindow?[kCGWindowNumber as String] as? Int else {
    print("FAIL: 「Snapcut 拼贴」窗口未找到；on-screen 窗口：")
    for info in list.prefix(10) {
        print("  owner=\(info[kCGWindowOwnerName as String] ?? "?") title=\(info[kCGWindowName as String] ?? "?")")
    }
    exit(1)
}

// 4. 截窗口
let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-o", "-l", "\(windowNumber)", outPath]
try capture.run()
capture.waitUntilExit()

guard FileManager.default.fileExists(atPath: outPath) else {
    print("FAIL: 截图未生成")
    exit(1)
}
print("OK: 拼贴窗口 \(windowNumber) 已截到 \(outPath)")
exit(0)
