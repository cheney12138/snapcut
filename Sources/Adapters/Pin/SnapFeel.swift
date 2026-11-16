import AppKit
import QuartzCore

/// 磁吸手感（任务 B「再做顺滑一点」）：落位缓动 + 分离阻力 + 重吸防抖。
///
/// 参数（用户裁定 + 实现推演，全部集中在此便于实机调参）：
/// - 落位缓动 100ms ease-out（80–120ms 带中值）：吸附「啪嗒」变「嗒~」
/// - 分离回滑 100ms ease-out：46px 硬阈值断开不再瞬间跳回
/// - 阻力带 24px：release 46 前 24px 区间跟随比 1:1 → 0.6:1 线性渐变
/// - 重吸防抖 200ms：刚分离后 200ms 内同伙伴同边不再吸附（防抖动）
enum SnapFeel {
    /// 吸附落位缓动时长（80–120ms 带中值）
    static let landingDuration: TimeInterval = 0.10
    /// 分离回滑缓动时长（消除硬跳回）
    static let releaseDuration: TimeInterval = 0.10
    /// 分离阻力带宽度：releaseDistance 前 24px 区间开始衰减（1:1 → 0.6:1）
    static let resistBand: CGFloat = 24
    /// 阻力带末端跟随比（0.6:1）
    static let maxFollowRatio: CGFloat = 0.6
    /// 分离后同伙伴同边重吸防抖窗口
    static let resnapDebounce: TimeInterval = 0.2

    /// 分离阻力位移量（CGSize）：吸附态拖出方向与吸附边相反时，位置从全钉死
    /// 渐变为 0.6:1 跟随（线性 ramp 0 → 0.6，跨 24px 阻力带）。
    /// - Parameters:
    ///   - candidate: 自由位置外框（外框空间）
    ///   - outcome: 当前吸附结果（贴合位外框）
    static func resistOffset(candidate: CGRect, outcome: MagnetSnapOutcome) -> CGSize {
        let snap = outcome.frame
        let alongX: Bool
        // d = 沿吸附边法线的带符号拖出距离（正 = 远离贴合点）
        let d: CGFloat
        switch outcome.edge {
        case .right:  alongX = true;  d = candidate.maxX - snap.maxX // 移动盒贴对方右侧，拖出 = 向右拉
        case .left:   alongX = true;  d = candidate.minX - snap.minX
        case .top:    alongX = false; d = candidate.maxY - snap.maxY // 全局 Y-up，「上」= maxY 侧
        case .bottom: alongX = false; d = candidate.minY - snap.minY
        }
        let pull = abs(d)
        let zoneStart = MagnetGroup.releaseDistance - resistBand
        guard pull > zoneStart else { return .zero }
        let progress = min((pull - zoneStart) / resistBand, 1)
        let ratio = maxFollowRatio * progress   // 0 → 0.6 渐变
        let offset = (pull - zoneStart) * ratio * (d < 0 ? -1 : 1)
        return alongX ? CGSize(width: offset, height: 0) : CGSize(width: 0, height: offset)
    }
}

/// 分离后重吸防抖：刚分离（snapped → free）后 resnapDebounce 窗口内，
/// 同伙伴同边的吸附判定作废（防「分离→回弹→再吸」抖动循环）。
struct SnapResnapGuard {
    private var lastRelease: (partnerID: String, edge: MagnetEdge, at: TimeInterval)?

    /// 分离瞬间记录（在 dragMoved 的无吸附分支调用）
    mutating func noteRelease(partnerID: String, edge: MagnetEdge, now: TimeInterval) {
        lastRelease = (partnerID, edge, now)
    }

    /// 吸附判定结果是否应作废（同伙伴同边 + 窗口期内）
    mutating func shouldSuppress(partnerID: String, edge: MagnetEdge, now: TimeInterval) -> Bool {
        if let last = lastRelease,
           last.partnerID == partnerID, last.edge == edge,
           now - last.at < SnapFeel.resnapDebounce {
            return true
        }
        lastRelease = nil   // 窗口外/不同边 → 记录作废
        return false
    }
}

/// 吸附落位/分离缓动器：主线程逐帧拖动模型下的轻量插值。
///
/// - 进入吸附（或吸附目标/边变化）：从上一渲染位 ease-out 滑向贴合位（landingDuration）
/// - 分离（吸附帧 → 自由帧）：从上一渲染位 ease-out 回滑到自由位（releaseDuration），
///   消除 46px 磁滞断开瞬间的硬跳回
/// - 稳态吸附帧 / 稳态自由帧：1:1 硬跟随（无滞后；缓动只在状态切换时介入）
struct SnapEaser {
    private var animFrom: CGPoint?
    private var animT0: TimeInterval = 0
    private var animDuration: TimeInterval = SnapFeel.landingDuration
    private var lastRendered: CGPoint?
    private var wasSnapped = false

    /// 吸附帧：target = 本帧贴合位渲染目标（含阻力位移）；newSnap = 吸附刚建立或目标/边变化
    mutating func snapFrame(target: CGPoint, newSnap: Bool, now: TimeInterval) -> CGPoint {
        if newSnap, let last = lastRendered {
            animFrom = last
            animT0 = now
            animDuration = SnapFeel.landingDuration
        }
        wasSnapped = true
        return glide(to: target, now: now)
    }

    /// 自由帧：target = 本帧自由跟随位；吸附→分离的过渡帧自动启动回滑缓动
    mutating func freeFrame(target: CGPoint, now: TimeInterval) -> CGPoint {
        let released = wasSnapped
        wasSnapped = false
        if released, let last = lastRendered {
            animFrom = last
            animT0 = now
            animDuration = SnapFeel.releaseDuration
        }
        return glide(to: target, now: now)
    }

    private mutating func glide(to target: CGPoint, now: TimeInterval) -> CGPoint {
        guard let from = animFrom else {
            lastRendered = target
            return target
        }
        let p = (now - animT0) / animDuration
        guard p < 1 else {
            animFrom = nil
            lastRendered = target
            return target
        }
        let eased = 1 - pow(1 - p, 3)   // ease-out cubic
        let rendered = CGPoint(
            x: from.x + (target.x - from.x) * eased,
            y: from.y + (target.y - from.y) * eased
        )
        lastRendered = rendered
        return rendered
    }
}
