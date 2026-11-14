import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 覆盖层窗口：无边框、透明、screenSaver 层级、全屏盖住单台显示器
@MainActor
final class OverlayWindow: NSWindow {
    // 无边框窗口默认 canBecomeKey=false，必须显式允许才能接收键盘事件
    override var canBecomeKey: Bool { true }

    let owningScreen: NSScreen

    init(screen: NSScreen, controller: OverlayController) {
        self.owningScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), controller: controller)
        contentView = view
    }

    /// 选区所在屏进入编辑模式（显示冻结底图 + 标注交互）
    func enterEditorMode(session: EditorSession) {
        (contentView as? OverlayView)?.enterEditorMode(session: session)
    }

    /// 滚动截图模式（滚动 HUD）
    func enterScrollMode() {
        (contentView as? OverlayView)?.enterScrollMode()
    }

    func exitScrollMode() {
        (contentView as? OverlayView)?.exitScrollMode()
    }
}

/// 覆盖层视图：蒙层 / 橡皮筋选框 / 尺寸角标 + 编辑态（冻结底图 + 标注 + 手势）
@MainActor
final class OverlayView: NSView {
    private unowned let controller: OverlayController

    private enum Phase: Equatable {
        case waitingForDrag
        case dragging(start: CGPoint)
        case confirmed    // 松手，等底图冻结
        case editing      // 编辑态（有 editorSession）
    }
    private var phase: Phase = .waitingForDrag

    /// 选区（视图本地坐标，Y 向上）
    private var selectionLocal: CGRect = .zero

    /// 编辑会话（编辑态非空）
    private var editorSession: EditorSession?

    /// 编辑态：选区在视图本地坐标（Y 向上）
    private var editorRectLocal: CGRect = .zero

    /// 拖拽中的标注预览（未确认，不入 store）
    private var pendingAnnotation: AnnotationModel?

    /// 滚动截图模式（controller 的 scrollController 非空）
    private(set) var scrollMode = false
    /// 滚动 HUD 显示的选区（本窗口负责的那块，可能是 nil=本屏无选区）
    private var scrollRectLocal: CGRect?

    /// 文字输入框（text 工具）
    private var textField: NSTextField?

    // 视觉常量
    private let dimAlpha: CGFloat = 0.25
    private let borderWidth: CGFloat = 1.5
    private let minSelectionSize: CGFloat = 4

    init(frame frameRect: NSRect, controller: OverlayController) {
        self.controller = controller
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }  // 统一 Y 向下（与标注几何一致）

    // MARK: - 编辑态切入

    func enterEditorMode(session: EditorSession) {
        editorSession = session
        phase = .editing
        // 全局选区 → 本地坐标（Y 向下）
        let global = session.selectionGlobal
        let frame = window?.frame ?? .zero
        editorRectLocal = CGRect(
            x: global.minX - frame.minX,
            y: frame.maxY - global.maxY,  // AppKit 全局 Y 向上 → 本地 Y 向下
            width: global.width,
            height: global.height
        )
        needsDisplay = true
    }

    func enterScrollMode() {
        scrollMode = true
        // ⚠️ 滚动事件必须穿透到下层 App（否则用户滚动的是我们的覆盖层，
        // 底下内容不动，拼接永远失败——e2e 实测 12 帧全静止的病例）
        window?.ignoresMouseEvents = true
        if let global = controller.scrollSelectionGlobal {
            let frame = window?.frame ?? .zero
            scrollRectLocal = CGRect(
                x: global.minX - frame.minX,
                y: frame.maxY - global.maxY,
                width: global.width,
                height: global.height
            )
        } else {
            scrollRectLocal = nil
        }
        needsDisplay = true
    }

    func exitScrollMode() {
        scrollMode = false
        window?.ignoresMouseEvents = false
        scrollRectLocal = nil
        needsDisplay = true
    }

    // MARK: - 光标

    override func resetCursorRects() {
        switch phase {
        case .editing:
            addCursorRect(editorRectLocal, cursor: .crosshair)
            addCursorRect(bounds.minus(editorRectLocal), cursor: .arrow)
        default:
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - 手势

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .waitingForDrag:
            phase = .dragging(start: point)
            selectionLocal = CGRect(origin: point, size: .zero)
            window?.makeKey()
            needsDisplay = true
        case .confirmed:
            if event.clickCount >= 2 {
                controller.perform(action: .copy)
            }
        case .editing:
            handleEditorMouseDown(point, event: event)
        case .dragging:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        switch phase {
        case .dragging(let start):
            let point = convert(event.locationInWindow, from: nil)
            let clamped = CGPoint(
                x: min(max(point.x, 0), bounds.width),
                y: min(max(point.y, 0), bounds.height)
            )
            selectionLocal = CGRect(
                x: min(start.x, clamped.x),
                y: min(start.y, clamped.y),
                width: abs(clamped.x - start.x),
                height: abs(clamped.y - start.y)
            )
            needsDisplay = true
        case .editing:
            handleEditorDragged(convert(event.locationInWindow, from: nil))
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        switch phase {
        case .dragging:
            if selectionLocal.width < minSelectionSize || selectionLocal.height < minSelectionSize {
                phase = .waitingForDrag
                selectionLocal = .zero
                needsDisplay = true
                return
            }
            phase = .confirmed
            needsDisplay = true
            // 松手即激活：capture 冻结 ~100-200ms 期间用户可能已按键，
            // 未激活 App 的键盘事件全给前台 App（用户实报：Enter/Esc 无响应）
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            let globalRect = convertToGlobalRect(selectionLocal)
            let screen = window?.screen ?? NSScreen.main!
            controller.didSelect(rect: globalRect, on: screen)
        case .editing:
            handleEditorMouseUp(convert(event.locationInWindow, from: nil))
        default:
            break
        }
    }

    // MARK: - 编辑态手势（标注绘制）

    private func handleEditorMouseDown(_ point: CGPoint, event: NSEvent) {
        guard let session = editorSession else { return }
        // 点击在选区外：忽略（R7：移出选区不生效）
        guard editorRectLocal.contains(point) else { return }

        switch session.currentTool {
        case .text:
            beginTextEditing(at: localToAnnotation(point))
        case .sequence:
            controller.addAnnotation(AnnotationModel(
                shape: .sequence(anchor: localToAnnotation(point)),
                colorIndex: session.colorIndex,
                strokeWidth: session.strokeWidth,
                index: session.store.consumeSequenceNumber()
            ))
        case .arrow:
            pendingStartPoint = localToAnnotation(point)
            pendingAnnotation = AnnotationModel(
                shape: .arrow(from: localToAnnotation(point), to: localToAnnotation(point)),
                colorIndex: session.colorIndex, strokeWidth: session.strokeWidth, text: nil, index: nil
            )
        case .rect, .mosaic:
            pendingStartPoint = localToAnnotation(point)
            let startRect = CGRect(origin: point, size: .zero)
            pendingAnnotation = AnnotationModel(
                shape: session.currentTool == .rect
                    ? .rect(annotationRect(startRect))
                    : .mosaic(annotationRect(startRect)),
                colorIndex: session.colorIndex, strokeWidth: session.strokeWidth, text: nil, index: nil
            )
        case .highlight:
            pendingStartPoint = localToAnnotation(point)
            pendingAnnotation = AnnotationModel(
                shape: .highlight(from: localToAnnotation(point), to: localToAnnotation(point)),
                colorIndex: session.colorIndex, strokeWidth: session.strokeWidth, text: nil, index: nil
            )
        }
        needsDisplay = true
    }

    private func handleEditorDragged(_ point: CGPoint) {
        guard var pending = pendingAnnotation else { return }
        let a = localToAnnotation(point)
        switch pending.shape {
        case .arrow(_, _):
            pending.shape = .arrow(from: pendingStartPoint ?? a, to: a)
        case .highlight(let from, _):
            pending.shape = .highlight(from: from, to: a)
        case .rect(let r):
            pending.shape = .rect(unionRect(r, a))
        case .mosaic(let r):
            pending.shape = .mosaic(unionRect(r, a))
        default:
            break
        }
        pendingAnnotation = pending
        needsDisplay = true
    }

    private var pendingStartPoint: CGPoint?

    private var phaseLabel: String {
        if scrollMode { return "scroll" }
        switch phase {
        case .waitingForDrag: return "wait"
        case .dragging: return "drag"
        case .confirmed: return "confirm"
        case .editing: return "edit"
        }
    }

    private func handleEditorMouseUp(_ point: CGPoint) {
        guard let pending = pendingAnnotation, let session = editorSession else { return }
        let a = localToAnnotation(point)
        var final = pending
        // 交互预览态 → 定稿几何
        switch pending.shape {
        case .arrow(let from, _):
            let start = pendingStartPoint ?? from
            if hypot(a.x - start.x, a.y - start.y) < 4 { pendingAnnotation = nil; needsDisplay = true; return }
            final.shape = .arrow(from: start, to: a)
        case .highlight(let from, _):
            if hypot(a.x - from.x, a.y - from.y) < 4 { pendingAnnotation = nil; needsDisplay = true; return }
            final.shape = .highlight(from: from, to: a)
        case .rect(let r):
            let rect = unionRect(r, a)
            if rect.width < 3 || rect.height < 3 { pendingAnnotation = nil; needsDisplay = true; return }
            final.shape = .rect(rect)
        case .mosaic(let r):
            let rect = unionRect(r, a)
            if rect.width < 3 || rect.height < 3 { pendingAnnotation = nil; needsDisplay = true; return }
            final.shape = .mosaic(rect)
        default: break
        }
        controller.addAnnotation(final)
        pendingAnnotation = nil
        pendingStartPoint = nil
        needsDisplay = true
    }

    // MARK: - 文字输入

    private func beginTextEditing(at annotationPoint: CGPoint) {
        // 已有输入框先落库
        commitTextFieldIfNeeded()

        let localPoint = annotationToLocal(annotationPoint)
        let field = NSTextField(frame: NSRect(
            x: localPoint.x, y: localPoint.y - 14,
            width: max(120, editorRectLocal.width - localPoint.x),
            height: 24
        ))
        field.font = .systemFont(ofSize: 14, weight: .medium)
        if let colorIndex = editorSession?.colorIndex, AnnotationModel.palette.indices.contains(colorIndex) {
            field.textColor = AnnotationModel.palette[colorIndex]
        }
        field.placeholderString = "输入文字，Enter 确认"
        field.target = self
        field.action = #selector(textFieldCommit(_:))
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        // 记录落点（确认时生成标注）
        textFieldAnchor = annotationPoint
    }

    private var textFieldAnchor: CGPoint?

    @objc private func textFieldCommit(_ sender: NSTextField?) {
        commitTextFieldIfNeeded()
    }

    private func commitTextFieldIfNeeded() {
        guard let field = textField, let anchor = textFieldAnchor, let session = editorSession else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        if !text.isEmpty {
            controller.addAnnotation(AnnotationModel(
                shape: .text(anchor: anchor),
                colorIndex: session.colorIndex,
                strokeWidth: session.strokeWidth,
                text: text
            ))
        }
        textField = nil
        textFieldAnchor = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        Log.logger(.overlay).debug("evt=overlay.keyDown key=\(event.keyCode, privacy: .public) phase=\(self.phaseLabel, privacy: .public)")
        // 文字输入态：普通键给输入框（first responder 已是 field，事件不会到这）
        switch Int(event.keyCode) {
        case kVK_Escape:
            if scrollMode {
                controller.perform(action: .cancel)
                return
            }
            if textField != nil {
                // 文字输入态的 Esc：取消文字（R4 语义在编辑器内优先作用于文字）
                textField?.removeFromSuperview()
                textField = nil
                textFieldAnchor = nil
                window?.makeFirstResponder(self)
                return
            }
            controller.perform(action: .cancel)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if scrollMode {
                controller.finishScrollForSelfTest()
                return
            }
            if phase == .editing {
                if textField != nil { commitTextFieldIfNeeded(); return }
                controller.perform(action: .copy)
            } else if phase == .confirmed {
                controller.perform(action: .copy)
            }
        case kVK_ANSI_S:
            if event.modifierFlags.contains(.command), phase == .editing || phase == .confirmed {
                controller.perform(action: .save)
            } else if phase == .editing, !event.modifierFlags.contains(.command) {
                // S = 滚动截图模式（需求 3：滚动截图）
                Log.event(.scroll, "scroll.keyReceived")
                controller.beginScrollCapture()
            } else {
                super.keyDown(with: event)
            }
        case kVK_ANSI_Z:
            if event.modifierFlags.contains(.command) {
                if event.modifierFlags.contains(.shift) {
                    controller.redoAnnotation()
                } else {
                    controller.undoAnnotation()
                }
            } else {
                super.keyDown(with: event)
            }
        case kVK_ANSI_H:
            if phase == .editing {
                controller.toggleToolbarVisibility()
            } else {
                super.keyDown(with: event)
            }
        default:
            // 热键 1-6 直选工具（R6）
            if phase == .editing,
               let tool = toolFor(keyCode: Int(event.keyCode)) {
                editorSession?.currentTool = tool
                controller.refreshToolbar()
                needsDisplay = true
                return
            }
            super.keyDown(with: event)
        }
    }

    private func toolFor(keyCode: Int) -> EditorSession.Tool? {
        let map = [
            kVK_ANSI_1: EditorSession.Tool.arrow,
            kVK_ANSI_2: EditorSession.Tool.rect,
            kVK_ANSI_3: EditorSession.Tool.text,
            kVK_ANSI_4: EditorSession.Tool.mosaic,
            kVK_ANSI_5: EditorSession.Tool.sequence,
            kVK_ANSI_6: EditorSession.Tool.highlight,
        ]
        return map[keyCode]
    }

    // MARK: - 坐标换算

    /// 视图本地（Y 向下，屏幕点）→ 标注几何（选区本地 Y 向下 point）
    private func localToAnnotation(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - editorRectLocal.minX, y: p.y - editorRectLocal.minY)
    }

    /// 标注几何 → 视图本地
    private func annotationToLocal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + editorRectLocal.minX, y: p.y + editorRectLocal.minY)
    }

    private func annotationRect(_ r: CGRect) -> CGRect {
        CGRect(
            x: r.minX - editorRectLocal.minX, y: r.minY - editorRectLocal.minY,
            width: r.width, height: r.height
        )
    }

    private func unionRect(_ r: CGRect, _ point: CGPoint) -> CGRect {
        CGRect(
            x: min(r.minX, point.x), y: min(r.minY, point.y),
            width: abs(point.x - (r.minX + r.width)) , height: abs(point.y - (r.minY + r.height))
        )
    }

    /// 本地选区矩形（Y 向下）→ AppKit 全局（Y 向上）
    private func convertToGlobalRect(_ local: CGRect) -> CGRect {
        guard let windowFrame = window?.frame else { return local }
        return CGRect(
            x: windowFrame.minX + local.minX,
            y: windowFrame.maxY - local.maxY,
            width: local.width,
            height: local.height
        )
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if scrollMode {
            drawScrollHUD(ctx: ctx)
            return
        }
        switch phase {
        case .editing:
            drawEditor(ctx: ctx)
        default:
            drawSelection(ctx: ctx)
        }
    }

    /// 滚动 HUD：选区框 + 帧/引导
    private func drawScrollHUD(ctx: CGContext) {
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.fill(bounds)
        guard let rect = scrollRectLocal else { return }
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(rect)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(rect)

        let frames = controller.scrollFrameCount
        let text = "滚动内容以捕获 · 已抓 \(frames) 帧 · Enter 完成拼接 · Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 10
        let size = CGSize(width: ceil(textSize.width + padding * 2), height: ceil(textSize.height + 8))
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.maxY + 10)
        if origin.y + size.height > bounds.height { origin.y = rect.minY - size.height - 10 }
        origin.x = min(max(origin.x, 8), bounds.width - 8 - size.width)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.fill(CGRect(origin: origin, size: size))
        (text as NSString).draw(at: CGPoint(x: origin.x + padding, y: origin.y + 4), withAttributes: attributes)
    }

    /// 选区阶段：蒙层 + 橡皮筋 + 角标 + 提示
    private func drawSelection(ctx: CGContext) {
        // 1. 蒙层
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        ctx.fill(bounds)

        guard selectionLocal.width > 0 || selectionLocal.height > 0 else { return }

        // 2. 挖空
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(selectionLocal)
        ctx.restoreGState()

        // 3. 描边
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(borderWidth)
        ctx.stroke(selectionLocal)

        // 4. 尺寸角标
        if phase != .waitingForDrag {
            let scale = window?.screen?.backingScaleFactor ?? 1
            let sizeText = "\(Int(selectionLocal.width * scale))×\(Int(selectionLocal.height * scale))"
            drawBadge(text: sizeText, below: selectionLocal)
        }
    }

    /// 编辑阶段：选区外蒙层 + 选区内冻结底图 + 标注层
    private func drawEditor(ctx: CGContext) {
        guard let session = editorSession else { return }

        // 1. 选区外蒙层（比选区阶段浅，弱化干扰）
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha * 0.7).cgColor)
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(editorRectLocal)
        ctx.restoreGState()

        // 2. 冻结底图：像素精确 1:1 绘制（不重采样不模糊）。
        // 坐标处理：CGContext.draw 假设 Y-up；本视图 Y-down ⇒ 局部翻转一次
        // 再 draw，方向即正确（病例三连：①不翻=倒置 ②NSImage.draw 按 point
        // size 重采样=模糊+错位 ③正确解=显式翻转+像素尺寸矩形）
        ctx.saveGState()
        ctx.clip(to: editorRectLocal)
        ctx.translateBy(x: editorRectLocal.minX, y: editorRectLocal.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -editorRectLocal.minX, y: -editorRectLocal.minY)
        ctx.interpolationQuality = .none
        ctx.draw(session.baseImage, in: editorRectLocal)
        // 3. 标注层（同一渲染器 = 导出所见）
        let annotations = session.store.annotations + (pendingAnnotation.map { [$0] } ?? [])
        CGRenderer.render(annotations: annotations, in: editorRectLocal.size, context: ctx, contextIsYDown: true)
        ctx.restoreGState()

        // 4. 选区描边（编辑态的画布边界）
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(editorRectLocal)

        // 5. 文字提示（无标注时）
        if session.store.annotations.isEmpty && pendingAnnotation == nil && textField == nil {
            drawHintText("Snapcut · 框选完成，可直接标注 · 1-6 切工具 · H 藏工具栏 · Enter 复制 · Esc 取消")
        }
    }

    private func drawBadge(text: String, below rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let size = CGSize(width: ceil(textSize.width + padding * 2), height: ceil(textSize.height + padding))
        var origin = CGPoint(x: rect.maxX - size.width, y: min(rect.maxY + 6, bounds.height - size.height))
        if origin.y + size.height > bounds.height { origin.y = rect.minY - size.height - 6 }
        if origin.y < 0 { origin.y = 4 }
        if origin.x < 0 { origin.x = 4 }
        let badgeRect = CGRect(origin: origin, size: size)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx?.addPath(path)
        ctx?.fillPath()
        (text as NSString).draw(at: CGPoint(x: origin.x + padding, y: origin.y + padding / 2), withAttributes: attributes)
    }

    private func drawHintText(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 8
        let size = CGSize(width: ceil(textSize.width + padding * 2), height: ceil(textSize.height + 4))
        var origin = CGPoint(
            x: editorRectLocal.midX - size.width / 2,
            y: editorRectLocal.maxY + 8
        )
        if origin.y + size.height > bounds.height {
            origin.y = editorRectLocal.minY - size.height - 8
        }
        origin.x = min(max(origin.x, 8), bounds.width - 8 - size.width)
        let rect = CGRect(origin: origin, size: size)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx?.fill(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil).boundingBox)
        (text as NSString).draw(at: CGPoint(x: origin.x + padding, y: origin.y + 2), withAttributes: attributes)
    }
}

// MARK: - 文字输入框委托（Enter 落库 / Esc 取消在 keyDown 里处理不了 field 的，走 doCommandBy）

extension OverlayView: NSTextFieldDelegate {
    nonisolated func control(_: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        MainActor.assumeIsolated {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                commitTextFieldIfNeeded()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                textField?.removeFromSuperview()
                textField = nil
                textFieldAnchor = nil
                window?.makeFirstResponder(self)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - 辅助

private extension NSRect {
    /// 粗粒度：编辑态选区外光标区域（功能先行，视觉后调）
    func minus(_ other: NSRect) -> NSRect { self }
}
