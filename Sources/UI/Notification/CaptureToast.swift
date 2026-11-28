import AppKit
import CoreGraphics

/// 复制成功反馈（重设计 scene 05：缩略图 + 「已复制到剪贴板」+ 尺寸格式）
///
/// 视觉真源：snapcut-design-redesign scene 05；token 取自 DesignTokens（§9 Toast 规格）：
/// - 图片版 268×76、radius 14、padding 10、缩略图 56 radius 6 + 0.5pt 白 .22 描边
/// - 纯文案版：高 40、radius 10、12/500 + 状态色图标 15（只表达状态）
/// - mat.hud（钉暗窗口内解析暗玻璃）、描边 stroke（白 .14）、数字 tabular-nums
/// - 入场：淡入 + 上滑 12pt、0.22s spring（motion.spring）
///
/// 设计纪律：
/// - 不抢焦点（.nonactivatingPanel，ignoresMouseEvents = true）——截完图用户要马上继续干活
/// - 不写入截图（它在截图会话结束之后才出现，且不属于覆盖层）
/// - 2 秒自动消失，淡出 + 轻微下滑
@MainActor
enum CaptureToast {
    /// 纯文案 toast 的状态语义（状态色只表达状态，不做装饰）
    @MainActor
    enum Status {
        case ok
        case warn

        var color: NSColor {
            switch self {
            case .ok: return DesignTokens.statusOK
            case .warn: return DesignTokens.statusWarn
            }
        }

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle"
            case .warn: return "exclamationmark.circle"
            }
        }
    }

    private static var current: NSPanel?
    private static var dismissWork: DispatchWorkItem?
    /// 窗口外扩留白专供圆角投影绘制（杜绝 panel.hasShadow=true + borderless NSVisualEffectView 的四个白色直角）
    private static let shadowMargin: CGFloat = 16

    /// 构造带双层 Apple 光学圆角投影 + 自适应玻璃（maskImage 零白角 + 对称顶缘镜面高光）的容器
    private static func makeCardContainer(
        cardWidth: CGFloat, cardHeight: CGFloat, cornerRadius: CGFloat
    ) -> (outer: ToastOuterView, effect: NSVisualEffectView) {
        let m = shadowMargin
        let outer = ToastOuterView(frame: NSRect(x: 0, y: 0, width: cardWidth + m * 2, height: cardHeight + m * 2))
        outer.wantsLayer = true

        let cardRect = NSRect(x: m, y: m, width: cardWidth, height: cardHeight)
        outer.cardFrame = cardRect

        let shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: cardRect.size),
            cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        )
        // 双层光学影：柔散环境影 + 贴边接触影（层次贴近 macOS 通知中心卡片）
        let ambientShadow = NSView(frame: cardRect)
        ambientShadow.wantsLayer = true
        ambientShadow.layer?.backgroundColor = NSColor.clear.cgColor
        ambientShadow.layer?.shadowColor = NSColor.black.cgColor
        ambientShadow.layer?.shadowOpacity = 0.20
        ambientShadow.layer?.shadowRadius = 14
        ambientShadow.layer?.shadowOffset = CGSize(width: 0, height: -6)
        ambientShadow.layer?.shadowPath = shadowPath
        outer.addSubview(ambientShadow)

        let contactShadow = NSView(frame: cardRect)
        contactShadow.wantsLayer = true
        contactShadow.layer?.backgroundColor = NSColor.clear.cgColor
        contactShadow.layer?.shadowColor = NSColor.black.cgColor
        contactShadow.layer?.shadowOpacity = 0.12
        contactShadow.layer?.shadowRadius = 3
        contactShadow.layer?.shadowOffset = CGSize(width: 0, height: -1)
        contactShadow.layer?.shadowPath = shadowPath
        outer.addSubview(contactShadow)

        let effect = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: cornerRadius
        )
        effect.frame = cardRect
        outer.addSubview(effect)
        return (outer, effect)
    }

    /// 退场动效：strong ease-out（绝不用 ease-in 拖慢收尾）+ 轻落 6pt；reduceMotion 时仅淡出
    private static func playExit(panel: NSPanel, duration: TimeInterval, completion: (() -> Void)? = nil) {
        let reduce = DesignTokens.Motion.reduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 0
            if !reduce {
                var sinkFrame = panel.frame
                sinkFrame.origin.y -= 6
                panel.animator().setFrameOrigin(sinkFrame.origin)
            }
        }, completionHandler: {
            panel.orderOut(nil)
            completion?()
        })
    }

    /// 连续截图替换旧 toast：0.1s strong ease-out 快 fade 再上新
    private static func retireCurrentToast() {
        guard let old = current else { return }
        current = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            old.animator().alphaValue = 0
        }, completionHandler: { old.orderOut(nil) })
    }

    /// 纯文案 toast（无缩略图）：系统级提示用（如菜单栏溢出告知 / 滚动回退告知）。
    /// 同样不抢焦点，2.5 秒自动消失。status 缺省 nil = 不带状态图标。
    static func show(message: String, status: Status? = nil) {
        dismissWork?.cancel()
        retireCurrentToast()

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame

        // 宽度随文案自适应（上限屏宽 - 40），避免长文案被裁切
        let probe = NSTextField(labelWithString: message)
        probe.font = .systemFont(ofSize: 12, weight: .medium)
        let iconSpace: CGFloat = status == nil ? 0 : 15 + 10
        let textWidth = probe.intrinsicContentSize.width + 32 + iconSpace
        let width = min(max(180, textWidth), visible.width - 40)
        let height: CGFloat = DesignTokens.Toast.textHeight

        let m = shadowMargin
        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width + m * 2, height: height + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let (outer, effect) = makeCardContainer(
            cardWidth: width, cardHeight: height, cornerRadius: DesignTokens.Radius.lg
        )

        var views: [NSView] = []
        if let status {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            icon.contentTintColor = status.color
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 15).isActive = true
            views.append(icon)
        }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = DesignTokens.label1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        views.append(label)
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: effect.leadingAnchor, constant: 14),
        ])
        panel.contentView = outer

        let restOrigin = CGPoint(
            x: visible.maxX - width - DesignTokens.Toast.screenMargin - m,
            y: visible.minY + DesignTokens.Toast.screenMargin - m
        )
        let reduce = DesignTokens.Motion.reduceMotion
        panel.setFrameOrigin(CGPoint(x: restOrigin.x, y: restOrigin.y - (reduce ? 0 : 10)))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 1
            if !reduce { panel.animator().setFrameOrigin(restOrigin) }
        }
        current = panel

        let work = DispatchWorkItem {
            guard current === panel else { return }
            playExit(panel: panel, duration: DesignTokens.Motion.exitDuration) {
                if current === panel { current = nil }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if current === panel {
                    panel.orderOut(nil)
                    current = nil
                }
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        Log.event(.app, "toast.show", ["kind": "text", "msg": message])
    }

    /// 取色完成反馈（功能 #3 一键取色闭环的收尾一拍）：色卡芯片 + 当前格式色值
    ///
    /// 视觉真源沿本文件既有体系：
    /// - 248×64（色值较长时最多扩到 284）、radius 14（`Radius.xl`）、`mat.hud` 自适应玻璃 + 双层光学影
    /// - 左侧 36×36 圆角 9 纯色芯片：采样色填充 + **自适应** 0.5pt 发丝边（亮色压暗边、暗色提白边，
    ///   否则纯白/纯黑采样会与玻璃底融成一片）+ 柔和阴影
    /// - 主行 `formatted`（等宽加粗 label1，HEX/RGB/HSL 数字不跳字）、副行 `已复制色值 · secondary`
    /// - 右下角入场同 `show(image:)`；2.2s 自动退场（`playExit` + 0.6s 强制收窗双保险）
    /// - 不抢焦点也不吃鼠标（`ignoresMouseEvents = true`）——取色时用户可能在连续拖拽
    static func showColorCopied(
        formatted: String,
        secondary: String,
        r: Int,
        g: Int,
        b: Int
    ) {
        dismissWork?.cancel()
        retireCurrentToast()

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame

        let chipSide: CGFloat = 36
        let textX: CGFloat = 10 + chipSide + 12
        let mainFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let subFont = DesignTokens.Font.monoDigit(11)
        let secondaryLine = "已复制色值 · \(secondary)"
        let mainWidth = (formatted as NSString).size(withAttributes: [.font: mainFont]).width
        let subWidth = (secondaryLine as NSString).size(withAttributes: [.font: subFont]).width
        // 248 起；色值更长时按真实字宽扩（上限 284，label 另有尾部截断兜底）
        let width: CGFloat = min(284, max(248, ceil(textX + max(mainWidth, subWidth) + 12)))
        let height: CGFloat = 64

        let m = shadowMargin
        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width + m * 2, height: height + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let (outer, effect) = makeCardContainer(
            cardWidth: width, cardHeight: height, cornerRadius: DesignTokens.Radius.xl
        )

        let chip = makeColorChip(r: r, g: g, b: b, side: chipSide, radius: 9)
        chip.frame.origin = CGPoint(x: 10, y: (height - chipSide) / 2)
        effect.addSubview(chip)

        // 两行文字垂直居中：主行 17 + 间距 4 + 副行 14 = 35，上下各留 14.5
        let valueLabel = NSTextField(labelWithString: formatted)
        valueLabel.font = mainFont
        valueLabel.textColor = DesignTokens.label1
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.frame = NSRect(x: textX, y: height - 14.5 - 17, width: width - textX - 12, height: 17)
        effect.addSubview(valueLabel)

        let noteLabel = NSTextField(labelWithString: secondaryLine)
        noteLabel.font = subFont
        noteLabel.textColor = DesignTokens.label2
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.frame = NSRect(x: textX, y: height - 14.5 - 17 - 4 - 14, width: width - textX - 12, height: 14)
        effect.addSubview(noteLabel)

        panel.contentView = outer

        let restOrigin = CGPoint(
            x: visible.maxX - width - 20 - m,
            y: visible.minY + 20 - m
        )
        let reduce = DesignTokens.Motion.reduceMotion
        panel.setFrameOrigin(CGPoint(x: restOrigin.x, y: restOrigin.y - (reduce ? 0 : 10)))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 1
            if !reduce { panel.animator().setFrameOrigin(restOrigin) }
        }
        current = panel

        let work = DispatchWorkItem {
            guard current === panel else { return }
            playExit(panel: panel, duration: DesignTokens.Motion.exitDuration) {
                if current === panel { current = nil }
            }
            // 双保险（NSAnimationContext completion 偶发不触发 → 0.6s 后无条件收窗）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if current === panel {
                    panel.orderOut(nil)
                    current = nil
                    Log.event(.app, "toast.exit.forced", [:])
                }
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
        Log.event(.app, "toast.colorCopied", ["value": formatted])
    }

    /// 色卡芯片：纯色圆角方块 + 自适应发丝边 + 柔和阴影
    ///
    /// 发丝边为什么自适应：纯白采样（#FFFFFF）在暗玻璃上是“无边”的，纯黑采样（#000000）也会糊掉，
    /// 按采样亮度切换黑/白半透明描边，任何颜色都有清晰轮廓且不显脏。
    private static func makeColorChip(r: Int, g: Int, b: Int, side: CGFloat, radius: CGFloat) -> NSView {
        let holder = NSView(frame: NSRect(origin: .zero, size: NSSize(width: side, height: side)))
        holder.wantsLayer = true
        holder.layer?.shadowColor = NSColor.black.cgColor
        holder.layer?.shadowOpacity = 0.18
        holder.layer?.shadowRadius = 4
        holder.layer?.shadowOffset = CGSize(width: 0, height: -1)
        holder.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: NSSize(width: side, height: side)),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        )

        let chip = NSView(frame: NSRect(origin: .zero, size: NSSize(width: side, height: side)))
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor(
            srgbRed: CGFloat(min(255, max(0, r))) / 255,
            green: CGFloat(min(255, max(0, g))) / 255,
            blue: CGFloat(min(255, max(0, b))) / 255,
            alpha: 1
        ).cgColor
        chip.layer?.cornerRadius = radius
        chip.layer?.cornerCurve = .continuous
        chip.layer?.masksToBounds = true
        chip.layer?.borderWidth = 0.5
        let luminance = (0.2126 * CGFloat(r) + 0.7152 * CGFloat(g) + 0.0722 * CGFloat(b)) / 255
        chip.layer?.borderColor = luminance > 0.72
            ? NSColor.black.withAlphaComponent(0.20).cgColor
            : NSColor.white.withAlphaComponent(0.28).cgColor

        holder.addSubview(chip)
        return holder
    }

    static func show(image: CGImage, message: String = "已复制到剪贴板",
                     onClick: (() -> Void)? = nil) {
        // 连续截图：旧 toast 0.1s 快 fade 再上新，避免叠影硬切
        dismissWork?.cancel()
        retireCurrentToast()

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        // 尺寸角标 + 拖出提示比原来的「点击编辑」长，放不下就按规格扩到 296（上限 320），绝不裁切/压字
        let thumbSide = DesignTokens.Toast.thumbSide
        let textX: CGFloat = thumbSide + 20
        let rightReserve: CGFloat = onClick != nil ? 28 : 14
        let detailText = onClick != nil
            ? "\(image.width) × \(image.height) · 点击编辑或拖出"
            : "\(image.width) × \(image.height) · 按住可拖出"
        let titleWidth = (message as NSString).size(withAttributes: [.font: DesignTokens.Font.head]).width
        let detailWidth = (detailText as NSString)
            .size(withAttributes: [.font: DesignTokens.Font.monoDigit(11)]).width
        let neededWidth = textX + rightReserve + max(titleWidth, detailWidth)
        var width: CGFloat = onClick != nil ? 284 : 268
        if neededWidth > width { width = min(320, max(296, ceil(neededWidth))) }
        let height: CGFloat = 76

        let m = shadowMargin
        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width + m * 2, height: height + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 图片 Toast 一律允许鼠标交互：无论能否点击编辑，都要支持「按住随手拖出 PNG 文件」
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // 背景：mat.hud 自适应玻璃（radius 14 + maskImage 零白角 + 双层光学影 + 顶缘高光）
        let (outer, effect) = makeCardContainer(
            cardWidth: width, cardHeight: height, cornerRadius: DesignTokens.Radius.xl
        )

        // 缩略图（独立阴影托架 + 56pt 圆角 7 + 精细 0.5pt 边界线，告别贴死在灰板上的廉价感）
        let thumbHolder = NSView(frame: NSRect(x: 10, y: 10, width: thumbSide, height: thumbSide))
        thumbHolder.wantsLayer = true
        thumbHolder.layer?.shadowColor = NSColor.black.cgColor
        thumbHolder.layer?.shadowOpacity = 0.16
        thumbHolder.layer?.shadowRadius = 4
        thumbHolder.layer?.shadowOffset = CGSize(width: 0, height: -1)
        thumbHolder.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: NSSize(width: thumbSide, height: thumbSide)),
            cornerWidth: 7, cornerHeight: 7, transform: nil
        )
        let thumbView = NSImageView(frame: NSRect(origin: .zero, size: NSSize(width: thumbSide, height: thumbSide)))
        thumbView.image = NSImage(cgImage: image, size: NSSize(width: thumbSide, height: thumbSide))
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 7
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 0.5
        thumbView.layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
        thumbHolder.addSubview(thumbView)
        effect.addSubview(thumbHolder)

        // 文案两行：t.head 主文案 + t.note 尺寸/操作提示（数字 tabular-nums）
        let title = NSTextField(labelWithString: message)
        title.font = DesignTokens.Font.head
        title.textColor = DesignTokens.label1
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: textX, y: height - 34, width: width - textX - rightReserve, height: 18)

        let detail = NSTextField(labelWithString: detailText)
        detail.font = DesignTokens.Font.monoDigit(11)
        detail.textColor = DesignTokens.label2
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: textX, y: height - 53, width: width - textX - rightReserve, height: 15)

        effect.addSubview(title)
        effect.addSubview(detail)

        // 可点击提示箭头（悬停时轻移 2pt + 提亮，符合 Apple 交互线索）
        var chevronView: NSImageView?
        if onClick != nil {
            let chevron = NSImageView(frame: NSRect(x: width - 22, y: (height - 13) / 2, width: 10, height: 13))
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "编辑")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            chevron.contentTintColor = DesignTokens.label3
            chevron.wantsLayer = true
            effect.addSubview(chevron)
            chevronView = chevron
        }
        panel.contentView = outer

        // 入场：右下角强缓出轻浮入场（无橡胶过冲；reduceMotion 时纯淡入）
        let restOrigin = CGPoint(
            x: visible.maxX - width - 20 - m,
            y: visible.minY + 20 - m
        )
        let reduce = DesignTokens.Motion.reduceMotion
        panel.setFrameOrigin(CGPoint(x: restOrigin.x, y: restOrigin.y - (reduce ? 0 : 10)))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 1
            if !reduce { panel.animator().setFrameOrigin(restOrigin) }
        }
        current = panel

        func scheduleDismiss(after delay: TimeInterval) {
            dismissWork?.cancel()
            let work = DispatchWorkItem {
                guard current === panel else { return }
                playExit(panel: panel, duration: DesignTokens.Motion.exitDuration) {
                    if current === panel { current = nil }
                }
                // 双保险（NSAnimationContext completion 偶发不触发 → 0.6s 后无条件收窗）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if current === panel {
                        panel.orderOut(nil)
                        current = nil
                        Log.event(.app, "toast.exit.forced", [:])
                    }
                }
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        /// 立即优雅退场（拖出成功放下 / 点击后收窗用，不再等倒计时）
        func dismissNow() {
            dismissWork?.cancel()
            dismissWork = nil
            guard current === panel else { return }
            playExit(panel: panel, duration: DesignTokens.Motion.exitDuration) {
                if current === panel { current = nil }
            }
            // 双保险（NSAnimationContext completion 偶发不触发 → 0.6s 后无条件收窗）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if current === panel {
                    panel.orderOut(nil)
                    current = nil
                    Log.event(.app, "toast.exit.forced", [:])
                }
            }
        }

        // 整卡交互层（功能 #2 随手拖拽出图）：
        // - 有 onClick 时单击编辑（停留延长到 5s）；两种形态都支持「按住拖出 PNG」
        // - 悬停暂停倒计时（移出后 1.8s 退场），绝不出现「还没来得及用就消失」
        // - 起拖（位移 ≥ 5pt）时掐掉自动退场：拖到一半卡片自己消失是最糟的手感；
        //   放下成功立即优雅收窗，取消拖放则重新排 1.8s
        let clickView = ToastClickView(frame: effect.bounds)
        clickView.targetCard = effect
        clickView.onHoverChange = { [weak panel, weak chevronView] hovering in
            guard let panel, current === panel else { return }
            if let chevron = chevronView {
                chevron.contentTintColor = hovering ? DesignTokens.label1 : DesignTokens.label3
                if !DesignTokens.Motion.reduceMotion {
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.14)
                    CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
                    chevron.layer?.transform = hovering
                        ? CATransform3DMakeTranslation(2, 0, 0)
                        : CATransform3DIdentity
                    CATransaction.commit()
                }
            }
            if hovering {
                dismissWork?.cancel()
                dismissWork = nil
            } else {
                scheduleDismiss(after: 1.8)
            }
        }
        clickView.onBeginDrag = { [weak panel] event, sourceView in
            guard let panel, current === panel else { return false }
            dismissWork?.cancel()
            dismissWork = nil
            let started = ImageDragCoordinator.shared.beginImageDrag(
                cgImage: image,
                suggestedName: "Snapcut-\(image.width)x\(image.height).png",
                from: sourceView,
                event: event,
                onEnd: { dropped in
                    if dropped {
                        dismissNow()
                    } else {
                        scheduleDismiss(after: 1.8)
                    }
                }
            )
            // 起拖被拒（已有会话在跑 / 临时文件写失败）时把退场计时接回来，不留僵尸卡片
            if !started { scheduleDismiss(after: 1.8) }
            return started
        }
        if let onClick {
            clickView.onClick = { [weak panel] in
                guard let panel else { return }
                dismissWork?.cancel()
                dismissWork = nil
                panel.orderOut(nil)
                if current === panel { current = nil }
                onClick()
            }
        }
        effect.addSubview(clickView)
        clickView.autoresizingMask = [.width, .height]
        scheduleDismiss(after: onClick != nil ? 5.0 : 3.0)
        Log.event(.app, "toast.show", [
            "pxW": "\(image.width)", "pxH": "\(image.height)",
            "clickable": "\(onClick != nil)",
        ])
    }

    /// 外部剪贴板检测到图片（CLIP-B）：轻提示 + 一步直达「贴图划词 / 提取排版」
    ///
    /// 视觉与交互 100% 复用本类型既有体系（双层光学投影 + `mat.hud` 玻璃 + `ToastActionPillButton`）：
    /// - 卡片 326×82、radius 14（`Radius.xl`）、缩略图 56×56 圆角 8 + 0.5pt 白 .22 描边
    /// - 主标题 `Font.head` / label1；副信息 `monoDigit(11)` / label2（宽×高 · 约 N 字）
    /// - 右下两个紧凑胶囊：accent 主按钮「贴图划词」+ 克制灰底次按钮「提取排版」
    /// - 右上角安全区（visibleFrame 已排除菜单栏与 Dock）；淡入 + 上滑 12pt、0.22s easeOutStrong
    /// - 默认 4.5s 退场；鼠标移入任意区域取消倒计时，移出 1.8s 后退场
    static func showClipboardImageDetected(
        thumbnail: CGImage,
        pixelSize: CGSize,
        hasText: Bool,
        hasQR: Bool,
        charCount: Int,
        onPinLiveText: @escaping @MainActor () -> Void,
        onExtractOCR: @escaping @MainActor () -> Void
    ) {
        dismissWork?.cancel()
        retireCurrentToast()

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = 326
        let height: CGFloat = 82
        let m = shadowMargin

        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width + m * 2, height: height + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let (outer, effect) = makeCardContainer(
            cardWidth: width, cardHeight: height, cornerRadius: DesignTokens.Radius.xl
        )

        // 收窗（动作按钮 / 关闭钮共用）：立即收起，不留残余倒计时
        func closeToast() {
            dismissWork?.cancel()
            dismissWork = nil
            panel.orderOut(nil)
            if current === panel { current = nil }
        }

        // 左侧缩略图（56×56 圆角 8 + 0.5pt 白 .22 描边，垂直居中）
        let thumbSide: CGFloat = 56
        let thumb = makeClipboardThumbnailView(image: thumbnail, side: thumbSide)
        thumb.frame.origin = CGPoint(x: 10, y: (height - thumbSide) / 2)
        effect.addSubview(thumb)

        let textX: CGFloat = 10 + thumbSide + 10
        let closeReserve: CGFloat = 30

        // 主标题：按检测结果三态
        let titleText: String
        if hasText && hasQR {
            titleText = "检测到图片文字与二维码"
        } else if !hasText && hasQR {
            titleText = "检测到图片二维码"
        } else {
            titleText = "检测到图片文字"
        }
        let title = NSTextField(labelWithString: titleText)
        title.font = DesignTokens.Font.head
        title.textColor = DesignTokens.label1
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(
            x: textX,
            y: height - 10 - 18,
            width: width - textX - closeReserve,
            height: 18
        )
        effect.addSubview(title)

        // 副信息：像素尺寸（数字 tabular-nums），有文字时追加「约 N 字」
        var detailText = "\(Int(pixelSize.width))×\(Int(pixelSize.height))"
        if hasText && charCount > 0 {
            detailText += " · 约 \(charCount) 字"
        }
        let detail = NSTextField(labelWithString: detailText)
        detail.font = DesignTokens.Font.monoDigit(11)
        detail.textColor = DesignTokens.label2
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: textX, y: height - 10 - 18 - 15, width: width - textX - closeReserve, height: 15)
        effect.addSubview(detail)

        // 整卡点击层（位于缩略图/文字之上，关闭钮与底部双钮之下）：
        // 单击缩略图或卡片主区域直接触发「贴图划词」，不强迫用户瞄准小按钮
        let cardClickView = ToastClickView(frame: effect.bounds)
        cardClickView.targetCard = effect
        cardClickView.autoresizingMask = [.width, .height]
        cardClickView.onClick = {
            closeToast()
            onPinLiveText()
        }
        effect.addSubview(cardClickView)

        // 右上关闭圆钮（置于点击层之上，点击仅收起不触发贴图）
        let closeBtn = ToastCloseButton {
            closeToast()
        }
        closeBtn.frame = NSRect(x: width - 10 - 22, y: height - 10 - 22, width: 22, height: 22)
        effect.addSubview(closeBtn)

        // 悬停防消失层（hitTest 穿透，整卡含按钮区域悬停均暂停倒计时）
        let hoverTracker = ToastCardHoverTracker(frame: effect.bounds)
        hoverTracker.onHoverChange = { [weak panel] inside in
            guard let panel, current === panel else { return }
            if inside {
                dismissWork?.cancel()
                dismissWork = nil
            } else {
                scheduleDismiss(after: 1.8)
            }
        }
        hoverTracker.autoresizingMask = [.width, .height]
        effect.addSubview(hoverTracker)

        func scheduleDismiss(after delay: TimeInterval) {
            dismissWork?.cancel()
            let work = DispatchWorkItem {
                guard current === panel else { return }
                playExit(panel: panel, duration: DesignTokens.Motion.exitDuration) {
                    if current === panel { current = nil }
                }
                // 双保险（NSAnimationContext completion 偶发不触发 → 0.6s 后无条件收窗）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if current === panel {
                        panel.orderOut(nil)
                        current = nil
                        Log.event(.app, "toast.exit.forced", [:])
                    }
                }
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        // 右下动作区：主「贴图划词」（accent）+ 次「提取排版」（克制灰底），置于点击层之上各自独立响应
        let pinLiveTextBtn = ToastActionPillButton(
            symbol: "text.viewfinder",
            title: "贴图划词",
            style: .primary
        ) {
            closeToast()
            onPinLiveText()
        }
        let extractOCRBtn = ToastActionPillButton(
            symbol: "doc.text.viewfinder",
            title: "提取排版",
            style: .normal
        ) {
            closeToast()
            onExtractOCR()
        }
        let btnStack = NSStackView(views: [pinLiveTextBtn, extractOCRBtn])
        btnStack.orientation = .horizontal
        btnStack.alignment = .centerY
        btnStack.spacing = 6
        btnStack.frame = NSRect(x: textX, y: 9, width: width - textX - 10, height: 26)
        effect.addSubview(btnStack)

        panel.contentView = outer

        // 入场：统一右下角安全区（与截图 / 录屏完成 Toast 保持同一位置心智），淡入 + 上滑 10pt
        let restOrigin = CGPoint(
            x: visible.maxX - width - 20 - m,
            y: visible.minY + 20 - m
        )
        let reduce = DesignTokens.Motion.reduceMotion
        panel.setFrameOrigin(CGPoint(x: restOrigin.x, y: restOrigin.y - (reduce ? 0 : 10)))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 1
            if !reduce { panel.animator().setFrameOrigin(restOrigin) }
        }
        current = panel
        scheduleDismiss(after: 4.5)

        Log.event(.clipboard, "clipboard.toast.show", [
            "hasText": "\(hasText)", "hasQR": "\(hasQR)", "chars": "\(charCount)",
        ])
    }

    /// 剪贴板提示专用缩略图：圆角 8 + 0.5pt 白 .22 描边（比录制 Toast 的角标托架更纯净）
    private static func makeClipboardThumbnailView(image: CGImage, side: CGFloat) -> NSView {
        let holder = NSView(frame: NSRect(origin: .zero, size: NSSize(width: side, height: side)))
        holder.wantsLayer = true
        holder.layer?.shadowColor = NSColor.black.cgColor
        holder.layer?.shadowOpacity = 0.16
        holder.layer?.shadowRadius = 4
        holder.layer?.shadowOffset = CGSize(width: 0, height: -1)
        holder.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: NSSize(width: side, height: side)),
            cornerWidth: 8, cornerHeight: 8, transform: nil
        )

        let content = NSImageView(frame: NSRect(origin: .zero, size: NSSize(width: side, height: side)))
        content.image = NSImage(cgImage: image, size: NSSize(width: side, height: side))
        content.imageScaling = .scaleProportionallyUpOrDown
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        content.layer?.backgroundColor = DesignTokens.capsuleDark.cgColor

        holder.addSubview(content)
        return holder
    }

    /// 录屏 / GIF 保存完成 Toast：
    /// - 初始态与截图 Toast 同构（缩略图 + 格式角标 + 时长/体积 + 点击操作 ›）；
    /// - 点击后原地平滑展开为 Apple HUD 动作卡（复制文件 / 访达 / 打开 / 丢弃），不抢焦点。
    static func showRecording(
        _ result: RecordingResult,
        onCopyFile: @escaping @MainActor (URL) -> Void,
        onRevealInFinder: @escaping @MainActor (URL) -> Void,
        onOpen: @escaping @MainActor (URL) -> Void,
        onDiscard: @escaping @MainActor (URL) -> Void
    ) {
        dismissWork?.cancel()
        retireCurrentToast()

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = 296
        let height: CGFloat = 76
        let m = shadowMargin

        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width + m * 2, height: height + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let (outer, effect) = makeCardContainer(
            cardWidth: width, cardHeight: height, cornerRadius: DesignTokens.Radius.xl
        )

        let thumbSide = DesignTokens.Toast.thumbSide
        let thumbHolder = makeThumbnailView(
            image: result.thumbnail,
            side: thumbSide,
            badgeText: result.format.displayName
        )
        thumbHolder.frame.origin = CGPoint(x: 10, y: 10)
        effect.addSubview(thumbHolder)

        let textX = thumbSide + 20
        let rightReserve: CGFloat = 28
        let titleText = result.format == .mp4 ? "录屏已保存" : "GIF 已保存"
        let title = NSTextField(labelWithString: titleText)
        title.font = DesignTokens.Font.head
        title.textColor = DesignTokens.label1
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: textX, y: height - 34, width: width - textX - rightReserve, height: 18)

        let detail = NSTextField(labelWithString: "\(result.formattedDuration) · \(result.formattedSize) · 点击操作")
        detail.font = DesignTokens.Font.monoDigit(11)
        detail.textColor = DesignTokens.label2
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: textX, y: height - 53, width: width - textX - rightReserve, height: 15)

        let chevron = NSImageView(frame: NSRect(x: width - 22, y: (height - 13) / 2, width: 10, height: 13))
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "操作")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = DesignTokens.label3
        chevron.wantsLayer = true

        effect.addSubview(title)
        effect.addSubview(detail)
        effect.addSubview(chevron)
        panel.contentView = outer

        let restOrigin = CGPoint(
            x: visible.maxX - width - 20 - m,
            y: visible.minY + 20 - m
        )
        let reduce = DesignTokens.Motion.reduceMotion
        panel.setFrameOrigin(CGPoint(x: restOrigin.x, y: restOrigin.y - (reduce ? 0 : 10)))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 1
            if !reduce { panel.animator().setFrameOrigin(restOrigin) }
        }
        current = panel

        func scheduleDismiss(after delay: TimeInterval) {
            dismissWork?.cancel()
            let work = DispatchWorkItem {
                guard current === panel else { return }
                playExit(panel: panel, duration: DesignTokens.Motion.exitDuration) {
                    if current === panel { current = nil }
                }
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        let clickView = ToastClickView(frame: effect.bounds)
        clickView.targetCard = effect
        clickView.onHoverChange = { [weak panel, weak chevron] hovering in
            guard let panel, current === panel else { return }
            if let chevron {
                chevron.contentTintColor = hovering ? DesignTokens.label1 : DesignTokens.label3
                if !DesignTokens.Motion.reduceMotion {
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.14)
                    CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
                    chevron.layer?.transform = hovering
                        ? CATransform3DMakeTranslation(2, 0, 0)
                        : CATransform3DIdentity
                    CATransaction.commit()
                }
            }
            if hovering {
                dismissWork?.cancel()
                dismissWork = nil
            } else {
                scheduleDismiss(after: 2.0)
            }
        }
        clickView.onClick = { [weak panel] in
            guard let panel, current === panel else { return }
            dismissWork?.cancel()
            dismissWork = nil
            presentExpandedRecordingActions(
                replacing: panel,
                on: screen,
                result: result,
                onCopyFile: onCopyFile,
                onRevealInFinder: onRevealInFinder,
                onOpen: onOpen,
                onDiscard: onDiscard
            )
        }
        effect.addSubview(clickView)
        clickView.autoresizingMask = [.width, .height]
        scheduleDismiss(after: 6.0)

        Log.event(.recording, "recording.toast.show", [
            "format": result.format.rawValue,
            "bytes": "\(result.fileSizeBytes)",
        ])
    }

    private static func presentExpandedRecordingActions(
        replacing oldPanel: NSPanel,
        on screen: NSScreen,
        result: RecordingResult,
        onCopyFile: @escaping @MainActor (URL) -> Void,
        onRevealInFinder: @escaping @MainActor (URL) -> Void,
        onOpen: @escaping @MainActor (URL) -> Void,
        onDiscard: @escaping @MainActor (URL) -> Void
    ) {
        oldPanel.orderOut(nil)
        if current === oldPanel { current = nil }

        let visible = screen.visibleFrame
        let width: CGFloat = 334
        let height: CGFloat = 114
        let m = shadowMargin

        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width + m * 2, height: height + m * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let (outer, effect) = makeCardContainer(
            cardWidth: width, cardHeight: height, cornerRadius: DesignTokens.Radius.xl
        )

        func closeExpanded() {
            dismissWork?.cancel()
            dismissWork = nil
            playExit(panel: panel, duration: DesignTokens.Motion.exitDuration) {
                if current === panel { current = nil }
            }
        }

        func scheduleExpandedDismiss(after delay: TimeInterval) {
            dismissWork?.cancel()
            let work = DispatchWorkItem {
                guard current === panel else { return }
                closeExpanded()
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        // 顶部信息区
        let thumbSide: CGFloat = 42
        let thumbHolder = makeThumbnailView(
            image: result.thumbnail,
            side: thumbSide,
            badgeText: result.format.displayName
        )
        thumbHolder.frame.origin = CGPoint(x: 12, y: height - 12 - thumbSide)
        effect.addSubview(thumbHolder)

        let textX = 12 + thumbSide + 10
        let closeBtn = ToastCloseButton {
            closeExpanded()
        }
        closeBtn.frame = NSRect(x: width - 32, y: height - 32, width: 22, height: 22)
        effect.addSubview(closeBtn)

        let fileNameLabel = NSTextField(labelWithString: result.fileURL.lastPathComponent)
        fileNameLabel.font = DesignTokens.Font.head
        fileNameLabel.textColor = DesignTokens.label1
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.frame = NSRect(x: textX, y: height - 32, width: width - textX - 38, height: 18)
        effect.addSubview(fileNameLabel)

        let metaLabel = NSTextField(
            labelWithString: "\(result.formattedDuration) · \(result.formattedSize) · \(result.pixelWidth)×\(result.pixelHeight)"
        )
        metaLabel.font = DesignTokens.Font.monoDigit(11)
        metaLabel.textColor = DesignTokens.label2
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.frame = NSRect(x: textX, y: height - 50, width: width - textX - 16, height: 15)
        effect.addSubview(metaLabel)

        // 0.5pt 发丝分隔线
        let hair = NSView(frame: NSRect(x: 12, y: 48, width: width - 24, height: 0.5))
        hair.wantsLayer = true
        hair.layer?.backgroundColor = DesignTokens.hair.cgColor
        effect.addSubview(hair)

        // 底部操作按钮行
        let copyFileBtn = ToastActionPillButton(
            symbol: "doc.on.doc",
            title: "复制文件",
            style: .primary
        ) {
            dismissWork?.cancel()
            dismissWork = nil
            panel.orderOut(nil)
            if current === panel { current = nil }
            onCopyFile(result.fileURL)
        }
        let finderBtn = ToastActionPillButton(
            symbol: "folder",
            title: "访达",
            style: .normal
        ) {
            onRevealInFinder(result.fileURL)
            closeExpanded()
        }
        let openBtn = ToastActionPillButton(
            symbol: "play.circle",
            title: "预览",
            style: .normal
        ) {
            onOpen(result.fileURL)
            closeExpanded()
        }
        let discardBtn = ToastActionPillButton(
            symbol: "trash",
            title: "丢弃",
            style: .destructive
        ) {
            dismissWork?.cancel()
            dismissWork = nil
            panel.orderOut(nil)
            if current === panel { current = nil }
            onDiscard(result.fileURL)
        }

        let btnStack = NSStackView(views: [copyFileBtn, finderBtn, openBtn, discardBtn])
        btnStack.orientation = .horizontal
        btnStack.alignment = .centerY
        btnStack.spacing = 6
        btnStack.frame = NSRect(x: 12, y: 11, width: width - 24, height: 28)
        effect.addSubview(btnStack)

        let hoverTracker = ToastCardHoverTracker(frame: effect.bounds)
        hoverTracker.onHoverChange = { [weak panel] inside in
            guard let panel, current === panel else { return }
            if inside {
                dismissWork?.cancel()
                dismissWork = nil
            } else {
                scheduleExpandedDismiss(after: 4.0)
            }
        }
        hoverTracker.autoresizingMask = [.width, .height]
        effect.addSubview(hoverTracker, positioned: .below, relativeTo: closeBtn)

        panel.contentView = outer
        let origin = CGPoint(
            x: visible.maxX - width - 20 - m,
            y: visible.minY + 20 - m
        )
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0.92
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 1
        }
        current = panel
        scheduleExpandedDismiss(after: 6.5)
    }

    private static func makeThumbnailView(
        image: CGImage?,
        side: CGFloat,
        badgeText: String
    ) -> NSView {
        let holder = NSView(frame: NSRect(origin: .zero, size: NSSize(width: side, height: side)))
        holder.wantsLayer = true
        holder.layer?.shadowColor = NSColor.black.cgColor
        holder.layer?.shadowOpacity = 0.16
        holder.layer?.shadowRadius = 4
        holder.layer?.shadowOffset = CGSize(width: 0, height: -1)
        holder.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: NSSize(width: side, height: side)),
            cornerWidth: 7, cornerHeight: 7, transform: nil
        )

        let content = NSView(frame: NSRect(origin: .zero, size: NSSize(width: side, height: side)))
        content.wantsLayer = true
        content.layer?.cornerRadius = 7
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
        content.layer?.backgroundColor = DesignTokens.capsuleDark.cgColor

        if let image {
            let imgView = NSImageView(frame: content.bounds)
            imgView.image = NSImage(cgImage: image, size: NSSize(width: side, height: side))
            imgView.imageScaling = .scaleProportionallyUpOrDown
            content.addSubview(imgView)
        } else {
            let fallback = NSImageView(frame: content.bounds.insetBy(dx: 12, dy: 12))
            fallback.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            fallback.contentTintColor = DesignTokens.label1
            content.addSubview(fallback)
        }

        let badge = NSTextField(labelWithString: badgeText)
        badge.font = .systemFont(ofSize: 8.5, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        badge.layer?.cornerRadius = 3.5
        badge.frame = NSRect(x: side - 27, y: 3, width: 24, height: 12)
        content.addSubview(badge)

        holder.addSubview(content)
        return holder
    }
}

@MainActor
private final class ToastActionPillButton: NSView {
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

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon.contentTintColor = style.foreground
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = style.foreground
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

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

@MainActor
private final class ToastCloseButton: NSView {
    private let icon = NSImageView()
    private let onTap: () -> Void
    private var tracking: NSTrackingArea?

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        icon.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        icon.contentTintColor = DesignTokens.label2
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

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

@MainActor
private final class ToastCardHoverTracker: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// toast 点击/拖出与悬停层（全幅 hit-test，首击激活，悬停暂停自动消失 + 轻按触觉反馈）
///
/// 拖出判定：`mouseDown` 记锚点，`mouseDragged` 位移 ≥ 5pt 才起拖（与系统拖拽手势同参），
/// 起拖成功一次后 `mouseUp` 不再算点击 —— 避免“拖完图又弹出编辑器”的双触发。
private final class ToastClickView: NSView {
    weak var targetCard: NSView?
    var onClick: (() -> Void)?
    /// 起拖回调：返回 true 表示拖拽会话已被接管（此后本次 `mouseUp` 不再触发 onClick）
    var onBeginDrag: ((NSEvent, NSView) -> Bool)?
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovering = false
    /// 起拖位移阈值：5pt 以内仍当点击（手指/触控板微抖不算拖）
    private static let dragThreshold: CGFloat = 5
    private var pressPoint: NSPoint?
    private var didStartDrag = false
    private var didAttemptDrag = false

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

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isHovering {
            isHovering = true
            NSCursor.pointingHand.push()
        }
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        popHoverCursorIfNeeded()
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
        didAttemptDrag = false
        if let card = targetCard {
            TactilePress.animate(view: card, pressed: true, scale: 0.985)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, !didAttemptDrag, let start = pressPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x
        let dy = point.y - start.y
        guard (dx * dx + dy * dy).squareRoot() >= Self.dragThreshold else { return }
        // 只尝试一次：起拖失败（端口不接）就退回点击语义，不反复骚扰拖拽协调器
        didAttemptDrag = true
        if let card = targetCard {
            TactilePress.animate(view: card, pressed: false)
        }
        didStartDrag = onBeginDrag?(event, self) ?? false
        if didStartDrag { popHoverCursorIfNeeded() }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = didStartDrag
        pressPoint = nil
        didStartDrag = false
        didAttemptDrag = false
        if let card = targetCard {
            TactilePress.animate(view: card, pressed: false)
        }
        guard !wasDragging else { return }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return }
        popHoverCursorIfNeeded()
        onClick?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            popHoverCursorIfNeeded()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func popHoverCursorIfNeeded() {
        guard isHovering else { return }
        isHovering = false
        NSCursor.pop()
    }
}

/// 透明外框：卡片外的投影留白区 hitTest 返回 nil，点击穿透给桌面
private final class ToastOuterView: NSView {
    var cardFrame: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return cardFrame.contains(local) ? super.hitTest(point) : nil
    }
}

/// 不抢焦点的浮层（LSUIElement 下也可靠显示，HUD 档统一钉暗以保证白字与玻璃对比度）
private final class ToastPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
