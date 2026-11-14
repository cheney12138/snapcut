import AppKit
import Carbon.HIToolbox

/// 延时截图倒计时 HUD（Snow Shot `screenshot_delay` 同款语义）
///
/// 行为约束：
/// - 触发后立刻显示，每秒递减；到 0 自动进入区域截图（冻结屏幕）
/// - **Esc 取消**（取消后不做任何截图）
/// - 跟随鼠标所在显示器居中偏上，不抢焦点（nonactivating），不影响用户布局窗口
@MainActor
final class CountdownHUD {
    private static var current: CountdownHUD?
    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var remaining: Int = 0
    private var onFinish: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var escHotkeyID: UInt32?

    /// 启动倒计时。seconds <= 0 时立即回调 onFinish。
    static func start(
        seconds: Int,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        current?.stop()
        let hud = CountdownHUD()
        current = hud
        hud.run(seconds: seconds, onFinish: onFinish, onCancel: onCancel)
    }

    private func run(seconds: Int, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        remaining = max(0, seconds)
        buildPanel()
        updateLabel()
        guard remaining > 0 else {
            finish()
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Esc 取消：**用 Carbon 热键**而不是 NSEvent 全局监听器——
        // addGlobalMonitorForEvents 需要「输入监控」权限，未授权时静默失效（病例）；
        // Carbon RegisterEventHotKey 不需要额外权限，与滚动截图收尾同款做法
        escHotkeyID = CarbonHotKeyCenter.shared.register(
            keyCode: kVK_Escape, modifiers: []
        ) { [weak self] in
            self?.cancel()
        }
        Log.event(.app, "countdown.start", ["seconds": "\(remaining)"])
    }

    private func tick() {
        remaining -= 1
        updateLabel()
        if remaining <= 0 { finish() }
    }

    private func buildPanel() {
        let size = NSSize(width: 168, height: 132)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let card = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        card.layer?.backgroundColor = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.169, alpha: 0.62).cgColor

        let number = NSTextField(labelWithString: "3")
        number.font = .systemFont(ofSize: 64, weight: .semibold)
        number.alignment = .center
        number.textColor = .white
        number.frame = NSRect(x: 0, y: 34, width: size.width, height: 76)
        card.addSubview(number)

        let hint = NSTextField(labelWithString: "按 Esc 取消")
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        hint.textColor = NSColor.white.withAlphaComponent(0.55)
        hint.frame = NSRect(x: 0, y: 16, width: size.width, height: 16)
        card.addSubview(hint)

        panel.contentView = card
        self.panel = panel
        self.label = number

        // 位置：鼠标所在屏，居中偏上
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY + 80
            ))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.panel?.animator().alphaValue = 1
        }
    }

    private func updateLabel() {
        label?.stringValue = "\(max(0, remaining))"
        Log.event(.app, "countdown.tick", ["left": "\(max(0, remaining))"])
    }

    private func finish() {
        let action = onFinish
        stop()
        action?()
    }

    private func cancel() {
        let action = onCancel
        stop()
        Log.event(.app, "countdown.cancel")
        action?()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        CarbonHotKeyCenter.shared.unregister(escHotkeyID)
        escHotkeyID = nil
        panel?.orderOut(nil)
        panel = nil
        label = nil
        onFinish = nil
        onCancel = nil
        if CountdownHUD.current === self { CountdownHUD.current = nil }
    }
}
