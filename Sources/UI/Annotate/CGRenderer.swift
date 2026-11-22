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
        guard let ctx = makeRGBA8Context(width: width, height: height, matching: baseWithMosaic) else { return base }
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
            drawSequenceBadge(
                number: a.index ?? 1,
                at: anchor,
                color: color,
                strokeWidth: width,
                context: context
            )

        case .highlight(let from, let to):
            context.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(width * 5) // 高亮笔粗
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

        case .ellipse(let center, let radiusX, let radiusY):
            // 圆心圈选：center 起拖至边缘（用户裁定 2026-11-16 新增）
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            let r = CGRect(
                x: center.x - abs(radiusX), y: center.y - abs(radiusY),
                width: abs(radiusX) * 2, height: abs(radiusY) * 2)
            context.strokeEllipse(in: normalized(r))
        }
        // ⚠️ 翻转上下文（Y-down 宿主）里椭圆中心坐标与其他 shape 一致——
        // 都在标注本地坐标系，无需单独处理
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

    /// Apple / CleanShot X 风格序号标注徽章：
    /// - 尺寸随工具栏 3 档粗细点自适应（细 24pt / 中 28pt / 粗 32pt 直径；两位数自动微缩字号保持优雅留白）；
    /// - 柔散投影 + 1.75pt 干净外白环分离背景文字 + 柔和上亮下深微渐变 + 顶缘高光弧；
    /// - SF Pro Rounded Bold 字体 + `useGlyphPathBounds` 墨迹边界精确光学居中（彻底消除数字偏下/偏左）。
    private static func drawSequenceBadge(
        number: Int,
        at anchor: CGPoint,
        color: NSColor,
        strokeWidth: CGFloat,
        context: CGContext
    ) {
        let text = "\(number)"
        // 连续粗细映射（2pt 起步=24pt，随无极滑杆线性平滑增至最高 34pt）
        let diameter = (24 + min(max(strokeWidth - 2, 0), 8) * 1.25).rounded()
        let radius = diameter / 2

        let srgb = color.usingColorSpace(.sRGB) ?? color
        let rComp = srgb.redComponent
        let gComp = srgb.greenComponent
        let bComp = srgb.blueComponent
        let luminance = 0.299 * rComp + 0.587 * gComp + 0.114 * bComp
        let isLightFill = luminance > 0.64
        let isNearWhite = luminance > 0.90

        // 外白环尺寸（在彩底与文字背景上形成利落呼吸隔离带）
        let ringWidth: CGFloat = 1.75
        let outerRect = CGRect(
            x: anchor.x - radius - ringWidth,
            y: anchor.y - radius - ringWidth,
            width: (radius + ringWidth) * 2,
            height: (radius + ringWidth) * 2
        )
        let innerRect = CGRect(
            x: anchor.x - radius,
            y: anchor.y - radius,
            width: diameter,
            height: diameter
        )

        // 1. 柔和悬浮投影 + 纯净外隔离环（CGContext 阴影 offset 在设备空间 Y-up，负 Y = 向下投射）
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1.5),
            blur: 5.5,
            color: NSColor.black.withAlphaComponent(0.24).cgColor
        )
        let ringColor = isNearWhite
            ? NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
            : NSColor.white.withAlphaComponent(0.96)
        context.setFillColor(ringColor.cgColor)
        context.fillEllipse(in: outerRect)
        context.restoreGState()

        // 外圈极细暗影发丝边（白底页面上让外白环轮廓依然干净利落）
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(isNearWhite ? 0.18 : 0.10).cgColor)
        context.setLineWidth(0.5)
        context.strokeEllipse(in: outerRect.insetBy(dx: 0.25, dy: 0.25))
        context.restoreGState()

        // 2. 徽章本体：细腻顶亮底深微渐变（比纯平红圆更有 Apple 立体光泽）
        let topColor = NSColor(
            srgbRed: min(1, rComp + (1 - rComp) * 0.14),
            green: min(1, gComp + (1 - gComp) * 0.14),
            blue: min(1, bComp + (1 - bComp) * 0.14),
            alpha: 1
        )
        let bottomColor = NSColor(
            srgbRed: max(0, rComp * 0.90),
            green: max(0, gComp * 0.90),
            blue: max(0, bComp * 0.90),
            alpha: 1
        )
        context.saveGState()
        context.addEllipse(in: innerRect)
        context.clip()
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(
            colorsSpace: space,
            colors: [topColor.cgColor, color.cgColor, bottomColor.cgColor] as CFArray,
            locations: [0.0, 0.45, 1.0]
           ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: anchor.x, y: innerRect.minY),
                end: CGPoint(x: anchor.x, y: innerRect.maxY),
                options: []
            )
        } else {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: innerRect)
        }
        // 细腻内圈高光边
        context.setStrokeColor(NSColor.white.withAlphaComponent(isLightFill ? 0.35 : 0.22).cgColor)
        context.setLineWidth(0.75)
        context.strokeEllipse(in: innerRect.insetBy(dx: 0.375, dy: 0.375))
        context.restoreGState()

        // 3. SF Pro Rounded Bold 数字，按实际字形墨迹框（useGlyphPathBounds）精确光学居中
        let baseFontSize = diameter * (text.count >= 2 ? 0.46 : 0.54)
        let systemFont = NSFont.systemFont(ofSize: baseFontSize, weight: .bold)
        let roundedFont: NSFont
        if let desc = systemFont.fontDescriptor.withDesign(.rounded),
           let f = NSFont(descriptor: desc, size: baseFontSize) {
            roundedFont = f
        } else {
            roundedFont = systemFont
        }
        let textColor = isLightFill
            ? NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
            : NSColor.white

        let attributed = NSAttributedString(string: text, attributes: [
            .font: roundedFont,
            .foregroundColor: textColor,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        context.saveGState()
        if !isLightFill {
            context.setShadow(
                offset: CGSize(width: 0, height: -0.75),
                blur: 1.2,
                color: NSColor.black.withAlphaComponent(0.18).cgColor
            )
        }
        // Y-down 上下文中局部翻为 Y-up 后，字形墨迹中心 (midX, midY) 严格落于 anchor
        context.translateBy(x: anchor.x - glyphBounds.midX, y: anchor.y + glyphBounds.midY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// 普通文字标注绘制（Apple Markup 风格：semibold 清晰字重 + 克制自适应可读性微影，明暗截图皆利落）
    private static func drawText(_ text: String, at anchor: CGPoint, color: NSColor, size: CGFloat? = nil, context: CGContext, yDown: Bool) {
        guard !text.isEmpty else { return }
        let fontSize = size ?? 14
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        let isVeryDark = luminance < 0.22

        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: isVeryDark ? 0 : -0.75),
            blur: isVeryDark ? 2.5 : 2.2,
            color: (isVeryDark
                ? NSColor.white.withAlphaComponent(0.50)
                : NSColor.black.withAlphaComponent(0.28)).cgColor
        )
        context.translateBy(x: anchor.x, y: anchor.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
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
              let ctx = makeRGBA8Context(width: width, height: height, matching: image) else { return image }
        // 画底图（一次；多区域共用同一全图上下文，避免逐区域全图重绘）
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        for (pxRect, blockSize) in clamped {
            // 块平均：缩小再放大
            let blocksX = max(1, Int(pxRect.width) / blockSize)
            let blocksY = max(1, Int(pxRect.height) / blockSize)
            guard let cropped = image.cropping(to: pxRect),
                  let smallCtx = makeRGBA8Context(width: blocksX, height: blocksY, matching: image) else { continue }
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

    /// 优先沿用源图 RGB 色域（如 Display P3）创建 8-bit 上下文，避免广色域退化为 sRGB 且零多余转换开销
    private static func makeRGBA8Context(width: Int, height: Int, matching image: CGImage?) -> CGContext? {
        if let preferred = image?.colorSpace,
           preferred.model == .rgb,
           !CGColorSpaceUsesExtendedRange(preferred),
           let ctx = CGContext(
               data: nil,
               width: width,
               height: height,
               bitsPerComponent: 8,
               bytesPerRow: 0,
               space: preferred,
               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
           ) {
            return ctx
        }
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: fallback,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - 克制画框美化（Smart Backdrop：预览与导出统一渲染管线）

    /// 快速采样图像四边主色（下采样到最大边 ≤ 128px 后沿四边各取 24 个内缩 1px 样本）
    ///
    /// - Returns: 边缘色彩较一致（≥ 55% 样本单通道平均偏差 ≤ 0.16）时返回中位主色，
    ///   若边缘透明或色彩高度杂乱则返回 `nil`（调用方优雅回落，避免强行补色违和）。
    static func detectEdgeColor(of image: CGImage) -> RGBAColor? {
        guard image.width > 0, image.height > 0 else { return nil }

        let maxSide: CGFloat = 128
        let longest = CGFloat(max(image.width, image.height))
        let downscale = min(1, maxSide / longest)
        let bufW = max(1, Int((CGFloat(image.width) * downscale).rounded()))
        let bufH = max(1, Int((CGFloat(image.height) * downscale).rounded()))
        let bytesPerRow = bufW * 4
        var pixels = [UInt8](repeating: 0, count: bufH * bytesPerRow)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = CGContext(
                    data: baseAddress,
                    width: bufW,
                    height: bufH,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: bufW, height: bufH))
            return true
        }
        guard drawn else { return nil }

        let insetX = bufW > 2 ? 1 : 0
        let insetY = bufH > 2 ? 1 : 0
        let minX = insetX
        let maxX = bufW - 1 - insetX
        let minY = insetY
        let maxY = bufH - 1 - insetY
        let samplesPerEdge = 24

        struct Sample {
            let r: CGFloat
            let g: CGFloat
            let b: CGFloat
        }

        var samples: [Sample] = []
        samples.reserveCapacity(samplesPerEdge * 4)

        func appendSample(x rawX: Int, y rawY: Int) {
            let x = min(bufW - 1, max(0, rawX))
            let y = min(bufH - 1, max(0, rawY))
            let offset = y * bytesPerRow + x * 4
            let alphaByte = pixels[offset + 3]
            guard alphaByte >= 16 else { return }
            let alpha = CGFloat(alphaByte) / 255.0
            let r = min(1, max(0, (CGFloat(pixels[offset]) / 255.0) / alpha))
            let g = min(1, max(0, (CGFloat(pixels[offset + 1]) / 255.0) / alpha))
            let b = min(1, max(0, (CGFloat(pixels[offset + 2]) / 255.0) / alpha))
            samples.append(Sample(r: r, g: g, b: b))
        }

        for i in 0..<samplesPerEdge {
            let t = (CGFloat(i) + 0.5) / CGFloat(samplesPerEdge)
            let x = Int((CGFloat(minX) + t * CGFloat(maxX - minX)).rounded())
            let y = Int((CGFloat(minY) + t * CGFloat(maxY - minY)).rounded())
            appendSample(x: x, y: minY)
            appendSample(x: x, y: maxY)
            appendSample(x: minX, y: y)
            appendSample(x: maxX, y: y)
        }

        guard samples.count >= 8 else { return nil }

        func median(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[mid - 1] + sorted[mid]) * 0.5
            }
            return sorted[mid]
        }

        let medR = median(samples.map(\.r))
        let medG = median(samples.map(\.g))
        let medB = median(samples.map(\.b))

        let threshold: CGFloat = 0.16
        let matchingCount = samples.reduce(0) { count, sample in
            let meanDelta = (abs(sample.r - medR) + abs(sample.g - medG) + abs(sample.b - medB)) / 3.0
            return count + (meanDelta <= threshold ? 1 : 0)
        }

        guard CGFloat(matchingCount) / CGFloat(samples.count) >= 0.55 else { return nil }
        return RGBAColor(red: medR, green: medG, blue: medB, alpha: 1)
    }

    /// 计算柔和克制的边缘主色均衡内衬（仅在开启 autoBalance 且检测到有效边缘主色时启用）
    static func effectiveBalanceInset(
        for style: BackdropStyle,
        imagePointSize: CGSize,
        edgeColor: RGBAColor?
    ) -> CGFloat {
        guard style.autoBalance, edgeColor != nil else { return 0 }
        let shortSide = min(imagePointSize.width, imagePointSize.height)
        guard shortSide > 0 else { return 0 }
        return min(16, max(8, shortSide * 0.03)).rounded()
    }

    /// 绘制背景线性渐变（预览与导出共用；`startPoint`/`endPoint` 始终以视觉左上为 `(0,0)`、右下为 `(1,1)`）
    static func drawBackdropBackground(
        style: BackdropStyle,
        in rect: CGRect,
        context: CGContext,
        contextIsYDown: Bool
    ) {
        guard !rect.isEmpty else { return }
        let colors = style.preset.colors
        guard !colors.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cgColors = colors.map(\.cgColor)
        if cgColors.count >= 2 {
            let count = cgColors.count
            let locations = (0..<count).map { CGFloat($0) / CGFloat(count - 1) }
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: cgColors as CFArray,
                locations: locations
            ) {
                let startNorm = style.preset.startPoint
                let endNorm = style.preset.endPoint
                let start = CGPoint(
                    x: rect.minX + startNorm.x * rect.width,
                    y: contextIsYDown
                        ? rect.minY + startNorm.y * rect.height
                        : rect.maxY - startNorm.y * rect.height
                )
                let end = CGPoint(
                    x: rect.minX + endNorm.x * rect.width,
                    y: contextIsYDown
                        ? rect.minY + endNorm.y * rect.height
                        : rect.maxY - endNorm.y * rect.height
                )
                context.drawLinearGradient(
                    gradient,
                    start: start,
                    end: end,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                return
            }
        }

        context.setFillColor(cgColors[0])
        context.fill(rect)
    }

    /// 绘制圆角卡片双层 Apple 风格柔和投影与均衡衬底（预览与导出共用）
    ///
    /// - Note: `CGBitmapContext`（`contextIsYDown == false`）的 `setShadow` 在设备空间 Y-up 上，
    ///   需以负 `offset.height` 向下投影并按 CTM 缩放补偿；layer-backed flipped AppKit 视图
    ///   （`contextIsYDown == true`）已带翻转后的 BaseCTM，正 `offset.height` 向下投影且按 pt 计。
    static func drawBackdropCardChrome(
        cardRect: CGRect,
        cornerRadius: CGFloat,
        isDarkBackdrop: Bool,
        cushionColor: RGBAColor?,
        context: CGContext,
        contextIsYDown: Bool
    ) {
        guard cardRect.width > 0, cardRect.height > 0 else { return }
        let clampedRadius = min(max(0, cornerRadius), min(cardRect.width, cardRect.height) * 0.5)
        let cardPath = CGPath(
            roundedRect: cardRect,
            cornerWidth: clampedRadius,
            cornerHeight: clampedRadius,
            transform: nil
        )

        let ySign: CGFloat = contextIsYDown ? 1 : -1
        let shadowScale: CGFloat = contextIsYDown
            ? 1
            : max(1, hypot(context.ctm.a, context.ctm.b))

        let fillColor: CGColor
        if let cushionColor {
            fillColor = cushionColor.withAlpha(1).cgColor
        } else if isDarkBackdrop {
            fillColor = CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        } else {
            fillColor = CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1)
        }

        // 1. 远层环境大柔影
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: ySign * 14 * shadowScale),
            blur: 32 * shadowScale,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: isDarkBackdrop ? 0.48 : 0.14)
        )
        context.addPath(cardPath)
        context.setFillColor(fillColor)
        context.fillPath()
        context.restoreGState()

        // 2. 近层接触微影 + 干净不透明卡片衬底
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: ySign * 3 * shadowScale),
            blur: 8 * shadowScale,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: isDarkBackdrop ? 0.28 : 0.08)
        )
        context.addPath(cardPath)
        context.setFillColor(fillColor)
        context.fillPath()
        context.restoreGState()
    }

    /// 绘制圆角卡片外沿内缩半线宽的 0.5pt 克制发丝描边（预览与导出共用）
    static func drawBackdropCardHairline(
        cardRect: CGRect,
        cornerRadius: CGFloat,
        isDarkBackdrop: Bool,
        lineWidth: CGFloat,
        context: CGContext
    ) {
        guard cardRect.width > 0, cardRect.height > 0, lineWidth > 0 else { return }
        let inset = lineWidth * 0.5
        let insetRect = cardRect.insetBy(dx: inset, dy: inset)
        guard insetRect.width > 0, insetRect.height > 0 else { return }

        let adjustedRadius = min(
            max(0, cornerRadius - inset),
            min(insetRect.width, insetRect.height) * 0.5
        )
        let path = CGPath(
            roundedRect: insetRect,
            cornerWidth: adjustedRadius,
            cornerHeight: adjustedRadius,
            transform: nil
        )
        let strokeColor = isDarkBackdrop
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08)

        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(strokeColor)
        context.setLineWidth(lineWidth)
        context.strokePath()
        context.restoreGState()
    }

    /// 导出合成：在截图外围渲染克制画框（渐变背景 + 双层柔影卡片 + 可选边缘主色均衡内衬 + 发丝描边）
    static func renderWithBackdrop(
        image: CGImage,
        style: BackdropStyle,
        scale: CGFloat,
        precomputedEdgeColor: RGBAColor? = nil
    ) -> CGImage {
        guard style.enabled else { return image }

        let safeScale = max(1, scale)
        let imagePointSize = CGSize(
            width: CGFloat(image.width) / safeScale,
            height: CGFloat(image.height) / safeScale
        )
        let edgeColor = style.autoBalance ? (precomputedEdgeColor ?? detectEdgeColor(of: image)) : nil
        let inset = effectiveBalanceInset(for: style, imagePointSize: imagePointSize, edgeColor: edgeColor)
        let layout = style.layout(for: imagePointSize, balanceInset: inset)

        let pxW = max(1, Int((layout.canvasSize.width * safeScale).rounded()))
        let pxH = max(1, Int((layout.canvasSize.height * safeScale).rounded()))

        guard let ctx = makeRGBA8Context(width: pxW, height: pxH, matching: image) else { return image }

        let canvasW = layout.canvasSize.width
        let canvasH = layout.canvasSize.height
        func yUpRect(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: canvasH - rect.maxY, width: rect.width, height: rect.height)
        }

        ctx.saveGState()
        ctx.scaleBy(x: safeScale, y: safeScale)

        let canvasRect = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        let cardRectYUp = yUpRect(layout.cardRect)
        let imageRectYUp = yUpRect(layout.imageRect)
        let isDark = style.preset.isDark

        // 1. 铺满线性渐变背景
        drawBackdropBackground(style: style, in: canvasRect, context: ctx, contextIsYDown: false)

        // 2. 绘制圆角卡片双层柔影与均衡内衬底
        drawBackdropCardChrome(
            cardRect: cardRectYUp,
            cornerRadius: layout.cornerRadius,
            isDarkBackdrop: isDark,
            cushionColor: inset > 0 ? edgeColor : nil,
            context: ctx,
            contextIsYDown: false
        )

        // 3. 圆角裁切 cardRect 并精确绘制原图到 imageRect
        let cardPath = CGPath(
            roundedRect: cardRectYUp,
            cornerWidth: layout.cornerRadius,
            cornerHeight: layout.cornerRadius,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        let pxOriginX = imageRectYUp.minX * safeScale
        let pxOriginY = imageRectYUp.minY * safeScale
        let isPixelAligned = abs(pxOriginX - pxOriginX.rounded()) < 0.01
            && abs(pxOriginY - pxOriginY.rounded()) < 0.01
            && abs(imageRectYUp.width * safeScale - CGFloat(image.width)) < 0.5
            && abs(imageRectYUp.height * safeScale - CGFloat(image.height)) < 0.5
        ctx.interpolationQuality = isPixelAligned ? .none : .high
        ctx.draw(image, in: imageRectYUp)
        ctx.restoreGState()

        // 4. 绘制 0.5pt 精致发丝描边
        drawBackdropCardHairline(
            cardRect: cardRectYUp,
            cornerRadius: layout.cornerRadius,
            isDarkBackdrop: isDark,
            lineWidth: 0.5,
            context: ctx
        )

        ctx.restoreGState()
        return ctx.makeImage() ?? image
    }
}
