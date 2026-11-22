import AppKit

/// 贴图窗口：无边框、floating 层级、透明背景自绘圆角。
/// LSUIElement App 无 Dock 图标，窗口必须显式 canBecomeKey（Esc 依赖 key 态）。
/// 覆写 constrainFrameRect 解除系统对窗口高度与菜单栏顶缘的强制夹取：长图放大到原生像素
/// （超过屏高）时窗口严格按光标锚点等比缩放、绝不被系统压扁拉伸或顶出锚点。
@MainActor
final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
