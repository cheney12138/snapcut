import AppKit
import CoreGraphics

/// 拼贴导出（docs/06 §2 导出 / §4 C4：CollageExporter = 范围 + composite）
///
/// 把 CollageDocument（贴片 + 统一标注）合成为单张 CGImage。渲染约定与
/// 画布窗口完全同一条路径（「编辑器所见 = 导出所得」）：
/// - 坐标系：画布坐标（原点左上、Y 向下，与 Piece.frame / AnnotationModel 同一空间；
///   canvasOrigin 是派生值不是平移——见 CollageDocument.recomputeCanvas 不移动 frame）。
///   导出时整体翻上翻成位图的 Y-up 空间，翻转手法与 CGRenderer.composite 一致
///   （translateBy(0, h) + scaleBy(1, -1)）。
/// - 背景色铺满整个画布：外圈 padding 与贴片间 gutter（SnapGeometry.defaultGutter 16pt）
///   都是「没有贴片的画布」，自然透出背景色——间隙即背景色由此保证，不需要单独画格线。
/// - 贴片：图像拉伸填入 frame + 绕中心顺时针旋转 + 分镜框裁切（圆角 2）+
///   分镜框描边（0.5pt，半透明黑发丝线，默认开）。
/// - 标注层：CGRenderer.render 零改动复用，contextIsYDown: true（翻转后的上下文
///   与编辑器 isFlipped 画布同约定；composite 病例已注明两种上下文的翻转差异）。
///   ⚠️ 已知边界：mosaic 标注的像素化只存在于 CGRenderer.composite 的单底图路径，
///   拼贴多底图没有统一「底图」，矢量层对 mosaic 不绘制（与编辑器预览一致的行为边界）。
///
/// 剪贴板/保存链路：复用既有 ExportCoordinator 思路——本文件只提供 exportAndCopy
/// （ClipboardWriter PNG+TIFF 双表示 + CaptureToast 反馈），落盘继续走
/// ExportCoordinator.quickSave / savePanel，不另起炉灶。
enum CollageExporter {

    // MARK: - Options

    struct ExportOptions: Sendable {
        /// 画布背景色（docs/06 §2：透明/白/深色三选，导出随选）
        enum Background: String, Sendable, CaseIterable {
            /// 透明（PNG alpha，间隙与 padding 全透）
            case transparent
            case white
            /// 深色 #1E1E22
            case dark
        }

        var background: Background
        /// 内容 bounding box 到画布边缘的留白（默认与文档画布 padding 一致 = 32）
        var padding: CGFloat
        /// 像素比例：1 = 1x（1 画布 pt = 1 px），2 = 2x Retina；其余正值也允许
        var scale: CGFloat

        init(
            background: Background = .transparent,
            padding: CGFloat = CollageDocument.canvasPadding,
            scale: CGFloat = 1
        ) {
            self.background = background
            self.padding = padding
            self.scale = scale
        }
    }

    // MARK: - 分镜框常量（与画布窗口渲染同一组值，docs/06 §2：0.5pt 描边 + 圆角 2）

    static let panelBorderWidth: CGFloat = 0.5
    static let panelCornerRadius: CGFloat = 2

    /// 半透明黑发丝线（任意背景色上都可读；CGColor 每次现建，避免静态非 Sendable 存储）
    static var panelBorderColor: CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4) }

    /// 深色背景 #1E1E22
    static var darkBackgroundColor: CGColor {
        CGColor(srgbRed: 30 / 255, green: 30 / 255, blue: 34 / 255, alpha: 1)
    }

    // MARK: - 导出

    /// 按画布范围合成整图
    ///
    /// - Parameters:
    ///   - document: 拼贴文档（贴片几何 + 标注几何，画布坐标 Y-down）
    ///   - imageProvider: imageRef 字符串键 → 位图（适配器负责查图像缓存/解码）
    ///   - options: 背景 / padding / scale
    /// - Returns: 合成位图；空文档、非法 scale 或上下文创建失败返回 nil
    static func export(
        document: CollageDocument,
        imageProvider: (String) -> CGImage?,
        options: ExportOptions
    ) -> CGImage? {
        guard !document.pieces.isEmpty, options.scale > 0 else { return nil }

        // 1. 导出范围 = 内容 bounding box（旋转感知）外扩 options.padding
        let bounds = exportBounds(of: document, padding: options.padding)
        let pxWidth = max(1, Int((bounds.width * options.scale).rounded()))
        let pxHeight = max(1, Int((bounds.height * options.scale).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: pxWidth,
            height: pxHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Log.error(.export, "collage.export.fail", ["reason": "context"])
            return nil
        }

        // 2. 背景色：铺满整个画布。透明 = 不铺（premultipliedLast 初始全 0）；
        //    白/深色实填——贴片间 gutter 与外圈 padding 没有贴片，透出的就是它。
        switch options.background {
        case .transparent:
            break
        case .white:
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))
        case .dark:
            ctx.setFillColor(darkBackgroundColor)
            ctx.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))
        }

        // 3. 画布 Y-down → 位图 Y-up（与 CGRenderer.composite 的翻转处理同构）：
        //    先平移负 bounds 原点（画布坐标归零到导出范围左上），
        //    再 scale + y 翻转（注意翻转在缩放里一并做：scaleBy(scale, -scale)）。
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(pxHeight))
        ctx.scaleBy(x: options.scale, y: -options.scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)

        // 4. 贴片：z 升序（低层先画，高层覆盖其上；reorderingZ 已把 z 归一化为数组下标）
        for piece in document.pieces.sorted(by: { $0.z < $1.z }) {
            drawPiece(piece, image: imageProvider(piece.imageRef), in: ctx)
        }

        // 5. 标注层：上下文此刻已是 Y-down（contextIsYDown: true），几何零换算。
        //    文字/序号徽章在 CGRenderer 内部局部翻 Y-up，两条路径都已验证过。
        CGRenderer.render(
            annotations: document.annotations,
            in: bounds.size,
            context: ctx,
            contextIsYDown: true
        )
        ctx.restoreGState()

        guard let output = ctx.makeImage() else {
            Log.error(.export, "collage.export.fail", ["reason": "makeImage"])
            return nil
        }
        Log.event(.export, "collage.export.ok", [
            "pxW": "\(pxWidth)", "pxH": "\(pxHeight)",
            "pieces": "\(document.pieces.count)",
            "bg": options.background.rawValue,
            "scale": "\(options.scale)",
        ])
        return output
    }

    // MARK: - 贴片绘制

    /// 单贴片：图像拉伸填 frame + 绕中心旋转 + 分镜框（裁切 + 描边）
    ///
    /// 旋转约定：piece.rotation「度，顺时针」。翻转后的上下文是 Y-down，
    /// CG rotate 正方向（+x→+y）在该空间里视觉上就是顺时针，度数直接进 rotate。
    private static func drawPiece(_ piece: CollagePiece, image: CGImage?, in ctx: CGContext) {
        let frame = piece.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let panel = CGRect(
            x: -frame.width / 2, y: -frame.height / 2,
            width: frame.width, height: frame.height
        )

        // 图像：平移到中心 → 旋转 → 圆角裁切 → y 翻转后绘制。
        // y 翻转的原因：Y-down 上下文里 draw 会把位图倒立（composite 同款病例），
        // 以中心为轴 scaleBy(1, -1) 后 panel 关于原点对称，正立贴回。
        if let image {
            ctx.saveGState()
            ctx.translateBy(x: frame.midX, y: frame.midY)
            if piece.rotation != 0 {
                ctx.rotate(by: piece.rotation * .pi / 180)
            }
            ctx.addPath(CGPath(
                roundedRect: panel,
                cornerWidth: panelCornerRadius,
                cornerHeight: panelCornerRadius,
                transform: nil
            ))
            ctx.clip()
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: panel)
            ctx.restoreGState()
        } else {
            Log.event(.export, "collage.export.missingImage", ["ref": "<private>"])
        }

        // 分镜框描边：与图像同一个旋转系（框随贴片转），但不做圆角裁切——
        // 0.5pt 线骑在 frame 边缘上，裁切会切掉外半像素。
        if piece.showsPanelBorder {
            ctx.saveGState()
            ctx.translateBy(x: frame.midX, y: frame.midY)
            if piece.rotation != 0 {
                ctx.rotate(by: piece.rotation * .pi / 180)
            }
            ctx.addPath(CGPath(
                roundedRect: panel,
                cornerWidth: panelCornerRadius,
                cornerHeight: panelCornerRadius,
                transform: nil
            ))
            ctx.setStrokeColor(panelBorderColor)
            ctx.setLineWidth(panelBorderWidth)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - 范围

    /// 导出范围 = 内容 bounding box 外扩 padding。
    /// 内容 bbox 对旋转贴片取「旋转后 rect 的轴对齐包围盒」，保证旋转贴片不出画布。
    private static func exportBounds(of document: CollageDocument, padding: CGFloat) -> CGRect {
        var content: CGRect?
        for piece in document.pieces {
            let aabb = rotatedAABB(piece.frame, rotation: piece.rotation)
            content = content.map { $0.union(aabb) } ?? aabb
        }
        guard let c = content else {
            return CGRect(origin: .zero, size: CollageDocument.defaultCanvasSize)
        }
        return c.insetBy(dx: -padding, dy: -padding)
    }

    /// rect 绕中心旋转 θ 后的轴对齐包围盒（±θ 对 AABB 等价，取绝对角度即可）
    private static func rotatedAABB(_ rect: CGRect, rotation: CGFloat) -> CGRect {
        let t = abs(rotation.truncatingRemainder(dividingBy: 360))
        guard t != 0 else { return rect }
        let theta = t * .pi / 180
        let s = sin(theta), c = cos(theta)
        let w = rect.width * c + rect.height * s
        let h = rect.width * s + rect.height * c
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

// MARK: - 复用 ExportCoordinator 的剪贴板链路

extension CollageExporter {
    /// 导出并复制：ClipboardWriter（PNG + TIFF 双表示）+ CaptureToast 反馈。
    /// 与既有 AppCoordinator 的 copyToClipboard → CaptureToast 调用序列一致，
    /// 拼贴窗口只需调这一个入口。
    @MainActor
    @discardableResult
    static func exportAndCopy(
        document: CollageDocument,
        imageProvider: (String) -> CGImage?,
        options: ExportOptions
    ) -> CGImage? {
        guard let image = export(document: document, imageProvider: imageProvider, options: options) else {
            Log.error(.export, "collage.export.fail", ["reason": "compose"])
            return nil
        }
        ClipboardWriter.writeImage(image)
        CaptureToast.show(image: image, message: "拼贴已复制到剪贴板")
        return image
    }
}
