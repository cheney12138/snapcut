import CoreGraphics

/// 选区调整的纯几何（领域层，无 AppKit）
///
/// 坐标系约定：本文件所有 rect/point 都是**视图本地坐标、Y 向下**（与覆盖层一致）。
/// 全局坐标（AppKit Y 向上）的换算由 UI 层负责，领域不关心屏幕。
///
/// 为什么单独成文件：选区调整是纯几何 + 一堆边界条件（最小尺寸、屏幕边界、
/// 手柄命中容差），把它抽成纯函数后，UI 只负责「把鼠标事件翻译成一次几何变换」。
public enum SelectionEdge: Sendable, Equatable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    /// 该手柄是否影响水平方向
    public var affectsX: Bool {
        switch self {
        case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        case .top, .bottom: return false
        }
    }

    /// 该手柄是否影响垂直方向
    public var affectsY: Bool {
        switch self {
        case .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        case .left, .right: return false
        }
    }
}

public enum SelectionGeometry {
    /// 手柄命中容差（逻辑点）
    public static let handleHitTolerance: CGFloat = 8
    /// 选区边长超过该值才显示手柄
    public static let handleVisibilityThreshold: CGFloat = 40
    /// 选区最小边长（1 像素也要能截）
    public static let minSize: CGFloat = 1

    /// 命中的手柄（点在选区边/角附近才算）
    public static func edge(atLocal point: CGPoint, in rect: CGRect, tolerance: CGFloat = handleHitTolerance) -> SelectionEdge? {
        // 必须先接近选区，再判方位：否则全屏都会变成「手柄区」
        let expanded = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard expanded.contains(point) else { return nil }

        let nearLeft = abs(point.x - rect.minX) <= tolerance
        let nearRight = abs(point.x - rect.maxX) <= tolerance
        let nearTop = abs(point.y - rect.minY) <= tolerance
        let nearBottom = abs(point.y - rect.maxY) <= tolerance
        guard nearLeft || nearRight || nearTop || nearBottom else { return nil }

        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    /// 拖拽手柄后的新矩形（保持对边不动，受最小尺寸与边界约束）
    public static func resized(
        _ rect: CGRect,
        edge: SelectionEdge,
        to point: CGPoint,
        limit: CGRect,
        minimum: CGFloat = minSize
    ) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY

        if edge.affectsX {
            let x = min(max(point.x, limit.minX), limit.maxX)
            if edge == .left || edge == .topLeft || edge == .bottomLeft {
                minX = min(x, maxX - minimum)
            } else {
                maxX = max(x, minX + minimum)
            }
        }
        if edge.affectsY {
            let y = min(max(point.y, limit.minY), limit.maxY)
            if edge == .top || edge == .topLeft || edge == .topRight {
                minY = min(y, maxY - minimum)
            } else {
                maxY = max(y, minY + minimum)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 整体平移（夹在边界内）
    public static func moved(_ rect: CGRect, by delta: CGSize, limit: CGRect) -> CGRect {
        var x = rect.minX + delta.width
        var y = rect.minY + delta.height
        x = min(max(x, limit.minX), limit.maxX - rect.width)
        y = min(max(y, limit.minY), limit.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// 独立外源图等比缩放拖拽（锁定原图宽高比，绝不横向/纵向拉伸变形；支持任意 8 向手柄与超屏放大）
    public static func resizedAspectLocked(
        _ rect: CGRect,
        edge: SelectionEdge,
        to point: CGPoint,
        aspect: CGFloat,
        minWidth: CGFloat = 60,
        maxWidth: CGFloat = 6000
    ) -> CGRect {
        let safeAspect = max(0.01, aspect)
        let clampedMinW = max(20, minWidth)
        let clampedMaxW = max(clampedMinW, maxWidth)

        var targetW: CGFloat
        switch edge {
        case .left:
            targetW = rect.maxX - point.x
        case .right:
            targetW = point.x - rect.minX
        case .top:
            targetW = (rect.maxY - point.y) * safeAspect
        case .bottom:
            targetW = (point.y - rect.minY) * safeAspect
        case .topLeft:
            let wFromX = rect.maxX - point.x
            let wFromY = (rect.maxY - point.y) * safeAspect
            targetW = abs(wFromX - rect.width) >= abs(wFromY - rect.width) ? wFromX : wFromY
        case .topRight:
            let wFromX = point.x - rect.minX
            let wFromY = (rect.maxY - point.y) * safeAspect
            targetW = abs(wFromX - rect.width) >= abs(wFromY - rect.width) ? wFromX : wFromY
        case .bottomLeft:
            let wFromX = rect.maxX - point.x
            let wFromY = (point.y - rect.minY) * safeAspect
            targetW = abs(wFromX - rect.width) >= abs(wFromY - rect.width) ? wFromX : wFromY
        case .bottomRight:
            let wFromX = point.x - rect.minX
            let wFromY = (point.y - rect.minY) * safeAspect
            targetW = abs(wFromX - rect.width) >= abs(wFromY - rect.width) ? wFromX : wFromY
        }

        targetW = min(max(targetW, clampedMinW), clampedMaxW)
        let targetH = targetW / safeAspect

        let originX: CGFloat
        let originY: CGFloat
        switch edge {
        case .left:
            originX = rect.maxX - targetW
            originY = rect.midY - targetH / 2
        case .right:
            originX = rect.minX
            originY = rect.midY - targetH / 2
        case .top:
            originX = rect.midX - targetW / 2
            originY = rect.maxY - targetH
        case .bottom:
            originX = rect.midX - targetW / 2
            originY = rect.minY
        case .topLeft:
            originX = rect.maxX - targetW
            originY = rect.maxY - targetH
        case .topRight:
            originX = rect.minX
            originY = rect.maxY - targetH
        case .bottomLeft:
            originX = rect.maxX - targetW
            originY = rect.minY
        case .bottomRight:
            originX = rect.minX
            originY = rect.minY
        }
        return CGRect(x: originX, y: originY, width: targetW, height: targetH)
    }

    /// 放大超屏时的平滑拖拽平移（允许图超出屏幕上下/左右边界，只保证至少保留 minVisible 可见）
    public static func movedPartiallyVisible(
        _ rect: CGRect,
        by delta: CGSize,
        in bounds: CGRect,
        minVisible: CGFloat = 80
    ) -> CGRect {
        let visX = min(minVisible, rect.width)
        let visY = min(minVisible, rect.height)
        let minX = bounds.minX + visX - rect.width
        let maxX = bounds.maxX - visX
        let minY = bounds.minY + visY - rect.height
        let maxY = bounds.maxY - visY
        let x = min(max(rect.minX + delta.width, minX), maxX)
        let y = min(max(rect.minY + delta.height, minY), maxY)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// 键盘微调（dx/dy 为本地 Y 向下方向）
    public static func nudged(_ rect: CGRect, dx: CGFloat, dy: CGFloat, limit: CGRect) -> CGRect {
        moved(rect, by: CGSize(width: dx, height: dy), limit: limit)
    }

    /// 选区变化后，标注在**旧本地坐标 → 新本地坐标**的平移量
    ///
    /// 本地坐标原点在选区左上（Y 向下）。要让标注「钉在图像上」：
    /// dx = old.minX - new.minX，dy = 新矩形的高度变化带来的顶边位移。
    /// 用全局坐标表达更直观：dxGlobal = new.minX - old.minX（右移为负），
    /// 但这里两端都传本地 rect，调用方保证同坐标系。
    public static func annotationOffset(old: CGRect, new: CGRect) -> CGSize {
        CGSize(width: old.minX - new.minX, height: old.minY - new.minY)
    }
}
