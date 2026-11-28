import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import os
import QuartzCore
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// 屏幕录制适配器（ScreenCaptureKit `SCStream` + `AVAssetWriter` / `CGImageDestination`）
///
/// 关键设计：
/// - 进程级排除 Snapcut 自身浮层（选区框、控制条、倒计时 HUD 永不入镜）；
/// - 支持 MP4（H.264 硬件加速 + 可选系统声音 & 麦克风）与 GIF（O(1) 内存流式增量写盘 + 真实帧间时长）；
/// - 支持无缝暂停/继续（统一偏移媒体时间戳，输出连续无跳变时间轴）。
@MainActor
final class SCKScreenRecorder: ScreenRecording {
    enum RecorderError: LocalizedError {
        case alreadyRunning
        case notRunning
        case displayNotFound
        case invalidWriter(String)
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "录制已在进行中"
            case .notRunning: return "当前没有进行中的录制"
            case .displayNotFound: return "找不到目标显示器"
            case .invalidWriter(let msg): return "编码器初始化失败：\(msg)"
            case .emptyRecording: return "未采集到有效画面帧"
            }
        }
    }

    private(set) var isRecording = false
    private(set) var isPaused = false

    private var session: ActiveSession?
    private var progressTimer: Timer?
    /// 实时音频电平轮询（15Hz）：只在 MP4 且启用系统声/麦克风时存在，随录制生命周期释放
    private var audioMeterTimer: Timer?
    private var startedWallTime: Date?
    private var accumulatedActiveBeforePause: TimeInterval = 0
    private var onEvent: (@MainActor (ScreenRecordingEvent) -> Void)?

    func start(
        request: ScreenRecordingRequest,
        onEvent: @escaping @MainActor (ScreenRecordingEvent) -> Void
    ) async throws {
        guard !isRecording else { throw RecorderError.alreadyRunning }
        self.onEvent = onEvent

        var effectiveOptions = request.options
        if effectiveOptions.format == .mp4 && effectiveOptions.captureMicrophone {
            let micOK = await Self.ensureMicrophonePermission()
            if !micOK {
                effectiveOptions.captureMicrophone = false
                // 降级提示必须与真实落盘内容一致：只有系统声也在录才说「画面与系统声音」
                let hasSystemAudio = effectiveOptions.captureSystemAudio
                Log.event(.recording, "recording.mic.deniedFallback", [
                    "sysAudio": "\(hasSystemAudio)",
                ])
                CaptureToast.show(
                    message: hasSystemAudio
                        ? "未开启麦克风权限，已继续录制画面与系统声音"
                        : "未开启麦克风权限，已继续录制无声画面",
                    status: .warn
                )
            }
        }

        let effectiveRequest = ScreenRecordingRequest(
            regionGlobal: request.regionGlobal,
            displayID: request.displayID,
            screenFrame: request.screenFrame,
            backingScale: request.backingScale,
            preferDisplayP3: request.preferDisplayP3,
            options: effectiveOptions,
            outputURL: request.outputURL,
            isTemporaryFile: request.isTemporaryFile
        )

        let active = ActiveSession(request: effectiveRequest) { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.stopProgressTimer()
                self.stopAudioMeterTimer()
                self.isRecording = false
                self.isPaused = false
                self.session = nil
                self.onEvent?(.failed(message))
            }
        }

        try await active.start()
        self.session = active
        self.isRecording = true
        self.isPaused = false
        self.accumulatedActiveBeforePause = 0
        self.startedWallTime = Date()
        startProgressTimer()
        if effectiveOptions.format == .mp4,
           effectiveOptions.captureSystemAudio || effectiveOptions.captureMicrophone {
            startAudioMeterTimer()
        }
        onEvent(.started)

        Log.event(.recording, "recording.start", [
            "format": effectiveOptions.format.rawValue,
            "fps": "\(effectiveOptions.effectiveFPS)",
            "sysAudio": "\(effectiveOptions.captureSystemAudio)",
            "mic": "\(effectiveOptions.captureMicrophone)",
            "cursor": "\(effectiveOptions.showCursor)",
        ])
    }

    func pause() async {
        guard isRecording, !isPaused, let session else { return }
        isPaused = true
        if let started = startedWallTime {
            accumulatedActiveBeforePause += Date().timeIntervalSince(started)
            startedWallTime = nil
        }
        await session.pause()
        // 暂停时立刻回平：不必等下一个轮询周期，UI 电平条立刻落零
        onEvent?(.audioLevels(system: 0, microphone: 0))
        onEvent?(.paused(elapsed: accumulatedActiveBeforePause))
        Log.event(.recording, "recording.pause", [
            "elapsed": String(format: "%.1f", accumulatedActiveBeforePause),
        ])
    }

    func resume() async {
        guard isRecording, isPaused, let session else { return }
        isPaused = false
        startedWallTime = Date()
        await session.resume()
        onEvent?(.resumed)
        Log.event(.recording, "recording.resume")
    }

    func stop() async throws -> RecordingResult {
        guard isRecording, let session else { throw RecorderError.notRunning }
        stopProgressTimer()
        stopAudioMeterTimer()
        let activeDuration = currentElapsed()
        isRecording = false
        isPaused = false
        self.session = nil

        let result = try await session.stop(fallbackDuration: activeDuration)
        Log.event(.recording, "recording.stop.ok", [
            "format": result.format.rawValue,
            "px": "\(result.pixelWidth)x\(result.pixelHeight)",
            "duration": String(format: "%.2f", result.duration),
            "frames": "\(result.frameCount)",
            "bytes": "\(result.fileSizeBytes)",
        ])
        return result
    }

    func cancel() async {
        stopProgressTimer()
        stopAudioMeterTimer()
        isRecording = false
        isPaused = false
        let currentSession = session
        session = nil
        startedWallTime = nil
        accumulatedActiveBeforePause = 0
        if let currentSession {
            await currentSession.cancel()
        }
        Log.event(.recording, "recording.cancelled")
    }

    // MARK: - 计时器

    private func currentElapsed() -> TimeInterval {
        if isPaused {
            return accumulatedActiveBeforePause
        }
        if let started = startedWallTime {
            return accumulatedActiveBeforePause + Date().timeIntervalSince(started)
        }
        return accumulatedActiveBeforePause
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isPaused else { return }
                self.onEvent?(.progress(elapsed: self.currentElapsed()))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// 启动音频电平轮询（~15Hz）：只读 `ActiveSession` 的无锁快照，绝不参与编码路径
    private func startAudioMeterTimer() {
        stopAudioMeterTimer()
        let timer = Timer(timeInterval: 0.066, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isPaused, let session = self.session else { return }
                let levels = session.snapshotAudioLevels()
                self.onEvent?(.audioLevels(system: levels.system, microphone: levels.microphone))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioMeterTimer = timer
    }

    private func stopAudioMeterTimer() {
        audioMeterTimer?.invalidate()
        audioMeterTimer = nil
    }

    // MARK: - 麦克风权限检查

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

// MARK: - 底层 SCStream + 编码管线

private final class ActiveSession: @unchecked Sendable {
    private let request: ScreenRecordingRequest
    private let mediaQueue = DispatchQueue(label: "app.snapcut.recording.media", qos: .userInitiated)
    /// GIF 色彩量化与 Floyd-Steinberg 抖动较耗时，必须在独立串行队列执行，绝不阻塞 SCStream `sampleHandlerQueue` 导致掉帧
    private let gifEncodeQueue = DispatchQueue(label: "app.snapcut.recording.gif", qos: .utility)
    private let onAsyncError: @Sendable (String) -> Void

    private var stream: SCStream?
    private var streamDelegate: StreamDelegateProxy?

    // 编码目标状态（仅在 mediaQueue 内读写）
    private var targetWidth = 0
    private var targetHeight = 0
    private var isPaused = false
    private var isStopped = false
    private var pauseBeganHostTime: CMTime?
    private var accumulatedPauseOffset: CMTime = .zero
    private var sessionStarted = false
    private var firstAdjustedPTS: CMTime?
    private var lastAdjustedVideoPTS: CMTime?
    private var firstThumbnail: CGImage?
    private var writtenFrames = 0

    // MP4 写入器（仅 mediaQueue）
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    /// 最近一帧成功写入的视频样本：静止画面补尾帧专用，保证输出时长 = 真实录制时长
    /// （每帧覆盖，最多只占 queueDepth=8 中的 1 槽）
    private var lastMP4VideoSample: CMSampleBuffer?
    /// 各音轨最近一帧的调整后 PTS：暂停/继续与音频包乱序时直接丢弃非单调包，避免 AVAssetWriter 失败
    private var lastSystemAudioPTS: CMTime?
    private var lastMicAudioPTS: CMTime?

    // 音频归一化器（零锁，仅 mediaQueue 串行访问）：把任意源格式统一成 48kHz / 2ch / Float32 / 非交错
    private let systemAudioNormalizer = AudioFormatNormalizer()
    private let micAudioNormalizer = AudioFormatNormalizer()
    /// 成功写入的音频包数量（仅用于收尾日志核对音轨是否真的有数据）
    private var systemAudioPacketsWritten = 0
    private var micAudioPacketsWritten = 0
    /// 音频写入失败计数：日志节流用（前 3 次 + 每 50 次）
    private var systemAudioAppendFailures = 0
    private var micAudioAppendFailures = 0

    // MARK: 双路混音（系统声 + 麦克风 → 1 条音轨）状态（仅 mediaQueue）

    /// 混音音轨（双开时才存在；单开时走 systemAudioInput / micAudioInput 直通）
    private var mixedAudioInput: AVAssetWriterInput?
    /// 实时混音器（零锁，仅 mediaQueue 串行访问；由 Wave 3 的 AudioTrackMixer 提供）
    private var audioMixer: AudioTrackMixer?
    /// 最近一个成功写入的混音 chunk 的 PTS：单调性防护，非递增的 chunk 直接跳过
    private var lastMixedAudioPTS: CMTime?
    /// 成功写入的混音 chunk 数量
    private var mixedAudioPacketsWritten = 0
    /// 混音写入被节流/失败的计数：日志节流用（前 3 次 + 每 50 次）
    private var mixedAudioAppendFailures = 0
    /// 恢复瞬间的**原始**（未减暂停偏移）时间戳下限：拦截暂停前/暂停中滞留在硬件缓冲里的旧包
    private var resumeMinRawPTS: CMTime?
    private var resumeDroppedVideoFrames = 0
    private var resumeDroppedAudioPackets = 0
    /// 单路模式下最近音频包的结束 PTS：finalizeMP4 用它对齐 safeEndPTS，避免音轨超出 endSession
    private var lastSingleAudioEndPTS: CMTime?

    // 实时音频电平（媒体线程写、主线程 15Hz 读）：OSAllocatedUnfairLock 保证跨线程快照无数据竞态、
    // 且临界区只有几个浮点赋值，绝不阻塞 SCStream 采样回调
    private struct AudioLevelState: Sendable {
        var system: Float = 0
        var microphone: Float = 0
        var systemUpdatedAt: CFTimeInterval = 0
        var micUpdatedAt: CFTimeInterval = 0
    }
    private let audioLevelLock = OSAllocatedUnfairLock(initialState: AudioLevelState())

    // GIF 写入器（仅 gifEncodeQueue 独占，O(1) 内存流式增量写入）
    private var gifDestination: CGImageDestination?
    private var pendingGIFFrame: (image: CGImage, adjustedPTS: CMTime)?
    private var gifMinDelay: Double = 1.0 / 15.0
    private var gifWrittenFrames = 0
    private var gifCancelled = false
    private let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    init(request: ScreenRecordingRequest, onAsyncError: @escaping @Sendable (String) -> Void) {
        self.request = request
        self.onAsyncError = onAsyncError
    }

    /// 双路混音路由判定：只有 MP4 且系统声、麦克风同时开启时才把两路混成一条音轨
    private var isDualAudioMixing: Bool {
        request.options.format == .mp4
            && request.options.captureSystemAudio
            && request.options.captureMicrophone
    }

    /// 本次录制的音频路由形态（日志用）：none / sys / mic / mixed
    private var audioModeName: String {
        if mixedAudioInput != nil { return "mixed" }
        if systemAudioInput != nil { return "sys" }
        if micAudioInput != nil { return "mic" }
        return "none"
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
            throw SCKScreenRecorder.RecorderError.displayNotFound
        }

        // 进程级排除 Snapcut 自身所有窗口（选区框、控制条、Toast 等绝不入镜）
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

        // 物理像素格对齐 sourceRect
        let safeScale = max(1, request.backingScale)
        let invScale = 1.0 / safeScale
        let screenFrame = request.screenFrame
        let region = request.regionGlobal
        let rawMinX = max(0, region.minX - screenFrame.minX)
        let rawMinY = max(0, screenFrame.maxY - region.maxY)
        let rawMaxX = min(screenFrame.width, region.maxX - screenFrame.minX)
        let rawMaxY = min(screenFrame.height, screenFrame.maxY - region.minY)
        let alignedMinX = (rawMinX * safeScale).rounded(.down) * invScale
        let alignedMinY = (rawMinY * safeScale).rounded(.down) * invScale
        let alignedMaxX = max(alignedMinX + invScale, (rawMaxX * safeScale).rounded(.up) * invScale)
        let alignedMaxY = max(alignedMinY + invScale, (rawMaxY * safeScale).rounded(.up) * invScale)
        let sourceRect = CGRect(
            x: alignedMinX,
            y: alignedMinY,
            width: alignedMaxX - alignedMinX,
            height: alignedMaxY - alignedMinY
        )

        let targetSize = RecordingGeometry.targetPixelSize(
            regionPoints: sourceRect.size,
            backingScale: safeScale,
            options: request.options
        )
        let width = targetSize.width
        let height = targetSize.height
        let fps = request.options.effectiveFPS

        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.sourceRect = sourceRect
        config.width = width
        config.height = height
        // 缩放铺满策略：GIF 1x 模式下 sourceRect 是点、输出是像素，必须缩放；MP4 的 width/height 经偶数对齐后
        // 与 sourceRect 的宽高比存在 ≤1px 差异，同样按 fit 铺满，避免边缘出现黑边/绿边
        switch request.options.format {
        case .mp4:
            config.scalesToFit = true
        case .gif:
            config.scalesToFit = (request.options.gifScale1x && safeScale > 1)
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = request.options.showCursor

        if request.options.format == .mp4 {
            config.capturesAudio = request.options.captureSystemAudio
            if request.options.captureSystemAudio {
                config.sampleRate = 48_000
                config.channelCount = 2
                config.excludesCurrentProcessAudio = true
            }
            config.captureMicrophone = request.options.captureMicrophone
        }

        // 准备目标文件目录与编码器
        let dir = request.outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: request.outputURL.path) {
            try? FileManager.default.removeItem(at: request.outputURL)
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            mediaQueue.async { [self] in
                do {
                    self.targetWidth = width
                    self.targetHeight = height
                    self.gifMinDelay = 1.0 / Double(max(1, fps))

                    switch request.options.format {
                    case .mp4:
                        try self.setupMP4Writer(width: width, height: height, fps: fps)
                    case .gif:
                        try self.setupGIFDestination()
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        let proxy = StreamDelegateProxy(owner: self)
        let scStream = SCStream(filter: filter, configuration: config, delegate: proxy)
        try scStream.addStreamOutput(proxy, type: .screen, sampleHandlerQueue: mediaQueue)
        if request.options.format == .mp4 {
            if request.options.captureSystemAudio {
                try scStream.addStreamOutput(proxy, type: .audio, sampleHandlerQueue: mediaQueue)
            }
            if request.options.captureMicrophone {
                try scStream.addStreamOutput(proxy, type: .microphone, sampleHandlerQueue: mediaQueue)
            }
        }

        self.streamDelegate = proxy
        self.stream = scStream

        do {
            try await scStream.startCapture()
        } catch {
            await cleanupOnFailure()
            throw error
        }
    }

    func pause() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            mediaQueue.async { [self] in
                guard !isPaused, !isStopped else {
                    cont.resume()
                    return
                }
                isPaused = true
                // 暂停即清空电平，避免 UI 电平条卡在暂停前的瞬间值
                resetAudioLevels()
                let nowHost = CMClockGetTime(CMClockGetHostTimeClock())
                pauseBeganHostTime = nowHost
                if request.options.format == .gif {
                    let adjustedNow = CMTimeSubtract(nowHost, accumulatedPauseOffset)
                    gifEncodeQueue.async { [self] in
                        flushPendingGIF(upTo: adjustedNow)
                    }
                } else if sessionStarted, let mixer = audioMixer {
                    // 混音模式：暂停点前的音频必须当场冲刷干净，否则恢复后会补出一段跳空
                    let cutoffPTS = CMTimeSubtract(nowHost, accumulatedPauseOffset)
                    writeMixedAudioChunks(mixer.flushForPause(upTo: cutoffPTS))
                }
                cont.resume()
            }
        }
    }

    func resume() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            mediaQueue.async { [self] in
                guard isPaused, !isStopped else {
                    cont.resume()
                    return
                }
                let nowHost = CMClockGetTime(CMClockGetHostTimeClock())
                if let began = pauseBeganHostTime {
                    let delta = CMTimeSubtract(nowHost, began)
                    if delta > .zero {
                        accumulatedPauseOffset = CMTimeAdd(accumulatedPauseOffset, delta)
                    }
                }
                pauseBeganHostTime = nil
                isPaused = false
                // 恢复瞬间打一道「原始时间戳下限」：暂停前/暂停中滞留在 SCStream 与硬件缓冲里的旧包
                // 会在恢复后陆续送达，它们的 rawPTS 早于此刻，直接丢（仅 MP4；GIF 完全不参与，零回归）
                if request.options.format == .mp4 {
                    resumeMinRawPTS = CMTimeSubtract(nowHost, CMTime(value: 5, timescale: 1000))
                    // 重采样器滤波器里压着暂停期间的尾巴，不清掉恢复后头几包会带旧滤波残余
                    systemAudioNormalizer.flushState()
                    micAudioNormalizer.flushState()
                }
                cont.resume()
            }
        }
    }

    func stop(fallbackDuration: TimeInterval) async throws -> RecordingResult {
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        self.streamDelegate = nil

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RecordingResult, Error>) in
            mediaQueue.async { [self] in
                isStopped = true
                if isPaused, let began = pauseBeganHostTime {
                    let nowHost = CMClockGetTime(CMClockGetHostTimeClock())
                    let delta = CMTimeSubtract(nowHost, began)
                    if delta > .zero {
                        accumulatedPauseOffset = CMTimeAdd(accumulatedPauseOffset, delta)
                    }
                    pauseBeganHostTime = nil
                    isPaused = false
                }

                let nowAdjusted = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), accumulatedPauseOffset)
                let computedDuration: TimeInterval = {
                    if let first = firstAdjustedPTS {
                        let d = CMTimeSubtract(nowAdjusted, first).seconds
                        if d > 0.05 { return d }
                    }
                    return max(0.1, fallbackDuration)
                }()

                switch request.options.format {
                case .mp4:
                    finalizeMP4(endPTS: nowAdjusted, duration: computedDuration, continuation: cont)
                case .gif:
                    let width = targetWidth
                    let height = targetHeight
                    let thumb = firstThumbnail
                    gifEncodeQueue.async { [self] in
                        finalizeGIF(
                            endPTS: nowAdjusted,
                            duration: computedDuration,
                            width: width,
                            height: height,
                            thumbnail: thumb,
                            continuation: cont
                        )
                    }
                }
            }
        }
    }

    func cancel() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamDelegate = nil
        await cleanupOnFailure()
    }

    private func cleanupOnFailure() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            mediaQueue.async { [self] in
                isStopped = true
                resetAudioLevels()
                assetWriter?.cancelWriting()
                assetWriter = nil
                videoInput = nil
                systemAudioInput = nil
                micAudioInput = nil
                mixedAudioInput = nil
                audioMixer?.reset()
                audioMixer = nil
                lastMixedAudioPTS = nil
                resumeMinRawPTS = nil
                lastMP4VideoSample = nil
                systemAudioNormalizer.reset()
                micAudioNormalizer.reset()
                gifEncodeQueue.async { [self] in
                    gifCancelled = true
                    gifDestination = nil
                    pendingGIFFrame = nil
                    try? FileManager.default.removeItem(at: request.outputURL)
                    cont.resume()
                }
            }
        }
    }

    // MARK: - 编码器初始化（mediaQueue）

    private func setupMP4Writer(width: Int, height: Int, fps: Int) throws {
        let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mp4)
        let bitRate = min(24_000_000, max(4_000_000, width * height * fps / 10))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: max(fps, fps * 2),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else {
            throw SCKScreenRecorder.RecorderError.invalidWriter("无法添加视频轨道")
        }
        writer.add(vInput)
        videoInput = vInput

        if isDualAudioMixing {
            // 双开：只建 **1 条** 160kbps 混音音轨，系统声与麦克风在内存里实时混成一路
            // （两条独立音轨播出去没有增益控制，重叠段会硬削顶；单轨也让播放器兼容性最好）
            let mixInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: makeStereoAACSettings(bitRate: 160_000)
            )
            mixInput.expectsMediaDataInRealTime = true
            if writer.canAdd(mixInput) {
                writer.add(mixInput)
                mixedAudioInput = mixInput
                audioMixer = AudioTrackMixer()
            } else {
                Log.error(.recording, "recording.mp4.audioTrackRejected", ["track": "mixed"])
            }
        } else {
            if request.options.captureSystemAudio {
                // 系统声：48kHz 2ch，128kbps
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: makeStereoAACSettings(bitRate: 128_000))
                aInput.expectsMediaDataInRealTime = true
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    systemAudioInput = aInput
                }
            }

            if request.options.captureMicrophone {
                // 麦克风：同样按 48kHz 2ch 编码（归一化器会把单声道人声双耳居中），96kbps
                let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: makeStereoAACSettings(bitRate: 96_000))
                mInput.expectsMediaDataInRealTime = true
                if writer.canAdd(mInput) {
                    writer.add(mInput)
                    micAudioInput = mInput
                }
            }
        }

        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "startWriting 返回 false"
            throw SCKScreenRecorder.RecorderError.invalidWriter(msg)
        }
        assetWriter = writer
        Log.event(.recording, "recording.mp4.setup", [
            "px": "\(width)x\(height)",
            "fps": "\(fps)",
            "kbps": "\(bitRate / 1000)",
            "sysAudio": "\(request.options.captureSystemAudio)",
            "mic": "\(request.options.captureMicrophone)",
            "audioMode": audioModeName,
        ])
    }

    /// 统一的双声道 AAC 配置：两条音轨都写死 48kHz / 2ch，杜绝声道或采样率不匹配导致 AVAssetWriter 失败
    private func makeStereoAACSettings(bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitRate,
            AVChannelLayoutKey: Self.stereoChannelLayoutData(),
        ]
    }

    /// Stereo 声道布局的序列化字节（AudioChannelLayout 头 12 字节，tag 型布局无附加描述）
    private static func stereoChannelLayoutData() -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        layout.mNumberChannelDescriptions = 0
        let headerSize = MemoryLayout<UInt32>.size * 3
        return withUnsafeBytes(of: &layout) { Data($0.prefix(headerSize)) }
    }

    private func setupGIFDestination() throws {
        guard let dest = CGImageDestinationCreateWithURL(
            request.outputURL as CFURL,
            UTType.gif.identifier as CFString,
            0,
            nil
        ) else {
            throw SCKScreenRecorder.RecorderError.invalidWriter("无法创建 GIF 写入目标")
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        gifDestination = dest
    }

    // MARK: - 样本处理（mediaQueue）

    fileprivate func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isStopped, !isPaused, sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            guard isCompleteVideoFrame(sampleBuffer),
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // 跨暂停滞留帧（仅 MP4）：恢复前滞留在 SCStream 缓冲里的旧帧会让时间轴回退
            if request.options.format == .mp4,
               let minRaw = resumeMinRawPTS,
               CMTimeCompare(rawPTS, minRaw) < 0 {
                resumeDroppedVideoFrames += 1
                return
            }
            let adjustedPTS = CMTimeSubtract(rawPTS, accumulatedPauseOffset)
            if let last = lastAdjustedVideoPTS, CMTimeCompare(adjustedPTS, last) <= 0 {
                return
            }

            switch request.options.format {
            case .mp4:
                if firstThumbnail == nil {
                    firstThumbnail = copyCGImage(from: imageBuffer)
                }
                appendMP4VideoFrame(sampleBuffer, rawPTS: rawPTS, adjustedPTS: adjustedPTS)
            case .gif:
                appendGIFFrame(imageBuffer: imageBuffer, adjustedPTS: adjustedPTS)
            }

        case .audio:
            guard request.options.format == .mp4, sessionStarted,
                  systemAudioInput != nil || mixedAudioInput != nil else { return }
            appendAudioBuffer(sampleBuffer, track: .system)

        case .microphone:
            guard request.options.format == .mp4, sessionStarted,
                  micAudioInput != nil || mixedAudioInput != nil else { return }
            appendAudioBuffer(sampleBuffer, track: .microphone)

        @unknown default:
            break
        }
    }

    fileprivate func handleStreamError(_ error: Error) {
        mediaQueue.async { [self] in
            guard !isStopped else { return }
            isStopped = true
            assetWriter?.cancelWriting()
            onAsyncError(error.localizedDescription)
        }
    }

    private func isCompleteVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else {
            return false
        }
        return status == .complete
    }

    private func appendMP4VideoFrame(_ sampleBuffer: CMSampleBuffer, rawPTS: CMTime, adjustedPTS: CMTime) {
        guard let writer = assetWriter, let vInput = videoInput else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: adjustedPTS)
            sessionStarted = true
            firstAdjustedPTS = adjustedPTS
            // 混音器时钟以首帧 PTS 为锚点：音频与视频共用同一条输出时间轴
            if let mixer = audioMixer {
                mixer.anchor(at: adjustedPTS)
            }
        }
        guard writer.status == .writing, vInput.isReadyForMoreMediaData else { return }

        let adjustedSample: CMSampleBuffer
        if accumulatedPauseOffset == .zero {
            adjustedSample = sampleBuffer
        } else if let shifted = shiftSampleBufferTime(sampleBuffer, offset: accumulatedPauseOffset) {
            adjustedSample = shifted
        } else {
            return
        }

        if vInput.append(adjustedSample) {
            lastAdjustedVideoPTS = adjustedPTS
            writtenFrames += 1
            // 覆盖为最近一帧：静止画面时 finalizeMP4 用它补尾帧
            lastMP4VideoSample = adjustedSample
            // 视频帧时钟推进：混音器按此把两路音频对齐成整块输出（音频先到也绝不抢跑）
            if let mixer = audioMixer {
                writeMixedAudioChunks(mixer.advanceClock(to: adjustedPTS))
            }
        } else {
            Log.error(.recording, "recording.mp4.appendFail", [
                "err": writer.error?.localizedDescription ?? "unknown",
            ])
        }
    }

    private enum AudioTrack {
        case system
        case microphone

        var logName: String {
            switch self {
            case .system: return "system"
            case .microphone: return "mic"
            }
        }
    }

    private func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer, track: AudioTrack) {
        guard let writer = assetWriter, writer.status == .writing, let startPTS = firstAdjustedPTS else { return }

        guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            logAudioAppendFailure(track: track, reason: "notReadyOrEmpty")
            return
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // 跨暂停滞留包：恢复瞬间之前的旧包（硬件/蓝牙缓冲里的残留）直接丢，避免时间轴回退与听感重叠
        if let minRaw = resumeMinRawPTS, CMTimeCompare(rawPTS, minRaw) < 0 {
            resumeDroppedAudioPackets += 1
            return
        }

        let adjustedPTS = CMTimeSubtract(rawPTS, accumulatedPauseOffset)
        guard CMTimeCompare(adjustedPTS, startPTS) >= 0 else { return }

        // 归一化到 48kHz / 2ch / Float32 / 非交错，并把 PTS 平移到位（normalize 内部按需重建转换器）
        let normalizer = track == .system ? systemAudioNormalizer : micAudioNormalizer
        guard let normalized = normalizer.normalize(sampleBuffer, presentationTimeStamp: adjustedPTS) else {
            logAudioAppendFailure(track: track, reason: "normalize")
            return
        }

        // 电平采集挂在归一化产物上（固定 48k/2ch/Float32，口径跨设备一致），且必须在混音**之前**：
        // 控制栏蓝（系统声）/ 绿（麦克风）两根波形条要各跳各的，不能被混音后的合信号污染。
        // 失败不影响写入主路径
        recordAudioLevel(Self.computeNormalizedAudioLevel(from: normalized), track: track)

        // 混音模式：两路都推给 mixer，由其按 PTS 对齐后吐出新的 chunk（过期包也在 mixer 内部丢弃）
        if let mixer = audioMixer, mixedAudioInput != nil {
            let chunks = mixer.push(
                normalized,
                source: track == .system ? .system : .microphone,
                adjustedPTS: adjustedPTS
            )
            writeMixedAudioChunks(chunks)
            return
        }

        // 单路直通模式：系统声 → systemAudioInput，麦克风 → micAudioInput（保持原行为）
        let input: AVAssetWriterInput?
        switch track {
        case .system: input = systemAudioInput
        case .microphone: input = micAudioInput
        }
        guard let input else { return }

        // 每轨严格单调校验：暂停/继续与音频包乱序都会产生非递增 PTS，直接丢弃该包
        let lastPTS = track == .system ? lastSystemAudioPTS : lastMicAudioPTS
        if let lastPTS, CMTimeCompare(adjustedPTS, lastPTS) <= 0 { return }
        guard input.isReadyForMoreMediaData else { return }

        if input.append(normalized) {
            switch track {
            case .system:
                lastSystemAudioPTS = adjustedPTS
                systemAudioPacketsWritten += 1
            case .microphone:
                lastMicAudioPTS = adjustedPTS
                micAudioPacketsWritten += 1
            }
            // 归一化产物恒为 48kHz：帧数 / 48000 就是本包时长，用于 finalizeMP4 对齐 safeEndPTS
            let frames = CMSampleBufferGetNumSamples(normalized)
            let packetsDuration = CMTimeMultiply(
                CMTime(value: 1, timescale: 48_000),
                multiplier: Int32(clamping: max(1, frames))
            )
            lastSingleAudioEndPTS = CMTimeAdd(adjustedPTS, packetsDuration)
        } else {
            logAudioAppendFailure(
                track: track,
                reason: writer.error?.localizedDescription ?? "appendFalse"
            )
        }
    }

    /// 统一写入混音 chunk（混音模式下唯一的音频落盘路径）
    ///
    /// 三条防护，均记节流日志、绝不崩溃：
    /// 1. chunk PTS 非单调（≤ 上次写入）⇒ 跳过；
    /// 2. `isReadyForMoreMediaData == false` ⇒ 记日志并放弃**当前批次剩余**（不写就会丢音频，写则会让 writer 失败）；
    /// 3. `append` 返回 false ⇒ 记日志（前 3 次 + 每 50 次）。
    private func writeMixedAudioChunks(_ chunks: [CMSampleBuffer]) {
        guard !chunks.isEmpty else { return }
        guard let writer = assetWriter, writer.status == .writing, let mixedInput = mixedAudioInput else { return }
        for chunk in chunks {
            let pts = CMSampleBufferGetPresentationTimeStamp(chunk)
            if let last = lastMixedAudioPTS, CMTimeCompare(pts, last) <= 0 { continue }
            guard mixedInput.isReadyForMoreMediaData else {
                logMixedAudioThrottled(reason: "notReady")
                break
            }
            if mixedInput.append(chunk) {
                lastMixedAudioPTS = pts
                mixedAudioPacketsWritten += 1
            } else {
                logMixedAudioThrottled(reason: writer.error?.localizedDescription ?? "appendFalse")
            }
        }
    }

    /// 混音写入节流日志：前 3 次与每 50 次记录
    private func logMixedAudioThrottled(reason: String) {
        mixedAudioAppendFailures += 1
        let count = mixedAudioAppendFailures
        guard count <= 3 || count % 50 == 0 else { return }
        Log.error(.recording, "recording.mp4.audioAppendFail", [
            "track": "mixed",
            "err": reason,
            "n": "\(count)",
        ])
    }

    /// 音频写入失败日志：前 3 次与每 50 次记录，绝不静默吞错
    private func logAudioAppendFailure(track: AudioTrack, reason: String) {
        switch track {
        case .system: systemAudioAppendFailures += 1
        case .microphone: micAudioAppendFailures += 1
        }
        let count = track == .system ? systemAudioAppendFailures : micAudioAppendFailures
        guard count <= 3 || count % 50 == 0 else { return }
        Log.error(.recording, "recording.mp4.audioAppendFail", [
            "track": track.logName,
            "err": reason,
            "n": "\(count)",
        ])
    }

    // MARK: - 实时音频电平

    /// 写入一包音频的感知电平：与上一快照做轻微平滑保留（`max` + 0.65 衰减），
    /// 避免 15Hz 轮询漏掉短促音节（说话停顿/音节间隙不会瞬间闪成 0）。
    private func recordAudioLevel(_ level: Float, track: AudioTrack) {
        let now = CACurrentMediaTime()
        // 临界区只捕获 Float/CFTimeInterval（均 Sendable）；枚举 switch 放锁外，不把 AudioTrack 带进 @Sendable 闭包
        switch track {
        case .system:
            audioLevelLock.withLock { state in
                state.system = max(level, state.system * 0.65)
                state.systemUpdatedAt = now
            }
        case .microphone:
            audioLevelLock.withLock { state in
                state.microphone = max(level, state.microphone * 0.65)
                state.micUpdatedAt = now
            }
        }
    }

    /// 读取当前电平快照（线程安全，主线程 15Hz 轮询专用）
    ///
    /// - 某轨超过 0.25s 没有新包（系统静音 / 无声输出 / 麦克风静音）直接归零；
    /// - 读完对内部峰值做一次轻微衰减，保证声音结束后迅速自然回落，不会卡在高位。
    func snapshotAudioLevels() -> (system: Float, microphone: Float) {
        let now = CACurrentMediaTime()
        return audioLevelLock.withLock { state in
            if now - state.systemUpdatedAt > 0.25 { state.system = 0 }
            if now - state.micUpdatedAt > 0.25 { state.microphone = 0 }
            let snapshot = (system: state.system, microphone: state.microphone)
            state.system = Self.decayedLevel(state.system)
            state.microphone = Self.decayedLevel(state.microphone)
            return snapshot
        }
    }

    /// 清空电平快照（暂停 / 收尾 / 失败清理）
    private func resetAudioLevels() {
        audioLevelLock.withLock { $0 = AudioLevelState() }
    }

    private static func decayedLevel(_ value: Float) -> Float {
        let decayed = value * 0.72
        return decayed < 0.02 ? 0 : decayed
    }

    /// 计算单个音频包的感知归一化电平（`0.0...1.0`）
    ///
    /// - 只接受 Float32 LPCM（归一化器产物），其它格式安全返回 0，不越界不崩溃；
    /// - 步长 4 跨步抽样求 RMS，再以 dBFS 映射：低于 -54dB 的底噪压成 0，正常语音/音乐落在 0.25~0.90。
    private static func computeNormalizedAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32 else { return 0 }

        // 先探长度再按需分配：AudioBufferList 是柔性数组，不能直接用栈上定长结构接收多平面数据
        var neededSize = 0
        let probeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )
        guard probeStatus == noErr, neededSize >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: neededSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let listPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: neededSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return 0 }
        // 保留的 block buffer 需活到读完样本：显式引用后随作用域由 ARC 释放
        withExtendedLifetime(blockBuffer) {}

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        var sumOfSquares = 0.0
        var sampleCount = 0.0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            // 非交错双声道时每个平面单声道；交错时同平面多声道，两种布局都按 Float 顺序读
            let samples = data.assumingMemoryBound(to: Float.self)
            var index = 0
            while index < floatCount {
                let value = Double(samples[index])
                sumOfSquares += value * value
                sampleCount += 1
                index += 4
            }
        }
        guard sampleCount > 0 else { return 0 }

        let rms = (sumOfSquares / sampleCount).squareRoot()
        let db = 20.0 * log10(max(rms, 1e-6))
        let normalized = (db + 54.0) / 50.0
        return Float(min(1.0, max(0.0, normalized)))
    }

    private func appendGIFFrame(imageBuffer: CVImageBuffer, adjustedPTS: CMTime) {
        guard let image = copyCGImage(from: imageBuffer) else { return }
        if firstThumbnail == nil {
            firstThumbnail = image
        }
        if firstAdjustedPTS == nil {
            firstAdjustedPTS = adjustedPTS
        }
        lastAdjustedVideoPTS = adjustedPTS
        // 立刻脱离 SCStream 回调队列与 IOSurface，把耗时的 GIF 量化写盘丢给独立串行队列
        gifEncodeQueue.async { [self] in
            guard !gifCancelled else { return }
            flushPendingGIF(upTo: adjustedPTS)
            pendingGIFFrame = (image, adjustedPTS)
        }
    }

    /// 立刻拷贝像素数据并解锁 IOSurface（与 ScrollCaptureController 同款），防止占满 SCStream queueDepth 缓冲池导致掉帧
    private func copyCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        let data = Data(bytes: baseAddress, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: srgbColorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func flushPendingGIF(upTo nextPTS: CMTime) {
        guard !gifCancelled, let pending = pendingGIFFrame, let dest = gifDestination else { return }
        let rawDelta = CMTimeSubtract(nextPTS, pending.adjustedPTS).seconds
        let clamped = max(gifMinDelay, min(10.0, rawDelta.isFinite ? rawDelta : gifMinDelay))
        // GIF 规范按 1/100 秒存储延迟，低于 0.02s 部分浏览器会强制按 0.1s 降速
        let quantized = max(0.02, (clamped * 100.0).rounded() / 100.0)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: quantized,
                kCGImagePropertyGIFUnclampedDelayTime: quantized,
            ],
        ]
        CGImageDestinationAddImage(dest, pending.image, frameProps as CFDictionary)
        pendingGIFFrame = nil
        gifWrittenFrames += 1
    }

    // MARK: - 收尾（mediaQueue）

    private func finalizeMP4(
        endPTS: CMTime,
        duration: TimeInterval,
        continuation: CheckedContinuation<RecordingResult, Error>
    ) {
        guard let writer = assetWriter else {
            continuation.resume(throwing: SCKScreenRecorder.RecorderError.emptyRecording)
            return
        }
        resetAudioLevels()
        guard sessionStarted, writtenFrames > 0 else {
            writer.cancelWriting()
            audioMixer?.reset()
            audioMixer = nil
            mixedAudioInput = nil
            resumeMinRawPTS = nil
            systemAudioNormalizer.reset()
            micAudioNormalizer.reset()
            try? FileManager.default.removeItem(at: request.outputURL)
            continuation.resume(throwing: SCKScreenRecorder.RecorderError.emptyRecording)
            return
        }

        // 1) 先算「视频口径」的结束点（逻辑同原 safeEndPTS，确保严格大于最后一帧）
        let candidateEndPTS: CMTime
        if let last = lastAdjustedVideoPTS, CMTimeCompare(endPTS, last) > 0 {
            candidateEndPTS = endPTS
        } else if let last = lastAdjustedVideoPTS {
            candidateEndPTS = CMTimeAdd(last, CMTime(value: 1, timescale: CMTimeScale(max(1, request.options.effectiveFPS))))
        } else {
            candidateEndPTS = endPTS
        }

        // 2) 混音模式：收尾前把 mixer 里还压着的音频一次冲刷出来（不足部分由 mixer 补静音块）
        if isDualAudioMixing, writer.status == .writing, let mixer = audioMixer {
            writeMixedAudioChunks(mixer.flushFinal(upTo: candidateEndPTS))
        }

        // 3) 最终结束点 = max(视频口径, 混音器已吐出的结束点, 单轨音频结束点)，保证音轨尾巴不被 endSession 截掉
        var safeEndPTS = candidateEndPTS
        if let mixedEnd = audioMixer?.lastEmittedEndPTS, CMTimeCompare(mixedEnd, safeEndPTS) > 0 {
            safeEndPTS = mixedEnd
        }
        if let singleEnd = lastSingleAudioEndPTS, CMTimeCompare(singleEnd, safeEndPTS) > 0 {
            safeEndPTS = singleEnd
        }

        // 静止画面补尾帧：最后一帧与结束时间相差超过 0.12s 时，用最近一帧的副本撑到 safeEndPTS，
        // 否则静止屏幕录 5 秒输出只有 1 帧（时长≈0）
        if writer.status == .writing,
           let last = lastAdjustedVideoPTS,
           CMTimeSubtract(safeEndPTS, last).seconds > 0.12,
           let sample = lastMP4VideoSample,
           let vInput = videoInput,
           vInput.isReadyForMoreMediaData,
           let tailSample = copySampleBuffer(sample, withPTS: safeEndPTS) {
            if vInput.append(tailSample) {
                writtenFrames += 1
            } else {
                Log.error(.recording, "recording.mp4.appendFail", [
                    "err": writer.error?.localizedDescription ?? "unknown",
                ])
            }
        }
        lastMP4VideoSample = nil

        // 混音器统计必须在 reset() 之前取出来，供收尾日志定位丢包/延迟/削顶
        let mixerStats = audioMixer?.stats
        let audioMode = audioModeName
        let mixedChunks = mixedAudioPacketsWritten
        let resumeDrops = resumeDroppedAudioPackets + resumeDroppedVideoFrames

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()
        mixedAudioInput?.markAsFinished()
        writer.endSession(atSourceTime: safeEndPTS)

        // 混音器与滞留阀门随本次会话一起销毁
        audioMixer?.reset()
        audioMixer = nil
        mixedAudioInput = nil
        lastMixedAudioPTS = nil
        resumeMinRawPTS = nil

        let url = request.outputURL
        let width = targetWidth
        let height = targetHeight
        let frames = writtenFrames
        let sysPkts = isDualAudioMixing ? (mixerStats?.sysPacketsPushed ?? systemAudioPacketsWritten) : systemAudioPacketsWritten
        let micPkts = isDualAudioMixing ? (mixerStats?.micPacketsPushed ?? micAudioPacketsWritten) : micAudioPacketsWritten
        let silenceChunks = mixerStats?.silenceFallbackChunks ?? 0
        let lateDrops = mixerStats?.latePacketsDropped ?? 0
        let clipped = mixerStats?.clippedSamples ?? 0
        let thumb = firstThumbnail
        let isTemp = request.isTemporaryFile

        // 音频转换器随本次会话一起销毁，避免持有已失效的源格式
        systemAudioNormalizer.reset()
        micAudioNormalizer.reset()

        nonisolated(unsafe) let finishedWriter = writer
        writer.finishWriting {
            if finishedWriter.status == .completed {
                let bytes = Self.fileSize(at: url)
                Log.event(.recording, "recording.mp4.finalize", [
                    "frames": "\(frames)",
                    "duration": String(format: "%.2f", duration),
                    "bytes": "\(bytes)",
                    "sysAudioPkts": "\(sysPkts)",
                    "micAudioPkts": "\(micPkts)",
                    "audioMode": audioMode,
                    "mixedChunks": "\(mixedChunks)",
                    "silenceChunks": "\(silenceChunks)",
                    "lateDrops": "\(lateDrops)",
                    "resumeDrops": "\(resumeDrops)",
                    "clipped": "\(clipped)",
                ])
                continuation.resume(returning: RecordingResult(
                    format: .mp4,
                    fileURL: url,
                    pixelWidth: width,
                    pixelHeight: height,
                    duration: duration,
                    fileSizeBytes: bytes,
                    frameCount: frames,
                    thumbnail: thumb,
                    isTemporaryFile: isTemp
                ))
            } else {
                let err = finishedWriter.error ?? SCKScreenRecorder.RecorderError.invalidWriter("finishWriting 失败")
                continuation.resume(throwing: err)
            }
        }
    }

    /// 用新的 presentation timestamp 复制一份样本（补尾帧专用，不改动原始样本）
    private func copySampleBuffer(_ sampleBuffer: CMSampleBuffer, withPTS pts: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }

        var infos = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count
        ) == noErr else { return nil }

        let duration = infos[0].duration.isValid
            ? infos[0].duration
            : CMTime(value: 1, timescale: CMTimeScale(max(1, request.options.effectiveFPS)))
        for i in 0..<infos.count {
            // 关闭重排序后无需 DTS，交给 writer 自行推导
            infos[i].decodeTimeStamp = .invalid
            infos[i].presentationTimeStamp = CMTimeAdd(pts, CMTimeMultiply(duration, multiplier: Int32(i)))
            if !infos[i].duration.isValid {
                infos[i].duration = duration
            }
        }
        var copy: CMSampleBuffer?
        let err = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &copy
        )
        return err == noErr ? copy : nil
    }

    private func finalizeGIF(
        endPTS: CMTime,
        duration: TimeInterval,
        width: Int,
        height: Int,
        thumbnail: CGImage?,
        continuation: CheckedContinuation<RecordingResult, Error>
    ) {
        flushPendingGIF(upTo: endPTS)
        guard !gifCancelled, let dest = gifDestination, gifWrittenFrames > 0 else {
            try? FileManager.default.removeItem(at: request.outputURL)
            continuation.resume(throwing: SCKScreenRecorder.RecorderError.emptyRecording)
            return
        }
        let ok = CGImageDestinationFinalize(dest)
        gifDestination = nil
        guard ok else {
            try? FileManager.default.removeItem(at: request.outputURL)
            continuation.resume(throwing: SCKScreenRecorder.RecorderError.invalidWriter("GIF 封装失败"))
            return
        }
        let bytes = Self.fileSize(at: request.outputURL)
        continuation.resume(returning: RecordingResult(
            format: .gif,
            fileURL: request.outputURL,
            pixelWidth: width,
            pixelHeight: height,
            duration: duration,
            fileSizeBytes: bytes,
            frameCount: gifWrittenFrames,
            thumbnail: thumbnail,
            isTemporaryFile: request.isTemporaryFile
        ))
    }

    private func shiftSampleBufferTime(_ sampleBuffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }

        var infos = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count
        ) == noErr else { return nil }

        for i in 0..<infos.count {
            if infos[i].presentationTimeStamp.isValid {
                infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            }
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        let err = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &copy
        )
        return err == noErr ? copy : nil
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let num = attrs[.size] as? NSNumber else { return 0 }
        return num.int64Value
    }
}

private final class StreamDelegateProxy: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var owner: ActiveSession?

    init(owner: ActiveSession) {
        self.owner = owner
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        owner?.handleSampleBuffer(sampleBuffer, of: type)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owner?.handleStreamError(error)
    }
}
