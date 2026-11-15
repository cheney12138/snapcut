import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 滚动截图采集控制器（手动滚动模式）
///
/// 使用方式：`start(region:)` 后用户自己滚动内容，控制器每 ~400ms 抓一帧并通过
/// `onFrame` 回调交付；`stop()` 结束采集，随后把帧序列交给 `Stitcher` 拼接。
///
/// 自动滚动模式（CGEventPost 合成 scrollWheel 事件驱动页面滚动）暂未实现，
/// 见下方 `startAutoScroll` 的 TODO 占位。
///
/// 线程语义：本类为 `@MainActor` 隔离；`start` / `stop` 必须在主线程调用；
/// `onFrame` 回调同样保证在主线程（MainActor）执行，回调内拿到的是只读 CGImage，
/// 可安全转交后台队列做拼接等重活。
@MainActor
final class ScrollCaptureController {

    // MARK: - 配置

    struct Config {
        /// 抓帧间隔（秒）。手动滚动模式下 ~400ms 足以保证相邻帧重叠
        var captureInterval: TimeInterval = 0.4
        /// 最小帧高（像素）：低于此值的帧（如空窗口）直接丢弃
        var minFrameHeight: Int = 8
    }

    // MARK: - 错误

    enum ScrollCaptureError: LocalizedError {
        case regionOffScreen
        case displayNotFound
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .regionOffScreen:
                return "采集区域不在任何已知屏幕上"
            case .displayNotFound:
                return "SCShareableContent 中找不到目标显示器"
            case .alreadyRunning:
                return "滚动采集已在进行中"
            }
        }
    }

    // MARK: - 状态

    /// 帧回调：每抓到一帧在主线程调用一次
    var onFrame: ((CGImage) -> Void)?
    /// 停止回调（用户 stop 或异常终止），在主线程调用
    var onStop: ((Int) -> Void)? // 参数为本次采集累计交付的帧数

    private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var deliveredFrameCount = 0

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    deinit {
        task?.cancel()
    }

    // MARK: - 开始 / 停止

    /// 开始对指定区域（AppKit 全局坐标，point）做定时抓帧采集。
    ///
    /// - Throws: 区域不在屏幕上 / 已在运行 / 找不到显示器。
    /// 线程语义：必须在主线程调用；内部立刻返回，抓帧循环运行在后台 Task 中。
    func start(region: CGRect) throws {
        guard !isRunning else { throw ScrollCaptureError.alreadyRunning }
        guard let screen = Self.screen(containing: region) else {
            throw ScrollCaptureError.regionOffScreen
        }
        guard let displayID = Self.displayID(of: screen) else {
            throw ScrollCaptureError.displayNotFound
        }
        let scale = screen.backingScaleFactor
        let interval = config.captureInterval
        isRunning = true
        deliveredFrameCount = 0
        Log.event(.scroll, "scroll.sampler.start", [
            "region": "\(Int(region.width))x\(Int(region.height))",
            "display": "\(displayID)", "interval": "\(interval)",
        ])

        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await ScrollFrameGrabber.capture(
                        region: region, displayID: displayID, scale: scale)
                    if let self, frame.height >= self.config.minFrameHeight {
                        self.deliveredFrameCount += 1
                        self.onFrame?(frame)
                    }
                } catch {
                    // 单帧失败（权限抖动 / 显示器热插拔等）打日志继续重试，不中断采集
                    Log.error(.scroll, "scroll.frame.grab.fail", ["err": "\(error.localizedDescription)"])
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// 停止采集。已抓到的帧仍会通过 `onFrame` 交付完在途的一帧（若有），
    /// 随后触发 `onStop(累计帧数)`。
    /// 线程语义：必须在主线程调用；幂等（未运行时调用无副作用）。
    func stop() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        isRunning = false
        Log.event(.scroll, "scroll.sampler.stop", ["delivered": "\(deliveredFrameCount)"])
        onStop?(deliveredFrameCount)
    }

    // MARK: - 屏幕定位

    /// 返回包含区域中心的屏幕（点坐标）。纯函数，任意线程可调用。
    static func screen(containing region: CGRect) -> NSScreen? {
        let center = CGPoint(x: region.midX, y: region.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    /// 从 NSScreen 取 CGDirectDisplayID。纯函数，任意线程可调用。
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID else { return nil }
        return id
    }

    // MARK: - 自动滚动（TODO 占位，暂不实现）

    /// TODO(auto-scroll): 自动滚动模式 —— 通过 CGEventPost 合成 scrollWheel 事件
    /// 驱动目标窗口匀速滚动（先点击窗口获得焦点，再按固定像素步长发事件），
    /// 抓帧节奏与滚动步长联动以保证相邻帧重叠可控。
    /// 需要辅助功能权限（AXIsProcessTrusted）；实现时复用本类的抓帧循环，
    /// 仅把「用户手滚」换成「事件驱动滚动」。
    // func startAutoScroll(region: CGRect, pixelsPerTick: Int) throws { ... }
}

// MARK: - 精简抓帧器（集成占位）

/// ScrollFrameGrabber：本模块自带的精简抓帧实现（SCShareableContent +
/// SCScreenshotManager 整屏截图 + 像素裁剪）。
///
/// ⚠️ 集成时删除本类型，改用 internal/capture 模块的 CaptureService /
/// SCKCapture（坐标换算统一走 CoordinateConverter），避免两套截屏入口并存。
///
/// 线程语义：`capture` 为 async；SCShareableContent / SCScreenshotManager 的
/// 异步接口自带并发安全，本类型无共享可变状态，可多任务并发调用。
enum ScrollFrameGrabber {

    /// 抓取区域截图：整屏 SCK 截图 → 按 scale 裁剪到像素区域。
    /// region 为 AppKit 全局点坐标；displayID 为目标显示器。
    static func capture(
        region: CGRect, displayID: CGDirectDisplayID, scale: CGFloat
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScrollCaptureController.ScrollCaptureError.displayNotFound
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
        let full = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        // ⚠️ 不信任传入 scale（BetterDisplay/虚拟分辨率病例：SCK 整屏图 1920×1080
        // 而屏物理 3456×2234）——用「实际图尺寸 ÷ 屏幕 point 尺寸」实测比例裁剪
        let screen = NSScreen.screens.first { Self.displayID(of: $0) == displayID }
        guard let frame = screen?.frame, frame.width > 0, frame.height > 0 else {
            throw ScrollCaptureController.ScrollCaptureError.displayNotFound
        }
        let scaleX = CGFloat(full.width) / frame.width
        let scaleY = CGFloat(full.height) / frame.height
        let pxRect = CGRect(
            x: (region.minX - frame.minX) * scaleX,
            y: (frame.maxY - region.maxY) * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        ).integral
        guard pxRect.width > 0, pxRect.height > 0,
              let cropped = full.cropping(to: pxRect) else {
            throw ScrollCaptureController.ScrollCaptureError.regionOffScreen
        }
        return cropped
    }

    /// displayID 辅助（与 ScrollCaptureController 保持一致的取法）
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID
    }
}
