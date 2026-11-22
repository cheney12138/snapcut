import CoreGraphics
import Foundation

/// 标注模型（docs/03 §6：AnnotationModel 纯数据，Codable）
///
/// 唯一真相源原则：Annotation 只存几何+样式，绘制只发生在 CGRenderer 一处；
/// 编辑器画布与导出共用同一渲染器（编辑器所见 = 导出所得）。
/// 坐标系：选区本地 point 坐标（原点选区左上，Y 向下，与 CG 一致），导出时按 scale 换算。
public struct AnnotationModel: Equatable, Codable, Sendable {
    public enum Shape: Equatable, Codable, Sendable {
        case arrow(from: CGPoint, to: CGPoint)
        case rect(CGRect)
        case text(anchor: CGPoint)      // 内容存 NSAttributedString 的字符串部分
        case mosaic(CGRect)
        case sequence(anchor: CGPoint)   // 序号：1,2,3... 自动递增
        case highlight(from: CGPoint, to: CGPoint) // 高亮笔（半透明粗线）
        /// 椭圆/圆（center 起拖到边缘：用户裁定「圆心圈选」；rect 为外接矩形）
        case ellipse(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat)
    }

    public var shape: Shape
    public var colorIndex: Int   // 调色板索引（功能先行：0 红 1 蓝 2 黄 3 黑 4 白）
    public var strokeWidth: CGFloat  // 连续 2-6pt（滑杆无极调节；绘制端 width = max(1.5, strokeWidth)）
    public var text: String?     // text shape 专用
    public var index: Int?       // sequence shape 专用
    public var fontSize: CGFloat = 14  // text shape 专用（4 档 12/14/17/21，默认 14；
                                       // 带默认值 ⇒ 构造器对既有调用点保持兼容）
    /// 是否由「智能一键脱敏」自动生成（支持在马赛克工具下单击单独取消）
    public var isAutoRedacted: Bool = false

    public init(
        shape: Shape,
        colorIndex: Int,
        strokeWidth: CGFloat,
        text: String? = nil,
        index: Int? = nil,
        fontSize: CGFloat = 14,
        isAutoRedacted: Bool = false
    ) {
        self.shape = shape
        self.colorIndex = colorIndex
        self.strokeWidth = strokeWidth
        self.text = text
        self.index = index
        self.fontSize = fontSize
        self.isAutoRedacted = isAutoRedacted
    }

    private enum CodingKeys: String, CodingKey {
        case shape
        case colorIndex
        case strokeWidth
        case text
        case index
        case fontSize
        case isAutoRedacted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decode(Shape.self, forKey: .shape)
        colorIndex = try container.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        strokeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .strokeWidth) ?? 2
        text = try container.decodeIfPresent(String.self, forKey: .text)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        fontSize = try container.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 14
        isAutoRedacted = try container.decodeIfPresent(Bool.self, forKey: .isAutoRedacted) ?? false
    }

    /// 调色板（领域值类型，UI 负责转 NSColor/CGColor）
    public static let palette: [RGBAColor] = [.red, .blue, .yellow, .black, .white]

    public var color: RGBAColor { Self.palette[colorIndex % Self.palette.count] }

    /// 几何平移（选区调整时用，样式与序号不变）
    public func offsetBy(dx: CGFloat, dy: CGFloat) -> AnnotationModel {
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
        case .ellipse(let center, let radiusX, let radiusY):
            copy.shape = .ellipse(
                center: CGPoint(x: center.x + dx, y: center.y + dy),
                radiusX: radiusX, radiusY: radiusY
            )
        }
        return copy
    }

    /// 几何等比缩放（外源图/长图在编辑器内缩放预览时，保持标注严格钉在原图像素上）
    public func scaled(by factor: CGFloat) -> AnnotationModel {
        guard factor > 0, abs(factor - 1) > 0.0001 else { return self }
        var copy = self
        copy.strokeWidth = max(0.5, strokeWidth * factor)
        copy.fontSize = max(6, fontSize * factor)
        switch shape {
        case .arrow(let from, let to):
            copy.shape = .arrow(
                from: CGPoint(x: from.x * factor, y: from.y * factor),
                to: CGPoint(x: to.x * factor, y: to.y * factor)
            )
        case .rect(let rect):
            copy.shape = .rect(CGRect(
                x: rect.minX * factor, y: rect.minY * factor,
                width: rect.width * factor, height: rect.height * factor
            ))
        case .text(let anchor):
            copy.shape = .text(anchor: CGPoint(x: anchor.x * factor, y: anchor.y * factor))
        case .mosaic(let rect):
            copy.shape = .mosaic(CGRect(
                x: rect.minX * factor, y: rect.minY * factor,
                width: rect.width * factor, height: rect.height * factor
            ))
        case .sequence(let anchor):
            copy.shape = .sequence(anchor: CGPoint(x: anchor.x * factor, y: anchor.y * factor))
        case .highlight(let from, let to):
            copy.shape = .highlight(
                from: CGPoint(x: from.x * factor, y: from.y * factor),
                to: CGPoint(x: to.x * factor, y: to.y * factor)
            )
        case .ellipse(let center, let radiusX, let radiusY):
            copy.shape = .ellipse(
                center: CGPoint(x: center.x * factor, y: center.y * factor),
                radiusX: radiusX * factor,
                radiusY: radiusY * factor
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

    /// 批处理追加（供智能一键脱敏使用：整批只压一次撤销栈，一次 ⌘Z 整体撤回）
    func addBatch(_ newAnnotations: [AnnotationModel]) {
        guard !newAnnotations.isEmpty else { return }
        pushUndo()
        annotations.append(contentsOf: newAnnotations)
    }

    /// 查找命中点最上层的自动脱敏马赛克矩形（供悬停提示与单击取消使用）
    func autoRedactedRect(at point: CGPoint) -> CGRect? {
        for item in annotations.reversed() where item.isAutoRedacted {
            if case .mosaic(let rect) = item.shape, rect.contains(point) {
                return rect
            }
        }
        return nil
    }

    /// 单击取消某处自动脱敏（压入撤销栈，误删也可 ⌘Z 恢复）
    @discardableResult
    func removeAutoRedacted(at point: CGPoint) -> Bool {
        for idx in annotations.indices.reversed() {
            let item = annotations[idx]
            guard item.isAutoRedacted else { continue }
            if case .mosaic(let rect) = item.shape, rect.contains(point) {
                pushUndo()
                annotations.remove(at: idx)
                return true
            }
        }
        return false
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

    /// 视口缩放时同步缩放所有标注与历史快照（纯视口变换，不污染撤销栈）
    func scaleAll(by factor: CGFloat) {
        guard factor > 0, abs(factor - 1) > 0.0001 else { return }
        annotations = annotations.map { $0.scaled(by: factor) }
        undoStack = undoStack.map { snapshot in snapshot.map { $0.scaled(by: factor) } }
        redoStack = redoStack.map { snapshot in snapshot.map { $0.scaled(by: factor) } }
    }

    /// 恢复历史/Toast 矢量标注层，并按条重建撤销栈（支持 ⌘Z 逐条撤回已恢复的箭头/文字/序号/马赛克，及 ⌘⇧Z 重做）
    func restore(annotations restored: [AnnotationModel]) {
        redoStack.removeAll()
        guard !restored.isEmpty else {
            undoStack = []
            annotations = []
            Log.event(.editor, "editor.restore", ["count": "0"])
            return
        }
        var rebuiltUndo: [[AnnotationModel]] = []
        rebuiltUndo.reserveCapacity(restored.count)
        var prefix: [AnnotationModel] = []
        prefix.reserveCapacity(restored.count)
        for item in restored {
            rebuiltUndo.append(prefix)
            prefix.append(item)
        }
        if rebuiltUndo.count > 200 {
            rebuiltUndo.removeFirst(rebuiltUndo.count - 200)
        }
        undoStack = rebuiltUndo
        annotations = restored
        Log.event(.editor, "editor.restore", ["count": "\(restored.count)"])
    }

    private func pushUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
        if undoStack.count > 200 { undoStack.removeFirst() }
    }
}
