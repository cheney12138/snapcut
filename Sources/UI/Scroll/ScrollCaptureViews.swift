import AppKit
import CoreGraphics
import QuartzCore

/// 滚动截图采集态视觉件（重设计 scene 06，档 1 HUD 钉暗）：
/// - ScrollCaptureHUDPanel：贴选区下缘 8pt 的进度 HUD（呼吸点×3 + tabular 帧数 +
///   44×3pt 进度条）；到底切确认态（OK 图标 status.ok + 「已到底 · 自动合成」）
/// - ScrollRegionGlowView：采集区域边缘光晕（motion.pulse：opacity .35↔.70
///   autoreverse 1.6s）+ 到底底缘 2pt status.ok 条
///
/// token 全部取自 DesignTokens（§9 场景 06 规格）。

// MARK: - 采集进度 HUD（独立 NSPanel，nonactivating，档 1 钉暗）

@MainActor
final class ScrollCaptureHUDPanel: NSPanel {
    private var dots: [NSView] = []
    private let countLabel = NSTextField(labelWithString: "")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    /// 进度条宽度约束（只改 constant，不重建）——旧实现每次 update 都 deactivate
    /// progressFill.constraints，把 leading/top/bottom 钉扎约束一起拆了 ⇒
    /// fill 位置悬空、进度条看起来不动/错位
    private var progressFillWidthConstraint: NSLayoutConstraint?
    private let okIconView = NSImageView()
    private let okLabel = NSTextField(labelWithString: "已到底 · 自动合成")
    private var capturingStack: NSStackView!
    private var okStack: NSStackView!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // mat.hud 钉暗：浮在任意内容上保持可读（tokens.md 钉暗策略）
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        buildUI()
    }

    private func buildUI() {
        // 玻璃容器：radius 9、padding 6/10、0.5pt stroke、inset.hi、shadow.card
        let glass = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: DesignTokens.Radius.hudSmall
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        contentView = glass
        glass.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        // 采集态：呼吸点×3 + 帧数（tabular-nums）+ 44×3pt 进度条
        for _ in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = DesignTokens.accent.cgColor
            dot.layer?.cornerRadius = DesignTokens.Scroll.breathingDotSide / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: DesignTokens.Scroll.breathingDotSide).isActive = true
            dot.heightAnchor.constraint(equalToConstant: DesignTokens.Scroll.breathingDotSide).isActive = true
            installBreathingAnimation(on: dot)
            dots.append(dot)
        }
        countLabel.attributedStringValue = Self.framesText(0)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        progressTrack.layer?.cornerRadius = DesignTokens.Scroll.progressSize.height / 2
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.widthAnchor.constraint(equalToConstant: DesignTokens.Scroll.progressSize.width).isActive = true
        progressTrack.heightAnchor.constraint(equalToConstant: DesignTokens.Scroll.progressSize.height).isActive = true

        progressFill.wantsLayer = true
        progressFill.layer?.backgroundColor = DesignTokens.accent.cgColor
        progressFill.layer?.cornerRadius = DesignTokens.Scroll.progressSize.height / 2
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        let fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        progressFillWidthConstraint = fillWidth
        NSLayoutConstraint.activate([
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth,
        ])

        capturingStack = NSStackView(views: dots + [countLabel, progressTrack])
        capturingStack.orientation = .horizontal
        capturingStack.alignment = .centerY
        capturingStack.spacing = DesignTokens.Spacing.s2
        capturingStack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(capturingStack)

        // 到底确认态：OK 图标（status.ok）+「已到底 · 自动合成」
        okIconView.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                   accessibilityDescription: "已到底")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        okIconView.contentTintColor = DesignTokens.statusOK
        okIconView.translatesAutoresizingMaskIntoConstraints = false
        okIconView.widthAnchor.constraint(equalToConstant: 13).isActive = true
        okIconView.heightAnchor.constraint(equalToConstant: 13).isActive = true
        okLabel.font = DesignTokens.Font.caption
        okLabel.textColor = DesignTokens.label1
        okStack = NSStackView(views: [okIconView, okLabel])
        okStack.orientation = .horizontal
        okStack.alignment = .centerY
        okStack.spacing = DesignTokens.Spacing.s2
        okStack.translatesAutoresizingMaskIntoConstraints = false
        okStack.isHidden = true
        glass.addSubview(okStack)

        NSLayoutConstraint.activate([
            capturingStack.topAnchor.constraint(equalTo: glass.topAnchor, constant: DesignTokens.Scroll.hudPaddingV),
            capturingStack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -DesignTokens.Scroll.hudPaddingV),
            capturingStack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: DesignTokens.Scroll.hudPaddingH),
            capturingStack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -DesignTokens.Scroll.hudPaddingH),
            okStack.topAnchor.constraint(equalTo: glass.topAnchor, constant: DesignTokens.Scroll.hudPaddingV),
            okStack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -DesignTokens.Scroll.hudPaddingV),
            okStack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: DesignTokens.Scroll.hudPaddingH),
            okStack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -DesignTokens.Scroll.hudPaddingH),
        ])
    }

    /// 呼吸点：opacity .35↔1 的 1.2s pulse，三点依次延迟 0.2s（scene 06 .s6-spin；
    /// 审查：.22↔1 满幅闪烁 → .35↔1 呼吸）
    private func installBreathingAnimation(on view: NSView) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = DesignTokens.Scroll.breathingAlphaMin
        anim.toValue = 1.0
        anim.duration = 1.2
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.opacity = DesignTokens.Scroll.breathingAlphaMin
        view.layer?.add(anim, forKey: "breathing")
    }

    private static func framesText(_ n: Int) -> NSAttributedString {
        // t.caption + tabular-nums（等宽数字）
        NSAttributedString(string: "已采集 \(n) 帧", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: DesignTokens.label1,
        ])
    }

    // MARK: - 状态更新

    /// HUD 状态语义（用户 2026-11-16：「没理解 HUD 表达的是什么」）：
    /// - waiting：等待首次滚动（刚进入，还没净贡献帧）
    /// - capturing(n)：采集中——已入列 n 帧（净贡献帧，非采样数）
    /// - fastScroll(hint)：滚动过快提示（帧被丢弃，请放慢）——短暂显示后回落
    private var lastStateKind: String = ""

    func update(frames: Int, progress: CGFloat, droppedHint: Bool = false) {
        let kind = frames <= 0 ? "waiting" : (droppedHint ? "dropped" : "capturing")
        let stateChanged = kind != lastStateKind
        lastStateKind = kind
        if frames <= 0 {
            countLabel.attributedStringValue = Self.hintText("等待滚动…")
        } else if droppedHint {
            countLabel.attributedStringValue = Self.hintText("滚动过快，帧丢失")
        } else {
            countLabel.attributedStringValue = Self.framesText(frames)
        }
        // 帧内进度条：只改宽度约束 constant（钉扎约束保持不动）
        progressFillWidthConstraint?.constant =
            DesignTokens.Scroll.progressSize.width * min(max(progress, 0), 1)
        contentView?.layoutSubtreeIfNeeded()
        if stateChanged {
            // 三态切换 crossfade（motion.crossfade 0.15s ease-out）：等待/采集/过快
            // 不再瞬跳，像一块连续的东西
            crossfade(capturingStack)
        }
        adjustWindowSize()
    }

    /// motion.crossfade：内容态切换 0.15s 透明度过渡（新内容淡入）
    private func crossfade(_ view: NSView) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.crossfadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.alphaValue = 0
            view.animator().alphaValue = 1
        }
    }

    private static func hintText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ])
    }

    /// 到底：切确认态（呼吸点/帧数/进度条 crossfade 出、OK 态 crossfade 入）
    func setBottomState() {
        guard okStack.isHidden else { return }   // 已在确认态，幂等
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.crossfadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            capturingStack.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.capturingStack.isHidden = true
            self.capturingStack.alphaValue = 1   // 复位，下次进入采集态可直接显示
            self.okStack.isHidden = false
            self.okStack.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = DesignTokens.Motion.crossfadeDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.okStack.animator().alphaValue = 1
            }
            self.contentView?.layoutSubtreeIfNeeded()
            self.adjustWindowSize()
        })
    }

    /// HUD 贴选区下缘 8pt 居中（§9：贴选区下缘 8pt）
    func reposition(below selectionGlobal: CGRect, on screen: NSScreen) {
        let size = contentView?.fittingSize ?? frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(
            x: selectionGlobal.midX - size.width / 2,
            y: selectionGlobal.minY - size.height - DesignTokens.Scroll.hudOffsetFromSelection
        )
        // 放不下（贴屏底）翻到选区上方；再夹回可视区
        if origin.y < visible.minY + 4 {
            origin.y = selectionGlobal.maxY + DesignTokens.Scroll.hudOffsetFromSelection
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        setFrameOrigin(origin)
    }

    func show(below selectionGlobal: CGRect, on screen: NSScreen) {
        contentView?.layoutSubtreeIfNeeded()
        adjustWindowSize()
        reposition(below: selectionGlobal, on: screen)
        // 入场：fade + rise 6pt（0.2s spring，与 toast 同语言；原仅 fade）
        let finalFrame = frame
        setFrameOrigin(CGPoint(x: finalFrame.minX, y: finalFrame.minY - 6))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = DesignTokens.Motion.springTimingFunction
            self.animator().setFrame(finalFrame, display: true)
            self.animator().alphaValue = 1
        }
    }

    /// 退场：fade 0.12s 后 orderOut（原 orderOut 直切；completion 强持有 self——
    /// 调用方同步置 nil 也不会让窗口在动画中途被释放）
    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1   // 复位，下次 show() 从 0 起动画
        })
    }

    /// 内容自适应窗口尺寸（栈 fitting + padding）；宽度变化走 0.2s spring
    /// （审查：三态内容宽度跳变 → spring 平滑）
    private func adjustWindowSize() {
        guard let glass = contentView else { return }
        glass.layoutSubtreeIfNeeded()
        let size = glass.fittingSize
        let width = max(size.width, 80)
        let height = size.height
        var frame = self.frame
        frame.origin.x += (frame.width - width) / 2
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        guard frame.size != self.frame.size else {
            setFrameOrigin(frame.origin)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = DesignTokens.Motion.springTimingFunction
            self.animator().setFrame(frame, display: true)
        }
    }
}

// MARK: - 采集区域边缘光晕 + 底缘绿条（覆盖层子视图，坐标与 OverlayView 一致 Y-down）

@MainActor
final class ScrollRegionGlowView: NSView {
    /// 与宿主 OverlayView 同向（Y 向下）：底缘绿条的 layer 几何才落在区域底部
    override var isFlipped: Bool { true }

    /// 区域 outline：1.5pt accent（与普通选区同构）
    private let outlineLayer = CAShapeLayer()
    /// 边缘光晕：accent shadow，motion.pulse（opacity .35↔.70 autoreverse 1.6s）
    private let glowLayer = CAShapeLayer()
    /// 到底底缘：2pt status.ok 条 + 绿色柔光
    private let bottomBarLayer = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        outlineLayer.fillColor = NSColor.clear.cgColor
        outlineLayer.strokeColor = DesignTokens.accent.cgColor
        outlineLayer.lineWidth = DesignTokens.Scroll.outlineWidth
        layer?.addSublayer(outlineLayer)

        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.strokeColor = DesignTokens.accent.withAlphaComponent(0.35).cgColor
        glowLayer.lineWidth = DesignTokens.Scroll.outlineSoftRing * 2
        glowLayer.shadowColor = DesignTokens.accent.cgColor
        glowLayer.shadowOpacity = 0.55
        glowLayer.shadowRadius = 14
        glowLayer.shadowOffset = .zero
        layer?.addSublayer(glowLayer)
        installPulse()

        bottomBarLayer.fillColor = DesignTokens.statusOK.cgColor
        bottomBarLayer.shadowColor = DesignTokens.statusOK.cgColor
        bottomBarLayer.shadowOpacity = 0.65
        bottomBarLayer.shadowRadius = 6
        bottomBarLayer.shadowOffset = .zero
        bottomBarLayer.isHidden = true
        layer?.addSublayer(bottomBarLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ScrollRegionGlowView 只走代码创建") }

    /// motion.pulse：CABasicAnimation opacity .35→.70 autoreverse 1.6s（tokens.md §8）
    private func installPulse() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = DesignTokens.Motion.pulseAlphaMin
        anim.toValue = DesignTokens.Motion.pulseAlphaMax
        anim.duration = DesignTokens.Motion.pulseDuration
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.opacity = DesignTokens.Motion.pulseAlphaMin
        glowLayer.add(anim, forKey: "motion.pulse")
    }

    /// 区域更新（选区随内容生长；view frame 与区域重合，路径即自身 bounds）
    func update(rect: CGRect) {
        frame = rect
        needsLayout = true
        layoutNow()
    }

    override func layout() {
        super.layout()
        layoutNow()
    }

    private func layoutNow() {
        let b = bounds
        let path = CGPath(roundedRect: b.insetBy(dx: 1, dy: 1), cornerWidth: 2, cornerHeight: 2, transform: nil)
        outlineLayer.path = path
        outlineLayer.frame = b
        glowLayer.path = path
        glowLayer.frame = b
        // 底缘 2pt 绿条（贴区域底边内侧）
        let barRect = CGRect(x: 0, y: b.height - DesignTokens.Scroll.bottomBarHeight,
                             width: b.width, height: DesignTokens.Scroll.bottomBarHeight)
        bottomBarLayer.frame = barRect
        bottomBarLayer.path = CGPath(rect: barRect, transform: nil)
    }

    /// 到底：底缘 2pt 绿条亮起 + 光晕停止脉动（定格确认态）
    func setBottomReached() {
        bottomBarLayer.isHidden = false
        glowLayer.removeAnimation(forKey: "motion.pulse")
        glowLayer.opacity = DesignTokens.Motion.pulseAlphaMin
    }
}
