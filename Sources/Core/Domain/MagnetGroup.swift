import CoreGraphics
import Foundation

/// 磁吸几何（纯 Core，零 AppKit 纪律）：松手吸附 + 柔和对齐参考线 + 自然脱离判定。
///
/// 坐标约定：AppKit 全局 points（Y-up）。「top / bottom」指视觉上下边
/// （top = maxY；bottom = minY）。
///
/// 交互哲学（用户裁定 2026-11-20）：
/// - 拖动过程 100% 1:1 自由跟随光标（零磁滞、零阻力死区、绝不中途劫持卡片位置）；
/// - 进入吸附区间时仅展示视觉预览（鬼影落位框 + 柔和对齐参考线），松手才顺滑落位成组；
/// - 柔和对齐（类似桌面图标整理）：仅当边/中心线本就接近（≤16pt）时轻柔对齐，用户刻意上下/左右错开时绝不强行拉齐；
/// - 若用户刻意把卡片推入对方内部重叠（超越内阈）则预览自动消失，允许自由叠放对比。
public enum MagnetEdge: String, Sendable {
    /// 移动盒左缘贴到对方右侧（移动盒在对方右边）
    case left
    /// 移动盒右缘贴到对方左侧（移动盒在对方左边）
    case right
    /// 移动盒上缘贴到对方下缘（Y-up 下移动盒在对方视觉下方）
    case top
    /// 移动盒下缘贴到对方上缘（Y-up 下移动盒在对方视觉上方）
    case bottom
}

/// 软对齐类型（横向贴合对齐上/下/中线；纵向贴合对齐左/右/中线）
public enum MagnetAlignKind: String, Sendable, Equatable {
    case top
    case bottom
    case centerY
    case left
    case right
    case centerX
}

/// 参考线线段（全局 Y-up points）
public struct MagnetGuideLine: Sendable, Equatable {
    public let start: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }
}

/// 磁吸候选（id 由注册表分配，进程内唯一即可；frame 为贴图真实内容框）
public struct MagnetSnapItem: Sendable {
    public let id: String
    public let frame: CGRect
    public init(id: String, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// 吸附预览与松手落位结果
public struct MagnetSnapOutcome: Sendable {
    /// 松手后的最终落位矩形（全局 Y-up）
    public let frame: CGRect
    public let edge: MagnetEdge
    public let partnerID: String
    /// 触发软对齐时的视觉参考线（未触发软对齐时为 nil）
    public let alignGuide: MagnetGuideLine?
    public let alignKind: MagnetAlignKind?
    /// 贴合缝隙居中引导线（视觉反馈即将成组的缝隙）
    public let seamGuide: MagnetGuideLine
}

public enum MagnetGroup {
    /// 成组后相邻卡片之间的紧凑留白（配合统一磨砂玻璃托盘）
    public static let gutter: CGFloat = 12
    /// 外侧进入吸附预览的距离阈值（距目标贴合位外侧 ≤26pt 即亮起预览）
    public static let snapZoneOuter: CGFloat = 26
    /// 内侧容忍阈值（推入超过目标贴合位内侧 16pt，即开始显著重叠 >4pt 时自动撤掉预览，允许自由重叠）
    public static let snapZoneInner: CGFloat = 16
    /// 软对齐触发阈值（边或中线距对方 ≤16pt 时柔吸对齐；超出则尊重用户错位）
    public static let softAlignThreshold: CGFloat = 16
    /// 主轴贴合所需的最小垂直投影重叠（避免斜对角远距离误触发）
    public static let minOverlap: CGFloat = 12
    /// 组内单卡直拖松手后，距所有剩余同伴边缘间距大于此值则自然脱离组
    public static let detachDistance: CGFloat = 44

    /// 多个矩形的轴对齐包围盒（组 union rect）
    public static func unionRect(_ rects: [CGRect]) -> CGRect {
        guard var result = rects.first else { return .zero }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }

    /// 评估松手吸附预览（无磁滞、无阻力死区，纯几何评估）。
    public static func previewSnap(
        candidate: CGRect,
        others: [MagnetSnapItem]
    ) -> MagnetSnapOutcome? {
        var best: (outcome: MagnetSnapOutcome, score: CGFloat)?

        for other in others {
            let o = other.frame

            // 四个贴合方向：outward > 0 表示在目标贴合位外侧，outward < 0 表示往对方方向推近
            let candidates: [(edge: MagnetEdge, outward: CGFloat, delta: CGFloat, axis: Axis)] = [
                (.right, (o.minX - gutter) - candidate.maxX, (o.minX - gutter) - candidate.maxX, .x),
                (.left, candidate.minX - (o.maxX + gutter), (o.maxX + gutter) - candidate.minX, .x),
                (.top, (o.minY - gutter) - candidate.maxY, (o.minY - gutter) - candidate.maxY, .y),
                (.bottom, candidate.minY - (o.maxY + gutter), (o.maxY + gutter) - candidate.minY, .y),
            ]

            for cand in candidates {
                guard cand.outward >= -snapZoneInner, cand.outward <= snapZoneOuter else { continue }

                var frame = candidate
                if cand.axis == .x {
                    frame.origin.x += cand.delta
                } else {
                    frame.origin.y += cand.delta
                }

                guard let alignment = evaluatePerpendicularAndAlign(
                    candidate: frame, other: o, axis: cand.axis
                ) else { continue }

                if cand.axis == .x {
                    frame.origin.y += alignment.shift
                } else {
                    frame.origin.x += alignment.shift
                }

                let alignGuide = makeAlignGuide(
                    landing: frame, other: o, kind: alignment.kind
                )
                let seamGuide = makeSeamGuide(
                    landing: frame, other: o, edge: cand.edge
                )

                // 距离越近优先级越高；触发了边/中线软对齐略微加分（2pt）
                let score = abs(cand.outward) - (alignment.kind != nil ? 2.0 : 0.0)
                if best == nil || score < best!.score {
                    best = (
                        MagnetSnapOutcome(
                            frame: frame,
                            edge: cand.edge,
                            partnerID: other.id,
                            alignGuide: alignGuide,
                            alignKind: alignment.kind,
                            seamGuide: seamGuide
                        ),
                        score
                    )
                }
            }
        }
        return best?.outcome
    }

    /// 兼容入口：保留旧签名便于测试与平滑迁移
    public static func snap(
        candidate: CGRect,
        others: [MagnetSnapItem],
        active: (partnerID: String, edge: MagnetEdge)? = nil
    ) -> MagnetSnapOutcome? {
        _ = active
        return previewSnap(candidate: candidate, others: others)
    }

    /// 脱离判定：单卡自由拖放后，若与剩余同组成员的最小边缘距离 > threshold，则自然移出拼贴组
    public static func shouldDetach(
        cardFrame: CGRect,
        otherFrames: [CGRect],
        threshold: CGFloat = detachDistance
    ) -> Bool {
        guard !otherFrames.isEmpty else { return true }
        var minDist = CGFloat.greatestFiniteMagnitude
        for other in otherFrames {
            let dx = max(0, max(other.minX - cardFrame.maxX, cardFrame.minX - other.maxX))
            let dy = max(0, max(other.minY - cardFrame.maxY, cardFrame.minY - other.maxY))
            let d = hypot(dx, dy)
            if d < minDist { minDist = d }
        }
        return minDist > threshold
    }

    // MARK: - 内部几何辅助

    private enum Axis { case x, y }

    private struct AlignResult {
        let shift: CGFloat
        let kind: MagnetAlignKind?
    }

    /// 校验垂直投影重叠，并在边/中线自然接近（≤softAlignThreshold）时提供柔和对齐
    private static func evaluatePerpendicularAndAlign(
        candidate: CGRect, other: CGRect, axis: Axis
    ) -> AlignResult? {
        if axis == .x {
            let overlap = min(candidate.maxY, other.maxY) - max(candidate.minY, other.minY)
            // 允许边轻微错开 8pt 内也能识别到边对齐，彻底远离则不误吸
            guard overlap >= -8 else { return nil }

            let options: [(kind: MagnetAlignKind, shift: CGFloat)] = [
                (.top, other.maxY - candidate.maxY),
                (.bottom, other.minY - candidate.minY),
                (.centerY, other.midY - candidate.midY),
            ]
            if let nearest = options.min(by: { abs($0.shift) < abs($1.shift) }),
               abs(nearest.shift) <= softAlignThreshold {
                return AlignResult(shift: nearest.shift, kind: nearest.kind)
            }
            guard overlap >= minOverlap else { return nil }
            return AlignResult(shift: 0, kind: nil)
        } else {
            let overlap = min(candidate.maxX, other.maxX) - max(candidate.minX, other.minX)
            guard overlap >= -8 else { return nil }

            let options: [(kind: MagnetAlignKind, shift: CGFloat)] = [
                (.left, other.minX - candidate.minX),
                (.right, other.maxX - candidate.maxX),
                (.centerX, other.midX - candidate.midX),
            ]
            if let nearest = options.min(by: { abs($0.shift) < abs($1.shift) }),
               abs(nearest.shift) <= softAlignThreshold {
                return AlignResult(shift: nearest.shift, kind: nearest.kind)
            }
            guard overlap >= minOverlap else { return nil }
            return AlignResult(shift: 0, kind: nil)
        }
    }

    private static func makeAlignGuide(
        landing: CGRect, other: CGRect, kind: MagnetAlignKind?
    ) -> MagnetGuideLine? {
        guard let kind else { return nil }
        let extend: CGFloat = 10
        switch kind {
        case .top:
            let y = other.maxY
            return MagnetGuideLine(
                start: CGPoint(x: min(landing.minX, other.minX) - extend, y: y),
                end: CGPoint(x: max(landing.maxX, other.maxX) + extend, y: y)
            )
        case .bottom:
            let y = other.minY
            return MagnetGuideLine(
                start: CGPoint(x: min(landing.minX, other.minX) - extend, y: y),
                end: CGPoint(x: max(landing.maxX, other.maxX) + extend, y: y)
            )
        case .centerY:
            let y = other.midY
            return MagnetGuideLine(
                start: CGPoint(x: min(landing.minX, other.minX) - extend, y: y),
                end: CGPoint(x: max(landing.maxX, other.maxX) + extend, y: y)
            )
        case .left:
            let x = other.minX
            return MagnetGuideLine(
                start: CGPoint(x: x, y: min(landing.minY, other.minY) - extend),
                end: CGPoint(x: x, y: max(landing.maxY, other.maxY) + extend)
            )
        case .right:
            let x = other.maxX
            return MagnetGuideLine(
                start: CGPoint(x: x, y: min(landing.minY, other.minY) - extend),
                end: CGPoint(x: x, y: max(landing.maxY, other.maxY) + extend)
            )
        case .centerX:
            let x = other.midX
            return MagnetGuideLine(
                start: CGPoint(x: x, y: min(landing.minY, other.minY) - extend),
                end: CGPoint(x: x, y: max(landing.maxY, other.maxY) + extend)
            )
        }
    }

    private static func makeSeamGuide(
        landing: CGRect, other: CGRect, edge: MagnetEdge
    ) -> MagnetGuideLine {
        switch edge {
        case .right:
            let x = (landing.maxX + other.minX) / 2
            let lo = max(landing.minY, other.minY) + 4
            let hi = min(landing.maxY, other.maxY) - 4
            let y1 = min(lo, hi), y2 = max(lo, hi)
            return MagnetGuideLine(start: CGPoint(x: x, y: y1), end: CGPoint(x: x, y: y2))
        case .left:
            let x = (other.maxX + landing.minX) / 2
            let lo = max(landing.minY, other.minY) + 4
            let hi = min(landing.maxY, other.maxY) - 4
            let y1 = min(lo, hi), y2 = max(lo, hi)
            return MagnetGuideLine(start: CGPoint(x: x, y: y1), end: CGPoint(x: x, y: y2))
        case .top:
            let y = (landing.maxY + other.minY) / 2
            let lo = max(landing.minX, other.minX) + 4
            let hi = min(landing.maxX, other.maxX) - 4
            let x1 = min(lo, hi), x2 = max(lo, hi)
            return MagnetGuideLine(start: CGPoint(x: x1, y: y), end: CGPoint(x: x2, y: y))
        case .bottom:
            let y = (other.maxY + landing.minY) / 2
            let lo = max(landing.minX, other.minX) + 4
            let hi = min(landing.maxX, other.maxX) - 4
            let x1 = min(lo, hi), x2 = max(lo, hi)
            return MagnetGuideLine(start: CGPoint(x: x1, y: y), end: CGPoint(x: x2, y: y))
        }
    }
}
