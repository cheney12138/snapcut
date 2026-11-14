import AppKit
import CoreGraphics

/// CGRenderer —— 标注绘制的唯一实现（docs/03 §6）
///
/// 编辑器画布与导出共用本渲染器：编辑器把"底图 + 标注层"逐帧调用 render；
/// 导出时同一函数按最终尺寸重绘。"编辑器所见 = 导出所得"由此保证。
/// 所有几何输入为选区本地 point 坐标（原点左上、Y 向下）。
enum CGRenderer {
    /// 把标注层画到 CGContext（调用方负责底图与上下文状态）
    ///
    /// - Parameter contextIsYDown: 上下文是否已是 Y 向下（AppKit isFlipped 视图的
    /// cgContext 即 Y-down；导出 composite 的上下文是 Y-up + 已翻转标注层坐标系）。
    /// 文字绘制需要局部翻转，两种上下文的翻转次数不同（病例：编辑器画布上
    /// 文字倒置——Y-down 上下文里又翻了一次）
    static func render(annotations: [AnnotationModel], in size: CGSize, context: CGContext, contextIsYDown: Bool = false) {
        for annotation in annotations {
            draw(annotation, in: size, context: context, yDown: contextIsYDown)
        }
    }

    /// 导出：底图 + 标注 → 合成 CGImage（选区像素坐标系）
    ///
    /// 马赛克先对底图真实像素化（applyMosaic），再画矢量标注——
    /// ⚠️ 病例：旧实现 composite 只画底图 + 矢量层，马赛克仅剩矢量层里
    /// alpha 0.05 的黑罩，导出成品等于没打码（用户实报「点了没反应」）。
    static func composite(base: CGImage, annotations: [AnnotationModel], scale: CGFloat) -> CGImage {
        let width = base.width
        let height = base.height
        // 0. 马赛克像素化：选区本地 point rect × scale → 底图像素 rect，逐个打码
        // （与编辑器预览 renderMosaicPreview 同一算法，「编辑器所见 = 导出所得」）
        let baseWithMosaic = applyMosaic(base: base, annotations: annotations, scale: scale)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }
        // 1. 底图（已含马赛克像素化）正常方向（Y-up 上下文直接 draw 即正立）
        ctx.draw(baseWithMosaic, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
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

    private static func draw(_ a: AnnotationModel, in size: CGSize, context: CGContext, yDown: Bool) {
        let color = NSColor(cgColor: a.color.cgColor) ?? .red
        let width = max(1.5, a.strokeWidth)  // 连续粗细：2-6pt 直接作为线宽（下限 1.5 兜底）
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
            // 文字渲染用标注自带的 fontSize（导出所见 = 编辑器所见）
            drawText(a.text ?? "", at: anchor, color: color, size: a.fontSize, context: context, yDown: yDown)

        case .mosaic:
            // 真实像素化在 composite / 编辑器预览阶段对底图做（applyMosaic），
            // 矢量层不再叠加任何罩色。
            // ⚠️ 病例：旧实现这里画 alpha 0.05 黑罩——预览/导出几乎不可见，
            // 用户实报「马赛克点了没反应」。区域几何存在标注里供打码用。
            break

        case .sequence(let anchor):
            drawText("\(a.index ?? 1)", at: anchor, color: color, size: 16, badge: true, context: context, yDown: yDown)

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
    ///
    /// 徽章对比度（病例：白色/黄色徽章 + 白色数字 ⇒ 白底白字看不见）：
    /// 按底色亮度选数字颜色（亮底黑字/暗底白字），并加一圈同色系描边，
    /// 保证徽章在任意底色的截图上都能被看见。
    private static func drawText(_ text: String, at anchor: CGPoint, color: NSColor, size: CGFloat, badge: Bool = false, context: CGContext, yDown: Bool) {
        guard !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: size, weight: badge ? .semibold : .medium)
        // 徽章底色亮度 → 数字颜色（0.299/0.587/0.114 加权亮度，阈值 0.6）
        let components = color.usingColorSpace(.sRGB)
        let luminance = badge
            ? 0.299 * (components?.redComponent ?? 0)
                + 0.587 * (components?.greenComponent ?? 0)
                + 0.114 * (components?.blueComponent ?? 0)
            : 0
        let onLightFill = luminance > 0.6
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: badge ? (onLightFill ? NSColor.black : NSColor.white) : color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        var origin = anchor
        if badge {
            let radius = max(lineBounds.height / 2 + 5, 12)
            let circle = CGRect(
                x: anchor.x - radius, y: anchor.y - radius,
                width: radius * 2, height: radius * 2
            )
            // 实心圆底
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: circle)
            // 描边圈：亮底加深色圈（白底截图上白徽章不可见的同源问题）
            context.setStrokeColor((onLightFill ? NSColor.black : NSColor.white)
                .withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: circle)
            // 数字居中：水平用光学宽度，垂直按行高带（基线落在中心 + 半行高处）
            origin = CGPoint(
                x: anchor.x - lineBounds.width / 2,
                y: anchor.y - lineBounds.height / 2
            )
        }
        // 文字局部翻转：只有 Y-up（导出路径，render 入口已统一翻转到 Y-down）
        // 需要再翻一次；编辑器画布（isFlipped）本来就是 Y-down，再翻就倒置
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + lineBounds.height)
        if !yDown {
            context.scaleBy(x: 1, y: -1)
        }
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - 马赛克像素化

    /// 块大小映射：strokeWidth 1→8px 2→16px 3→24px（预览/导出共用）
    /// （参照 Snow Shot：mosaic_block_size = 2 + 20 × strength²，块像素语义一致）
    /// strokeWidth 已连续化（CGFloat 2-6）：块大小随粗细线性放大（8px 起，+4px/pt）
    static func mosaicBlockSize(for strokeWidth: CGFloat) -> Int {
        Int(max(8, strokeWidth * 4))
    }

    /// 对底图应用全部马赛克标注的像素化（导出 composite 与编辑器预览共用）
    ///
    /// - Parameters:
    ///   - base: 底图（像素分辨率，scale 已含）
    ///   - annotations: 标注列表（geometry 为选区本地 point 坐标，Y 向下）
    ///   - scale: 底图像素 / 选区 point 的比例
    /// - Returns: 打码后的底图（无有效马赛克时原样返回）
    static func applyMosaic(base: CGImage, annotations: [AnnotationModel], scale: CGFloat) -> CGImage {
        var jobs: [(rect: CGRect, blockSize: Int)] = []
        for a in annotations {
            if case .mosaic(let r) = a.shape {
                let n = normalized(r)
                guard n.width > 1, n.height > 1 else { continue }  // 拖拽起步的零尺寸 rect 跳过
                let pxRect = CGRect(
                    x: n.minX * scale, y: n.minY * scale,
                    width: n.width * scale, height: n.height * scale
                ).integral
                jobs.append((pxRect, mosaicBlockSize(for: a.strokeWidth)))
            }
        }
        return pixelateRegions(of: base, regions: jobs)
    }

    /// 编辑器实时预览：底图 + mosaic 像素化（含拖拽中的 pending 标注）
    ///
    /// 与导出 composite 的像素化完全同一条路径（applyMosaic），
    /// 保证「编辑器所见 = 导出所得」。
    static func renderMosaicPreview(base: CGImage, annotations: [AnnotationModel], scale: CGFloat) -> CGImage {
        applyMosaic(base: base, annotations: annotations, scale: scale)
    }

    /// 马赛克像素化：对底图多个区域做块平均（缩小再放大，GPU 加速的经典路径）
    /// - Parameter regions: 图像像素坐标（原点左上）+ 每区域块大小（px）
    static func pixelateRegions(of image: CGImage, regions: [(rect: CGRect, blockSize: Int)]) -> CGImage {
        let width = image.width
        let height = image.height
        // 裁剪到图像范围内并取整；块大小非法的跳过
        var clamped: [(rect: CGRect, blockSize: Int)] = []
        for job in regions {
            let x = max(0, job.rect.minX), y = max(0, job.rect.minY)
            let pxRect = CGRect(
                x: x, y: y,
                width: min(CGFloat(width) - x, job.rect.width),
                height: min(CGFloat(height) - y, job.rect.height)
            ).integral
            guard pxRect.width > 1, pxRect.height > 1, job.blockSize > 0 else { continue }
            clamped.append((rect: pxRect, blockSize: job.blockSize))
        }
        guard !clamped.isEmpty,
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        // 画底图（一次；多区域共用同一全图上下文，避免逐区域全图重绘）
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        for (pxRect, blockSize) in clamped {
            // 块平均：缩小再放大
            let blocksX = max(1, Int(pxRect.width) / blockSize)
            let blocksY = max(1, Int(pxRect.height) / blockSize)
            guard let cropped = image.cropping(to: pxRect),
                  let smallCtx = CGContext(
                    data: nil, width: blocksX, height: blocksY,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { continue }
            smallCtx.interpolationQuality = .low
            smallCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(blocksX), height: CGFloat(blocksY)))
            guard let small = smallCtx.makeImage() else { continue }
            ctx.interpolationQuality = .none
            // pxRect 是图像像素坐标（原点左上）；Y-up 上下文里的贴图 y 要翻
            ctx.draw(small, in: CGRect(
                x: pxRect.minX,
                y: CGFloat(height) - pxRect.maxY,
                width: pxRect.width,
                height: pxRect.height
            ))
        }
        return ctx.makeImage() ?? image
    }

    /// 单区域像素化（EditorSession.renderFinalImage 的既有入口，语义不变）
    static func pixelate(image: CGImage, rect: CGRect, blockSize: Int) -> CGImage {
        pixelateRegions(of: image, regions: [(rect, blockSize)])
    }

    private static func normalized(_ r: CGRect) -> CGRect {
        CGRect(
            x: min(r.minX, r.maxX), y: min(r.minY, r.maxY),
            width: abs(r.width), height: abs(r.height)
        )
    }
}
