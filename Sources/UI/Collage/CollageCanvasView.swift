import AppKit
import CoreGraphics

/// 拼贴画布视图（C2 交付物 2）：画布渲染 + 贴片手势 + 吸附预览 + 标注层
///
/// 坐标系：视图 isFlipped（Y 向下），CollageDocument 贴片 frame / 标注几何
/// 同为「画布平面坐标、Y 向下」——两套坐标只差一个平移（画布在视图内居中，
/// 超出视图后左上对齐），无翻转/缩放换算。
///
/// 渲染分层（下→上）：
/// 1. 窗口底色（比画布纸面更深，衬托画布范围）
/// 2. 画布纸面（#1E1E22，docs/06 画布底色）
/// 3. 贴片：imageRef 查 CollageImageCache 按 frame 绘制 + rotation
///    （CGAffineTransform）+ 分镜框描边（showsPanelBorder，0.5pt + 圆角 2）
/// 4. 选中高亮（#0A84FF 2pt）
/// 5. 吸附预览：拖动中 snapTarget 的 gridSlot 虚线框 / 单轴 gutter 引导线
///    （#0A84FF 虚线；吸附是辅助，⌘ 拖跳过）
/// 6. 框选带（空白拖动）
/// 7. 标注层：CGRenderer.render(annotations:in:context:contextIsYDown:)，
///    画布坐标直画（与编辑器同一渲染器 = 导出所见）
///
/// 手势约定：拖动只改本地预览态，松手一次落位（一次拖动 = 一条 undo 快照）；
/// 滚轮缩放选中贴片（每档一条 undo）；双击贴片 = 标注编辑模式挂接点（TODO）。
@MainActor
final class CollageCanvasView: NSView {

    // MARK: - 外部接线（CollageWindowController 注入）

    /// 唯一真相源是 controller 的 CollageHistory；本视图只持有只读副本渲染
    var document = CollageDocument() { didSet { needsDisplay = true } }

    /// 手势产生的不可变更新（view 把新文档交给 controller 入 undo 历史）
    var onDocumentChanged: ((CollageDocument) -> Void)?

    /// 右键「粘贴入画布」（controller.addPiece 落位 nextGridSlot）
    var onAddImage: ((CGImage) -> Void)?

    // TODO(C4 导出): C4 交付后 controller 在此接导出入口（范围框选 + composite）；
    // 未接线前导出菜单项保持禁用（见 exportWired）
    var onExportRequested: (() -> Void)?

    /// C4 未交付标记：导出菜单项开关（C4 交付时翻 true 即亮）
    static var exportWired = false

    // MARK: - 状态

    private(set) var selection: Set<UUID> = []

    /// 清空选中（controller 用）
    func clearSelection() {
        selection = []
        needsDisplay = true
    }

    /// 拖动中视觉态（不进文档，松手才落位 → 一次拖动 = 一条 undo）
    private enum Drag {
        case piece(id: UUID, grabOffset: CGSize, allowSnap: Bool)
        case rubberBand(start: CGPoint)
    }
    private var drag: Drag?
    /// 被拖贴片的实时预览 frame（画布坐标）
    private var dragPreviewFrame: CGRect?
    /// 拖动中吸附预览（SnapGeometry.snapTarget 实时结果）
    private var snapPreview: SnapResult?
    /// 框选带（画布坐标）
    private var rubberBand: CGRect?

    // MARK: - 颜色常量（玻璃语言同源：#0A84FF 品牌色）

    private static let backdrop = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.086, alpha: 1)  // #131316
    private static let paper = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.133, alpha: 1)     // #1E1E22
    private static let paperStroke = NSColor(white: 1.0, alpha: 0.10)
    private static let accent = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)      // #0A84FF
    private static let panelBorder = NSColor(white: 1.0, alpha: 0.85)
    private static let placeholder = NSColor(white: 1.0, alpha: 0.08)
    private static let panelRadius: CGFloat = 2   // 分镜框圆角 2（C1 约定）
    private static let panelBorderWidth: CGFloat = 0.5

    // MARK: - 生命周期

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CollageCanvasView 只走代码创建") }

    override var isFlipped: Bool { true }   // 统一 Y 向下（与文档/标注几何一致）
    override var acceptsFirstResponder: Bool { true }

    // MARK: - 坐标映射（画布平面 ↔ 视图）

    /// 画布在视图内的摆放偏移：能放下则居中，放不下则左上对齐（原点 0）
    private var canvasOffset: CGPoint {
        let size = document.canvasSize
        let ox = max(0, (bounds.width - size.width) / 2)
        let oy = max(0, (bounds.height - size.height) / 2)
        return CGPoint(x: ox, y: oy)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - document.canvasOrigin.x + canvasOffset.x,
                y: p.y - document.canvasOrigin.y + canvasOffset.y)
    }

    private func toCanvasPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - canvasOffset.x + document.canvasOrigin.x,
                y: p.y - canvasOffset.y + document.canvasOrigin.y)
    }

    private func toCanvasRect(_ r: CGRect) -> CGRect {
        // ⚠️ C2 病例：这里误用了 toCanvasPoint（逆向）——贴片画到画布外
        // （viewFrame=-152,-225），正确是 toView（画布→视图）
        CGRect(origin: toView(r.origin), size: r.size)
    }

    private var canvasPaperRect: CGRect {
        CGRect(origin: toView(document.canvasOrigin), size: document.canvasSize)
    }

    // MARK: - 渲染

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .medium

        // 1. 窗口底色
        ctx.setFillColor(Self.backdrop.cgColor)
        ctx.fill(bounds)

        // 2. 画布纸面
        let paper = canvasPaperRect
        ctx.setFillColor(Self.paper.cgColor)
        ctx.fill(paper)
        ctx.setStrokeColor(Self.paperStroke.cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(paper)

        // 3. 贴片（z 序 = 数组序；被拖贴片用预览 frame）
        let zSorted = document.pieces.sorted { $0.z < $1.z }
        let draggingID = draggedPieceID
        for piece in zSorted {
            let frame = (draggingID == piece.id && dragPreviewFrame != nil)
                ? dragPreviewFrame!
                : piece.frame
            drawPiece(piece, frame: toCanvasRect(frame), context: ctx)
        }

        // 4. 吸附预览（拖动中）——选中高亮已在 drawPiece 内随描边处理
        if let snap = snapPreview {
            drawSnapPreview(snap, context: ctx)
        }

        // 5. 框选带
        if let band = rubberBand {
            let rect = toCanvasRect(band)
            ctx.setFillColor(Self.accent.withAlphaComponent(0.12).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(Self.accent.cgColor)
            ctx.setLineWidth(1)
            Self.setDash(ctx)
            ctx.stroke(rect)
            Self.clearDash(ctx)
        }

        // 6. 标注层（画布坐标，视图原生 Y-down CTM + 平移即可——OverlayWindow
        //    drawEditor 同款姿势：标注绝不能画进为位图准备的翻转 gstate）
        if !document.annotations.isEmpty {
            ctx.saveGState()
            let origin = toView(document.canvasOrigin)
            ctx.translateBy(x: origin.x, y: origin.y)
            CGRenderer.render(
                annotations: document.annotations,
                in: document.canvasSize,
                context: ctx,
                contextIsYDown: true
            )
            ctx.restoreGState()
        }
    }

    /// 被拖贴片 id（渲染时预览 frame 只对它生效）
    private var draggedPieceID: UUID? {
        if case let .piece(id, _, _) = drag { return id }
        return nil
    }

    private func drawPiece(_ piece: CollagePiece, frame: CGRect, context ctx: CGContext) {
        guard let image = CollageImageCache.shared.image(for: piece.imageRef) else {
            // 缓存逐出兜底：灰块占位（NSCache 内存压力回收后的降级可见性）
            ctx.setFillColor(Self.placeholder.cgColor)
            ctx.fill(frame)
            return
        }

        let selected = selection.contains(piece.id)
        let strokeColor = selected ? Self.accent : Self.panelBorder
        let strokeWidth = selected ? 2.0 : Self.panelBorderWidth

        ctx.saveGState()
        // rotation（度，顺时针；Y-down 坐标系下正角即视觉顺时针）
        if piece.rotation != 0 {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: piece.rotation * .pi / 180)
            ctx.translateBy(x: -center.x, y: -center.y)
        }

        // 位图：CGContext.draw 假设 Y-up，本视图 Y-down ⇒ 局部镜像一次再 draw
        // （PinContentView / OverlayWindow drawEditor 同款翻转处理）
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        ctx.restoreGState()

        // 分镜框：0.5pt 描边 + 圆角 2（默认开）；选中时换成 2pt 品牌色高亮
        let border = NSBezierPath(roundedRect: frame, xRadius: Self.panelRadius, yRadius: Self.panelRadius)
        border.lineWidth = strokeWidth
        strokeColor.setStroke()
        border.stroke()

        ctx.restoreGState()
    }

    private func drawSnapPreview(_ snap: SnapResult, context ctx: CGContext) {
        ctx.setStrokeColor(Self.accent.cgColor)
        ctx.setLineWidth(1.5)
        Self.setDash(ctx)

        switch snap {
        case .gridSlot(let rect):
            // 完整格位：虚线框（gutter 间隙已含在格位几何里）
            ctx.stroke(toCanvasRect(rect))
        case .vertical(let x, _):
            // 单轴命中：间隙中线引导线（竖线）
            let vx = toView(CGPoint(x: x, y: 0)).x
            ctx.move(to: CGPoint(x: vx, y: canvasPaperRect.minY))
            ctx.addLine(to: CGPoint(x: vx, y: canvasPaperRect.maxY))
            ctx.strokePath()
        case .horizontal(let y, _):
            let hy = toView(CGPoint(x: 0, y: y)).y
            ctx.move(to: CGPoint(x: canvasPaperRect.minX, y: hy))
            ctx.addLine(to: CGPoint(x: canvasPaperRect.maxX, y: hy))
            ctx.strokePath()
        case .none:
            break
        }
        Self.clearDash(ctx)
    }

    private static func setDash(_ ctx: CGContext, phase: CGFloat = 0) {
        ctx.setLineDash(phase: phase, lengths: [5, 4])
    }

    private static func clearDash(_ ctx: CGContext) {
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // MARK: - 手势：单击选中 / 拖动落位 / 框选 / 双击进标注编辑

    override func mouseDown(with event: NSEvent) {
        let canvasPoint = toCanvasPoint(convert(event.locationInWindow, from: nil))

        // 双击贴片 → 标注编辑模式挂接点
        if event.clickCount >= 2, let piece = pieceAt(canvasPoint) {
            selection = [piece.id]
            beginAnnotationEdit(for: piece.id)
            return
        }

        if let piece = pieceAt(canvasPoint) {
            selection = [piece.id]
            let grabOffset = CGSize(
                width: canvasPoint.x - piece.frame.origin.x,
                height: canvasPoint.y - piece.frame.origin.y
            )
            // ⌘ 拖 = 跳过吸附（docs/06 §2：自由位置仍然允许）
            let allowSnap = !event.modifierFlags.contains(.command)
            drag = .piece(id: piece.id, grabOffset: grabOffset, allowSnap: allowSnap)
            dragPreviewFrame = piece.frame
            snapPreview = nil
            needsDisplay = true
            return
        }

        // 空白：框选（松手判定是否「点击清选」）
        drag = .rubberBand(start: canvasPoint)
        rubberBand = CGRect(origin: canvasPoint, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        let canvasPoint = toCanvasPoint(convert(event.locationInWindow, from: nil))
        switch drag {
        case let .piece(id, grabOffset, allowSnap):
            guard let piece = document.piece(with: id) else { return }
            let preview = CGRect(
                x: canvasPoint.x - grabOffset.width,
                y: canvasPoint.y - grabOffset.height,
                width: piece.frame.width,
                height: piece.frame.height
            )
            dragPreviewFrame = preview
            snapPreview = allowSnap
                ? SnapGeometry.snapTarget(
                    for: preview,
                    in: document.pieces.filter { $0.id != id }.map(\.frame),
                    gutter: SnapGeometry.defaultGutter
                )
                : nil
            needsDisplay = true

        case let .rubberBand(start):
            rubberBand = CGRect(
                x: min(start.x, canvasPoint.x), y: min(start.y, canvasPoint.y),
                width: abs(canvasPoint.x - start.x), height: abs(canvasPoint.y - start.y)
            )
            needsDisplay = true

        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case let .piece(id, _, _):
            // 落位：吸附命中（非 ⌘ 拖）→ snapped frame；否则预览位置原样落
            let final: CGRect
            switch snapPreview {
            case .gridSlot(let rect): final = rect
            case .vertical(_, let snapped): final = snapped
            case .horizontal(_, let snapped): final = snapped
            case .none: final = dragPreviewFrame ?? (document.piece(with: id)?.frame ?? .zero)
            @unknown default: final = dragPreviewFrame ?? (document.piece(with: id)?.frame ?? .zero)
            }
            drag = nil
            dragPreviewFrame = nil
            snapPreview = nil
            if let current = document.piece(with: id), current.frame != final {
                onDocumentChanged?(document.resizing(pieceID: id, to: final))
            }
            needsDisplay = true

        case .rubberBand:
            defer {
                drag = nil
                rubberBand = nil
                needsDisplay = true
            }
            guard let band = rubberBand else { return }
            if band.width < 4 && band.height < 4 {
                // 空白单击 = 清选
                selection.removeAll()
                return
            }
            // 框选多贴片（与框选带相交即选中）
            selection = Set(document.pieces.filter { $0.frame.intersects(band) }.map(\.id))

        case nil:
            break
        }
    }

    // MARK: - 手势：滚轮缩放选中贴片

    override func scrollWheel(with event: NSEvent) {
        // 单选贴片时滚轮缩放；无选中交给 super（窗口滚动语义）
        guard selection.count == 1, let id = selection.first,
              let piece = document.piece(with: id) else {
            super.scrollWheel(with: event)
            return
        }
        // 自然滚动：deltaY < 0（上滚）放大
        let factor = event.deltaY < 0 ? 1.06 : 1 / 1.06
        var w = piece.frame.width * factor
        var h = piece.frame.height * factor
        w = min(max(w, 40), 4000)
        h = min(max(h, 40), 4000)
        let next = document.resizing(
            pieceID: id,
            to: CGRect(x: piece.frame.midX - w / 2, y: piece.frame.midY - h / 2, width: w, height: h)
        )
        onDocumentChanged?(next)
    }

    // MARK: - 右键菜单（空白处：粘贴入画布 / 清空 / 导出占位）

    override func rightMouseDown(with event: NSEvent) {
        let canvasPoint = toCanvasPoint(convert(event.locationInWindow, from: nil))
        // 贴片上的右键暂走系统默认（TODO(C3 合并手势): 「合并到拼贴」/层级菜单接手）
        guard pieceAt(canvasPoint) == nil else {
            super.rightMouseDown(with: event)
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let paste = NSMenuItem(title: "粘贴入画布", action: #selector(menuPaste), keyEquivalent: "v")
        paste.target = self
        paste.isEnabled = Self.pasteboardImage() != nil

        let clear = NSMenuItem(title: "清空画布", action: #selector(menuClear), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !document.pieces.isEmpty || !document.annotations.isEmpty

        let export = NSMenuItem(title: "导出画布…", action: #selector(menuExport), keyEquivalent: "")
        export.target = self
        // TODO(C4 导出): C4 交付（范围框选 + composite）并接线 onExportRequested 后启用
        export.isEnabled = Self.exportWired

        for item in [paste, NSMenuItem.separator(), clear, NSMenuItem.separator(), export] {
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func menuPaste() {
        guard let image = Self.pasteboardImage() else { return }
        onAddImage?(image)
        Log.event(.app, "collage.paste")
    }

    @objc private func menuClear() {
        onDocumentChanged?(CollageDocument())
        selection.removeAll()
        Log.event(.app, "collage.clear")
    }

    @objc private func menuExport() {
        onExportRequested?()
    }

    /// 剪贴板图像（有图才启用「粘贴入画布」）
    private static func pasteboardImage() -> CGImage? {
        guard let nsImage = NSPasteboard.general.readObjects(
            forClasses: [NSImage.self], options: nil
        )?.first as? NSImage,
            let tiff = nsImage.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }

    // MARK: - 查询

    private func pieceAt(_ canvasPoint: CGPoint) -> CollagePiece? {
        // 顶层优先（z 大者在上）
        document.pieces
            .sorted { $0.z > $1.z }
            .first { $0.frame.contains(canvasPoint) }
    }

    // MARK: - 标注编辑模式挂接点

    /// 双击贴片 → 进标注层编辑（docs/06 §2 工具 3：标注模式全套照常画）
    ///
    // TODO(C-标注编辑): 在此挂接 CGRenderer 标注工具链——
    //   1. 建 AnnotationStore（或直绑 document.annotations）+ 工具面板；
    //   2. mouseDown 按当前工具产 AnnotationModel 写入（复用编辑器手势骨架）；
    //   3. 提交走 onDocumentChanged(doc.withAnnotations(...)) 进 undo 历史；
    //   4. Esc 退出标注模式回排版模式。
    // C2 本任务只留挂接点与日志打点，不实现工具面板。
    private func beginAnnotationEdit(for pieceID: UUID) {
        Log.event(.app, "collage.editMode.todo", ["piece": pieceID.uuidString])
    }
}
