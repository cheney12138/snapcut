import Foundation

/// 拼贴文档暂存端口（docs/06 §4：会话级存储，可先内存实现）
///
/// 依赖方向：画布窗口 / 导出器只认本协议，不直接碰文件系统或
/// UserDefaults；适配器负责按 id 存取 CollageDocument 值快照。
/// 文档是 Sendable 值类型，跨隔离域传递无需额外同步。
@MainActor
protocol CollageStoring {
    /// 保存（新建或整体覆盖；拼贴文档小，整文档写回最简单）
    func save(_ document: CollageDocument, id: UUID)

    /// 读取；不存在或解码失败返回 nil（调用方回退到空文档）
    func load(id: UUID) -> CollageDocument?

    /// 删除（拼贴关闭且不再恢复时调用）
    func delete(id: UUID)

    /// 当前会话内的全部文档 id（画布恢复列表用）
    func allIDs() -> [UUID]
}
