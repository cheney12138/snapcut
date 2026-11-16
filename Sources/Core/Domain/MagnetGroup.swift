import CoreGraphics
import Foundation

/// 磁吸几何（纯 Core，零 AppKit 纪律；HTML 原型 snapcut-collage 的数学移植）
///
/// 坐标约定：AppKit 全局 points（Y-up）。「top / bottom」指视觉上下边
/// （top = y 大的一侧 = maxY；bottom = minY）。重叠/间距判定对 Y 方向对称，
/// Y-up / Y-down 皆成立。
///
/// 三参数（原型 CSS 变量同源）：
/// - gutter 16：贴合后两外框之间的间距
/// - snap 14：吸附触发阈值
/// - release 46：磁滞分离阈值（已吸住要拖更远才断开）
///
/// 外框空间约定：调用方（PinMagnetRegistry）保证传入的都是「外框」矩形——
/// 成组 pin 的窗体 frame 已含 8pt 白垫 + 1px 描边；未成组 pin 用
/// frame 外扩 9pt 的虚拟外框。这样成组（垫出现）前后几何不跳变。
public enum MagnetEdge: String, Sendable {
    /// 移动盒左缘贴到对方右侧（对方右外侧）
    case left
    /// 移动盒右缘贴到对方左侧（对方左外侧）
    case right
    /// 移动盒上缘贴到对方上方
    case top
    /// 移动盒下缘贴到对方下方
    case bottom
}

/// 磁吸候选（id 由注册表分配，进程内唯一即可）
public struct MagnetSnapItem: Sendable {
    public let id: String
    public let frame: CGRect
    public init(id: String, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// 吸附结果：吸附后的移动外框 + 贴合边 + 目标 id
public struct MagnetSnapOutcome: Sendable {
    public let frame: CGRect
    public let edge: MagnetEdge
    public let partnerID: String
}

public enum MagnetGroup {
    public static let gutter: CGFloat = 16
    public static let snapDistance: CGFloat = 14
    // 28（用户裁定 2026-11-16「吸附之后扯不开，不丝滑，期望像乐高」：
    // 46px 磁滞 + 0.6:1 阻力带让卡片 46px 内最多只挪 14px——视觉钉死。
    // 乐高语义 = 轻拉即开：release 收到 28，阻力带 10px、0.85:1）
    public static let releaseDistance: CGFloat = 28
    /// 贴边才有意义：投影重叠不足此值时进入「角吸附」分支（原型 overlap1 > 8；
    /// 病例：斜 45° 靠近时两轴投影都不重叠 → 永不吸附，补角吸附对齐）
    public static let minOverlap: CGFloat = 8

    /// 多个矩形的轴对齐包围盒（组 union rect）
    public static func unionRect(_ rects: [CGRect]) -> CGRect {
        guard var result = rects.first else { return .zero }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }

    /// 磁滞吸附判定（原型 magnetics() 移植）
    ///
    /// - Parameter candidate: 移动盒外框（自由移动后的位置）
    /// - Parameter others: 候选目标（不含移动盒自身/同拖集合）
    /// - Parameter active: 当前已吸附状态（磁滞：同一目标同一边用 release 阈值）
    /// - Returns: nil = 无吸附（自由位）；非 nil = 应用返回 frame
    public static func snap(
        candidate: CGRect,
        others: [MagnetSnapItem],
        active: (partnerID: String, edge: MagnetEdge)? = nil
    ) -> MagnetSnapOutcome? {
        var best: (outcome: MagnetSnapOutcome, d: CGFloat)?

        for other in others {
            let o = other.frame

            // 四个候选边（delta = 主轴需平移量；正 = 沿正方向移）：
            // .right ：c.maxX = o.minX - gutter（移动盒贴对方左侧）
            // .left  ：c.minX = o.maxX + gutter（移动盒贴对方右侧）
            // .top   ：c.maxY = o.minY - gutter（移动盒贴对方上方）
            // .bottom：c.minY = o.maxY + gutter（移动盒贴对方下方）
            let candidates: [(edge: MagnetEdge, delta: CGFloat, axis: Axis)] = [
                (.right, (o.minX - gutter) - candidate.maxX, .x),
                (.left, (o.maxX + gutter) - candidate.minX, .x),
                (.top, (o.minY - gutter) - candidate.maxY, .y),
                (.bottom, (o.maxY + gutter) - candidate.minY, .y),
            ]

            for cand in candidates {
                let d = abs(cand.delta)
                let isSameSnap = active?.partnerID == other.id && active?.edge == cand.edge
                // 磁滞：已吸附在同一目标上 → 用 release 阈值
                let threshold = isSameSnap ? releaseDistance : snapDistance
                guard d < threshold else { continue }

                // 垂直方向（另一轴）投影重叠判定 + 角吸附
                let perpShift = perpendicularAdjust(candidate: candidate, other: o, axis: cand.axis)
                guard let perpShift else { continue }

                if best == nil || d < best!.d {
                    var frame = candidate
                    if cand.axis == .x {
                        frame.origin.x += cand.delta
                        frame.origin.y += perpShift
                    } else {
                        frame.origin.y += cand.delta
                        frame.origin.x += perpShift
                    }
                    best = (
                        MagnetSnapOutcome(frame: frame, edge: cand.edge, partnerID: other.id),
                        d
                    )
                }
            }
        }
        return best?.outcome
    }

    private enum Axis { case x, y }

    /// 垂直轴调整量：
    /// - 投影重叠 ≥ minOverlap → 0（正贴边）
    /// - 重叠不足但间距 < snap → 角吸附：贴到对方最近边（对齐到角，留 gutter）
    /// - 间距太远 → nil（该候选作废）
    private static func perpendicularAdjust(
        candidate: CGRect, other: CGRect, axis: Axis
    ) -> CGFloat? {
        let overlap: CGFloat
        let alignToNear: () -> CGFloat
        let gap: CGFloat

        if axis == .x {
            // 垂直方向 = y：重叠量 / 间距 / 上下对齐
            overlap = min(candidate.maxY, other.maxY) - max(candidate.minY, other.minY)
            gap = max(other.minY - candidate.maxY, candidate.minY - other.maxY)
            let above = (other.minY - gutter) - candidate.maxY   // 移动盒对齐到对方上方
            let below = (other.maxY + gutter) - candidate.minY   // 对齐到对方下方
            alignToNear = { abs(above) <= abs(below) ? above : below }
        } else {
            overlap = min(candidate.maxX, other.maxX) - max(candidate.minX, other.minX)
            gap = max(other.minX - candidate.maxX, candidate.minX - other.maxX)
            let before = (other.minX - gutter) - candidate.maxX  // 移动盒对齐到对方左侧
            let after = (other.maxX + gutter) - candidate.minX   // 对齐到对方右侧
            alignToNear = { abs(before) <= abs(after) ? before : after }
        }

        if overlap >= minOverlap { return 0 }
        guard gap < snapDistance else { return nil }
        return alignToNear()
    }
}
