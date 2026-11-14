import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 覆盖层窗口：无边框、透明、screenSaver 层级、全屏盖住单台显示器（docs/03 §3）
@MainActor
final class OverlayWindow: NSWindow {
    init(screen: NSScreen, controller: OverlayController) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false // 由 OverlayController 统一管理生命周期

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), controller: controller)
        contentView = view
    }
}

/// 覆盖层视图：蒙层 / 橡皮筋选框 / 尺寸角标 / 确认提示 + 手势（docs/03 R2/R3/R4/R5）
@MainActor
final class OverlayView: NSView {
    private unowned let controller: OverlayController

    /// 选区状态
    private enum Phase: Equatable {
        case waitingForDrag          // 等待按下鼠标
        case dragging(start: CGPoint) // 拖拽中
        case confirmed               // 松手，待 Enter/⌘S/Esc/双击
    }
    private var phase: Phase = .waitingForDrag

    /// 选区（视图本地坐标，原点左下）
    private var selectionLocal: CGRect = .zero

    // 视觉常量（贴合系统截图观感）
    private let dimAlpha: CGFloat = 0.25
    private let borderWidth: CGFloat = 1.5
    private let badgeFontSize: CGFloat = 12
    private let minSelectionSize: CGFloat = 4

    init(frame frameRect: NSRect, controller: OverlayController) {
        self.controller = controller
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // MARK: - 光标

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 手势

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .waitingForDrag:
            phase = .dragging(start: point)
            selectionLocal = CGRect(origin: point, size: .zero)
            // 本窗口成为 key window 以接收键盘事件（Enter/Esc/⌘S）
            window?.makeKey()
            needsDisplay = true
        case .confirmed:
            // R5：确认态双击 = 复制退出
            if event.clickCount >= 2 {
                controller.perform(action: .copy)
            }
        case .dragging:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard case .dragging(let start) = phase else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 橡皮筋选框（v0.1：限制在本屏内；跨屏拖拽 v0.2 处理）
        let clamped = CGPoint(
            x: min(max(point.x, 0), bounds.width),
            y: min(max(point.y, 0), bounds.height)
        )
        selectionLocal = CGRect(
            x: min(start.x, clamped.x),
            y: min(start.y, clamped.y),
            width: abs(clamped.x - start.x),
            height: abs(clamped.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard case .dragging = phase else { return }
        // 过小选区视为误触：回到等待态
        if selectionLocal.width < minSelectionSize || selectionLocal.height < minSelectionSize {
            phase = .waitingForDrag
            selectionLocal = .zero
            needsDisplay = true
            return
        }
        phase = .confirmed
        needsDisplay = true
        // 上报全局矩形（AppKit 全局坐标）
        let globalRect = window?.convertToScreen(selectionLocal) ?? selectionLocal
        let screen = window?.screen ?? NSScreen.main!
        controller.didSelect(rect: globalRect, on: screen)
    }

    // MARK: - 键盘（R4：Enter 复制 / ⌘S 保存 / Esc 取消）

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            controller.perform(action: .cancel)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if phase == .confirmed {
                controller.perform(action: .copy)
            }
        case kVK_ANSI_S:
            if event.modifierFlags.contains(.command), phase == .confirmed {
                controller.perform(action: .save)
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 全屏蒙层（选区外）
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        ctx.fill(bounds)

        if selectionLocal.width > 0 || selectionLocal.height > 0 {
            let showBadge = (phase != .waitingForDrag)

            // 2. 选区“挖空”蒙层（clear 混合模式）
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fill(selectionLocal)
            ctx.restoreGState()

            // 3. 选区描边（白底 + 深色内衬，模拟系统截图的双层描边）
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.stroke(selectionLocal)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(0.5)
            let inset = borderWidth / 2 + 0.5
            ctx.stroke(selectionLocal.insetBy(dx: inset, dy: inset))
            ctx.restoreGState()

            // 4. 尺寸角标（选区右下角外侧）
            if showBadge {
                let scale = window?.screen?.backingScaleFactor ?? 1
                let sizeText = "\(Int(selectionLocal.width * scale))×\(Int(selectionLocal.height * scale))"
                drawBadge(text: sizeText, near: selectionLocal, ctx: ctx, scale: scale)

                // 5. 确认态提示条
                if phase == .confirmed {
                    drawHint(ctx: ctx)
                }
            }
        }
    }

    /// 尺寸角标：黑底白字胶囊，跟随选区右下角（不超出屏幕）
    private func drawBadge(text: String, near rect: CGRect, ctx: CGContext, scale: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: badgeFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let badgeSize = CGSize(
            width: ceil(textSize.width + padding * 2),
            height: ceil(textSize.height + padding)
        )
        // 锚点：选区右下角（视图本地坐标 Y 向上 → minY 侧）
        var origin = CGPoint(
            x: rect.maxX - badgeSize.width,
            y: rect.minY - badgeSize.height - 6
        )
        // 边界保护
        if origin.y < 0 { origin.y = rect.maxY + 6 }
        if origin.x < 0 { origin.x = 0 }
        if origin.x + badgeSize.width > bounds.width {
            origin.x = bounds.width - badgeSize.width
        }
        let badgeRect = CGRect(origin: origin, size: badgeSize)
        let path = CGPath(
            roundedRect: badgeRect,
            cornerWidth: badgeSize.height / 2,
            cornerHeight: badgeSize.height / 2,
            transform: nil
        )
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        (text as NSString).draw(
            at: CGPoint(x: origin.x + padding, y: origin.y + padding / 2),
            withAttributes: attributes
        )
    }

    /// 确认态提示：选区上方居中的操作提示胶囊
    private func drawHint(ctx: CGContext) {
        let text = "Enter 复制 · ⌘S 保存 · Esc 取消 · 双击复制"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 8
        let size = CGSize(width: ceil(textSize.width + padding * 2), height: ceil(textSize.height + 4))
        var origin = CGPoint(
            x: selectionLocal.midX - size.width / 2,
            y: selectionLocal.maxY + 8
        )
        if origin.y + size.height > bounds.height {
            origin.y = selectionLocal.minY - size.height - 8
        }
        if origin.x < 8 { origin.x = 8 }
        if origin.x + size.width > bounds.width - 8 { origin.x = bounds.width - 8 - size.width }
        let rect = CGRect(origin: origin, size: size)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: origin.x + padding, y: origin.y + 2), withAttributes: attributes)
    }
}
