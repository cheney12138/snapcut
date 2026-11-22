import AppKit

/// 显示器信息（v0.1 极简版：按需查询，v0.5+ 再做缓存与变更监听）
enum DisplayRegistry {
    /// 通过 CGDirectDisplayID 找 NSScreen
    @MainActor
    static func screen(forDisplayID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
    }

    /// NSScreen → CGDirectDisplayID
    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 鼠标指针当前所在的显示器（多屏场景统一按光标所在屏唤起浮窗/面板）
    @MainActor
    static func screenAtMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// 将指定尺寸的窗口居中在目标屏幕（默认光标所在屏）的可见区域内
    @MainActor
    static func centerOrigin(for size: NSSize, on screen: NSScreen? = nil) -> CGPoint {
        let target = screen ?? screenAtMouse()
        guard let visible = target?.visibleFrame else { return CGPoint(x: 200, y: 200) }
        return CGPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        )
    }
}
