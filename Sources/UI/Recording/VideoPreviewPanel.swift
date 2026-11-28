import AppKit
@preconcurrency import AVFoundation
import CoreMedia

/// 内置 MP4 视频预览窗（替代不播视频的 macOS 原生预览 App）
///
/// 设计（与 `GIFPreviewPanel` 同一套 Apple HUD 视觉语言）：
/// - 居中于当前鼠标所在屏幕，深色磨砂玻璃卡片 + 双层光学阴影（`.spotlight` / margin 24 / r16）；
/// - `AVPlayer` + `AVPlayerLayer(videoGravity: .resizeAspect)` 承载画面，打开即自动播放并无缝循环；
/// - 舞台与底栏之间是自绘胶囊进度条（点击 / 拖拽实时 seek），时间读数走 tabular-nums；
/// - 进度条两端各一枚裁剪柄：拖左/右柄定头尾，播放头与循环播放都收进 `[start, end]`，
///   被裁掉的两端用暗化遮罩表达「这段不要」，双击柄一键复位；
/// - 底栏「暂停/播放 · 静音/有声 · 应用裁剪（仅已裁剪时出现）· 转 GIF · 复制文件 · 访达 · 丢弃」；
/// - 快捷键（仅窗口可见且为 keyWindow 时生效）：空格播放/暂停、`Esc` 关闭、`←/→` 快退/快进 2s、`M` 静音；
/// - `cleanUpPlayer()` 在关闭、「丢弃」以及**原地裁剪替换前**必定先行，确保 mp4 文件句柄立即
///   释放——否则导出的新文件写不进去、磁盘删除也绝不成功。
@MainActor
final class VideoPreviewPanel: NSPanel {
    static let shared = VideoPreviewPanel()

    struct Callbacks {
        var onCopyFile: (URL) -> Void
        var onRevealInFinder: (URL) -> Void
        var onDiscard: (URL) -> Void
        /// 头尾裁剪：拿 `[range]` 段换一个新文件（可原地原子替换），返回裁剪后的结果
        var onTrim: ((RecordingResult, VideoTrimRange) async throws -> RecordingResult)? = nil
        /// 按当前裁剪区间转 GIF，进度回调 0...1（可能来自后台线程，消费方自行 hop 回主线程）
        var onConvertToGIF: (
            (RecordingResult, VideoTrimRange, @escaping @Sendable (Double) -> Void) async throws -> RecordingResult
        )? = nil
        /// 转好 GIF 后直接打开内置 GIF 预览（本窗此时已 dismiss）
        var onOpenGIFPreview: ((RecordingResult) -> Void)? = nil
    }

    /// 卡片几何（header 44 + stage + scrubber 34 + footer 50，间隙固定 8pt 栅格里的小档）
    private enum Metrics {
        static let shadowMargin: CGFloat = 24
        static let cornerRadius: CGFloat = 16
        static let headerHeight: CGFloat = 44
        static let stageTopGap: CGFloat = 12
        static let stageScrubberGap: CGFloat = 10
        static let scrubberHeight: CGFloat = 34
        static let scrubberFooterGap: CGFloat = 6
        static let footerHeight: CGFloat = 50
        static let contentInset: CGFloat = 14
        /// header + 间隙 + scrubber + 间隙 + footer，即卡片除舞台外的高度
        static let chromeHeight: CGFloat =
            headerHeight + stageTopGap + stageScrubberGap + scrubberHeight + scrubberFooterGap + footerHeight
        /// 底栏加到 7 枚按钮后 420 会挤成一行省略号，560 才排得下且留出弹性留白
        static let minCardWidth: CGFloat = 560
        static let minStageHeight: CGFloat = 180
        static let stageCornerRadius: CGFloat = 10
    }

    private var currentResult: RecordingResult?
    private var callbacks: Callbacks?
    private var keyMonitor: Any?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var isPlaying = false

    /// 当前裁剪区间（打开即整段；拖柄 / 复位都走领域值，越界与「两端重合」在构造时已被合法化）
    private var trimRange: VideoTrimRange = .full(duration: 0)
    private var isProcessing = false
    private var processingTask: Task<Void, Never>?
    /// 转 GIF 前是否在播放：成功就切走预览窗，失败要恢复成用户交过来的样子
    private var wasPlayingBeforeProcessing = false
    private var lastGIFPercent = -1
    /// 区间循环补 seek 期间屏蔽重复 seek（周期回调比 seek 完成快得多，不挡会疯狂重发）
    private var isLoopSeeking = false

    private let outerView = VideoPreviewOuterView()
    private let cardRoot = NSView()
    private let outerShadowView = OuterShadowView(
        spec: .spotlight,
        margin: Metrics.shadowMargin,
        cornerRadius: Metrics.cornerRadius
    )
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let currentTimeLabel = NSTextField(labelWithString: "00:00")
    private let durationLabel = NSTextField(labelWithString: "00:00")
    private let stageView = VideoPreviewStageView(frame: .zero)
    private let scrubberTrack = VideoPreviewScrubberTrack(frame: .zero)
    private var stageHeightConstraint: NSLayoutConstraint!
    private var playPauseBtn: VideoPreviewPillButton!
    private var muteBtn: VideoPreviewPillButton!
    private var applyTrimBtn: VideoPreviewPillButton!
    private var gifBtn: VideoPreviewPillButton!
    /// 处理中要整体置灰的按钮（「转 GIF」不在此列：它就是进度读数本身）
    private var disableDuringProcessing: [VideoPreviewPillButton] = []

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        buildUI()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - 展示 / 关闭

    func show(result: RecordingResult, callbacks: Callbacks) {
        cleanUpPlayer()
        cancelProcessing()

        self.currentResult = result
        self.callbacks = callbacks
        self.trimRange = .full(duration: max(0, result.duration))

        applyFrame(for: result)
        titleLabel.stringValue = result.fileURL.lastPathComponent
        metaLabel.stringValue =
            "\(result.pixelWidth)×\(result.pixelHeight) · \(result.formattedDuration) · \(result.formattedSize)"
        durationLabel.stringValue = result.formattedDuration
        durationLabel.textColor = DesignTokens.label2
        currentTimeLabel.stringValue = "00:00"
        scrubberTrack.setTrimFractions(start: 0, end: 1)
        scrubberTrack.setProgress(0, force: true)
        syncTrimUI()
        syncActionButtons()

        startPlayback(url: result.fileURL)

        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            animator().alphaValue = 1
        }
        Log.event(.recording, "recording.videoPreview.open", [
            "px": "\(result.pixelWidth)x\(result.pixelHeight)",
            "duration": String(format: "%.2f", result.duration),
        ])
    }

    func dismiss() {
        removeKeyMonitor()
        cancelProcessing()
        // 关键：先释放 AVPlayer 与文件句柄，再 orderOut（否则「丢弃」删盘会撞上未释放的 mp4）
        cleanUpPlayer()
        scrubberTrack.setProgress(0, force: true)
        scrubberTrack.setTrimFractions(start: 0, end: 1)
        currentTimeLabel.stringValue = "00:00"
        durationLabel.stringValue = "00:00"
        durationLabel.textColor = DesignTokens.label2
        trimRange = .full(duration: 0)
        orderOut(nil)
        currentResult = nil
        callbacks = nil
    }

    /// 取消在途的裁剪/转 GIF（窗口关闭、换片、丢弃都要叫一遍）
    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        lastGIFPercent = -1
        gifBtn?.update(symbol: "film", title: "转 GIF")
        syncActionButtons()
    }

    /// 按录制像素与屏幕可见区域自适应卡片尺寸，居中于鼠标所在屏幕
    private func applyFrame(for result: RecordingResult) {
        let screen = DisplayRegistry.screenAtMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let backing = max(1, screen.backingScaleFactor)

        let rawW = max(1, CGFloat(result.pixelWidth))
        let rawH = max(1, CGFloat(result.pixelHeight))
        // 2x 原画质录制按逻辑尺寸起始展示；小尺寸录制按 1:1 展示并允许适度放大到易读尺寸
        let logicalW = rawW > visible.width * 0.7 ? rawW / backing : rawW
        let logicalH = rawH > visible.height * 0.65 ? rawH / backing : rawH

        let m = Metrics.shadowMargin
        // 舞台上限：既要留出 chrome（header + scrubber + footer）与双层阴影留白，也留一圈呼吸
        let maxStageW = max(160, min(visible.width * 0.68, visible.width - m * 2 - Metrics.contentInset * 2 - 48))
        let maxStageH = max(120, min(visible.height * 0.62,
                                      visible.height - m * 2 - Metrics.chromeHeight - 32))

        let fitScale = min(1.0, min(maxStageW / logicalW, maxStageH / logicalH))
        let stageW = max(Metrics.minCardWidth - Metrics.contentInset * 2, (logicalW * fitScale).rounded())
        let stageH = max(Metrics.minStageHeight, (logicalH * fitScale).rounded())

        let cardW = max(Metrics.minCardWidth, stageW + Metrics.contentInset * 2)
        let cardH = stageH + Metrics.chromeHeight
        let totalSize = CGSize(width: cardW + m * 2, height: cardH + m * 2)

        let origin = DisplayRegistry.centerOrigin(for: totalSize, on: screen)
        setFrame(CGRect(origin: origin, size: totalSize), display: true)
        stageHeightConstraint.constant = stageH
    }

    // MARK: - 播放器生命周期

    private func startPlayback(url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.isMuted = false

        self.player = player
        self.playerItem = item
        isLoopSeeking = false

        stageView.playerLayer.player = player
        stageView.playerLayer.videoGravity = .resizeAspect

        installTimeObserver(on: player)
        installEndObserver(on: item)

        player.play()
        isPlaying = true
        syncPlaybackButtons()
    }

    /// 周期刷新进度（主队列回调 → 主 actor 桥接）；拖拽期间跳过，避免与手写 seek 打架
    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            MainActor.assumeIsolated {
                self?.handleTimeTick(seconds: seconds)
            }
        }
    }

    private func installEndObserver(on item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartFromBeginning()
            }
        }
    }

    /// 释放播放器与全部观察者（句柄必须在这里彻底放掉）
    private func cleanUpPlayer() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        stageView.playerLayer.player = nil
        player = nil
        playerItem = nil
        isPlaying = false
    }

    // MARK: - 播放控制

    private func handleTimeTick(seconds: Double) {
        guard !scrubberTrack.isDragging else { return }
        let duration = effectiveDuration
        guard seconds.isFinite, duration > 0 else { return }

        // 区间循环：播到裁剪终点前一点点就无缝跳回起点（比等 didPlayToEnd 快得多，
        // 也保证「裁掉尾段后不会黑屏停住」）
        if trimRange.isTrimmed, seconds >= trimRange.end - 0.03 {
            if !isLoopSeeking {
                isLoopSeeking = true
                player?.seek(
                    to: CMTime(seconds: trimRange.start, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                currentTimeLabel.stringValue = RecordingGeometry.formatDuration(trimRange.start)
                scrubberTrack.setProgress(trimRange.startFraction, force: true)
            }
            return
        }
        isLoopSeeking = false

        let clamped = trimRange.isTrimmed
            ? trimRange.clampingTime(seconds)
            : min(max(seconds, 0), duration)
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(clamped)
        scrubberTrack.setProgress(duration > 0 ? clamped / duration : 0)
    }

    private func restartFromBeginning() {
        guard let player else { return }
        let start = trimRange.isTrimmed ? trimRange.start : 0
        player.seek(
            to: CMTime(seconds: start, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
        isPlaying = true
        syncPlaybackButtons()
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(start)
        scrubberTrack.setProgress(trimRange.isTrimmed ? trimRange.startFraction : 0, force: true)
    }

    private func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // 播到尾再按播放：从头开始，别让用户以为按钮坏了
            let duration = effectiveDuration
            let current = CMTimeGetSeconds(player.currentTime())
            let boundary = trimRange.isTrimmed ? trimRange.end : duration
            if duration > 0, current.isFinite, current >= boundary - 0.05 {
                let start = trimRange.isTrimmed ? trimRange.start : 0
                player.seek(
                    to: CMTime(seconds: start, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                currentTimeLabel.stringValue = RecordingGeometry.formatDuration(start)
                scrubberTrack.setProgress(trimRange.isTrimmed ? trimRange.startFraction : 0, force: true)
            }
            player.play()
            isPlaying = true
        }
        syncPlaybackButtons()
    }

    private func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
        syncPlaybackButtons()
    }

    private func syncPlaybackButtons() {
        playPauseBtn?.update(
            symbol: isPlaying ? "pause.fill" : "play.fill",
            title: isPlaying ? "暂停" : "播放"
        )
        let muted = player?.isMuted ?? false
        muteBtn?.update(
            symbol: muted ? "speaker.wave.2" : "speaker.slash",
            title: muted ? "有声" : "静音"
        )
    }

    private var effectiveDuration: Double {
        guard let result = currentResult else { return 0 }
        if let itemDuration = playerItem?.duration,
           itemDuration.isNumeric,
           CMTimeGetSeconds(itemDuration).isFinite,
           CMTimeGetSeconds(itemDuration) > 0 {
            return CMTimeGetSeconds(itemDuration)
        }
        return max(0, result.duration)
    }

    // MARK: - 进度控制

    private func seek(toFraction fraction: Double) {
        guard let player else { return }
        let duration = effectiveDuration
        guard duration > 0 else { return }
        // 播放头始终只能落在有效区间内（未裁剪时就是 0...1，保持原有手感）
        let clamped = min(max(fraction, trimRange.startFraction), trimRange.endFraction)
        let target = clamped * duration
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(target)
        scrubberTrack.setProgress(clamped, force: true)
    }

    /// 拖裁剪柄时预览「精确起始 / 结束帧」（按秒定位，不走归一化以免求回时抖动）
    private func seek(toTime seconds: TimeInterval) {
        guard let player else { return }
        let duration = effectiveDuration
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(clamped)
        scrubberTrack.setProgress(duration > 0 ? clamped / duration : 0, force: true)
    }

    private func seek(byDelta delta: Double) {
        guard let player else { return }
        let duration = effectiveDuration
        let current = CMTimeGetSeconds(player.currentTime())
        let base = current.isFinite ? max(0, current) : 0
        let lower = trimRange.isTrimmed ? trimRange.start : 0
        let upper = trimRange.isTrimmed ? trimRange.end : max(duration, 0)
        let target = min(max(base + delta, lower), upper)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(target)
        scrubberTrack.setProgress(duration > 0 ? target / duration : 0, force: true)
    }

    // MARK: - 裁剪区间 UI

    /// 把 `trimRange` 同步到进度条与时长读数（拖柄、重置、裁完、失败恢复都走这一个口）
    private func syncTrimUI() {
        scrubberTrack.setTrimFractions(start: trimRange.startFraction, end: trimRange.endFraction)
        updateTimeReadout()
        let shouldHide = !trimRange.isTrimmed
        if applyTrimBtn.isHidden != shouldHide {
            applyTrimBtn.isHidden = shouldHide
        }
        if !isProcessing {
            applyTrimBtn.update(symbol: "scissors", title: "应用裁剪")
        }
    }

    /// 右侧时长读数保持定宽（绝不挤压进度条），裁剪区间读数优雅放到顶栏 metaLabel
    private func updateTimeReadout() {
        guard let result = currentResult else {
            durationLabel.stringValue = "00:00"
            return
        }
        if trimRange.isTrimmed {
            let start = RecordingGeometry.formatPreciseTime(trimRange.start)
            let end = RecordingGeometry.formatPreciseTime(trimRange.end)
            durationLabel.stringValue = RecordingGeometry.formatDuration(trimRange.trimmedDuration)
            durationLabel.textColor = DesignTokens.label1
            metaLabel.stringValue =
                "\(start) – \(end) · 保留 \(String(format: "%.1fs", trimRange.trimmedDuration))"
            metaLabel.textColor = DesignTokens.label1
        } else {
            durationLabel.stringValue = result.formattedDuration
            durationLabel.textColor = DesignTokens.label2
            metaLabel.stringValue =
                "\(result.pixelWidth)×\(result.pixelHeight) · \(result.formattedDuration) · \(result.formattedSize)"
            metaLabel.textColor = DesignTokens.label2
        }
    }

    /// 处理中的按钮态（防重入靠 `isProcessing` + 置灰两层）
    private func syncActionButtons() {
        for btn in disableDuringProcessing {
            btn.setEnabled(!isProcessing)
        }
        scrubberTrack.isInteractionEnabled = !isProcessing
    }

    // MARK: - 头尾裁剪 / 转 GIF

    private func performTrim() {
        guard !isProcessing,
              trimRange.isTrimmed,
              let result = currentResult,
              let onTrim = callbacks?.onTrim
        else { return }

        let range = trimRange
        isProcessing = true
        isLoopSeeking = false
        // 关键：原地替换 MP4 前必须放掉 AVPlayer/AVPlayerItem 持有的文件句柄，
        // 否则导出会话拿不到可写的文件（表现为导出失败或旧帧残留）
        cleanUpPlayer()
        syncPlaybackButtons()
        applyTrimBtn.update(symbol: "scissors", title: "裁剪中…")
        syncActionButtons()
        Log.event(.recording, "recording.videoPreview.trim.start", [
            "start": String(format: "%.2f", range.start),
            "end": String(format: "%.2f", range.end),
        ])

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trimmed = try await onTrim(result, range)
                guard !Task.isCancelled else { return }
                self.finishTrim(trimmed: trimmed)
            } catch {
                guard !Task.isCancelled else { return }
                self.failTrim(error: error, original: result)
            }
        }
    }

    private func finishTrim(trimmed: RecordingResult) {
        isProcessing = false
        processingTask = nil
        currentResult = trimmed
        trimRange = .full(duration: max(0, trimmed.duration))

        titleLabel.stringValue = trimmed.fileURL.lastPathComponent
        metaLabel.stringValue =
            "\(trimmed.pixelWidth)×\(trimmed.pixelHeight) · \(trimmed.formattedDuration) · \(trimmed.formattedSize)"
        currentTimeLabel.stringValue = "00:00"
        scrubberTrack.setTrimFractions(start: 0, end: 1)
        scrubberTrack.setProgress(0, force: true)
        durationLabel.stringValue = trimmed.formattedDuration
        durationLabel.textColor = DesignTokens.label2

        startPlayback(url: trimmed.fileURL)
        syncTrimUI()
        syncActionButtons()
        CaptureToast.show(message: "已裁剪视频（\(trimmed.formattedDuration)）", status: .ok)
        // 事件名与适配器的 `recording.trim.ok` 错开：一个是「用户点了裁剪」，
        // 一个是「导出写盘成功」，同名字会让排查时少一半信息
        Log.event(.recording, "recording.videoPreview.trim.ok", [
            "duration": String(format: "%.2f", trimmed.duration),
            "bytes": "\(trimmed.fileSizeBytes)",
        ])
    }

    private func failTrim(error: Error, original: RecordingResult) {
        isProcessing = false
        processingTask = nil
        // 失败时原文件没变（适配器先写临时文件再原子替换），恢复播放原片，别留黑屏
        startPlayback(url: original.fileURL)
        syncTrimUI()
        syncActionButtons()
        CaptureToast.show(message: "裁剪失败：\(error.localizedDescription)", status: .warn)
        Log.error(.recording, "recording.videoPreview.trim.fail", ["err": error.localizedDescription])
    }

    private func performConvertToGIF() {
        guard !isProcessing,
              let result = currentResult,
              let onConvert = callbacks?.onConvertToGIF
        else { return }

        let range = trimRange
        // 硬上限提前温柔拦截（不暂停播放、不闪按钮态），直接引导用户拖两端裁剪柄
        if range.trimmedDuration > GIFConversionOptions.maxDurationSeconds + GIFConversionOptions.durationToleranceSeconds {
            let cur = RecordingGeometry.formatDuration(range.trimmedDuration)
            CaptureToast.show(
                message: "GIF 最长支持 \(Int(GIFConversionOptions.maxDurationSeconds)) 秒，请先拖动进度条两端裁剪片段（当前 \(cur)）",
                status: .warn
            )
            Log.event(.recording, "recording.convertGIF.tooLong", [
                "duration": String(format: "%.2f", range.trimmedDuration),
            ])
            return
        }
        isProcessing = true
        lastGIFPercent = -1
        wasPlayingBeforeProcessing = isPlaying
        player?.pause()
        isPlaying = false
        syncPlaybackButtons()
        gifBtn.update(symbol: "film", title: "转 GIF 0%")
        syncActionButtons()

        // 进度回调可能来自后台线程：hop 回主 actor 再刷按钮标题
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.updateGIFProgress(fraction)
            }
        }

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let gifResult = try await onConvert(result, range, progress)
                guard !Task.isCancelled else { return }
                self.finishGIFConversion(result: gifResult)
            } catch {
                guard !Task.isCancelled else { return }
                self.failGIFConversion(error: error)
            }
        }
    }

    private func updateGIFProgress(_ fraction: Double) {
        guard isProcessing else { return }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        guard percent != lastGIFPercent else { return }
        lastGIFPercent = percent
        gifBtn.update(symbol: "film", title: "转 GIF \(percent)%")
    }

    private func finishGIFConversion(result gifResult: RecordingResult) {
        isProcessing = false
        processingTask = nil
        lastGIFPercent = -1
        gifBtn.update(symbol: "film", title: "转 GIF")
        syncActionButtons()
        Log.event(.recording, "recording.convertGIF.ok", [
            "bytes": "\(gifResult.fileSizeBytes)",
            "frames": "\(gifResult.frameCount)",
        ])

        // dismiss() 会清掉 callbacks，先取出来再关窗
        let openPreview = callbacks?.onOpenGIFPreview
        dismiss()
        openPreview?(gifResult)
        CaptureToast.show(message: "已转存 GIF（\(gifResult.formattedSize)）", status: .ok)
    }

    private func failGIFConversion(error: Error) {
        isProcessing = false
        processingTask = nil
        lastGIFPercent = -1
        gifBtn.update(symbol: "film", title: "转 GIF")
        syncActionButtons()
        if wasPlayingBeforeProcessing, let player {
            player.play()
            isPlaying = true
            syncPlaybackButtons()
        }
        CaptureToast.show(message: "转 GIF 失败：\(error.localizedDescription)", status: .warn)
        Log.error(.recording, "recording.convertGIF.fail", ["err": error.localizedDescription])
    }

    // MARK: - 底部操作

    private func performCopyFile() {
        guard let url = currentResult?.fileURL else { return }
        callbacks?.onCopyFile(url)
        dismiss()
    }

    private func performReveal() {
        guard let url = currentResult?.fileURL else { return }
        callbacks?.onRevealInFinder(url)
        dismiss()
    }

    private func performDiscard() {
        guard let url = currentResult?.fileURL else { return }
        // 先放掉 AVPlayer/AVPlayerItem 持有的 mp4 句柄，再让上层删盘——顺序反了删除会失败
        cleanUpPlayer()
        callbacks?.onDiscard(url)
        dismiss()
    }

    // MARK: - UI

    private func buildUI() {
        let m = Metrics.shadowMargin
        outerView.wantsLayer = true
        outerView.cardRootView = cardRoot

        outerShadowView.translatesAutoresizingMaskIntoConstraints = false
        outerView.addSubview(outerShadowView)

        cardRoot.wantsLayer = true
        cardRoot.translatesAutoresizingMaskIntoConstraints = false
        outerView.addSubview(cardRoot)

        let glass = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: Metrics.cornerRadius
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        cardRoot.addSubview(glass)

        // MARK: 顶部栏
        titleLabel.font = DesignTokens.Font.head
        titleLabel.textColor = DesignTokens.label1
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = DesignTokens.Font.monoDigit(11)
        metaLabel.textColor = DesignTokens.label2
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = VideoPreviewCloseButton { [weak self] in
            self?.dismiss()
        }
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        let topDivider = makeDivider()

        // MARK: 视频舞台
        let stageBg = NSView()
        stageBg.wantsLayer = true
        stageBg.layer?.cornerRadius = Metrics.stageCornerRadius
        stageBg.layer?.cornerCurve = .continuous
        stageBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        stageBg.layer?.borderWidth = 0.5
        stageBg.layer?.borderColor = DesignTokens.stroke.cgColor
        stageBg.translatesAutoresizingMaskIntoConstraints = false

        stageView.playerLayer.videoGravity = .resizeAspect
        stageView.onTap = { [weak self] in
            self?.togglePlayPause()
        }
        stageView.translatesAutoresizingMaskIntoConstraints = false
        stageBg.addSubview(stageView)

        // MARK: 进度控制条
        let scrubberRow = NSView()
        scrubberRow.translatesAutoresizingMaskIntoConstraints = false

        for label in [currentTimeLabel, durationLabel] {
            label.font = DesignTokens.Font.monoDigit(11)
            label.textColor = DesignTokens.label2
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        currentTimeLabel.alignment = .left
        durationLabel.alignment = .right
        currentTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        scrubberTrack.onScrubStart = { [weak self] in
            // 拖拽期间屏蔽周期刷新（VideoPreviewScrubberTrack.isDragging 已是 true）
            self?.currentTimeLabel.textColor = DesignTokens.label1
        }
        scrubberTrack.onScrub = { [weak self] fraction in
            self?.seek(toFraction: fraction)
        }
        scrubberTrack.onScrubEnd = { [weak self] in
            self?.currentTimeLabel.textColor = DesignTokens.label2
        }
        scrubberTrack.onTrimStartDrag = { [weak self] fraction in
            guard let self else { return }
            self.trimRange = self.trimRange.updatingStartFraction(fraction)
            self.syncTrimUI()
            // 拖到哪就看到哪帧：直接 seek 到新起点，裁前先确认「头没切多」
            self.seek(toTime: self.trimRange.start)
        }
        scrubberTrack.onTrimEndDrag = { [weak self] fraction in
            guard let self else { return }
            self.trimRange = self.trimRange.updatingEndFraction(fraction)
            self.syncTrimUI()
            self.seek(toTime: self.trimRange.end)
        }
        scrubberTrack.onTrimDragEnd = { [weak self] in
            guard let self else { return }
            self.currentTimeLabel.textColor = DesignTokens.label2
            self.syncTrimUI()
        }
        scrubberTrack.onTrimReset = { [weak self] in
            guard let self, let result = self.currentResult else { return }
            self.trimRange = .full(duration: max(0, result.duration))
            self.syncTrimUI()
            self.seek(toTime: 0)
        }
        scrubberTrack.translatesAutoresizingMaskIntoConstraints = false

        scrubberRow.addSubview(currentTimeLabel)
        scrubberRow.addSubview(scrubberTrack)
        scrubberRow.addSubview(durationLabel)

        // MARK: 底部栏
        let bottomDivider = makeDivider()

        playPauseBtn = VideoPreviewPillButton(symbol: "pause.fill", title: "暂停", style: .normal) { [weak self] in
            self?.togglePlayPause()
        }
        muteBtn = VideoPreviewPillButton(symbol: "speaker.slash", title: "静音", style: .normal) { [weak self] in
            self?.toggleMute()
        }
        // 「应用裁剪」只在真的拖了柄之后出现，平时不占位也不诱发误点
        applyTrimBtn = VideoPreviewPillButton(symbol: "scissors", title: "应用裁剪", style: .primary) {
            [weak self] in
            self?.performTrim()
        }
        applyTrimBtn.isHidden = true
        gifBtn = VideoPreviewPillButton(symbol: "film", title: "转 GIF", style: .normal) { [weak self] in
            self?.performConvertToGIF()
        }
        let copyBtn = VideoPreviewPillButton(symbol: "doc.on.doc", title: "复制文件", style: .primary) { [weak self] in
            self?.performCopyFile()
        }
        let finderBtn = VideoPreviewPillButton(symbol: "folder", title: "访达", style: .normal) { [weak self] in
            self?.performReveal()
        }
        let discardBtn = VideoPreviewPillButton(symbol: "trash", title: "丢弃", style: .destructive) {
            [weak self] in
            self?.performDiscard()
        }
        disableDuringProcessing = [playPauseBtn, muteBtn, applyTrimBtn, copyBtn, finderBtn, discardBtn]

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // 弹性留白：按钮行变宽（「应用裁剪」出现）时先挤它，别去挤按钮文字
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footerStack = NSStackView(views: [
            playPauseBtn, muteBtn, spacer, applyTrimBtn, gifBtn, copyBtn, finderBtn, discardBtn,
        ])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 7
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        glass.addSubview(titleLabel)
        glass.addSubview(metaLabel)
        glass.addSubview(closeBtn)
        glass.addSubview(topDivider)
        glass.addSubview(stageBg)
        glass.addSubview(scrubberRow)
        glass.addSubview(bottomDivider)
        glass.addSubview(footerStack)

        stageHeightConstraint = stageBg.heightAnchor.constraint(equalToConstant: 260)

        NSLayoutConstraint.activate([
            outerShadowView.leadingAnchor.constraint(equalTo: outerView.leadingAnchor),
            outerShadowView.trailingAnchor.constraint(equalTo: outerView.trailingAnchor),
            outerShadowView.topAnchor.constraint(equalTo: outerView.topAnchor),
            outerShadowView.bottomAnchor.constraint(equalTo: outerView.bottomAnchor),

            cardRoot.leadingAnchor.constraint(equalTo: outerView.leadingAnchor, constant: m),
            cardRoot.trailingAnchor.constraint(equalTo: outerView.trailingAnchor, constant: -m),
            cardRoot.topAnchor.constraint(equalTo: outerView.topAnchor, constant: m),
            cardRoot.bottomAnchor.constraint(equalTo: outerView.bottomAnchor, constant: -m),

            glass.leadingAnchor.constraint(equalTo: cardRoot.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: cardRoot.trailingAnchor),
            glass.topAnchor.constraint(equalTo: cardRoot.topAnchor),
            glass.bottomAnchor.constraint(equalTo: cardRoot.bottomAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -12),
            closeBtn.topAnchor.constraint(equalTo: glass.topAnchor, constant: 10),
            closeBtn.widthAnchor.constraint(equalToConstant: 24),
            closeBtn.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),

            metaLabel.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -10),
            metaLabel.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),

            topDivider.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: glass.topAnchor, constant: Metrics.headerHeight),
            topDivider.heightAnchor.constraint(equalToConstant: 0.5),

            stageBg.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Metrics.contentInset),
            stageBg.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Metrics.contentInset),
            stageBg.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: Metrics.stageTopGap),
            stageHeightConstraint,

            stageView.leadingAnchor.constraint(equalTo: stageBg.leadingAnchor, constant: 1),
            stageView.trailingAnchor.constraint(equalTo: stageBg.trailingAnchor, constant: -1),
            stageView.topAnchor.constraint(equalTo: stageBg.topAnchor, constant: 1),
            stageView.bottomAnchor.constraint(equalTo: stageBg.bottomAnchor, constant: -1),

            scrubberRow.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Metrics.contentInset),
            scrubberRow.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Metrics.contentInset),
            scrubberRow.topAnchor.constraint(equalTo: stageBg.bottomAnchor, constant: Metrics.stageScrubberGap),
            scrubberRow.heightAnchor.constraint(equalToConstant: Metrics.scrubberHeight),

            currentTimeLabel.leadingAnchor.constraint(equalTo: scrubberRow.leadingAnchor),
            currentTimeLabel.centerYAnchor.constraint(equalTo: scrubberRow.centerYAnchor),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 44),

            durationLabel.trailingAnchor.constraint(equalTo: scrubberRow.trailingAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: scrubberRow.centerYAnchor),
            durationLabel.widthAnchor.constraint(equalToConstant: 44),

            scrubberTrack.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 10),
            scrubberTrack.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -10),
            scrubberTrack.centerYAnchor.constraint(equalTo: scrubberRow.centerYAnchor),
            scrubberTrack.heightAnchor.constraint(equalToConstant: 22),

            bottomDivider.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -Metrics.footerHeight),
            bottomDivider.heightAnchor.constraint(equalToConstant: 0.5),

            footerStack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Metrics.contentInset),
            footerStack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Metrics.contentInset),
            footerStack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -11),
            footerStack.heightAnchor.constraint(equalToConstant: 28),
        ])

        contentView = outerView
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DesignTokens.hair.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
    }

    // MARK: - 快捷键

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isVisible, self.isKeyWindow else { return false }
                return self.handleKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            dismiss()
            return true
        case 49: // Space
            togglePlayPause()
            return true
        case 123: // ←
            seek(byDelta: -2)
            return true
        case 124: // →
            seek(byDelta: 2)
            return true
        case 46 where !event.modifierFlags.contains(.command): // M
            toggleMute()
            return true
        default:
            return false
        }
    }
}

// MARK: - 阴影留白区不吞点击（只有卡片本体响应鼠标）

@MainActor
private final class VideoPreviewOuterView: NSView {
    weak var cardRootView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let root = cardRootView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return root.frame.contains(local) ? super.hitTest(point) : nil
    }
}

// MARK: - 视频舞台（AVPlayerLayer 子层承载画面，圆角裁切 + 单击播放/暂停）

@MainActor
private final class VideoPreviewStageView: NSView {
    let playerLayer = AVPlayerLayer()
    var onTap: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 9
        playerLayer.videoGravity = .resizeAspect
        playerLayer.masksToBounds = true
        playerLayer.cornerCurve = .continuous
        playerLayer.cornerRadius = 9
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("VideoPreviewStageView 只走代码创建") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// 吞掉 mouseDown，避免 isMovableByWindowBackground 把点击当窗口拖拽
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onTap?()
        }
    }
}

// MARK: - 自绘胶囊进度滑块（点击 / 拖拽实时 seek）

@MainActor
private final class VideoPreviewScrubberTrack: NSView {
    var onScrubStart: (() -> Void)?
    /// fraction ∈ 0...1
    var onScrub: ((Double) -> Void)?
    var onScrubEnd: (() -> Void)?
    /// 拖左裁剪柄（新起点 fraction）
    var onTrimStartDrag: ((Double) -> Void)?
    /// 拖右裁剪柄（新终点 fraction）
    var onTrimEndDrag: ((Double) -> Void)?
    var onTrimDragEnd: (() -> Void)?
    /// 双击裁剪柄复位成整段（极简「重置」，不额外占一枚按钮）
    var onTrimReset: (() -> Void)?

    /// 处理中（裁剪 / 转 GIF）禁拖：文件正在原地替换时改区间没有任何意义
    var isInteractionEnabled = true

    /// 任何柄/播放头拖动期间都为 true（面板据此屏蔽周期刷新）
    private(set) var isDragging = false

    private var progress: CGFloat = 0
    private var startFraction: CGFloat = 0
    private var endFraction: CGFloat = 1
    private var isHovering = false
    private var hoverHandle: Handle?
    private var dragMode: DragMode?
    private var tracking: NSTrackingArea?

    private enum Handle { case start, end }
    private enum DragMode { case scrub, trimStart, trimEnd }

    private enum Metrics {
        static let handleWidth: CGFloat = 6
        static let handleHeight: CGFloat = 16
        /// 柄热区半宽（比手柄本体宽一圈，轻松抓住）
        static let handleHitSlack: CGFloat = 9
        /// 轨道两端内缩，保证 fraction=0/1 时柄不被窗口边缘切掉
        static let trackInset: CGFloat = 6
        /// 两柄之间永远留一丝缝（真正的 minSpan 由 VideoTrimRange 把关）
        static let minimumFractionGap: CGFloat = 0.002
    }

    private var isActive: Bool { isDragging || isHovering }
    private var knobRadius: CGFloat { isActive ? 5.5 : 4.5 }
    private var barHeight: CGFloat { isActive ? 6 : 5 }
    private var isRangeTrimmed: Bool { startFraction > 0.001 || endFraction < 0.999 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("VideoPreviewScrubberTrack 只走代码创建") }

    /// `force = true` 时无视拖拽保护（seek 回写 / 复位用）；播放头始终压在有效区间内
    func setProgress(_ fraction: Double, force: Bool = false) {
        guard force || !isDragging else { return }
        let clamped = CGFloat(min(max(fraction, 0), 1))
        let bounded = min(max(clamped, startFraction), endFraction)
        guard abs(bounded - progress) > 0.0005 else { return }
        progress = bounded
        needsDisplay = true
    }

    /// 面板裁完 / 拖柄回写用：同步左右柄位置（顺带把播放头收回区间）
    func setTrimFractions(start: Double, end: Double) {
        let s = CGFloat(min(max(start, 0), 1))
        let e = CGFloat(min(max(end, 0), 1))
        guard e > s else { return }
        startFraction = s
        endFraction = e
        progress = min(max(progress, s), e)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// ⚠️ 关键：父窗口开了 `isMovableByWindowBackground = true`，非不透明子视图默认
    /// `mouseDownCanMoveWindow == true`，不覆写 false 会导致按住进度条拖动直接把整个窗口拖走！
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    // MARK: - 悬停 / 光标

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        // 柄上要实时换 .resizeLeftRight，窗口必须先接受 mouseMoved
        window?.acceptsMouseMovedEvents = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoverHandle = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let handle = handleHit(at: point)
        guard handle != hoverHandle else { return }
        hoverHandle = handle
        needsDisplay = true
    }

    /// 柄上给左右调整光标，其余区域保持箭头（拖动进度条不改光标，避免整条都是小手）
    override func resetCursorRects() {
        super.resetCursorRects()
        let bar = trackGeometry()
        guard bar.width > 0 else { return }
        let reach = Metrics.handleWidth / 2 + 4
        for fraction in [startFraction, endFraction] {
            let centerX = bar.minX + bar.width * fraction
            addCursorRect(
                NSRect(x: centerX - reach, y: 0, width: reach * 2, height: bounds.height),
                cursor: .resizeLeftRight
            )
        }
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled, bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let handle = handleHit(at: point)

        if event.clickCount >= 2, handle != nil {
            // 双击柄 = 复位整段
            isDragging = false
            dragMode = nil
            needsDisplay = true
            onTrimReset?()
            return
        }

        isDragging = true
        onScrubStart?()
        if let handle {
            dragMode = handle == .start ? .trimStart : .trimEnd
        } else {
            dragMode = .scrub
            applyScrub(point: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let dragMode else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .scrub: applyScrub(point: point)
        case .trimStart: applyTrimDrag(handle: .start, point: point)
        case .trimEnd: applyTrimDrag(handle: .end, point: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let dragMode else {
            isDragging = false
            self.dragMode = nil
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .scrub:
            applyScrub(point: point)
            onScrubEnd?()
        case .trimStart, .trimEnd:
            onTrimDragEnd?()
        }
        isDragging = false
        self.dragMode = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// 命中优先级：左右裁剪柄（各自 ±8pt）→ 回落普通进度条 seek
    private func handleHit(at point: NSPoint) -> Handle? {
        let bar = trackGeometry()
        guard bar.width > 0 else { return nil }
        let startX = bar.minX + bar.width * startFraction
        let endX = bar.minX + bar.width * endFraction
        let distanceToStart = abs(point.x - startX)
        let distanceToEnd = abs(point.x - endX)
        let hitStart = distanceToStart <= Metrics.handleHitSlack
        let hitEnd = distanceToEnd <= Metrics.handleHitSlack
        if hitStart && hitEnd {
            // 两柄快要重合：按指针落在中点哪一侧区分，避免「只能拖左柄」的怪感
            let mid = (startX + endX) / 2
            return point.x <= mid ? .start : .end
        }
        if hitStart { return .start }
        if hitEnd { return .end }
        return nil
    }

    private func applyScrub(point: NSPoint) {
        let bar = trackGeometry()
        guard bar.width > 0 else { return }
        let x = min(max(point.x, bar.minX), bar.maxX)
        let fraction = (x - bar.minX) / bar.width
        // 播放头不许跑出有效区间（未裁剪时相当于原行为）
        let clamped = min(max(fraction, startFraction), endFraction)
        guard abs(clamped - progress) > 0.0002 else { return }
        progress = clamped
        needsDisplay = true
        onScrub?(Double(clamped))
    }

    private func applyTrimDrag(handle: Handle, point: NSPoint) {
        let bar = trackGeometry()
        guard bar.width > 0 else { return }
        let x = min(max(point.x, bar.minX), bar.maxX)
        let fraction = (x - bar.minX) / bar.width
        switch handle {
        case .start:
            let next = min(fraction, endFraction - Metrics.minimumFractionGap)
            guard abs(next - startFraction) > 0.0002 else { return }
            startFraction = max(0, next)
            progress = max(progress, startFraction)
            needsDisplay = true
            onTrimStartDrag?(Double(startFraction))
        case .end:
            let next = max(fraction, startFraction + Metrics.minimumFractionGap)
            guard abs(next - endFraction) > 0.0002 else { return }
            endFraction = min(1, next)
            progress = min(progress, endFraction)
            needsDisplay = true
            onTrimEndDrag?(Double(endFraction))
        }
    }

    private func trackGeometry() -> NSRect {
        let width = bounds.width - Metrics.trackInset * 2
        return NSRect(x: Metrics.trackInset, y: 0, width: max(0, width), height: bounds.height)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let bar = trackGeometry()
        guard bar.width > 0 else { return }

        let barH = barHeight
        let radius = barH / 2
        let trackRect = NSRect(x: bar.minX, y: (bounds.height - barH) / 2, width: bar.width, height: barH)
        let basePath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)

        // 1) 整条底轨（裁剪后两端保持低调暗透，突出保留段）
        NSColor.white.withAlphaComponent(isRangeTrimmed ? 0.08 : 0.15).setFill()
        basePath.fill()

        let validMinX = bar.minX + bar.width * startFraction
        let validMaxX = bar.minX + bar.width * endFraction
        let validRect = NSRect(
            x: validMinX,
            y: trackRect.minY,
            width: max(0, validMaxX - validMinX),
            height: barH
        )

        // 2) 有效区间亮底（克制磨砂白，视觉自然聚焦保留段）
        NSColor.white.withAlphaComponent(isRangeTrimmed ? 0.24 : 0.16).setFill()
        NSBezierPath(roundedRect: validRect, xRadius: radius, yRadius: radius).fill()

        // 3) 播放进度（只在有效区间内填充；极短也给一段可见宽度，避免「拖到头只看到 1px」）
        let span = max(0.0001, Double(endFraction - startFraction))
        let localFraction = CGFloat(min(1, max(0, Double(progress - startFraction) / span)))
        if localFraction > 0.001, validRect.width > 0 {
            let filledW = min(validRect.width, max(barH, validRect.width * localFraction))
            let fillRect = NSRect(x: validRect.minX, y: trackRect.minY, width: filledW, height: barH)
            DesignTokens.accent.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }

        // 4) 已裁剪时给有效区间加一圈克制主色蓝微光细框（与暗色 HUD 玻璃同族，无刺眼黄框）
        if isRangeTrimmed {
            let frameRect = validRect.insetBy(dx: -1, dy: -1.5)
            let frame = NSBezierPath(roundedRect: frameRect, xRadius: radius + 1.5, yRadius: radius + 1.5)
            frame.lineWidth = 1
            DesignTokens.accent.withAlphaComponent(0.68).setStroke()
            frame.stroke()
        }

        // 5) 左右裁剪柄
        let startActive = dragMode == .trimStart || hoverHandle == .start
        let endActive = dragMode == .trimEnd || hoverHandle == .end
        drawHandle(centerX: validMinX, active: startActive)
        drawHandle(centerX: validMaxX, active: endActive)

        // 6) 播放头白圆点（画在柄之上，永远看得见）
        let knobR = knobRadius
        let knobCenterX = bar.minX + bar.width * progress
        let knobRect = NSRect(
            x: knobCenterX - knobR,
            y: bounds.midY - knobR,
            width: knobR * 2,
            height: knobR * 2
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSColor.black.withAlphaComponent(0.24).setStroke()
        let ring = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.25, dy: 0.25))
        ring.lineWidth = 0.5
        ring.stroke()
    }

    /// 精致磨砂白竖柄 + 1pt 握持微槽；悬停/拖动时亮白并带主色蓝发丝边，克制耐看
    private func drawHandle(centerX: CGFloat, active: Bool) {
        let w = Metrics.handleWidth
        let h = Metrics.handleHeight
        let rect = NSRect(x: centerX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        let pill = NSBezierPath(roundedRect: rect, xRadius: w / 2, yRadius: w / 2)

        let fillAlpha: CGFloat = active ? 0.98 : (isRangeTrimmed ? 0.88 : 0.38)
        NSColor.white.withAlphaComponent(fillAlpha).setFill()
        pill.fill()

        if active || isRangeTrimmed {
            pill.lineWidth = active ? 1.0 : 0.5
            (active ? DesignTokens.accent : NSColor.black.withAlphaComponent(0.28)).setStroke()
            pill.stroke()
        }

        let grip = NSRect(x: centerX - 0.5, y: rect.minY + 4.5, width: 1, height: max(1, h - 9))
        NSColor.black.withAlphaComponent(active ? 0.42 : (isRangeTrimmed ? 0.30 : 0.22)).setFill()
        grip.fill()
    }
}

// MARK: - 圆形关闭按钮（Esc / ×）

@MainActor
private final class VideoPreviewCloseButton: NSView {
    private let icon = NSImageView()
    private let onTap: () -> Void
    private var tracking: NSTrackingArea?

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        icon.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = DesignTokens.label2
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("VideoPreviewCloseButton 只走代码创建") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = DesignTokens.fillHover.cgColor
        icon.contentTintColor = DesignTokens.label1
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        icon.contentTintColor = DesignTokens.label2
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onTap()
        }
    }
}

// MARK: - 胶囊按钮（对齐 GIFPreviewPanel 的 PreviewPillButton 质感）

@MainActor
private final class VideoPreviewPillButton: NSView {
    @MainActor
    enum Style {
        case primary
        case normal
        case destructive

        var idleBg: NSColor {
            switch self {
            case .primary: return DesignTokens.accent
            case .normal: return DesignTokens.fill
            case .destructive: return DesignTokens.statusError.withAlphaComponent(0.14)
            }
        }

        var hoverBg: NSColor {
            switch self {
            case .primary: return DesignTokens.accentHover
            case .normal: return DesignTokens.fillHover
            case .destructive: return DesignTokens.statusError.withAlphaComponent(0.24)
            }
        }

        var foreground: NSColor {
            switch self {
            case .primary: return .white
            case .normal: return DesignTokens.label1
            case .destructive: return DesignTokens.statusError
            }
        }
    }

    private let style: Style
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let onTap: () -> Void
    private var tracking: NSTrackingArea?
    /// 处理中置灰：不响应点击（防重入的第一道闸，面板里还有 `isProcessing` 守卫）
    private(set) var isEnabled = true

    init(symbol: String, title: String, style: Style, onTap: @escaping () -> Void) {
        self.style = style
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = style.idleBg.cgColor

        icon.contentTintColor = style.foreground
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = style.foreground
        label.translatesAutoresizingMaskIntoConstraints = false

        update(symbol: symbol, title: title)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("VideoPreviewPillButton 只走代码创建") }

    func update(symbol: String, title: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .medium))
        label.stringValue = title
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        alphaValue = enabled ? 1 : 0.38
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = style.hoverBg.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = style.idleBg.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        TactilePress.animate(view: self, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        TactilePress.animate(view: self, pressed: false)
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onTap()
        }
    }
}
