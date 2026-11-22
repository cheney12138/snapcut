import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// 滚动截图采集控制器（ScreenCaptureKit `SCStream` 60fps 连续流引擎）
///
/// 相比早期的 `SCScreenshotManager.captureImage` 120ms 轮询（实际 ~7fps）：
/// - 采用系统合成器直推的 `SCStream` 连续视频流，最高 **60 fps**（16.7ms/帧）且静止时 **0 推帧 / 0 CPU**；
/// - 通过 `excludingApplications` 按当前进程 PID 彻底排除 Snapcut 自身浮层（OverlayWindow / 光晕框 / HUD）；
/// - `sourceRect` 直接让 WindowServer 在 GPU 侧完成区域裁剪，`CVPixelBuffer` (`IOSurface`) 转 `CGImage` 仅耗时 `<1ms`，
///   高速惯性甩动也能保持充足帧间重叠，彻底告别「滚动速度过快」。
@MainActor
final class ScrollCaptureController {

    // MARK: - 配置

    struct Config {
        /// 目标上限帧率（默认 60fps；ScreenCaptureKit 仅在画面变化时回调，静止不消耗）
        var targetFPS: Int = 60
        /// 缓冲队列深度（官方建议 ≤ 8）
        var queueDepth: Int = 6
        /// 最小帧高（像素）：低于此值的异常帧直接丢弃
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

    /// 帧回调：每收到一帧有效画面变化在主线程调用一次
    var onFrame: ((CGImage) -> Void)?
    /// 停止回调（用户 stop 或异常终止），在主线程调用
    var onStop: ((Int) -> Void)?
    /// 流启动或运行期异常回调（主线程）
    var onError: ((Error) -> Void)?

    private(set) var isRunning = false
    private var startTask: Task<Void, Never>?
    private var sessionGeneration = 0
    private var deliveredFrameCount = 0
    private let streamBox = ScrollStreamBox()
    private let streamQueue = DispatchQueue(label: "app.snapcut.scroll.stream", qos: .userInteractive)
    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    deinit {
        startTask?.cancel()
        let box = streamBox
        Task { await box.stop() }
    }

    // MARK: - 开始 / 停止

    /// 开始对指定区域（AppKit 全局坐标，point）启动 60fps `SCStream` 连续采集。
    func start(region: CGRect) throws {
        guard !isRunning else { throw ScrollCaptureError.alreadyRunning }
        guard let screen = Self.screen(containing: region) else {
            throw ScrollCaptureError.regionOffScreen
        }
        guard let displayID = Self.displayID(of: screen) else {
            throw ScrollCaptureError.displayNotFound
        }

        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let fps = max(1, min(120, config.targetFPS))
        let queueDepth = max(2, min(8, config.queueDepth))
        let minHeight = config.minFrameHeight

        sessionGeneration &+= 1
        let generation = sessionGeneration
        isRunning = true
        deliveredFrameCount = 0

        Log.event(.scroll, "scroll.sampler.start", [
            "engine": "SCStream",
            "region": "\(Int(region.width))x\(Int(region.height))",
            "display": "\(displayID)",
            "maxFPS": "\(fps)",
        ])

        let box = streamBox
        let queue = streamQueue
        startTask = Task { [weak self] in
            do {
                try await box.start(
                    generation: generation,
                    region: region,
                    displayID: displayID,
                    screenFrame: screenFrame,
                    scale: scale,
                    fps: fps,
                    queueDepth: queueDepth,
                    minFrameHeight: minHeight,
                    streamQueue: queue,
                    onFrame: { [weak self] image in
                        guard let self, self.isRunning, self.sessionGeneration == generation else { return }
                        self.deliveredFrameCount += 1
                        self.onFrame?(image)
                    },
                    onError: { [weak self] error in
                        guard let self, self.isRunning, self.sessionGeneration == generation else { return }
                        Log.error(.scroll, "scroll.stream.error", ["err": "\(error.localizedDescription)"])
                        self.onError?(error)
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.isRunning, self.sessionGeneration == generation else { return }
                Log.error(.scroll, "scroll.stream.startFail", ["err": "\(error.localizedDescription)"])
                self.isRunning = false
                self.onError?(error)
            }
        }
    }

    /// 停止采集，终止 `SCStream` 与启动任务，随后触发 `onStop(累计帧数)`。
    func stop() {
        guard isRunning else { return }
        sessionGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        isRunning = false

        let box = streamBox
        Task { await box.stop() }
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
}

// MARK: - SCStream 生命周期隔离 Actor

private actor ScrollStreamBox {
    private var activeStream: SCStream?
    private var activeOutput: ScrollStreamOutput?
    private var currentGeneration = 0

    func start(
        generation: Int,
        region: CGRect,
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        scale: CGFloat,
        fps: Int,
        queueDepth: Int,
        minFrameHeight: Int,
        streamQueue: DispatchQueue,
        onFrame: @escaping @MainActor (CGImage) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async throws {
        await stop()
        currentGeneration = generation

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        try Task.checkCancellation()
        guard currentGeneration == generation else { return }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScrollCaptureController.ScrollCaptureError.displayNotFound
        }

        // 进程级排除 Snapcut 自身所有窗口（OverlayWindow / 光晕框 / HUD），从合成层杜绝入镜
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter { $0.processID == ownPID }
        let filter: SCContentFilter
        if !excludedApps.isEmpty {
            filter = SCContentFilter(
                display: display, excludingApplications: excludedApps, exceptingWindows: []
            )
        } else {
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        }

        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.sourceRect = CGRect(
            x: region.minX - screenFrame.minX,
            y: screenFrame.maxY - region.maxY,
            width: region.width,
            height: region.height
        )
        config.width = max(1, Int(region.width * scale))
        config.height = max(1, Int(region.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = queueDepth
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.scalesToFit = false

        Log.event(.scroll, "scroll.filter.cached", [
            "display": "\(displayID)",
            "excludedApps": "\(excludedApps.count)",
            "px": "\(config.width)x\(config.height)",
            "maxFPS": "\(fps)",
        ])

        let output = ScrollStreamOutput(
            expectedWidth: config.width,
            expectedHeight: config.height,
            minFrameHeight: minFrameHeight,
            region: region,
            screenFrame: screenFrame,
            onFrame: onFrame,
            onError: onError
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: streamQueue)
        try await stream.startCapture()

        if Task.isCancelled || currentGeneration != generation {
            try? await stream.stopCapture()
            return
        }
        activeStream = stream
        activeOutput = output
    }

    func stop() async {
        currentGeneration &+= 1
        let stream = activeStream
        activeStream = nil
        activeOutput = nil
        if let stream {
            try? await stream.stopCapture()
        }
    }
}

// MARK: - SCStream 高速帧接收器（IOSurface 零阻塞拷贝 → sRGB CGImage）

private final class ScrollStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let expectedWidth: Int
    private let expectedHeight: Int
    private let minFrameHeight: Int
    private let region: CGRect
    private let screenFrame: CGRect
    private let colorSpace: CGColorSpace
    private let onFrame: @MainActor (CGImage) -> Void
    private let onError: @MainActor (Error) -> Void

    init(
        expectedWidth: Int,
        expectedHeight: Int,
        minFrameHeight: Int,
        region: CGRect,
        screenFrame: CGRect,
        onFrame: @escaping @MainActor (CGImage) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        self.expectedWidth = expectedWidth
        self.expectedHeight = expectedHeight
        self.minFrameHeight = minFrameHeight
        self.region = region
        self.screenFrame = screenFrame
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let image = makeCGImage(from: pixelBuffer), image.height >= minFrameHeight else { return }

        let deliver = onFrame
        Task { @MainActor in
            deliver(image)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let notify = onError
        Task { @MainActor in
            notify(error)
        }
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        // 立刻拷贝并解锁 IOSurface，避免占住 SCStream queueDepth 环形缓冲
        let pixelData = Data(bytes: baseAddress, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let full = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        if full.width == expectedWidth && full.height == expectedHeight {
            return full
        }

        guard screenFrame.width > 0, screenFrame.height > 0 else { return full }
        let scaleX = CGFloat(full.width) / screenFrame.width
        let scaleY = CGFloat(full.height) / screenFrame.height
        let pxRect = CGRect(
            x: (region.minX - screenFrame.minX) * scaleX,
            y: (screenFrame.maxY - region.maxY) * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        ).integral
        guard pxRect.width > 0, pxRect.height > 0,
              let cropped = full.cropping(to: pxRect) else {
            return nil
        }
        return cropped
    }
}
