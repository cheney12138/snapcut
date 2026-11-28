import AppKit

/// 贴图窗口：无边框、floating 层级、透明背景自绘圆角。
/// LSUIElement App 无 Dock 图标，窗口必须显式 canBecomeKey（Esc 依赖 key 态）。
/// 覆写 constrainFrameRect 解除系统对窗口高度与菜单栏顶缘的强制夹取：长图放大到原生像素
/// （超过屏高）时窗口严格按光标锚点等比缩放、绝不被系统压扁拉伸或顶出锚点。
@MainActor
final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    /// 贴图窗级快捷键兜底（⌘C / ⌘A / T / Esc）。
    ///
    /// 病例：LSUIElement 无主菜单栏 App 里，一旦实况文本的 `ImageAnalysisOverlayView`
    /// 拿到焦点，⌘C / ⌘A 会沿响应链去找 App 主菜单的 Edit 菜单项（不存在 ⇒ 无反应），
    /// 而 Esc 又会被系统当作 cancel 手势先吃掉（误关窗口）。窗口级
    /// performKeyEquivalent 是唯一能稳定先于焦点链拿到这些组合键的地方。
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
