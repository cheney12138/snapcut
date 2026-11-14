import AppKit
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
    var strokeWidth: Int  // 1=细 2=中 3=粗
    var text: String?     // text shape 专用
    var index: Int?       // sequence shape 专用

    static let palette: [NSColor] = [
        NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1),  // 红
        NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1),   // 蓝
        NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 1),   // 黄
        .black,
        .white,
    ]

    var color: NSColor { Self.palette[colorIndex % Self.palette.count] }
}

/// 标注存储：有序列表 + undo/redo 栈（R8：只走 Cmd+Z / Cmd+Shift+Z，无双轨）
@MainActor
final class AnnotationStore {
    private(set) var annotations: [AnnotationModel] = []
    private var undoStack: [[AnnotationModel]] = []
    private var redoStack: [[AnnotationModel]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 序号工具的下一个值（本次截图会话内连续）
    private var nextSequence = 1

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

    func consumeSequenceNumber() -> Int {
        let n = nextSequence
        nextSequence += 1
        return n
    }

    func resetSequence() { nextSequence = 1 }

    private func pushUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
        if undoStack.count > 200 { undoStack.removeFirst() }
    }
}
