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

    /// 退场动效：fade 0.18s + 下滑 6pt（motion.exit 的 toast 变体，兑现注释承诺）；
    /// completionHandler 里才 orderOut（不能只做动画不收窗）
    private static func playExit(panel: NSPanel, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            var sinkFrame = panel.frame
            sinkFrame.origin.y -= 6   // 下滑 6pt：AppKit y 向上，origin.y 减小 = 视觉向下
            panel.animator().setFrameOrigin(sinkFrame.origin)
        }, completionHandler: {
            panel.orderOut(nil)
            completion?()
        })
    }

    /// 连续截图替换旧 toast：0.1s 快 fade 再上新（避免叠影硬切）
    private static func retireCurrentToast() {
        guard let old = current else { return }
        current = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            old.animator().alphaValue = 0
        }, completionHandler: { old.orderOut(nil) })
    }

    /// 纯文案 toast（无缩略图）：系统级提示用（如菜单栏溢出告知 / 滚动回退告知）。
    /// 同样不抢焦点，2.5 秒自动消失。status 缺省 nil = 不带状态图标。
    static func show(message: String, status: Status? = nil) {
        dismissWork?.cancel()
        retireCurrentToast()

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        // 宽度随文案自适应（上限屏宽 - 40），避免长文案被裁切
        let probe = NSTextField(labelWithString: message)
        probe.font = .systemFont(ofSize: 12, weight: .medium)
        let iconSpace: CGFloat = status == nil ? 0 : 15 + 10
        let textWidth = probe.intrinsicContentSize.width + 32 + iconSpace
        let width = min(max(180, textWidth), visible.width - 40)
        let height: CGFloat = DesignTokens.Toast.textHeight

        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let effect = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: DesignTokens.Radius.lg
        )
        effect.frame = NSRect(x: 0, y: 0, width: width, height: height)

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
        panel.contentView = effect

        let restOrigin = CGPoint(
            x: visible.maxX - width - DesignTokens.Toast.screenMargin,
            y: visible.minY + DesignTokens.Toast.screenMargin
        )
        panel.setFrameOrigin(CGPoint(x: restOrigin.x, y: restOrigin.y - 12))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.springDuration
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: DesignTokens.Motion.springControlPoints.0,
                DesignTokens.Motion.springControlPoints.1,
                DesignTokens.Motion.springControlPoints.2,
                DesignTokens.Motion.springControlPoints.3
            )
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(restOrigin)
        }
        current = panel

        let work = DispatchWorkItem {
            playExit(panel: panel, duration: 0.18) {
                if current === panel { current = nil }
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

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = 268
        let height: CGFloat = 76

        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // 背景：mat.hud 玻璃（radius 14 + 0.5pt stroke）
        let effect = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: DesignTokens.Radius.xl
        )
        effect.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // 缩略图（56pt radius 6 + 0.5pt 白 .22 描边）
        let thumbSide = DesignTokens.Toast.thumbSide
        let thumbView = NSImageView(frame: NSRect(x: 10, y: 10, width: thumbSide, height: thumbSide))
        thumbView.image = NSImage(cgImage: image, size: NSSize(width: thumbSide, height: thumbSide))
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = DesignTokens.Radius.sm
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 0.5
        thumbView.layer?.borderColor = NSColor.white.withAlphaComponent(DesignTokens.Toast.thumbStrokeAlpha).cgColor
        effect.addSubview(thumbView)

        // 文案两行：t.head 主文案 + t.note 尺寸/格式（数字 tabular-nums）
        let textX = thumbSide + 20
        let title = NSTextField(labelWithString: message)
        title.font = DesignTokens.Font.head
        title.textColor = DesignTokens.label1
        title.frame = NSRect(x: textX, y: height - 34, width: width - textX - 14, height: 18)

        let detail = NSTextField(labelWithString: "\(image.width) × \(image.height) · PNG")
        detail.font = DesignTokens.Font.monoDigit(11)
        detail.textColor = DesignTokens.label2
        detail.frame = NSRect(x: textX, y: height - 53, width: width - textX - 14, height: 15)

        effect.addSubview(title)
        effect.addSubview(detail)
        panel.contentView = effect

        // 入场：右下角滑入
        let restOrigin = CGPoint(
            x: visible.maxX - width - 20,
            y: visible.minY + 20
        )
        panel.setFrameOrigin(CGPoint(x: restOrigin.x, y: restOrigin.y - 12))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.5, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(restOrigin)
        }
        current = panel

        // 点击打开编辑（用户功能 2026-11-17「通知弹窗允许点击,打开截图
        // 继续编辑」）：toast 可点（首击激活窗）——点击立即退场+回调
        if let onClick {
            panel.ignoresMouseEvents = false
            let clickView = ToastClickView(frame: panel.contentView?.bounds ?? .zero)
            clickView.onClick = { [weak panel] in
                guard let panel else { return }
                panel.orderOut(nil)
                if current === panel { current = nil }
                onClick()
            }
            panel.contentView?.addSubview(clickView)
            clickView.autoresizingMask = [.width, .height]
        }
        // 2 秒后退场：fade 0.18s + 下滑 6pt
        let work = DispatchWorkItem {
            playExit(panel: panel, duration: 0.18) {
                if current === panel { current = nil }
            }
            // 双保险（用户病例「回车之后还浮在桌面上」：NSAnimationContext
            // completion 偶发不触发 → toast 永驻）：0.6s 后无条件收窗
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if current === panel {
                    panel.orderOut(nil)
                    current = nil
                    Log.event(.app, "toast.exit.forced", [:])
                }
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        Log.event(.app, "toast.show", [
            "pxW": "\(image.width)", "pxH": "\(image.height)",
        ])
    }
}

/// toast 点击层（全幅 hit-test,首击激活）
private final class ToastClickView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// 不抢焦点的浮层（LSUIElement 下也可靠显示）
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
