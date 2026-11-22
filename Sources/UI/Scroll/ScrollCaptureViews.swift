import AppKit
import CoreGraphics
import QuartzCore

/// 滚动截图采集态视觉件（重设计 scene 06，档 1 HUD 钉暗）：
/// - ScrollCaptureHUDPanel：贴选区下缘 8pt 的实时状态 HUD（三点波浪呼吸 + tabular 屏数/像素高度 +
///   状态提示，去掉无总长分母的伪进度条）；到底切确认态（OK 图标 status.ok + 「已到底 · 自动合成」）
/// - ScrollRegionGlowView：采集区域边缘光晕（motion.pulse：opacity .35↔.70
///   autoreverse 1.6s）+ 到底底缘 2pt status.ok 条
///
/// token 全部取自 DesignTokens（§9 场景 06 规格）。

// MARK: - 采集状态 HUD（独立 NSPanel，nonactivating，档 1 钉暗）

@MainActor
final class ScrollCaptureHUDPanel: NSPanel {
    enum State: Equatable {
        case waiting
        case capturing(screens: Double, heightPx: Int)
        case contained(screens: Double, heightPx: Int)
        case dropped
    }

    private let dotContainer = NSView()
    private var dotLayers: [CALayer] = []
    private let countLabel = NSTextField(labelWithString: "")
    private let okIconView = NSImageView()
    private let okLabel = NSTextField(labelWithString: "已到底 · 自动合成")
    private var capturingStack: NSStackView!
    private var okStack: NSStackView!
    private var glassView: NSVisualEffectView!
    private var shadowView: NSView!
    /// 投影外扩留白（让圆角软影自然落在胶囊外，消除无影浮片感）
    private static let shadowMargin: CGFloat = 12
    /// 锚定选区与屏幕：宽度自适应时始终基于选区中心重算，避免动画叠加引起水平漂移
    private var anchorSelectionGlobal: CGRect?
    private weak var anchorScreen: NSScreen?

    init() {
        let m = Self.shadowMargin
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220 + m * 2, height: 28 + m * 2),
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
        let m = Self.shadowMargin
        let outer = NSView()
        outer.wantsLayer = true

        // 圆角柔和投影层
        let shadow = NSView()
        shadow.wantsLayer = true
        shadow.translatesAutoresizingMaskIntoConstraints = false
        shadow.layer?.backgroundColor = NSColor.clear.cgColor
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.28
        shadow.layer?.shadowRadius = 10
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -4)
        outer.addSubview(shadow)
        shadowView = shadow

        // 自适应玻璃容器：radius 10、maskImage 消白边 + 对称顶缘高光 + 0.5pt stroke
        let glass = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: DesignTokens.Radius.lg
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(glass)
        glassView = glass
        contentView = outer

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: m),
            glass.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -m),
            glass.topAnchor.constraint(equalTo: outer.topAnchor, constant: m),
            glass.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -m),
            glass.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            shadow.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            shadow.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            shadow.topAnchor.constraint(equalTo: glass.topAnchor),
            shadow.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])

        // 采集态：三颗 Q 弹波浪跳动点（独立 CALayer 居中锚点，支持挤压拉伸 + 回弹）+ 等宽状态读数
        let dotSide: CGFloat = 5
        let dotSpacing: CGFloat = 9
        let containerW: CGFloat = 27
        let containerH: CGFloat = 14
        dotContainer.wantsLayer = true
        dotContainer.layer?.masksToBounds = false
        dotContainer.translatesAutoresizingMaskIntoConstraints = false
        dotContainer.widthAnchor.constraint(equalToConstant: containerW).isActive = true
        dotContainer.heightAnchor.constraint(equalToConstant: containerH).isActive = true

        for i in 0..<3 {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: dotSide, height: dotSide)
            dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            dot.position = CGPoint(x: 4.5 + CGFloat(i) * dotSpacing, y: 5.5)
            dot.backgroundColor = DesignTokens.accent.cgColor
            dot.cornerRadius = dotSide / 2
            dotContainer.layer?.addSublayer(dot)
            installJellyBounceAnimation(on: dot, delay: CFTimeInterval(i) * 0.14)
            dotLayers.append(dot)
        }

        countLabel.attributedStringValue = Self.hintText("等待滚动… · Enter 结束")
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        capturingStack = NSStackView(views: [dotContainer, countLabel])
        capturingStack.orientation = .horizontal
        capturingStack.alignment = .centerY
        capturingStack.spacing = DesignTokens.Spacing.s2
        capturingStack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(capturingStack)

        // 到底/到顶确认态：OK 图标（status.ok）+ 文案
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

    /// Q 弹果冻波浪动效：蓄力压扁 → 轻盈弹起拉长 → 落地回弹微震（三点错峰 0.14s 接力；reduceMotion 降级为温和呼吸）
    private func installJellyBounceAnimation(on layer: CALayer, delay: CFTimeInterval) {
        if DesignTokens.Motion.reduceMotion {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 0.45
            breath.toValue = 1.0
            breath.duration = 0.9
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.beginTime = CACurrentMediaTime() + delay
            layer.opacity = 0.45
            layer.add(breath, forKey: "jellyBounce")
            return
        }
        let keyTimes: [NSNumber] = [0.0, 0.08, 0.28, 0.48, 0.62, 0.74, 1.0]
        let timingFunctions: [CAMediaTimingFunction] = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0),
            CAMediaTimingFunction(controlPoints: 0.55, 0.0, 0.85, 0.6),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
        ]

        let bounceY = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounceY.values = [0.0, -0.7, 5.0, -1.0, 0.7, 0.0, 0.0]
        bounceY.keyTimes = keyTimes
        bounceY.timingFunctions = timingFunctions

        let scaleX = CAKeyframeAnimation(keyPath: "transform.scale.x")
        scaleX.values = [1.0, 1.24, 0.82, 1.26, 0.92, 1.0, 1.0]
        scaleX.keyTimes = keyTimes
        scaleX.timingFunctions = timingFunctions

        let scaleY = CAKeyframeAnimation(keyPath: "transform.scale.y")
        scaleY.values = [1.0, 0.76, 1.24, 0.76, 1.08, 1.0, 1.0]
        scaleY.keyTimes = keyTimes
        scaleY.timingFunctions = timingFunctions

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.55, 0.85, 1.0, 0.92, 0.68, 0.55, 0.55]
        opacity.keyTimes = keyTimes

        let group = CAAnimationGroup()
        group.animations = [bounceY, scaleX, scaleY, opacity]
        group.duration = 1.15
        group.beginTime = CACurrentMediaTime() + delay
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        layer.opacity = 0.55
        layer.add(group, forKey: "jellyBounce")
    }

    /// 每次有新帧净增拼接时，给三颗点一次轻巧的 Q 弹缩放反馈
    func pulseOnGrowth() {
        for (i, dot) in dotLayers.enumerated() {
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [1.0, 1.32, 0.90, 1.06, 1.0]
            pop.keyTimes = [0.0, 0.25, 0.58, 0.82, 1.0]
            pop.duration = 0.28
            pop.beginTime = CACurrentMediaTime() + CFTimeInterval(i) * 0.035
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dot.add(pop, forKey: "growthPop")
        }
    }

    private static func capturingText(screens: Double, heightPx: Int) -> NSAttributedString {
        let screenStr = String(format: "%.1f", max(1.0, screens))
        let text = "已拼接 \(screenStr) 屏 · \(heightPx) px · Enter 完成"
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: DesignTokens.label1,
        ])
    }

    private static func containedText(screens: Double) -> NSAttributedString {
        let screenStr = String(format: "%.1f", max(1.0, screens))
        let text = "已在已采集区 · \(screenStr) 屏 · Enter 完成"
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78),
        ])
    }

    // MARK: - 状态更新

    private var lastStateKind: String = ""

    func update(state: State) {
        let kind: String
        switch state {
        case .waiting:
            kind = "waiting"
            countLabel.attributedStringValue = Self.hintText("等待滚动… · Enter 结束")
            setDotsColor(DesignTokens.accent)
        case .capturing(let screens, let heightPx):
            kind = "capturing"
            countLabel.attributedStringValue = Self.capturingText(screens: screens, heightPx: heightPx)
            setDotsColor(DesignTokens.accent)
        case .contained(let screens, _):
            kind = "contained"
            countLabel.attributedStringValue = Self.containedText(screens: screens)
            setDotsColor(DesignTokens.statusOK)
        case .dropped:
            kind = "dropped"
            countLabel.attributedStringValue = Self.hintText("滚动过快，请放慢")
            setDotsColor(DesignTokens.statusWarn)
        }
        let stateChanged = kind != lastStateKind
        lastStateKind = kind
        contentView?.layoutSubtreeIfNeeded()
        if stateChanged {
            crossfade(capturingStack)
        }
        adjustWindowSize(animated: stateChanged)
    }

    private func setDotsColor(_ color: NSColor) {
        let cg = color.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dotLayers {
            dot.backgroundColor = cg
        }
        CATransaction.commit()
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

    /// 到底/到顶：切确认态（呼吸点/帧数 crossfade 出、OK 态 crossfade 入）
    func setBottomState(isTop: Bool = false) {
        okLabel.stringValue = isTop ? "已到顶 · 自动合成" : "已到底 · 自动合成"
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

    /// 到底撤销：回采集态（用户又继续滚，scroll.bottom.revoked 配套）
    func setCapturingState() {
        capturingStack.isHidden = false
        capturingStack.alphaValue = 1
        okStack.isHidden = true
        contentView?.layoutSubtreeIfNeeded()
        adjustWindowSize()
    }

    /// HUD 贴选区下缘 8pt 居中（§9：贴选区下缘 8pt，窗体含四周 shadowMargin）
    func reposition(below selectionGlobal: CGRect, on screen: NSScreen) {
        anchorSelectionGlobal = selectionGlobal
        anchorScreen = screen
        glassView.layoutSubtreeIfNeeded()
        let pillSize = glassView.fittingSize
        setFrame(targetFrame(forPillSize: pillSize, below: selectionGlobal, on: screen), display: true)
        updateShadowPath(forPillSize: pillSize)
    }

    private func updateShadowPath(forPillSize pillSize: NSSize) {
        let w = max(pillSize.width, 120)
        let h = pillSize.height
        shadowView.layer?.shadowPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
            cornerWidth: DesignTokens.Radius.lg,
            cornerHeight: DesignTokens.Radius.lg,
            transform: nil
        )
    }

    private func targetFrame(forPillSize size: NSSize, below selectionGlobal: CGRect, on screen: NSScreen) -> NSRect {
        let m = Self.shadowMargin
        let width = max(size.width, 120)
        let height = size.height
        let visible = screen.visibleFrame
        var origin = CGPoint(
            x: selectionGlobal.midX - width / 2,
            y: selectionGlobal.minY - height - DesignTokens.Scroll.hudOffsetFromSelection
        )
        // 放不下（贴屏底）翻到选区上方；再夹回可视区
        if origin.y < visible.minY + 4 {
            origin.y = selectionGlobal.maxY + DesignTokens.Scroll.hudOffsetFromSelection
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - height - 4)
        return NSRect(x: origin.x - m, y: origin.y - m, width: width + m * 2, height: height + m * 2)
    }

    func show(below selectionGlobal: CGRect, on screen: NSScreen) {
        anchorSelectionGlobal = selectionGlobal
        anchorScreen = screen
        contentView?.layoutSubtreeIfNeeded()
        reposition(below: selectionGlobal, on: screen)
        let finalFrame = frame
        let reduce = DesignTokens.Motion.reduceMotion
        setFrameOrigin(CGPoint(x: finalFrame.minX, y: finalFrame.minY - (reduce ? 0 : 6)))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            if !reduce { self.animator().setFrame(finalFrame, display: true) }
            self.animator().alphaValue = 1
        }
    }

    /// 退场：fade 0.14s strong ease-out（杜绝 ease-in）
    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.exitDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1   // 复位，下次 show() 从 0 起动画
        })
    }

    /// 内容自适应窗口尺寸（栈 fitting + padding），始终基于锚定选区居中，杜绝宽度微抖与水平漂移
    private func adjustWindowSize(animated: Bool = true) {
        glassView.layoutSubtreeIfNeeded()
        let size = glassView.fittingSize
        let nextFrame: NSRect
        if let sel = anchorSelectionGlobal, let screen = anchorScreen {
            nextFrame = targetFrame(forPillSize: size, below: sel, on: screen)
        } else {
            let m = Self.shadowMargin
            let width = max(size.width, 120) + m * 2
            let height = size.height + m * 2
            var f = self.frame
            f.origin.x += (f.width - width) / 2
            f.origin.y += f.height - height
            f.size = NSSize(width: width, height: height)
            nextFrame = f
        }
        updateShadowPath(forPillSize: size)
        let widthDelta = abs(nextFrame.width - self.frame.width)
        let heightDelta = abs(nextFrame.height - self.frame.height)
        guard widthDelta >= 1 || heightDelta >= 1 else { return }
        // 数字位数小幅变化不走弹跳，状态切换且变化显著时才柔和过渡
        guard animated && widthDelta > 6 && !DesignTokens.Motion.reduceMotion else {
            setFrame(nextFrame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.animator().setFrame(nextFrame, display: true)
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

    /// 到底撤销（用户又继续滚）：清绿条恢复脉动
    func clearBottomReached() {
        bottomBarLayer.isHidden = true
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = DesignTokens.Motion.pulseAlphaMin
        anim.toValue = DesignTokens.Motion.pulseAlphaMax
        anim.duration = DesignTokens.Motion.pulseDuration
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(anim, forKey: "motion.pulse")
    }
}
