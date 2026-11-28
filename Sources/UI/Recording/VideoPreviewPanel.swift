import AppKit
@preconcurrency import AVFoundation
import CoreMedia

/// 内置 MP4 视频预览窗（替代不播视频的 macOS 原生预览 App）
///
/// 设计（与 `GIFPreviewPanel` 同一套 Apple HUD 视觉语言）：
/// - 居中于当前鼠标所在屏幕，深色磨砂玻璃卡片 + 双层光学阴影（`.spotlight` / margin 24 / r16）；
/// - `AVPlayer` + `AVPlayerLayer(videoGravity: .resizeAspect)` 承载画面，打开即自动播放并无缝循环；
/// - 舞台与底栏之间是自绘胶囊进度条（点击 / 拖拽实时 seek），时间读数走 tabular-nums；
/// - 底栏「暂停/播放 · 静音/有声 · 复制文件 · 访达 · 丢弃」；
/// - 快捷键（仅窗口可见且为 keyWindow 时生效）：空格播放/暂停、`Esc` 关闭、`←/→` 快退/快进 2s、`M` 静音；
/// - `cleanUpPlayer()` 在关闭与「丢弃」前必定先行，确保 mp4 文件句柄立即释放、磁盘删除绝不失败。
@MainActor
final class VideoPreviewPanel: NSPanel {
    static let shared = VideoPreviewPanel()

    struct Callbacks {
        var onCopyFile: (URL) -> Void
        var onRevealInFinder: (URL) -> Void
        var onDiscard: (URL) -> Void
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
        static let minCardWidth: CGFloat = 420
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

        self.currentResult = result
        self.callbacks = callbacks

        applyFrame(for: result)
        titleLabel.stringValue = result.fileURL.lastPathComponent
        metaLabel.stringValue =
            "\(result.pixelWidth)×\(result.pixelHeight) · \(result.formattedDuration) · \(result.formattedSize)"
        durationLabel.stringValue = result.formattedDuration
        currentTimeLabel.stringValue = "00:00"
        scrubberTrack.setProgress(0, force: true)

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
        // 关键：先释放 AVPlayer 与文件句柄，再 orderOut（否则「丢弃」删盘会撞上未释放的 mp4）
        cleanUpPlayer()
        scrubberTrack.setProgress(0, force: true)
        currentTimeLabel.stringValue = "00:00"
        orderOut(nil)
        currentResult = nil
        callbacks = nil
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
        guard seconds.isFinite else { return }
        let clamped = min(max(seconds, 0), max(duration, 0))
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(clamped)
        scrubberTrack.setProgress(duration > 0 ? clamped / duration : 0)
    }

    private func restartFromBeginning() {
        guard let player else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
        syncPlaybackButtons()
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(0)
        scrubberTrack.setProgress(0, force: true)
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
            if duration > 0, current.isFinite, current >= duration - 0.05 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTimeLabel.stringValue = RecordingGeometry.formatDuration(0)
                scrubberTrack.setProgress(0, force: true)
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
        let clamped = min(max(fraction, 0), 1)
        let target = clamped * duration
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(target)
        scrubberTrack.setProgress(clamped, force: true)
    }

    private func seek(byDelta delta: Double) {
        guard let player else { return }
        let duration = effectiveDuration
        let current = CMTimeGetSeconds(player.currentTime())
        let base = current.isFinite ? max(0, current) : 0
        let target = min(max(base + delta, 0), max(duration, 0))
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTimeLabel.stringValue = RecordingGeometry.formatDuration(target)
        scrubberTrack.setProgress(duration > 0 ? target / duration : 0, force: true)
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

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footerStack = NSStackView(views: [playPauseBtn, muteBtn, spacer, copyBtn, finderBtn, discardBtn])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 8
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

    private(set) var isDragging = false
    private var progress: CGFloat = 0
    private var isHovering = false
    private var tracking: NSTrackingArea?

    private var isActive: Bool { isDragging || isHovering }
    private var knobRadius: CGFloat { isActive ? 5.5 : 4.5 }
    private var barHeight: CGFloat { isActive ? 6 : 5 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("VideoPreviewScrubberTrack 只走代码创建") }

    /// `force = true` 时无视拖拽保护（seek 回写 / 复位用）
    func setProgress(_ fraction: Double, force: Bool = false) {
        guard force || !isDragging else { return }
        let clamped = CGFloat(min(max(fraction, 0), 1))
        guard abs(clamped - progress) > 0.0005 else { return }
        progress = clamped
        needsDisplay = true
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
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard bounds.width > 0 else { return }
        isDragging = true
        onScrubStart?()
        apply(point: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        apply(point: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        apply(point: convert(event.locationInWindow, from: nil))
        isDragging = false
        needsDisplay = true
        onScrubEnd?()
    }

    private func apply(point: NSPoint) {
        guard bounds.width > 0 else { return }
        let x = min(max(point.x, 0), bounds.width)
        let fraction = CGFloat(x / bounds.width)
        progress = fraction
        needsDisplay = true
        onScrub?(Double(fraction))
    }

    override func draw(_ dirtyRect: NSRect) {
        let knobR = knobRadius
        let barH = barHeight
        let trackWidth = bounds.width - knobR * 2
        guard trackWidth > 0 else { return }
        let trackRect = NSRect(
            x: knobR,
            y: (bounds.height - barH) / 2,
            width: trackWidth,
            height: barH
        )
        let radius = barH / 2

        DesignTokens.fill.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius).fill()

        if progress > 0 {
            // 极短进度也给一个圆点，避免「拖到头只看到 1px」
            let filledW = min(trackWidth, max(barH, trackWidth * progress))
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: filledW, height: barH)
            DesignTokens.accent.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }

        let knobCenterX = trackRect.minX + trackWidth * progress
        let knobRect = NSRect(
            x: knobCenterX - knobR,
            y: bounds.midY - knobR,
            width: knobR * 2,
            height: knobR * 2
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
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
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("VideoPreviewPillButton 只走代码创建") }

    func update(symbol: String, title: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .medium))
        label.stringValue = title
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
        layer?.backgroundColor = style.hoverBg.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = style.idleBg.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: false)
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onTap()
        }
    }
}
