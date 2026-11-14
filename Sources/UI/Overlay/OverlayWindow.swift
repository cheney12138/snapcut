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

    /// 安装冻结帧（会话开始时的整屏静态图）
    func installFrozenImage(_ image: CGImage) {
        (contentView as? OverlayView)?.installFrozenImage(image)
    }

    /// 外部入口：整屏截图（⌘⇧S / 托盘菜单）
    func pickFullDisplay() {
        (contentView as? OverlayView)?.pickFullDisplayExternally()
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

    /// 冻结帧（会话开始时的整屏静态画面；有它就不再实时看桌面）
    private var frozenImage: CGImage?

    /// 编辑态手势（改选区尺寸 / 整体移动）
    private enum EditGesture {
        case none
        case resize(edge: SelectionEdge, startRect: CGRect)
        case move(startRect: CGRect, startPoint: CGPoint)
    }
    private var editGesture: EditGesture = .none
    /// 空格按下（临时切「整体移动」）
    private var spacePressed = false
    /// 悬停中的手柄（绘制手柄高亮 + 光标反馈）
    private var hoverEdge: SelectionEdge?
    /// 放大镜采样器（安装冻结帧时构建一次）
    private var frozenSampler: FrozenSampler?
    /// 光标本地坐标（放大镜跟随；Y 向下）
    private var cursorLocal: CGPoint = .zero

    /// 悬停命中的窗口（窗口截图预览 + 单击整窗）
    private var hovered: HoveredWindow?
    private var hoveredLocalRect: CGRect?
    private var hoverProbePoint: CGPoint = .zero
    private var hoverProbeTime: CFTimeInterval = 0
    /// 单击整窗的延迟任务（220ms 双击宽限：双击=全屏，单击=整窗）
    private var pendingWindowCapture: DispatchWorkItem?
    private var trackingAreaRef: NSTrackingArea?

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

    /// 安装冻结帧并重绘（"屏幕定住"效果的唯一来源）
    func installFrozenImage(_ image: CGImage) {
        frozenImage = image
        // 放大镜/取色用：一次性解像素，之后 O(1) 采样（禁止实时屏捕）
        frozenSampler = FrozenSampler(image: image)
        needsDisplay = true
    }

    // MARK: - 悬停跟踪（窗口高亮）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let local = convert(event.locationInWindow, from: nil)
        cursorLocal = local
        if scrollMode { return }
        switch phase {
        case .waitingForDrag:
            updateHover(at: local)
            needsDisplay = true      // 放大镜跟随
        case .editing:
            updateHoverEdge(at: local)
        default:
            break
        }
    }

    /// 编辑态：光标是否压在手柄上（决定光标形状 + 手柄高亮）
    private func updateHoverEdge(at local: CGPoint) {
        let rect = editorRectLocal
        let edge: SelectionEdge? = (rect.width >= SelectionGeometry.handleVisibilityThreshold
            || rect.height >= SelectionGeometry.handleVisibilityThreshold)
            ? SelectionGeometry.edge(atLocal: local, in: rect)
            : nil
        guard edge != hoverEdge else { return }
        hoverEdge = edge
        if let edge {
            switch edge {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            case .topLeft, .bottomRight: NSCursor.crosshair.set()
            case .topRight, .bottomLeft: NSCursor.crosshair.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hovered != nil else { return }
        clearHover()
    }

    /// 鼠标位置的窗口探测（50ms 节流：窗口枚举有成本）
    private func updateHover(at local: CGPoint) {
        let now = CACurrentMediaTime()
        let moved = abs(local.x - hoverProbePoint.x) > 1.5 || abs(local.y - hoverProbePoint.y) > 1.5
        guard moved || now - hoverProbeTime > 0.08 else { return }
        hoverProbePoint = local
        hoverProbeTime = now
        guard let frame = window?.frame else { return }
        let global = CGPoint(x: frame.minX + local.x, y: frame.maxY - local.y)
        let found = WindowLocator.window(atGlobalPoint: global, excludingPID: getpid())
        guard found != hovered else { return }
        hovered = found
        hoveredLocalRect = found.map {
            CGRect(
                x: $0.rectGlobal.minX - frame.minX,
                y: frame.maxY - $0.rectGlobal.maxY,
                width: $0.rectGlobal.width,
                height: $0.rectGlobal.height
            )
        }
        needsDisplay = true
    }

    private func clearHover() {
        hovered = nil
        hoveredLocalRect = nil
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
            // 双击 = 当前显示器全屏截图（与单击整窗共用鼠标时靠宽限区分）
            if event.clickCount >= 2 {
                pendingWindowCapture?.cancel()
                pendingWindowCapture = nil
                pickFullDisplay()
                return
            }
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
                // 单击（未拖动）：命中窗口 → 220ms 宽限后整窗截图
                // （宽限是为了让双击能被识别为全屏，见 mouseDown clickCount>=2）
                if let target = hovered {
                    scheduleWindowCapture(target)
                }
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

    // MARK: - 整窗 / 全屏采集

    private func scheduleWindowCapture(_ target: HoveredWindow) {
        pendingWindowCapture?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .waitingForDrag else { return }
            self.pickWindow(target)
        }
        pendingWindowCapture = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func pickWindow(_ target: HoveredWindow) {
        guard let screen = window?.screen else { return }
        pendingWindowCapture = nil
        if let frame = window?.frame {
            selectionLocal = CGRect(
                x: target.rectGlobal.minX - frame.minX,
                y: frame.maxY - target.rectGlobal.maxY,
                width: target.rectGlobal.width,
                height: target.rectGlobal.height
            )
        }
        phase = .confirmed
        needsDisplay = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        Log.event(.overlay, "overlay.pick.window", [
            "owner": target.ownerName,
            "title": target.title,
            "size": "\(Int(target.rectGlobal.width))x\(Int(target.rectGlobal.height))",
        ])
        controller.didSelect(rect: target.rectGlobal, on: screen)
    }

    private func pickFullDisplay() {
        guard let screen = window?.screen else { return }
        selectionLocal = bounds
        phase = .confirmed
        needsDisplay = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        Log.event(.overlay, "overlay.pick.fullscreen", [
            "screen": "\(Int(screen.frame.width))x\(Int(screen.frame.height))",
        ])
        controller.didSelect(rect: screen.frame, on: screen)
    }

    /// 外部入口（热键 ⌘⇧S / 托盘菜单）：直接整屏
    func pickFullDisplayExternally() {
        guard phase == .waitingForDrag else { return }
        pickFullDisplay()
    }

    // MARK: - 编辑态手势（标注绘制）

    private func handleEditorMouseDown(_ point: CGPoint, event: NSEvent) {
        guard let session = editorSession else { return }

        // 1) 手柄优先：拖手柄改选区（Snow Shot 同款「快速选区修改」）
        if let edge = SelectionGeometry.edge(atLocal: point, in: editorRectLocal) {
            editGesture = .resize(edge: edge, startRect: editorRectLocal)
            Log.event(.overlay, "selection.resize.begin", ["edge": "\(edge)"])
            return
        }

        // 2) 空格 + 选区内拖拽 = 整体移动
        if spacePressed && editorRectLocal.contains(point) {
            editGesture = .move(startRect: editorRectLocal, startPoint: point)
            return
        }

        // 3) 常规标注：点击在选区外忽略（R7：移出选区不生效）
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
        switch editGesture {
        case .resize(let edge, let startRect):
            editorRectLocal = SelectionGeometry.resized(
                startRect, edge: edge, to: point, limit: bounds
            )
            needsDisplay = true
            return
        case .move(let startRect, let startPoint):
            let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            editorRectLocal = SelectionGeometry.moved(startRect, by: delta, limit: bounds)
            needsDisplay = true
            return
        case .none:
            break
        }

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

    // MARK: - 选区调整提交

    /// 当前选区在会话里的本地坐标（Y 向下），用于算标注平移量
    private func sessionLocalRect() -> CGRect {
        guard let session = editorSession, let frame = window?.frame else { return .zero }
        let g = session.selectionGlobal
        return CGRect(
            x: g.minX - frame.minX,
            y: frame.maxY - g.maxY,
            width: g.width, height: g.height
        )
    }

    private func commitSelectionResize() {
        guard editorSession != nil, let screen = window?.screen else { return }
        let oldLocal = sessionLocalRect()
        let newLocal = editorRectLocal
        let offset = SelectionGeometry.annotationOffset(old: oldLocal, new: newLocal)
        let global = convertToGlobalRect(newLocal)
        controller.adjustSelection(to: global, on: screen, annotationOffset: offset)
        Log.event(.overlay, "selection.resize.commit", [
            "ptW": "\(Int(newLocal.width))", "ptH": "\(Int(newLocal.height))",
        ])
    }

    private func commitSelectionMove() {
        guard editorSession != nil, let screen = window?.screen else { return }
        let oldLocal = sessionLocalRect()
        let newLocal = editorRectLocal
        let offset = SelectionGeometry.annotationOffset(old: oldLocal, new: newLocal)
        let global = convertToGlobalRect(newLocal)
        controller.adjustSelection(to: global, on: screen, annotationOffset: offset)
    }

    /// 键盘微调选区（编辑态方向键）
    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        let newLocal = SelectionGeometry.nudged(editorRectLocal, dx: dx, dy: dy, limit: bounds)
        guard newLocal != editorRectLocal else { return }
        editorRectLocal = newLocal
        needsDisplay = true
        commitSelectionMove()
    }

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
        // 选区调整提交：重裁底图 + 平移标注 + 工具栏跟随
        if case .none = editGesture {} else {
            if case .move = editGesture {
                // 移动不改尺寸 → 不重裁，只更新全局选区
                commitSelectionMove()
            } else {
                commitSelectionResize()
            }
            editGesture = .none
            pendingAnnotation = nil
            needsDisplay = true
            return
        }
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
            field.textColor = NSColor(cgColor: AnnotationModel.palette[colorIndex].cgColor) ?? .red
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

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space {
            spacePressed = false
            return
        }
        super.keyUp(with: event)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        Log.logger(.overlay).debug("evt=overlay.keyDown key=\(event.keyCode, privacy: .public) phase=\(self.phaseLabel, privacy: .public)")
        // 文字输入态：普通键给输入框（first responder 已是 field，事件不会到这）
        // 空格：编辑态临时切「整体移动」（按下期间有效）
        if Int(event.keyCode) == kVK_Space {
            if phase == .editing { spacePressed = true }
            return
        }
        // 方向键：编辑态微调选区（Shift = 10pt）
        if phase == .editing, [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(Int(event.keyCode)) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch Int(event.keyCode) {
            case kVK_LeftArrow: nudgeSelection(dx: -step, dy: 0)
            case kVK_RightArrow: nudgeSelection(dx: step, dy: 0)
            case kVK_UpArrow: nudgeSelection(dx: 0, dy: -step)
            case kVK_DownArrow: nudgeSelection(dx: 0, dy: step)
            default: break
            }
            return
        }
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
        case kVK_ANSI_O:
            if phase == .editing, !event.modifierFlags.contains(.command) {
                controller.toolbarAction(.ocr)
                return
            }
            super.keyDown(with: event)
        case kVK_ANSI_P:
            if phase == .editing, !event.modifierFlags.contains(.command) {
                controller.toolbarAction(.pin)
                return
            }
            super.keyDown(with: event)
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
            drawSelectionOverlays(ctx: ctx)
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

    /// 选区阶段：冻结帧 + 蒙层 + 橡皮筋 + 角标 + 窗口悬停高亮
    private func drawSelection(ctx: CGContext) {
        // 0. 冻结帧铺满（与编辑器同样的翻转处理：Y-down 上下文需镜像一次）
        if let frozen = frozenImage {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(frozen, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        }
        // 1. 蒙层
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        ctx.fill(bounds)

        // 1.5 窗口悬停高亮：挖出该窗口区域（提亮）+ 系统蓝描边 + 应用名角标
        let selectionEmpty = selectionLocal.width <= 0 && selectionLocal.height <= 0
        if selectionEmpty, let rect = hoveredLocalRect, let target = hovered {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fill(rect)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(rect.insetBy(dx: 1, dy: 1))
            let label = target.title.isEmpty ? target.ownerName : "\(target.ownerName) · \(target.title)"
            drawWindowBadge(text: label, below: rect)
            return
        }

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

    /// 选区阶段收尾：放大镜（独立方法，draw() 里在蒙层/选框之后调用）
    private func drawSelectionOverlays(ctx: CGContext) {
        drawMagnifier(ctx: ctx)
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

        // 4.5 手柄（选区足够大时）：8 个白色方块，悬停的加粗
        drawSelectionHandles(ctx: ctx)

        // 5. 文字提示（无标注时）
        if session.store.annotations.isEmpty && pendingAnnotation == nil && textField == nil {
            drawHintText("Snapcut · 框选完成，可直接标注 · 1-6 切工具 · H 藏工具栏 · Enter 复制 · Esc 取消")
        }
    }

    /// 窗口名角标（白底深字胶囊，贴窗口左上角内侧）
    ///
    /// ⚠️ 不能写 `NSColor.labelColor`：本覆盖层是 dark appearance，labelColor 解析成
    /// 白色 ⇒ 白底白字不可读（实拍病例）。固定深色文字 + 白底。
    private func drawWindowBadge(text: String, below rect: CGRect) {
        let maxChars = 42
        let shown = text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        ]
        let textSize = (shown as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let size = CGSize(width: ceil(textSize.width + padding * 2), height: ceil(textSize.height + 4))
        // 贴在窗口内侧左上（外侧会压到菜单栏）
        var origin = CGPoint(x: rect.minX + 8, y: rect.minY + 8)
        origin.x = min(max(origin.x, 4), bounds.width - size.width - 4)
        let badgeRect = CGRect(origin: origin, size: size)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(NSColor.white.withAlphaComponent(0.94).cgColor)
        ctx?.addPath(path)
        ctx?.fillPath()
        (shown as NSString).draw(at: CGPoint(x: origin.x + padding, y: origin.y + 2), withAttributes: attributes)
    }

    /// 8 向手柄（四角 + 四边中点）
    private func drawSelectionHandles(ctx: CGContext) {
        let rect = editorRectLocal
        guard rect.width >= SelectionGeometry.handleVisibilityThreshold
                || rect.height >= SelectionGeometry.handleVisibilityThreshold else { return }
        let size: CGFloat = 7
        let points: [(CGPoint, SelectionEdge)] = [
            (CGPoint(x: rect.minX, y: rect.minY), .topLeft),
            (CGPoint(x: rect.midX, y: rect.minY), .top),
            (CGPoint(x: rect.maxX, y: rect.minY), .topRight),
            (CGPoint(x: rect.minX, y: rect.midY), .left),
            (CGPoint(x: rect.maxX, y: rect.midY), .right),
            (CGPoint(x: rect.minX, y: rect.maxY), .bottomLeft),
            (CGPoint(x: rect.midX, y: rect.maxY), .bottom),
            (CGPoint(x: rect.maxX, y: rect.maxY), .bottomRight),
        ]
        for (center, edge) in points {
            let isHot = hoverEdge == edge
            let s = isHot ? size + 3 : size
            let box = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(box)
        }
    }

    /// 放大镜（选区阶段；纯离线采样冻结帧，绝不实时屏捕）
    private func drawMagnifier(ctx: CGContext) {
        guard let sampler = frozenSampler,
              let frozen = frozenImage,
              let frame = window?.frame,
              let screen = window?.screen else { return }
        MagnifierPainter.draw(
            sampler: sampler,
            cursorLocal: cursorLocal,
            bounds: bounds,
            imageSize: CGSize(width: frozen.width, height: frozen.height),
            screenPoints: screen.frame.size,
            globalOrigin: CGPoint(x: frame.minX, y: screen.frame.maxY),
            ctx: ctx
        )
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
