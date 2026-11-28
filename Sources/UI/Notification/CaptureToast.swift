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

    static func show(image: CGImage, message: String = "已复制到剪贴板",
                     onClick: (() -> Void)? = nil) {
        // 连续截图：旧 toast 0.1s 快 fade 再上新，避免叠影硬切
        dismissWork?.cancel()
        retireCurrentToast()

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = onClick != nil ? 284 : 268
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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // 背景：mat.hud 自适应玻璃（radius 14 + maskImage 零白角 + 双层光学影 + 顶缘高光）
        let (outer, effect) = makeCardContainer(
            cardWidth: width, cardHeight: height, cornerRadius: DesignTokens.Radius.xl
        )

        // 缩略图（独立阴影托架 + 56pt 圆角 7 + 精细 0.5pt 边界线，告别贴死在灰板上的廉价感）
        let thumbSide = DesignTokens.Toast.thumbSide
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
        let textX = thumbSide + 20
        let rightReserve: CGFloat = onClick != nil ? 28 : 14
        let title = NSTextField(labelWithString: message)
        title.font = DesignTokens.Font.head
        title.textColor = DesignTokens.label1
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: textX, y: height - 34, width: width - textX - rightReserve, height: 18)

        let detailText = onClick != nil
            ? "\(image.width) × \(image.height) · 点击编辑"
            : "\(image.width) × \(image.height) · PNG"
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

        // 点击打开编辑：停留延长到 5s，且鼠标悬停时暂停倒计时（移出后 1.8s 退场），
        // 绝不出现「还没来得及点就消失」；点击立即取消退场定时并打开截图编辑器。
        if let onClick {
            panel.ignoresMouseEvents = false
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
            clickView.onClick = { [weak panel] in
                guard let panel else { return }
                dismissWork?.cancel()
                dismissWork = nil
                panel.orderOut(nil)
                if current === panel { current = nil }
                onClick()
            }
            effect.addSubview(clickView)
            clickView.autoresizingMask = [.width, .height]
            scheduleDismiss(after: 5.0)
        } else {
            scheduleDismiss(after: 3.0)
        }
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

/// toast 点击与悬停层（全幅 hit-test，首击激活，悬停暂停自动消失 + 轻按触觉反馈）
private final class ToastClickView: NSView {
    weak var targetCard: NSView?
    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovering = false

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
        if let card = targetCard {
            TactilePress.animate(view: card, pressed: true, scale: 0.985)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let card = targetCard {
            TactilePress.animate(view: card, pressed: false)
        }
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
