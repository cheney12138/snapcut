import CoreGraphics

/// 纯值类型颜色（领域层不依赖 AppKit 的 NSColor）
///
/// 为什么不用 NSColor：NSColor 属于 AppKit 表现层，一旦进 Core，
/// 领域模型就被绑死在 UI 框架上（六边形铁律：Core 只允许 Foundation/CoreGraphics）。
/// 渲染时由 UI 适配器转成 NSColor/CGColor。
public struct RGBAColor: Equatable, Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public func withAlpha(_ alpha: CGFloat) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    // 标注调色板（0 红 1 蓝 2 黄 3 黑 4 白）
    public static let red = RGBAColor(red: 1.0, green: 0.23, blue: 0.19)
    public static let blue = RGBAColor(red: 0.0, green: 0.48, blue: 1.0)
    public static let yellow = RGBAColor(red: 1.0, green: 0.84, blue: 0.0)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
}
