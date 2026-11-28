import CoreGraphics
import Foundation

/// 已画标注的二次编辑几何引擎（纯 Core：无 AppKit / Vision / ScreenCaptureKit）
///
/// 设计口径：
/// - 命中判定与拖拽变换都是**纯函数**，输入「标注 + 光标点」输出「命中结果 / 新标注」，
///   不持有状态、不碰视图：UI 层只负责把鼠标事件换算成字段调用，导出与编辑器共用同一几何真相，
///   避免"编辑器里能选中、导出后位置不一致"的双轨漂移。
/// - 坐标系与 `AnnotationModel` 完全一致：选区本地 point 坐标（原点选区左上，Y 向下）。
/// - 所有容差以「视觉可点」为准而非「数学精确」：描边类标注按线宽给足手指容差，
///   实体类（马赛克）按面积命中，描边类不给内部空白挡路（框内嵌套的文字/箭头仍可点）。
public enum AnnotationHandle: Equatable, Hashable, Sendable {
    /// 标注本体（整条平移）
    case body
    /// 起点手柄（`.arrow` / `.highlight`）
    case start
    /// 终点手柄（`.arrow` / `.highlight`）
    case end
    /// 左上角（`.rect` / `.mosaic` / `.ellipse`）
    case topLeft
    /// 右上角
    case topRight
    /// 左下角
    case bottomLeft
    /// 右下角
    case bottomRight
}

/// 命中结果：命中第几条 + 命中的是哪一部分（操控柄 or 本体）
public struct AnnotationHitResult: Equatable, Sendable {
    public let index: Int
    public let handle: AnnotationHandle

    public init(index: Int, handle: AnnotationHandle) {
        self.index = index
        self.handle = handle
    }
}

/// 文字的排版度量（Core 侧纯值类型：字体由 UI 层用 CoreText 量好传回，Core 不 import AppKit/CoreText）
///
/// 坐标口径与 `CGRenderer.drawText` 完全一致：`.text` 的 `anchor` 是**文字基线（baseline）**，
/// 字形向上延伸 `ascent`、向下延伸 `descent`，水平方向从 `anchor.x` 起排 `width`。
/// 因此视觉矩形永远是「基线之上 ascent、基线之下 descent」，不是「anchor 作为左上角」。
public struct AnnotationTextMetrics: Equatable, Sendable {
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public var height: CGFloat { ascent + descent }

    public init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }
}

/// 操控柄的锚点（世界坐标 = 选区本地坐标），UI 层据此画 8pt 小方块
public struct AnnotationHandlePoint: Equatable, Sendable {
    public let handle: AnnotationHandle
    public let point: CGPoint

    public init(handle: AnnotationHandle, point: CGPoint) {
        self.handle = handle
        self.point = point
    }
}

/// 标注编辑几何：包围盒 / 操控柄布局 / 命中 / 拖拽变换
public enum AnnotationEditorGeometry {

    // MARK: - 基础几何

    /// 反向拖拽产生的负宽高矩形归一化（与 CGRenderer.normalized 同口径）
    private static func normalized(_ r: CGRect) -> CGRect {
        CGRect(
            x: min(r.minX, r.maxX),
            y: min(r.minY, r.maxY),
            width: abs(r.width),
            height: abs(r.height)
        )
    }

    /// 两点外接矩形（箭头 / 高亮笔；反向拖拽同样归一）
    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 点到线段的最短距离（箭头/高亮的环形命中基础，退化线段按点距处理）
    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return distance(p, a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// 描边类标注的基础可点容差：细线也要按 4pt 上浮，粗线按半线宽外扩
    private static func strokeTolerance(tolerance: CGFloat, strokeWidth: CGFloat) -> CGFloat {
        max(tolerance, strokeWidth / 2 + 4)
    }

    // MARK: - 序号徽章

    /// 序号徽章视觉半径（与 CGRenderer.drawSequenceBadge 视觉同源：直径随无极滑杆 24→34pt 平滑增长）
    ///
    /// 绘制端直径 = 24 + clamp(strokeWidth - 2, 0, 8) * 1.25（24…34），外加 1.75pt 白色隔离环；
    /// 这里用更保守的连续映射 `diameter = clamp(20 + strokeWidth * 2, 24, 34)`（2pt→24、6pt→32、8pt→34），
    /// 再按「半径 + 2pt 余量」给命中半径，保证徽章边缘可点、且不会因滑杆微调而突变。
    public static func sequenceRadius(strokeWidth: CGFloat) -> CGFloat {
        let diameter = max(24, min(34, 20 + strokeWidth * 2))
        return diameter / 2 + 2
    }

    // MARK: - 包围盒

    /// 标注的轴对齐包围盒（selection 布局、hover 高亮、文字改字框定位都用它）
    ///
    /// - `textMetrics` 为文字实测排版度量（由 UI 用 CoreText 量出来传回，Core 不碰字体），
    ///   最精确：视觉矩形 = `CGRect(x: anchor.x, y: anchor.y - ascent, width, height: ascent + descent)`。
    /// - `textSize` 为只有宽高的旧口径（向后兼容）：把高度按经验比例拆成 ascent/descent，
    ///   同样**按基线**对齐（病例：旧实现把 anchor 当左上角 ⇒ 蓝框比文字低一整个字高）。
    public static func boundingRect(for annotation: AnnotationModel, textMetrics: AnnotationTextMetrics?) -> CGRect {
        switch annotation.shape {
        case .text(let anchor):
            let m = textMetrics ?? heuristicTextMetrics(for: annotation)
            return CGRect(x: anchor.x, y: anchor.y - m.ascent, width: m.width, height: m.height)
        default:
            return boundingRect(for: annotation, textSize: nil)
        }
    }

    /// 遗留口径：只拿到宽高时的包围盒（文字同样按基线对齐）
    ///
    /// - `textSize` 为文字实测尺寸（由 UI 量出来传回，Core 不碰字体）；
    ///   为 nil 时按字符数 × 字号的启发式估宽，保证 Core 侧无字体依赖也能出框。
    public static func boundingRect(for annotation: AnnotationModel, textSize: CGSize?) -> CGRect {
        switch annotation.shape {
        case .arrow(let from, let to):
            return rect(from: from, to: to)
        case .highlight(let from, let to):
            return rect(from: from, to: to)
        case .rect(let r):
            return normalized(r)
        case .mosaic(let r):
            return normalized(r)
        case .ellipse(let center, let radiusX, let radiusY):
            let rx = abs(radiusX)
            let ry = abs(radiusY)
            return CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)
        case .sequence(let anchor):
            let radius = sequenceRadius(strokeWidth: annotation.strokeWidth)
            return CGRect(
                x: anchor.x - radius,
                y: anchor.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        case .text(let anchor):
            let m = resolvedTextMetrics(for: annotation, textSize: textSize)
            return CGRect(x: anchor.x, y: anchor.y - m.ascent, width: m.width, height: m.height)
        }
    }

    // MARK: - 文字度量

    /// 只有宽高时把高度拆成 ascent/descent（经验比例 0.79 / 0.21，两者之和恒等于高度）
    public static func resolvedTextMetrics(
        for annotation: AnnotationModel,
        textSize: CGSize?
    ) -> AnnotationTextMetrics {
        guard let size = textSize else { return heuristicTextMetrics(for: annotation) }
        let height = max(0, size.height)
        let ascent = height * 0.79
        return AnnotationTextMetrics(
            width: max(0, size.width),
            ascent: ascent,
            descent: height - ascent
        )
    }

    /// 完全拿不到排版信息时的启发式度量（UI 尚未排版完成的瞬间也能出框/命中）
    public static func heuristicTextMetrics(for annotation: AnnotationModel) -> AnnotationTextMetrics {
        let fontSize = max(1, annotation.fontSize)
        return AnnotationTextMetrics(
            width: max(48, CGFloat((annotation.text ?? "").count) * fontSize * 0.65),
            ascent: fontSize * 0.95,
            descent: fontSize * 0.28
        )
    }

    // MARK: - 操控柄

    /// 该标注可拉的操控柄（箭头/高亮给两端点；矩形/马赛克/椭圆给四角；序号与文字仅本体拖拽）
    public static func handles(
        for annotation: AnnotationModel,
        textSize: CGSize? = nil
    ) -> [AnnotationHandlePoint] {
        switch annotation.shape {
        case .arrow(let from, let to):
            return [
                AnnotationHandlePoint(handle: .start, point: from),
                AnnotationHandlePoint(handle: .end, point: to)
            ]
        case .highlight(let from, let to):
            return [
                AnnotationHandlePoint(handle: .start, point: from),
                AnnotationHandlePoint(handle: .end, point: to)
            ]
        case .rect(let r), .mosaic(let r):
            return corners(of: normalized(r))
        case .ellipse:
            return corners(of: boundingRect(for: annotation, textSize: textSize))
        case .sequence, .text:
            return []
        }
    }

    private static func corners(of r: CGRect) -> [AnnotationHandlePoint] {
        [
            AnnotationHandlePoint(handle: .topLeft, point: CGPoint(x: r.minX, y: r.minY)),
            AnnotationHandlePoint(handle: .topRight, point: CGPoint(x: r.maxX, y: r.minY)),
            AnnotationHandlePoint(handle: .bottomLeft, point: CGPoint(x: r.minX, y: r.maxY)),
            AnnotationHandlePoint(handle: .bottomRight, point: CGPoint(x: r.maxX, y: r.maxY))
        ]
    }

    /// 操控柄命中（先手柄后本体：手柄优先，避免贴着角的拖拽被当成本体平移）
    public static func hitTestHandle(
        at point: CGPoint,
        for annotation: AnnotationModel,
        textSize: CGSize? = nil,
        tolerance: CGFloat = 9
    ) -> AnnotationHandle? {
        for candidate in handles(for: annotation, textSize: textSize)
        where distance(point, candidate.point) <= tolerance {
            return candidate.handle
        }
        return nil
    }

    // MARK: - 本体命中

    /// 本体命中（倒序遍历 ⇒ 顶层标注优先；返回下标，nil = 没点到任何标注）
    ///
    /// 各形状口径：
    /// - 箭头/高亮：到线段距离；高亮笔线宽粗，容差至少 `strokeWidth * 1.5`
    /// - 矩形：只命中**描边环**，不拦截内部空白（框内嵌套的文字/箭头照样可点，框内拖拽仍能起选区）
    /// - 椭圆：命中椭圆边环（按平均半径把法向容差换算成归一化半径带宽）；极小椭圆退化为整块命中
    /// - 马赛克：命中整个实体面积（外扩 4pt，实体本就是"盖住的区块"语义）
    /// - 序号：命中徽章圆 + 4pt；文字：命中**基线对齐后的字形框**外扩（dx 6 / dy 4）
    ///
    /// - `textMetricsProvider`：UI 用 CoreText 量出的精确排版度量（优先，1:1 贴合视觉字形）
    /// - `textSizeProvider`：只有宽高的旧口径（向后兼容，同样按基线对齐）
    public static func hitTestBody(
        at point: CGPoint,
        in annotations: [AnnotationModel],
        textMetricsProvider: (AnnotationModel) -> AnnotationTextMetrics? = { _ in nil },
        textSizeProvider: (AnnotationModel) -> CGSize? = { _ in nil },
        tolerance: CGFloat = 8
    ) -> Int? {
        for index in annotations.indices.reversed() {
            if hitTestBody(
                at: point,
                for: annotations[index],
                textMetrics: textMetricsProvider(annotations[index]),
                textSize: textSizeProvider(annotations[index]),
                tolerance: tolerance
            ) {
                return index
            }
        }
        return nil
    }

    /// 单条标注的本体命中（便于 UI 单独校验某条，也便于测试逐形状断言）
    public static func hitTestBody(
        at point: CGPoint,
        for annotation: AnnotationModel,
        textMetrics: AnnotationTextMetrics? = nil,
        textSize: CGSize? = nil,
        tolerance: CGFloat = 8
    ) -> Bool {
        switch annotation.shape {
        case .arrow(let from, let to), .highlight(let from, let to):
            var limit = strokeTolerance(tolerance: tolerance, strokeWidth: annotation.strokeWidth)
            if case .highlight = annotation.shape {
                limit = max(limit, annotation.strokeWidth * 1.5)
            }
            return distanceToSegment(point, from, to) <= limit

        case .rect(let r):
            let limit = strokeTolerance(tolerance: tolerance, strokeWidth: annotation.strokeWidth)
            let outer = normalized(r).insetBy(dx: -limit, dy: -limit)
            guard outer.contains(point) else { return false }
            let inner = normalized(r).insetBy(dx: limit, dy: limit)
            // 内缩后一旦塌陷（细框/小框）就没有"内部空白"，整块都算描边
            if inner.width <= 0 || inner.height <= 0 { return true }
            return !inner.contains(point)

        case .ellipse(let center, let radiusX, let radiusY):
            let rx = abs(radiusX)
            let ry = abs(radiusY)
            guard rx > 0.0001, ry > 0.0001 else {
                return distance(point, center) <= strokeTolerance(tolerance: tolerance, strokeWidth: annotation.strokeWidth)
            }
            let limit = strokeTolerance(tolerance: tolerance, strokeWidth: annotation.strokeWidth)
            // 极小椭圆没法按"环"点中，退化为整块命中（否则等于不可选）
            if rx < 12 || ry < 12 {
                return boundingRect(for: annotation, textSize: textSize)
                    .insetBy(dx: -limit, dy: -limit)
                    .contains(point)
            }
            let nx = (point.x - center.x) / rx
            let ny = (point.y - center.y) / ry
            let normalizedRadius = (nx * nx + ny * ny).squareRoot()
            let band = limit / ((rx + ry) / 2)
            return normalizedRadius >= max(0, 1 - band) && normalizedRadius <= 1 + band

        case .mosaic(let r):
            return normalized(r).insetBy(dx: -4, dy: -4).contains(point)

        case .sequence(let anchor):
            return distance(point, anchor) <= sequenceRadius(strokeWidth: annotation.strokeWidth) + 4

        case .text:
            // 字形框是排版量出来的（宽度依赖 UI 实测）；这里按基线对齐后的视觉矩形给 dx 6 / dy 4 的手指容差
            let m = textMetrics ?? resolvedTextMetrics(for: annotation, textSize: textSize)
            return boundingRect(for: annotation, textMetrics: m)
                .insetBy(dx: -6, dy: -4)
                .contains(point)
        }
    }

    // MARK: - 拖拽变换

    /// 单一拖拽步（UI 每帧用「原始标注 + 累计 delta」调用它，天然幂等、不累积漂移）
    ///
    /// - `.body`：整条平移
    /// - `.arrow` / `.highlight`：`.start` 移 from、`.end` 移 to
    /// - `.rect` / `.mosaic`：拖动角、锚定对角，允许跨对角翻转（翻转后仍是合法矩形），宽/高钳制 `minSize`
    /// - `.ellipse`：外接矩形按四角锚定对角缩放，再回算 center / radiusX / radiusY（半径不塌成 0）
    /// - handle 与形状不匹配：原样返回（让调用方不必先判形状）
    public static func transformed(
        _ annotation: AnnotationModel,
        handle: AnnotationHandle,
        delta: CGSize,
        minSize: CGFloat = 8
    ) -> AnnotationModel {
        if handle == .body {
            return annotation.offsetBy(dx: delta.width, dy: delta.height)
        }

        switch annotation.shape {
        case .arrow(let from, let to):
            switch handle {
            case .start:
                return replacing(annotation, with: .arrow(from: moved(from, by: delta), to: to))
            case .end:
                return replacing(annotation, with: .arrow(from: from, to: moved(to, by: delta)))
            default:
                return annotation
            }

        case .highlight(let from, let to):
            switch handle {
            case .start:
                return replacing(annotation, with: .highlight(from: moved(from, by: delta), to: to))
            case .end:
                return replacing(annotation, with: .highlight(from: from, to: moved(to, by: delta)))
            default:
                return annotation
            }

        case .rect(let r):
            guard let newRect = resized(r, handle: handle, delta: delta, minSize: minSize) else {
                return annotation
            }
            return replacing(annotation, with: .rect(newRect))

        case .mosaic(let r):
            guard let newRect = resized(r, handle: handle, delta: delta, minSize: minSize) else {
                return annotation
            }
            return replacing(annotation, with: .mosaic(newRect))

        case .ellipse(let center, let radiusX, let radiusY):
            let box = CGRect(
                x: center.x - abs(radiusX),
                y: center.y - abs(radiusY),
                width: abs(radiusX) * 2,
                height: abs(radiusY) * 2
            )
            guard let newRect = resized(box, handle: handle, delta: delta, minSize: minSize) else {
                return annotation
            }
            let minRadius = minSize / 2
            return replacing(annotation, with: .ellipse(
                center: CGPoint(x: newRect.midX, y: newRect.midY),
                radiusX: max(minRadius, newRect.width / 2),
                radiusY: max(minRadius, newRect.height / 2)
            ))

        case .sequence, .text:
            return annotation
        }
    }

    private static func moved(_ p: CGPoint, by delta: CGSize) -> CGPoint {
        CGPoint(x: p.x + delta.width, y: p.y + delta.height)
    }

    private static func replacing(
        _ annotation: AnnotationModel,
        with shape: AnnotationModel.Shape
    ) -> AnnotationModel {
        var copy = annotation
        copy.shape = shape
        return copy
    }

    /// 四角缩放：锚定对角不动，移动拖动角；跨过对角时自动翻转，跨度不足 `minSize` 则按拖动方向钳制
    private static func resized(
        _ r: CGRect,
        handle: AnnotationHandle,
        delta: CGSize,
        minSize: CGFloat
    ) -> CGRect? {
        let box = normalized(r)
        let anchor: CGPoint
        let moving: CGPoint
        switch handle {
        case .topLeft:
            anchor = CGPoint(x: box.maxX, y: box.maxY)
            moving = CGPoint(x: box.minX, y: box.minY)
        case .topRight:
            anchor = CGPoint(x: box.minX, y: box.maxY)
            moving = CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeft:
            anchor = CGPoint(x: box.maxX, y: box.minY)
            moving = CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight:
            anchor = CGPoint(x: box.minX, y: box.minY)
            moving = CGPoint(x: box.maxX, y: box.maxY)
        default:
            return nil
        }

        var x = moving.x + delta.width
        var y = moving.y + delta.height
        // 钳制最小跨度：保留拖动方向（翻转为负跨度同样成立），不足则推到 minSize
        if abs(x - anchor.x) < minSize {
            x = anchor.x + (x < anchor.x ? -minSize : minSize)
        }
        if abs(y - anchor.y) < minSize {
            y = anchor.y + (y < anchor.y ? -minSize : minSize)
        }
        return normalized(CGRect(
            x: min(anchor.x, x),
            y: min(anchor.y, y),
            width: abs(x - anchor.x),
            height: abs(y - anchor.y)
        ))
    }
}
