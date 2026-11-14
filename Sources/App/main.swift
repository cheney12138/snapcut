import AppKit

// LSUIElement 应用：手工装配 NSApplication（无 SwiftUI App 生命周期）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
