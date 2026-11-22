import AppKit
import CoreGraphics
import QuartzCore

/// 松手吸附动效参数 + 视觉预览叠层 + 松手滑入动画器（零拖中阻力 / 零死区）。
enum SnapFeel {
    /// 松手后滑入贴合位的缓动时长（160ms strong ease-out，顺滑利落）
    static let glideDuration: TimeInterval = 0.16
    /// 视觉预览叠层淡入/淡出时长
    static let previewFadeIn: TimeInterval = 0.10
    static let previewFadeOut: TimeInterval = 0.09
}

/// 拖动期纯视觉吸附预览叠层（绝不篡改卡片位置、绝不拦截鼠标事件）：
/// - 鬼影落位框（浅强调蓝半透填充 + 1.5pt 圆角线）
/// - 12pt 缝隙居中轻引导线
/// - 软对齐参考线（仅当触发上/下/左/右/中线软对齐时显示，类似 Keynote / 桌面智能参考线）
@MainActor
final class SnapPreviewOverlay {
    static let shared = SnapPreviewOverlay()

    private let panel: NSPanel
    private let previewView: SnapPreviewView
    private var visible = false
    private var hideToken = 0

    private init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        let v = SnapPreviewView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        p.contentView = v
        self.panel = p
        self.previewView = v
    }

    func show(outcome: MagnetSnapOutcome) {
        hideToken += 1
        var boundsRect = outcome.frame
        boundsRect = include(line: outcome.seamGuide, in: boundsRect)
        if let align = outcome.alignGuide {
            boundsRect = include(line: align, in: boundsRect)
        }
        let panelFrame = boundsRect.insetBy(dx: -24, dy: -24).integral
        panel.setFrame(panelFrame, display: false)
        previewView.frame = NSRect(origin: .zero, size: panelFrame.size)
        previewView.panelOrigin = panelFrame.origin
        previewView.outcome = outcome
        previewView.needsDisplay = true

        if !visible {
            visible = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = SnapFeel.previewFadeIn
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
            if panel.alphaValue < 0.99 {
                panel.alphaValue = 1
            }
        }
    }

    func hide(immediate: Bool = false) {
        guard visible || panel.isVisible else { return }
        visible = false
        hideToken += 1
        let token = hideToken
        if immediate || DesignTokens.Motion.reduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = SnapFeel.previewFadeOut
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token, !self.visible else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func include(line: MagnetGuideLine, in rect: CGRect) -> CGRect {
        let minX = min(line.start.x, line.end.x)
        let maxX = max(line.start.x, line.end.x)
        let minY = min(line.start.y, line.end.y)
        let maxY = max(line.start.y, line.end.y)
        return rect.union(CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)))
    }
}

@MainActor
private final class SnapPreviewView: NSView {
    var panelOrigin: CGPoint = .zero
    var outcome: MagnetSnapOutcome?

    override func draw(_ dirtyRect: NSRect) {
        guard let outcome, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 全局 Y-up 转本视图本地 Y-up（默认 NSView 即 Y-up，直接减去 panelOrigin）
        func localRect(_ r: CGRect) -> CGRect {
            r.offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y)
        }
        func localPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - panelOrigin.x, y: p.y - panelOrigin.y)
        }

        // 1. 鬼影落位框（浅蓝半透底 + 1.5pt 圆角高亮框）
        let ghost = localRect(outcome.frame)
        let r = PinContentView.cornerRadius
        let ghostPath = CGPath(roundedRect: ghost.insetBy(dx: 0.75, dy: 0.75), cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        ctx.addPath(ghostPath)
        ctx.setFillColor(DesignTokens.accent.withAlphaComponent(0.09).cgColor)
        ctx.fillPath()
        ctx.addPath(ghostPath)
        ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(0.62).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()

        // 2. 贴合缝隙轻引导线（12pt 缝隙居中）
        let seamStart = localPoint(outcome.seamGuide.start)
        let seamEnd = localPoint(outcome.seamGuide.end)
        if hypot(seamEnd.x - seamStart.x, seamEnd.y - seamStart.y) >= 8 {
            ctx.saveGState()
            ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(0.36).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineCap(.round)
            ctx.move(to: seamStart)
            ctx.addLine(to: seamEnd)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 3. 软对齐参考线（仅当触发上/下/左/右/中线软对齐时显示，清晰克制）
        if let align = outcome.alignGuide {
            let a = localPoint(align.start)
            let b = localPoint(align.end)
            ctx.saveGState()
            ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(0.86).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineCap(.round)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()

            // 两端 3pt 小刻度锚点（Apple Keynote 智能参考线质感）
            let isHorizontal = abs(a.y - b.y) < 0.5
            let tick: CGFloat = 2.5
            ctx.setLineWidth(1.0)
            for pt in [a, b] {
                if isHorizontal {
                    ctx.move(to: CGPoint(x: pt.x, y: pt.y - tick))
                    ctx.addLine(to: CGPoint(x: pt.x, y: pt.y + tick))
                } else {
                    ctx.move(to: CGPoint(x: pt.x - tick, y: pt.y))
                    ctx.addLine(to: CGPoint(x: pt.x + tick, y: pt.y))
                }
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

/// 松手落位滑入动画器：在 ~160ms 内将一组贴图从当前位置按 strong ease-out 顺滑过渡到目标位置，
/// 同步驱动回调刷新磨砂托盘位置，确保整组与单卡视觉零跳变。
@MainActor
final class SnapGlideAnimator {
    static let shared = SnapGlideAnimator()

    private var timer: Timer?
    private var token = 0

    private init() {}

    func cancel() {
        token += 1
        timer?.invalidate()
        timer = nil
    }

    func glide(
        items: [(pin: PinWindowController, from: CGPoint, to: CGPoint)],
        duration: TimeInterval = SnapFeel.glideDuration,
        onStep: @escaping @MainActor () -> Void,
        onComplete: @escaping @MainActor () -> Void
    ) {
        cancel()
        let maxShift = items.reduce(CGFloat(0)) { acc, item in
            max(acc, hypot(item.to.x - item.from.x, item.to.y - item.from.y))
        }
        if maxShift < 0.5 || DesignTokens.Motion.reduceMotion {
            for item in items { item.pin.setFrameOrigin(item.to) }
            onStep()
            onComplete()
            return
        }

        let myToken = token
        let start = CACurrentMediaTime()
        let stepTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.token == myToken else { return }
                let raw = (CACurrentMediaTime() - start) / duration
                if raw >= 1.0 {
                    self.timer?.invalidate()
                    self.timer = nil
                    for item in items { item.pin.setFrameOrigin(item.to) }
                    onStep()
                    onComplete()
                    return
                }
                // Strong ease-out quartic（近似 cubic-bezier(0.23, 1, 0.32, 1)）
                let eased = 1.0 - pow(1.0 - raw, 4.0)
                for item in items {
                    let x = item.from.x + (item.to.x - item.from.x) * eased
                    let y = item.from.y + (item.to.y - item.from.y) * eased
                    item.pin.setFrameOrigin(CGPoint(x: x, y: y))
                }
                onStep()
            }
        }
        RunLoop.main.add(stepTimer, forMode: .common)
        timer = stepTimer
    }
}
