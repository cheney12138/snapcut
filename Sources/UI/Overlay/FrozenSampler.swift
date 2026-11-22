import AppKit
import CoreGraphics

/// 冻结帧的像素级采样器（放大镜 / 取色用）
///
/// 为什么单独抽出：放大镜要在每个鼠标事件里读 121 个像素，
/// 必须 O(1)，不能走 `NSBitmapImageRep.colorAt`（每次都要过 CG 桥）。
/// 安装冻结帧时一次性把像素解到连续缓冲，之后纯数组索引。
struct FrozenSampler {
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let pixels: [UInt8]

    init?(image: CGImage) {
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 4
        let w = width
        let h = height
        var buffer = [UInt8](repeating: 0, count: rowBytes * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        bytesPerRow = rowBytes
        pixels = buffer
    }

    /// 取像素（RGBA 0-255，alpha 已按 premultiplied 解算成直通值）
    func rgba(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let idx = y * bytesPerRow + x * 4
        guard idx + 3 < pixels.count else { return nil }
        let a = Int(pixels[idx + 3])
        guard a > 0 else { return (0, 0, 0, 0) }
        // premultiplied → 直通
        let r = min(255, Int(pixels[idx]) * 255 / a)
        let g = min(255, Int(pixels[idx + 1]) * 255 / a)
        let b = min(255, Int(pixels[idx + 2]) * 255 / a)
        return (r, g, b, a)
    }

    func hex(x: Int, y: Int) -> String {
        guard let c = rgba(x: x, y: y) else { return "#------" }
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }
}

/// 放大镜绘制（选区阶段的精确对位 / 取色）
///
/// 规格参照 Snow Shot 取色器：11×11 源像素 @12× = 132pt 面板，
/// 中心像素描边标记，两行读数（坐标 + 色值），光标右下 16pt 跟随、
/// 贴边自动翻到另一侧。
enum MagnifierPainter {
    static let sampleCount = 11
    static let zoom: CGFloat = 12
    private static let panelSize = CGFloat(sampleCount) * zoom          // 132
    private static let gap: CGFloat = 16

    /// - Parameters:
    ///   - sampler: 冻结帧采样器
    ///   - cursorLocal: 光标在本视图的本地坐标（Y 向下）
    ///   - bounds: 视图范围（用于避让边缘）
    ///   - imageSize: 冻结帧像素尺寸（用于本地点 → 像素换算）
    ///   - screenPoints: 屏幕逻辑尺寸（用于坐标读数）
    ///   - globalOrigin: 本窗在全局坐标的原点（用于换算屏幕坐标读数）
    static func draw(
        sampler: FrozenSampler,
        cursorLocal: CGPoint,
        bounds: CGRect,
        imageSize: CGSize,
        screenPoints: CGSize,
        globalOrigin: CGPoint,
        ctx: CGContext
    ) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        // 本地点 → 图像像素
        let px = Int(cursorLocal.x / bounds.width * imageSize.width)
        let py = Int(cursorLocal.y / bounds.height * imageSize.height)
        guard px >= 0, px < sampler.width, py >= 0, py < sampler.height else { return }

        let footerHeight: CGFloat = 42
        let cardHeight = panelSize + footerHeight
        let cornerR: CGFloat = 10

        // 面板位置：光标右下 18pt，右侧/下方放不下则翻到另一侧
        var origin = CGPoint(x: cursorLocal.x + gap + 2, y: cursorLocal.y + gap + 2)
        if origin.x + panelSize + 10 > bounds.maxX { origin.x = cursorLocal.x - gap - 2 - panelSize }
        if origin.y + cardHeight + 10 > bounds.maxY { origin.y = cursorLocal.y - gap - 2 - cardHeight }
        origin.x = max(8, min(origin.x, bounds.maxX - panelSize - 8))
        origin.y = max(8, min(origin.y, bounds.maxY - cardHeight - 8))

        // 背景卡片（Apple Digital Color Meter 风格：柔和圆角投影 + 深半透底 + 0.5pt 发丝边）
        let cardRect = CGRect(x: origin.x, y: origin.y, width: panelSize, height: cardHeight)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 22/255.0, green: 22/255.0, blue: 26/255.0, alpha: 0.90).cgColor)
        ctx.addPath(cardPath)
        ctx.fillPath()
        ctx.restoreGState()

        // 放大区裁进卡片圆角内
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        ctx.clip(to: CGRect(x: origin.x, y: origin.y, width: panelSize, height: panelSize))

        // 逐源像素绘制 12×12 方块（最近邻，不插值）
        let half = sampleCount / 2
        for dy in 0..<sampleCount {
            for dx in 0..<sampleCount {
                let sx = px - half + dx
                let sy = py - half + dy
                let color = sampler.rgba(x: sx, y: sy) ?? (0, 0, 0, 0)
                ctx.setFillColor(
                    NSColor(
                        srgbRed: CGFloat(color.r) / 255,
                        green: CGFloat(color.g) / 255,
                        blue: CGFloat(color.b) / 255,
                        alpha: color.a == 0 ? 0.35 : 1
                    ).cgColor
                )
                ctx.fill(CGRect(
                    x: origin.x + CGFloat(dx) * zoom,
                    y: origin.y + CGFloat(dy) * zoom,
                    width: zoom, height: zoom
                ))
            }
        }

        // 精细像素网格线（克制白 α.07）
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1..<sampleCount {
            let x = origin.x + CGFloat(i) * zoom
            let y = origin.y + CGFloat(i) * zoom
            ctx.move(to: CGPoint(x: x, y: origin.y))
            ctx.addLine(to: CGPoint(x: x, y: origin.y + panelSize))
            ctx.move(to: CGPoint(x: origin.x, y: y))
            ctx.addLine(to: CGPoint(x: origin.x + panelSize, y: y))
        }
        ctx.strokePath()

        // 柔和十字准线（白 α.45，避免喧宾夺主）
        let centerRect = CGRect(
            x: origin.x + CGFloat(half) * zoom,
            y: origin.y + CGFloat(half) * zoom,
            width: zoom, height: zoom
        )
        let cx = centerRect.midX
        let cy = centerRect.midY
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.75)
        ctx.move(to: CGPoint(x: origin.x, y: cy))
        ctx.addLine(to: CGPoint(x: centerRect.minX - 1, y: cy))
        ctx.move(to: CGPoint(x: centerRect.maxX + 1, y: cy))
        ctx.addLine(to: CGPoint(x: origin.x + panelSize, y: cy))
        ctx.move(to: CGPoint(x: cx, y: origin.y))
        ctx.addLine(to: CGPoint(x: cx, y: centerRect.minY - 1))
        ctx.move(to: CGPoint(x: cx, y: centerRect.maxY + 1))
        ctx.addLine(to: CGPoint(x: cx, y: origin.y + panelSize))
        ctx.strokePath()

        // 中心像素取色框（内白外暗双边，深浅底色皆清晰）
        let reticle = centerRect.insetBy(dx: -0.75, dy: -0.75)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(2.2)
        ctx.stroke(reticle)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.2)
        ctx.stroke(reticle)
        ctx.restoreGState()

        // 放大区与读数区分隔发丝线 + 外框 0.5pt 发丝边
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: origin.x, y: origin.y + panelSize))
        ctx.addLine(to: CGPoint(x: origin.x + panelSize, y: origin.y + panelSize))
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(cardPath)
        ctx.strokePath()

        // 读数区：首行 = 实时色点 + HEX + 「C」取色提示；次行 = 精确坐标（等宽数字）
        let centerRGBA = sampler.rgba(x: px, y: py) ?? (0, 0, 0, 255)
        let colorText = sampler.hex(x: px, y: py)
        let swatchRect = CGRect(x: origin.x + 8, y: origin.y + panelSize + 8, width: 9, height: 9)
        ctx.setFillColor(NSColor(
            srgbRed: CGFloat(centerRGBA.r) / 255,
            green: CGFloat(centerRGBA.g) / 255,
            blue: CGFloat(centerRGBA.b) / 255,
            alpha: 1
        ).cgColor)
        ctx.fillEllipse(in: swatchRect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: swatchRect)

        let colorAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.46),
        ]
        (colorText as NSString).draw(
            at: CGPoint(x: origin.x + 22, y: origin.y + panelSize + 5.5),
            withAttributes: colorAttrs
        )
        ("C 取色" as NSString).draw(
            at: CGPoint(x: origin.x + panelSize - 34, y: origin.y + panelSize + 6.5),
            withAttributes: hintAttrs
        )

        let screenX = Int(cursorLocal.x.rounded())
        let screenY = Int(cursorLocal.y.rounded())
        let coordText = "X \(screenX)  Y \(screenY)"
        let coordAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.58),
        ]
        (coordText as NSString).draw(
            at: CGPoint(x: origin.x + 8, y: origin.y + panelSize + 23),
            withAttributes: coordAttrs
        )
    }
}
