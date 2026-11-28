import AppKit
import CoreGraphics
import QuartzCore

/// 录屏 / GIF 悬浮控制栏（与 ToolbarPanel 同源高晶玻璃 + 双层光学投影）
///
/// 职责：
/// - 准备态：实时展示目标像素尺寸、切换参数（FPS / 系统声音 / 麦克风 / 光标 / GIF 1x 缩放），点击「开始录制」；
/// - 录制态：原地收敛为紧凑计时胶囊（呼吸红点 + 等宽计时 + 暂停/继续 + 完成 + 取消），支持拖动换位，且被 SCStream 进程级排除永不入镜；
/// - `nonactivatingPanel` + `acceptsFirstMouse`：录制中点击暂停/停止绝不抢走被录制应用的键盘焦点。
@MainActor
final class RecordingControlBar: NSPanel {
    struct Callbacks {
        var onOptionsChanged: (RecordingOptions) -> Void = { _ in }
        var onStart: () -> Void = {}
        var onPauseToggle: () -> Void = {}
        var onStop: () -> Void = {}
        var onCancel: () -> Void = {}
    }

    private static let shadowMargin: CGFloat = 28

    /// 与工具栏同源的尺寸度量：外框高 / 外圆角 / 左右内边距 / 间距全部跟随 settings.toolbarSize
    /// （单一真源 DesignTokens.Toolbar.Metrics，与 ToolbarPanel 的 TBStyle 完全同一套）
    private let metrics: DesignTokens.Toolbar.Metrics
    /// 由 metrics 派生的内部控件几何：所有胶囊/按钮共享同一条视觉高度基准线与同心圆角
    private let geom: BarGeometry

    private var options: RecordingOptions
    private var callbacks: Callbacks
    private var phase: RecordingPhase = .preparing
    private var selectionSizePoints: CGSize = .zero
    private var backingScale: CGFloat = 2
    private var userMovedManually = false

    private let outerView = BarOuterView()
    private let panelRoot = NSView()
    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let foregroundHost = NSView()
    private let outerShadowView: OuterShadowView
    private let contentStack = NSStackView()

    // 准备态控件
    /// GIF / 视频 格式分段切换器（最左，紧凑轻玻璃胶囊）
    private var formatSegment: BarFormatSegment!
    private let sizeBadgeLabel = NSTextField(labelWithString: "")
    private var sizeBadgeContainer: NSView!
    private var fpsButton: BarChipButton!
    private var fpsSlider: BarFPSSlider!
    private let fpsReadoutLabel = NSTextField(labelWithString: "15 fps")
    private var fpsSliderGroup: NSStackView!
    private var systemAudioButton: BarToggleIconButton!
    private var micButton: BarToggleIconButton!
    private var gifScaleButton: BarChipButton!
    private var cursorButton: BarToggleIconButton!
    private var startButton: BarPrimaryActionButton!
    private var prepCancelButton: BarIconButton!

    // 录制态控件
    private let recDotLayer = CALayer()
    private let recDotView = NSView()
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let stateTagLabel = NSTextField(labelWithString: "MP4")
    /// 录制中实时音频指示（轻盈声波胶囊，仅 mp4 且对应开关开启时显示）
    private var recSystemAudioBadge: BarAudioActivityBadge!
    private var recMicBadge: BarAudioActivityBadge!
    private var recAudioRow: NSStackView!
    private var pauseButton: BarIconButton!
    private var stopButton: BarStopRecordButton!
    private var recCancelButton: BarIconButton!

    private var tooltipWindow: BarTooltipWindow?
    /// tooltip 当前是否在展示（用于点击切换后原地刷新文案）
    private var tooltipVisible = false

    init(options: RecordingOptions, callbacks: Callbacks) {
        let sizeSetting = AppCoordinatorShared.coordinator?.settings.toolbarSize ?? .regular
        let metrics = DesignTokens.Toolbar.Metrics.forSize(sizeSetting)
        self.metrics = metrics
        self.geom = BarGeometry(metrics)
        self.options = options
        self.callbacks = callbacks
        self.glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: metrics.cornerRadius,
            tintAlpha: 0.08
        )
        self.outerShadowView = OuterShadowView(
            spec: .toolbar,
            margin: Self.shadowMargin,
            cornerRadius: metrics.cornerRadius
        )
        let m = Self.shadowMargin
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420 + m * 2, height: metrics.height + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .aqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        buildUI()
        rebuildStack(for: .preparing)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - 公开状态更新

    func configure(options: RecordingOptions, callbacks: Callbacks) {
        self.options = options
        self.callbacks = callbacks
        syncOptionButtons()
    }

    func updateSelectionSize(_ sizePoints: CGSize, backingScale: CGFloat) {
        self.selectionSizePoints = sizePoints
        self.backingScale = max(1, backingScale)
        let px = RecordingGeometry.targetPixelSize(
            regionPoints: sizePoints,
            backingScale: self.backingScale,
            options: options
        )
        sizeBadgeLabel.stringValue = "\(options.format.displayName) · \(px.width)×\(px.height)"
        if case .preparing = phase {
            relayoutToFitCurrentContent()
        }
    }

    func updatePhase(_ newPhase: RecordingPhase, anchorGlobalRect: CGRect?, on screen: NSScreen?) {
        let modeChanged: Bool = {
            switch (phase, newPhase) {
            case (.preparing, .preparing): return false
            case (.preparing, _), (_, .preparing): return true
            default: return false
            }
        }()
        phase = newPhase
        if modeChanged {
            hideTooltip()
            rebuildStack(for: newPhase)
        }
        syncLiveStateUI()
        if modeChanged, let anchorGlobalRect, let screen, !userMovedManually {
            place(nearGlobalRect: anchorGlobalRect, on: screen)
        } else if modeChanged {
            relayoutToFitCurrentContent()
        }
    }

    func place(nearGlobalRect rect: CGRect, on screen: NSScreen) {
        contentView?.layoutSubtreeIfNeeded()
        let barSize = measuredBarSize()
        let visible = screen.visibleFrame
        let gap: CGFloat = 10
        let margin: CGFloat = 10

        var x = rect.midX - barSize.width / 2
        x = max(visible.minX + margin, min(x, visible.maxX - barSize.width - margin))

        let belowY = rect.minY - gap - barSize.height
        let aboveY = rect.maxY + gap
        let y: CGFloat
        if belowY >= visible.minY + margin {
            y = belowY
        } else if aboveY + barSize.height <= visible.maxY - margin {
            y = aboveY
        } else {
            y = visible.minY + 24
        }

        let m = Self.shadowMargin
        let frame = CGRect(
            x: (x - m).rounded(),
            y: (y - m).rounded(),
            width: barSize.width + m * 2,
            height: barSize.height + m * 2
        )
        setFrame(frame, display: true)
    }

    func dismiss() {
        hideTooltip()
        recDotLayer.removeAllAnimations()
        // 声波胶囊归零放平：避免下次唤起时残留上一次的跳动高度
        recSystemAudioBadge?.reset()
        recMicBadge?.reset()
        orderOut(nil)
    }

    /// 接收录制器回传的实时音频电平（0.0...1.0），驱动控制条上的声波胶囊
    ///
    /// 只有 `.recording` 态才跳动；`.paused` / `.finalizing` / `.preparing` 一律放平归零——
    /// 否则暂停后会残留最后一帧的高柱，看起来像还在收音。
    func updateAudioLevels(system: Float, microphone: Float) {
        guard case .recording = phase else {
            recSystemAudioBadge?.updateLevel(0)
            recMicBadge?.updateLevel(0)
            return
        }
        recSystemAudioBadge?.updateLevel(system)
        recMicBadge?.updateLevel(microphone)
    }

    // MARK: - UI 构建

    private func buildUI() {
        let m = Self.shadowMargin
        outerView.wantsLayer = true
        outerView.panelRootView = panelRoot
        outerView.onBackgroundDrag = { [weak self] delta in
            guard let self else { return }
            self.userMovedManually = true
            var origin = self.frame.origin
            origin.x += delta.x
            origin.y += delta.y
            self.setFrameOrigin(origin)
        }

        outerShadowView.translatesAutoresizingMaskIntoConstraints = false
        outerView.addSubview(outerShadowView)

        panelRoot.wantsLayer = true
        panelRoot.translatesAutoresizingMaskIntoConstraints = false
        outerView.addSubview(panelRoot)

        let glassHost = glassSurface.hostView
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        panelRoot.addSubview(glassHost)

        foregroundHost.wantsLayer = true
        foregroundHost.appearance = NSAppearance(named: .aqua)
        foregroundHost.translatesAutoresizingMaskIntoConstraints = false
        panelRoot.addSubview(foregroundHost)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        // 组内间距/左右内边距与工具栏同一套度量（多 2pt 让相邻胶囊不粘连）
        contentStack.spacing = max(6, metrics.groupGap + 2)
        contentStack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: metrics.paddingH,
            bottom: 0,
            right: metrics.paddingH
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        foregroundHost.addSubview(contentStack)

        NSLayoutConstraint.activate([
            outerShadowView.leadingAnchor.constraint(equalTo: outerView.leadingAnchor),
            outerShadowView.trailingAnchor.constraint(equalTo: outerView.trailingAnchor),
            outerShadowView.topAnchor.constraint(equalTo: outerView.topAnchor),
            outerShadowView.bottomAnchor.constraint(equalTo: outerView.bottomAnchor),

            panelRoot.leadingAnchor.constraint(equalTo: outerView.leadingAnchor, constant: m),
            panelRoot.trailingAnchor.constraint(equalTo: outerView.trailingAnchor, constant: -m),
            panelRoot.topAnchor.constraint(equalTo: outerView.topAnchor, constant: m),
            panelRoot.bottomAnchor.constraint(equalTo: outerView.bottomAnchor, constant: -m),
            panelRoot.heightAnchor.constraint(equalToConstant: metrics.height),

            glassHost.leadingAnchor.constraint(equalTo: panelRoot.leadingAnchor),
            glassHost.trailingAnchor.constraint(equalTo: panelRoot.trailingAnchor),
            glassHost.topAnchor.constraint(equalTo: panelRoot.topAnchor),
            glassHost.bottomAnchor.constraint(equalTo: panelRoot.bottomAnchor),

            foregroundHost.leadingAnchor.constraint(equalTo: panelRoot.leadingAnchor),
            foregroundHost.trailingAnchor.constraint(equalTo: panelRoot.trailingAnchor),
            foregroundHost.topAnchor.constraint(equalTo: panelRoot.topAnchor),
            foregroundHost.bottomAnchor.constraint(equalTo: panelRoot.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: foregroundHost.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: foregroundHost.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: foregroundHost.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: foregroundHost.bottomAnchor),
        ])

        buildSubcontrols()
        contentView = outerView
    }

    private func buildSubcontrols() {
        // 格式分段切换器（GIF | 视频）：切换后重建准备态控件栈并同步尺寸徽章
        formatSegment = BarFormatSegment(geom: geom)
        formatSegment.onSelect = { [weak self] format in
            guard let self, self.options.format != format else { return }
            self.options.format = format
            self.rebuildStack(for: .preparing)
            self.updateSelectionSize(self.selectionSizePoints, backingScale: self.backingScale)
            self.relayoutToFitCurrentContent()
            self.callbacks.onOptionsChanged(self.options)
        }
        formatSegment.onHover = { [weak self] inside in
            self?.handleHover(inside, target: self?.formatSegment, text: "切换录制格式")
        }

        // 尺寸徽章：干净浮在玻璃上的等宽文字（无灰底块，与工具栏同脉清透）
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.clear.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        sizeBadgeLabel.font = DesignTokens.Font.monoDigit(11.5)
        sizeBadgeLabel.textColor = DesignTokens.label2
        sizeBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(sizeBadgeLabel)
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: geom.pillHeight),
            sizeBadgeLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 4),
            sizeBadgeLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -4),
            sizeBadgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        sizeBadgeContainer = badge

        fpsButton = BarChipButton(title: "60 fps", geom: geom, fixedWidth: 56, tabularDigits: true) { [weak self] in self?.cycleFPS() }
        fpsButton.onHover = { [weak self] inside in
            self?.handleHover(inside, target: self?.fpsButton, text: "切换录制帧率")
        }

        fpsSlider = BarFPSSlider(minFPS: 10, maxFPS: 24, initialFPS: options.effectiveFPS, height: geom.pillHeight)
        fpsSlider.onChange = { [weak self] fps in
            guard let self else { return }
            self.options.gifFPS = fps
            self.fpsReadoutLabel.stringValue = "\(fps) fps"
            self.handleHover(true, target: self.fpsSlider, text: "帧率 \(fps) fps")
        }
        fpsSlider.onCommit = { [weak self] fps in
            guard let self else { return }
            self.options.gifFPS = fps
            self.fpsReadoutLabel.stringValue = "\(fps) fps"
            self.callbacks.onOptionsChanged(self.options)
        }
        fpsSlider.onHover = { [weak self] inside in
            guard let self else { return }
            self.handleHover(inside, target: self.fpsSlider, text: "帧率 \(self.options.effectiveFPS) fps（10–24）")
        }

        fpsReadoutLabel.font = DesignTokens.Font.monoDigit(11.5)
        fpsReadoutLabel.textColor = DesignTokens.label1
        fpsReadoutLabel.alignment = .left
        fpsReadoutLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsReadoutLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        fpsSliderGroup = NSStackView(views: [fpsSlider, fpsReadoutLabel])
        fpsSliderGroup.orientation = .horizontal
        fpsSliderGroup.alignment = .centerY
        fpsSliderGroup.spacing = 6
        fpsSliderGroup.translatesAutoresizingMaskIntoConstraints = false

        systemAudioButton = BarToggleIconButton(
            onSymbol: "speaker.wave.2.fill",
            offSymbol: "speaker.slash",
            geom: geom,
            onTap: { [weak self] in
                guard let self else { return }
                self.options.captureSystemAudio.toggle()
                self.syncOptionButtons()
                // tooltip 还在展示时立刻刷新文案，用户点完即看到状态变化
                if self.tooltipVisible {
                    self.handleHover(true, target: self.systemAudioButton, text: self.systemAudioTooltipText)
                }
                self.callbacks.onOptionsChanged(self.options)
            }
        )
        systemAudioButton.onHover = { [weak self] inside in
            guard let self else { return }
            self.handleHover(inside, target: self.systemAudioButton, text: self.systemAudioTooltipText)
        }

        micButton = BarToggleIconButton(
            onSymbol: "mic.fill",
            offSymbol: "mic.slash",
            geom: geom,
            onTap: { [weak self] in
                guard let self else { return }
                self.options.captureMicrophone.toggle()
                self.syncOptionButtons()
                // tooltip 还在展示时立刻刷新文案，用户点完即看到状态变化
                if self.tooltipVisible {
                    self.handleHover(true, target: self.micButton, text: self.micTooltipText)
                }
                self.callbacks.onOptionsChanged(self.options)
            }
        )
        micButton.onHover = { [weak self] inside in
            guard let self else { return }
            self.handleHover(inside, target: self.micButton, text: self.micTooltipText)
        }

        gifScaleButton = BarChipButton(title: "1x 轻量", geom: geom, fixedWidth: 64) { [weak self] in
            guard let self else { return }
            self.options.gifScale1x.toggle()
            self.syncOptionButtons()
            self.updateSelectionSize(self.selectionSizePoints, backingScale: self.backingScale)
            self.callbacks.onOptionsChanged(self.options)
        }
        gifScaleButton.onHover = { [weak self] inside in
            guard let self else { return }
            self.handleHover(inside, target: self.gifScaleButton, text: self.options.gifScale1x ? "1x 逻辑像素（体积更小）" : "原始 Retina 像素（更清晰）")
        }

        cursorButton = BarToggleIconButton(
            onSymbol: "cursorarrow.motionlines",
            offSymbol: "cursorarrow",
            geom: geom,
            onTap: { [weak self] in
                guard let self else { return }
                self.options.showCursor.toggle()
                self.syncOptionButtons()
                self.callbacks.onOptionsChanged(self.options)
            }
        )
        cursorButton.onHover = { [weak self] inside in
            guard let self else { return }
            self.handleHover(inside, target: self.cursorButton, text: self.options.showCursor ? "显示鼠标指针：开" : "显示鼠标指针：关")
        }

        startButton = BarPrimaryActionButton(
            symbol: "record.circle.fill",
            title: "开始录制",
            tint: DesignTokens.statusError,
            geom: geom,
            onTap: { [weak self] in self?.callbacks.onStart() }
        )
        startButton.onHover = { [weak self] inside in
            self?.handleHover(inside, target: self?.startButton, text: "开始录制 (Return)")
        }

        prepCancelButton = BarIconButton(symbol: "xmark", geom: geom) { [weak self] in
            self?.callbacks.onCancel()
        }
        prepCancelButton.onHover = { [weak self] inside in
            self?.handleHover(inside, target: self?.prepCancelButton, text: "取消 (Esc)")
        }

        // 录制态控件
        recDotView.wantsLayer = true
        recDotView.translatesAutoresizingMaskIntoConstraints = false
        recDotView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        recDotView.heightAnchor.constraint(equalToConstant: 12).isActive = true
        recDotLayer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        recDotLayer.position = CGPoint(x: 6, y: 6)
        recDotLayer.cornerRadius = 4
        recDotLayer.backgroundColor = DesignTokens.statusError.cgColor
        recDotView.layer?.addSublayer(recDotLayer)

        timerLabel.font = DesignTokens.Font.monoDigit(13)
        timerLabel.textColor = DesignTokens.label1

        stateTagLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateTagLabel.textColor = DesignTokens.label2

        // 录制中音频指示：实时声波胶囊，一眼确认收录了哪几路声音、哪一路正在收音
        recSystemAudioBadge = BarAudioActivityBadge(
            symbol: "speaker.wave.2.fill",
            tint: DesignTokens.accent,
            activeTooltip: "正在收录系统声音",
            pausedTooltip: "系统声音已暂停",
            geom: geom
        )
        recMicBadge = BarAudioActivityBadge(
            symbol: "mic.fill",
            tint: DesignTokens.statusOK,
            activeTooltip: "正在收录麦克风",
            pausedTooltip: "麦克风已暂停",
            geom: geom
        )
        recSystemAudioBadge.onHover = { [weak self] inside in
            guard let self else { return }
            self.handleHover(inside, target: self.recSystemAudioBadge, text: self.recSystemAudioBadge.tooltipText)
        }
        recMicBadge.onHover = { [weak self] inside in
            guard let self else { return }
            self.handleHover(inside, target: self.recMicBadge, text: self.recMicBadge.tooltipText)
        }
        recSystemAudioBadge.isHidden = true
        recMicBadge.isHidden = true
        let badgeViews: [NSView] = [recSystemAudioBadge, recMicBadge]
        recAudioRow = NSStackView(views: badgeViews)
        recAudioRow.orientation = .horizontal
        recAudioRow.alignment = .centerY
        recAudioRow.spacing = 6
        recAudioRow.translatesAutoresizingMaskIntoConstraints = false

        pauseButton = BarIconButton(symbol: "pause.fill", geom: geom) { [weak self] in
            self?.callbacks.onPauseToggle()
        }
        pauseButton.onHover = { [weak self] inside in
            guard let self else { return }
            let isPaused = {
                if case .paused = self.phase { return true }
                return false
            }()
            self.handleHover(inside, target: self.pauseButton, text: isPaused ? "继续录制" : "暂停录制")
        }

        stopButton = BarStopRecordButton(geom: geom) { [weak self] in
            self?.callbacks.onStop()
        }
        stopButton.onHover = { [weak self] inside in
            self?.handleHover(inside, target: self?.stopButton, text: "停止并保存")
        }

        recCancelButton = BarIconButton(symbol: "xmark", geom: geom) { [weak self] in
            self?.callbacks.onCancel()
        }
        recCancelButton.onHover = { [weak self] inside in
            self?.handleHover(inside, target: self?.recCancelButton, text: "放弃本次录制")
        }
    }

    private func rebuildStack(for phase: RecordingPhase) {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch phase {
        case .preparing:
            contentStack.addArrangedSubview(formatSegment)
            contentStack.addArrangedSubview(sizeBadgeContainer)
            contentStack.addArrangedSubview(makeSeparator())
            if options.format == .mp4 {
                // 系统声与麦克风完全独立，可自由组合：无声 / 仅系统声 / 仅麦克风 / 两者
                contentStack.addArrangedSubview(fpsButton)
                contentStack.addArrangedSubview(systemAudioButton)
                contentStack.addArrangedSubview(micButton)
                contentStack.addArrangedSubview(cursorButton)
            } else {
                contentStack.addArrangedSubview(fpsSliderGroup)
                contentStack.addArrangedSubview(gifScaleButton)
                contentStack.addArrangedSubview(cursorButton)
            }
            contentStack.addArrangedSubview(makeSeparator())
            contentStack.addArrangedSubview(startButton)
            contentStack.addArrangedSubview(prepCancelButton)
            formatSegment.setFormat(options.format)
            syncOptionButtons()

        case .recording, .paused, .finalizing:
            var statusViews: [NSView] = [recDotView, timerLabel, stateTagLabel]
            if options.format == .mp4 {
                statusViews.append(recAudioRow)
            }
            let statusRow = NSStackView(views: statusViews)
            statusRow.orientation = .horizontal
            statusRow.alignment = .centerY
            statusRow.spacing = 6
            statusRow.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)

            let sep = makeSeparator()

            let actionsRow = NSStackView(views: [pauseButton, stopButton, recCancelButton])
            actionsRow.orientation = .horizontal
            actionsRow.alignment = .centerY
            actionsRow.spacing = 2

            contentStack.addArrangedSubview(statusRow)
            contentStack.addArrangedSubview(sep)
            contentStack.addArrangedSubview(actionsRow)
            // 光学平衡：左接实心声波胶囊留 8pt，右接无底色透明暂停键（图标自带 ~11pt 内留白）仅留 2pt
            contentStack.setCustomSpacing(8, after: statusRow)
            contentStack.setCustomSpacing(2, after: sep)
            syncLiveStateUI()
        }
    }

    private func syncOptionButtons() {
        fpsButton.setTitle("\(options.effectiveFPS) fps")
        fpsSlider.setFPS(options.effectiveFPS)
        fpsReadoutLabel.stringValue = "\(options.effectiveFPS) fps"
        systemAudioButton.setOn(options.captureSystemAudio)
        micButton.setOn(options.captureMicrophone)
        gifScaleButton.setTitle(options.gifScale1x ? "1x 轻量" : "原画质")
        cursorButton.setOn(options.showCursor)
    }

    private var systemAudioTooltipText: String {
        options.captureSystemAudio ? "收录系统声音：已开启" : "收录系统声音：已关闭"
    }

    private var micTooltipText: String {
        options.captureMicrophone ? "收录麦克风：已开启" : "收录麦克风：已关闭"
    }

    /// 录制态音频指示：仅 mp4 且对应开关开启时展示，关闭隐藏；两路都关时整行隐藏不留空隙
    private func syncRecAudioIndicators() {
        let isVideo = options.format == .mp4
        let showSystem = isVideo && options.captureSystemAudio
        let showMic = isVideo && options.captureMicrophone
        recSystemAudioBadge?.isHidden = !showSystem
        recMicBadge?.isHidden = !showMic
        recAudioRow?.isHidden = !showSystem && !showMic
        if !showSystem { recSystemAudioBadge?.updateLevel(0) }
        if !showMic { recMicBadge?.updateLevel(0) }
    }

    /// 声波胶囊跟随录制阶段：仅录制态跳动，暂停/导出/准备态全部放平
    private func syncAudioBadgePhase(paused: Bool) {
        recSystemAudioBadge?.setPaused(paused)
        recMicBadge?.setPaused(paused)
    }

    private func syncLiveStateUI() {
        syncRecAudioIndicators()
        switch phase {
        case .preparing:
            recDotLayer.removeAllAnimations()
            syncAudioBadgePhase(paused: true)
        case .recording(let elapsed):
            timerLabel.stringValue = RecordingGeometry.formatDuration(elapsed)
            stateTagLabel.stringValue = options.format.displayName
            pauseButton.setSymbol("pause.fill")
            pauseButton.isEnabled = true
            stopButton.isEnabled = true
            recCancelButton.isEnabled = true
            syncAudioBadgePhase(paused: false)
            updateDotAnimation(paused: false)
        case .paused(let elapsed):
            timerLabel.stringValue = RecordingGeometry.formatDuration(elapsed)
            stateTagLabel.stringValue = "已暂停"
            pauseButton.setSymbol("play.fill")
            pauseButton.isEnabled = true
            stopButton.isEnabled = true
            recCancelButton.isEnabled = true
            syncAudioBadgePhase(paused: true)
            recSystemAudioBadge?.updateLevel(0)
            recMicBadge?.updateLevel(0)
            updateDotAnimation(paused: true)
        case .finalizing:
            stateTagLabel.stringValue = "正在导出…"
            pauseButton.isEnabled = false
            stopButton.isEnabled = false
            recCancelButton.isEnabled = false
            syncAudioBadgePhase(paused: true)
            recSystemAudioBadge?.updateLevel(0)
            recMicBadge?.updateLevel(0)
            updateDotAnimation(paused: true)
        }
    }

    private func updateDotAnimation(paused: Bool) {
        if paused {
            recDotLayer.removeAllAnimations()
            recDotLayer.backgroundColor = DesignTokens.statusWarn.cgColor
            recDotLayer.opacity = 1
        } else {
            recDotLayer.backgroundColor = DesignTokens.statusError.cgColor
            if recDotLayer.animation(forKey: "dot.pulse") == nil, !DesignTokens.Motion.reduceMotion {
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 0.35
                anim.toValue = 1.0
                anim.duration = 0.7
                anim.autoreverses = true
                anim.repeatCount = .infinity
                recDotLayer.add(anim, forKey: "dot.pulse")
            }
        }
    }

    private func cycleFPS() {
        switch options.format {
        case .mp4:
            options.mp4FPS = (options.mp4FPS == 60) ? 30 : 60
        case .gif:
            switch options.gifFPS {
            case 10: options.gifFPS = 15
            case 15: options.gifFPS = 24
            default: options.gifFPS = 10
            }
        }
        syncOptionButtons()
        callbacks.onOptionsChanged(options)
    }

    private func makeSeparator() -> NSView {
        let sep = BarHairlineView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 1.0).isActive = true
        sep.heightAnchor.constraint(equalToConstant: metrics.separatorHeight).isActive = true
        return sep
    }

    private func measuredBarSize() -> CGSize {
        contentView?.layoutSubtreeIfNeeded()
        let fit = contentStack.fittingSize
        return CGSize(width: ceil(max(180, fit.width)), height: metrics.height)
    }

    private func relayoutToFitCurrentContent() {
        let newBarSize = measuredBarSize()
        let m = Self.shadowMargin
        let newW = newBarSize.width + m * 2
        let newH = newBarSize.height + m * 2
        // 尺寸未变化时直接返回，杜绝 0.5pt 四舍五入导致的整栏 1px 抖动
        guard abs(newW - frame.width) >= 0.5 || abs(newH - frame.height) >= 0.5 else { return }
        let oldCenterX = frame.midX
        var x = (oldCenterX - newW / 2).rounded()
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            x = max(visible.minX + 8 - m, min(x, visible.maxX - newW + m - 8))
        }
        setFrame(CGRect(x: x, y: frame.minY, width: newW, height: newH), display: true)
    }

    private func handleHover(_ inside: Bool, target: NSView?, text: String) {
        if inside, let target {
            if tooltipWindow == nil { tooltipWindow = BarTooltipWindow() }
            let localRect = target.convert(target.bounds, to: nil)
            let globalRect = convertToScreen(localRect)
            tooltipWindow?.show(text: text, aboveGlobalRect: globalRect)
            tooltipVisible = true
        } else {
            hideTooltip()
        }
    }

    private func hideTooltip() {
        tooltipVisible = false
        tooltipWindow?.orderOut(nil)
    }
}

// MARK: - 宿主外框（留白穿透 + 背景拖拽移动控制栏）

@MainActor
private final class BarOuterView: NSView {
    weak var panelRootView: NSView?
    var onBackgroundDrag: ((CGPoint) -> Void)?
    private var draggingBar = false
    private var lastScreenPoint: CGPoint = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let panel = panelRootView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return panel.frame.contains(local) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        draggingBar = true
        lastScreenPoint = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingBar else { return }
        let now = NSEvent.mouseLocation
        let delta = CGPoint(x: now.x - lastScreenPoint.x, y: now.y - lastScreenPoint.y)
        lastScreenPoint = now
        onBackgroundDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        draggingBar = false
    }
}

// MARK: - 子控件（对齐 ToolbarPanel 视觉质感）

/// 录制控制栏内部控件的统一几何基准（全部由 `DesignTokens.Toolbar.Metrics` 派生）
///
/// 与 ToolbarPanel 的 TBStyle 同源：所有胶囊/按钮共享同一条视觉高度基准线
/// （`pillHeight`）与同心圆角（`innerRadius`）——玻璃面上不再出现高低参差的色块。
private struct BarGeometry {
    /// 命中区边长（= 工具栏按钮边长 `metrics.buttonSide`）
    let buttonSide: CGFloat
    /// 视觉本体高：命中区四周内缩 2pt，刚好等于 ToolbarPanel backdropLayer 的高
    let pillHeight: CGFloat
    /// 同心内圆角
    let innerRadius: CGFloat
    /// 基准图标字号
    let iconPointSize: CGFloat

    init(_ metrics: DesignTokens.Toolbar.Metrics) {
        buttonSide = metrics.buttonSide
        pillHeight = metrics.buttonSide - 4
        innerRadius = metrics.innerPillRadius
        iconPointSize = metrics.iconPointSize
    }
}

/// 明暗自适应组间分隔线：避免在未加入 `.aqua` 父视图前求值 `DesignTokens.hair.cgColor`，
/// 导致深色系统下在浅色玻璃上画出隐身白线。
@MainActor
private final class BarHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0.5
        refreshColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    private func refreshColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.black.withAlphaComponent(0.14)
            layer?.backgroundColor = color.cgColor
        }
    }
}

@MainActor
private final class BarIconButton: NSView {
    private let iconView = NSImageView()
    private let onTap: () -> Void
    private let geom: BarGeometry
    /// 2pt 内缩的悬停底胶囊（对齐 TBIconButton：色块不贴边、不拉高按钮）
    private let backdropLayer = CALayer()
    private var tracking: NSTrackingArea?
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.4
        }
    }
    var onHover: ((Bool) -> Void)?

    init(symbol: String, geom: BarGeometry, onTap: @escaping () -> Void) {
        self.onTap = onTap
        self.geom = geom
        super.init(frame: .zero)
        wantsLayer = true

        backdropLayer.cornerRadius = geom.innerRadius
        backdropLayer.cornerCurve = .continuous
        backdropLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(backdropLayer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = DesignTokens.hudForeground(DesignTokens.Toolbar.iconIdleAlpha)
        addSubview(iconView)
        setSymbol(symbol)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: geom.buttonSide),
            heightAnchor.constraint(equalToConstant: geom.buttonSide),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// macOS 26 上 NSButton 的 alignmentRectInsets 习性在这里不存在，但 NSView 子类统一归零
    /// 可避免宿主栈按 baseline 额外撑高
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds.insetBy(dx: 2, dy: 2)
        CATransaction.commit()
    }

    func setSymbol(_ symbol: String) {
        iconView.image = TBIcon.symbolImage(
            named: symbol,
            pointSize: geom.iconPointSize - 1.5,
            weight: .medium,
            hierarchical: false
        )
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
        setBackdrop(DesignTokens.fillHover)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        setBackdrop(nil)
        onHover?(false)
    }

    private func setBackdrop(_ color: NSColor?) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropLayer.backgroundColor = color?.cgColor ?? NSColor.clear.cgColor
            CATransaction.commit()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        TactilePress.animate(view: self, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: false)
        guard isEnabled else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onTap()
        }
    }
}

/// 开关型图标按钮：1:1 移植 ToolbarPanel `TBIconButton(usesSelfSelectedBackdrop: true)` 的质感
/// 开启态 = accentSoft 底 + 0.5pt accent 描边 + accent 图标；关闭态 = 透明浮于玻璃 + 悬停轻底
@MainActor
private final class BarToggleIconButton: NSView {
    private let onSymbol: String
    private let offSymbol: String
    private let iconView = NSImageView()
    private let onTap: () -> Void
    private let geom: BarGeometry
    /// 2pt 内缩的独立底胶囊（= pillHeight × pillHeight，与字号/图标同步同心）
    private let backdropLayer = CALayer()
    private var isOn = false
    private var isHovered = false
    private var tracking: NSTrackingArea?
    var onHover: ((Bool) -> Void)?

    init(onSymbol: String, offSymbol: String, geom: BarGeometry, onTap: @escaping () -> Void) {
        self.onSymbol = onSymbol
        self.offSymbol = offSymbol
        self.onTap = onTap
        self.geom = geom
        super.init(frame: .zero)
        wantsLayer = true

        backdropLayer.cornerRadius = geom.innerRadius
        backdropLayer.cornerCurve = .continuous
        backdropLayer.backgroundColor = NSColor.clear.cgColor
        backdropLayer.borderWidth = 0
        layer?.addSublayer(backdropLayer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: geom.buttonSide),
            heightAnchor.constraint(equalToConstant: geom.buttonSide),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds.insetBy(dx: 2, dy: 2)
        CATransaction.commit()
    }

    func setOn(_ on: Bool) {
        isOn = on
        refreshAppearance()
    }

    private func refreshAppearance() {
        let sym = isOn ? onSymbol : offSymbol
        iconView.image = TBIcon.symbolImage(
            named: sym,
            pointSize: max(13.5, geom.iconPointSize - 1.0),
            weight: .medium,
            hierarchical: true
        )
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if isOn {
                backdropLayer.backgroundColor = DesignTokens.accentSoft.cgColor
                backdropLayer.borderWidth = 0.5
                backdropLayer.borderColor = DesignTokens.accent.withAlphaComponent(0.22).cgColor
                iconView.contentTintColor = DesignTokens.accent
            } else {
                iconView.contentTintColor = DesignTokens.hudForeground(0.52)
                if isHovered {
                    backdropLayer.backgroundColor = DesignTokens.fillHover.cgColor
                    backdropLayer.borderWidth = 0
                    backdropLayer.borderColor = nil
                } else {
                    backdropLayer.backgroundColor = NSColor.clear.cgColor
                    backdropLayer.borderWidth = 0
                    backdropLayer.borderColor = nil
                }
            }
            CATransaction.commit()
        }
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
        isHovered = true
        refreshAppearance()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance()
        onHover?(false)
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

@MainActor
private final class BarFormatSegment: NSView {
    var onSelect: ((RecordingFormat) -> Void)?
    var onHover: ((Bool) -> Void)?

    private let gifIconView = NSImageView()
    private let gifLabel = NSTextField(labelWithString: "GIF")
    private let videoIconView = NSImageView()
    private let videoLabel = NSTextField(labelWithString: "视频")
    private let pillLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var selectedFormat: RecordingFormat = .mp4
    private var hasLaidOutOnce = false

    private let itemWidth: CGFloat = 56
    private let inset: CGFloat = 2

    init(geom: BarGeometry) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = geom.innerRadius
        layer?.cornerCurve = .continuous
        // 外槽轻透：极浅黑底 + 0.5pt 内边，比之前的实心灰块轻得多
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.055).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.05).cgColor

        pillLayer.cornerRadius = max(4, geom.innerRadius - 2)
        pillLayer.cornerCurve = .continuous
        pillLayer.backgroundColor = NSColor.white.cgColor
        pillLayer.shadowColor = NSColor.black.cgColor
        pillLayer.shadowOpacity = 0.14
        pillLayer.shadowRadius = 2.0
        pillLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(pillLayer)

        gifIconView.image = TBIcon.image(.recordGIF, pointSize: 12)
        videoIconView.image = TBIcon.image(.record, pointSize: 12)
        for iconView in [gifIconView, videoIconView] {
            iconView.imageScaling = .scaleProportionallyDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 13),
                iconView.heightAnchor.constraint(equalToConstant: 13),
            ])
        }

        for label in [gifLabel, videoLabel] {
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        let gifSlot = NSView()
        gifSlot.translatesAutoresizingMaskIntoConstraints = false
        let gifStack = NSStackView(views: [gifIconView, gifLabel])
        gifStack.orientation = .horizontal
        gifStack.alignment = .centerY
        gifStack.spacing = 4
        gifStack.translatesAutoresizingMaskIntoConstraints = false
        gifSlot.addSubview(gifStack)
        addSubview(gifSlot)

        let videoSlot = NSView()
        videoSlot.translatesAutoresizingMaskIntoConstraints = false
        let videoStack = NSStackView(views: [videoIconView, videoLabel])
        videoStack.orientation = .horizontal
        videoStack.alignment = .centerY
        videoStack.spacing = 4
        videoStack.translatesAutoresizingMaskIntoConstraints = false
        videoSlot.addSubview(videoStack)
        addSubview(videoSlot)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: itemWidth * 2 + inset * 2),
            heightAnchor.constraint(equalToConstant: geom.pillHeight),

            gifSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            gifSlot.widthAnchor.constraint(equalToConstant: itemWidth),
            gifSlot.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            gifSlot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            gifStack.centerXAnchor.constraint(equalTo: gifSlot.centerXAnchor),
            gifStack.centerYAnchor.constraint(equalTo: gifSlot.centerYAnchor),

            videoSlot.leadingAnchor.constraint(equalTo: gifSlot.trailingAnchor),
            videoSlot.widthAnchor.constraint(equalToConstant: itemWidth),
            videoSlot.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            videoSlot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            videoStack.centerXAnchor.constraint(equalTo: videoSlot.centerXAnchor),
            videoStack.centerYAnchor.constraint(equalTo: videoSlot.centerYAnchor),
        ])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFormat(_ format: RecordingFormat, animated: Bool = false) {
        selectedFormat = format
        refreshAppearance()
        updatePillFrame(animated: animated && hasLaidOutOnce && !DesignTokens.Motion.reduceMotion)
    }

    private func refreshAppearance() {
        let selectsGIF = selectedFormat == .gif
        gifIconView.contentTintColor = selectsGIF ? DesignTokens.accent : DesignTokens.label2
        gifLabel.textColor = selectsGIF ? DesignTokens.label1 : DesignTokens.label2
        gifLabel.font = .systemFont(ofSize: 11.5, weight: selectsGIF ? .semibold : .medium)

        videoIconView.contentTintColor = selectsGIF ? DesignTokens.label2 : DesignTokens.accent
        videoLabel.textColor = selectsGIF ? DesignTokens.label2 : DesignTokens.label1
        videoLabel.font = .systemFont(ofSize: 11.5, weight: selectsGIF ? .medium : .semibold)
    }

    private func updatePillFrame(animated: Bool) {
        guard bounds.height > inset * 2 else { return }
        let selectsGIF = selectedFormat == .gif
        let x: CGFloat = selectsGIF ? inset : itemWidth + inset
        let targetFrame = CGRect(x: x, y: inset, width: itemWidth, height: max(0, bounds.height - inset * 2))
        CATransaction.begin()
        if animated {
            CATransaction.setDisableActions(false)
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        } else {
            CATransaction.setDisableActions(true)
        }
        pillLayer.frame = targetFrame
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updatePillFrame(animated: false)
        hasLaidOutOnce = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

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
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true, scale: 0.97)
    }

    override func mouseUp(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: false)
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else { return }
        let next: RecordingFormat = pt.x < bounds.midX ? .gif : .mp4
        guard next != selectedFormat else { return }
        setFormat(next, animated: true)
        onSelect?(next)
    }
}

@MainActor
private final class BarChipButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let onTap: () -> Void
    private let idleFill = NSColor.black.withAlphaComponent(0.045)
    private let hoverFill = NSColor.black.withAlphaComponent(0.085)
    private var tracking: NSTrackingArea?
    var onHover: ((Bool) -> Void)?

    init(title: String, geom: BarGeometry, fixedWidth: CGFloat? = nil, tabularDigits: Bool = false, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = geom.innerRadius
        layer?.cornerCurve = .continuous
        // 极轻底色 + 0.5pt 细描边：与工具栏图标键同样只是「浮在玻璃上的一层薄膜」
        layer?.backgroundColor = idleFill.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.07).cgColor

        label.stringValue = title
        label.font = tabularDigits ? DesignTokens.Font.monoDigit(11.5) : .systemFont(ofSize: 11.5, weight: .medium)
        label.alignment = .center
        label.textColor = DesignTokens.label1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false
        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: geom.pillHeight),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let fixedWidth {
            constraints.append(widthAnchor.constraint(equalToConstant: fixedWidth))
            constraints.append(label.centerXAnchor.constraint(equalTo: centerXAnchor))
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9))
            constraints.append(label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String) {
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
        layer?.backgroundColor = hoverFill.cgColor
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = idleFill.cgColor
        onHover?(false)
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

@MainActor
private final class BarPrimaryActionButton: NSView {
    private let tint: NSColor
    private let onTap: () -> Void
    /// 顶缘 0.5pt 内高光：红色大键不至于「贴纸感」，与玻璃面有厚度关系
    private let sheenLayer = CALayer()
    private var tracking: NSTrackingArea?
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.55
        }
    }
    var onHover: ((Bool) -> Void)?

    init(symbol: String, title: String, tint: NSColor, geom: BarGeometry, onTap: @escaping () -> Void) {
        self.tint = tint
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        // 圆角/高度与相邻胶囊完全齐平：整条栏共享同一条基准线
        layer?.cornerRadius = geom.innerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = tint.cgColor

        sheenLayer.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.addSublayer(sheenLayer)

        let icon = NSImageView()
        icon.image = TBIcon.symbolImage(named: symbol, pointSize: 12.5, weight: .semibold, hierarchical: false)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: geom.pillHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 只铺顶缘（圆角由 masksToBounds 裁切）
        sheenLayer.frame = CGRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5)
        CATransaction.commit()
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
        layer?.backgroundColor = tint.blended(withFraction: 0.14, of: .white)?.cgColor ?? tint.cgColor
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = tint.cgColor
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        TactilePress.animate(view: self, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: false)
        guard isEnabled else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onTap()
        }
    }
}

// MARK: - 录制态实时声波胶囊（Apple 灵动岛风格）

/// 录制中单路音频（系统声 / 麦克风）的实时声波胶囊
/// 手机录屏风格的红色停止录制键（命中区 = metrics.buttonSide，与暂停/关闭键等大；
/// 红环套红圆角方块，无冗余文字；悬停底与其它按钮一样是 2pt 内缩胶囊）
@MainActor
private final class BarStopRecordButton: NSView {
    private let backdropLayer = CALayer()
    private let ringLayer = CALayer()
    private let squareLayer = CALayer()
    private let onTap: () -> Void
    private let geom: BarGeometry
    private var tracking: NSTrackingArea?
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.4
        }
    }
    var onHover: ((Bool) -> Void)?

    init(geom: BarGeometry, onTap: @escaping () -> Void) {
        self.onTap = onTap
        self.geom = geom
        super.init(frame: .zero)
        wantsLayer = true

        backdropLayer.cornerRadius = geom.innerRadius
        backdropLayer.cornerCurve = .continuous
        backdropLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(backdropLayer)

        let red = DesignTokens.statusError.cgColor
        ringLayer.borderWidth = 1.75
        ringLayer.borderColor = red
        ringLayer.backgroundColor = DesignTokens.statusError.withAlphaComponent(0.08).cgColor
        layer?.addSublayer(ringLayer)

        squareLayer.cornerCurve = .continuous
        squareLayer.backgroundColor = red
        layer?.addSublayer(squareLayer)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: geom.buttonSide),
            heightAnchor.constraint(equalToConstant: geom.buttonSide),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds.insetBy(dx: 2, dy: 2)
        // 红环/方块的直径派生自内部胶囊高，任何尺寸档位下都与相邻胶囊同心同高
        let ringSide = max(16, geom.pillHeight - 4)
        ringLayer.frame = CGRect(
            x: (bounds.width - ringSide) / 2,
            y: (bounds.height - ringSide) / 2,
            width: ringSide,
            height: ringSide
        )
        ringLayer.cornerRadius = ringSide / 2
        let squareSide = (ringSide * 0.42).rounded()
        squareLayer.frame = CGRect(
            x: (bounds.width - squareSide) / 2,
            y: (bounds.height - squareSide) / 2,
            width: squareSide,
            height: squareSide
        )
        squareLayer.cornerRadius = squareSide * 0.25
        CATransaction.commit()
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
        setBackdrop(DesignTokens.statusError.withAlphaComponent(0.10))
        ringLayer.backgroundColor = DesignTokens.statusError.withAlphaComponent(0.14).cgColor
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        setBackdrop(nil)
        ringLayer.backgroundColor = DesignTokens.statusError.withAlphaComponent(0.08).cgColor
        onHover?(false)
    }

    private func setBackdrop(_ color: NSColor?) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropLayer.backgroundColor = color?.cgColor ?? NSColor.clear.cgColor
            CATransaction.commit()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        TactilePress.animate(view: self, pressed: true, scale: 0.94)
    }

    override func mouseUp(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: false)
        guard isEnabled else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onTap()
        }
    }
}

/// 录制态实时音频收录动效徽章（图标 + 5 根对称动态声波柱；放宽排布、清晰易读）
@MainActor
private final class BarAudioActivityBadge: NSView {
    private enum Metrics {
        static let heightCap: CGFloat = 28
        static let horizontalPadding: CGFloat = 8
        static let iconSize: CGFloat = 12
        static let iconSpacing: CGFloat = 6
        static let barWidth: CGFloat = 2.2
        static let barSpacing: CGFloat = 2.0
        static let waveWidth: CGFloat = 19.0   // 5 × 2.2pt + 4 × 2.0pt
        static let waveHeight: CGFloat = 13
        static let barCornerRadius: CGFloat = 1.1
        static let dotHeight: CGFloat = 2.6
        static let badgeWidth: CGFloat = horizontalPadding * 2 + iconSize + iconSpacing + waveWidth
        /// 有效声音阈值：低于它视为静音，收敛成圆点
        static let activeThreshold: Float = 0.04
        /// 快起慢落（上升 0.07s / 回落 0.15s）
        static let riseDuration: CFTimeInterval = 0.07
        static let fallDuration: CFTimeInterval = 0.15
        static let tintDuration: CFTimeInterval = 0.16
    }

    /// 五根微柱的对称包络权重：中间最高、两侧渐收，更舒展自然
    private static let barWeights: [CGFloat] = [0.48, 0.84, 1.0, 0.86, 0.52]

    var onHover: ((Bool) -> Void)?

    /// 有声收录时的主题色（系统声=accent 蓝 / 麦克风=statusOK 绿）
    private let activeTint: NSColor
    private let activeTooltip: String
    private let pausedTooltip: String

    private let iconView = NSImageView()
    private let waveHost = NSView()
    private var bars: [CALayer] = []
    private var tracking: NSTrackingArea?

    private var level: Float = 0
    private var isPaused = false
    /// 逐帧递进的相位，让 3 根柱子永不同步
    private var phase: Double = 0

    /// 当前着色 / 底色状态（用它做变更判定，避免每帧重设动态色）
    private enum Tone { case idle, active, paused }
    private var tone: Tone?
    private var isHighlighted: Bool?

    init(symbol: String, tint: NSColor, activeTooltip: String, pausedTooltip: String, geom: BarGeometry) {
        self.activeTint = tint
        self.activeTooltip = activeTooltip
        self.pausedTooltip = pausedTooltip
        let height = min(geom.pillHeight, Metrics.heightCap)
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.badgeWidth, height: height))

        wantsLayer = true
        layer?.cornerRadius = geom.innerRadius
        layer?.cornerCurve = .continuous
        // 与工具栏同脉的极轻薄膜底色（比直接跟随玻璃面稍显形，但不成为灰块）
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.045).cgColor
        layer?.borderWidth = 0

        iconView.image = TBIcon.symbolImage(
            named: symbol,
            pointSize: Metrics.iconSize,
            weight: .medium,
            hierarchical: false
        )
        iconView.contentTintColor = DesignTokens.label2
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        waveHost.wantsLayer = true
        waveHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waveHost)

        bars = (0..<Self.barWeights.count).map { index in
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.cornerRadius = Metrics.barCornerRadius
            bar.backgroundColor = DesignTokens.label3.cgColor
            bar.bounds = CGRect(x: 0, y: 0, width: Metrics.barWidth, height: Metrics.dotHeight)
            // position 锁在中轴：只改 bounds.height ⇒ 上下对称伸缩（不会向上单侧长高）
            bar.position = CGPoint(
                x: CGFloat(index) * (Metrics.barWidth + Metrics.barSpacing) + Metrics.barWidth / 2,
                y: Metrics.waveHeight / 2
            )
            waveHost.layer?.addSublayer(bar)
            return bar
        }

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.badgeWidth),
            heightAnchor.constraint(equalToConstant: height),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            waveHost.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Metrics.iconSpacing),
            waveHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveHost.widthAnchor.constraint(equalToConstant: Metrics.waveWidth),
            waveHost.heightAnchor.constraint(equalToConstant: Metrics.waveHeight),
        ])

        render(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 悬停提示语（随暂停态切换）
    var tooltipText: String { isPaused ? pausedTooltip : activeTooltip }

    /// 暂停 / 恢复：暂停时立即放平归零
    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused { level = 0 }
        render(animated: true)
    }

    /// 推入一帧电平（0.0...1.0）
    func updateLevel(_ newLevel: Float) {
        guard !isPaused else { return }
        level = min(max(newLevel, 0), 1)
        phase += 0.55
        render(animated: true)
    }

    /// 归零放平（dismiss / 隐藏时调用）
    func reset() {
        level = 0
        phase = 0
        render(animated: false)
    }

    // MARK: - 渲染

    private func render(animated: Bool) {
        let isActive = !isPaused && level > Metrics.activeThreshold
        let newTone: Tone = isPaused ? .paused : (isActive ? .active : .idle)
        let toneChanged = tone != newTone
        tone = newTone

        setHighlighted(isActive, animated: animated && toneChanged)

        // 着色只在 Tone 跳变时重设：避免每帧给 CALayer 塞新动态色
        if toneChanged {
            switch newTone {
            case .active:
                setIconTint(activeTint, animated: animated)
                setBarColor(activeTint, animated: animated)
            case .paused:
                setIconTint(DesignTokens.label3, animated: animated)
                setBarColor(DesignTokens.label3, animated: animated)
            case .idle:
                setIconTint(DesignTokens.label2, animated: animated)
                setBarColor(DesignTokens.label3, animated: animated)
            }
        }

        for (index, bar) in bars.enumerated() {
            updateBarHeight(bar, index: index, active: isActive, animated: animated)
        }
    }

    /// 目标柱高：静音=2.5pt 圆点；有声=按电平在 2.5pt...12pt 间伸缩
    private func targetBarHeight(at index: Int, active: Bool) -> CGFloat {
        guard active else { return Metrics.dotHeight }
        // 开方压缩动态范围：轻声也看得出跳动，重音不至于长期顶格
        let eased = CGFloat(sqrt(Double(min(max(level, 0), 1))))
        var amplitude = eased * Self.barWeights[index]
        // 减弱动态效果时只保留静态高度，不加相位波动
        if !DesignTokens.Motion.reduceMotion {
            let wobble = 1 + 0.1 * CGFloat(sin(phase + Double(index) * 1.15))
            amplitude *= wobble
        }
        let span = Metrics.waveHeight - Metrics.dotHeight
        return min(Metrics.waveHeight, max(Metrics.dotHeight, Metrics.dotHeight + amplitude * span))
    }

    private func updateBarHeight(_ bar: CALayer, index: Int, active: Bool, animated: Bool) {
        let previous = bar.bounds.height
        let height = targetBarHeight(at: index, active: active)
        let rising = height > previous

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = CGRect(x: 0, y: 0, width: Metrics.barWidth, height: height)
        CATransaction.commit()

        guard animated, !DesignTokens.Motion.reduceMotion, abs(height - previous) > 0.01 else { return }
        let grow = CABasicAnimation(keyPath: "bounds.size.height")
        grow.fromValue = previous
        grow.toValue = height
        grow.duration = rising ? Metrics.riseDuration : Metrics.fallDuration
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bar.add(grow, forKey: "level")
    }

    private func setBarColor(_ color: NSColor, animated: Bool) {
        let target = color.cgColor
        for bar in bars {
            if animated, !DesignTokens.Motion.reduceMotion {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = bar.presentation()?.backgroundColor ?? bar.backgroundColor
                fade.toValue = target
                fade.duration = Metrics.tintDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(fade, forKey: "tint")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.backgroundColor = target
            CATransaction.commit()
        }
    }

    private func setIconTint(_ color: NSColor, animated: Bool) {
        if animated, !DesignTokens.Motion.reduceMotion, let iconLayer = iconView.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Metrics.tintDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            iconLayer.add(fade, forKey: "tint")
        }
        iconView.contentTintColor = color
    }

    private func setHighlighted(_ highlighted: Bool, animated: Bool) {
        guard isHighlighted != highlighted else { return }
        isHighlighted = highlighted
        let target = highlighted ? activeTint.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.045)
        let border = highlighted ? activeTint.withAlphaComponent(0.20).cgColor : nil
        let borderWidth: CGFloat = highlighted ? 0.5 : 0
        if animated, !DesignTokens.Motion.reduceMotion, let layer {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = target.cgColor
            fade.duration = Metrics.tintDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "highlight")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = target.cgColor
        layer?.borderWidth = borderWidth
        layer?.borderColor = border
        CATransaction.commit()
    }

    // MARK: - 悬停

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

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
private final class BarTooltipWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        let pill = DesignTokens.Mat.glass(material: DesignTokens.Mat.hud, cornerRadius: 7)
        pill.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = DesignTokens.label1
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
        ])
        contentView = pill
    }

    func show(text: String, aboveGlobalRect rect: CGRect) {
        label.stringValue = text
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? NSSize(width: 100, height: 24)
        let x = (rect.midX - size.width / 2).rounded()
        let y = (rect.maxY + 8).rounded()
        setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        orderFrontRegardless()
    }
}

/// 帧率无极滑杆（10–24 fps，视觉与交互手感 1:1 对齐 TBStrokeSlider）
@MainActor
private final class BarFPSSlider: NSView {
    var onChange: ((Int) -> Void)?
    var onCommit: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?

    private let minFPS: Int
    private let maxFPS: Int
    private var currentValue: CGFloat

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knobLayer = CALayer()
    private let knobRimLayer = CALayer()

    private var trackingArea: NSTrackingArea?
    private var isHot = false
    private var isDragging = false

    private let sliderWidth: CGFloat = 86
    private let trackHeight: CGFloat = 5.0
    private let knobWidth: CGFloat = 19.0
    private let knobHeight: CGFloat = 12.0
    private let sidePad: CGFloat = 4

    init(minFPS: Int = 10, maxFPS: Int = 24, initialFPS: Int = 15, height: CGFloat = 28) {
        self.minFPS = minFPS
        self.maxFPS = maxFPS
        self.currentValue = CGFloat(min(maxFPS, max(minFPS, initialFPS)))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        widthAnchor.constraint(equalToConstant: sliderWidth).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true

        let noAnim: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "cornerRadius": NSNull(),
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
        ]
        trackLayer.actions = noAnim
        trackLayer.cornerRadius = trackHeight / 2
        trackLayer.cornerCurve = .continuous
        trackLayer.masksToBounds = true
        trackLayer.borderWidth = 0.5
        trackLayer.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        trackLayer.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor

        fillLayer.cornerRadius = trackHeight / 2
        fillLayer.cornerCurve = .continuous
        fillLayer.backgroundColor = DesignTokens.accent.cgColor

        knobLayer.bounds = CGRect(x: 0, y: 0, width: knobWidth, height: knobHeight)
        knobLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        knobLayer.cornerRadius = knobHeight / 2
        knobLayer.cornerCurve = .continuous
        knobLayer.masksToBounds = false
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOffset = CGSize(width: 0, height: -1.2)

        knobRimLayer.frame = knobLayer.bounds.insetBy(dx: 0.5, dy: 0.5)
        knobRimLayer.cornerRadius = (knobHeight - 1) / 2
        knobRimLayer.cornerCurve = .continuous
        knobRimLayer.borderWidth = 0.75
        knobLayer.addSublayer(knobRimLayer)

        layer?.addSublayer(trackLayer)
        trackLayer.addSublayer(fillLayer)
        layer?.addSublayer(knobLayer)
        updateKnobState(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFPS(_ fps: Int) {
        let clamped = CGFloat(min(maxFPS, max(minFPS, fps)))
        guard abs(clamped - currentValue) > 0.01 else { return }
        currentValue = clamped
        layoutSliderLayers(animated: false)
    }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        layoutSliderLayers(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        updateKnobState(animated: true)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        if !isDragging {
            updateKnobState(animated: true)
            onHover?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        updateKnobState(animated: true)
        let local = convert(event.locationInWindow, from: nil)
        updateValue(from: local.x, animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let local = convert(event.locationInWindow, from: nil)
        updateValue(from: local.x, animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let local = convert(event.locationInWindow, from: nil)
        updateValue(from: local.x, animated: false)
        let snapped = Int(currentValue.rounded())
        currentValue = CGFloat(snapped)
        layoutSliderLayers(animated: true)
        updateKnobState(animated: true)
        onCommit?(snapped)
        if !isHot {
            onHover?(false)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard abs(delta) > 0.2 else { return }
        let step: CGFloat = delta > 0 ? 1 : -1
        let next = CGFloat(min(maxFPS, max(minFPS, Int((currentValue + step).rounded()))))
        if abs(next - currentValue) >= 0.5 {
            currentValue = next
            layoutSliderLayers(animated: true)
            let fps = Int(currentValue.rounded())
            onChange?(fps)
            onCommit?(fps)
        }
    }

    private func updateValue(from localX: CGFloat, animated: Bool) {
        let trackLeft = sidePad
        let trackRight = max(trackLeft + knobWidth, bounds.width - sidePad)
        let travel = max(1, (trackRight - trackLeft) - knobWidth)
        let centerStart = trackLeft + knobWidth / 2
        let t = min(1, max(0, (localX - centerStart) / travel))
        let raw = CGFloat(minFPS) + t * CGFloat(maxFPS - minFPS)
        let prevInt = Int(currentValue.rounded())
        currentValue = min(CGFloat(maxFPS), max(CGFloat(minFPS), raw))
        layoutSliderLayers(animated: animated)
        let nextInt = Int(currentValue.rounded())
        if nextInt != prevInt || animated {
            onChange?(nextInt)
        }
    }

    private func layoutSliderLayers(animated: Bool) {
        guard bounds.width > 10, bounds.height > 4 else { return }
        let trackLeft = sidePad
        let trackRight = max(trackLeft + knobWidth, bounds.width - sidePad)
        let midY = bounds.midY
        let span = max(1, trackRight - trackLeft)
        let ratio = min(1, max(0, (currentValue - CGFloat(minFPS)) / CGFloat(max(1, maxFPS - minFPS))))
        let travel = max(1, span - knobWidth)
        let knobCenterX = trackLeft + knobWidth / 2 + travel * ratio

        trackLayer.frame = CGRect(x: trackLeft, y: midY - trackHeight / 2, width: span, height: trackHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        }
        fillLayer.frame = CGRect(x: 0, y: 0, width: max(trackHeight, knobCenterX - trackLeft), height: trackHeight)
        knobLayer.position = CGPoint(x: knobCenterX, y: midY)
        CATransaction.commit()
    }

    private func updateKnobState(animated: Bool) {
        let scale: CGFloat = isDragging ? 1.12 : (isHot ? 1.05 : 1.0)
        let bg = isDragging ? NSColor.white.withAlphaComponent(0.80).cgColor : NSColor.white.cgColor
        let border = isDragging ? NSColor.white.withAlphaComponent(0.95).cgColor : NSColor.black.withAlphaComponent(0.10).cgColor
        let borderW: CGFloat = isDragging ? 0.9 : 0.5
        let rim = isDragging ? NSColor.white.withAlphaComponent(0.65).cgColor : NSColor.white.withAlphaComponent(0.85).cgColor
        let shadowOpacity: Float = isDragging ? 0.22 : (isHot ? 0.20 : 0.16)
        let shadowRadius: CGFloat = isDragging ? 5.0 : (isHot ? 3.8 : 3.0)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        } else {
            CATransaction.setDisableActions(true)
        }
        knobLayer.backgroundColor = bg
        knobLayer.borderColor = border
        knobLayer.borderWidth = borderW
        knobLayer.shadowOpacity = shadowOpacity
        knobLayer.shadowRadius = shadowRadius
        knobLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        knobRimLayer.borderColor = rim
        CATransaction.commit()
    }
}
