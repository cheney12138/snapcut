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
}
