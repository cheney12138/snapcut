import CoreGraphics

/// 标注模型（docs/03 §6：AnnotationModel 纯数据，Codable）
///
/// 唯一真相源原则：Annotation 只存几何+样式，绘制只发生在 CGRenderer 一处；
/// 编辑器画布与导出共用同一渲染器（编辑器所见 = 导出所得）。
/// 坐标系：选区本地 point 坐标（原点选区左上，Y 向下，与 CG 一致），导出时按 scale 换算。
struct AnnotationModel: Equatable {
    enum Shape: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        case rect(CGRect)
        case text(anchor: CGPoint)      // 内容存 NSAttributedString 的字符串部分
        case mosaic(CGRect)
        case sequence(anchor: CGPoint)   // 序号：1,2,3... 自动递增
        case highlight(from: CGPoint, to: CGPoint) // 高亮笔（半透明粗线）
    }

    var shape: Shape
    var colorIndex: Int   // 调色板索引（功能先行：0 红 1 蓝 2 黄 3 黑 4 白）
    var strokeWidth: CGFloat  // 连续 2-6pt（滑杆无极调节；绘制端 width = max(1.5, strokeWidth)）
    var text: String?     // text shape 专用
    var index: Int?       // sequence shape 专用
    var fontSize: CGFloat = 14  // text shape 专用（4 档 12/14/17/21，默认 14；
                                // 带默认值 ⇒ memberwise 构造器对既有调用点保持兼容）

    /// 调色板（领域值类型，UI 负责转 NSColor/CGColor）
    static let palette: [RGBAColor] = [.red, .blue, .yellow, .black, .white]

    var color: RGBAColor { Self.palette[colorIndex % Self.palette.count] }

    /// 几何平移（选区调整时用，样式与序号不变）
    func offsetBy(dx: CGFloat, dy: CGFloat) -> AnnotationModel {
        var copy = self
        switch shape {
        case .arrow(let from, let to):
            copy.shape = .arrow(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy)
            )
        case .rect(let rect):
            copy.shape = .rect(rect.offsetBy(dx: dx, dy: dy))
        case .text(let anchor):
            copy.shape = .text(anchor: CGPoint(x: anchor.x + dx, y: anchor.y + dy))
        case .mosaic(let rect):
            copy.shape = .mosaic(rect.offsetBy(dx: dx, dy: dy))
        case .sequence(let anchor):
            copy.shape = .sequence(anchor: CGPoint(x: anchor.x + dx, y: anchor.y + dy))
        case .highlight(let from, let to):
            copy.shape = .highlight(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy)
            )
        }
        return copy
    }
}

/// 标注存储：有序列表 + undo/redo 栈（R8：只走 Cmd+Z / Cmd+Shift+Z，无双轨）
@MainActor
final class AnnotationStore {
    private(set) var annotations: [AnnotationModel] = []
    private var undoStack: [[AnnotationModel]] = []
    private var redoStack: [[AnnotationModel]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 序号工具的下一个值（Snow Shot 同款「派生」语义）
    ///
    /// ⚠️ 不是自增计数器：旧实现 mouseDown 时 nextSequence += 1，撤销不回退 ⇒
    /// 撤销后下一个序号跳号（用户实报「序号也有问题」）。改为从当前画面上
    /// 可见的序号标注派生：最大已有序号 + 1（等价「可见序号数 + 1」，且
    /// 中间撤销时不会与既有序号撞号）。
    func nextSequenceNumber() -> Int {
        let maxExisting = annotations.compactMap { $0.index }.max() ?? 0
        return maxExisting + 1
    }

    /// 兼容旧调用点（AppCoordinator selftest 等）；语义已改为派生值（见上）
    func consumeSequenceNumber() -> Int { nextSequenceNumber() }

    func add(_ annotation: AnnotationModel) {
        pushUndo()
        annotations.append(annotation)
    }

    func undo() {
        guard canUndo else { return }
        redoStack.append(annotations)
        annotations = undoStack.removeLast()
        Log.event(.editor, "editor.undo", ["count": "\(annotations.count)"])
    }

    func redo() {
        guard canRedo else { return }
        undoStack.append(annotations)
        annotations = redoStack.removeLast()
        Log.event(.editor, "editor.redo", ["count": "\(annotations.count)"])
    }

    /// 选区调整后整体平移所有标注（保持标注"钉在图像上"）
    func offsetAll(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        pushUndo()
        annotations = annotations.map { $0.offsetBy(dx: dx, dy: dy) }
    }

    private func pushUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
        if undoStack.count > 200 { undoStack.removeFirst() }
    }
}
