import AppKit
import CoreGraphics

/// 屏幕上某个点命中的窗口（用于悬停高亮 / 单击整窗截图）
struct HoveredWindow: Equatable {
    let windowID: CGWindowID
    /// AppKit 全局坐标（Y 向上，原点=主屏左下）
    let rectGlobal: CGRect
    let ownerName: String
    let title: String
}

/// 窗口枚举与坐标换算（F2 窗口截图）
///
/// 坐标系陷阱（病例：这块最容易错，务必按下面写）：
/// - `CGWindowListCopyWindowInfo` 的 bounds 是 **CG 全局坐标**：原点在主屏**左上**，Y 向下
/// - AppKit 全局坐标：原点在主屏**左下**，Y 向上
/// - 换算：`appKitY = mainScreenHeight - (cgY + cgH)`
/// - 主屏高度取 `NSScreen.screens.first`（菜单栏所在屏），多屏负坐标同样成立
enum WindowLocator {
    /// 排除自身与系统装饰窗口后，取点下最顶层的普通窗口
    static func window(atGlobalPoint point: CGPoint, excludingPID pid: pid_t) -> HoveredWindow? {
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainHeight = mainScreen.frame.height
        // 点 → CG 坐标（Y 下）用于命中判断
        let cgPoint = CGPoint(x: point.x, y: mainHeight - point.y)

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != pid else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            // 太小的条状窗口（分隔线、贴边把手）不算目标
            guard cgRect.width >= 40, cgRect.height >= 40 else { continue }
            guard cgRect.contains(cgPoint) else { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { continue }

            let appKitRect = CGRect(
                x: cgRect.minX,
                y: mainHeight - cgRect.maxY,
                width: cgRect.width,
                height: cgRect.height
            )
            return HoveredWindow(
                windowID: info[kCGWindowNumber as String] as? CGWindowID ?? 0,
                rectGlobal: appKitRect,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? ""
            )
        }
        return nil
    }
}
