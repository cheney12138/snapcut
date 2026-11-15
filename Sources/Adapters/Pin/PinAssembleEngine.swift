import AppKit
import CoreGraphics

/// 组 → 合成 CGImage（设计定稿 §1.4）：成员图按组本地坐标烤入。
///
/// 渲染约定（与 PinContentView 成组视觉逐条一致，所见 = 所得）：
/// - 成员窗体 frame（外框，已含 8pt 白垫 + 1px 描边）→ 白垫圆角 10 填充
/// - 图像画在框内缩 9pt 的矩形里，圆角 6 裁切，1:1 像素（interpolation none）
/// - 成员之间 gutter 16pt 的间隙 + 外圈 padding = 背景色
///   （背景色三选沿用旧 CollageExporter.ExportOptions.Background 枚举语义，默认白）
///
/// 马赛克边界说明：合成图是单底图，后续标注编辑走 EditorSession →
/// CGRenderer.composite 的单底图路径，无旧「多底图无 mosaic」问题。
@MainActor
enum PinAssembleEngine {
    enum Background: String, Sendable, CaseIterable {
        /// 透明（PNG alpha，间隙与 padding 全透）
        case transparent
        case white
        /// 深色 #1E1E22
        case dark
    }

    /// 成员：图像 + 当前窗体 frame（AppKit 全局 points，Y-up）
    static func compose(
        members: [(image: CGImage, frame: CGRect)],
        background: Background = .white
    ) -> (image: CGImage, pxScale: CGFloat)? {
        guard !members.isEmpty else { return nil }
        let union = MagnetGroup.unionRect(members.map(\.frame))
        guard union.width >= 1, union.height >= 1 else { return nil }

        // 像素比例：用 union 所在屏的 backingScaleFactor（pin 图像本就 1:1 落在该屏）
        let screen = NSScreen.screens.first { $0.frame.intersects(union) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let width = max(1, Int((union.width * scale).rounded()))
        let height = max(1, Int((union.height * scale).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 背景色铺满：间隙（gutter）与外圈没有贴片，透出的就是它
        switch background {
        case .transparent:
            break
        case .white:
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .dark:
            ctx.setFillColor(CGColor(srgbRed: 30 / 255, green: 30 / 255, blue: 34 / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        // 坐标系（reviewer 实证修正 2026-11-15）：CGBitmapContext 的用户空间
        // 是 Y-up，AppKit 全局 frame 也是 Y-up——直接 scale + 平移即正立；
        // 原实现外层翻 Y + 成员内层再翻一次 = 净翻一次（合成图垂直镜像）。
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -union.minX, y: -union.minY)

        for member in members {
            let frame = member.frame
            guard frame.width > 0, frame.height > 0 else { continue }

            // 白垫（外框圆角 10）+ 发丝描边
            let padPath = CGPath(
                roundedRect: frame, cornerWidth: PinContentView.groupCornerRadius,
                cornerHeight: PinContentView.groupCornerRadius, transform: nil
            )
            ctx.addPath(padPath)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()

            // 图像：框内缩 9pt（pad 8 + border 1），圆角 6 裁切
            let imageRect = frame.insetBy(
                dx: PinWindowController.groupPadTotal, dy: PinWindowController.groupPadTotal
            )
            ctx.saveGState()
            ctx.addPath(CGPath(
                roundedRect: imageRect, cornerWidth: PinContentView.cornerRadius,
                cornerHeight: PinContentView.cornerRadius, transform: nil
            ))
            ctx.clip()
            // Y-up 上下文直接 draw 即正立（勿加局部镜像——见顶部坐标系注释）
            ctx.interpolationQuality = .none
            ctx.draw(member.image, in: imageRect)
            ctx.restoreGState()

            // 描边：黑 15% 1pt 骑外缘（不裁切，线完整）
            ctx.saveGState()
            ctx.addPath(CGPath(
                roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: PinContentView.groupCornerRadius,
                cornerHeight: PinContentView.groupCornerRadius, transform: nil
            ))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.15))
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { return nil }
        return (image, scale)
    }
}
