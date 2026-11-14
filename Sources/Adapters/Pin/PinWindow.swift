import AppKit

/// 贴图窗口：无边框、floating 层级、透明背景自绘圆角。
/// LSUIElement App 无 Dock 图标，窗口必须显式 canBecomeKey（Esc 依赖 key 态）。
@MainActor
final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
