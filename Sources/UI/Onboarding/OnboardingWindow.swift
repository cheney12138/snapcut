import AppKit

/// 首次运行引导卡（重设计 scene 02 `.onb` 的 1:1 移植）
///
/// 视觉真源：`html-pages/snapcut-design-redesign/index.html` scene 02；
/// 施工图：tokens.md §2/§7/§9「引导卡（档 2）」。token 全部取自 DesignTokens。
/// - 材质：mat.card（hudWindow，**跟随窗口 appearance 不钉暗**——本卡有完整文字
///   层级，亮色玻璃可读；token 表给了暗/亮双值）
/// - 卡：400pt 宽、radius 16、padding 24、0.5pt stroke、行高 40 + 0.5pt hairline
/// - 权限行：状态点 7pt + 语义色文字；未授权 → 右侧 btn-mini.accent「去授权」
/// - 快捷键行右值：kbd 胶囊组（gap 5；热键从 settings 读，自定义后提示跟随）
/// - 主按钮：34 高 radius 8 accent 实心（hover accentHover）+ foot 提示 note/label.3
///
/// 产品意图：**权限前置**——在用户第一次想截图之前就把屏幕录制权限讲清楚并引导授权。
/// 展示时机（由 AppCoordinator 决定）：从未完成引导，或屏幕录制权限尚未授予。
@MainActor
final class OnboardingWindow: NSPanel {
    private let onPermissionTap: () -> Void
    private let onFinish: () -> Void
    private var permissionDot: NSView?
    private var permissionLabel: NSTextField?
    private var permissionButton: NSButton?

    init(permissionGranted: Bool,
         onPermissionTap: @escaping () -> Void,
         onFinish: @escaping () -> Void) {
        self.onPermissionTap = onPermissionTap
        self.onFinish = onFinish
        let size = NSSize(width: DesignTokens.Onboarding.width, height: Self.cardHeight)
        // 窗口比卡四边各大 1pt：卡内缩进窗口，卡边缘的圆角边缘不落在窗口
        // 边缘上（窗口边缘的材质缓冲边缘伪影被 1pt 透明带吸收；引导卡黑边病例：
        // 禁用 maskImage，圆角一律 layer.cornerRadius + masksToBounds）
        let windowSize = NSSize(width: size.width + 2, height: size.height + 2)
        super.init(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        // mat.card：跟随系统外观（不钉 darkAqua；迁移差异 §10-6）
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // borderless 窗口默认不可拖：显式允许「背景拖拽」（控件 hitTest 优先）
        isMovableByWindowBackground = true
        buildUI(size: size, permissionGranted: permissionGranted)
    }

    /// 卡高：pad 24 + 头 48 + 18 + 行 4×40 + 18 + 主按钮 34 + 12 + foot 15 + 24
    private static let cardHeight: CGFloat = 24 + 48 + 18 + 160 + 18 + 34 + 12 + 15 + 24

    private func buildUI(size: NSSize, permissionGranted: Bool) {
        let container = NSView(frame: NSRect(origin: .zero,
                                             size: NSSize(width: size.width + 2, height: size.height + 2)))
        // 玻璃卡（档 2：hudWindow 跟随外观；radius 16 + masksToBounds，无 maskImage）
        let card = NSVisualEffectView(frame: NSRect(x: 1, y: 1, width: size.width, height: size.height))
        card.material = DesignTokens.Mat.card
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = DesignTokens.Radius.xxl
        card.layer?.masksToBounds = true
        // 内描边（0.5pt stroke，圆角路径内缩 0.25pt 整条落在卡内）
        let stroke = CAShapeLayer()
        let inset: CGFloat = 0.25
        stroke.frame = CGRect(origin: .zero, size: size)
        stroke.path = CGPath(
            roundedRect: stroke.frame.insetBy(dx: inset, dy: inset),
            cornerWidth: DesignTokens.Radius.xxl - inset,
            cornerHeight: DesignTokens.Radius.xxl - inset,
            transform: nil
        )
        stroke.fillColor = nil
        stroke.strokeColor = DesignTokens.stroke.cgColor
        stroke.lineWidth = 0.5
        card.layer?.addSublayer(stroke)
        // inset.hi：顶缘 1pt 高光（贴描边下沿）
        let hi = NSView(frame: NSRect(x: 1, y: size.height - 1.5, width: size.width - 2, height: 1))
        hi.wantsLayer = true
        hi.layer?.backgroundColor = NSColor.white.withAlphaComponent(DesignTokens.Inset.hiAlpha.0).cgColor
        card.addSubview(hi)

        let pad = DesignTokens.Onboarding.padding
        var y = size.height - pad

        // 头：48pt 圆角 11 App 图标 + t.title 标题 + t.note 副标题
        let iconSide = DesignTokens.Onboarding.headIconSize
        let icon = NSImageView(frame: NSRect(x: pad, y: y - iconSide, width: iconSide, height: iconSide))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 11
        icon.layer?.masksToBounds = true
        card.addSubview(icon)

        let titleX = pad + iconSide + 14
        let title = NSTextField(labelWithString: "Snapcut 已就绪")
        title.font = DesignTokens.Font.title
        title.textColor = DesignTokens.label1
        title.frame = NSRect(x: titleX, y: y - 22, width: size.width - titleX - pad, height: 22)
        card.addSubview(title)

        let subtitle = NSTextField(labelWithString: "授权一次，之后按快捷键就能用")
        subtitle.font = DesignTokens.Font.note
        subtitle.textColor = DesignTokens.label2
        subtitle.frame = NSRect(x: titleX, y: y - 38, width: size.width - titleX - pad, height: 16)
        card.addSubview(subtitle)

        y -= iconSide + 18

        // 行：权限（状态点 + 语义色 + 去授权）+ 三个快捷键（kbd 胶囊组）
        let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
        let rows: [(String, RowValue)] = [
            ("屏幕录制权限", .permission(granted: permissionGranted)),
            ("区域截图", .hotkeys(settings.hotkeyRegion)),
            ("全屏截图", .hotkeys(settings.hotkeyFullScreen)),
            ("取色（框选时）", .hotkeys("c")),
        ]
        let rowHeight = DesignTokens.Onboarding.rowHeight
        for (_, row) in rows.enumerated() {
            // 行高 40 + 0.5pt hairline（首行也有 border-top，末行无）
            let hairline = NSView(frame: NSRect(x: pad, y: y, width: size.width - pad * 2, height: 0.5))
            hairline.wantsLayer = true
            hairline.layer?.backgroundColor = DesignTokens.hair.cgColor
            card.addSubview(hairline)

            let rowTop = y - 0.5
            let label = NSTextField(labelWithString: row.0)
            label.font = DesignTokens.Font.head
            label.textColor = DesignTokens.label1
            label.frame = NSRect(x: pad, y: rowTop - rowHeight + (rowHeight - 18) / 2,
                                 width: 200, height: 18)
            card.addSubview(label)

            switch row.1 {
            case .permission(let granted):
                let dot = NSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 3.5
                dot.layer?.backgroundColor = (granted ? DesignTokens.statusOK : DesignTokens.statusWarn).cgColor
                let permText = NSTextField(labelWithString: granted ? "已授权" : "未授权")
                permText.font = .systemFont(ofSize: 11.5, weight: .semibold)
                permText.textColor = granted ? DesignTokens.statusOK : DesignTokens.statusWarn
                let textSize = permText.intrinsicContentSize
                let totalW = 7 + 6 + ceil(textSize.width)
                let startX = size.width - pad - totalW - (granted ? 0 : 10 + 62)
                dot.frame.origin = NSPoint(x: startX, y: rowTop - rowHeight / 2 - 3.5)
                permText.frame = NSRect(x: startX + 13, y: rowTop - rowHeight + (rowHeight - 15) / 2,
                                        width: ceil(textSize.width) + 2, height: 15)
                card.addSubview(dot)
                card.addSubview(permText)
                permissionDot = dot
                permissionLabel = permText
                if !granted {
                    // btn-mini.accent「去授权」：22 高 radius 6 accent 实心（hover accentHover）
                    let button = HoverButton(title: "去授权", target: self, action: #selector(permissionTapped))
                    button.isBordered = false
                    button.wantsLayer = true
                    button.layer?.cornerRadius = DesignTokens.Radius.sm
                    button.layer?.backgroundColor = DesignTokens.accent.cgColor
                    button.attributedTitle = NSAttributedString(string: "去授权", attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                        .foregroundColor: DesignTokens.labelOnAccent,
                    ])
                    let bw: CGFloat = 62
                    button.frame = NSRect(x: size.width - pad - bw, y: rowTop - rowHeight + (rowHeight - 22) / 2,
                                          width: bw, height: 22)
                    button.onHover = { hot in
                        button.layer?.backgroundColor = (hot ? DesignTokens.accentHover : DesignTokens.accent).cgColor
                    }
                    card.addSubview(button)
                    permissionButton = button
                }
            case .hotkeys(let combo):
                // kbd 胶囊组（gap 5）：从显示串拆分（"⌘ ⇧ A" → 3 枚）
                let chips = Self.kbdChips(for: combo)
                let chipStack = NSStackView(views: chips)
                chipStack.orientation = .horizontal
                chipStack.alignment = .centerY
                chipStack.spacing = 5
                let fit = chipStack.fittingSize
                chipStack.frame = NSRect(x: size.width - pad - fit.width,
                                         y: rowTop - rowHeight + (rowHeight - fit.height) / 2,
                                         width: fit.width, height: fit.height)
                card.addSubview(chipStack)
            }
            y -= rowHeight
        }

        // 主按钮（34 高 radius 8 accent 实心 + hover accentHover）
        let primary = HoverButton(title: "开始使用", target: self, action: #selector(finishTapped))
        primary.isBordered = false
        primary.wantsLayer = true
        primary.layer?.cornerRadius = DesignTokens.Radius.primaryButton
        primary.layer?.backgroundColor = DesignTokens.accent.cgColor
        primary.attributedTitle = NSAttributedString(string: "开始使用", attributes: [
            .font: DesignTokens.Font.head,
            .foregroundColor: DesignTokens.labelOnAccent,
        ])
        primary.frame = NSRect(x: pad, y: pad + 27, width: size.width - pad * 2, height: 34)
        primary.onHover = { hot in
            primary.layer?.backgroundColor = (hot ? DesignTokens.accentHover : DesignTokens.accent).cgColor
        }
        card.addSubview(primary)

        // foot 提示（t.note / label.3）
        let foot = NSTextField(labelWithString: "权限仅用于截屏，数据全部留在本机")
        foot.font = DesignTokens.Font.note
        foot.textColor = DesignTokens.label3
        foot.alignment = .center
        foot.frame = NSRect(x: pad, y: pad, width: size.width - pad * 2, height: 15)
        card.addSubview(foot)

        container.addSubview(card)
        contentView = container
    }

    private enum RowValue {
        case permission(granted: Bool)
        case hotkeys(String)
    }

    /// 热键显示串 → kbd 胶囊视图组（"cmd+shift+a" → ⌘/⇧/A 三枚）
    private static func kbdChips(for combo: String) -> [NSView] {
        let display = HotkeySpec.display(combo)
        let parts = display.split(separator: " ").map(String.init)
        return (parts.isEmpty ? [display] : parts).map { KbdCapsuleView(text: $0) }
    }

    /// 居中显示（若权限已授权且已完成引导，调用方不应显示）
    /// 入场 motion.enter.center：0.28s spring + rise 10pt + scale .96→1 + fade
    /// （居中卡离参照物远，浮起幅度比贴边浮层大；原仅 alpha 显影）
    func showCentered(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = frame.size
        let finalFrame = CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + 40,
            width: size.width, height: size.height
        )
        setFrameOrigin(CGPoint(x: finalFrame.minX, y: finalFrame.minY - DesignTokens.Motion.enterRise))
        alphaValue = 0
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeScale(DesignTokens.Motion.enterCenterScale,
                                                     DesignTokens.Motion.enterCenterScale, 1)
            CATransaction.commit()
        }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterCenterDuration
            ctx.timingFunction = DesignTokens.Motion.springTimingFunction
            self.animator().setFrame(finalFrame, display: true)
            self.animator().alphaValue = 1
        }
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.enterCenterDuration)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.springTimingFunction)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    /// motion.exit 退场：fade + scale→.98 + 下沉 6pt，0.16s ease-in；
    /// orderOut 延迟到动画尾（完成 / 权限跳转共用；completionHandler 强持有 self，
    /// 调用方同步置 nil 也不会中断动画）
    func dismissAnimated() {
        guard isVisible else {
            orderOut(nil)
            return
        }
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.exitDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
            layer.transform = CATransform3DMakeScale(0.98, 0.98, 1)
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.exitDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            var sinkFrame = frame
            sinkFrame.origin.y -= 6
            self.animator().setFrame(sinkFrame, display: true)
        }, completionHandler: {
            self.orderOut(nil)
            if let layer = self.contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        })
    }

    func updatePermission(granted: Bool) {
        // 权限状态过渡：0.3s 颜色过渡 + 状态点 1.2x 弹一下（状态变化有重量转移感）
        if let dot = permissionDot, let layer = dot.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            layer.backgroundColor = (granted ? DesignTokens.statusOK : DesignTokens.statusWarn).cgColor
            let bounce = CABasicAnimation(keyPath: "transform.scale")
            bounce.fromValue = 1.0
            bounce.toValue = 1.2
            bounce.duration = 0.15
            bounce.autoreverses = true
            bounce.repeatCount = 2
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(bounce, forKey: "permBounce")
            CATransaction.commit()
        }
        permissionLabel?.stringValue = granted ? "已授权" : "未授权"
        permissionLabel?.textColor = granted ? DesignTokens.statusOK : DesignTokens.statusWarn
        permissionButton?.isHidden = granted
    }

    @objc private func permissionTapped() {
        // 点完引导卡要让位：TCC 确认框/系统设置立刻弹出，引导卡挡在最前面挡住授权流程。
        // 隐藏而非关闭：权限轮询 granted 后由 controller 恢复或走完成。
        dismissAnimated()
        onPermissionTap()
    }

    @objc private func finishTapped() {
        onFinish()
    }
}

// MARK: - kbd 键位胶囊（§7：22 高 / min 22 宽、radius 5、fill.kbd、内上白 .10；内下阴影已删）

@MainActor
final class KbdCapsuleView: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        let textSize = label.intrinsicContentSize
        let width = max(DesignTokens.Control.kbdMinWidth, ceil(textSize.width) + 12)
        let height = DesignTokens.Control.kbdHeight
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.kbd
        layer?.backgroundColor = DesignTokens.fillKbd.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(name: "kbd.stroke") { ap in
            ap.isDark ? NSColor.white.withAlphaComponent(0.16)
                      : NSColor.black.withAlphaComponent(0.16)
        }.cgColor
        // 内上白 .10 一条 1pt 线模拟（审查：22pt 胶囊双内阴影过雕，内下黑 .28 删除）
        let top = NSView(frame: NSRect(x: 3, y: height - 2, width: width - 6, height: 1))
        top.wantsLayer = true
        top.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        addSubview(top)

        label.font = DesignTokens.Font.kbd
        label.textColor = DesignTokens.label2
        label.frame = bounds.insetBy(dx: 6, dy: (height - ceil(textSize.height)) / 2)
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("KbdCapsuleView 只走代码创建") }
}

// MARK: - hover 回调按钮（引导卡 accent 实心键换 hover 底色用）

@MainActor
final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
