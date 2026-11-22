import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: LocalizedError, Equatable {
    case displayNotFound
    case noScreen
    case cropFailed
    case denied
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "SCShareableContent 中找不到目标显示器"
        case .noScreen: return "无法解析目标 NSScreen"
        case .cropFailed: return "选区裁剪失败（坐标越界？）"
        case .denied: return "屏幕录制权限被拒绝"
        case .windowNotFound: return "SCShareableContent 中找不到目标窗口"
        }
    }
}

/// ScreenCaptureKit 截图封装（docs/03 §5）
///
/// 静态截图用 SCScreenshotManager（macOS 14+），整显示器 filter → 返回整屏 CGImage，
/// 区域裁剪在 CaptureService 中完成（先整屏后裁剪，避免 SCK 按子区域 filter 的坐标陷阱）。
actor SCKCapture {
    static let shared = SCKCapture()

    /// 启动后静默预热 SCShareableContent + SCScreenshotManager 首帧 GPU/Metal 管线：
    /// 拍一张 64×64 微缩帧即可提前完成 WindowServer 握手与着色器编译，把重启后首次 F1 从 ~1s 压到 ~35ms
    func warmup() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 64
        config.height = 64
        config.showsCursor = false
        config.captureResolution = .nominal
        _ = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // ⚠️ 默认 .nominal 会返回降采样图（逻辑分辨率），坐标按物理像素裁剪就会越界
        // （病例：屏幕下方选区 pxH=80 而非 500）。.exact = 显示器原生像素。
        config.captureResolution = .best
        // ⚠️ SCStreamConfiguration 默认输出 1920×1080（宽高以像素计，头文件实锤）——
        // 这就是「截图变模糊」的根因。CGDisplayPixelsWide 在缩放模式下返回的是
        // 当前模式像素（1728）而非面板物理像素（3456）——必须用 frame × backingScale。
        let physical = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
        config.width = Int((physical?.frame.width ?? 1728) * (physical?.backingScaleFactor ?? 2))
        config.height = Int((physical?.frame.height ?? 1117) * (physical?.backingScaleFactor ?? 2))
        config.showsCursor = false
        config.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return image
    }

    /// 单窗口捕获（SCK 桌面独立窗口滤镜）
    ///
    /// 为什么要单窗口而不是「整屏裁剪」：整屏裁剪只能拿到**当前可见像素**，
    /// 窗口被别的窗口遮住时会截到遮挡物（病例）。SCK 的 desktopIndependentWindow
    /// 滤镜拿到的是该窗口自己的内容，且 ignoreShadows 去掉系统阴影/圆角外残留。
    func captureWindow(windowID: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // 忽略阴影后内容尺寸 = 窗口 frame；按屏幕实测缩放比放大到物理像素
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        Log.event(.capture, "capture.window.ok", [
            "pxW": "\(image.width)", "pxH": "\(image.height)",
            "windowId": "\(windowID)",
        ])
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
            // 用实际捕获图尺寸做比例换算（见 CoordinateConverter 的病例注释）
            let pxRect = CoordinateConverter.pixelRect(
                selection: selection, onScreen: screen,
                imageWidth: full.width, imageHeight: full.height
            )
            guard let cropped = full.cropping(to: pxRect), cropped.width > 0, cropped.height > 0 else {
                throw CaptureError.cropFailed
            }
            let realScale = CGFloat(full.width) / screen.frame.width
            Log.event(.capture, "capture.display.ok", [
                "ms": "\(elapsedMs)",
                "pxW": "\(cropped.width)",
                "pxH": "\(cropped.height)",
                "scale": String(format: "%.2f", realScale),
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
