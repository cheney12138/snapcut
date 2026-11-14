import AppKit
import CoreGraphics

/// 坐标换算（docs/03 §5：换算收敛单点）
///
/// ⚠️ 病例（2026-11-14，BetterDisplay/虚拟分辨率场景）：SCK 返回的整屏图尺寸
/// 与 NSScreen 物理像素（backingScale × frame）**不保证相等**——实测 1920×1080
/// 对 3456×2234 的屏。因此换算**不假设 scale**，一律用「实际图尺寸 ÷ 屏幕 point
/// 尺寸」的实测比例做裁剪，任何分辨率/缩放模式下都正确。
enum CoordinateConverter {
    /// 选区（全局 point）→ 目标屏幕本地像素矩形，按实际捕获图比例换算
    static func pixelRect(selection: CGRect, onScreen screen: NSScreen, imageWidth: Int, imageHeight: Int) -> CGRect {
        let frame = screen.frame
        // 实测像素/point 比例（x/y 独立，防非等比缩放）
        let scaleX = CGFloat(imageWidth) / frame.width
        let scaleY = CGFloat(imageHeight) / frame.height
        let x = (selection.minX - frame.minX) * scaleX
        let y = (frame.maxY - selection.maxY) * scaleY
        let width = selection.width * scaleX
        let height = selection.height * scaleY
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 兼容旧接口（假设物理像素 = frame × backingScale；仅用于无捕获图上下文）
    static func pixelRect(selection: CGRect, onScreen screen: NSScreen) -> CGRect {
        let scale = screen.backingScaleFactor
        let frame = screen.frame
        return CGRect(
            x: (selection.minX - frame.minX) * scale,
            y: (frame.maxY - selection.maxY) * scale,
            width: selection.width * scale,
            height: selection.height * scale
        )
    }

    /// 屏幕本地像素尺寸（假设物理像素 = frame × backingScale）
    static func pixelSize(of screen: NSScreen) -> CGSize {
        CGSize(width: screen.frame.width * screen.backingScaleFactor,
               height: screen.frame.height * screen.backingScaleFactor)
    }
}
