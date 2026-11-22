import AppKit
import CoreGraphics

/// 组 → 合成 CGImage：按屏幕所见磨砂托盘布局（14pt 外圈留白 + 成员真实间距 + 圆角卡片微投影与发丝边）烤入单张高清图。
@MainActor
enum PinAssembleEngine {
    enum Background: String, Sendable, CaseIterable {
        /// 透明（PNG alpha，间隙与外圈全透）
        case transparent
        /// 柔和浅灰白画布（Apple 质感，避免刺眼死白与卡片白底融为一体）
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

        // 与屏幕磨砂托盘外圈留白一致（14pt），导出即所见
        let padding: CGFloat = GroupBackdropPanel.matPadding
        let canvasRect = union.insetBy(dx: -padding, dy: -padding)

        let screen = NSScreen.screens.first { $0.frame.intersects(union) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let width = max(1, Int((canvasRect.width * scale).rounded()))
        let height = max(1, Int((canvasRect.height * scale).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        switch background {
        case .transparent:
            break
        case .white:
            // Apple 极浅暖灰底 (#F5F5F7)，让白底截图卡片依然有清晰轮廓与精致呼吸感
            ctx.setFillColor(CGColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .dark:
            ctx.setFillColor(CGColor(srgbRed: 30 / 255, green: 30 / 255, blue: 34 / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        // CGBitmapContext 用户空间 Y-up，AppKit 全局 frame 也是 Y-up
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -canvasRect.minX, y: -canvasRect.minY)

        let r = PinContentView.cornerRadius
        for member in members {
            let frame = member.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            let cardPath = CGPath(roundedRect: frame, cornerWidth: r, cornerHeight: r, transform: nil)

            // 1. 卡片轻投影（与磨砂托盘上的卡片浮起层次一致）
            if background != .transparent {
                ctx.saveGState()
                ctx.setShadow(
                    offset: CGSize(width: 0, height: -2),
                    blur: 8,
                    color: CGColor(gray: 0, alpha: background == .dark ? 0.36 : 0.12)
                )
                ctx.addPath(cardPath)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillPath()
                ctx.restoreGState()
            }

            // 2. 圆角裁切绘制原图
            ctx.saveGState()
            ctx.addPath(cardPath)
            ctx.clip()
            let exact1to1 = abs(frame.width * scale - CGFloat(member.image.width)) < 1.5
                && abs(frame.height * scale - CGFloat(member.image.height)) < 1.5
            ctx.interpolationQuality = exact1to1 ? .none : .high
            ctx.draw(member.image, in: frame)
            ctx.restoreGState()

            // 3. 0.5pt 精致发丝描边
            ctx.saveGState()
            ctx.addPath(CGPath(
                roundedRect: frame.insetBy(dx: 0.25, dy: 0.25),
                cornerWidth: r, cornerHeight: r, transform: nil
            ))
            ctx.setStrokeColor(CGColor(gray: background == .dark ? 1 : 0, alpha: background == .dark ? 0.14 : 0.12))
            ctx.setLineWidth(0.5)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { return nil }
        return (image, scale)
    }
}
