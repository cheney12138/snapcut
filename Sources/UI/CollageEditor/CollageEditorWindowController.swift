import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 拼贴合成编辑宿主（设计定稿 §1.4）：点「⟐ 合成整体」后的标注编辑窗口。
///
/// EditorSession = baseImage + AnnotationStore + 渲染参数，renderFinalImage()
/// 独立可用 ⇒ 整体复用；ToolbarPanel.configure 直接驱动 undo/redo/工具/颜色/粗细。
/// 与 Overlay 编辑器的差异只有三点：
/// 1. 宿主窗是普通标题窗（非全屏覆盖层），底图 = 组合成图（虚拟 selectionGlobal）
/// 2. ToolbarPanel.place(aboveGlobal:) 贴窗顶
/// 3. 键盘路由走共享 EditorKeyRouter + 本视图的 Esc/Enter 内置语义
///
/// onAction 语义映射（裁决书）：
/// - done → renderFinalImage + 复制（ExportCoordinator 链路）
/// - save → savePanel；cancel → 确认后关窗（合成图已丢弃，回不到组）
/// - pin → 合成图（含标注）重新 pin 回桌面，继续参与下一轮磁吸
@MainActor
final class CollageEditorWindowController: NSWindowController, NSWindowDelegate {
    /// 存活实例（窗口关闭前防 ARC 回收，同 PinWindowController 模式）
    private static var live: [CollageEditorWindowController] = []

    private let session: EditorSession
    /// 内容视图读取（标注手势/绘制用；session 本体保持不可变引用）
    var editorSession: EditorSession { session }
    private var toolbar: ToolbarPanel?
    private let exporter = ExportCoordinator()
    /// 显示缩放（窗口内容小于图像 point 尺寸时 < 1；标注坐标 = 本地 / displayScale）
    let displayScale: CGFloat
    let imagePtSize: CGSize

    private var editorView: CollageEditorContentView? {
        window?.contentView as? CollageEditorContentView
    }

    /// 入口：PinMagnetRegistry.assemble 合成后调用
    static func present(composite: CGImage, pxScale: CGFloat) {
        guard let controller = CollageEditorWindowController(composite: composite, pxScale: pxScale) else {
            Log.error(.editor, "collage.editor.fail", ["reason": "init"])
            return
        }
        live.append(controller)
        controller.showWindow()
        Log.event(.editor, "collage.editor.open", [
            "pxW": "\(composite.width)",
            "pxH": "\(composite.height)",
        ])
    }

    private init?(composite: CGImage, pxScale: CGFloat) {
        // 像素 → point：pxScale 由烤图方透传（union 所在屏的 backingScaleFactor，
        // 多屏时与 NSScreen.main 不同——错猜会让标注/马赛克整体错位）
        let screen = NSScreen.main
        let ptSize = CGSize(
            width: CGFloat(composite.width) / pxScale,
            height: CGFloat(composite.height) / pxScale
        )
        guard ptSize.width >= 1, ptSize.height >= 1 else { return nil }
        self.imagePtSize = ptSize
        // 显示尺寸夹取：超过可视区 85% 等比缩小（内容视图绘制/手势按 displayScale 换算）
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = visible.width * 0.85
        let maxH = visible.height * 0.85
        self.displayScale = min(
            1, maxW / ptSize.width, maxH / ptSize.height
        )

        // 虚拟 selectionGlobal = 图像 point 尺寸（scale = px/pt = pxScale）
        guard let hostScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        self.session = EditorSession(
            baseImage: composite,
            scale: pxScale,
            selectionGlobal: CGRect(origin: .zero, size: ptSize),
            screen: hostScreen
        )

        let contentSize = CGSize(
            width: ptSize.width * displayScale,
            height: ptSize.height * displayScale
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Snapcut 拼贴 · 标注"
        // 坑（同 CollageWindowController/ToolbarPanel）：不钉 appearance 浅色系统
        // 下控件解析成浅色，深底画布上不可读
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.center()

        let view = CollageEditorContentView(frame: NSRect(origin: .zero, size: contentSize))
        window.contentView = view
        // self 转移必须在 super.init 之后（Swift 初始化完备性）；controller
        // 回接与 firstResponder 挂到 showWindow 阶段做
        super.init(window: window)
        view.controller = self
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CollageEditorWindowController 只走 present 创建") }

    private func showWindow() {
        guard let window else { return }
        window.center()
        window.initialFirstResponder = editorView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupToolbar()
        // ToolbarPanel 创建/orderFront 会偷 key 态（OverlayController.enterEditor 同款
        // 病例）：延后一个 runloop tick 夺回 key + first responder
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if let view = window.contentView {
                _ = window.makeFirstResponder(view)
            }
            self.toolbar?.orderFrontRegardless()
            Log.event(.editor, "collage.editor.focus", ["keyWin": "\(window.isKeyWindow)"])
        }
    }

    /// 工具栏（EditorSession/ToolbarPanel 零改动复用）
    private func setupToolbar() {
        guard let window else { return }
        let toolbar = ToolbarPanel()
        toolbar.updateScreen(window.screen ?? NSScreen.main ?? NSScreen.screens[0])
        toolbar.configure(
            session: session,
            onToolChange: { [weak self] in self?.editorView?.needsDisplay = true },
            onAction: { [weak self] action in self?.toolbarAction(action) }
        )
        // 贴窗顶（合成窗场景；place(below:) 语义不适合标题窗）
        toolbar.place(aboveGlobal: window.frame)
        toolbar.orderFrontRegardless()
        self.toolbar = toolbar
    }

    // MARK: - ToolbarPanel.Action 语义映射

    func toolbarAction(_ action: ToolbarPanel.Action) {
        switch action {
        case .undo:
            session.store.undo()
            refreshAfterStoreChange("annotate.undo")
        case .redo:
            session.store.redo()
            refreshAfterStoreChange("annotate.redo")
        case .toggleVisibility:
            session.toolbarVisible.toggle()
            if session.toolbarVisible {
                toolbar?.orderFrontRegardless()
            } else {
                toolbar?.orderOut(nil)
                toolbar?.hideTooltip()
            }
            toolbar?.setToolbarHidden(!session.toolbarVisible)
            Log.event(.editor, "editor.toolbar.\(session.toolbarVisible ? "show" : "hide")")
        case .done:
            exportAndClose(mode: .copy)
        case .save:
            exportAndClose(mode: .save)
        case .cancel:
            confirmCancel()
        case .ocr:
            runOCR()
        case .pin:
            pinComposite()
        case .scroll:
            // 滚动截图是截图编辑器专属语义，拼贴编辑器无此动作（按钮不出现在此场景）
            break
        }
    }

    private func refreshAfterStoreChange(_ evt: String) {
        toolbar?.refreshSelectionState()
        editorView?.needsDisplay = true
        Log.event(.editor, evt, [
            "canUndo": "\(session.store.canUndo)", "canRedo": "\(session.store.canRedo)",
        ])
    }

    /// 标注落库（内容视图手势回调）
    func addAnnotation(_ annotation: AnnotationModel) {
        session.store.add(annotation)
        toolbar?.refreshSelectionState()
        editorView?.needsDisplay = true
    }

    // MARK: - 导出 / 收尾

    private enum ExportMode { case copy, save }

    /// renderFinalImage（底图 + 马赛克像素化 + CGRenderer.composite 矢量标注）
    /// → 既有导出链路（矩阵 PNG：间隙背景色 + 标注已烤入）
    private func exportAndClose(mode: ExportMode) {
        editorView?.flushPendingAnnotationForExport()
        let image = session.renderFinalImage()
        AppCoordinatorShared.deps?.history.record(image)
        switch mode {
        case .copy:
            AppCoordinatorShared.deps?.clipboard.writeImage(image)
            let settings = AppCoordinatorShared.coordinator?.settings ?? .defaultSettings
            if settings.showCopyNotification {
                CaptureToast.show(image: image)
            }
            Log.event(.editor, "collage.editor.copy", [
                "pxW": "\(image.width)", "pxH": "\(image.height)",
            ])
        case .save:
            exporter.savePanel(image)
        }
        closeEditor()
    }

    /// cancel 弹确认（裁决：合成图已丢弃，回不到组）
    private func confirmCancel() {
        // 文字输入态的 Esc 先取消输入（与 Overlay 编辑器一致）
        if editorView?.cancelTextEditingIfNeeded() == true { return }
        let alert = NSAlert()
        alert.messageText = "放弃这张拼贴？"
        alert.informativeText = "关闭后合成图与标注将丢弃，成员贴图已收编、无法回到拼贴组。"
        alert.addButton(withTitle: "放弃并关闭")
        alert.addButton(withTitle: "继续编辑")
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Log.event(.editor, "collage.editor.cancel")
            closeEditor()
        }
    }

    /// 合成图（含标注）重新 pin 回桌面（闭环：还能继续参与下一轮磁吸）
    private func pinComposite() {
        editorView?.flushPendingAnnotationForExport()
        let image = session.renderFinalImage()
        AppCoordinatorShared.deps?.history.record(image)
        guard let window, let view = editorView else { return }
        let screenRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        // reviewer 补丁：pin 契约是 rect.size × backingScale == 像素尺寸——
        // 显示可能整体缩小（displayScale<1），按图像 point 尺寸落位才 1:1
        let rect = CGRect(origin: screenRect.origin, size: imagePtSize)
        AppCoordinatorShared.deps?.pinning.pin(image, atGlobalRect: rect)
        Log.event(.pin, "collage.editor.pin", [
            "pxW": "\(image.width)", "pxH": "\(image.height)",
        ])
        closeEditor()
    }

    /// 取字（复用 Vision 端口 + OCRResultPanel）
    private func runOCR() {
        editorView?.flushPendingAnnotationForExport()
        let image = session.renderFinalImage()
        AppCoordinatorShared.deps?.history.record(image)
        guard let window, let deps = AppCoordinatorShared.deps else { return }
        Log.event(.ocr, "ocr.start", ["pxW": "\(image.width)", "pxH": "\(image.height)"])
        let rect = window.frame
        let screen = window.screen ?? NSScreen.main ?? NSScreen()
        Task { @MainActor in
            let text = (try? await deps.textRecognizer.recognize(image)) ?? ""
            OCRResultPanel.present(text: text, nearGlobalRect: rect, on: screen)
            Log.event(.ocr, "ocr.present", ["chars": "\(text.count)"])
        }
    }

    func closeEditor() {
        toolbar?.orderOut(nil)
        toolbar = nil
        window?.orderOut(nil)
        Self.live.removeAll { $0 === self }
        Log.event(.editor, "collage.editor.close")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        closeEditor()
    }

    // MARK: - EditorKeyRouter 动作集（内容视图 keyDown 用）

    var keyActions: EditorKeyRouter.Actions {
        EditorKeyRouter.Actions(
            undo: { [weak self] in self?.toolbarAction(.undo) },
            redo: { [weak self] in self?.toolbarAction(.redo) },
            toggleVisibility: { [weak self] in self?.toolbarAction(.toggleVisibility) },
            ocr: { [weak self] in self?.toolbarAction(.ocr) },
            pin: { [weak self] in self?.toolbarAction(.pin) },
            save: { [weak self] in self?.toolbarAction(.save) },
            done: { [weak self] in self?.toolbarAction(.done) },
            cancel: { [weak self] in self?.toolbarAction(.cancel) },
            selectTool: { [weak self] tool in
                guard let self else { return }
                self.session.currentTool = tool
                self.toolbar?.refreshSelectionState()
                self.editorView?.needsDisplay = true
            }
        )
    }
}

// MARK: - 内容视图：合成图绘制 + 标注手势 + 键盘

@MainActor
final class CollageEditorContentView: NSView {
    weak var controller: CollageEditorWindowController?

    /// 拖拽中的标注预览（未确认，不入 store）
    private var pendingAnnotation: AnnotationModel?
    private var pendingStartPoint: CGPoint?
    /// 文字输入框（text 工具）
    private var textField: NSTextField?
    private var textFieldAnchor: CGPoint?

    override var isFlipped: Bool { true }  // 统一 Y 向下（与标注几何一致）
    override var acceptsFirstResponder: Bool { true }

    private var session: EditorSession? { controller?.editorSession }
    /// 标注坐标系 = 图像 point 坐标；显示可能整体缩小（displayScale < 1）
    private var displayScale: CGFloat { controller?.displayScale ?? 1 }

    // MARK: - 坐标换算

    /// 视图本地（Y-down，显示 points）→ 标注几何（图像本地 Y-down point）
    private func localToAnnotation(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / displayScale, y: p.y / displayScale)
    }

    private func annotationToLocal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * displayScale, y: p.y * displayScale)
    }

    private func annotationRect(_ r: CGRect) -> CGRect {
        CGRect(
            x: r.minX / displayScale, y: r.minY / displayScale,
            width: r.width / displayScale, height: r.height / displayScale
        )
    }

    /// 两点 → 矩形（起点锚定，非增量 union；OverlayView 病例同款）
    private func rectFromPoints(_ start: CGPoint, _ point: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
    }

    // MARK: - 手势（OverlayView 编辑态子集：无选区调整/放大镜/滚动）

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        guard let session else { return }
        let point = convert(event.locationInWindow, from: nil)
        let a = localToAnnotation(point)
        switch session.currentTool {
        case .text:
            beginTextEditing(at: a)
        case .sequence:
            controller?.addAnnotation(AnnotationModel(
                shape: .sequence(anchor: a),
                colorIndex: session.colorIndex,
                strokeWidth: session.strokeWidth,
                index: session.store.nextSequenceNumber()
            ))
        case .arrow, .highlight:
            pendingStartPoint = a
            pendingAnnotation = AnnotationModel(
                shape: session.currentTool == .arrow
                    ? .arrow(from: a, to: a)
                    : .highlight(from: a, to: a),
                colorIndex: session.colorIndex, strokeWidth: session.strokeWidth,
                text: nil, index: nil
            )
            needsDisplay = true
        case .rect, .mosaic:
            pendingStartPoint = a
            pendingAnnotation = AnnotationModel(
                shape: session.currentTool == .rect
                    ? .rect(annotationRect(CGRect(origin: point, size: .zero)))
                    : .mosaic(annotationRect(CGRect(origin: point, size: .zero))),
                colorIndex: session.colorIndex, strokeWidth: session.strokeWidth,
                text: nil, index: nil
            )
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var pending = pendingAnnotation, let start = pendingStartPoint else { return }
        let a = localToAnnotation(convert(event.locationInWindow, from: nil))
        switch pending.shape {
        case .arrow(_, _):
            pending.shape = .arrow(from: start, to: a)
        case .highlight(let from, _):
            pending.shape = .highlight(from: from, to: a)
        case .rect:
            pending.shape = .rect(rectFromPoints(start, a))
        case .mosaic:
            pending.shape = .mosaic(rectFromPoints(start, a))
        default:
            break
        }
        pendingAnnotation = pending
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        _ = finalizePendingAnnotation(at: convert(event.locationInWindow, from: nil))
    }

    /// 定稿 pending（mouseUp 正常路径 + 导出 flush 共用；同 OverlayWindow 收口）
    @discardableResult
    private func finalizePendingAnnotation(at point: CGPoint) -> Bool {
        guard let pending = pendingAnnotation else { return false }
        let a = localToAnnotation(point)
        var final = pending
        switch pending.shape {
        case .arrow(let from, _):
            let start = pendingStartPoint ?? from
            guard hypot(a.x - start.x, a.y - start.y) >= 4 else { cancelPending(); return false }
            final.shape = .arrow(from: start, to: a)
        case .highlight(let from, _):
            let start = pendingStartPoint ?? from
            guard hypot(a.x - start.x, a.y - start.y) >= 4 else { cancelPending(); return false }
            final.shape = .highlight(from: start, to: a)
        case .rect:
            let rect = rectFromPoints(pendingStartPoint ?? a, a)
            guard rect.width >= 3, rect.height >= 3 else { cancelPending(); return false }
            final.shape = .rect(rect)
        case .mosaic:
            let rect = rectFromPoints(pendingStartPoint ?? a, a)
            guard rect.width >= 3, rect.height >= 3 else { cancelPending(); return false }
            final.shape = .mosaic(rect)
        default:
            return false
        }
        Log.event(.editor, "editor.shape.commit", [
            "shape": "\(final.shape)", "color": "\(final.color)",
        ])
        controller?.addAnnotation(final)
        cancelPending()
        return true
    }

    /// 导出前统一 flush（mouseUp/keyDown 竞态兜底）。
    /// pending.shape 已随 drag 更新（= 用户所见），直接提交，不用光标位重算
    /// （光标位是 mouseMoved 旧值，会误判「零位移」而 drop——同 Overlay 病例）。
    func flushPendingAnnotationForExport() {
        guard let pending = pendingAnnotation else { return }
        var final = pending
        switch pending.shape {
        case .arrow(let from, let to):
            guard hypot(to.x - from.x, to.y - from.y) >= 4 else {
                Log.event(.editor, "editor.shape.flush.drop", [:])
                cancelPending(); return
            }
            final.shape = .arrow(from: from, to: to)
        case .highlight(let from, let to):
            guard hypot(to.x - from.x, to.y - from.y) >= 4 else {
                Log.event(.editor, "editor.shape.flush.drop", [:])
                cancelPending(); return
            }
            final.shape = .highlight(from: from, to: to)
        case .rect(let r), .mosaic(let r):
            guard r.width >= 3, r.height >= 3 else {
                Log.event(.editor, "editor.shape.flush.drop", [:])
                cancelPending(); return
            }
        default:
            return
        }
        Log.event(.editor, "editor.shape.commit", [
            "shape": "\(final.shape)", "color": "\(final.color)", "via": "flush",
        ])
        controller?.addAnnotation(final)
        cancelPending()
    }

    private func cancelPending() {
        pendingAnnotation = nil
        pendingStartPoint = nil
        needsDisplay = true
    }

    // MARK: - 文字输入（简化版：无玻璃字号条，4 档字号跟 session.textFontSize）

    private func beginTextEditing(at annotationPoint: CGPoint) {
        commitTextFieldIfNeeded()
        let pointSize = CGFloat(session?.textFontSize ?? 14)
        let local = annotationToLocal(annotationPoint)
        let field = NSTextField(frame: NSRect(
            x: local.x, y: max(2, local.y - 16),
            width: max(160, bounds.width - local.x - 8),
            height: 30
        ))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: pointSize, weight: .medium)
        if let colorIndex = session?.colorIndex,
           AnnotationModel.palette.indices.contains(colorIndex) {
            field.textColor = NSColor(cgColor: AnnotationModel.palette[colorIndex].cgColor) ?? .white
        } else {
            field.textColor = .white
        }
        field.placeholderString = "输入文字，Enter 确认"
        field.target = self
        field.action = #selector(textFieldCommit(_:))
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textFieldAnchor = annotationPoint
    }

    @objc private func textFieldCommit(_ sender: NSTextField?) {
        commitTextFieldIfNeeded()
    }

    private func commitTextFieldIfNeeded() {
        guard let field = textField, let anchor = textFieldAnchor, let session else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        textField = nil
        textFieldAnchor = nil
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }
        controller?.addAnnotation(AnnotationModel(
            shape: .text(anchor: anchor),
            colorIndex: session.colorIndex,
            strokeWidth: session.strokeWidth,
            text: text,
            index: nil,
            fontSize: CGFloat(session.textFontSize)
        ))
    }

    /// Esc 取消文字输入；返回是否发生了取消（调用方决定是否继续走 cancel 语义）
    func cancelTextEditingIfNeeded() -> Bool {
        guard textField != nil else { return false }
        textField?.removeFromSuperview()
        textField = nil
        textFieldAnchor = nil
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: - 键盘（共享 EditorKeyRouter + 本宿主内置键序）

    override func keyDown(with event: NSEvent) {
        // 编辑器自定义热键（⌘Z/H/O/P…）：共享分发逻辑（OverlayWindow 同源）。
        // 滚动截图是截图编辑器专属语义：这里忽略 scroll 键，S 仍当普通键。
        if textField == nil, let actionKey = EditorKeyRouter.matchHotkey(event, ignoringScroll: true) {
            EditorKeyRouter.perform(actionKey, actions: controller?.keyActions
                ?? EditorKeyRouter.Actions())
            return
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            controller?.toolbarAction(.cancel)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if textField != nil { commitTextFieldIfNeeded(); return }
            controller?.toolbarAction(.done)
        default:
            if textField == nil, let tool = EditorKeyRouter.tool(for: Int(event.keyCode)) {
                controller?.keyActions.selectTool(tool)
                return
            }
            super.keyDown(with: event)
        }
    }

    // MARK: - 绘制（编辑器所见 = 导出所得；翻转处理同 OverlayView.drawEditor）

    override func draw(_ dirtyRect: NSRect) {
        guard let session, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ptSize = controller?.imagePtSize ?? bounds.size

        ctx.saveGState()
        ctx.scaleBy(x: displayScale, y: displayScale)

        let annotations = session.store.annotations + (pendingAnnotation.map { [$0] } ?? [])

        // 1. 马赛克预览：已提交 + 拖拽中的 mosaic 都走与导出 composite 完全
        //    相同的像素化算法（CGRenderer.applyMosaic →「编辑器所见 = 导出所得」）
        let hasMosaic = annotations.contains { annotation in
            if case .mosaic = annotation.shape { return true }
            return false
        }
        let baseForDraw = hasMosaic
            ? CGRenderer.renderMosaicPreview(
                base: session.baseImage, annotations: annotations, scale: session.scale
            )
            : session.baseImage

        // 2. 底图：像素精确 1:1（Y-down 上下文需镜像一次再 draw）
        ctx.saveGState()
        ctx.translateBy(x: 0, y: ptSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(baseForDraw, in: CGRect(origin: .zero, size: ptSize))
        ctx.restoreGState()

        // 3. 标注层（同一渲染器 = 导出所见；原生 Y-down CTM，几何原点即视图原点）
        CGRenderer.render(
            annotations: annotations, in: ptSize, context: ctx, contextIsYDown: true
        )
        ctx.restoreGState()
    }
}

// MARK: - 文字输入委托（Enter 落库 / Esc 取消）

extension CollageEditorContentView: NSTextFieldDelegate {
    nonisolated func control(_: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        MainActor.assumeIsolated {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                commitTextFieldIfNeeded()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancelTextEditingIfNeeded()
                return true
            default:
                return false
            }
        }
    }
}
