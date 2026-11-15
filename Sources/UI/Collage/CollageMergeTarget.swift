import CoreGraphics

/// C3（Pin 手势）⇄ C2（拼贴画布）合并接口约定（docs/06 §3 操作路径的唯一入口）
///
/// C3 侧只认本协议：右键「合并到拼贴…」/ ⌥拖合并 / drop target 都把 CGImage
/// 交给 target，不直接触碰 CollageDocument / SnapGeometry（那是 C2 的领地）。
/// C2 的 CollageWindowController 需遵循本协议，并在创建时写入
/// AppCoordinatorShared.collageTarget（主会话接线；关闭时置 nil）。
///
/// 落位语义（C2 实现 acceptPiece 时遵守）：
/// - 坐标 `at` 为屏幕全局点（AppKit Y-up），nil = 自动排位
///   （SnapGeometry.nextGridSlot 光栅填充，⌘⇧A 连续入画布同款）。
/// - 连续两次 acceptPiece（⌥拖成组 / drop 合并的调用顺序 = 目标图先、
///   拖动图后）即自然形成相邻两贴片（nextGridSlot 依次放位）。
/// - imageRef：C2 内部为 CGImage 分配字符串键存图像缓存，
///   CollagePiece.imageRef 按键查缓存（C1 接口约定，C3 不感知）。
@MainActor
protocol CollageMergeTarget: AnyObject {
    /// 接收一张图进拼贴画布；`at` 为屏幕全局点（可选），nil = 自动 nextGridSlot
    func acceptPiece(image: CGImage, at: CGPoint?)
}
