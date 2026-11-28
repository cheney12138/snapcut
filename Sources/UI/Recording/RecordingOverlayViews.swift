import AppKit
import CoreGraphics
import QuartzCore

/// 录屏进行中区域外框视图（纯 CALayer，零每帧 drawRect 开销）：
/// - 边框画在采集矩形外扩 2pt 处，既清晰标识录制边界，又不遮挡内部操作内容；
/// - 配合 `SCStream` 进程级排除，本视图永远不会进入录制画面；
/// - 录制态呈现克制的呼吸红框，暂停态切换为静态琥珀色提示。
@MainActor
final class RecordingRegionBorderView: NSView {
    /// 与宿主 OverlayView 同向（Y 向下），确保录屏红框严格落在选区位置而不上下翻转
    override var isFlipped: Bool { true }

    private let borderLayer = CAShapeLayer()
    private var regionRectLocal: CGRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 2.0
        borderLayer.strokeColor = DesignTokens.statusError.withAlphaComponent(0.9).cgColor
        borderLayer.shadowColor = DesignTokens.statusError.cgColor
        borderLayer.shadowOpacity = 0.28
        borderLayer.shadowRadius = 6
        borderLayer.shadowOffset = .zero
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(rect: CGRect) {
        regionRectLocal = rect
        let outer = rect.insetBy(dx: -1.5, dy: -1.5)
        let path = CGPath(roundedRect: outer, cornerWidth: 4, cornerHeight: 4, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.path = path
        CATransaction.commit()
    }

    func setRecordingActive(_ paused: Bool) {
        borderLayer.removeAnimation(forKey: "rec.pulse")
        let color = paused ? DesignTokens.statusWarn : DesignTokens.statusError
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.strokeColor = color.withAlphaComponent(0.92).cgColor
        borderLayer.shadowColor = color.cgColor
        borderLayer.opacity = 1.0
        CATransaction.commit()

        guard !paused, !DesignTokens.Motion.reduceMotion else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.52
        anim.toValue = 1.0
        anim.duration = 0.9
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        borderLayer.add(anim, forKey: "rec.pulse")
    }
}
