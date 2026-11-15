import AppKit

/// 首次运行引导卡（原型 scene 07 `.onb-card` 的 1:1 移植）
///
/// 产品意图：**权限前置**——在用户第一次想截图之前就把屏幕录制权限讲清楚并引导授权，
/// 而不是等他按了 ⌘⇧A 失败后弹窗（用户反馈："应该在安装/首启就授权，而不是开始使用后"）。
///
/// 展示时机（由 AppCoordinator 决定）：
/// - 从未完成引导（UserDefaults `onboarding.completed` = false），或
/// - 屏幕录制权限尚未授予
@MainActor
final class OnboardingWindow: NSPanel {
    private let onPermissionTap: () -> Void
    private let onFinish: () -> Void
    private var permissionRowValue: NSTextField?

    init(permissionGranted: Bool,
         onPermissionTap: @escaping () -> Void,
         onFinish: @escaping () -> Void) {
        self.onPermissionTap = onPermissionTap
        self.onFinish = onFinish
        let size = NSSize(width: 400, height: 292)
        // 窗口比卡四边各大 1pt：卡内缩进窗口，卡边缘的遮罩/圆角边缘不落在窗口
        // 边缘上（窗口边缘的材质缓冲边缘伪影被 1pt 透明带吸收，见 buildUI 病例）
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
        // 病例（用户实报「透明有问题」）：浅色系统主题下 .hudWindow 解析成亮灰
        // 材质——和 ToolbarPanel/Settings 同源的坑，窗口+材质都钉暗色外观
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 病例（用户实报「这个窗怎么拖不动」）：borderless 窗口默认不可拖，
        // 必须显式允许「背景拖拽」。卡片是 NSVisualEffectView 背景，会命中。
        // 控件（按钮/文字）不受影响——hitTest 优先给控件，拖不动的地方只是空白背景。
        isMovableByWindowBackground = true
        buildUI(size: size, permissionGranted: permissionGranted)
    }

    private func buildUI(size: NSSize, permissionGranted: Bool) {
        // 卡片容器（窗口比卡四边各大 1pt，卡内缩进窗口）
        let container = NSView(frame: NSRect(origin: .zero,
                                             size: NSSize(width: size.width + 2, height: size.height + 2)))
        // 玻璃卡（原型：radius 16 / padding 22 / .5pt 白 12% / 深影）
        let card = NSVisualEffectView(frame: NSRect(x: 1, y: 1, width: size.width, height: size.height))
        card.material = .hudWindow
        card.appearance = NSAppearance(named: .darkAqua)
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        // 病例二轮（用户实拍：白背景下卡边缘仍是一圈黑线，第一轮内描边修法无效）：
        // 黑线随 3da1eee 引入 maskImage 才出现——同项目 CaptureToast/CountdownHUD/
        // ToolbarPanel 用同族材质（hudWindow + cornerRadius + masksToBounds +
        // hasShadow）浮在任意内容上从未被报黑边，唯一差异就是 maskImage：
        // maskImage 的半透明遮罩边缘坡道进了窗口阴影源 + 材质合成，
        // 在浅背景上生成紧贴卡边的一圈暗色硬轮廓。离线 harness
        // （onb_edge_harness.swift）证实：maskImage 与否，cacheDisplay 像素层面
        // 边缘都不比内部暗（环 min=93=内部 min，暗像素 0）——黑线只在
        // 窗口服务器合成路径（材质遮罩边缘/阴影源）出现，第一轮改 layer 层
        // 的描边当然拦不住。
        // 修复：弃用 maskImage（连同它要修的「白角」——同 commit 自证屏幕级
        // 「白像素」实为玻璃透出的底下内容，系误诊），改用本项目已实机的
        // toast/toolbar 配方：layer.cornerRadius + masksToBounds；窗口四边各
        // 留 1pt 透明带，卡边缘不落在窗口边缘上，材质缓冲的窗口边缘伪影被
        // 透明带吸收。圆角形状 = cornerRadius 隆齐（与 CaptureToast 同款，
        // 无 mask 坡道进阴影源）。
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        // 内描边（原型暗色 --glass-stroke 精确值：rgba(255,255,255,.12)，宽 .5px，
        // 见 index.html scene 07 .onb-card）——圆角路径内缩 0.25pt，整条描边完整
        // 落在卡内。第一轮曾把黑线归咎于旧 layer 描边（改内描边），实机复测
        // 证明描边不是黑线根因（真凶是 maskImage，见上方病例）；内描边本身
        // 抗锯齿干净，保留作玻璃质感描边。
        let stroke = CAShapeLayer()
        let inset: CGFloat = 0.25
        let strokeFrame = CGRect(origin: .zero, size: size)
        stroke.frame = strokeFrame
        stroke.path = CGPath(
            roundedRect: strokeFrame.insetBy(dx: inset, dy: inset),
            cornerWidth: 16 - inset,
            cornerHeight: 16 - inset,
            transform: nil
        )
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        stroke.lineWidth = 0.5
        card.layer?.addSublayer(stroke)
        card.layer?.backgroundColor = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.169, alpha: 0.72).cgColor

        let pad: CGFloat = 22
        var y = size.height - pad
        // 图标 + 标题
        let iconSide: CGFloat = 46
        let icon = NSImageView(frame: NSRect(x: pad, y: y - iconSide, width: iconSide, height: iconSide))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 12
        icon.layer?.masksToBounds = true
        card.addSubview(icon)

        let titleX = pad + iconSide + 12
        let title = NSTextField(labelWithString: "Snapcut 已就绪")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: titleX, y: y - 20, width: size.width - titleX - pad, height: 20)
        card.addSubview(title)

        let subtitle = NSTextField(labelWithString: "授权一次，之后按快捷键就能用")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitle.frame = NSRect(x: titleX, y: y - 38, width: size.width - titleX - pad, height: 16)
        card.addSubview(subtitle)

        y -= iconSide + 18

        // 行：权限（带按钮）+ 三个快捷键
        let rows: [(String, String, Bool)] = [
            ("屏幕录制权限", permissionGranted ? "已授权 ✓" : "未授权", true),
            ("区域截图", "⌘ ⇧ A", false),
            ("全屏截图", "⌘ ⇧ S", false),
            ("取色（框选时）", "C", false),
        ]
        for (titleText, valueText, isPermission) in rows {
            let rowHeight: CGFloat = 34
            let hairline = NSView(frame: NSRect(x: pad, y: y, width: size.width - pad * 2, height: 0.5))
            hairline.wantsLayer = true
            hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            card.addSubview(hairline)

            let label = NSTextField(labelWithString: titleText)
            label.font = .systemFont(ofSize: 12)
            label.textColor = NSColor.white.withAlphaComponent(0.72)
            label.frame = NSRect(x: pad + 2, y: y - rowHeight + 2, width: 200, height: 18)
            card.addSubview(label)

            let value = NSTextField(labelWithString: valueText)
            value.alignment = .right
            value.font = .systemFont(ofSize: 12, weight: .semibold)
            value.textColor = isPermission
                ? (permissionGranted ? NSColor.systemGreen : NSColor.systemOrange)
                : NSColor.white.withAlphaComponent(0.92)
            let valueWidth: CGFloat = isPermission ? 90 : 120
            // 病例（用户实报「已授权没有靠右」）：78pt 按钮预留位在已授权时也生效了，
            // 文字卡在中间。只有未授权（真的有「去授权」按钮）才需要让位。
            let buttonInset: CGFloat = (isPermission && !permissionGranted) ? 78 : 0
            value.frame = NSRect(x: size.width - pad - valueWidth - buttonInset,
                                 y: y - rowHeight + 2, width: valueWidth, height: 18)
            card.addSubview(value)
            if isPermission { permissionRowValue = value }

            if isPermission && !permissionGranted {
                let button = NSButton(title: "去授权", target: self, action: #selector(permissionTapped))
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11, weight: .medium)
                button.frame = NSRect(x: size.width - pad - 66, y: y - rowHeight + 3, width: 66, height: 22)
                card.addSubview(button)
            }
            y -= rowHeight
        }

        // 主按钮
        let primary = NSButton(title: "开始使用", target: self, action: #selector(finishTapped))
        primary.isBordered = false
        primary.wantsLayer = true
        primary.layer?.cornerRadius = 9
        primary.layer?.backgroundColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1).cgColor
        primary.font = .systemFont(ofSize: 12.5, weight: .semibold)
        primary.contentTintColor = .white
        primary.frame = NSRect(x: pad, y: pad, width: size.width - pad * 2, height: 34)
        card.addSubview(primary)

        // ⚠️ 病例（permfix2 重构回归）：card 构建完忘了 addSubview 进 container——
        // contentView 是空容器，窗口「在屏但全黑/AX 树为空」（用户实报引导卡弹不出）
        container.addSubview(card)
        contentView = container
    }

    /// 居中显示（若权限已授权且已完成引导，调用方不应显示）
    func showCentered(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + 40
        ))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.5, 1)
            self.animator().alphaValue = 1
        }
    }

    func updatePermission(granted: Bool) {
        permissionRowValue?.stringValue = granted ? "已授权 ✓" : "未授权"
        permissionRowValue?.textColor = granted ? .systemGreen : .systemOrange
    }

    @objc private func permissionTapped() {
        // 病例（用户实报「点了去授权窗口不消失很烦人」）：点完引导卡要让位——
        // TCC 确认框/系统设置会立刻弹出，引导卡挡在最前面挡住授权流程。
        // 隐藏而非关闭：权限轮询 granted 后由 controller 恢复或走完成。
        orderOut(nil)
        onPermissionTap()
    }

    @objc private func finishTapped() {
        onFinish()
    }
}
