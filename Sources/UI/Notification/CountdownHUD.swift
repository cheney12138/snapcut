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
        let cardSize = NSSize(width: 168, height: 132)
        let margin: CGFloat = 20
        let cornerRadius: CGFloat = 18
        let totalSize = NSSize(width: cardSize.width + margin * 2, height: cardSize.height + margin * 2)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: totalSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 禁用 borderless NSVisualEffectView 的系统 hasShadow（白色直角伪影根因），统一走 OuterShadowView
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let outer = NSView(frame: NSRect(origin: .zero, size: totalSize))
        outer.wantsLayer = true

        let shadowHost = OuterShadowView(spec: .pill, margin: margin, cornerRadius: cornerRadius)
        shadowHost.frame = outer.bounds
        shadowHost.autoresizingMask = [.width, .height]
        outer.addSubview(shadowHost)

        let cardRect = NSRect(x: margin, y: margin, width: cardSize.width, height: cardSize.height)
        let glassSurface = DesignTokens.Mat.liquidGlass(
            cornerRadius: cornerRadius,
            style: .clear,
            tintColor: DesignTokens.Mat.floatingGlassTint,
            fallbackMaterial: DesignTokens.Mat.hud
        )
        glassSurface.hostView.frame = cardRect
        outer.addSubview(glassSurface.hostView)

        let container = NSView(frame: cardRect)
        container.wantsLayer = true
        container.appearance = NSAppearance(named: .aqua)
        outer.addSubview(container)
        let number = NSTextField(labelWithString: "3")
        number.font = .monospacedDigitSystemFont(ofSize: 64, weight: .semibold)
        number.alignment = .center
        number.textColor = DesignTokens.label1
        number.frame = NSRect(x: 0, y: 36, width: cardSize.width, height: 76)
        container.addSubview(number)

        let hint = NSTextField(labelWithString: "按 Esc 取消")
        hint.font = .systemFont(ofSize: 11.5, weight: .medium)
        hint.alignment = .center
        hint.textColor = DesignTokens.label2
        hint.frame = NSRect(x: 0, y: 16, width: cardSize.width, height: 16)
        container.addSubview(hint)

        panel.contentView = outer
        outer.layoutSubtreeIfNeeded()
        shadowHost.refreshGeometry()
        self.panel = panel
        self.label = number

        // 位置：光标所在显示器正居中
        let origin = DisplayRegistry.centerOrigin(for: cardSize)
        panel.setFrameOrigin(CGPoint(x: origin.x - margin, y: origin.y - margin))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
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
