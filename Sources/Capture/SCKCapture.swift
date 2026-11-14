import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case noScreen
    case cropFailed
    case denied

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "SCShareableContent 中找不到目标显示器"
        case .noScreen: return "无法解析目标 NSScreen"
        case .cropFailed: return "选区裁剪失败（坐标越界？）"
        case .denied: return "屏幕录制权限被拒绝"
        }
    }
}

/// ScreenCaptureKit 截图封装（docs/03 §5）
///
/// 静态截图用 SCScreenshotManager（macOS 14+），整显示器 filter → 返回整屏 CGImage，
/// 区域裁剪在 CaptureService 中完成（先整屏后裁剪，避免 SCK 按子区域 filter 的坐标陷阱）。
actor SCKCapture {
    static let shared = SCKCapture()

    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return image
    }
}

/// 截图服务：区域截图（整屏捕获 + 像素裁剪）
@MainActor
enum CaptureService {
    /// 在指定屏幕上截取全局 point 选区
    static func captureRegion(_ selection: CGRect, on screen: NSScreen) async throws -> CGImage {
        guard let displayID = DisplayRegistry.displayID(of: screen) else {
            throw CaptureError.noScreen
        }
        let start = DispatchTime.now()
        do {
            let full = try await SCKCapture.shared.captureDisplay(displayID: displayID)
            let elapsedMs = Int(
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            )
            let pxRect = CoordinateConverter.pixelRect(selection: selection, onScreen: screen)
            guard let cropped = full.cropping(to: pxRect), cropped.width > 0, cropped.height > 0 else {
                throw CaptureError.cropFailed
            }
            let scale = screen.backingScaleFactor
            Log.event(.capture, "capture.display.ok", [
                "ms": "\(elapsedMs)",
                "pxW": "\(cropped.width)",
                "pxH": "\(cropped.height)",
                "scale": "\(scale)",
                "displayId": "\(displayID)",
                "rectPx": "\(Int(pxRect.minX)),\(Int(pxRect.minY)),\(Int(pxRect.width)),\(Int(pxRect.height))",
            ])
            return cropped
        } catch let error as CaptureError {
            Log.error(.capture, "capture.fail", ["err": "\(error.localizedDescription)"])
            throw error
        } catch {
            // SCK 抛错最常见原因是权限未授予
            let granted = CGPreflightScreenCaptureAccess()
            Log.error(.capture, granted ? "capture.fail" : "capture.denied", [
                "err": "\(error.localizedDescription)",
            ])
            if !granted { throw CaptureError.denied }
            throw error
        }
    }
}
