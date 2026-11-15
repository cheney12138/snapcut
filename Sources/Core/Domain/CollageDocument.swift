import CoreGraphics
import Foundation

/// 拼贴贴片（docs/06 §4：Piece = id / imageRef / frame / rotation / z / 分镜框开关）
///
/// `imageRef` 是图像库键（不是 CGImage 本身）——文档保持纯值类型可自由拷贝进
/// undo 快照；像素解码由渲染层按 imageRef 查缓存完成。
/// frame 为画布坐标（原点画布左上、Y 向下，与 AnnotationModel/CGRenderer 一致）。
struct CollagePiece: Identifiable, Equatable, Sendable {
    let id: UUID
    /// 图像库键（适配器负责解析为位图）
    var imageRef: String
    /// 画布坐标中的占位矩形
    var frame: CGRect
    /// 旋转角（度，顺时针；渲染层负责换算）
    var rotation: CGFloat
    /// 层级（大者在上；重排后由 CollageDocument 归一化为 0..n-1）
    var z: Int
    /// 分镜框（0.5pt 描边 + 圆角 2，漫画分镜感；默认开）
    var showsPanelBorder: Bool

    init(
        id: UUID = UUID(),
        imageRef: String,
        frame: CGRect,
        rotation: CGFloat = 0,
        z: Int = 0,
        showsPanelBorder: Bool = true
    ) {
        self.id = id
        self.imageRef = imageRef
        self.frame = frame
        self.rotation = rotation
        self.z = z
        self.showsPanelBorder = showsPanelBorder
    }
}

/// AnnotationModel 与拼贴文档同处一个模块且全部成员是值类型
/// （CGPoint/CGRect/String/CGFloat/Int），补一个 @unchecked Sendable 声明
/// 即可让 CollageDocument（含标注数组）满足 Sendable。跨文件声明 Sendable
/// 需要 @unchecked，这里的安全性由「AnnotationModel 只含值类型成员」保证；
/// 本文件不改动 AnnotationModel.swift 本身（既有文件纪律）。
extension AnnotationModel: @unchecked Sendable {}

/// 拼贴文档（docs/06 §4：贴片数组 + 标注数组 + 画布范围）
///
/// 唯一真相源：贴片几何在这里，标注几何复用既有 AnnotationModel
/// （坐标系同为画布/选区本地、Y 向下，CGRenderer 可零改动复用）。
/// 文档是值类型：所有变更走「返回新文档」的不可变更新，
/// undo/redo 由 CollageHistory 对整文档做值快照（AnnotationStore 思路），
/// 不需要 command 模式——快照本身就是最小的完整状态。
struct CollageDocument: Equatable, Sendable {
    /// 画布内容与画布边缘的留白（bounding box 外扩）
    static let canvasPadding: CGFloat = 32
    /// 空文档的初始画布（给用户一个「有东西可拖」的起点）
    static let defaultCanvasSize = CGSize(width: 800, height: 600)

    var pieces: [CollagePiece]
    /// 统一标注层（跨图框选/序号/文字/箭头/马赛克/画笔，复用既有模型）
    var annotations: [AnnotationModel]
    /// 画布左上角（内容 bounding box 外扩 padding 后的位置）
    var canvasOrigin: CGPoint
    /// 画布尺寸（内容 bounding box + 2 × padding）
    var canvasSize: CGSize

    init(
        pieces: [CollagePiece] = [],
        annotations: [AnnotationModel] = [],
        canvasOrigin: CGPoint = .zero,
        canvasSize: CGSize = CollageDocument.defaultCanvasSize
    ) {
        self.pieces = pieces
        self.annotations = annotations
        self.canvasOrigin = canvasOrigin
        self.canvasSize = canvasSize
    }

    // MARK: - 查询

    func piece(with id: UUID) -> CollagePiece? {
        pieces.first { $0.id == id }
    }

    /// 当前内容 bounding box（所有贴片 frame 的并集；空文档返回 nil）
    var contentBounds: CGRect? {
        guard let first = pieces.first else { return nil }
        return pieces.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    // MARK: - 不可变更新（每个方法返回新文档）

    /// 新增贴片：z 取当前最大 + 1（新图在最上层）
    func adding(_ piece: CollagePiece) -> CollageDocument {
        var doc = self
        var newPiece = piece
        newPiece.z = (pieces.map(\.z).max() ?? -1) + 1
        doc.pieces.append(newPiece)
        doc.recomputeCanvas()
        return doc
    }

    /// 移除贴片（标注不动：标注是整画布层，删图后用户自行修整）
    func removing(pieceID: UUID) -> CollageDocument {
        var doc = self
        doc.pieces.removeAll { $0.id == pieceID }
        doc.recomputeCanvas()
        return doc
    }

    /// 平移贴片到画布坐标 origin，随后重算画布范围（内容 bounding box + padding）
    func moving(pieceID: UUID, to origin: CGPoint) -> CollageDocument {
        mutateFrame(pieceID: pieceID) { $0.origin = origin }
    }

    /// 整体位移量版本（拖动手势直接喂 delta）
    func moving(pieceID: UUID, by delta: CGSize) -> CollageDocument {
        mutateFrame(pieceID: pieceID) { $0.origin.x += delta.width; $0.origin.y += delta.height }
    }

    /// 调整贴片矩形（吸附目标格位也走这里落位）
    func resizing(pieceID: UUID, to frame: CGRect) -> CollageDocument {
        mutateFrame(pieceID: pieceID) { $0 = frame }
    }

    /// 旋转贴片（度，顺时针）
    func rotating(pieceID: UUID, to rotation: CGFloat) -> CollageDocument {
        var doc = self
        guard let index = doc.pieces.firstIndex(where: { $0.id == pieceID }) else { return doc }
        doc.pieces[index].rotation = rotation
        return doc
    }

    /// 分镜框开关
    func settingPanelBorder(pieceID: UUID, visible: Bool) -> CollageDocument {
        var doc = self
        guard let index = doc.pieces.firstIndex(where: { $0.id == pieceID }) else { return doc }
        doc.pieces[index].showsPanelBorder = visible
        return doc
    }

    /// 层级重排：重排后 z 归一化为 0..n-1（数组顺序即 z 序）
    enum ZOrderAction: Sendable, Equatable {
        case toFront, toBack
        case forward, backward
    }

    func reorderingZ(pieceID: UUID, action: ZOrderAction) -> CollageDocument {
        var doc = self
        guard let index = doc.pieces.firstIndex(where: { $0.id == pieceID }) else { return doc }
        let piece = doc.pieces.remove(at: index)
        let target: Int
        switch action {
        case .toFront: target = doc.pieces.count
        case .toBack: target = 0
        case .forward: target = min(index + 1, doc.pieces.count)
        case .backward: target = max(index - 1, 0)
        }
        doc.pieces.insert(piece, at: target)
        // 归一化：数组顺序 → z = 下标，避免长期使用后 z 值漂移/并列
        for i in doc.pieces.indices { doc.pieces[i].z = i }
        return doc
    }

    /// 标注层整体平移（画布因贴片移动而重算原点时，标注要跟着钉在内容上）
    func offsettingAnnotations(dx: CGFloat, dy: CGFloat) -> CollageDocument {
        var doc = self
        guard dx != 0 || dy != 0 else { return doc }
        doc.annotations = doc.annotations.map { $0.offsetBy(dx: dx, dy: dy) }
        return doc
    }

    // MARK: - 私有

    private func mutateFrame(pieceID: UUID, _ change: (inout CGRect) -> Void) -> CollageDocument {
        var doc = self
        guard let index = doc.pieces.firstIndex(where: { $0.id == pieceID }) else { return doc }
        change(&doc.pieces[index].frame)
        doc.recomputeCanvas()
        return doc
    }

    /// 画布范围 = 内容 bounding box 外扩 padding。
    /// 空文档保留当前画布（不缩成 0，用户删光后画布不跳动）。
    private mutating func recomputeCanvas() {
        guard let bounds = contentBounds else { return }
        let origin = CGPoint(
            x: bounds.minX - Self.canvasPadding,
            y: bounds.minY - Self.canvasPadding
        )
        canvasOrigin = origin
        canvasSize = CGSize(
            width: bounds.width + Self.canvasPadding * 2,
            height: bounds.height + Self.canvasPadding * 2
        )
    }
}

/// 拼贴 undo/redo：整文档值快照栈（AnnotationStore 思路的直译）。
///
/// 取舍：贴片 + 标注一起变（拖动会同时改 canvas 与标注平移），command 模式
/// 要为每种操作写逆操作、还要处理交错序列；值快照天然覆盖「任意操作组合」，
/// 代价只是几百字节的 rect 拷贝，跟 AnnotationStore 的 200 条上限同一量级。
struct CollageHistory: Sendable {
    private var current: CollageDocument
    private var undoStack: [CollageDocument] = []
    private var redoStack: [CollageDocument] = []
    private let limit = 200

    public init(document: CollageDocument = CollageDocument()) {
        self.current = document
    }

    public var document: CollageDocument { current }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// 提交一次变更（值语义：状态没变就不产生快照，防重复入栈）
    public mutating func apply(_ next: CollageDocument) {
        guard next != current else { return }
        undoStack.append(current)
        redoStack.removeAll()
        if undoStack.count > limit { undoStack.removeFirst() }
        current = next
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }
}
