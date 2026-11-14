import AppKit
import CoreGraphics

/// 复制成功反馈（原型右下角 `.toast`：缩略图 + 「已复制到剪贴板」+ 尺寸格式）
///
/// 设计纪律：
/// - 不抢焦点（`.nonactivatingPanel`，`ignoresMouseEvents = true`）——截完图用户要马上继续干活
/// - 不写入截图（它在截图会话结束之后才出现，且不属于覆盖层）
/// - 2 秒自动消失，淡出 + 轻微下滑（与工具栏同族的 spring 手感）
@MainActor
enum CaptureToast {
    private static var current: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    static func show(image: CGImage, message: String = "已复制到剪贴板") {
        // 连续截图：先关旧的，避免堆叠
        dismissWork?.cancel()
        current?.orderOut(nil)
        current = nil

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

        // 背景：hud 磨砂 + 14pt 圆角 + 细描边
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        // 缩略图（保持比例，圆角 6，带描边）
        let thumbSide: CGFloat = 56
        let thumbView = NSImageView(frame: NSRect(x: 10, y: 10, width: thumbSide, height: thumbSide))
        thumbView.image = NSImage(cgImage: image, size: NSSize(width: thumbSide, height: thumbSide))
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 6
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 0.5
        thumbView.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        effect.addSubview(thumbView)

        // 文案两行：主文案 + 尺寸/格式
        let textX = thumbSide + 20
        let title = NSTextField(labelWithString: message)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: textX, y: height - 34, width: width - textX - 14, height: 18)

        let detail = NSTextField(labelWithString: "\(image.width) × \(image.height) · PNG")
        detail.font = .systemFont(ofSize: 11, weight: .regular)
        detail.textColor = NSColor.white.withAlphaComponent(0.62)
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

        // 2 秒后淡出
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
                if current === panel { current = nil }
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        Log.event(.app, "toast.show", [
            "pxW": "\(image.width)", "pxH": "\(image.height)",
        ])
    }
}

/// 不抢焦点的浮层（LSUIElement 下也可靠显示）
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
