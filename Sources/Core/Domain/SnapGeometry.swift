import CoreGraphics

/// 分镜格吸附结果（docs/06 §2 用户裁定：吸附目标 = 格位（带 gutter 间隙），
/// 不是零距离贴合——无缝贴片不可读，漫画分镜式间隙让多图结构一眼可辨）
///
/// - `none`：阈值内没有吸附目标，保持自由位置
/// - `horizontal`：只命中水平方向的格位（垂直方向自由），y 为间隙中线引导线
/// - `vertical`：只命中垂直方向的格位（水平方向自由），x 为间隙中线引导线
/// - `gridSlot`：两个方向同时命中——完整格位，rect 即贴片落位后的目标框
///   （吸附预览虚线框直接画它）
/// 每个非 none 情形都携带 `snapped`（吸附后的贴片 frame），UI 落位直接用，
/// 不必自己再算一遍偏移。
public enum SnapResult: Equatable, Sendable {
    case none
    case horizontal(y: CGFloat, snapped: CGRect)
    case vertical(x: CGFloat, snapped: CGRect)
    case gridSlot(rect: CGRect)
}

/// 分镜格吸附纯几何（领域层，无 AppKit；SelectionGeometry 同款风格）
///
/// 坐标系约定：所有 rect/point 都是**画布本地坐标、Y 向下**
/// （与 CollageDocument.piece.frame、AnnotationModel 一致）。
public enum SnapGeometry {
    /// 边对边吸附触发距离（逻辑点）：拖动中贴片与格位的间隙偏差小于它才吸附
    public static let snapDistance: CGFloat = 24
    /// 分镜格默认间隙（用户裁定 2026-11-15）
    public static let defaultGutter: CGFloat = 16

    /// 计算拖动中的贴片对其它贴片的吸附目标
    ///
    /// 规则：候选格位是「贴片某条边与相邻贴片对应边之间隔一个 gutter」的位置
    /// （左/右/上/下四向）。每个轴取偏差最近且 < snapDistance 的候选；
    /// 两轴同时命中 → 完整格位（优先级最高），单轴命中 → 引导线，
    /// 都没命中 → .none。
    ///
    /// - Parameters:
    ///   - piece: 拖动中的贴片当前 frame（画布坐标）
    ///   - pieces: 其它贴片的 frame（不包含被拖动的那一片）
    ///   - gutter: 分镜间隙
    public static func snapTarget(
        for piece: CGRect,
        in pieces: [CGRect],
        gutter: CGFloat = defaultGutter
    ) -> SnapResult {
        guard !pieces.isEmpty else { return .none }

        // X 轴候选：贴片左缘贴到其它贴片右缘 + gutter（右侧邻位），
        // 或贴片右缘贴到其它贴片左缘 - gutter（左侧邻位）
        var bestX: (offset: CGFloat, x: CGFloat, guide: CGFloat)?
        // Y 轴候选同构
        var bestY: (offset: CGFloat, y: CGFloat, guide: CGFloat)?

        for other in pieces {
            // 右侧邻位：贴片 minX = other.maxX + gutter
            considerX(piece, candidateX: other.maxX + gutter, gapEdge: other.maxX, gutter: gutter, best: &bestX)
            // 左侧邻位：贴片 maxX = other.minX - gutter
            considerX(piece, candidateX: other.minX - gutter - piece.width, gapEdge: other.minX, gutter: gutter, best: &bestX)
            // 下方邻位：贴片 minY = other.maxY + gutter
            considerY(piece, candidateY: other.maxY + gutter, gapEdge: other.maxY, gutter: gutter, best: &bestY)
            // 上方邻位：贴片 maxY = other.minY - gutter
            considerY(piece, candidateY: other.minY - gutter - piece.height, gapEdge: other.minY, gutter: gutter, best: &bestY)
        }

        switch (bestX, bestY) {
        case let (x?, y?):
            return .gridSlot(rect: CGRect(
                x: x.x,
                y: y.y,
                width: piece.width,
                height: piece.height
            ))
        case let (x?, nil):
            let rect = CGRect(x: x.x, y: piece.minY, width: piece.width, height: piece.height)
            return .vertical(x: x.guide, snapped: rect)
        case let (nil, y?):
            let rect = CGRect(x: piece.minX, y: y.y, width: piece.width, height: piece.height)
            return .horizontal(y: y.guide, snapped: rect)
        default:
            return .none
        }
    }

    /// 自动找「下一格」位置（从左上开始的光栅填充）：
    /// ⌘⇧A 连续截图自动入画布用——新贴片落在现有排布的下一个空位。
    ///
    /// 算法：候选位置 = 现有内容 bounding box 左上 + 每个已占格的
    /// 「右侧邻位 / 下方邻位」；按 y 再 x 排序（光栅顺序），返回第一个
    /// 与所有已占格（外扩 gutter 作缓冲）都不相交的候选。
    /// 找不到（理论不发生，候选足够多）则兜底放 bounding box 正下方。
    ///
    /// 坐标系：返回值与 occupied 同坐标系；occupied 为空时返回 .zero。
    public static func nextGridSlot(
        occupied: [CGRect],
        pieceSize: CGSize,
        gutter: CGFloat = defaultGutter
    ) -> CGPoint {
        guard let first = occupied.first else { return .zero }

        let bounds = occupied.reduce(first) { $0.union($1) }
        var candidates: [CGPoint] = [CGPoint(x: bounds.minX, y: bounds.minY)]
        for rect in occupied {
            candidates.append(CGPoint(x: rect.maxX + gutter, y: rect.minY))
            candidates.append(CGPoint(x: rect.minX, y: rect.maxY + gutter))
        }
        candidates.sort { lhs, rhs in
            lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x
        }

        // 已占格外扩 gutter → 新格与旧格之间保证有完整间隙
        let buffered = occupied.map { $0.insetBy(dx: -gutter, dy: -gutter) }
        for candidate in candidates {
            let frame = CGRect(origin: candidate, size: pieceSize)
            if !buffered.contains(where: { $0.intersects(frame) }) {
                return candidate
            }
        }
        return CGPoint(x: bounds.minX, y: bounds.maxY + gutter)
    }

    // MARK: - 私有

    private static func considerX(
        _ piece: CGRect,
        candidateX: CGFloat,
        gapEdge: CGFloat,
        gutter: CGFloat,
        best: inout (offset: CGFloat, x: CGFloat, guide: CGFloat)?
    ) {
        let offset = candidateX - piece.minX
        guard abs(offset) < snapDistance else { return }
        // 间隙中线引导线：画在两片之间的 gutter 正中，视觉上「这一格留给你」
        let toRight = candidateX > gapEdge
        let guide = toRight ? gapEdge + gutter / 2 : gapEdge - gutter / 2
        if best == nil || abs(offset) < abs(best!.offset) {
            best = (offset, candidateX, guide)
        }
    }

    private static func considerY(
        _ piece: CGRect,
        candidateY: CGFloat,
        gapEdge: CGFloat,
        gutter: CGFloat,
        best: inout (offset: CGFloat, y: CGFloat, guide: CGFloat)?
    ) {
        let offset = candidateY - piece.minY
        guard abs(offset) < snapDistance else { return }
        let below = candidateY > gapEdge
        let guide = below ? gapEdge + gutter / 2 : gapEdge - gutter / 2
        if best == nil || abs(offset) < abs(best!.offset) {
            best = (offset, candidateY, guide)
        }
    }
}
