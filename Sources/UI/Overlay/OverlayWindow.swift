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

    /// 窗口层事件总闸 + 起拖兜底（用户病例 2026-11-16 三报「唤起后没立马框选」）
    /// 根因（日志钉死）：mouseDown 落在 keyWin=false 的窗上（key 尚未稳定/
    /// 光标屏判定竞速）——AppKit 丢弃非 key 窗的 down 到 responder，但拖拽
    /// 会话继续把 drag 喂给窗（sendEvent 收到、view 收不到）。因此兜底必须
    /// 在窗层：drag 到达且 view 仍在 waitingForDrag 时，窗直接驱动 view 起拖。
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            Log.event(.overlay, "win.event", [
                "type": "\(event.type == .leftMouseDown ? "down" : (event.type == .leftMouseUp ? "up" : "drag"))",
                "winId": "\(Unmanaged.passUnretained(self).toOpaque())",
                "keyWin": "\(isKeyWindow)",
                "appKey": "\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")",
                "active": "\(NSApp.isActive)",
            ])
        default: break
        }
        // 起拖兜底（down 或 drag 任一到达 + view 空闲）：view 的 mouseDown/
        // mouseDragged 在非 key 窗时收不到，窗层补齐（起拖只做一次，view
        // phase 变化后 guard 挡住）
        if event.type == .leftMouseDown || event.type == .leftMouseDragged {
            // 冷启动首激活（用户病例 2026-11-17 终报：重启后第一次唤起，
            // 热键回调的 activate 被系统忽略——LSUIElement 无手势上下文；
            // 3.1s 未激活。真实点击=手势上下文，系统必接受——按下瞬间激活）
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            if let view = contentView as? OverlayView {
                view.beginDragIfNeeded(from: view.convert(event.locationInWindow, from: nil))
            }
        }
        super.sendEvent(event)
    }

    /// 选区所在屏进入编辑模式（显示冻结底图 + 标注交互）
    func enterEditorMode(session: EditorSession) {
        (contentView as? OverlayView)?.enterEditorMode(session: session)
    }

    /// 滚动截图模式（区域 outline + 光晕脉动）
    func enterScrollMode() {
        (contentView as? OverlayView)?.enterScrollMode()
    }

    /// 退出编辑模式（enterEditor 幂等重入用：回蒙层态）
    func exitEditorIfNeeded() {
        (contentView as? OverlayView)?.exitEditorIfNeeded()
    }

    func exitScrollMode() {
        (contentView as? OverlayView)?.exitScrollMode()
    }

    /// 滚动采集：区域随内容生长（全局矩形）
    func updateScrollRegion(_ global: CGRect) {
        (contentView as? OverlayView)?.updateScrollRegion(global: global)
    }

    /// 到底：底缘 2pt 绿条 + 光晕定格
    func setScrollBottomReached() {
        (contentView as? OverlayView)?.setScrollBottomReached()
    }

    /// 到底撤销（用户到底后又继续滚）：清绿条恢复采集光晕
    func clearScrollBottomReached() {
        (contentView as? OverlayView)?.clearScrollBottomReached()
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
    /// 采集区域边缘光晕 + 底缘绿条（motion.pulse；替代旧 draw 内画框）
    private var scrollGlowView: ScrollRegionGlowView?

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
    private var draggedEventCount = 0
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
    /// 蒙层：0.22（审查：0.25 → 轻 12%，选区提亮不变）
    private let dimAlpha: CGFloat = 0.22
    private let borderWidth: CGFloat = 1.5
    private let minSelectionSize: CGFloat = 4
    /// 窗口悬停高亮淡入起点（审查：悬停反馈应「亮起」不是「出现」，0.12s）
    private var hoverFadeStart: CFTimeInterval = 0

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
        installScrollGlow()
        needsDisplay = true
    }

    func exitScrollMode() {
        scrollMode = false
        window?.ignoresMouseEvents = false
        scrollRectLocal = nil
        scrollGlowView?.removeFromSuperview()
        scrollGlowView = nil
        needsDisplay = true
    }

    /// 退出编辑模式（enterEditor 幂等重入用）：phase 回蒙层态
    func exitEditorIfNeeded() {
        if case .editing = phase {
            phase = .waitingForDrag
            needsDisplay = true
        }
    }

    /// 采集区域生长（全局矩形 → 本地）
    func updateScrollRegion(global: CGRect) {
        guard let frame = window?.frame else { return }
        let local = CGRect(
            x: global.minX - frame.minX,
            y: frame.maxY - global.maxY,
            width: global.width,
            height: global.height
        )
        scrollRectLocal = local
        scrollGlowView?.update(rect: local)
    }

    /// 到底确认态（底缘绿条亮起，光晕定格）
    func setScrollBottomReached() {
        scrollGlowView?.setBottomReached()
    }

    func clearScrollBottomReached() {
        scrollGlowView?.clearBottomReached()
    }

    /// 边缘光晕层（scene 06：outline 1.5pt accent + 3.5pt soft 外圈 + motion.pulse）
    private func installScrollGlow() {
        guard let rect = scrollRectLocal, scrollGlowView == nil else { return }
        let glow = ScrollRegionGlowView()
        glow.frame = rect
        addSubview(glow)
        scrollGlowView = glow
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
        if found != nil { hoverFadeStart = CACurrentMediaTime() }
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
        hoverFadeStart = 0
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

    /// 窗层兜底起拖（幂等）：down/drag 到达窗时若还没起拖就立即起。
    /// 覆盖两种丢 mouseDown 的时序：①冻结窗口期按下（窗未上屏）；②按下落在
    /// keyWin=false 的窗（AppKit 丢弃到 responder 但拖拽会话仍喂窗）。
    /// 由 OverlayWindow.sendEvent 调用（窗层事件总闸）；view 自己的
    /// mouseDown 正常路径不受影响（phase guard 幂等）。
    func beginDragIfNeeded(from point: CGPoint) {
        guard phase == .waitingForDrag else { return }
        phase = .dragging(start: point)
        selectionLocal = CGRect(origin: point, size: .zero)
        Log.event(.overlay, "overlay.drag.recover", ["pt": "\(Int(point.x)),\(Int(point.y))"])
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        Log.event(.overlay, "overlay.mousedown", [
            "phase": phaseLabel, "pt": "\(Int(point.x)),\(Int(point.y))",
        ])
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
            // 双击=copy 已移除（用户裁定 2026-11-17「我还没 Enter，贴图就不要
            // 生成」——确认动作只走 Enter/工具栏按钮，鼠标双击不得隐式完成）
            break
        case .editing:
            handleEditorMouseDown(point, event: event)
        case .dragging:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        draggedEventCount += 1
        Log.event(.overlay, "overlay.dragged", [
            "n": "\(draggedEventCount)",
            "pt": "\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y))",
            "key": "\(window?.isKeyWindow ?? false)",
            "viewId": "\(Unmanaged.passUnretained(self).toOpaque())",
            "sel": "\(Int(selectionLocal.width))x\(Int(selectionLocal.height))",
        ])
        switch phase {
        case .dragging(let start):
            let point = convert(event.locationInWindow, from: nil)
            var clamped = CGPoint(
                x: min(max(point.x, 0), bounds.width),
                y: min(max(point.y, 0), bounds.height)
            )
            // Shift：锁 1:1（以按下点为锚，取较短边，方向跟随鼠标）
            if event.modifierFlags.contains(.shift) {
                let dx = clamped.x - start.x
                let dy = clamped.y - start.y
                let side = min(abs(dx), abs(dy))
                clamped = CGPoint(
                    x: start.x + (dx < 0 ? -side : side),
                    y: start.y + (dy < 0 ? -side : side)
                )
            }
            cursorLocal = clamped
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
            Log.event(.overlay, "overlay.mouseup", [
                "sel": "\(Int(selectionLocal.minX)),\(Int(selectionLocal.minY)),\(Int(selectionLocal.width)),\(Int(selectionLocal.height))",
                "phase": phaseLabel,
                "objId": "\(Unmanaged.passUnretained(self).toOpaque())",
            ])
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
        controller.didSelect(rect: target.rectGlobal, on: screen, windowID: target.windowID)
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
        Log.event(.editor, "editor.mousedown", [
            "pt": "\(Int(point.x)),\(Int(point.y))",
            "tool": editorSession?.currentTool.label ?? "none",
            "contains": "\(editorRectLocal.contains(point))",
            "clicks": "\(event.clickCount)",
        ])
        guard let session = editorSession else { return }

        // 1) 手柄优先：拖手柄改选区（Snow Shot 同款「快速选区修改」）
        if let edge = SelectionGeometry.edge(atLocal: point, in: editorRectLocal) {
            editGesture = .resize(edge: edge, startRect: editorRectLocal)
            Log.event(.overlay, "selection.resize.begin", ["edge": "\(edge)"])
            return
        }

        // 2) 空格 + 选区内拖拽 = 整体移动（保留）
        if spacePressed && editorRectLocal.contains(point) {
            editGesture = .move(startRect: editorRectLocal, startPoint: point)
            return
        }

        // 3) 常规标注：点击在选区外忽略（R7：移出选区不生效）
        guard editorRectLocal.contains(point) else { return }

        switch session.currentTool {
        case .none:
            // 无工具默认态（用户裁定）：拖动 = 整体移动选区（不用按空格）
            editGesture = .move(startRect: editorRectLocal, startPoint: point)
        case .text:
            beginTextEditing(at: localToAnnotation(point))
        case .sequence:
            controller.addAnnotation(AnnotationModel(
                shape: .sequence(anchor: localToAnnotation(point)),
                colorIndex: session.colorIndex,
                strokeWidth: session.strokeWidth,
                index: session.store.nextSequenceNumber()
            ))
        case .arrow:
            pendingStartPoint = localToAnnotation(point)
            pendingAnnotation = AnnotationModel(
                shape: .arrow(from: localToAnnotation(point), to: localToAnnotation(point)),
                colorIndex: session.colorIndex, strokeWidth: session.strokeWidth, text: nil, index: nil
            )
        case .rect, .mosaic:
            Log.event(.editor, "editor.shape.begin", [
            "tool": session.currentTool.label,
            "a0": "\(localToAnnotation(point))",
            "erl": "\(Int(editorRectLocal.minX)),\(Int(editorRectLocal.minY)),\(Int(editorRectLocal.width)),\(Int(editorRectLocal.height))",
        ])
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
        case .ellipse:
            // 圆心圈选：按下点 = 圆心，拖动半径实时更新
            pendingStartPoint = localToAnnotation(point)
            let c = localToAnnotation(point)
            pendingAnnotation = AnnotationModel(
                shape: .ellipse(center: c, radiusX: 0, radiusY: 0),
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
        Log.event(.editor, "editor.drag", [
            "pt": "\(Int(point.x)),\(Int(point.y))",
            "a": "\(Int(a.x)),\(Int(a.y))",
            "erl": "\(Int(editorRectLocal.minX)),\(Int(editorRectLocal.minY)),\(Int(editorRectLocal.width)),\(Int(editorRectLocal.height))",
        ])
        switch pending.shape {
        case .arrow(_, _):
            pending.shape = .arrow(from: pendingStartPoint ?? a, to: a)
        case .highlight(let from, _):
            pending.shape = .highlight(from: from, to: a)
        case .rect:
            pending.shape = .rect(rectFromPoints(pendingStartPoint ?? a, a))
        case .mosaic:
            pending.shape = .mosaic(rectFromPoints(pendingStartPoint ?? a, a))
        case .ellipse(let center, _, _):
            pending.shape = .ellipse(
                center: center,
                radiusX: a.x - center.x,
                radiusY: a.y - center.y
            )
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

    /// 选区调整后夺回键盘路由（病例：拖手柄后 frontmost 变回终端 App，
    /// 之后的 Enter/Esc/方向键全部落到别的 App，编辑器看起来"僵死"）
    private func reclaimKeyboard() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        controller.ensureActivation(reason: "selection.adjust")
        Log.event(.editor, "editor.focus.reclaim", [
            "active": "\(NSApp.isActive)",
            "keyWin": "\(window?.isKeyWindow ?? false)",
            "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?",
        ])
    }

    private func commitSelectionResize() {
        guard editorSession != nil, let screen = window?.screen else { return }
        let oldLocal = sessionLocalRect()
        let newLocal = editorRectLocal
        let offset = SelectionGeometry.annotationOffset(old: oldLocal, new: newLocal)
        let global = convertToGlobalRect(newLocal)
        controller.adjustSelection(to: global, on: screen, annotationOffset: offset)
        reclaimKeyboard()
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
        reclaimKeyboard()
    }

    /// 取色：采样冻结帧光标处像素 → 写剪贴板（hex）→ 结束会话
    private func copyColorUnderCursor() {
        guard let sampler = frozenSampler,
              let frozen = frozenImage else { return }
        let px = Int(cursorLocal.x / bounds.width * CGFloat(frozen.width))
        let py = Int(cursorLocal.y / bounds.height * CGFloat(frozen.height))
        let hex = sampler.hex(x: px, y: py)
        guard hex.hasPrefix("#"), hex.count == 7 else { return }
        AppCoordinatorShared.deps?.clipboard.writeText(hex)
        Log.event(.overlay, "overlay.copyColor", ["hex": hex, "x": "\(px)", "y": "\(py)"])
        controller.perform(action: .cancel)
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
        _ = finalizePendingAnnotation(at: point)
    }

    /// 拖拽标注定稿（mouseUp 正常路径与导出 flush 共用）：
    /// 返回 true = 有标注落库。非法几何（箭头/高亮 <4pt、矩形 <3px）视为
    /// 用户放弃，静默丢弃。
    /// 收口背景（用户病例 2026-11-15）：拖完箭头立即按 Enter，导出图无箭头
    /// ——mouseUp 与 keyDown 的事件时序在触摸板上不可靠，渲染前必须 flush。
    @discardableResult
    private func finalizePendingAnnotation(at point: CGPoint) -> Bool {
        guard let pending = pendingAnnotation, let session = editorSession else { return false }
        let a = localToAnnotation(point)
        var final = pending
        switch pending.shape {
        case .arrow(let from, _):
            let start = pendingStartPoint ?? from
            if hypot(a.x - start.x, a.y - start.y) < 4 { pendingAnnotation = nil; needsDisplay = true; return false }
            final.shape = .arrow(from: start, to: a)
        case .highlight(let from, _):
            if hypot(a.x - from.x, a.y - from.y) < 4 { pendingAnnotation = nil; needsDisplay = true; return false }
            final.shape = .highlight(from: from, to: a)
        case .rect:
            let rect = rectFromPoints(pendingStartPoint ?? a, a)
            if rect.width < 3 || rect.height < 3 { pendingAnnotation = nil; needsDisplay = true; return false }
            final.shape = .rect(rect)
        case .mosaic:
            let rect = rectFromPoints(pendingStartPoint ?? a, a)
            if rect.width < 3 || rect.height < 3 { pendingAnnotation = nil; needsDisplay = true; return false }
            final.shape = .mosaic(rect)
        case .ellipse(let center, let rx, let ry):
            if abs(rx) < 2 || abs(ry) < 2 { pendingAnnotation = nil; needsDisplay = true; return false }
            final.shape = .ellipse(center: center, radiusX: rx, radiusY: ry)
        default: return false
        }
        Log.event(.editor, "editor.shape.commit", [
            "shape": "\(final.shape)", "color": "\(final.color)",
        ])
        controller.addAnnotation(final)
        pendingAnnotation = nil
        pendingStartPoint = nil
        needsDisplay = true
        return true
    }

    /// 导出前统一 flush（唯一收口点，OverlayController 各导出路径调用）。
    /// 病例二轮（2026-11-15 实录）：拖到 (273,103) 立即 Enter——mouseUp 缺席，
    /// flush 用 cursorLocal（mouseMoved 旧值，≈起点）重算 → hypot<4 判「用户
    /// 放弃」drop。正确语义：pendingAnnotation 的 shape 已随每次 drag 更新
    /// （draw 渲染的就是它 = 用户所见），直接提交 pending 即可。
    func flushPendingAnnotationForExport() {
        guard let pending = pendingAnnotation, let session = editorSession else { return }
        // 合法性只对「零尺寸」形状丢弃；已拖出的几何（drag 更新过）直接落库
        var final = pending
        switch pending.shape {
        case .arrow(let from, let to):
            if hypot(to.x - from.x, to.y - from.y) < 4 {
                Log.event(.editor, "editor.shape.flush.drop", [:])
                cancelPendingLocal()
                return
            }
            final.shape = .arrow(from: from, to: to)
        case .highlight(let from, let to):
            if hypot(to.x - from.x, to.y - from.y) < 4 {
                Log.event(.editor, "editor.shape.flush.drop", [:])
                cancelPendingLocal()
                return
            }
            final.shape = .highlight(from: from, to: to)
        case .rect(let r), .mosaic(let r):
            if r.width < 3 || r.height < 3 {
                Log.event(.editor, "editor.shape.flush.drop", [:])
                cancelPendingLocal()
                return
            }
            final.shape = pending.shape
        default:
            return
        }
        Log.event(.editor, "editor.shape.commit", [
            "shape": "\(final.shape)", "color": "\(final.color)", "via": "flush",
        ])
        controller.addAnnotation(final)
        pendingAnnotation = nil
        pendingStartPoint = nil
        needsDisplay = true
    }

    private func cancelPendingLocal() {
        pendingAnnotation = nil
        pendingStartPoint = nil
        needsDisplay = true
    }

    // MARK: - 文字输入

    /// 4 档字号（与 session.textFontSize 同源）
    private static let textFontSizes: [Int] = [12, 14, 17, 21]

    /// 浮动字号选择条（磨砂玻璃小条，与工具栏同一视觉家族：
    /// hudWindow 材质 + 60% 深着色 + 0.5pt 白 16% 描边；点选即改 session 档位并实时套到输入框）
    private var fontSizePicker: FontSizeBarView?

    private func beginTextEditing(at annotationPoint: CGPoint) {
        // 已有输入框先落库
        commitTextFieldIfNeeded()

        let pointSize = CGFloat(editorSession?.textFontSize
            ?? OverlayView.textFontSizes[1])
        let localPoint = annotationToLocal(annotationPoint)
        // §10-9 落地：无底透明框 + 0.5pt 当前标注色 α.60 描边（描边色 =「这段字会用
        // 什么颜色」的语义）；placeholder 删除（空框 + caret 即最强「请输入」）
        let field = GlassTextField(frame: NSRect(
            x: localPoint.x, y: localPoint.y - 16,
            width: max(160, editorRectLocal.width - localPoint.x),
            height: 32
        ))
        field.font = .systemFont(ofSize: pointSize, weight: .medium)
        field.textColor = .white
        if let colorIndex = editorSession?.colorIndex, AnnotationModel.palette.indices.contains(colorIndex) {
            let paletteColor = NSColor(cgColor: AnnotationModel.palette[colorIndex].cgColor) ?? .red
            field.textColor = paletteColor
            field.annotationColor = paletteColor
        }
        field.target = self
        field.action = #selector(textFieldCommit(_:))
        field.delegate = self
        addSubview(field)
        playTextFieldEntrance(field)
        window?.makeFirstResponder(field)
        textField = field
        installFontSizePicker(near: field.frame)
        // 记录落点（确认时生成标注）
        textFieldAnchor = annotationPoint
    }

    /// 文字件入场（motion.enter 缩小版）：fade + rise 8pt，0.22s spring
    private func playTextFieldEntrance(_ view: NSView) {
        let finalFrame = view.frame
        view.frame = finalFrame.offsetBy(dx: 0, dy: 8)   // 翻转坐标 y+8 = 视觉在下方，起 步后上浮
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = DesignTokens.Motion.springTimingFunction
            view.animator().setFrameOrigin(finalFrame.origin)
            view.animator().alphaValue = 1
        }
    }

    /// 文字件退场：fade 0.12s（原瞬删）——completionHandler 持有视图至移除
    private func fadeOutTextField(_ view: NSView) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
        }, completionHandler: { view.removeFromSuperview() })
    }

    /// Esc 取消文字输入：框与字号条 fade 退场，不落标注
    private func cancelTextEditing() {
        if let field = textField { fadeOutTextField(field) }
        textField = nil
        textFieldAnchor = nil
        removeFontSizePicker()
    }

    /// 浮动 4 档字号选择条（Aa12/Aa14/Aa17/Aa21）：贴在输入框上方 8pt（不遮挡输入框），
    /// 放不下（贴近画布顶部/屏幕顶）则改到输入框下方，并夹在可视范围内
    private func installFontSizePicker(near fieldFrame: NSRect) {
        let sizes = OverlayView.textFontSizes
        let selectedIndex = sizes.firstIndex(of: editorSession?.textFontSize ?? 14) ?? 1
        let bar = FontSizeBarView(sizes: sizes, selectedIndex: selectedIndex)
        bar.onSelect = { [weak self] index in
            guard sizes.indices.contains(index) else { return }
            let size = sizes[index]
            self?.editorSession?.textFontSize = size
            // 实时套用到正在编辑的输入框（所见 = 所选）
            self?.textField?.font = .systemFont(ofSize: CGFloat(size), weight: .medium)
            Log.event(.editor, "editor.text.fontSize", ["size": "\(size)"])
        }
        let size = FontSizeBarView.preferredSize(buttonCount: sizes.count)
        let aboveY = fieldFrame.minY - 8 - size.height
        var origin = CGPoint(x: fieldFrame.minX, y: aboveY >= editorRectLocal.minY ? aboveY : fieldFrame.maxY + 8)
        origin.x = min(max(origin.x, 4), bounds.width - size.width - 4)
        origin.y = min(max(origin.y, 4), bounds.height - size.height - 4)
        bar.frame = CGRect(origin: origin, size: size)
        addSubview(bar)
        playTextFieldEntrance(bar)   // 字号件与输入框同源入场（fade + rise 8pt）
        fontSizePicker = bar
    }

    private var textFieldAnchor: CGPoint?

    @objc private func textFieldCommit(_ sender: NSTextField?) {
        commitTextFieldIfNeeded()
    }

    private func commitTextFieldIfNeeded() {
        guard let field = textField, let anchor = textFieldAnchor, let session = editorSession else { return }
        let text = field.stringValue
        fadeOutTextField(field)
        removeFontSizePicker()
        if !text.isEmpty {
            controller.addAnnotation(AnnotationModel(
                shape: .text(anchor: anchor),
                colorIndex: session.colorIndex,
                strokeWidth: session.strokeWidth,
                text: text,
                index: nil,
                fontSize: CGFloat(session.textFontSize)
            ))
        }
        textField = nil
        textFieldAnchor = nil
        window?.makeFirstResponder(self)
    }

    /// Esc/提交后一并拆掉浮动字号条（fade 0.12s）
    private func removeFontSizePicker() {
        guard let picker = fontSizePicker else { return }
        fontSizePicker = nil
        fadeOutTextField(picker)
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
        // 拼接窗口期（scroll 停采后 → 长图回填前的异步间隙）：所有键吞掉。
        // 此时 editorSession 还挂着旧单帧底图，Enter→done / Esc→cancel 会把会话
        // 销毁 ⇒ 合成结果无处回填（scroll.compose.noSession 病例）。
        if controller.isScrollComposing { return }
        // 文字输入态：普通键给输入框（first responder 已是 field，事件不会到这）
        // C：选区阶段复制光标处像素颜色（取色器语义），随后结束会话
        let inSelectionPhase: Bool = {
            switch phase {
            case .waitingForDrag, .dragging: return true
            default: return false
            }
        }()
        if Int(event.keyCode) == kVK_ANSI_C, inSelectionPhase,
           !event.modifierFlags.contains(.command) {
            copyColorUnderCursor()
            return
        }
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
        // 编辑器自定义热键（工具栏后半段 8 动作，settings.editorHotkeys）：
        // 匹配优先于下述系统语义（Return/Esc 先走文字输入态，S 滚动/⌘⌥S 快存
        // 等内置键序保留——自定义组合撞内置键时内置先行，设置页有冲突提示）。
        // （分发逻辑在 EditorKeyRouter：拼贴合成编辑宿主共用）
        if let action = matchEditorHotkey(event) {
            performEditorHotkeyAction(action)
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            if scrollMode {
                // 采集态 Esc = 取消滚动采集（丢帧回标注态），不是取消整个截图会话
                controller.cancelScrollForUser()
                return
            }
            if textField != nil {
                // 文字输入态的 Esc：取消文字（R4 语义在编辑器内优先作用于文字）
                cancelTextEditing()
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
            // ⌘⌥S 快存（内置语义，不走热键体系）；⌘S 保存与裸 S 滚动截图
            // 均已并入 settings.editorHotkeys（EditorKeyRouter 分发，见上方 match）
            if event.modifierFlags.contains(.command), event.modifierFlags.contains(.option),
               phase == .editing || phase == .confirmed {
                controller.perform(action: .quickSave)
            } else {
                super.keyDown(with: event)
            }
        default:
            // 热键 1-6 直选工具（R6）；再按同键取消回 .none（用户裁定
            // 2026-11-16：默认无工具拖动=移动选区，数字键即取即还）
            if phase == .editing,
               let tool = toolFor(keyCode: Int(event.keyCode)) {
                editorSession?.currentTool = (editorSession?.currentTool == tool) ? .none : tool
                controller.refreshToolbar()
                needsDisplay = true
                return
            }
            super.keyDown(with: event)
        }
    }

// MARK: 编辑器自定义热键（工具栏后半段）

    /// 分发逻辑在共享的 EditorKeyRouter（Sources/UI/Editor/EditorKeyRouter.swift），
    /// 拼贴合成编辑宿主（CollageEditorWindowController）复用同一套。
    private lazy var editorKeyActions = EditorKeyRouter.Actions(
        undo: { [weak self] in self?.controller.undoAnnotation() },
        redo: { [weak self] in self?.controller.redoAnnotation() },
        toggleVisibility: { [weak self] in self?.controller.toggleToolbarVisibility() },
        ocr: { [weak self] in self?.controller.toolbarAction(.ocr) },
        pin: { [weak self] in self?.controller.toolbarAction(.pin) },
        save: { [weak self] in self?.controller.perform(action: .save) },
        done: { [weak self] in self?.controller.perform(action: .copy) },
        cancel: { [weak self] in self?.controller.perform(action: .cancel) },
        scroll: { [weak self] in
            guard let self else { return }
            Log.event(.scroll, "scroll.keyReceived")
            self.controller.beginScrollCapture()
        },
        selectTool: { [weak self] tool in
            guard let self else { return }
            self.editorSession?.currentTool = tool
            self.controller.refreshToolbar()
            self.needsDisplay = true
        }
    )

    /// event → 组合串 → settings.editorHotkeys 反查 action key。
    /// 仅编辑/确认阶段且无文字输入时生效（文字输入态的键必须给输入框）。
    private func matchEditorHotkey(_ event: NSEvent) -> String? {
        guard textField == nil, phase == .editing || phase == .confirmed, !scrollMode else { return nil }
        return EditorKeyRouter.matchHotkey(event)
    }

    private func performEditorHotkeyAction(_ actionKey: String) {
        EditorKeyRouter.perform(actionKey, actions: editorKeyActions)
    }

    private func toolFor(keyCode: Int) -> EditorSession.Tool? {
        EditorKeyRouter.tool(for: keyCode)
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

    /// 两点 → 矩形（起点锚定，非增量 union）
    ///
    /// ⚠️ 病例：旧实现 `abs(point - (minX + width))` 在增量迭代下语义漂移——
    /// 每次 drag 都拿「上一帧 rect」再算，w 变了之后算出的宽越来越偏（拖 150pt
    /// 只得 75pt）。矩形/马赛克这类「两点定形」必须始终用固定起点做锚。
    private func rectFromPoints(_ start: CGPoint, _ point: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
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

    /// 滚动采集态：蒙层 + 挖空采集区（outline/光晕/底缘绿条由 ScrollRegionGlowView 承担，
    /// 帧数/进度由 ScrollCaptureHUDPanel 承担——图层动画不能走 draw 重绘路径）
    private func drawScrollHUD(ctx: CGContext) {
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.fill(bounds)
        guard let rect = scrollRectLocal else { return }
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(rect)
        ctx.restoreGState()
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
        // 审查：悬停是未确认态，层级低于主选区 —— accent α.85 · 1.5pt（原 2pt α.95）
        // + 0.12s alpha 淡入（draw 路径用时间插值，未满 1 时保持重绘）
        let selectionEmpty = selectionLocal.width <= 0 && selectionLocal.height <= 0
        if selectionEmpty, let rect = hoveredLocalRect, let target = hovered {
            let elapsed = hoverFadeStart > 0 ? CACurrentMediaTime() - hoverFadeStart : 1
            let hoverAlpha = min(1, CGFloat(elapsed / 0.12))
            if hoverAlpha < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                    self?.needsDisplay = true
                }
            }
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fill(rect)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85 * hoverAlpha).cgColor)
            ctx.setLineWidth(1.5)
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

        // 4. 尺寸角标（原型样式：「452 × 323 @2x」，黑胶囊 11pt）
        if phase != .waitingForDrag {
            let scale = window?.screen?.backingScaleFactor ?? 1
            let w = Int(selectionLocal.width * scale)
            let h = Int(selectionLocal.height * scale)
            let sizeText = "\(w) × \(h) @\(Int(scale))x"
            drawBadge(text: sizeText, below: selectionLocal)
        }
    }

    /// 选区阶段收尾：放大镜（独立方法，draw() 里在蒙层/选框之后调用）
    private func drawSelectionOverlays(ctx: CGContext) {
        drawMagnifier(ctx: ctx)
    }

    /// 编辑阶段：选区外蒙层 + 选区内冻结底图 + 标注层
    /// move 手势期间的实时取景：当前选区在冻结帧上的对应区域
    private func liveFrozenCrop() -> CGImage? {
        guard let window = window, let frozen = frozenImage, bounds.width > 0 else { return nil }
        // editorRectLocal（视图 Y-down）→ 屏全局（Y-up）
        let global = CGRect(
            x: window.frame.minX + editorRectLocal.minX,
            y: window.frame.maxY - editorRectLocal.maxY,
            width: editorRectLocal.width, height: editorRectLocal.height)
        // 屏 → 冻结帧像素（frozen 与 window.frame 同区域 1:1 像素比例）
        let sx = CGFloat(frozen.width) / max(1, window.frame.width)
        let sy = CGFloat(frozen.height) / max(1, window.frame.height)
        let px = CGRect(
            x: (global.minX - window.frame.minX) * sx,
            y: (window.frame.maxY - global.maxY) * sy,
            width: global.width * sx, height: global.height * sy).integral
        return frozen.cropping(to: px)
    }

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
        let annotations = session.store.annotations + (pendingAnnotation.map { [$0] } ?? [])

        // 2.5 马赛克预览：已提交 + 拖拽中（pending）的 mosaic 都走与导出 composite
        // 完全相同的像素化算法（CGRenderer.applyMosaic → 「编辑器所见 = 导出所得」）。
        // ⚠️ 病例：马赛克只有矢量层 5% 黑罩时，选区内拖拽看不到任何效果
        //（用户实报「点了没反应」）——必须在底图上真实打码才有拖拽反馈。
        let hasMosaic = annotations.contains { annotation in
            if case .mosaic = annotation.shape { return true }
            return false
        }
        let baseForDraw: CGImage
        if hasMosaic {
            baseForDraw = CGRenderer.renderMosaicPreview(
                base: session.baseImage, annotations: annotations, scale: session.scale
            )
        } else {
            baseForDraw = session.baseImage
        }
        // ⚠️ 用户裁定（2026-11-17「相机取景框」语义）：拖动选区期间，框内内容
        // 必须实时映射冻结帧的对应区域（取景器对着的是世界，不是一张贴图）。
        // 实现：move 手势进行中（editGesture == .move）从全屏 frozenImage 动态
        // 裁 editorRectLocal 屏幕对应区域；松手时 adjustSelection 提交正式底图
        // （标注 offset 平移）——拖动中标注跟框走，视觉连贯。
        switch editGesture {
        case .move, .resize:
            if let frozen = frozenImage, let liveCrop = liveFrozenCrop() {
            ctx.saveGState()
            ctx.clip(to: editorRectLocal)
            ctx.translateBy(x: editorRectLocal.minX, y: editorRectLocal.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(liveCrop, in: editorRectLocal)
            ctx.restoreGState()
                return
            }
        default:
            break
        }
        do {
        ctx.saveGState()
        ctx.clip(to: editorRectLocal)
        ctx.translateBy(x: editorRectLocal.minX, y: editorRectLocal.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -editorRectLocal.minX, y: -editorRectLocal.minY)
        ctx.interpolationQuality = .none
        ctx.draw(baseForDraw, in: editorRectLocal)
        ctx.restoreGState()
        }

        // 3. 标注层（同一渲染器 = 导出所见）
        // ⚠️ 病例：不能放在上面的「图像翻转 gstate」里画——那个 CTM 是为 Y-up 位图
        // 准备的绝对坐标翻转，标注却是选区局部坐标 → 画出来必然被 clip 裁光
        // （用户实报：矩形工具画不出任何东西；log 里 shape.commit 都在，屏幕零像素）。
        // 正确姿势：回到视图原生 Y-down CTM，clip 选区 + 平移原点即可。
        Log.event(.editor, "editor.draw", [
            "count": "\(annotations.count)", "shapes": annotations.map { "\($0.shape)" }.joined(separator: "|"),
        ])
        ctx.saveGState()
        ctx.clip(to: editorRectLocal)
        ctx.translateBy(x: editorRectLocal.minX, y: editorRectLocal.minY)
        CGRenderer.render(annotations: annotations, in: editorRectLocal.size, context: ctx, contextIsYDown: true)
        ctx.restoreGState()

        // 4. 选区描边（编辑态的画布边界；审查：与框选态统一线宽阶梯 white .85 · 1.5pt）
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(borderWidth)
        ctx.stroke(editorRectLocal)

        // 4.5 手柄（选区足够大时）：8 个白色方块，悬停的加粗
        drawSelectionHandles(ctx: ctx)

        // 5. 提示条已移除（病例：长条提示与工具栏重叠、压住按钮，原型 scene 03 也没有它；
        //    快捷键教学放设置面板与首次引导，不占编辑画布）
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
            // 审查：删 black .45 描边（white 方块在冻结底图上自带对比，黑边是噪音）；
            // 改 shadow(black .30, r2, offset 0 1) 承担分离度。翻转上下文 y+1 = 视觉向下
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2,
                          color: NSColor.black.withAlphaComponent(0.30).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            ctx.restoreGState()
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

    /// 尺寸角标：深胶囊 rgba(24,24,27,.62) + 0.5pt stroke 白 .14（并入 tooltip 深胶囊家族；
    /// 原 black .72 实心胶囊），文字 white .94
    private func drawBadge(text: String, below rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 7
        let size = CGSize(width: ceil(textSize.width + padding * 2), height: ceil(textSize.height + 3))
        var origin = CGPoint(x: rect.maxX - size.width, y: min(rect.maxY + 6, bounds.height - size.height))
        if origin.y + size.height > bounds.height { origin.y = rect.minY - size.height - 6 }
        if origin.y < 0 { origin.y = 4 }
        if origin.x < 0 { origin.x = 4 }
        let badgeRect = CGRect(origin: origin, size: size)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(DesignTokens.capsuleDark.cgColor)
        ctx?.addPath(path)
        ctx?.fillPath()
        ctx?.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx?.setLineWidth(0.5)
        ctx?.addPath(path)
        ctx?.strokePath()
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
                cancelTextEditing()
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

// MARK: - 文字输入视觉件（§10-9 落地：透明底 + 标注色描边；glass 不叠色、无发光）
//
// 视觉 token 对齐 tokens.md §10-9（轻盈感审查后落地）：
// - 输入框：无底透明，唯一指示 = 0.5pt 当前标注色 α.60 描边（placeholder 删除）
// - 字号条：hudWindow 玻璃（不叠 60% tint）+ 0.5pt 白 16% 描边；选中档不发光

@MainActor
private enum TextUIStyle {
    static let accent = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)        // #0A84FF
    static let accentHover = NSColor(srgbRed: 0.102, green: 0.549, blue: 1.0, alpha: 1)   // #1A8CFF
    static let borderIdle = NSColor.white.withAlphaComponent(0.16)
    static let textIdle = NSColor.white.withAlphaComponent(0.82)
    static let textActive = NSColor.white
    static let hoverFill = NSColor.white.withAlphaComponent(0.12)
    /// 标注色描边 α .60（描边色即「这段字会用什么颜色」的语义，比通用蓝多一层信息）
    static let annotationBorderAlpha: CGFloat = 0.60
}

// MARK: - 文字输入框（§10-9：透明底 + 0.5pt 标注色 α.60 描边；无 placeholder 无聚焦框）

@MainActor
private final class GlassTextField: NSTextField {
    /// 当前画笔色（描边语义色；未设置时回落 accent）
    var annotationColor: NSColor = TextUIStyle.accent

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor   // 实心底已判死（token §10-9）
        layer?.borderWidth = 0.5
        applyAnnotationBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func applyAnnotationBorder() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderWidth = 0.5
        layer.borderColor = annotationColor.withAlphaComponent(TextUIStyle.annotationBorderAlpha).cgColor
        CATransaction.commit()
    }
}

// MARK: - 浮动字号条（磨砂玻璃小条：hudWindow + 60% 深着色，胶囊高 32）

@MainActor
private final class FontSizeBarView: NSView {
    /// 按钮 28 高 × 34 宽（13pt「Aa14」需要 ~30pt 宽，28 放不下会截字）+ 间距 2 + 左右 padding 4
    static let buttonSize = CGSize(width: 34, height: 28)
    static let barHeight: CGFloat = 32

    static func preferredSize(buttonCount: Int) -> CGSize {
        CGSize(width: CGFloat(buttonCount) * buttonSize.width
            + CGFloat(max(0, buttonCount - 1)) * 2 + 8,
               height: barHeight)
    }

    var onSelect: ((Int) -> Void)?
    private var buttons: [FontSizeOptionButton] = []
    private var selectedIndex = 0
    private let effect = NSVisualEffectView()
    private let stack = NSStackView(views: [])

    init(sizes: [Int], selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        wantsLayer = true

        // 玻璃容器（工具栏同款：hudWindow 磨砂 + 0.5pt 白 16% 描边；60% 叠色已判死，不再叠 tint）
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = TextUIStyle.borderIdle.cgColor
        addSubview(effect)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        addSubview(stack)

        for (i, size) in sizes.enumerated() {
            let button = FontSizeOptionButton(label: "Aa\(size)")
            button.onActivated = { [weak self] in
                guard let self else { return }
                self.select(index: i)
                self.onSelect?(i)
            }
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        select(index: selectedIndex)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        effect.frame = bounds
        stack.frame = bounds
    }

    func select(index: Int) {
        selectedIndex = index
        for (i, button) in buttons.enumerated() { button.setSelected(i == index) }
    }
}

// MARK: - 字号档按钮（28 高「Aa14」胶囊：选中 #0A84FF 高亮，hover 变亮；蓝色 glow 已删）

@MainActor
private final class FontSizeOptionButton: NSButton {
    var onActivated: (() -> Void)?
    private var isHot = false
    private var isSelectedState = false
    private var trackingArea: NSTrackingArea?
    /// 选中态 inset 白高光（工具栏同款：顶部白 30% 渐变，mask 到圆角）
    private let highlightGradient = CAGradientLayer()
    private var highlightInstalled = false

    init(label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = label
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        widthAnchor.constraint(equalToConstant: FontSizeBarView.buttonSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: FontSizeBarView.buttonSize.height).isActive = true
        setStyledTitle(TextUIStyle.textIdle, size: 13)

        highlightGradient.colors = [
            NSColor.white.withAlphaComponent(0.30).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        highlightGradient.startPoint = CGPoint(x: 0.5, y: 0)
        highlightGradient.endPoint = CGPoint(x: 0.5, y: 1)
        highlightGradient.locations = [0, 0.45]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func setStyledTitle(_ color: NSColor, size: CGFloat) {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ])
    }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        if !selected, highlightInstalled {
            highlightGradient.removeFromSuperlayer()
            highlightInstalled = false
        }
        needsDisplay = true
        applyStyle()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { applyStyle() }

    private func applyStyle() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelectedState {
            layer.backgroundColor = (isHot ? TextUIStyle.accentHover : TextUIStyle.accent).cgColor
            setStyledTitle(TextUIStyle.textActive, size: 13)
            // 蓝色外发光已删（token §1.1 删除项）：唯一彩块语义由 accent 底承担
            layer.shadowOpacity = 0
            if !highlightInstalled {
                layer.addSublayer(highlightGradient)
                highlightInstalled = true
            }
        } else if isHot {
            layer.backgroundColor = TextUIStyle.hoverFill.cgColor
            setStyledTitle(TextUIStyle.textActive, size: 13)
            layer.shadowOpacity = 0
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
            setStyledTitle(TextUIStyle.textIdle, size: 13)
            layer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let path = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        let mask = CAShapeLayer()
        mask.path = path
        highlightGradient.frame = bounds
        highlightGradient.mask = mask
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    /// 点击即生效（不等 mouseUp，输入态下手感更快）
    override func mouseDown(with event: NSEvent) {
        onActivated?()
    }
}

// MARK: - NSEvent → HotkeyModifiers 桥（UI 层；Core 无 AppKit）

extension NSEvent.ModifierFlags {
    var hotkeyModifiers: HotkeyModifiers {
        var mods: HotkeyModifiers = []
        if contains(.command) { mods.insert(.command) }
        if contains(.shift) { mods.insert(.shift) }
        if contains(.option) { mods.insert(.option) }
        if contains(.control) { mods.insert(.control) }
        return mods
    }
}
