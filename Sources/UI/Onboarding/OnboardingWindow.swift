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
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildUI(size: size, permissionGranted: permissionGranted)
    }

    private func buildUI(size: NSSize, permissionGranted: Bool) {
        // 玻璃卡（原型：radius 16 / padding 22 / .5pt 白 16% / 深影）
        let card = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
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
            value.frame = NSRect(x: size.width - pad - valueWidth - (isPermission ? 78 : 0),
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

        contentView = card
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
        onPermissionTap()
    }

    @objc private func finishTapped() {
        onFinish()
    }
}
