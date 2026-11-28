import AppKit
import CoreGraphics

/// 内置 GIF 动画预览窗（替代不播动图的 macOS 原生预览 App）
///
/// 设计：
/// - 居中于当前鼠标所在屏幕，Apple HUD 深色磨砂玻璃 + 双层光学阴影；
/// - 使用 `NSImageView(animates: true)` 按真实帧延迟循环播放 GIF；
/// - 支持空格暂停/继续、`Esc` 关闭、鼠标拖拽移动窗口，以及「复制文件 / 访达 / 丢弃」快捷操作。
@MainActor
final class GIFPreviewPanel: NSPanel {
    static let shared = GIFPreviewPanel()

    struct Callbacks {
        var onCopyFile: (URL) -> Void
        var onRevealInFinder: (URL) -> Void
        var onDiscard: (URL) -> Void
    }

    private static let shadowMargin: CGFloat = 24
    private static let cornerRadius: CGFloat = 16

    private var currentResult: RecordingResult?
    private var callbacks: Callbacks?
    private var keyMonitor: Any?

    private let outerView = PreviewOuterView()
    private let cardRoot = NSView()
    private let outerShadowView = OuterShadowView(
        spec: .spotlight,
        margin: shadowMargin,
        cornerRadius: cornerRadius
    )
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let gifImageView = ClickableGIFImageView()
    private var playPauseBtn: PreviewPillButton!

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
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

    func show(result: RecordingResult, callbacks: Callbacks) {
        self.currentResult = result
        self.callbacks = callbacks

        let screen = DisplayRegistry.screenAtMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let backing = max(1, screen.backingScaleFactor)

        let rawW = max(1, CGFloat(result.pixelWidth))
        let rawH = max(1, CGFloat(result.pixelHeight))
        // 若是 2x 原画质录制，按逻辑尺寸起始展示；否则按 1:1 展示并允许适度放大到易读尺寸
        let logicalW = rawW > visible.width * 0.7 ? rawW / backing : rawW
        let logicalH = rawH > visible.height * 0.65 ? rawH / backing : rawH

        let headerH: CGFloat = 44
        let footerH: CGFloat = 50
        let stagePad: CGFloat = 16
        let maxStageW = visible.width * 0.68
        let maxStageH = visible.height * 0.64
        let minCardW: CGFloat = 380
        let minStageH: CGFloat = 180

        let fitScale = min(1.0, min(maxStageW / logicalW, maxStageH / logicalH))
        let stageW = max(minCardW - stagePad * 2, (logicalW * fitScale).rounded())
        let stageH = max(minStageH, (logicalH * fitScale).rounded())

        let cardW = max(minCardW, stageW + stagePad * 2)
        let cardH = headerH + stageH + footerH + stagePad
        let m = Self.shadowMargin
        let totalSize = CGSize(width: cardW + m * 2, height: cardH + m * 2)

        let origin = DisplayRegistry.centerOrigin(for: totalSize, on: screen)
        setFrame(CGRect(origin: origin, size: totalSize), display: true)

        titleLabel.stringValue = result.fileURL.lastPathComponent
        let frameInfo = result.frameCount > 0 ? " · \(result.frameCount) 帧" : ""
        metaLabel.stringValue = "\(result.pixelWidth)×\(result.pixelHeight) · \(result.formattedDuration)\(frameInfo) · \(result.formattedSize)"

        let gifImage = NSImage(contentsOf: result.fileURL)
        gifImageView.image = gifImage
        gifImageView.animates = true
        syncPlayPauseButton()

        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            animator().alphaValue = 1
        }
        Log.event(.recording, "recording.gifPreview.open", [
            "frames": "\(result.frameCount)",
            "px": "\(result.pixelWidth)x\(result.pixelHeight)",
        ])
    }

    func dismiss() {
        removeKeyMonitor()
        gifImageView.animates = false
        gifImageView.image = nil
        orderOut(nil)
    }

    private func buildUI() {
        let m = Self.shadowMargin
        outerView.wantsLayer = true
        outerView.cardRootView = cardRoot

        outerShadowView.translatesAutoresizingMaskIntoConstraints = false
        outerView.addSubview(outerShadowView)

        cardRoot.wantsLayer = true
        cardRoot.translatesAutoresizingMaskIntoConstraints = false
        outerView.addSubview(cardRoot)

        let glass = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: Self.cornerRadius
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        cardRoot.addSubview(glass)

        // 顶部栏
        titleLabel.font = DesignTokens.Font.head
        titleLabel.textColor = DesignTokens.label1
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = DesignTokens.Font.monoDigit(11)
        metaLabel.textColor = DesignTokens.label2
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = PreviewCloseButton { [weak self] in
            self?.dismiss()
        }
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        let topDivider = NSView()
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = DesignTokens.hair.cgColor
        topDivider.translatesAutoresizingMaskIntoConstraints = false

        // 中部 GIF 舞台
        let stageBg = NSView()
        stageBg.wantsLayer = true
        stageBg.layer?.cornerRadius = 10
        stageBg.layer?.cornerCurve = .continuous
        stageBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        stageBg.layer?.borderWidth = 0.5
        stageBg.layer?.borderColor = DesignTokens.stroke.cgColor
        stageBg.translatesAutoresizingMaskIntoConstraints = false

        gifImageView.imageScaling = .scaleProportionallyUpOrDown
        gifImageView.animates = true
        gifImageView.translatesAutoresizingMaskIntoConstraints = false
        gifImageView.onTap = { [weak self] in
            self?.togglePlayPause()
        }
        stageBg.addSubview(gifImageView)

        // 底部栏
        let bottomDivider = NSView()
        bottomDivider.wantsLayer = true
        bottomDivider.layer?.backgroundColor = DesignTokens.hair.cgColor
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false

        playPauseBtn = PreviewPillButton(symbol: "pause.fill", title: "暂停", style: .normal) { [weak self] in
            self?.togglePlayPause()
        }
        let copyBtn = PreviewPillButton(symbol: "doc.on.doc", title: "复制文件", style: .primary) { [weak self] in
            guard let self, let url = self.currentResult?.fileURL else { return }
            self.callbacks?.onCopyFile(url)
            self.dismiss()
        }
        let finderBtn = PreviewPillButton(symbol: "folder", title: "访达", style: .normal) { [weak self] in
            guard let self, let url = self.currentResult?.fileURL else { return }
            self.callbacks?.onRevealInFinder(url)
            self.dismiss()
        }
        let discardBtn = PreviewPillButton(symbol: "trash", title: "丢弃", style: .destructive) { [weak self] in
            guard let self, let url = self.currentResult?.fileURL else { return }
            self.callbacks?.onDiscard(url)
            self.dismiss()
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footerStack = NSStackView(views: [playPauseBtn, spacer, copyBtn, finderBtn, discardBtn])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 8
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        glass.addSubview(titleLabel)
        glass.addSubview(metaLabel)
        glass.addSubview(closeBtn)
        glass.addSubview(topDivider)
        glass.addSubview(stageBg)
        glass.addSubview(bottomDivider)
        glass.addSubview(footerStack)

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
            topDivider.topAnchor.constraint(equalTo: glass.topAnchor, constant: 44),
            topDivider.heightAnchor.constraint(equalToConstant: 0.5),

            stageBg.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 14),
            stageBg.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -14),
            stageBg.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 12),
            stageBg.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -12),

            gifImageView.leadingAnchor.constraint(equalTo: stageBg.leadingAnchor, constant: 6),
            gifImageView.trailingAnchor.constraint(equalTo: stageBg.trailingAnchor, constant: -6),
            gifImageView.topAnchor.constraint(equalTo: stageBg.topAnchor, constant: 6),
            gifImageView.bottomAnchor.constraint(equalTo: stageBg.bottomAnchor, constant: -6),

            bottomDivider.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -50),
            bottomDivider.heightAnchor.constraint(equalToConstant: 0.5),

            footerStack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 14),
            footerStack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -14),
            footerStack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -11),
            footerStack.heightAnchor.constraint(equalToConstant: 28),
        ])

        contentView = outerView
    }

    private func togglePlayPause() {
        gifImageView.animates.toggle()
        syncPlayPauseButton()
    }

    private func syncPlayPauseButton() {
        let playing = gifImageView.animates
        playPauseBtn.update(symbol: playing ? "pause.fill" : "play.fill", title: playing ? "暂停" : "播放")
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                if event.keyCode == 53 { // Esc
                    self.dismiss()
                } else if event.keyCode == 49 { // Space
                    self.togglePlayPause()
                }
            }
            return (event.keyCode == 53 || event.keyCode == 49) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

@MainActor
private final class PreviewOuterView: NSView {
    weak var cardRootView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let root = cardRootView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return root.frame.contains(local) ? super.hitTest(point) : nil
    }
}

@MainActor
private final class ClickableGIFImageView: NSImageView {
    var onTap: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onTap?()
        }
    }
}

@MainActor
private final class PreviewCloseButton: NSView {
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

    required init?(coder: NSCoder) { fatalError() }

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

@MainActor
private final class PreviewPillButton: NSView {
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

    required init?(coder: NSCoder) { fatalError() }

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
