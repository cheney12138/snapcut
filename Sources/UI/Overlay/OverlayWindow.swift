import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 覆盖层窗口：无边框、透明、screenSaver 层级、全屏盖住单台显示器
@MainActor
final class OverlayWindow: NSWindow {
    // 无边框窗口默认 canBecomeKey=false，必须显式允许才能接收键盘事件
    override var canBecomeKey: Bool { true }

    private(set) var owningScreen: NSScreen
    /// GPU 冻结帧底层视图（CALayer.contents 直接托管 4K CGImage，消除每帧 mouseMoved 33MB CPU 重绘）
    private let frozenBackdropView: NSView
    /// 交互与蒙层/标注前景视图
    let overlayView: OverlayView

    init(screen: NSScreen, controller: OverlayController) {
        self.owningScreen = screen
        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        let root = NSView(frame: bounds)
        root.wantsLayer = true

        let backdrop = NSView(frame: bounds)
        backdrop.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        backdrop.layer?.contentsGravity = .resize
        backdrop.layer?.magnificationFilter = .linear
        backdrop.layer?.minificationFilter = .linear
        backdrop.isHidden = true

        let view = OverlayView(frame: bounds, controller: controller)
        view.autoresizingMask = [.width, .height]

        root.addSubview(backdrop)
        root.addSubview(view)
        self.frozenBackdropView = backdrop
        self.overlayView = view

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
        contentView = root
        initialFirstResponder = view
    }

    /// 窗口池复用重置（零 33MB backing-store 重建开销）
    func prepareForReuse(screen: NSScreen) {
        owningScreen = screen
        if frame != screen.frame {
            setFrame(screen.frame, display: false)
        }
        ignoresMouseEvents = false
        frozenBackdropView.layer?.contents = nil
        frozenBackdropView.isHidden = true
        overlayView.resetForReuse()
        makeFirstResponder(overlayView)
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
        // 首次点击落在非激活窗口时同步发起激活；配合 OverlayView.acceptsFirstMouse == true，
        // AppKit 会把首笔完整的 mouseDown → mouseDragged → mouseUp 原封不动送达视图，
        // 不再提前篡改 phase 导致首次框选卡死需要多次重拖。
        if event.type == .leftMouseDown, !NSApp.isActive {
            NSApp.activate()
        }
        super.sendEvent(event)
    }

    /// 选区所在屏进入编辑模式（显示冻结底图 + 标注交互）
    func enterEditorMode(session: EditorSession) {
        overlayView.enterEditorMode(session: session)
    }

    /// 滚动截图模式（隐藏冻结底图露出底层实时滚动画面 + 区域 outline 光晕脉动）
    func enterScrollMode() {
        frozenBackdropView.isHidden = true
        overlayView.enterScrollMode()
    }

    /// 退出编辑模式（enterEditor 幂等重入用：回蒙层态）
    func exitEditorIfNeeded() {
        overlayView.exitEditorIfNeeded()
    }

    func exitScrollMode(restoreFrozenBackdrop: Bool = true) {
        frozenBackdropView.isHidden = !restoreFrozenBackdrop || (frozenBackdropView.layer?.contents == nil)
        overlayView.exitScrollMode()
    }

    /// 录屏准备态：隐藏冻结底图露出实时桌面，保留可调选区框
    func enterRecordingPreparingMode(globalRect: CGRect) {
        frozenBackdropView.isHidden = true
        ignoresMouseEvents = false
        overlayView.enterRecordingPreparingMode(globalRect: globalRect)
    }

    /// 录屏进行中：事件完全穿透下层 App，仅保留外围录制边框
    func enterRecordingActiveMode(globalRect: CGRect, paused: Bool) {
        frozenBackdropView.isHidden = true
        ignoresMouseEvents = true
        overlayView.enterRecordingActiveMode(globalRect: globalRect, paused: paused)
    }

    func setRecordingPaused(_ paused: Bool) {
        overlayView.setRecordingPaused(paused)
    }

    func exitRecordingMode() {
        ignoresMouseEvents = false
        overlayView.exitRecordingMode()
    }

    /// 滚动采集：区域随内容生长（全局矩形）
    func updateScrollRegion(_ global: CGRect) {
        overlayView.updateScrollRegion(global: global)
    }

    /// 到底：底缘 2pt 绿条 + 光晕定格
    func setScrollBottomReached() {
        overlayView.setScrollBottomReached()
    }

    /// 到底撤销（用户到底后又继续滚）：清绿条恢复采集光晕
    func clearScrollBottomReached() {
        overlayView.clearScrollBottomReached()
    }

    /// 安装冻结帧（GPU CALayer 托管，零每帧 CPU 重绘）
    func installFrozenImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozenBackdropView.layer?.contents = image
        frozenBackdropView.isHidden = false
        CATransaction.commit()
        overlayView.installFrozenImage(image)
    }

    /// 窗口刚上屏或重聚焦时，立即同步真实鼠标位置、十字准星与放大镜，不等首次 mouseMoved
    func syncInitialCursor() {
        overlayView.syncInitialCursor()
    }

    /// 外部入口：整屏截图（⌘⇧S / 托盘菜单）
    func pickFullDisplay() {
        overlayView.pickFullDisplayExternally()
    }

    // MARK: - 智能框选（异步视觉探测回填，Controller 唯一入口）

    /// 文本行探测回填（最先就绪的一层：20-40ms 即可高亮文字行）
    func updateSmartVisionTextLines(_ lines: [CGRect]) {
        overlayView.updateSmartVisionTextLines(lines)
    }

    /// 控件/区域识别回填
    func updateSmartVisionRects(_ rects: [CGRect]) {
        overlayView.updateSmartVisionRects(rects)
    }

    /// 表格结构识别回填（单元格 / 行 / 列）
    func updateSmartVisionTables(_ tables: [DetectedVisualTable]) {
        overlayView.updateSmartVisionTables(tables)
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
    /// 独立外源图（Toast 重开 / 长图编辑）初始适配矩形，供双击「适配 ↔ 1:1 原生」切换
    private var standaloneFitRectLocal: CGRect = .zero
    private var standaloneZoomHudText: String?
    private var standaloneZoomHudWork: DispatchWorkItem?
    /// 智能一键脱敏（M1）：悬停可点消的自动脱敏框 + 刚命中时的短暂轻蓝轮廓提示 + 顶部瞬时胶囊反馈
    private var hoveredAutoRedactRect: CGRect?
    private var flashedAutoRedactRects: [CGRect] = []
    private var autoRedactFlashWork: DispatchWorkItem?
    private var editorToastText: String?
    private var editorToastWork: DispatchWorkItem?
    private var isStandaloneImage: Bool { frozenImage == nil }

    /// 拖拽中的标注预览（未确认，不入 store）
    private var pendingAnnotation: AnnotationModel?

    /// 滚动截图模式（controller 的 scrollController 非空）
    private(set) var scrollMode = false
    /// 滚动 HUD 显示的选区（本窗口负责的那块，可能是 nil=本屏无选区）
    private var scrollRectLocal: CGRect?
    /// 采集区域边缘光晕 + 底缘绿条（motion.pulse；替代旧 draw 内画框）
    private var scrollGlowView: ScrollRegionGlowView?

    private enum RecordingOverlayMode: Equatable {
        case none
        case preparing
        case active(paused: Bool)
    }
    private var recordingMode: RecordingOverlayMode = .none
    private var recordingRectLocal: CGRect = .zero
    private var recordingBorderView: RecordingRegionBorderView?

    /// 文字输入框（text 工具）
    private var textField: NSTextField?

    /// 冻结帧（会话开始时的整屏静态画面；有它就不再实时看桌面）
    private var frozenImage: CGImage?

    /// 编辑态手势（改选区尺寸 / 整体移动 / 已画标注二次编辑）
    private enum EditGesture {
        case none
        case resize(edge: SelectionEdge, startRect: CGRect)
        case move(startRect: CGRect, startPoint: CGPoint)
        /// 已画标注二次编辑：`initialAnnotation` 是按下瞬间的快照（每帧由「快照 + 累计 delta」重算，
        /// 幂等无漂移）；`preMutationSnapshot` 是整条列表快照，mouseUp 时整体压一步撤销（单步 ⌘Z）
        case editAnnotation(
            index: Int,
            handle: AnnotationHandle,
            startPoint: CGPoint,
            initialAnnotation: AnnotationModel,
            preMutationSnapshot: [AnnotationModel]
        )
    }
    private var editGesture: EditGesture = .none
    private var draggedEventCount = 0
    /// 空格按下（临时切「整体移动」）
    private var spacePressed = false
    /// 悬停中的手柄（绘制手柄高亮 + 光标反馈）
    private var hoverEdge: SelectionEdge?

    // MARK: 已画标注二次编辑（选中 / 悬停 / 原地改字）
    /// 编辑态当前选中的标注下标（nil = 未选中）
    private var selectedAnnotationIndex: Int?
    /// 悬停反馈：命中的标注下标与操控柄（决定光标与悬停虚线）
    private var hoveredAnnotationIndex: Int?
    private var hoveredAnnotationHandle: AnnotationHandle?
    /// 双击原地改字时正在编辑的原文字标注下标（绘制已落盘标注时跳过，防输入框底下重影）
    private var editingTextAnnotationIndex: Int?
    /// 选中标注改样式的「拖动前快照」（绑下标：滑杆连续拖动只占一步撤销，且绝不错用到别的标注）
    private var stylePreviewSnapshot: (index: Int, annotations: [AnnotationModel])?
    /// 最近一次已知工具（供工具栏回调判断「工具真的换了」而非仅改颜色/线宽）
    private var lastKnownTool: EditorSession.Tool = .none
    /// 取色复制格式（HEX → RGB → HSL，⇧C 轮换后落盘，下次沿用）
    private var colorCopyFormat: ColorCopyFormat = ColorCopyFormat.persisted
    /// 放大镜采样器（安装冻结帧时构建一次）
    private var frozenSampler: FrozenSampler?
    /// 光标本地坐标（放大镜跟随；Y 向下）
    private var cursorLocal: CGPoint = .zero

    /// 智能框选：视觉探测缓存（文本行 / 识别区域，均为 AppKit 全局坐标 Y 向上）
    private var smartTextLines: [CGRect] = []
    private var smartVisualRects: [CGRect] = []
    /// 智能框选：视觉表格结构缓存（单元格 / 行 / 列，AppKit 全局坐标 Y 向上）
    private var smartVisualTables: [DetectedVisualTable] = []
    /// 智能框选：最近一次 AX 探测结果 + 防乱序代际
    private var smartProbeTask: Task<Void, Never>?
    private var smartProbeEpoch: UInt64 = 0
    private var latestAXCandidates: [SmartSelectionCandidate] = []
    private var latestWindowCandidate: SmartSelectionCandidate?
    /// 当前候选栈（滚轮切层）与层级下标 / 滚轮累加器 / 用户是否手动滚轮锁定过层级
    private var smartStack: SmartCandidateStack = .empty
    private var smartCandidateIndex: Int = 0
    private var smartLayerUserPinned = false
    private var smartScrollAccumulator: CGFloat = 0
    /// 当前层级对应的智能候选（nil = 无候选，落到纯手拖）
    private var smartActiveCandidate: SmartSelectionCandidate? {
        smartStack.candidate(at: smartCandidateIndex)
    }
    /// 悬停高亮的本地矩形（智能候选 / 边缘全屏共用，Y 向下）
    private var hoveredLocalRect: CGRect?
    /// 鼠标移到屏幕边缘（≤14pt）时进入整屏预览，框体平滑变形为整个屏幕
    private var edgeFullScreenHover = false
    private var hoverMorphFromRect: CGRect?
    private var hoverMorphStart: CFTimeInterval = 0
    private var hoverProbePoint: CGPoint = .zero
    private var hoverProbeTime: CFTimeInterval = 0
    private var trackingAreaRef: NSTrackingArea?

    // MARK: 辅助功能权限轻提示条
    /// 用户关掉后不再提示（跨会话持久）
    private static let axHintDismissedKey = "smart.axHint.dismissed"
    /// 本次会话缓存的授权状态（AXIsProcessTrusted 是同步 TCC 查询，不能每帧 draw 里调）
    private var axTrusted = true
    private var axHintDismissed = false
    /// 命中矩形缓存（视图本地 Y 向下；nil = 当前未绘制）
    private var axHintBannerRect: CGRect?
    private var axHintCloseRect: CGRect?
    /// 光标是否悬在提示条上（用于进出时切换 hand/crosshair）
    private var axHintHovered = false
    /// 只有「唤起截图那一屏」显示轻提示（多屏时不在每块屏都糊一条）
    private var axHintHostFrame: CGRect?

    /// 未授权 + 用户没关过 + 选区悬停态（不打扰滚动/录制）才显示
    private var shouldShowAXHint: Bool {
        guard phase == .waitingForDrag, !scrollMode, recordingMode == .none else { return false }
        guard !axHintDismissed else { return false }
        guard let host = axHintHostFrame, window?.screen?.frame == host else { return false }
        return !axTrusted
    }

    // 视觉常量
    /// 蒙层：0.22（审查：0.25 → 轻 12%，选区提亮不变）
    private let dimAlpha: CGFloat = 0.22
    private let borderWidth: CGFloat = 1.5
    private let minSelectionSize: CGFloat = 4
    /// 窗口悬停高亮淡入起点（审查：悬停反馈应「亮起」不是「出现」，0.12s）
    private var hoverFadeStart: CFTimeInterval = 0
    /// 拖拽期直接按 Enter/快捷键提前提交后，吞掉系统随后补发的那一笔延迟 leftMouseUp（三指拖移场景）
    private var ignoreNextMouseUpAfterEarlyCommit = false

    init(frame frameRect: NSRect, controller: OverlayController) {
        self.controller = controller
        super.init(frame: frameRect)
        wantsLayer = true
        axTrusted = AccessibilityPermission.isTrusted()
        axHintDismissed = UserDefaults.standard.bool(forKey: Self.axHintDismissedKey)
        // 新建窗（非池化路径）也要能显示提示条：按当前光标所在屏定屏
        axHintHostFrame = NSScreen.screens
            .first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?
            .frame
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }  // 统一 Y 向下（与标注几何一致）
    /// 关键：允许非激活窗口的首笔鼠标按下/拖拽直接进入框选流程（杜绝重启后首次 F1 必须拖 2–3 次才选中的根因）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 复用重置：彻底清空上一轮选区/编辑/滚动/悬停状态，避免销毁重建 4K OverlayWindow
    func resetForReuse() {
        resetSmartSelectionState()
        standaloneZoomHudWork?.cancel()
        standaloneZoomHudWork = nil
        standaloneZoomHudText = nil
        hoveredAutoRedactRect = nil
        flashedAutoRedactRects = []
        autoRedactFlashWork?.cancel()
        autoRedactFlashWork = nil
        editorToastText = nil
        editorToastWork?.cancel()
        editorToastWork = nil
        textField?.removeFromSuperview()
        textField = nil
        scrollGlowView?.removeFromSuperview()
        scrollGlowView = nil
        scrollMode = false
        scrollRectLocal = nil
        recordingBorderView?.removeFromSuperview()
        recordingBorderView = nil
        recordingMode = .none
        recordingRectLocal = .zero
        phase = .waitingForDrag
        selectionLocal = .zero
        editorSession = nil
        editorRectLocal = .zero
        standaloneFitRectLocal = .zero
        pendingAnnotation = nil
        editGesture = .none
        draggedEventCount = 0
        spacePressed = false
        hoverEdge = nil
        selectedAnnotationIndex = nil
        hoveredAnnotationIndex = nil
        hoveredAnnotationHandle = nil
        editingTextAnnotationIndex = nil
        stylePreviewSnapshot = nil
        lastKnownTool = .none
        frozenImage = nil
        frozenSampler = nil
        ignoreNextMouseUpAfterEarlyCommit = false
        // 轻提示条显示资格：每轮截图重新问一次（用户刚去授权回来则自动消失）
        axTrusted = AccessibilityPermission.isTrusted()
        axHintDismissed = UserDefaults.standard.bool(forKey: Self.axHintDismissedKey)
        // 只在这一屏显示：按唤起时的光标位置定屏（与 OverlayController 选屏口径一致）
        axHintHostFrame = NSScreen.screens
            .first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?
            .frame
        axHintBannerRect = nil
        axHintCloseRect = nil
        axHintHovered = false
        needsDisplay = true
    }

    // MARK: - 编辑态切入

    func enterEditorMode(session: EditorSession) {
        // 进编辑态：悬停高亮/候选栈不再适用（AX 会话已由 controller 释放）
        clearHover()
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
        if isStandaloneImage {
            standaloneFitRectLocal = editorRectLocal
        }
        // 新会话：清掉上一轮标注选中/悬停/改字状态
        selectedAnnotationIndex = nil
        hoveredAnnotationIndex = nil
        hoveredAnnotationHandle = nil
        editingTextAnnotationIndex = nil
        stylePreviewSnapshot = nil
        lastKnownTool = session.currentTool
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

    func enterRecordingPreparingMode(globalRect: CGRect) {
        textField?.removeFromSuperview()
        textField = nil
        pendingAnnotation = nil
        editorSession = nil
        editGesture = .none
        hoverEdge = nil
        recordingBorderView?.removeFromSuperview()
        recordingBorderView = nil

        let frame = window?.frame ?? .zero
        recordingRectLocal = CGRect(
            x: globalRect.minX - frame.minX,
            y: frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
        recordingMode = .preparing
        phase = .confirmed
        needsDisplay = true
    }

    func enterRecordingActiveMode(globalRect: CGRect, paused: Bool) {
        editGesture = .none
        hoverEdge = nil
        let frame = window?.frame ?? .zero
        let local = CGRect(
            x: globalRect.minX - frame.minX,
            y: frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
        recordingRectLocal = local
        recordingMode = .active(paused: paused)
        if recordingBorderView == nil {
            let border = RecordingRegionBorderView(frame: bounds)
            border.autoresizingMask = [.width, .height]
            addSubview(border)
            recordingBorderView = border
        }
        recordingBorderView?.update(rect: local)
        recordingBorderView?.setRecordingActive(paused)
        needsDisplay = true
    }

    func setRecordingPaused(_ paused: Bool) {
        guard case .active = recordingMode else { return }
        recordingMode = .active(paused: paused)
        recordingBorderView?.setRecordingActive(paused)
    }

    func exitRecordingMode() {
        recordingMode = .none
        recordingRectLocal = .zero
        editGesture = .none
        hoverEdge = nil
        recordingBorderView?.removeFromSuperview()
        recordingBorderView = nil
        needsDisplay = true
    }

    /// 退出编辑模式（enterEditor 幂等重入用）：phase 回蒙层态
    func exitEditorIfNeeded() {
        selectedAnnotationIndex = nil
        hoveredAnnotationIndex = nil
        hoveredAnnotationHandle = nil
        editingTextAnnotationIndex = nil
        stylePreviewSnapshot = nil
        lastKnownTool = .none
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

    /// 安装冻结帧并立即首帧上屏；放大镜像素缓冲放到后台线程异步解码，消除主线程 ~68ms 阻塞
    func installFrozenImage(_ image: CGImage) {
        frozenImage = image
        frozenSampler = nil
        needsDisplay = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let sampler = FrozenSampler(image: image)
            await MainActor.run {
                guard let self, self.frozenImage === image else { return }
                self.frozenSampler = sampler
                if self.phase == .waitingForDrag {
                    self.needsDisplay = true
                }
            }
        }
    }

    /// 供会话级 Carbon Esc 路由调用：若当前正在输入文字，先取消文字输入并返回 true
    func cancelActiveTextEditingIfNeeded() -> Bool {
        guard textField != nil else { return false }
        cancelTextEditing()
        window?.makeFirstResponder(self)
        return true
    }

    /// 上屏首帧即按当前全局鼠标位置对齐 cursorLocal、悬停高亮与十字准星，避免首帧放大镜停在 (0,0) 且光标仍是箭头
    func syncInitialCursor() {
        guard let win = window, phase == .waitingForDrag else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(
            x: min(max(mouse.x - win.frame.minX, 0), bounds.width),
            y: min(max(win.frame.maxY - mouse.y, 0), bounds.height)
        )
        cursorLocal = local
        updateHover(at: local, force: true)
        win.invalidateCursorRects(for: self)
        NSCursor.crosshair.set()
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
        if case .preparing = recordingMode {
            updateHoverEdge(at: local)
            return
        }
        if case .active = recordingMode { return }
        switch phase {
        case .waitingForDrag:
            // 轻提示条上：手型光标（可点），且不抢占下方框选逻辑
            let overHint = shouldShowAXHint && axHintBannerRect?.contains(local) == true
            if overHint != axHintHovered {
                axHintHovered = overHint
                (overHint ? NSCursor.pointingHand : NSCursor.crosshair).set()
            } else if overHint {
                NSCursor.pointingHand.set()
            }
            updateHover(at: local)
            needsDisplay = true      // 放大镜跟随
        case .editing:
            updateHoverEdge(at: local)
            updateHoverAutoRedact(at: local)
            updateAnnotationHover(at: local)
        default:
            break
        }
    }

    // MARK: - 已画标注二次编辑（悬停 / 选中 / 操控柄 / 样式）

    /// 文字命中框实测尺寸（宽 + 字形高）：与 `CGRenderer.drawText` 完全同字体，保证命中框与视觉像素 100% 对齐
    /// （Core 侧不碰字体，尺寸由 UI 量好传回；空文本返回 nil 让 Core 走启发式估宽）
    /// 唯一真源是 `measuredTextMetrics(for:)`，不另外再用 `NSString.size` 量（那还含行距，口径会漂）
    nonisolated private func measuredTextSize(for annotation: AnnotationModel) -> CGSize? {
        guard let metrics = measuredTextMetrics(for: annotation) else { return nil }
        return CGSize(width: metrics.width, height: metrics.height)
    }

    /// 文字排版度量（宽 + 上伸 + 下伸）：与 `CGRenderer.drawText` **完全一致**的字体与 CTLine 量法
    ///
    /// 病例：`.text` 的 anchor 是 CoreText 的**基线**，字形向上延伸 ascent、向下延伸 descent。
    /// 旧实现把 anchor 当左上角 ⇒ 蓝色选中虚线框/悬停框/命中框整体比文字低一整个字高，永远对不齐。
    /// 这里用同一支 `NSFont.systemFont(ofSize:weight: .semibold)` + `CTLineGetTypographicBounds`
    /// 量出精确的 (width, ascent, descent)，交给 Core 按基线口径出框，蓝框与字形像素 1:1 严丝合缝。
    nonisolated private func measuredTextMetrics(for annotation: AnnotationModel) -> AnnotationTextMetrics? {
        guard case .text = annotation.shape,
              let text = annotation.text, !text.isEmpty else { return nil }
        let font = NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return AnnotationTextMetrics(width: width, ascent: ascent, descent: descent)
    }

    /// 是否有「已选中标注」（工具栏据此在 `.none` 选择态也浮出颜色/线宽样式胶囊）
    var hasSelectedAnnotation: Bool {
        guard phase == .editing, editingTextAnnotationIndex == nil else { return false }
        return selectedAnnotationIndex != nil
    }

    /// `.none`（选择与移动态）下的悬停反馈：选中标注的操控柄 → `.crosshair`，本体 → `.openHand`
    private func updateAnnotationHover(at local: CGPoint) {
        guard let session = editorSession,
              session.currentTool == .none,
              case .none = editGesture,
              hoverEdge == nil,
              hoveredAutoRedactRect == nil,
              editorRectLocal.contains(local) else {
            clearAnnotationHover()
            return
        }
        let annotPt = localToAnnotation(local)
        var nextHandle: AnnotationHandle?
        var nextIndex: Int?
        if let sel = selectedAnnotationIndex, session.store.annotations.indices.contains(sel) {
            let annot = session.store.annotations[sel]
            if let handle = AnnotationEditorGeometry.hitTestHandle(
                at: annotPt, for: annot, textSize: measuredTextSize(for: annot)
            ) {
                nextIndex = sel
                nextHandle = handle
            }
        }
        if nextHandle == nil,
           let idx = AnnotationEditorGeometry.hitTestBody(
                at: annotPt,
                in: session.store.annotations,
                textMetricsProvider: { [self] in self.measuredTextMetrics(for: $0) }
           ) {
            nextIndex = idx
            nextHandle = .body
        }
        let hadHover = hoveredAnnotationIndex != nil || hoveredAnnotationHandle != nil
        let changed = nextIndex != hoveredAnnotationIndex || nextHandle != hoveredAnnotationHandle
        hoveredAnnotationIndex = nextIndex
        hoveredAnnotationHandle = nextHandle
        if let nextHandle {
            if case .body = nextHandle {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        } else if hadHover, hoverEdge == nil, hoveredAutoRedactRect == nil {
            // 刚离开标注：只把光标恢复成准星，不碰「独立图内 openHand」等其它态
            NSCursor.crosshair.set()
        }
        if changed { needsDisplay = true }
    }

    private func clearAnnotationHover() {
        guard hoveredAnnotationIndex != nil || hoveredAnnotationHandle != nil else { return }
        hoveredAnnotationIndex = nil
        hoveredAnnotationHandle = nil
        if hoverEdge == nil, hoveredAutoRedactRect == nil { NSCursor.crosshair.set() }
        needsDisplay = true
    }

    /// 会话级 Esc 路由调用：已选中标注则先只取消选中（不关截图），返回 true = 吃掉了这次 Esc
    func dismissAnnotationSelectionIfNeeded() -> Bool {
        guard phase == .editing, selectedAnnotationIndex != nil else { return false }
        selectedAnnotationIndex = nil
        hoveredAnnotationIndex = nil
        hoveredAnnotationHandle = nil
        needsDisplay = true
        controller.refreshToolbar()
        Log.event(.editor, "editor.annotation.deselect", ["via": "esc"])
        return true
    }

    /// undo / redo / 删除后做边界校验（下标漂移越界就清选中，绝不画 ghost 手柄）
    func clampAnnotationSelection() {
        guard let idx = selectedAnnotationIndex else { return }
        guard let session = editorSession, session.store.annotations.indices.contains(idx) else {
            selectedAnnotationIndex = nil
            hoveredAnnotationIndex = nil
            hoveredAnnotationHandle = nil
            needsDisplay = true
            controller.refreshToolbar()
            return
        }
    }

    /// 工具栏换工具：真正换成「画图工具」时清掉标注选中（避免虚线框与新手势抢优先）
    func handleToolbarToolChange() {
        guard let session = editorSession else { return }
        let tool = session.currentTool
        guard tool != lastKnownTool else { return }
        lastKnownTool = tool
        clampAnnotationSelection()
        if tool != .none {
            selectedAnnotationIndex = nil
            hoveredAnnotationIndex = nil
            hoveredAnnotationHandle = nil
            needsDisplay = true
            controller.refreshToolbar()
        }
    }

    /// 工具栏改颜色 / 线宽 → 实时套到当前选中的标注（可单步 ⌘Z 撤销）
    /// - `commit == false`：滑杆拖动中的逐帧预览（不压撤销栈）
    /// - `commit == true`：颜色点选 / 滑杆松手，整段拖动只占一步撤销
    func applyStyleChangeToSelectedAnnotation(
        colorIndex: Int? = nil,
        strokeWidth: CGFloat? = nil,
        commit: Bool = true
    ) {
        guard let session = editorSession,
              let index = selectedAnnotationIndex,
              session.store.annotations.indices.contains(index) else {
            stylePreviewSnapshot = nil
            return
        }
        var updated = session.store.annotations[index]
        if let colorIndex { updated.colorIndex = colorIndex }
        if let strokeWidth { updated.strokeWidth = strokeWidth }

        guard commit else {
            if stylePreviewSnapshot?.index != index { stylePreviewSnapshot = (index, session.store.annotations) }
            if updated != session.store.annotations[index] {
                session.store.previewReplace(at: index, with: updated)
                needsDisplay = true
            }
            return
        }

        if let snapshot = stylePreviewSnapshot, snapshot.index == index {
            // 拖动中：先把最终值落到预览（不压栈），再把「拖动前快照」整体压一步
            session.store.previewReplace(at: index, with: updated)
            session.store.commitMutation(previousAnnotations: snapshot.annotations)
            stylePreviewSnapshot = nil
        } else {
            stylePreviewSnapshot = nil
            session.store.updateStyle(at: index, colorIndex: colorIndex, strokeWidth: strokeWidth)
        }
        controller.refreshToolbar()
        needsDisplay = true
    }

    /// 马赛克工具下悬停在自动脱敏块上时，高亮轻虚线轮廓并切换手型光标，直觉提示「单击可取消该处脱敏」
    private func updateHoverAutoRedact(at local: CGPoint) {
        let nextRect: CGRect?
        if let session = editorSession,
           session.currentTool == .mosaic,
           hoverEdge == nil,
           editorRectLocal.contains(local) {
            nextRect = session.store.autoRedactedRect(at: localToAnnotation(local))
        } else {
            nextRect = nil
        }
        guard nextRect != hoveredAutoRedactRect else { return }
        hoveredAutoRedactRect = nextRect
        if nextRect != nil {
            NSCursor.pointingHand.set()
        } else if hoverEdge == nil {
            NSCursor.crosshair.set()
        }
        needsDisplay = true
    }

    /// 一键脱敏命中后短暂闪一下轻蓝轮廓（~0.55s，不入导出图）
    func flashAutoRedactRects(_ rects: [CGRect]) {
        autoRedactFlashWork?.cancel()
        flashedAutoRedactRects = rects
        needsDisplay = true
        let work = DispatchWorkItem { [weak self] in
            self?.flashedAutoRedactRects = []
            self?.needsDisplay = true
        }
        autoRedactFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    /// 编辑器画布顶部轻提示胶囊（1.6s 后自动收起，仅屏幕可见，绝不入导出图）
    func showEditorToast(_ text: String) {
        editorToastWork?.cancel()
        editorToastText = text
        needsDisplay = true
        let work = DispatchWorkItem { [weak self] in
            self?.editorToastText = nil
            self?.needsDisplay = true
        }
        editorToastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// 编辑态：光标是否压在手柄上（决定光标形状 + 手柄高亮）
    private func updateHoverEdge(at local: CGPoint) {
        let isRecPrep = (recordingMode == .preparing)
        let rect = isRecPrep ? recordingRectLocal : editorRectLocal
        let edge: SelectionEdge? = (rect.width >= SelectionGeometry.handleVisibilityThreshold
            || rect.height >= SelectionGeometry.handleVisibilityThreshold)
            ? SelectionGeometry.edge(atLocal: local, in: rect)
            : nil
        if isRecPrep {
            hoverEdge = edge
            if let edge {
                switch edge {
                case .left, .right: NSCursor.resizeLeftRight.set()
                case .top, .bottom: NSCursor.resizeUpDown.set()
                case .topLeft, .bottomRight, .topRight, .bottomLeft: NSCursor.crosshair.set()
                }
            } else if rect.contains(local) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
            needsDisplay = true
            return
        }
        guard edge != hoverEdge else { return }
        hoverEdge = edge
        if let edge {
            switch edge {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            case .topLeft, .bottomRight: NSCursor.crosshair.set()
            case .topRight, .bottomLeft: NSCursor.crosshair.set()
            }
        } else if isStandaloneImage, editorSession?.currentTool == EditorSession.Tool.none, editorRectLocal.contains(local) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
        needsDisplay = true
    }

    // MARK: - 独立外源图滚轮/捏合缩放与平移

    override func scrollWheel(with event: NSEvent) {
        // 智能框选态：滚轮 = 切候选层级（向内缩 / 向外扩），不让滚轮穿透
        if phase == .waitingForDrag, !scrollMode, recordingMode == .none,
           !edgeFullScreenHover, smartStack.candidates.count > 1 {
            handleSmartLayerScroll(event)
            return
        }
        guard phase == .editing, !scrollMode, isStandaloneImage else {
            super.scrollWheel(with: event)
            return
        }
        let anchor = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.shift) {
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 14
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14
            panStandalone(dx: dx, dy: dy)
            return
        }
        guard event.momentumPhase.isEmpty else { return }
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return }
        let factor: CGFloat
        if event.hasPreciseScrollingDeltas {
            let clamped = min(max(deltaY, -40), 40)
            factor = pow(1.008, clamped)
        } else {
            let clamped = min(max(deltaY, -5), 5)
            factor = pow(1.12, clamped)
        }
        applyStandaloneZoom(factor: factor, anchor: anchor)
    }

    /// 滚轮切层：向上滚动 = 增大层级（向外扩，如 文字行 → 控件 → 区域 → 窗口），
    /// 向下滚动 = 减小层级（向内缩）。惯性尾帧直接忽略，避免一滑跳好几层。
    private func handleSmartLayerScroll(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        guard deltaY != 0 else { return }
        smartScrollAccumulator += deltaY
        let threshold: CGFloat = 12
        guard abs(smartScrollAccumulator) >= threshold else { return }
        let step: Int = smartScrollAccumulator > 0 ? 1 : -1
        smartScrollAccumulator = 0
        stepSmartLayer(by: step, via: "scroll")
    }

    /// 智能框选切层（滚轮 / ↑↓ 共用）：step > 0 向外扩一层，step < 0 向内缩一层。
    /// 切层后置 `smartLayerUserPinned`——后续异步 AX/Vision 回填不再把层级抢回默认值。
    private func stepSmartLayer(by step: Int, via source: String) {
        let count = smartStack.candidates.count
        guard count > 1 else { return }
        let next = min(max(smartCandidateIndex + step, 0), count - 1)
        guard next != smartCandidateIndex else { return }
        smartCandidateIndex = next
        smartLayerUserPinned = true
        applySmartHoverTarget(animate: true)
        needsDisplay = true
        Log.event(.overlay, "overlay.smart.layer", [
            "index": "\(next + 1)/\(count)",
            "kind": smartActiveCandidate?.kind.displayName ?? "?",
            "via": source,
        ])
    }

    override func magnify(with event: NSEvent) {
        guard phase == .editing, !scrollMode, isStandaloneImage else {
            super.magnify(with: event)
            return
        }
        let factor = max(0.2, 1 + event.magnification)
        applyStandaloneZoom(factor: factor, anchor: convert(event.locationInWindow, from: nil))
    }

    private func standaloneWidthBounds(for session: EditorSession) -> (minW: CGFloat, maxW: CGFloat, nativeW: CGFloat, aspect: CGFloat) {
        let backing = max(1, window?.backingScaleFactor ?? 2)
        let imgW = max(1, CGFloat(session.baseImage.width))
        let imgH = max(1, CGFloat(session.baseImage.height))
        let aspect = imgW / imgH
        let nativeW = imgW / backing
        let maxSafeDimPt = min(7200.0, 14400.0 / backing)
        let maxWByHeight = maxSafeDimPt * aspect
        let maxW = max(nativeW, min(max(nativeW * 2.5, bounds.width * 2.0), min(maxSafeDimPt, maxWByHeight)))
        let minW = min(max(80.0, nativeW * 0.1), maxW)
        return (minW, maxW, nativeW, aspect)
    }

    private func applyStandaloneZoom(factor: CGFloat, anchor: CGPoint) {
        guard let session = editorSession, factor > 0 else { return }
        let (minW, maxW, nativeW, aspect) = standaloneWidthBounds(for: session)
        let oldRect = editorRectLocal
        guard oldRect.width > 0, oldRect.height > 0 else { return }
        let newW = min(max(oldRect.width * factor, minW), maxW)
        guard abs(newW - oldRect.width) > 0.25 else { return }
        let newH = newW / aspect
        let u = (anchor.x - oldRect.minX) / oldRect.width
        let v = (anchor.y - oldRect.minY) / oldRect.height
        let newRect = CGRect(
            x: anchor.x - u * newW,
            y: anchor.y - v * newH,
            width: newW,
            height: newH
        )
        editorRectLocal = SelectionGeometry.movedPartiallyVisible(newRect, by: .zero, in: bounds)
        controller.zoomStandaloneSelection(to: convertToGlobalRect(editorRectLocal))
        let pct = Int(round((editorRectLocal.width / max(1, nativeW)) * 100))
        showStandaloneZoomHUD("\(pct)%")
        needsDisplay = true
    }

    private func panStandalone(dx: CGFloat, dy: CGFloat) {
        guard editorSession != nil else { return }
        let next = SelectionGeometry.movedPartiallyVisible(editorRectLocal, by: CGSize(width: dx, height: dy), in: bounds)
        guard next != editorRectLocal else { return }
        editorRectLocal = next
        controller.zoomStandaloneSelection(to: convertToGlobalRect(editorRectLocal))
        syncToolbarForLiveSelection()
        needsDisplay = true
    }

    private func toggleStandaloneDoubleClickZoom(at point: CGPoint) {
        guard let session = editorSession else { return }
        let (_, maxW, nativeW, aspect) = standaloneWidthBounds(for: session)
        let fitRect = standaloneFitRectLocal.width > 10 ? standaloneFitRectLocal : editorRectLocal
        let isNearFit = abs(editorRectLocal.width - fitRect.width) < 6
        if isNearFit && nativeW > fitRect.width * 1.15 {
            let targetW = min(nativeW, maxW)
            let targetH = targetW / aspect
            let u = (point.x - editorRectLocal.minX) / max(1, editorRectLocal.width)
            let v = (point.y - editorRectLocal.minY) / max(1, editorRectLocal.height)
            let zoomed = CGRect(x: point.x - u * targetW, y: point.y - v * targetH, width: targetW, height: targetH)
            editorRectLocal = SelectionGeometry.movedPartiallyVisible(zoomed, by: .zero, in: bounds)
            controller.zoomStandaloneSelection(to: convertToGlobalRect(editorRectLocal))
            showStandaloneZoomHUD("1:1")
        } else {
            editorRectLocal = fitRect
            controller.zoomStandaloneSelection(to: convertToGlobalRect(editorRectLocal))
            let pct = Int(round((fitRect.width / max(1, nativeW)) * 100))
            showStandaloneZoomHUD("\(pct)%")
        }
        needsDisplay = true
    }

    private func showStandaloneZoomHUD(_ text: String) {
        standaloneZoomHudText = text
        standaloneZoomHudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.standaloneZoomHudText = nil
            self?.needsDisplay = true
        }
        standaloneZoomHudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hoveredLocalRect != nil || !smartStack.isEmpty else { return }
        clearHover()
    }

    // MARK: - 智能框选（实时候选栈 / 滚轮切层）

    /// 智框状态彻底重置（窗口复用：新会话新冻结帧，视觉缓存一并清空）
    private func resetSmartSelectionState() {
        smartProbeTask?.cancel()
        smartProbeTask = nil
        smartProbeEpoch &+= 1
        latestAXCandidates = []
        latestWindowCandidate = nil
        smartStack = .empty
        smartCandidateIndex = 0
        smartLayerUserPinned = false
        smartScrollAccumulator = 0
        smartTextLines = []
        smartVisualRects = []
        smartVisualTables = []
        hoveredLocalRect = nil
        edgeFullScreenHover = false
        hoverMorphFromRect = nil
        hoverMorphStart = 0
        hoverFadeStart = 0
    }

    /// 视觉探测回填：文本行（最早就绪的一层）
    func updateSmartVisionTextLines(_ lines: [CGRect]) {
        smartTextLines = lines
        refreshSmartStackAfterVisionUpdate()
    }

    /// 视觉探测回填：控件 / 区域
    func updateSmartVisionRects(_ rects: [CGRect]) {
        smartVisualRects = rects
        refreshSmartStackAfterVisionUpdate()
    }

    /// 视觉探测回填：表格结构（单元格 / 行 / 列）
    func updateSmartVisionTables(_ tables: [DetectedVisualTable]) {
        smartVisualTables = tables
        refreshSmartStackAfterVisionUpdate()
    }

    /// 新视觉结果到达时，若仍在选区悬停态，立即用缓存重算当前光标处候选栈并平滑过渡
    private func refreshSmartStackAfterVisionUpdate() {
        guard phase == .waitingForDrag, !edgeFullScreenHover, recordingMode == .none else { return }
        guard !NSEvent.modifierFlags.contains(.option), let frame = window?.frame else { return }
        let global = CGPoint(x: frame.minX + cursorLocal.x, y: frame.maxY - cursorLocal.y)
        rebuildSmartStack(atGlobalPoint: global, screenFrame: frame, resetIndex: false)
    }

    /// 用「当前缓存的文本行 + 识别区域 + 表格结构 + AX 控件 + 窗口」重算候选栈，并平滑变形到当前层级
    private func rebuildSmartStack(atGlobalPoint global: CGPoint, screenFrame: CGRect, resetIndex: Bool) {
        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: global,
            screenFrame: screenFrame,
            textLines: smartTextLines,
            visualRects: smartVisualRects,
            visualTables: smartVisualTables,
            axCandidates: latestAXCandidates,
            windowCandidate: latestWindowCandidate
        )
        let count = stack.candidates.count
        if resetIndex {
            smartLayerUserPinned = false
            smartCandidateIndex = count > 0 ? min(max(stack.defaultIndex, 0), count - 1) : 0
        } else if !smartLayerUserPinned {
            // 异步 AX / Vision 到达且用户尚未滚轮切层时，跟随解析器算出的最优默认层级
            smartCandidateIndex = count > 0 ? min(max(stack.defaultIndex, 0), count - 1) : 0
        } else {
            smartCandidateIndex = count > 0 ? min(max(smartCandidateIndex, 0), count - 1) : 0
        }
        smartStack = stack
        applySmartHoverTarget(animate: true)
    }

    /// 当前层级候选 → 悬停高亮矩形（160ms 平滑变形，60fps 重绘由 drawSelection 自行排程）
    private func applySmartHoverTarget(animate: Bool) {
        let prevRect = currentHoverVisualRect()
        guard let candidate = smartActiveCandidate, let frame = window?.frame else {
            hoverMorphFromRect = nil
            hoveredLocalRect = nil
            hoverFadeStart = 0
            needsDisplay = true
            return
        }
        let next = localRect(fromGlobal: candidate.rectGlobal, frame: frame)
        guard next != hoveredLocalRect else {
            // 矩形未变但候选总数可能已更新（异步补齐），仍刷新角标文案
            needsDisplay = true
            return
        }
        hoverMorphFromRect = animate ? prevRect : nil
        hoverMorphStart = CACurrentMediaTime()
        hoverFadeStart = hoverMorphStart
        hoveredLocalRect = next
        needsDisplay = true
    }

    /// 异步 AX 探测控件候选（防乱序：代际 + 态 + Option 校验，过期结果一律丢弃）
    private func startSmartProbeTask(atGlobalPoint global: CGPoint) {
        smartProbeEpoch &+= 1
        let epoch = smartProbeEpoch
        smartProbeTask?.cancel()
        smartProbeTask = nil
        guard let prober = AppCoordinatorShared.deps?.smartElementProber else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? bounds.height
        smartProbeTask = Task { [weak self] in
            let axCandidates = await prober.probe(
                atGlobalPoint: global,
                mainScreenHeight: mainHeight,
                excludingPID: getpid()
            )
            guard let self, !Task.isCancelled, epoch == self.smartProbeEpoch,
                  self.phase == .waitingForDrag,
                  !self.edgeFullScreenHover,
                  !NSEvent.modifierFlags.contains(.option),
                  let frame = self.window?.frame else { return }
            self.latestAXCandidates = axCandidates
            self.rebuildSmartStack(atGlobalPoint: global, screenFrame: frame, resetIndex: false)
        }
    }

    /// 鼠标位置的智能候选探测（三层融合，越内层越优先，滚轮可切层）：
    /// - 鼠标靠近屏幕四边（≤14pt）：框体平滑变形为整屏预览（单击/Enter 框选整屏）；
    /// - 屏内：文本行 / AX 控件 / 识别区域 / 窗口 由 SmartCandidateResolver 融合成候选栈，
    ///   视觉结果与窗口候选都走同步缓存（0ms 响应），只有 AX 探测是异步回填。
    private func updateHover(at local: CGPoint, force: Bool = false) {
        // Option 按住 = 临时禁用智能框选（保留手动拖选）
        if NSEvent.modifierFlags.contains(.option) {
            clearHover()
            return
        }
        let edgeMargin: CGFloat = 14
        let nearEdge = local.x <= edgeMargin
            || local.x >= bounds.width - edgeMargin
            || local.y <= edgeMargin
            || local.y >= bounds.height - edgeMargin

        if nearEdge {
            if !edgeFullScreenHover {
                let startRect = currentHoverVisualRect()
                    ?? CGRect(x: local.x - 40, y: local.y - 30, width: 80, height: 60)
                hoverMorphFromRect = startRect
                hoverMorphStart = CACurrentMediaTime()
                hoverFadeStart = hoverMorphStart
                edgeFullScreenHover = true
                // 整屏预览是最高层级：撤掉智能候选与在途 AX 探测
                smartProbeTask?.cancel()
                smartProbeTask = nil
                smartProbeEpoch &+= 1
                latestAXCandidates = []
                latestWindowCandidate = nil
                smartStack = .empty
                smartCandidateIndex = 0
                smartScrollAccumulator = 0
                hoveredLocalRect = bounds
                needsDisplay = true
            }
            return
        }

        let leavingEdge = edgeFullScreenHover
        if leavingEdge {
            edgeFullScreenHover = false
        }

        let now = CACurrentMediaTime()
        let moved = abs(local.x - hoverProbePoint.x) > 2.5 || abs(local.y - hoverProbePoint.y) > 2.5
        guard leavingEdge || moved || force || now - hoverProbeTime > 0.08 else { return }
        hoverProbePoint = local
        hoverProbeTime = now
        guard let frame = window?.frame else { return }
        let global = CGPoint(x: frame.minX + local.x, y: frame.maxY - local.y)

        // ① 窗口命中最便宜（纯 CGWindowList 查询）——同步算出，0ms 即可给出窗口层候选
        // 近似满屏大窗的剪枝交给 SmartCandidateResolver（“无更细目标才剔除 / 有更细目标留在栈顶供滚轮切出”），
        // 这里不做任何预筛，否则最大化窗口永远没法滚轮切到整窗
        latestWindowCandidate = WindowLocator
            .window(atGlobalPoint: global, excludingPID: getpid())
            .map { win in
                SmartSelectionCandidate(
                    rectGlobal: win.rectGlobal,
                    kind: .window,
                    windowID: win.windowID,
                    ownerName: win.ownerName,
                    title: win.title
                )
            }

        // ② 点已移出上一轮 AX 候选范围：立刻丢弃，绝不让过期控件框跟着光标跑
        if !latestAXCandidates.isEmpty,
           !latestAXCandidates.contains(where: { $0.rectGlobal.contains(global) }) {
            latestAXCandidates = []
        }

        // ③ 文本行 / 识别区域 / 窗口都是已缓存结果：同步重算，0ms 出框
        rebuildSmartStack(atGlobalPoint: global, screenFrame: frame, resetIndex: true)
        // ④ AX 控件候选异步补齐（同点同代位合并后仍走平滑过渡）
        startSmartProbeTask(atGlobalPoint: global)
    }

    /// AppKit 全局矩形（Y 向上）→ 视图本地矩形（Y 向下）
    private func localRect(fromGlobal rect: CGRect, frame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - frame.minX,
            y: frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Option 键：按住临时禁用智能框选（立刻清智能高亮，保留手动拖选），松开后重算悬停
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard phase == .waitingForDrag, !scrollMode, recordingMode == .none else { return }
        if event.modifierFlags.contains(.option) {
            smartProbeTask?.cancel()
            smartProbeTask = nil
            smartProbeEpoch &+= 1
            latestAXCandidates = []
            latestWindowCandidate = nil
            smartStack = .empty
            smartCandidateIndex = 0
            smartScrollAccumulator = 0
            hoveredLocalRect = nil
            edgeFullScreenHover = false
            hoverMorphFromRect = nil
            hoverFadeStart = 0
            needsDisplay = true
        } else {
            updateHover(at: cursorLocal, force: true)
        }
    }

    private func currentHoverVisualRect() -> CGRect? {
        guard let target = hoveredLocalRect else { return nil }
        guard let from = hoverMorphFromRect, hoverMorphStart > 0 else { return target }
        let tRaw = min(1, max(0, (CACurrentMediaTime() - hoverMorphStart) / 0.16))
        // ease-out cubic
        let t = CGFloat(1 - pow(1 - tRaw, 3))
        return CGRect(
            x: from.minX + (target.minX - from.minX) * t,
            y: from.minY + (target.minY - from.minY) * t,
            width: from.width + (target.width - from.width) * t,
            height: from.height + (target.height - from.height) * t
        )
    }

    private func clearHover() {
        smartProbeTask?.cancel()
        smartProbeTask = nil
        smartProbeEpoch &+= 1
        latestAXCandidates = []
        latestWindowCandidate = nil
        smartStack = .empty
        smartCandidateIndex = 0
        smartLayerUserPinned = false
        smartScrollAccumulator = 0
        // 文本行/识别区域是「冻结帧级」缓存，与光标无关——这里刻意保留，
        // 否则 Option 临时开关或鼠标移出再回来就要重新等 20-40ms 才出框
        edgeFullScreenHover = false
        hoveredLocalRect = nil
        hoverMorphFromRect = nil
        hoverMorphStart = 0
        hoverFadeStart = 0
        needsDisplay = true
    }

    // MARK: - 光标

    override func resetCursorRects() {
        if case .preparing = recordingMode {
            addCursorRect(recordingRectLocal, cursor: .openHand)
            addCursorRect(bounds.minus(recordingRectLocal), cursor: .arrow)
            return
        }
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
        ignoreNextMouseUpAfterEarlyCommit = false
        phase = .dragging(start: point)
        selectionLocal = CGRect(origin: point, size: .zero)
        Log.event(.overlay, "overlay.drag.recover", ["pt": "\(Int(point.x)),\(Int(point.y))"])
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        ignoreNextMouseUpAfterEarlyCommit = false
        let point = convert(event.locationInWindow, from: nil)
        Log.event(.overlay, "overlay.mousedown", [
            "phase": phaseLabel, "pt": "\(Int(point.x)),\(Int(point.y))",
        ])
        if case .preparing = recordingMode {
            if let edge = SelectionGeometry.edge(atLocal: point, in: recordingRectLocal) {
                editGesture = .resize(edge: edge, startRect: recordingRectLocal)
            } else if recordingRectLocal.contains(point) {
                editGesture = .move(startRect: recordingRectLocal, startPoint: point)
            }
            return
        }
        switch phase {
        case .waitingForDrag:
            // 辅助功能轻提示条优先吃点击：点主区 = 退出截图并直达授权；点 × = 不再提示
            // （两条路径都不进入拖选，也不影响后续继续截图）
            if shouldShowAXHint, let banner = axHintBannerRect, banner.contains(point) {
                if let closeRect = axHintCloseRect, closeRect.contains(point) {
                    dismissAccessibilityHint()
                } else {
                    activateAccessibilityHint()
                }
                return
            }
            // 智能框选（用户裁定）：单击 = 直接确认当前智能候选 0ms 秒进编辑态，
            // 因此这里不再做「双击=全屏」的双击分流（全屏走边缘 ≤14pt 悬停单击 / Enter / 快捷键）；
            // 按下即进入框选，拖动仍可自由改选区。
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
        if case .preparing = recordingMode {
            let point = convert(event.locationInWindow, from: nil)
            switch editGesture {
            case .resize(let edge, let startRect):
                recordingRectLocal = SelectionGeometry.resized(startRect, edge: edge, to: point, limit: bounds)
            case .move(let startRect, let startPoint):
                let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
                recordingRectLocal = SelectionGeometry.moved(startRect, by: delta, limit: bounds)
            case .none, .editAnnotation:
                return
            }
            if let screen = window?.screen {
                controller.updateRecordingRegionGlobal(convertToGlobalRect(recordingRectLocal), on: screen)
            }
            needsDisplay = true
            return
        }
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
        if ignoreNextMouseUpAfterEarlyCommit {
            ignoreNextMouseUpAfterEarlyCommit = false
            Log.event(.overlay, "overlay.mouseup.ignoredAfterEarlyCommit", ["phase": phaseLabel])
            return
        }
        if case .preparing = recordingMode {
            commitRecordingEditGestureIfNeeded()
            return
        }
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
                // 单击（未拖动）确认：边缘全屏 → 整屏；否则当前智能候选 → 0ms 秒进编辑态
                if edgeFullScreenHover {
                    pickFullDisplay()
                } else if let candidate = smartActiveCandidate {
                    pickSmartCandidate(candidate)
                }
                return
            }
            _ = commitDraggingSelection(via: "mouseUp")
        case .editing:
            handleEditorMouseUp(convert(event.locationInWindow, from: nil))
        default:
            break
        }
    }

    /// 统一提交当前拖选框（mouseUp / 拖拽期直接按 Enter 或快捷键共用）
    @discardableResult
    private func commitDraggingSelection(via: String) -> Bool {
        guard case .dragging = phase,
              selectionLocal.width >= minSelectionSize,
              selectionLocal.height >= minSelectionSize else {
            return false
        }
        Log.event(.overlay, "overlay.drag.commit", [
            "via": via,
            "sel": "\(Int(selectionLocal.minX)),\(Int(selectionLocal.minY)),\(Int(selectionLocal.width)),\(Int(selectionLocal.height))",
        ])
        selectionLocal = snapToPixelGrid(selectionLocal)
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
        return true
    }

    private func commitRecordingEditGestureIfNeeded() {
        if case .none = editGesture { return }
        recordingRectLocal = snapToPixelGrid(recordingRectLocal)
        editGesture = .none
        if let screen = window?.screen {
            controller.updateRecordingRegionGlobal(convertToGlobalRect(recordingRectLocal), on: screen)
        }
        needsDisplay = true
    }

    // MARK: - 整窗 / 全屏采集

    /// 智能候选确认（单击 / Enter 共用）：
    /// - 直接裁冻结帧（windowID=nil）= 0ms 秒进编辑态，不用等屏捕；
    /// - 只有 `.window` 层拿 windowID 走 SCK 单窗口滤镜（被遮挡也正确）。
    private func pickSmartCandidate(_ target: SmartSelectionCandidate) {
        guard let screen = window?.screen else { return }
        if let frame = window?.frame {
            selectionLocal = snapToPixelGrid(CGRect(
                x: target.rectGlobal.minX - frame.minX,
                y: frame.maxY - target.rectGlobal.maxY,
                width: target.rectGlobal.width,
                height: target.rectGlobal.height
            ))
        }
        phase = .confirmed
        needsDisplay = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        Log.event(.overlay, "overlay.pick.smart", [
            "kind": target.kind.displayName,
            "owner": target.ownerName,
            "title": target.title,
            "size": "\(Int(target.rectGlobal.width))x\(Int(target.rectGlobal.height))",
            "layer": "\(smartCandidateIndex + 1)/\(max(1, smartStack.candidates.count))",
        ])
        if Self.isWindowKind(target.kind), let windowID = target.windowID {
            controller.didSelect(rect: target.rectGlobal, on: screen, windowID: windowID)
        } else {
            // 文本行 / 控件 / 区域 / 识别块：直接裁冻结帧，0ms 进编辑态（所见 = 所得）
            controller.didSelect(rect: target.rectGlobal, on: screen, windowID: nil)
        }
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

        let annotPt = localToAnnotation(point)

        // 3.5) 双击已有 `.text` 标注 = 原地改字（.none / .text 工具；已有输入框时不抢）
        if textField == nil,
           session.currentTool == .none || session.currentTool == .text,
           event.clickCount >= 2,
           let idx = AnnotationEditorGeometry.hitTestBody(
                at: annotPt,
                in: session.store.annotations,
                textMetricsProvider: { [self] in self.measuredTextMetrics(for: $0) }
           ),
           case .text = session.store.annotations[idx].shape {
            beginInlineReeditText(atIndex: idx)
            return
        }

        switch session.currentTool {
        case .none:
            handleSelectionToolMouseDown(at: point, annotationPoint: annotPt, clickCount: event.clickCount)
        case .text:
            beginTextEditing(at: annotPt)
        case .sequence:
            controller.addAnnotation(AnnotationModel(
                shape: .sequence(anchor: annotPt),
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

    /// `.none` 工具态：操控柄 → 本体（单击选中 / 按住直接拖走）→ 空白（清选中 + 原有选区行为）
    private func handleSelectionToolMouseDown(at point: CGPoint, annotationPoint annotPt: CGPoint, clickCount: Int) {
        guard let session = editorSession else { return }
        // 新的手势开始：丢掉上一轮可能残留的样式预览快照
        stylePreviewSnapshot = nil
        // ① 当前选中标注的操控柄优先（贴着角的拖拽走缩放，不被当成本体平移）
        if let sel = selectedAnnotationIndex, session.store.annotations.indices.contains(sel) {
            let annot = session.store.annotations[sel]
            if let handle = AnnotationEditorGeometry.hitTestHandle(
                at: annotPt, for: annot, textSize: measuredTextSize(for: annot)
            ) {
                selectedAnnotationIndex = sel
                editGesture = .editAnnotation(
                    index: sel,
                    handle: handle,
                    startPoint: annotPt,
                    initialAnnotation: annot,
                    preMutationSnapshot: session.store.annotations
                )
                Log.event(.editor, "editor.annotation.handle", ["handle": "\(handle)"])
                needsDisplay = true
                controller.refreshToolbar()
                return
            }
        }
        // ② 本体命中：单击选中（按住同一手势即可直接拖走）
        if let idx = AnnotationEditorGeometry.hitTestBody(
            at: annotPt,
            in: session.store.annotations,
            textMetricsProvider: { [self] in self.measuredTextMetrics(for: $0) }
        ) {
            let annot = session.store.annotations[idx]
            selectedAnnotationIndex = idx
            hoveredAnnotationIndex = idx
            hoveredAnnotationHandle = .body
            needsDisplay = true
            editGesture = .editAnnotation(
                index: idx,
                handle: .body,
                startPoint: annotPt,
                initialAnnotation: annot,
                preMutationSnapshot: session.store.annotations
            )
            Log.event(.editor, "editor.annotation.select", ["index": "\(idx)", "shape": "\(annot.shape)"])
            controller.refreshToolbar()
            return
        }
        // ③ 空白处：清选中，保持原有行为（独立图双击缩放 / 拖动整体移动选区）
        if selectedAnnotationIndex != nil {
            selectedAnnotationIndex = nil
            hoveredAnnotationIndex = nil
            hoveredAnnotationHandle = nil
            needsDisplay = true
            controller.refreshToolbar()
        }
        if isStandaloneImage && clickCount >= 2 {
            toggleStandaloneDoubleClickZoom(at: point)
            return
        }
        // 无工具默认态（用户裁定）：拖动 = 整体移动选区（不用按空格）
        editGesture = .move(startRect: editorRectLocal, startPoint: point)
    }

    private func syncToolbarForLiveSelection() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        controller.repositionToolbar(forLiveSelectionGlobal: convertToGlobalRect(editorRectLocal), on: screen)
    }

    private func handleEditorDragged(_ point: CGPoint) {
        switch editGesture {
        case .resize(let edge, let startRect):
            if isStandaloneImage, let session = editorSession {
                let (minW, maxW, nativeW, aspect) = standaloneWidthBounds(for: session)
                editorRectLocal = SelectionGeometry.resizedAspectLocked(
                    startRect, edge: edge, to: point, aspect: aspect,
                    minWidth: minW, maxWidth: maxW
                )
                let pct = Int(round((editorRectLocal.width / max(1, nativeW)) * 100))
                showStandaloneZoomHUD("\(pct)%")
            } else {
                editorRectLocal = SelectionGeometry.resized(
                    startRect, edge: edge, to: point, limit: bounds
                )
            }
            syncToolbarForLiveSelection()
            needsDisplay = true
            return
        case .move(let startRect, let startPoint):
            let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            if isStandaloneImage {
                editorRectLocal = SelectionGeometry.movedPartiallyVisible(startRect, by: delta, in: bounds)
            } else {
                editorRectLocal = SelectionGeometry.moved(startRect, by: delta, limit: bounds)
            }
            syncToolbarForLiveSelection()
            needsDisplay = true
            return
        case .editAnnotation(let index, let handle, let startPoint, let initialAnnotation, _):
            // 已画标注二次编辑：每帧用「按下快照 + 累计 delta」重算，幂等无漂移
            let annotPt = localToAnnotation(point)
            let delta = CGSize(width: annotPt.x - startPoint.x, height: annotPt.y - startPoint.y)
            let updated = AnnotationEditorGeometry.transformed(
                initialAnnotation, handle: handle, delta: delta
            )
            editorSession?.store.previewReplace(at: index, with: updated)
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

    /// 将选区对齐到屏幕物理像素格（如 2x Retina 按 0.5pt 取整），保证裁剪与 1:1 绘制零亚像素偏移
    private func snapToPixelGrid(_ rect: CGRect) -> CGRect {
        guard !isStandaloneImage else { return rect }
        let scale = max(1, window?.backingScaleFactor ?? 2)
        let invScale = 1.0 / scale
        let minX = max(0, (rect.minX * scale).rounded() * invScale)
        let minY = max(0, (rect.minY * scale).rounded() * invScale)
        let maxX = min(bounds.width, (rect.maxX * scale).rounded() * invScale)
        let maxY = min(bounds.height, (rect.maxY * scale).rounded() * invScale)
        return CGRect(
            x: minX,
            y: minY,
            width: max(invScale, maxX - minX),
            height: max(invScale, maxY - minY)
        )
    }

    private func commitSelectionResize() {
        guard editorSession != nil, let screen = window?.screen else { return }
        let oldLocal = sessionLocalRect()
        editorRectLocal = snapToPixelGrid(editorRectLocal)
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
        editorRectLocal = snapToPixelGrid(editorRectLocal)
        let newLocal = editorRectLocal
        let offset = SelectionGeometry.annotationOffset(old: oldLocal, new: newLocal)
        let global = convertToGlobalRect(newLocal)
        controller.adjustSelection(to: global, on: screen, annotationOffset: offset)
        reclaimKeyboard()
    }

    /// 取色：采样冻结帧光标处像素 → 写剪贴板（hex）→ 结束会话
    /// 取色闭环：采样冻结帧光标处像素 → 按当前格式写剪贴板 → 音效 + 色卡轻提示 → 结束会话
    private func copyColorUnderCursor() {
        guard let sampler = frozenSampler, let frozen = frozenImage else { return }
        let px = Int(cursorLocal.x / max(1, bounds.width) * CGFloat(frozen.width))
        let py = Int(cursorLocal.y / max(1, bounds.height) * CGFloat(frozen.height))
        guard let rgba = sampler.rgba(x: px, y: py) else { return }
        let formatted = sampler.formatted(x: px, y: py, format: colorCopyFormat)
        let secondary = sampler.secondaryInfo(x: px, y: py, format: colorCopyFormat)
        _ = AppCoordinatorShared.deps?.clipboard.writeText(formatted)
        CaptureSoundPlayer.play()
        Log.event(.overlay, "overlay.copyColor", [
            "format": colorCopyFormat.rawValue,
            "value": formatted,
            "x": "\(px)", "y": "\(py)",
        ])
        controller.perform(action: .cancel)
        CaptureToast.showColorCopied(
            formatted: formatted,
            secondary: secondary,
            r: rgba.r, g: rgba.g, b: rgba.b
        )
    }

    /// ⇧C：轮换取色格式（HEX → RGB → HSL）并落盘，不关遮罩（可直接接着取下一个颜色）
    private func cycleColorCopyFormat() {
        colorCopyFormat = colorCopyFormat.next()
        ColorCopyFormat.persisted = colorCopyFormat
        needsDisplay = true
        Log.event(.overlay, "overlay.colorFormat", ["format": colorCopyFormat.rawValue])
    }

    /// 方向键微调选中标注；返回 true = 吃掉这次方向键（不动整个选区框）
    @discardableResult
    private func nudgeSelectedAnnotation(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let session = editorSession,
              let idx = selectedAnnotationIndex,
              session.store.annotations.indices.contains(idx) else { return false }
        let moved = session.store.annotations[idx].offsetBy(dx: dx, dy: dy)
        session.store.replace(at: idx, with: moved)
        controller.refreshToolbar()
        needsDisplay = true
        return true
    }

    /// 删除选中标注（Delete / ⌦）；返回 true = 吃掉这次按键
    @discardableResult
    private func deleteSelectedAnnotationIfNeeded() -> Bool {
        guard let session = editorSession,
              let idx = selectedAnnotationIndex,
              session.store.remove(at: idx) else { return false }
        selectedAnnotationIndex = nil
        hoveredAnnotationIndex = nil
        hoveredAnnotationHandle = nil
        stylePreviewSnapshot = nil
        controller.refreshToolbar()
        needsDisplay = true
        Log.event(.editor, "editor.annotation.delete", ["index": "\(idx)"])
        return true
    }

    /// 键盘微调选区（编辑态方向键）
    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        let newLocal = isStandaloneImage
            ? SelectionGeometry.movedPartiallyVisible(editorRectLocal, by: CGSize(width: dx, height: dy), in: bounds)
            : SelectionGeometry.nudged(editorRectLocal, dx: dx, dy: dy, limit: bounds)
        guard newLocal != editorRectLocal else { return }
        editorRectLocal = newLocal
        needsDisplay = true
        commitSelectionMove()
    }

    private var phaseLabel: String {
        if scrollMode { return "scroll" }
        switch recordingMode {
        case .preparing: return "rec-prep"
        case .active: return "rec-active"
        case .none: break
        }
        switch phase {
        case .waitingForDrag: return "wait"
        case .dragging: return "drag"
        case .confirmed: return "confirm"
        case .editing: return "edit"
        }
    }

    private func handleEditorMouseUp(_ point: CGPoint) {
        // 已画标注二次编辑：拖拽结束 → 整段拖拽只压一步撤销（单步 ⌘Z）
        if case .editAnnotation(_, _, _, _, let preMutationSnapshot) = editGesture {
            editorSession?.store.commitMutation(previousAnnotations: preMutationSnapshot)
            editGesture = .none
            pendingAnnotation = nil
            stylePreviewSnapshot = nil
            controller.refreshToolbar()
            needsDisplay = true
            return
        }
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
            if rect.width < 3 || rect.height < 3 {
                pendingAnnotation = nil
                pendingStartPoint = nil
                // 单击已有「自动脱敏」块：精准取消该处打码（压撤销栈，⌘Z 可恢复）
                if session.store.removeAutoRedacted(at: a) {
                    // 删除会让后续下标整体前移：选中态直接清掉（绝不让虚线框套在别的标注上）
                    selectedAnnotationIndex = nil
                    hoveredAnnotationIndex = nil
                    hoveredAnnotationHandle = nil
                    hoveredAutoRedactRect = nil
                    controller.refreshToolbar()
                    showEditorToast("已取消该处脱敏")
                    Log.event(.editor, "redact.removeSingle", [:])
                }
                needsDisplay = true
                return false
            }
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
        guard let pending = pendingAnnotation, editorSession != nil else { return }
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

    private func beginTextEditing(at annotationPoint: CGPoint, prefill: String = "") {
        commitTextFieldIfNeeded()

        let pointSize = CGFloat(editorSession?.textFontSize ?? OverlayView.textFontSizes[1])
        let localPoint = annotationToLocal(annotationPoint)
        let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let fieldHeight = Self.preferredTextFieldHeight(for: font)
        let initialWidth = Self.preferredTextFieldWidth(text: prefill, font: font, maxWidth: max(96, editorRectLocal.maxX - localPoint.x - 4))
        // 使输入框内文字基线与点击处自然对齐，减少提交瞬间的位移跳动
        let originX = min(max(localPoint.x - GlassTextField.padX, editorRectLocal.minX + 2), max(editorRectLocal.minX + 2, editorRectLocal.maxX - initialWidth - 2))
        let originY = min(max(localPoint.y - fieldHeight / 2, editorRectLocal.minY + 2), max(editorRectLocal.minY + 2, editorRectLocal.maxY - fieldHeight - 2))

        let field = GlassTextField(frame: NSRect(
            x: originX.rounded(),
            y: originY.rounded(),
            width: initialWidth,
            height: fieldHeight
        ))
        field.font = font
        let paletteColor = currentAnnotationColor()
        field.textColor = paletteColor
        field.annotationColor = paletteColor
        field.refreshPlaceholder()
        field.target = self
        field.action = #selector(textFieldCommit(_:))
        field.delegate = self
        addSubview(field)
        playTextFieldEntrance(field)
        textField = field
        // 原地改字：预填原文字（必须在 becomeFirstResponder 之前写入，fieldEditor 才会带上内容）
        if !prefill.isEmpty { field.stringValue = prefill }
        window?.makeFirstResponder(field)
        if !prefill.isEmpty,
           let editor = window?.fieldEditor(false, for: field) as? NSTextView {
            // 全选：直接键入即整段覆盖
            editor.selectAll(nil)
        }
        installFontSizePicker(near: field.frame)
        textFieldAnchor = annotationPoint
    }

    /// 双击已有 `.text` 标注 = 原地改字：预填原文字并全选，Enter 提交（单步可 ⌘Z）/ Esc 原样恢复
    private func beginInlineReeditText(atIndex index: Int) {
        guard let session = editorSession, session.store.annotations.indices.contains(index) else { return }
        let annot = session.store.annotations[index]
        guard case .text(let anchor) = annot.shape, let text = annot.text, !text.isEmpty else { return }

        // 先收掉可能存在的上一只输入框（幂等），再标记「这一条正在原地改字」
        commitTextFieldIfNeeded()
        selectedAnnotationIndex = index
        editingTextAnnotationIndex = index
        // 工具栏同步该标注的样式：改字同时可换色 / 改字号
        let slot = ((annot.colorIndex % AnnotationModel.palette.count) + AnnotationModel.palette.count)
            % AnnotationModel.palette.count
        session.colorIndex = slot
        session.textFontSize = Self.nearestTextFontSize(to: annot.fontSize)
        controller.refreshToolbar()   // 同步颜色/字号档位，同时收起样式胶囊（改字时输入框+字号条已够）

        // 输入框垂直居中于落点 → 把落点落在文字真实垂直中点上（而不是顶边），改字前后零跳动
        //
        // 逆运算（与 `beginTextEditing` / `commitTextFieldIfNeeded` 精确互逆）：
        //   begin:  originX = placement.x - padX            originY = placement.y - fieldHeight / 2
        //   commit: anchor.x = field.minX + padX + 2        anchor.y = field.minY + topInset + ascender
        // 而 topInset = (fieldHeight - (ascender - descender)) / 2，即输入框内文字基线相对框顶的偏移。
        // 因此零位移落点：
        //   placement.x = anchor.x - 2
        //   placement.y = anchor.y - (ascender + descender) / 2   （descender 为负值 ⇒ 正好是基线上方的垂直中点）
        let placementFont = NSFont.systemFont(ofSize: CGFloat(session.textFontSize), weight: .semibold)
        let placement = CGPoint(
            x: anchor.x - 2,
            y: anchor.y - (placementFont.ascender + placementFont.descender) / 2
        )
        beginTextEditing(at: placement, prefill: text)
        needsDisplay = true
        Log.event(.editor, "editor.text.reedit", [
            "index": "\(index)",
            "chars": "\(text.count)",
            "size": "\(Int(annot.fontSize))",
        ])
    }

    /// 现有字号归一到最近的 4 档（12/14/17/21）
    private static func nearestTextFontSize(to fontSize: CGFloat) -> Int {
        textFontSizes.min { abs(CGFloat($0) - fontSize) < abs(CGFloat($1) - fontSize) }
            ?? textFontSizes[1]
    }

    /// 供工具栏点选颜色或字号时实时同步正在输入中的文字颜色、字号与浮条选中态
    func syncActiveTextColor() {
        guard let field = textField as? GlassTextField else { return }
        let color = currentAnnotationColor()
        field.textColor = color
        field.annotationColor = color
        if let size = editorSession?.textFontSize {
            let targetFont = NSFont.systemFont(ofSize: CGFloat(size), weight: .semibold)
            if field.font?.pointSize != targetFont.pointSize {
                field.font = targetFont
                resizeActiveTextField()
            }
            if let idx = Self.textFontSizes.firstIndex(of: size) {
                fontSizePicker?.select(index: idx, animated: true)
            }
        }
        field.refreshPlaceholder()
        if let editor = window?.fieldEditor(false, for: field) as? NSTextView {
            editor.insertionPointColor = color
        }
    }

    private func currentAnnotationColor() -> NSColor {
        if let colorIndex = editorSession?.colorIndex, AnnotationModel.palette.indices.contains(colorIndex) {
            return NSColor(cgColor: AnnotationModel.palette[colorIndex].cgColor) ?? .systemRed
        }
        return .systemRed
    }

    private static func preferredTextFieldHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender) + GlassTextField.padY * 2 + 4
    }

    private static func preferredTextFieldWidth(text: String, font: NSFont, maxWidth: CGFloat) -> CGFloat {
        let sample = text.isEmpty ? "输入文字…" : text
        let measured = (sample as NSString).size(withAttributes: [.font: font]).width
        let desired = ceil(measured) + GlassTextField.padX * 2 + 18
        return min(max(desired, 92), max(92, maxWidth))
    }

    /// 随输入内容或字号切换平滑自适应文本框宽高，紧贴文字不占满屏空白
    private func resizeActiveTextField() {
        guard let field = textField as? GlassTextField, let font = field.font else { return }
        let liveText = (window?.fieldEditor(false, for: field) as? NSTextView)?.string ?? field.stringValue
        let maxW = max(96, editorRectLocal.maxX - field.frame.minX - 4)
        let newW = Self.preferredTextFieldWidth(text: liveText, font: font, maxWidth: maxW)
        let newH = Self.preferredTextFieldHeight(for: font)
        var next = field.frame
        let midY = next.midY
        next.size.width = newW
        next.size.height = newH
        next.origin.y = min(max((midY - newH / 2).rounded(), editorRectLocal.minY + 2), max(editorRectLocal.minY + 2, editorRectLocal.maxY - newH - 2))
        if abs(next.width - field.frame.width) >= 1 || abs(next.height - field.frame.height) >= 1 {
            field.frame = next
            repositionFontSizePicker(near: next)
        }
    }

    /// 文字件入场（motion.enter 缩小版）：fade + 轻浮 5pt，0.18s easeOutStrong
    private func playTextFieldEntrance(_ view: NSView) {
        let finalFrame = view.frame
        let reduce = DesignTokens.Motion.reduceMotion
        if !reduce {
            view.frame = finalFrame.offsetBy(dx: 0, dy: 5)
        }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            if !reduce { view.animator().setFrameOrigin(finalFrame.origin) }
            view.animator().alphaValue = 1
        }
    }

    /// 文字件退场：fade 0.12s strong ease-out（杜绝 ease-in）
    private func fadeOutTextField(_ view: NSView) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            view.animator().alphaValue = 0
        }, completionHandler: { view.removeFromSuperview() })
    }

    /// Esc 取消文字输入：先彻底结束 fieldEditor 编辑态，再让框与字号条 fade 退场
    private func cancelTextEditing() {
        // 原地改字取消：store 里从未动过原文字，清下标即原样恢复显示（绝不闪一下空框）
        if editingTextAnnotationIndex != nil {
            editingTextAnnotationIndex = nil
            needsDisplay = true
            controller.refreshToolbar()
            Log.event(.editor, "editor.text.reedit.cancel", [:])
        }
        guard let field = textField else {
            removeFontSizePicker()
            return
        }
        textField = nil
        textFieldAnchor = nil
        field.delegate = nil
        field.target = nil
        window?.endEditing(for: field)
        fadeOutTextField(field)
        removeFontSizePicker()
        reclaimEditorFirstResponderAfterText()
    }

    /// 浮动 4 档字号选择条（12 / 14 / 17 / 21）：贴在输入框上方 8pt，放不下翻下方
    private func installFontSizePicker(near fieldFrame: NSRect) {
        let sizes = OverlayView.textFontSizes
        let selectedIndex = sizes.firstIndex(of: editorSession?.textFontSize ?? 14) ?? 1
        let bar = FontSizeBarView(sizes: sizes, selectedIndex: selectedIndex)
        bar.onSelect = { [weak self] index in
            guard let self, sizes.indices.contains(index) else { return }
            let size = sizes[index]
            self.editorSession?.textFontSize = size
            let newFont = NSFont.systemFont(ofSize: CGFloat(size), weight: .semibold)
            self.textField?.font = newFont
            (self.textField as? GlassTextField)?.refreshPlaceholder()
            self.resizeActiveTextField()
            if let tf = self.textField {
                self.window?.makeFirstResponder(tf)
            }
            self.controller.syncToolbarFromEditor()
            Log.event(.editor, "editor.text.fontSize", ["size": "\(size)"])
        }
        let size = FontSizeBarView.preferredSize(buttonCount: sizes.count)
        bar.frame = CGRect(origin: fontSizePickerOrigin(size: size, near: fieldFrame), size: size)
        addSubview(bar)
        playTextFieldEntrance(bar)
        fontSizePicker = bar
    }

    private func repositionFontSizePicker(near fieldFrame: NSRect) {
        guard let picker = fontSizePicker else { return }
        let origin = fontSizePickerOrigin(size: picker.frame.size, near: fieldFrame)
        picker.setFrameOrigin(origin)
    }

    private func fontSizePickerOrigin(size: CGSize, near fieldFrame: NSRect) -> CGPoint {
        let aboveY = fieldFrame.minY - 8 - size.height
        var origin = CGPoint(x: fieldFrame.minX, y: aboveY >= editorRectLocal.minY + 4 ? aboveY : fieldFrame.maxY + 8)
        origin.x = min(max(origin.x, 6), bounds.width - size.width - 6)
        origin.y = min(max(origin.y, 6), bounds.height - size.height - 6)
        return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }

    private var textFieldAnchor: CGPoint?

    @objc private func textFieldCommit(_ sender: NSTextField?) {
        commitTextFieldIfNeeded()
    }

    private func commitTextFieldIfNeeded() {
        guard let field = textField, let session = editorSession else { return }
        // 在 doCommandBy(insertNewline:) 回调时机，field.stringValue 尚未从 fieldEditor 同步，
        // 必须优先读取正在编辑中的 NSTextView.string
        let text = (window?.fieldEditor(false, for: field) as? NSTextView)?.string ?? field.stringValue
        let font = field.font ?? NSFont.systemFont(ofSize: CGFloat(session.textFontSize), weight: .semibold)
        // 按输入框内文字的真实排版基线反推标注落点，提交瞬间文字零跳动
        let textVisualHeight = font.ascender - font.descender
        let topInset = (field.frame.height - textVisualHeight) / 2
        let committedLocal = CGPoint(
            x: field.frame.minX + GlassTextField.padX + 2,
            y: field.frame.minY + topInset + font.ascender
        )
        let committedAnchor = localToAnnotation(committedLocal)
        // 原地改字：记下目标下标（下面的清理会一并清掉这个标记）
        let reeditIndex = editingTextAnnotationIndex
        editingTextAnnotationIndex = nil

        // 先清空引用并脱离 fieldEditor，防止 endEditing 触发重入，也不让退场动画中的旧输入框残留焦点
        textField = nil
        textFieldAnchor = nil
        field.delegate = nil
        field.target = nil
        window?.endEditing(for: field)

        fadeOutTextField(field)
        removeFontSizePicker()

        if let reeditIndex {
            commitInlineReeditText(
                atIndex: reeditIndex,
                text: text,
                colorIndex: session.colorIndex,
                fontSize: CGFloat(session.textFontSize)
            )
            reclaimEditorFirstResponderAfterText()
            return
        }

        if !text.isEmpty {
            controller.addAnnotation(AnnotationModel(
                shape: .text(anchor: committedAnchor),
                colorIndex: session.colorIndex,
                strokeWidth: session.strokeWidth,
                text: text,
                index: nil,
                fontSize: CGFloat(session.textFontSize)
            ))
        }
        reclaimEditorFirstResponderAfterText()
    }

    /// 原地改字提交：空文本 = 删掉该条；否则用新文字/颜色/字号回写（保留原 anchor，提交瞬间文字零跳动）
    /// 两条路径都只占一步撤销（remove / replace 内部自己压栈）
    private func commitInlineReeditText(
        atIndex index: Int,
        text: String,
        colorIndex: Int,
        fontSize: CGFloat
    ) {
        guard let session = editorSession, session.store.annotations.indices.contains(index) else {
            selectedAnnotationIndex = nil
            needsDisplay = true
            return
        }
        let original = session.store.annotations[index]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            session.store.remove(at: index)
            selectedAnnotationIndex = nil
            Log.event(.editor, "editor.text.reedit.remove", ["index": "\(index)"])
        } else {
            var updated = original
            updated.text = text
            updated.colorIndex = colorIndex
            updated.fontSize = fontSize
            // shape 保持原 `.text(anchor:)` 不变：锚点不漂移，改完字原位不位移
            session.store.replace(at: index, with: updated)
            selectedAnnotationIndex = index
            Log.event(.editor, "editor.text.reedit.commit", [
                "index": "\(index)",
                "chars": "\(text.count)",
                "size": "\(Int(fontSize))",
            ])
        }
        controller.refreshToolbar()
        needsDisplay = true
    }

    /// 结束文字输入后把键盘焦点稳妥交回 OverlayView（含当前 doCommandBy 回退后的下一个 runloop tick 兜底）
    private func reclaimEditorFirstResponderAfterText() {
        window?.makeFirstResponder(self)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.textField == nil, self.phase == .editing else { return }
            self.window?.makeFirstResponder(self)
        }
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

    /// 优先拦截 ⌘ 组合快捷键（如 ⌘Z 撤销 / ⌘⇧Z 重做 / ⌘S 保存 / ⌘⌥S 快存）：
    /// 使用文字工具触发过 NSTextField 后，macOS 的系统菜单 Edit → Undo 与窗口残留 UndoManager
    /// 会在 keyDown 之前于 performKeyEquivalent 阶段吞掉 ⌘Z；在这里先一步接管，彻底解决回车后 ⌘Z 失效。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller.isScrollComposing { return true }
        // 正在打字时把 ⌘A/⌘C/⌘V/⌘Z 留给文字输入框自己处理
        if textField != nil { return super.performKeyEquivalent(with: event) }
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if Int(event.keyCode) == kVK_ANSI_S,
           event.modifierFlags.contains(.option) {
            if case .dragging = phase, commitDraggingSelection(via: "keyQuickSave") {
                ignoreNextMouseUpAfterEarlyCommit = true
            }
            if recordingMode == .none, phase == .editing || phase == .confirmed {
                controller.perform(action: .quickSave)
                return true
            }
        }
        if case .dragging = phase,
           EditorKeyRouter.matchHotkey(event) != nil,
           commitDraggingSelection(via: "keyEquivalent") {
            ignoreNextMouseUpAfterEarlyCommit = true
        }
        if phase == .waitingForDrag, handleSmartDirectHotkey(event) {
            return true
        }
        if phase == .editing, let action = matchEditorHotkey(event) {
            performEditorHotkeyAction(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 智能框选悬停态直达取字（O） / 贴图（P 或用户自定义组合键如 ⌘T）：
    /// 同时被 `performKeyEquivalent`（⌘ 组合键入口）与 `keyDown`（裸键入口）调用，
    /// 完整尊重 `settings.editorHotkeys` 的自定义绑定（无论裸键还是带 ⌘/⌥/⌃）。
    private func handleSmartDirectHotkey(_ event: NSEvent) -> Bool {
        guard phase == .waitingForDrag, !scrollMode, recordingMode == .none,
              let screen = window?.screen else { return false }
        guard let hotkey = EditorKeyRouter.matchHotkey(event),
              hotkey == "ocr" || hotkey == "pin" else { return false }
        // 悬停目标：屏幕四边 → 整屏；否则当前智能候选层（窗口候选才带 windowID）
        var targetRect: CGRect?
        var windowID: CGWindowID?
        if edgeFullScreenHover {
            targetRect = screen.frame
        } else if let candidate = smartActiveCandidate {
            targetRect = candidate.rectGlobal
            windowID = Self.isWindowKind(candidate.kind) ? candidate.windowID : nil
        }
        guard let targetRect else { return false }
        if hotkey == "ocr" {
            controller.performSmartDirectOCR(rect: targetRect, on: screen, windowID: windowID)
        } else {
            controller.performSmartDirectPin(rect: targetRect, on: screen, windowID: windowID)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        Log.logger(.overlay).debug("evt=overlay.keyDown key=\(event.keyCode, privacy: .public) phase=\(self.phaseLabel, privacy: .public)")
        // 拼接窗口期（scroll 停采后 → 长图回填前的异步间隙）：所有键吞掉。
        // 此时 editorSession 还挂着旧单帧底图，Enter→done / Esc→cancel 会把会话
        // 销毁 ⇒ 合成结果无处回填（scroll.compose.noSession 病例）。
        if controller.isScrollComposing { return }
        if case .active = recordingMode { return }
        if case .preparing = recordingMode {
            switch Int(event.keyCode) {
            case kVK_Escape:
                controller.cancelRecordingSession()
            case kVK_Return, kVK_ANSI_KeypadEnter:
                controller.startRecordingFromBar()
            case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let dx: CGFloat = Int(event.keyCode) == kVK_LeftArrow ? -step : (Int(event.keyCode) == kVK_RightArrow ? step : 0)
                let dy: CGFloat = Int(event.keyCode) == kVK_UpArrow ? -step : (Int(event.keyCode) == kVK_DownArrow ? step : 0)
                let moved = SelectionGeometry.nudged(recordingRectLocal, dx: dx, dy: dy, limit: bounds)
                if moved != recordingRectLocal {
                    recordingRectLocal = moved
                    if let screen = window?.screen {
                        controller.updateRecordingRegionGlobal(convertToGlobalRect(moved), on: screen)
                    }
                    needsDisplay = true
                }
            default:
                break
            }
            return
        }
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
            // ⇧C = 轮换取色格式（HEX → RGB → HSL，不关遮罩）；裸 C = 复制光标处颜色
            if event.modifierFlags.contains(.shift) {
                cycleColorCopyFormat()
            } else {
                copyColorUnderCursor()
            }
            return
        }
        // 智能框选态：↑ 向外扩一层 / ↓ 向内缩一层（单元格 → 行 → 列 → 整表 → 窗口），
        // 与滚轮切层同一套语义、同一个 `smartLayerUserPinned` 记忆（切换后不被异步回填抢回默认层）
        if phase == .waitingForDrag, !scrollMode, recordingMode == .none,
           !edgeFullScreenHover, smartStack.candidates.count > 1,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                stepSmartLayer(by: 1, via: "key")
                return
            case kVK_DownArrow:
                stepSmartLayer(by: -1, via: "key")
                return
            default:
                break
            }
        }
        // 智能框选态：悬停候选上直接按取字键 / 贴图键一步直达（裸键走这里，⌘ 组合键已由 performKeyEquivalent 接管）
        if phase == .waitingForDrag, handleSmartDirectHotkey(event) {
            return
        }
        // 空格：编辑态临时切「整体移动」（按下期间有效）
        if Int(event.keyCode) == kVK_Space {
            if phase == .editing { spacePressed = true }
            return
        }
        // 方向键：编辑态微调（有选中标注 → 只挪该标注；否则挪整个选区框。Shift = 10pt）
        if phase == .editing, [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(Int(event.keyCode)) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            switch Int(event.keyCode) {
            case kVK_LeftArrow: dx = -step
            case kVK_RightArrow: dx = step
            case kVK_UpArrow: dy = -step
            case kVK_DownArrow: dy = step
            default: break
            }
            if !nudgeSelectedAnnotation(dx: dx, dy: dy) {
                nudgeSelection(dx: dx, dy: dy)
            }
            return
        }
        // 兜底：若系统三指拖移未下发离手触控事件，用户已拖出有效选区并在 0.5s 合成 mouseUp 间隙内
        // 直接按回车/快捷键（如 Return / ⌘S / P / O / S / R / G），立刻落定选区并同步执行该按键动作，绝不吞键！
        if case .dragging = phase,
           selectionLocal.width >= minSelectionSize,
           selectionLocal.height >= minSelectionSize {
            let code = Int(event.keyCode)
            let isReturn = (code == kVK_Return || code == kVK_ANSI_KeypadEnter)
            let isQuickSave = (code == kVK_ANSI_S && event.modifierFlags.contains(.command) && event.modifierFlags.contains(.option))
            let isEditorKey = EditorKeyRouter.matchHotkey(event) != nil
            if isReturn || isQuickSave || isEditorKey {
                if commitDraggingSelection(via: "keyDown") {
                    ignoreNextMouseUpAfterEarlyCommit = true
                    // 若本次是从录屏/GIF 入口框选，已切进准备态，停留在准备态不触发截图保存
                    if recordingMode != .none {
                        return
                    }
                }
            }
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
            // 已选中标注：Esc 先只取消选中（不关截图），再按一次才取消整个会话
            if dismissAnnotationSelectionIfNeeded() { return }
            controller.perform(action: .cancel)
        case kVK_Delete, kVK_ForwardDelete:
            // 选中标注 + Delete/⌦ = 删除该条（可 ⌘Z 恢复）
            if deleteSelectedAnnotationIfNeeded() { return }
            super.keyDown(with: event)
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
            } else if phase == .waitingForDrag, edgeFullScreenHover {
                pickFullDisplay()
            } else if phase == .waitingForDrag, let candidate = smartActiveCandidate {
                pickSmartCandidate(candidate)
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
            // ⇧M：编辑器内一键智能脱敏（无需先点马赛克工具也可随手触发）
            if phase == .editing, textField == nil,
               Int(event.keyCode) == kVK_ANSI_M,
               event.modifierFlags.contains(.shift),
               !event.modifierFlags.contains(.command) {
                controller.toolbarAction(.autoRedact)
                return
            }
            // B：编辑器内切换克制画框美化（Smart Backdrop）
            if phase == .editing, !scrollMode, textField == nil,
               Int(event.keyCode) == kVK_ANSI_B,
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                controller.toolbarAction(.toggleBackdrop)
                return
            }
            // 热键 1-7 直选工具（R6）；再按同键取消回 .none（用户裁定
            // 2026-11-16：默认无工具拖动=移动选区，数字键即取即还）
            if phase == .editing,
               let tool = toolFor(keyCode: Int(event.keyCode)) {
                editorSession?.currentTool = (editorSession?.currentTool == tool) ? .none : tool
                handleToolbarToolChange()
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
        record: { [weak self] in
            self?.controller.toolbarAction(.record)
        },
        recordGIF: { [weak self] in
            self?.controller.toolbarAction(.recordGIF)
        },
        selectTool: { [weak self] tool in
            guard let self else { return }
            self.editorSession?.currentTool = tool
            self.handleToolbarToolChange()
            self.controller.refreshToolbar()
            self.needsDisplay = true
        }
    )

    /// event → 组合串 → settings.editorHotkeys 反查 action key。
    /// 仅编辑/确认阶段且无文字输入时生效（文字输入态的键必须给输入框）。
    private func matchEditorHotkey(_ event: NSEvent) -> String? {
        guard textField == nil, phase == .editing || phase == .confirmed, !scrollMode, recordingMode == .none else { return nil }
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
        switch recordingMode {
        case .active:
            return
        case .preparing:
            drawRecordingPreparing(ctx: ctx)
            return
        case .none:
            break
        }
        switch phase {
        case .editing:
            drawEditor(ctx: ctx)
        default:
            drawSelection(ctx: ctx)
            drawSelectionOverlays(ctx: ctx)
            drawAccessibilityHintIfNeeded(ctx: ctx)
        }
    }

    private func drawRecordingPreparing(ctx: CGContext) {
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(bounds)
        let rect = recordingRectLocal
        guard rect.width > 0, rect.height > 0 else { return }

        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(rect)
        ctx.restoreGState()

        let outer = rect.insetBy(dx: -1.0, dy: -1.0)
        ctx.setStrokeColor(DesignTokens.statusError.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(outer)

        drawSelectionHandles(ctx: ctx, rect: rect)

        let scale = window?.screen?.backingScaleFactor ?? 1
        let w = Int((rect.width * scale).rounded())
        let h = Int((rect.height * scale).rounded())
        drawBadge(text: "\(w) × \(h)", below: rect)
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

    /// 选区阶段：蒙层 + 橡皮筋 + 角标 + 窗口悬停高亮（冻结帧已由底层 GPU CALayer 托管，零每帧 CPU 重绘）
    private func drawSelection(ctx: CGContext) {
        // 1. 蒙层
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        ctx.fill(bounds)

        // 1.5 智能候选 / 边缘全屏悬停高亮：平滑变形挖空 + accent 描边 + 角标
        let selectionEmpty = selectionLocal.width <= 0 && selectionLocal.height <= 0
        let smartCandidate = smartActiveCandidate
        if selectionEmpty, let targetRect = hoveredLocalRect,
           (edgeFullScreenHover || smartCandidate != nil) {
            let now = CACurrentMediaTime()
            let elapsed = hoverFadeStart > 0 ? now - hoverFadeStart : 1
            let hoverAlpha = min(1, CGFloat(elapsed / 0.14))
            let morphProgress = hoverMorphFromRect != nil ? min(1, (now - hoverMorphStart) / 0.16) : 1
            let drawRect = currentHoverVisualRect() ?? targetRect
            if hoverAlpha < 1 || morphProgress < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                    self?.needsDisplay = true
                }
            }
            // 圆角按目标类型适配：全屏 0 / 文本行 4 / 控件·区域 6 / 窗口 10
            let cornerR: CGFloat = edgeFullScreenHover
                ? 0
                : Self.smartCornerRadius(for: smartCandidate?.kind)
            let clearPath = CGPath(roundedRect: drawRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.addPath(clearPath)
            ctx.fillPath()
            ctx.restoreGState()

            let strokeRect = drawRect.insetBy(dx: 0.75, dy: 0.75)
            let strokeR = max(0, cornerR - 0.75)
            let strokePath = CGPath(roundedRect: strokeRect, cornerWidth: strokeR, cornerHeight: strokeR, transform: nil)
            let fillAlpha: CGFloat = edgeFullScreenHover || Self.isWindowKind(smartCandidate?.kind) ? 0.04 : 0.05
            ctx.setFillColor(DesignTokens.accent.withAlphaComponent(fillAlpha * hoverAlpha).cgColor)
            ctx.addPath(strokePath)
            ctx.fillPath()
            ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(0.88 * hoverAlpha).cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(strokePath)
            ctx.strokePath()
            let label = hoverBadgeLabel(candidate: smartCandidate, rect: targetRect)
            if !label.isEmpty {
                drawWindowBadge(text: label, below: drawRect)
            }
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

    /// 智能候选圆角：文本行·表格单元格 4 / 列表项·表格行列 5 / 控件·区域·识别块 6 / 表格 8 / 窗口 10 / 整屏 0
    private static func smartCornerRadius(for kind: SmartCandidateKind?) -> CGFloat {
        guard let kind else { return 10 }
        switch kind {
        case .textLine, .tableCell: return 4
        case .listItem, .tableRow, .tableColumn: return 5
        case .element, .container, .visualRect: return 6
        case .table: return 8
        case .window: return 10
        case .display: return 0
        }
    }

    /// 是否为窗口层（不依赖 SmartCandidateKind: Equatable 的隐式约定，用模式匹配更稳）
    private static func isWindowKind(_ kind: SmartCandidateKind?) -> Bool {
        guard let kind else { return false }
        if case .window = kind { return true }
        return false
    }

    /// 悬停角标文案：保持极简，只显示尺寸（整屏 / 窗口带精简标识，不铺「区域 / 滚轮切层」等冗长提示污染视线）
    private func hoverBadgeLabel(candidate: SmartSelectionCandidate?, rect: CGRect) -> String {
        let scale = window?.screen?.backingScaleFactor ?? 1
        let pxW = Int((rect.width * scale).rounded())
        let pxH = Int((rect.height * scale).rounded())
        if edgeFullScreenHover { return "全屏 · \(pxW) × \(pxH)" }
        guard let candidate else { return "" }
        if Self.isWindowKind(candidate.kind), !candidate.ownerName.isEmpty {
            return "\(candidate.ownerName) · \(pxW) × \(pxH)"
        }
        return "\(pxW) × \(pxH)"
    }

    /// 选区阶段收尾：放大镜（独立方法，draw() 里在蒙层/选框之后调用）
    private func drawSelectionOverlays(ctx: CGContext) {
        drawMagnifier(ctx: ctx)
    }

    // MARK: - 辅助功能权限轻提示条

    /// 未授权时的温和提示（不阻断截图）：点击主区 = 退出遮罩 + 直达系统设置辅助功能页；
    /// 点 × = 以后不再提示。绘制时顺手缓存两个命中矩形供 mouseDown/mouseMoved 用。
    private func drawAccessibilityHintIfNeeded(ctx: CGContext) {
        guard shouldShowAXHint else {
            axHintBannerRect = nil
            axHintCloseRect = nil
            return
        }

        let text = "未开启辅助功能 · 点击去开启，可精准识别表格与网页元素"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            .paragraphStyle: paragraph,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)

        let height: CGFloat = 32
        let padLeft: CGFloat = 14
        let gap: CGFloat = 10
        let closeWidth: CGFloat = 26
        let padRight: CGFloat = 6
        let available = max(80, bounds.width - 24)
        let textWidth = min(ceil(textSize.width), available - padLeft - gap - 1 - gap - closeWidth - padRight)
        let width = padLeft + textWidth + gap + 1 + gap + closeWidth + padRight
        let bannerRect = CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: 22,
            width: width,
            height: height
        )
        let dividerX = bannerRect.minX + padLeft + textWidth + gap
        let closeRect = CGRect(x: dividerX + 1 + gap, y: bannerRect.minY, width: closeWidth, height: height)
        axHintBannerRect = bannerRect
        axHintCloseRect = closeRect

        // 1. 深色半透胶囊 + 细白边（与工具栏胶囊同一族，不压住视觉焦点）
        let path = CGPath(roundedRect: bannerRect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10, color: NSColor.black.withAlphaComponent(0.26).cgColor)
        ctx.setFillColor(NSColor(white: 0.10, alpha: 0.84).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(path)
        ctx.strokePath()

        // 2. 主文案
        (text as NSString).draw(
            in: CGRect(
                x: bannerRect.minX + padLeft,
                y: bannerRect.minY + (height - textSize.height) / 2,
                width: textWidth,
                height: textSize.height
            ),
            withAttributes: attrs
        )

        // 3. 分隔线 + 关闭按钮 ×
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: dividerX.rounded() + 0.5, y: bannerRect.minY + 9))
        ctx.addLine(to: CGPoint(x: dividerX.rounded() + 0.5, y: bannerRect.maxY - 9))
        ctx.strokePath()

        let closeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ]
        let closeText = "×" as NSString
        let closeSize = closeText.size(withAttributes: closeAttrs)
        closeText.draw(
            at: CGPoint(
                x: (closeRect.midX - closeSize.width / 2).rounded(),
                y: (closeRect.midY - closeSize.height / 2).rounded()
            ),
            withAttributes: closeAttrs
        )
    }

    /// 点击主文案：先退出截图遮罩，再打开「系统设置 → 隐私与安全性 → 辅助功能」
    /// （用户主动点击才允许弹系统确认框，符合全局权限纪律）
    private func activateAccessibilityHint() {
        Log.event(.overlay, "overlay.axhint.openSettings", ["trusted": "\(axTrusted)"])
        controller.perform(action: .cancel)
        AccessibilityPermission.requestAndOpenSettings()
    }

    /// 点击 ×：本次及以后不再提示（不影响继续截图）
    private func dismissAccessibilityHint() {
        UserDefaults.standard.set(true, forKey: Self.axHintDismissedKey)
        axHintDismissed = true
        axHintBannerRect = nil
        axHintCloseRect = nil
        axHintHovered = false
        NSCursor.crosshair.set()
        needsDisplay = true
        Log.event(.overlay, "overlay.axhint.dismissed")
    }

    /// 编辑阶段：选区外蒙层 + 选区内冻结底图 + 标注层
    /// move 手势期间的实时取景：当前选区在冻结帧上的对应区域
    /// （整像素对齐裁剪 + 1:1 绘制矩形，采样每帧稳定不抖）
    private func liveFrozenCrop() -> (crop: CGImage, drawRect: CGRect)? {
        guard let window = window, let frozen = frozenImage, bounds.width > 0 else { return nil }
        // editorRectLocal（视图 Y-down）→ 屏全局（Y-up）
        let global = CGRect(
            x: window.frame.minX + editorRectLocal.minX,
            y: window.frame.maxY - editorRectLocal.maxY,
            width: editorRectLocal.width, height: editorRectLocal.height)
        // 屏 → 冻结帧像素（frozen 与 window.frame 同区域 1:1 像素比例）
        let sx = CGFloat(frozen.width) / max(1, window.frame.width)
        let sy = CGFloat(frozen.height) / max(1, window.frame.height)
        // ⚠️ 坐标两坑（用户镜像病例「左下→右上」两个 y 方向都复现过）：
        // ① CGImage.cropping 原点在**左上**（Y-down；crop_test3 实测铁证）
        //   —— y 从顶部量，与 controller.pixelRect 同公式
        // ② 真根因在绘制 CTM（drawEditor liveCrop 路径已补内层平移）：
        //   翻转围绕已平移原点致 draw rect.y 语义反转 = 垂直镜像
        var px = CGRect(
            x: (global.minX - window.frame.minX) * sx,
            y: (window.frame.maxY - global.maxY) * sy,
            width: global.width * sx, height: global.height * sy)
        // 防御：clamp 进位图边界（越界裁剪返 nil → 回退旧路径贴图）
        px = px.intersection(CGRect(x: 0, y: 0, width: CGFloat(frozen.width), height: CGFloat(frozen.height)))
        guard !px.isNull, px.width >= 1, px.height >= 1 else { return nil }
        // 整像素对齐（用户病例「取景框画面热空气扭曲」）：浮点裁剪 rect +
        // nearest 采样 = 每帧采样网格亚像素跳变 → 内容热浪般扭动。取整后
        // 每帧采样点集稳定；绘制矩形从像素反算回点（1:1 无拉伸）——clip 仍
        // 用 editorRectLocal（视觉框精确跟手，内容 0.5pt 内的对齐差不可见）
        px = px.integral
        // 绘制 rect（视图点，从顶部量——与 px 同向）：像素 ÷ 比例
        let drawRect = CGRect(
            x: px.minX / sx, y: px.minY / sy,
            width: px.width / sx, height: px.height / sy)
        guard let crop = frozen.cropping(to: px) else { return nil }
        return (crop, drawRect)
    }

    private func drawEditor(ctx: CGContext) {
        guard let session = editorSession else { return }

        let backdropLayout = session.currentBackdropLayout(for: editorRectLocal.size)
        let backdropRectLocal: CGRect?
        let cardRectLocal: CGRect?
        if let layout = backdropLayout {
            let backdropOrigin = CGPoint(
                x: editorRectLocal.minX - layout.imageRect.minX,
                y: editorRectLocal.minY - layout.imageRect.minY
            )
            backdropRectLocal = CGRect(origin: backdropOrigin, size: layout.canvasSize)
            cardRectLocal = layout.cardRect.offsetBy(dx: backdropOrigin.x, dy: backdropOrigin.y)
        } else {
            backdropRectLocal = nil
            cardRectLocal = nil
        }

        // 1. 选区外蒙层（比选区阶段浅，弱化干扰；开启画框时按画框总画布挖空）
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha * 0.7).cgColor)
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(backdropRectLocal ?? editorRectLocal)
        ctx.restoreGState()

        if let layout = backdropLayout, let backdropRect = backdropRectLocal, let cardRect = cardRectLocal {
            // 1.1 画框渐变背景
            CGRenderer.drawBackdropBackground(
                style: session.backdropStyle,
                in: backdropRect,
                context: ctx,
                contextIsYDown: true
            )
            // 1.2 圆角卡片双层柔影与可选边缘主色均衡内衬底
            let cushionColor = layout.balanceInset > 0 ? session.backdropEdgeColor() : nil
            CGRenderer.drawBackdropCardChrome(
                cardRect: cardRect,
                cornerRadius: layout.cornerRadius,
                isDarkBackdrop: session.backdropStyle.preset.isDark,
                cushionColor: cushionColor,
                context: ctx,
                contextIsYDown: true
            )
        }

        // 2. 选区内画面：
        // - 冻结桌面态且无马赛克（或正处于移动/缩放框选期间，未开画框）：
        //   底层 GPU `frozenBackdropView` 已经按 1:1 屏幕坐标静止托管完整冻结帧，
        //   上方 `.clear` 挖空直接透出绝对静止的原生画面——彻底根除 `liveFrozenCrop`
        //   每帧裁剪 + nearest 亚像素重采样导致的「移动选框时背后文字轻微变形/热浪抖动」；
        // - 开启画框时底下已铺渐变与卡片背景，必须绘制位图底图；
        // - 独立外源图（frozenImage == nil）或静止态含马赛克：正常绘制 `baseForDraw`。
        let annotations: [AnnotationModel] = {
            var items = session.store.annotations
            // 原地改字：先撤下那条已落盘文字，避免输入框底下重影（Esc 取消则原样恢复显示）
            if let reedit = editingTextAnnotationIndex, items.indices.contains(reedit) {
                items.remove(at: reedit)
            }
            if let pending = pendingAnnotation { items.append(pending) }
            return items
        }()
        let hasMosaic = annotations.contains { annotation in
            if case .mosaic = annotation.shape { return true }
            return false
        }
        let isDraggingBox: Bool
        let annotationOrigin: CGPoint
        switch editGesture {
        case .move(let startRect, _), .resize(_, let startRect):
            isDraggingBox = true
            annotationOrigin = (frozenImage != nil) ? startRect.origin : editorRectLocal.origin
        case .none, .editAnnotation:
            isDraggingBox = false
            annotationOrigin = editorRectLocal.origin
        }

        if let layout = backdropLayout, let cardRect = cardRectLocal {
            let cardPath = CGPath(
                roundedRect: cardRect,
                cornerWidth: layout.cornerRadius,
                cornerHeight: layout.cornerRadius,
                transform: nil
            )
            ctx.saveGState()
            ctx.addPath(cardPath)
            ctx.clip()
        }

        let needsBitmapDraw = (backdropLayout != nil) || (frozenImage == nil) || (hasMosaic && !isDraggingBox)
        if needsBitmapDraw {
            if backdropLayout != nil, frozenImage != nil, isDraggingBox, let liveCrop = liveFrozenCrop() {
                ctx.saveGState()
                ctx.clip(to: editorRectLocal)
                let drawRect = liveCrop.drawRect
                ctx.translateBy(x: drawRect.minX, y: drawRect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: -drawRect.minX, y: -drawRect.minY)
                ctx.interpolationQuality = .none
                ctx.draw(liveCrop.crop, in: drawRect)
                ctx.restoreGState()
            } else {
                let baseForDraw: CGImage
                if hasMosaic {
                    baseForDraw = CGRenderer.renderMosaicPreview(
                        base: session.baseImage, annotations: annotations, scale: session.scale
                    )
                } else {
                    baseForDraw = session.baseImage
                }
                if isStandaloneImage && backdropLayout == nil {
                    ctx.saveGState()
                    ctx.setShadow(
                        offset: CGSize(width: 0, height: 10),
                        blur: 28,
                        color: NSColor.black.withAlphaComponent(0.28).cgColor
                    )
                    ctx.setFillColor(NSColor.black.withAlphaComponent(0.01).cgColor)
                    ctx.fill(editorRectLocal)
                    ctx.restoreGState()
                }
                ctx.saveGState()
                ctx.clip(to: editorRectLocal)
                ctx.translateBy(x: editorRectLocal.minX, y: editorRectLocal.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: -editorRectLocal.minX, y: -editorRectLocal.minY)
                let backing = window?.backingScaleFactor ?? 2
                let exact1to1 = abs(editorRectLocal.width * backing - CGFloat(baseForDraw.width)) < 1.5
                    && abs(editorRectLocal.height * backing - CGFloat(baseForDraw.height)) < 1.5
                ctx.interpolationQuality = exact1to1 ? .none : .high
                ctx.draw(baseForDraw, in: editorRectLocal)
                ctx.restoreGState()
            }
        }

        // 3. 标注层（移动/缩放取景框时锚定 startRect.origin，使既有标注钉死在屏幕内容上不漂移）
        Log.event(.editor, "editor.draw", [
            "count": "\(annotations.count)", "shapes": annotations.map { "\($0.shape)" }.joined(separator: "|"),
        ])
        ctx.saveGState()
        ctx.clip(to: editorRectLocal)
        ctx.translateBy(x: annotationOrigin.x, y: annotationOrigin.y)
        CGRenderer.render(annotations: annotations, in: editorRectLocal.size, context: ctx, contextIsYDown: true)

        // 3.5 自动脱敏视觉反馈（仅屏幕展示，绝不入导出图）：刚命中时的轻蓝闪框 + 悬停可点消虚线框
        if !flashedAutoRedactRects.isEmpty {
            ctx.saveGState()
            ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(0.85).cgColor)
            ctx.setFillColor(DesignTokens.accent.withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(1.5)
            for r in flashedAutoRedactRects {
                let p = CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.addPath(p)
                ctx.fillPath()
                ctx.addPath(p)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        if let hoveredRect = hoveredAutoRedactRect, !isDraggingBox {
            ctx.saveGState()
            let p = CGPath(roundedRect: hoveredRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(1.25)
            ctx.setLineDash(phase: 0, lengths: [3.5, 2.5])
            ctx.addPath(p)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 3.6 已画标注二次编辑视觉反馈（悬停浅蓝细虚框 / 选中蓝虚框 + 操控柄；同样不入导出图）
        drawAnnotationEditingDecorations(ctx: ctx)
        ctx.restoreGState()

        if let layout = backdropLayout, let cardRect = cardRectLocal {
            ctx.restoreGState()
            CGRenderer.drawBackdropCardHairline(
                cardRect: cardRect,
                cornerRadius: layout.cornerRadius,
                isDarkBackdrop: session.backdropStyle.preset.isDark,
                lineWidth: 0.5,
                context: ctx
            )
        }

        // 4. 选区边界与画框外沿 0.5pt 边界线
        if let backdropRect = backdropRectLocal {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32).cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(backdropRect.insetBy(dx: 0.25, dy: 0.25))
            ctx.restoreGState()

            if hoverEdge != nil || isDraggingBox {
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
                ctx.setLineWidth(borderWidth + 0.5)
                ctx.stroke(editorRectLocal)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                ctx.setLineWidth(0.75)
                ctx.stroke(editorRectLocal)
            } else {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(editorRectLocal)
            }
        } else {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.24).cgColor)
            ctx.setLineWidth(borderWidth + 1.0)
            ctx.stroke(editorRectLocal)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.90).cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(editorRectLocal)
        }

        // 4.7 编辑器顶部轻提示胶囊（如「已自动脱敏 3 处 · 单击可取消」）
        if let toast = editorToastText {
            drawEditorToastPill(text: toast, in: backdropRectLocal ?? editorRectLocal, ctx: ctx)
        }

        // 4.5 手柄（Apple Preview / Keynote 圆形精致手柄）
        drawSelectionHandles(ctx: ctx)

        // 4.6 独立外源图缩放比例浮标（缩放时浮在可视画布右上角，1s 后自动淡隐）
        if let zoomText = standaloneZoomHudText {
            let visibleCanvas = (backdropRectLocal ?? editorRectLocal).intersection(bounds.insetBy(dx: 12, dy: 12))
            if !visibleCanvas.isNull, visibleCanvas.width >= 60, visibleCanvas.height >= 40 {
                drawZoomPill(text: zoomText, in: visibleCanvas, ctx: ctx)
            }
        }

        // 5. 提示条已移除（病例：长条提示与工具栏重叠、压住按钮，原型 scene 03 也没有它；
        //    快捷键教学放设置面板与首次引导，不占编辑画布）
    }

    // MARK: - 已画标注二次编辑（绘制）

    /// 标注轴对齐包框（文字用与 CGRenderer 同字体的实测尺寸，命中框 = 视觉像素）
    private func annotationFrameRect(for annotation: AnnotationModel) -> CGRect {
        AnnotationEditorGeometry.boundingRect(for: annotation, textMetrics: measuredTextMetrics(for: annotation))
    }

    /// 选中/悬停视觉：克制到「看得出能改、不抢内容」——细虚线 + Apple 风格白底蓝环小圆柄，全部不入导出图
    private func drawAnnotationEditingDecorations(ctx: CGContext) {
        guard let session = editorSession else { return }
        let items = session.store.annotations
        let isReediting = editingTextAnnotationIndex != nil

        // 悬停（非选中）：极克制浅蓝细虚线轮廓，提示「这里可点」
        if session.currentTool == .none, !isReediting,
           let hovered = hoveredAnnotationIndex, hovered != selectedAnnotationIndex,
           items.indices.contains(hovered) {
            drawAnnotationHoverOutline(for: items[hovered], ctx: ctx)
        }

        // 选中（且不在原地改字）：蓝虚框 + 操控柄
        guard !isReediting,
              let sel = selectedAnnotationIndex,
              items.indices.contains(sel) else { return }
        let annot = items[sel]
        drawAnnotationSelectionFrame(for: annot, ctx: ctx)
        for handlePoint in AnnotationEditorGeometry.handles(for: annot, textSize: measuredTextSize(for: annot)) {
            let isHot = hoveredAnnotationIndex == sel && hoveredAnnotationHandle == handlePoint.handle
            drawAnnotationHandle(at: handlePoint.point, isHot: isHot, ctx: ctx)
        }
    }

    private func drawAnnotationHoverOutline(for annotation: AnnotationModel, ctx: CGContext) {
        ctx.saveGState()
        ctx.beginPath()
        ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        switch annotation.shape {
        case .arrow(let from, let to), .highlight(let from, let to):
            // 线形标注沿走向描一条虚线，比斜向包围盒更读懂是「哪一条」
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
        default:
            let box = annotationFrameRect(for: annotation).insetBy(dx: -3, dy: -3)
            if box.width > 0.5, box.height > 0.5 {
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    private func drawAnnotationSelectionFrame(for annotation: AnnotationModel, ctx: CGContext) {
        switch annotation.shape {
        case .arrow, .highlight:
            // 箭头/高亮不画多余方框，直接高亮两个端点操控柄
            return
        default:
            break
        }
        let box = annotationFrameRect(for: annotation).insetBy(dx: -3, dy: -3)
        guard box.width > 0.5, box.height > 0.5 else { return }
        ctx.saveGState()
        ctx.beginPath()
        ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 操控柄：与选区手柄同源的 Apple 风格（白填充 + 蓝描边 7.5pt 圆柄；悬停 9.5pt + 轻投影）
    private func drawAnnotationHandle(at point: CGPoint, isHot: Bool, ctx: CGContext) {
        let diameter: CGFloat = isHot ? 9.5 : 7.5
        let circle = CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        ctx.saveGState()
        if isHot {
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4,
                          color: NSColor.black.withAlphaComponent(0.30).cgColor)
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()
        ctx.setStrokeColor(DesignTokens.accent.withAlphaComponent(isHot ? 1.0 : 0.92).cgColor)
        ctx.setLineWidth(isHot ? 1.5 : 1.0)
        ctx.strokeEllipse(in: circle)
    }

    /// 窗口名角标（统一深色半透玻璃胶囊族 + 0.5pt 发丝边 + 轻影，告别突兀纯白条）
    private func drawWindowBadge(text: String, below rect: CGRect) {
        let maxChars = 42
        let shown = text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]
        let textSize = (shown as NSString).size(withAttributes: attributes)
        let padH: CGFloat = 9
        let size = CGSize(width: ceil(textSize.width + padH * 2), height: 22)
        // 贴在窗口内侧左上（外侧会压到菜单栏）
        var origin = CGPoint(x: rect.minX + 10, y: rect.minY + 10)
        origin.x = min(max(origin.x, 8), bounds.width - size.width - 8)
        let badgeRect = CGRect(origin: origin, size: size)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 24/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.78).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(path)
        ctx.strokePath()
        (shown as NSString).draw(
            at: CGPoint(x: origin.x + padH, y: origin.y + (size.height - textSize.height) / 2),
            withAttributes: attributes
        )
    }

    /// 编辑器顶部轻提示胶囊（如自动脱敏命中数、单点取消反馈；贴在选区上方 10pt，贴屏顶时回落选区内侧顶部）
    private func drawEditorToastPill(text: String, in selection: CGRect, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padH: CGFloat = 11
        let size = CGSize(width: ceil(textSize.width + padH * 2), height: 24)
        let x = min(max(selection.midX - size.width / 2, 10), bounds.width - size.width - 10)
        let aboveY = selection.minY - size.height - 10
        let y = aboveY >= 10 ? aboveY : min(bounds.height - size.height - 10, selection.minY + 10)
        let pillRect = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        let path = CGPath(roundedRect: pillRect, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 24/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.84).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(path)
        ctx.strokePath()
        (text as NSString).draw(
            at: CGPoint(x: pillRect.minX + padH, y: pillRect.minY + (size.height - textSize.height) / 2),
            withAttributes: attrs
        )
    }

    /// 独立图缩放比例浮标（可视画布右上角）
    private func drawZoomPill(text: String, in canvas: CGRect, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padH: CGFloat = 9
        let size = CGSize(width: ceil(textSize.width + padH * 2), height: 22)
        let rect = CGRect(x: canvas.maxX - size.width - 10, y: canvas.minY + 10, width: size.width, height: size.height)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor.black.withAlphaComponent(0.26).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 24/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.76).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(path)
        ctx.strokePath()
        (text as NSString).draw(
            at: CGPoint(x: rect.minX + padH, y: rect.minY + (size.height - textSize.height) / 2),
            withAttributes: attrs
        )
    }

    /// 8 向圆形手柄（Apple Preview / Keynote 风格：圆形白点 + 悬停放大带蓝环 + 柔和投影）
    private func drawSelectionHandles(ctx: CGContext, rect customRect: CGRect? = nil) {
        let rect = customRect ?? editorRectLocal
        guard rect.width >= SelectionGeometry.handleVisibilityThreshold
                || rect.height >= SelectionGeometry.handleVisibilityThreshold else { return }
        let baseSize: CGFloat = 7.5
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
            let d = isHot ? baseSize + 2.5 : baseSize
            let circleRect = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                          color: NSColor.black.withAlphaComponent(0.32).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.restoreGState()
            ctx.setStrokeColor((isHot ? DesignTokens.accent : NSColor.black.withAlphaComponent(0.24)).cgColor)
            ctx.setLineWidth(isHot ? 1.5 : 0.6)
            ctx.strokeEllipse(in: circleRect)
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
            ctx: ctx,
            format: colorCopyFormat
        )
    }

    /// 尺寸角标：深色磨砂胶囊 + 等宽数字 tabular-nums（拖拽不横向抖动）+ 0.5pt 发丝边 + 轻影
    private func drawBadge(text: String, below rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padH: CGFloat = 8
        let size = CGSize(width: ceil(textSize.width + padH * 2), height: 22)
        var origin = CGPoint(x: rect.maxX - size.width, y: min(rect.maxY + 8, bounds.height - size.height - 4))
        if origin.y + size.height > bounds.height { origin.y = rect.minY - size.height - 8 }
        if origin.y < 4 { origin.y = 4 }
        if origin.x < 4 { origin.x = 4 }
        let badgeRect = CGRect(origin: origin, size: size)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 24/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.78).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(path)
        ctx.strokePath()
        (text as NSString).draw(
            at: CGPoint(x: origin.x + padH, y: origin.y + (size.height - textSize.height) / 2),
            withAttributes: attributes
        )
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
    nonisolated func controlTextDidChange(_ obj: Notification) {
        MainActor.assumeIsolated {
            resizeActiveTextField()
        }
    }

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

// MARK: - 文字输入框（Apple Preview / CleanShot 风格：紧凑内边距 + 柔和半透可读衬底 + 细腻虚线语义边框）

@MainActor
private final class PaddedTextFieldCell: NSTextFieldCell {
    var padX: CGFloat = 8
    var padY: CGFloat = 4

    private func insetRect(for rect: NSRect) -> NSRect {
        let base = rect.insetBy(dx: padX, dy: padY)
        guard let font else { return base }
        let textH = ceil(font.ascender - font.descender)
        let extraY = max(0, floor((base.height - textH) / 2))
        return NSRect(x: base.minX, y: base.minY + extraY, width: base.width, height: base.height - extraY)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        insetRect(for: super.drawingRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: insetRect(for: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: insetRect(for: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

@MainActor
private final class GlassTextField: NSTextField {
    static let padX: CGFloat = 8
    static let padY: CGFloat = 4

    /// 当前画笔色（变动时同步刷新虚线语义边框与轻度对比衬底）
    var annotationColor: NSColor = DesignTokens.accent {
        didSet { applyAnnotationChrome() }
    }

    private let dashedBorder = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let customCell = PaddedTextFieldCell(textCell: "")
        customCell.padX = Self.padX
        customCell.padY = Self.padY
        customCell.isEditable = true
        customCell.isSelectable = true
        customCell.isScrollable = true
        customCell.wraps = false
        customCell.drawsBackground = false
        customCell.isBezeled = false
        customCell.isBordered = false
        self.cell = customCell

        isBordered = false
        drawsBackground = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = false

        dashedBorder.fillColor = NSColor.clear.cgColor
        dashedBorder.lineWidth = 1.0
        dashedBorder.lineDashPattern = [3.5, 2.5]
        layer?.addSublayer(dashedBorder)
        applyAnnotationChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dashedBorder.frame = bounds
        dashedBorder.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 7, cornerHeight: 7, transform: nil
        )
        CATransaction.commit()
    }

    func refreshPlaceholder() {
        let f = font ?? NSFont.systemFont(ofSize: 14, weight: .semibold)
        let srgb = annotationColor.usingColorSpace(.sRGB) ?? annotationColor
        let lum = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        let placeholderColor = (lum < 0.25 ? NSColor.black : NSColor.white).withAlphaComponent(0.45)
        placeholderAttributedString = NSAttributedString(string: "输入文字…", attributes: [
            .font: f,
            .foregroundColor: placeholderColor,
        ])
    }

    private func applyAnnotationChrome() {
        guard let layer else { return }
        let srgb = annotationColor.usingColorSpace(.sRGB) ?? annotationColor
        let lum = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 极克制的编辑态对比衬底（仅打字时出现，回车提交后消失），让深/浅文字在杂乱背景上都能一眼看清
        layer.backgroundColor = (lum < 0.25
            ? NSColor.white.withAlphaComponent(0.28)
            : NSColor.black.withAlphaComponent(0.26)).cgColor
        dashedBorder.strokeColor = annotationColor.withAlphaComponent(0.72).cgColor
        CATransaction.commit()
    }
}

// MARK: - 浮动字号条（Apple Liquid Glass 胶囊 + 克制呼吸感弹性滑动选中态，与工具栏统一语言）

@MainActor
private final class FontSizeBarView: NSView {
    static let buttonSize = CGSize(width: 28, height: 22)
    static let barHeight: CGFloat = 30
    static let iconAreaWidth: CGFloat = 24
    static let itemGap: CGFloat = 2

    static func preferredSize(buttonCount: Int) -> CGSize {
        let buttonsW = CGFloat(buttonCount) * buttonSize.width + CGFloat(max(0, buttonCount - 1)) * itemGap
        return CGSize(width: 8 + iconAreaWidth + 7 + buttonsW + 6, height: barHeight)
    }

    var onSelect: ((Int) -> Void)?
    private var buttons: [FontSizeOptionButton] = []
    private var selectedIndex = 0
    private let glassSurface: DesignTokens.Mat.LiquidGlassSurface
    private let foregroundHost = NSView()
    private let iconView = NSImageView()
    private let divider = NSView()
    private let pillIndicator = NSView()
    private var indicatorPositioned = false

    init(sizes: [Int], selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        self.glassSurface = DesignTokens.Mat.fixedLightCrystalBlur(
            cornerRadius: 10,
            tintAlpha: 0.08
        )
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        if !glassSurface.isNativeLiquidGlass {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 10
            layer?.shadowOffset = CGSize(width: 0, height: -3)
        }

        addSubview(glassSurface.hostView)
        foregroundHost.wantsLayer = true
        foregroundHost.appearance = NSAppearance(named: .aqua)
        addSubview(foregroundHost)
        let contentHost = foregroundHost

        iconView.image = TBIcon.symbolImage(named: "textformat.size", pointSize: 11.5, weight: .medium, hierarchical: true)
        iconView.contentTintColor = DesignTokens.label3
        contentHost.addSubview(iconView)

        divider.wantsLayer = true
        contentHost.addSubview(divider)

        // 克制半透强调蓝滑动胶囊（同心圆角 11pt，与工具栏一致，不抢戏、有呼吸边距）
        pillIndicator.wantsLayer = true
        pillIndicator.layer?.cornerRadius = glassSurface.isNativeLiquidGlass ? 11 : 7
        pillIndicator.layer?.borderWidth = 0.5
        contentHost.addSubview(pillIndicator)

        for (i, size) in sizes.enumerated() {
            let button = FontSizeOptionButton(label: "\(size)")
            button.onActivated = { [weak self] in
                guard let self else { return }
                self.select(index: i, animated: true)
                self.onSelect?(i)
            }
            buttons.append(button)
            contentHost.addSubview(button)
        }
        refreshAppearanceColors()
        select(index: selectedIndex, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    private func refreshAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            divider.layer?.backgroundColor = DesignTokens.hair.cgColor
            pillIndicator.layer?.backgroundColor = DesignTokens.accent
                .withAlphaComponent(isDark ? 0.24 : 0.14).cgColor
            pillIndicator.layer?.borderColor = DesignTokens.accent
                .withAlphaComponent(isDark ? 0.36 : 0.26).cgColor
            iconView.contentTintColor = DesignTokens.label3
        }
    }

    override func layout() {
        super.layout()
        glassSurface.hostView.frame = bounds
        foregroundHost.frame = bounds
        if !glassSurface.isNativeLiquidGlass {
            layer?.shadowPath = CGPath(
                roundedRect: bounds,
                cornerWidth: Self.barHeight / 2,
                cornerHeight: Self.barHeight / 2,
                transform: nil
            )
        }
        let midY = bounds.height / 2
        iconView.frame = NSRect(x: 9, y: (midY - 7).rounded(), width: 15, height: 14)
        divider.frame = NSRect(x: 28, y: (midY - 6.5).rounded(), width: 0.5, height: 13)

        var x: CGFloat = 34
        let btnY = ((bounds.height - Self.buttonSize.height) / 2).rounded()
        for button in buttons {
            button.frame = NSRect(x: x, y: btnY, width: Self.buttonSize.width, height: Self.buttonSize.height)
            x += Self.buttonSize.width + Self.itemGap
        }
        moveIndicator(to: selectedIndex, animated: false)
        indicatorPositioned = true
    }

    func select(index: Int, animated: Bool) {
        selectedIndex = index
        for (i, button) in buttons.enumerated() {
            button.setSelected(i == index)
        }
        moveIndicator(to: index, animated: animated && indicatorPositioned)
    }

    private func moveIndicator(to index: Int, animated: Bool) {
        guard buttons.indices.contains(index) else { return }
        let target = buttons[index].frame
        guard target.width > 0 else { return }
        if !animated {
            pillIndicator.frame = target
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            pillIndicator.animator().frame = target
        }
    }
}

/// 字号档按钮（纯数字等宽 12 / 14 / 17 / 21，alignmentRectInsets=zero 严防 macOS 26 拉伸）
@MainActor
private final class FontSizeOptionButton: NSButton {
    var onActivated: (() -> Void)?
    private var isHot = false
    private var isSelectedState = false
    private var trackingArea: NSTrackingArea?
    private let digitText: String

    init(label: String) {
        self.digitText = label
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = label
        wantsLayer = true
        layer?.cornerRadius = 7
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (!isSelectedState && isHot)
                ? DesignTokens.fillHover.cgColor
                : NSColor.clear.cgColor
            let color: NSColor = isSelectedState
                ? DesignTokens.accent
                : (isHot ? DesignTokens.label1 : DesignTokens.label2)
            let weight: NSFont.Weight = isSelectedState ? .semibold : .medium
            attributedTitle = NSAttributedString(string: digitText, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: weight),
                .foregroundColor: color,
            ])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true, scale: 0.94)
        onActivated?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self else { return }
            TactilePress.animate(view: self, pressed: false)
        }
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
