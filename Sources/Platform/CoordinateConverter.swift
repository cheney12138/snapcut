import AppKit
import CoreGraphics

/// 坐标换算（docs/03 §5：换算收敛单点）
///
/// AppKit 全局坐标（原点在主屏左下，Y 向上）→ 截图图像像素坐标（原点在图像左上，Y 向下）。
enum CoordinateConverter {
    /// 选区（全局 point）→ 目标屏幕本地像素矩形，供 CGImage.cropping(to:) 使用
    static func pixelRect(selection: CGRect, onScreen screen: NSScreen) -> CGRect {
        let scale = screen.backingScaleFactor
        let frame = screen.frame
        let x = (selection.minX - frame.minX) * scale
        let y = (frame.maxY - selection.maxY) * scale
        let width = selection.width * scale
        let height = selection.height * scale
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 屏幕本地像素尺寸
    static func pixelSize(of screen: NSScreen) -> CGSize {
        CGSize(width: screen.frame.width * screen.backingScaleFactor,
               height: screen.frame.height * screen.backingScaleFactor)
    }
}
