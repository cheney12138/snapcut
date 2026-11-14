import AppKit
import CoreGraphics

/// CGRenderer —— 标注绘制的唯一实现（docs/03 §6）
///
/// 编辑器画布与导出共用本渲染器：编辑器把"底图 + 标注层"逐帧调用 render；
/// 导出时同一函数按最终尺寸重绘。"编辑器所见 = 导出所得"由此保证。
/// 所有几何输入为选区本地 point 坐标（原点左上、Y 向下）。
enum CGRenderer {
    /// 把标注层画到已锁定的 CGContext（调用方负责底图与上下文状态）
    static func render(annotations: [AnnotationModel], in size: CGSize, context: CGContext) {
        for annotation in annotations {
            draw(annotation, in: size, context: context)
        }
    }

    /// 导出：底图 + 标注 → 合成 CGImage（选区像素坐标系）
    static func composite(base: CGImage, annotations: [AnnotationModel], scale: CGFloat) -> CGImage {
        let width = base.width
        let height = base.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }
        // 1. 底图正常方向（Y-up 上下文直接 draw 即正立）
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        // 2. 标注层：几何是选区本地 Y-down point 坐标 → 翻转 + 像素缩放后绘制
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        let pointSize = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        render(annotations: annotations, in: pointSize, context: ctx)
        ctx.restoreGState()
        guard let output = ctx.makeImage() else { return base }
        return output
    }

    // MARK: - 单个标注绘制

    private static func draw(_ a: AnnotationModel, in size: CGSize, context: CGContext) {
        let color = a.color
        let width = CGFloat(a.strokeWidth + 1)  // 1→2pt 2→3pt 3→4pt（功能先行，手感后调）
        context.saveGState()

        switch a.shape {
        case .arrow(let from, let to):
            drawArrow(from: from, to: to, color: color, lineWidth: width, context: context)

        case .rect(let r):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineJoin(.round)
            context.stroke(normalized(r))

        case .text(let anchor):
            drawText(a.text ?? "", at: anchor, color: color, size: 14, context: context)

        case .mosaic(let r):
            // 马赛克不用笔色；实际像素化在 composite 阶段对底图做（这里只画提示框）
            context.setFillColor(NSColor.black.withAlphaComponent(0.05).cgColor)
            context.fill(normalized(r))

        case .sequence(let anchor):
            drawText("\(a.index ?? 1)", at: anchor, color: color, size: 16, badge: true, context: context)

        case .highlight(let from, let to):
            context.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(width * 5) // 高亮笔粗
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// 箭头：线段 + 三角箭头头（头尺寸随线宽）
    private static func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, lineWidth: CGFloat, context: CGContext) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let headLength = max(lineWidth * 3.5, 10)

        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        // 主线（缩短一个头长，避免被三角盖住）
        let lineEnd = CGPoint(x: to.x - cos(angle) * headLength, y: to.y - sin(angle) * headLength)
        context.move(to: from)
        context.addLine(to: lineEnd)
        context.strokePath()

        // 三角头
        let headAngle: CGFloat = 0.45
        let p1 = CGPoint(x: to.x, y: to.y)
        let p2 = CGPoint(
            x: to.x - cos(angle - headAngle) * headLength,
            y: to.y - sin(angle - headAngle) * headLength
        )
        let p3 = CGPoint(
            x: to.x - cos(angle + headAngle) * headLength,
            y: to.y - sin(angle + headAngle) * headLength
        )
        context.move(to: p1)
        context.addLine(to: p2)
        context.addLine(to: p3)
        context.closePath()
        context.fillPath()
    }

    /// 文字（text/sequence 共用；sequence 画成实心圆徽章）
    private static func drawText(_ text: String, at anchor: CGPoint, color: NSColor, size: CGFloat, badge: Bool = false, context: CGContext) {
        guard !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: size, weight: badge ? .semibold : .medium)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: badge ? NSColor.white : color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        var origin = anchor
        if badge {
            let radius = max(lineBounds.height / 2 + 5, 12)
            // 实心圆底
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(
                x: anchor.x - radius, y: anchor.y - radius,
                width: radius * 2, height: radius * 2
            ))
            origin = CGPoint(x: anchor.x - lineBounds.width / 2, y: anchor.y - lineBounds.height / 2)
        }
        // Y 翻转：CG 上下文当前是 Y 向下坐标系（render 入口统一翻转过）
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + lineBounds.height)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// 马赛克像素化（对 CGImage 区域做块平均，结果与标注一起 composite 时调用）
    static func pixelate(image: CGImage, rect: CGRect, blockSize: Int) -> CGImage {
        let width = image.width
        let height = image.height
        let pxRect = CGRect(
            x: max(0, rect.minX), y: max(0, rect.minY),
            width: min(CGFloat(width) - max(0, rect.minX), rect.width),
            height: min(CGFloat(height) - max(0, rect.minY), rect.height)
        ).integral
        guard pxRect.width > 1, pxRect.height > 1,
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        // 画底图
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        // 块平均：缩小再放大（GPU 加速的经典像素化路径）
        let blocksX = max(1, Int(pxRect.width) / blockSize)
        let blocksY = max(1, Int(pxRect.height) / blockSize)
        guard let cropped = image.cropping(to: pxRect) else { return image }
        guard let smallCtx = CGContext(
            data: nil, width: blocksX, height: blocksY,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        smallCtx.interpolationQuality = .low
        smallCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(blocksX), height: CGFloat(blocksY)))
        guard let small = smallCtx.makeImage() else { return image }
        ctx.interpolationQuality = .none
        // pxRect 是图像像素坐标（原点左上）；Y-up 上下文里的贴图 y 要翻
        ctx.draw(small, in: CGRect(
            x: pxRect.minX,
            y: CGFloat(height) - pxRect.maxY,
            width: pxRect.width,
            height: pxRect.height
        ))
        return ctx.makeImage() ?? image
    }

    private static func normalized(_ r: CGRect) -> CGRect {
        CGRect(
            x: min(r.minX, r.maxX), y: min(r.minY, r.maxY),
            width: abs(r.width), height: abs(r.height)
        )
    }
}
