import CoreGraphics
import Foundation

/// 智能框选的领域模型与纯算法（Core/Domain，零 AppKit 纪律）。
///
/// ## 坐标系契约
/// 本文件所有几何一律是 **AppKit 全局坐标**（原点在主屏左下，Y 向上）：
/// `rectGlobal` / `pointGlobal` / `textLines` / `visualRects` / `visualTables` / `screenFrame` 同源。
/// 坐标换算（屏幕像素 → 全局点、AX 的 Y-down → Y-up）由适配器负责，领域不关心。
///
/// ## 为什么是「候选栈」而不是「一个框」
/// 光标落点处天然存在多个尺度的目标：一行文字、它所在的按钮、按钮所在的卡片、
/// 卡片所在的窗口…… 用户希望「先给最想要的那个，滚轮再逐级放大」。
/// 所以这里只做两件事：
/// 1. 把多路来源（AX 元素 / Vision 文本行 / 视觉矩形 / 视觉表格结构 / 窗口）合成一个**按面积升序**
///    的候选栈（越小越具体，越靠前）；
/// 2. 决定默认落在哪一层（`defaultIndex`）—— 这是体验的关键，见 `decideDefaultIndex`。
///
/// ## 关键纪律
/// - **不自动高亮近似全屏大窗**：贴着屏幕边缘才会「变形整屏」，平时光标落在桌面空白处
///   不该弹出一个框住整个屏幕的高亮（与 Snapcut 既有框选手感一致）。但若光标处有
///   更细的目标，大窗仍留在栈里（滚轮可以逐级向上切到整窗）。
/// - **大块优先于单行字**：用户口径（2026-11-28）——「优先解析表格这种大块矩形，
///   以及网页 / GUI 里的大元素；没有表格时，无序列表的每一行也 OK」。所以默认层级的
///   优先级是 单元格 → 整行 → 整列 → 整表 → 列表项 → 大块元素/区域/视觉大矩形 → 单行文本，
///   详见 `decideDefaultIndex`。候选栈本身仍然完整保留，滚轮随时可以逐级切遍表格结构与整窗。
/// - **表格要能精准到单元格**：只框整张表是不够的。光标在表格内部时默认落在最内层
///   `.tableCell`（没有单元格就退 `.tableRow` → `.tableColumn` → `.table`），
///   光标贴着表格外边缘（≤ 8pt）时一键截整表。AX 没给出表格粒度（Electron/PDF/Canvas/
///   未授权）时，由 `DetectedVisualTable`（像素线检测结果）补齐同一套层级。
/// - **表格粒度齐全时不要视觉噪点**：AX 已给出表格/单元格/行时，Vision 的视觉矩形只是
///   背景填充块，只有明显更小（< 0.65 倍最深 AX 元素）时才值得作为候选；
///   AX 没细化（网页只有整页 `AXWebArea` 巨壳）时放宽到 0.72 倍，让像素大块矩形顶上。
public enum SmartCandidateKind: Int, Sendable, Equatable, CaseIterable {
    /// 一行文字（Vision 文本行 / AX 静态文本）
    case textLine = 0
    /// 表格单元格（AXCell / AXGridCell，或视觉表格结构）
    case tableCell = 1
    /// 列表项（无序列表 / 大纲的每一行，AXRow / AXOutlineRow / AXListItem）
    case listItem = 2
    /// 表格行（视觉表格结构 / AX 行）
    case tableRow = 3
    /// 表格列（视觉表格结构）
    case tableColumn = 4
    /// 控件（按钮、图片、输入框等，AX 精确元素）
    case element = 5
    /// 表格（AXTable / AXGrid：大块矩形优先识别的头号目标）
    case table = 6
    /// 容器（卡片、分组、面板、滚动区等，AX 容器元素）
    case container = 7
    /// 视觉识别矩形（Vision 版面分析，AX 没细化时的兜底）
    case visualRect = 8
    /// 窗口
    case window = 9
    /// 整块显示器
    case display = 10

    /// 给用户看的层级名（滚轮切换提示用）
    public var displayName: String {
        switch self {
        case .textLine: return "文本行"
        case .tableCell: return "单元格"
        case .listItem: return "列表项"
        case .tableRow: return "表格行"
        case .tableColumn: return "表格列"
        case .element: return "控件"
        case .table: return "表格"
        case .container: return "区域"
        case .visualRect: return "识别区域"
        case .window: return "窗口"
        case .display: return "全屏"
        }
    }
}

/// 视觉表格结构（像素线检测结果，AppKit 全局坐标 Y 向上）。
///
/// 为什么需要它：Electron / 静态图片 / PDF / Canvas 里的表格，AX 往往只吐一个巨壳
/// 甚至什么都不吐。此时「整表 / 行 / 列 / 单元格」四层几何只能靠 Vision 找横竖线，
/// 由适配器产出本结构，领域再把它融合进候选栈（与 AX 表格同一套优先级）。
public struct DetectedVisualTable: Sendable, Equatable {
    /// 整张表格矩形
    public let tableRect: CGRect
    /// 每一行的矩形
    public let rowRects: [CGRect]
    /// 每一列的矩形
    public let columnRects: [CGRect]
    /// 每个单元格的矩形
    public let cellRects: [CGRect]

    public init(
        tableRect: CGRect,
        rowRects: [CGRect],
        columnRects: [CGRect],
        cellRects: [CGRect]
    ) {
        self.tableRect = tableRect
        self.rowRects = rowRects
        self.columnRects = columnRects
        self.cellRects = cellRects
    }
}

/// 一个候选框（全局 Y-up 坐标）
public struct SmartSelectionCandidate: Sendable, Equatable {
    /// 全局坐标下的矩形（原点主屏左下，Y 向上）
    public let rectGlobal: CGRect
    public let kind: SmartCandidateKind
    /// 所属窗口（AX 探测拿得到就带，用于后续「截窗口」等能力）
    public let windowID: CGWindowID?
    /// 所属应用名（展示用；空串 = 未知）
    public let ownerName: String
    /// 窗口/控件标题（展示用；空串 = 无）
    public let title: String

    public init(
        rectGlobal: CGRect,
        kind: SmartCandidateKind,
        windowID: CGWindowID? = nil,
        ownerName: String = "",
        title: String = ""
    ) {
        self.rectGlobal = rectGlobal
        self.kind = kind
        self.windowID = windowID
        self.ownerName = ownerName
        self.title = title
    }
}

/// 候选栈：按面积升序（越具体越靠前），`defaultIndex` 指向默认高亮项
public struct SmartCandidateStack: Sendable, Equatable {
    public let candidates: [SmartSelectionCandidate]
    public let defaultIndex: Int

    public init(candidates: [SmartSelectionCandidate], defaultIndex: Int) {
        self.candidates = candidates
        self.defaultIndex = defaultIndex
    }

    public static let empty = SmartCandidateStack(candidates: [], defaultIndex: 0)

    public var isEmpty: Bool { candidates.isEmpty }

    public func candidate(at index: Int) -> SmartSelectionCandidate? {
        guard candidates.indices.contains(index) else { return nil }
        return candidates[index]
    }
}

/// 候选合成 / 排序 / 去重 / 默认层级决策（纯函数，可单测）
public enum SmartCandidateResolver {
    /// 候选最小边长（逻辑点）：小于它的框是指示灯、分隔线、图标碎片，不打扰用户
    public static let minCandidateSide: CGFloat = 12
    /// 命中容差（逻辑点）：光标压在边上也算命中
    public static let pointTolerance: CGFloat = 1
    /// 近重复判定：四边最大差值小于它即视为同一个框
    public static let dedupeEdgeDelta: CGFloat = 4
    /// 近重复判定：IoU 超过它即视为同一个框
    public static let dedupeIoU: CGFloat = 0.94
    /// 视觉矩形只有在明显小于最深 AX 元素（面积 < 该比例）时才纳入
    /// （AX 已给出表格/列表项等结构化目标时用这个严格值，别拿像素噪点污染精确结果）
    public static let visualRectAreaRatio: CGFloat = 0.65
    /// 同上，但 AX 没给出表格/列表项时用（网页/Electron 常常只吐一个整页 `AXWebArea` 巨壳，
    /// 此时 Vision 的表格框/卡片大矩形才是用户真正想要的那一层）
    public static let visualRectAreaRatioWithoutStructuredAX: CGFloat = 0.72
    /// 背景巨壳闸门：面积超过参考面积（窗口面积，无窗口则屏幕面积）这个比例的元素不算候选焦点
    /// （挡的是整页 `AXWebArea` / 整窗背景板抢焦点）
    public static let backgroundShellRatio: CGFloat = 0.78
    /// 表格面积上限（相对参考面积）：贴满整窗的「伪表格」不参与表格绝对优先
    public static let tableAreaCapRatio: CGFloat = 0.90
    /// 列表项高度上限（相对屏幕高度）：挡住整块列表面板被当成单个列表行
    public static let listItemMaxHeightRatio: CGFloat = 0.35
    /// 「有意义的大块区域」最小边长（逻辑点）：卡片 / 面板 / 侧边栏
    public static let containerMinWidth: CGFloat = 48
    public static let containerMinHeight: CGFloat = 32
    /// 「有意义的控件」最小边长：排除碎小单字、链接碎片、图标点
    public static let elementMinWidth: CGFloat = 44
    public static let elementMinHeight: CGFloat = 28
    /// 「有意义的视觉大矩形」最小边长：网页/图片里的表格框、大块卡片
    public static let visualRectMinWidth: CGFloat = 64
    public static let visualRectMinHeight: CGFloat = 40
    /// 独立大块控件阈值（面积）：≥ 2400 视为「一张配图 / 一个完整卡片控件 / 大输入区」，
    /// 默认优先级高于容器
    public static let significantElementArea: CGFloat = 2400
    /// 合理大块视觉矩形阈值（面积）：≥ 4800 才可能与 AX 容器竞争默认焦点
    public static let significantVisualRectArea: CGFloat = 4800
    /// 「AX 是否已给出同样贴合的块」判定容差：AX 块面积 ≤ 视觉矩形 * 该比例即视为更贴合
    public static let finerAXAreaRatio: CGFloat = 1.2
    /// 文本行面积比阈值：容器面积 > 文本行 * 2.2 → 默认选文本行（保留常量以兼容旧调用）
    public static let textLineAreaRatio: CGFloat = 2.2
    /// 近似满屏大窗：宽度占比（相对 screenFrame）
    public static let nearFullscreenWidthRatio: CGFloat = 0.88
    /// 近似满屏大窗：高度占比（相对 screenFrame）
    public static let nearFullscreenHeightRatio: CGFloat = 0.86
    /// 窗口与容器「近似等大」的容差（保留 window 以带出 windowID / ownerName）
    public static let sameSizeAreaTolerance: CGFloat = 0.15
    /// 表格外边缘命中宽度（逻辑点）：光标距表格四边任意一边 ≤ 它 → 一键截整张表格
    public static let tableEdgeTolerance: CGFloat = 8

    /// 合成光标处的候选栈
    ///
    /// - Parameters:
    ///   - point: 光标全局坐标（Y 向上）
    ///   - screenFrame: 当前屏幕全局 frame
    ///   - textLines: Vision 文本行（全局坐标）
    ///   - visualRects: Vision 视觉矩形（全局坐标）
    ///   - visualTables: Vision 视觉表格结构（整表/行/列/单元格，全局坐标）；
    ///     AX 没给出表格内部粒度时用它补齐层级，默认空以向后兼容
    ///   - axCandidates: AX 探测到的元素（含 kind / windowID / ownerName / title）
    ///   - windowCandidate: 光标下的窗口
    public static func buildStack(
        atGlobalPoint point: CGPoint,
        screenFrame: CGRect,
        textLines: [CGRect],
        visualRects: [CGRect],
        visualTables: [DetectedVisualTable] = [],
        axCandidates: [SmartSelectionCandidate],
        windowCandidate: SmartSelectionCandidate?
    ) -> SmartCandidateStack {
        let screenBounds = screenFrame.standardized
        guard screenBounds.width > 0, screenBounds.height > 0 else { return .empty }

        // MARK: 1. 窗口裁剪域 + 窗口候选

        var childBounds = screenBounds
        var windowAccepted: SmartSelectionCandidate?

        if let window = windowCandidate {
            let intersection = window.rectGlobal.intersection(screenBounds)
            if !intersection.isNull, intersection.width > 0, intersection.height > 0 {
                childBounds = intersection
            }
            if let clipped = validRect(window.rectGlobal, within: screenBounds),
                containsPoint(clipped, point)
            {
                windowAccepted = SmartSelectionCandidate(
                    rectGlobal: clipped,
                    kind: window.kind,
                    windowID: window.windowID,
                    ownerName: window.ownerName,
                    title: window.title
                )
            }
        }

        var collected: [SmartSelectionCandidate] = []

        // MARK: 2. 文本行（仅取面积最小的那一条，避免重叠文本行刷屏）

        var bestTextLine: CGRect?
        for line in textLines {
            guard let clipped = validRect(line, within: childBounds), containsPoint(clipped, point)
            else { continue }
            if let current = bestTextLine {
                if area(clipped) < area(current) { bestTextLine = clipped }
            } else {
                bestTextLine = clipped
            }
        }
        if let bestTextLine {
            collected.append(SmartSelectionCandidate(rectGlobal: bestTextLine, kind: .textLine))
        }

        // MARK: 3. AX 候选（全部纳入，但要先裁剪到窗口域并过有效性）

        var acceptedAX: [SmartSelectionCandidate] = []
        for candidate in axCandidates {
            guard let clipped = validRect(candidate.rectGlobal, within: childBounds),
                containsPoint(clipped, point)
            else { continue }
            acceptedAX.append(
                SmartSelectionCandidate(
                    rectGlobal: clipped,
                    kind: candidate.kind,
                    windowID: candidate.windowID,
                    ownerName: candidate.ownerName,
                    title: candidate.title
                )
            )
        }
        collected.append(contentsOf: acceptedAX)

        // MARK: 4. 视觉矩形兜底（AX 没细化时替它把大块矩形框住）
        //
        // 网页 / Electron 里 AX 经常只吐一个整页巨壳 `AXWebArea`，而用户真正想要的是
        // 页面里的表格框、卡片、大图 —— 那恰好是 Vision 四边形检测最擅长的。
        // 所以：AX 没给出表格/列表项时放宽闸门（最深 AX 元素的 0.72 倍），
        // 已给出结构化目标时保持严格（0.65 倍），不拿像素噪点污染精确结果。

        let hasStructuredAX = acceptedAX.contains {
            $0.kind == .table || $0.kind == .listItem
                || $0.kind == .tableCell || $0.kind == .tableRow
        }
        let visualRectRatio = hasStructuredAX
            ? visualRectAreaRatio
            : visualRectAreaRatioWithoutStructuredAX
        let deepestAXArea = acceptedAX.map { area($0.rectGlobal) }.min()

        for rect in visualRects {
            guard let clipped = validRect(rect, within: childBounds), containsPoint(clipped, point)
            else { continue }
            if let deepestAXArea {
                guard area(clipped) < deepestAXArea * visualRectRatio else { continue }
            }
            collected.append(SmartSelectionCandidate(rectGlobal: clipped, kind: .visualRect))
        }

        // MARK: 5. 视觉表格兜底（无 AX 表格粒度时补齐 单元格 / 行 / 列 / 整表）
        //
        // Electron 自定义 div 表格 / 静态图片 / PDF / Canvas 里，AX 往往只吐一个巨壳
        // 甚至什么都不吐；但用户要的「逐格精准框选」只能靠像素线检测的结构。
        // 铁门：只有 AX **完全没给出**表格内部粒度（.tableCell / .tableRow）时才融合，
        // 绝不用像素结果覆盖 AX 的精确元素。

        let hasAXTableGranularity = acceptedAX.contains {
            $0.kind == .tableCell || $0.kind == .tableRow
        }
        if !hasAXTableGranularity {
            for table in visualTables {
                guard let tableRect = validRect(table.tableRect, within: childBounds),
                    containsPoint(tableRect, point)
                else { continue }
                collected.append(SmartSelectionCandidate(rectGlobal: tableRect, kind: .table))
                for cell in table.cellRects {
                    guard let clipped = validRect(cell, within: childBounds),
                        containsPoint(clipped, point)
                    else { continue }
                    collected.append(SmartSelectionCandidate(rectGlobal: clipped, kind: .tableCell))
                }
                for row in table.rowRects {
                    guard let clipped = validRect(row, within: childBounds),
                        containsPoint(clipped, point)
                    else { continue }
                    collected.append(SmartSelectionCandidate(rectGlobal: clipped, kind: .tableRow))
                }
                for column in table.columnRects {
                    guard let clipped = validRect(column, within: childBounds),
                        containsPoint(clipped, point)
                    else { continue }
                    collected.append(SmartSelectionCandidate(rectGlobal: clipped, kind: .tableColumn))
                }
            }
        }

        // MARK: 6. 窗口候选

        if let windowAccepted {
            collected.append(windowAccepted)
        }

        guard !collected.isEmpty else { return .empty }

        // MARK: 7. 排序（面积升序，同面积按 kind 优先级）+ 相邻近重复合并

        var candidates = sortBySpecificity(collected)
        candidates = mergeNearDuplicates(candidates)

        // MARK: 8. 近似满屏大窗剪枝
        // 没有更细的目标时，不要给用户「一开就框住整个屏幕」的观感；
        // 有更细目标时大窗留在栈顶，滚轮可逐级切到整窗。

        let hasFinerCandidate = candidates.contains { $0.kind != .window && $0.kind != .display }
        if !hasFinerCandidate {
            let kept = candidates.filter { candidate in
                !(candidate.kind == .window && isNearFullscreen(candidate.rectGlobal, screenFrame: screenBounds))
            }
            guard !kept.isEmpty else { return .empty }
            candidates = kept
        }

        // MARK: 9. 默认层级
        //
        // 参考面积：有窗口用窗口面积（窗口内的元素才算「背景巨壳」），否则用屏幕面积。

        let windowRect = candidates.first { $0.kind == .window }?.rectGlobal
        let referenceArea = windowRect.map { area($0) } ?? area(screenBounds)
        let defaultIndex = decideDefaultIndex(
            candidates,
            referenceArea: referenceArea,
            screenHeight: screenBounds.height,
            atGlobalPoint: point
        )

        return SmartCandidateStack(candidates: candidates, defaultIndex: defaultIndex)
    }

    // MARK: - 默认层级决策

    /// 默认落在哪一层（只影响初始高亮，候选栈本身完整保留，滚轮随时可切换）
    ///
    /// 优先级（用户口径 2026-11-28：表格要能精准到单元格/行/列/整表，其次大块，最后单行字）：
    /// 1. 表格结构：贴着表格外边缘（≤ 8pt）→ 整张表；表格内部 → 最内层单元格 →
    ///    整行（无竖线表格）→ 整列 → 整张表格；
    /// 2. 无序列表的每一行（非背景巨壳、高度合理）；
    /// 3. 网页 / GUI 的大块目标：合理大块视觉矩形 / 独立大块控件 / 非背景容器 / 其他控件；
    /// 4. 纯文本流兜底：单行文本；
    /// 5. 最终兜底：最具体的一层（index 0）。
    ///
    /// - Parameters:
    ///   - candidates: 面积升序的候选栈
    ///   - referenceArea: 参考面积（有窗口取窗口面积，否则取屏幕面积）
    ///   - point: 光标全局坐标（Y 向上）—— 判定「贴着表格外边缘」与「落在哪个单元格」必需
    static func decideDefaultIndex(
        _ candidates: [SmartSelectionCandidate],
        referenceArea: CGFloat,
        atGlobalPoint point: CGPoint
    ) -> Int {
        // 不知屏幕高度时，按参考面积的「等价正方形边长」估算（列表项高度闸门用）
        decideDefaultIndex(
            candidates,
            referenceArea: referenceArea,
            screenHeight: referenceArea > 0 ? referenceArea.squareRoot() : 0,
            atGlobalPoint: point
        )
    }

    /// 同上的完整版：`screenHeight` 用于「列表项高度是否合理」闸门
    static func decideDefaultIndex(
        _ candidates: [SmartSelectionCandidate],
        referenceArea: CGFloat,
        screenHeight: CGFloat,
        atGlobalPoint point: CGPoint
    ) -> Int {
        guard !candidates.isEmpty else { return 0 }

        let reference = max(referenceArea, 1)
        // 背景巨壳：整页 AXWebArea / 整窗背景板，不是用户想要的「内容」
        let backgroundLimit = reference * backgroundShellRatio
        let listItemMaxHeight = screenHeight * listItemMaxHeightRatio
        // 贴满整窗的「伪表格」不参与表格层级（否则整页大框会吃掉一切）
        let tableAreaLimit = reference * tableAreaCapRatio

        func rect(at index: Int) -> CGRect { candidates[index].rectGlobal }
        func isBackgroundShell(_ index: Int) -> Bool { area(rect(at: index)) > backgroundLimit }
        func smallest(_ indices: [Int], minArea: CGFloat = 0) -> Int? {
            indices
                .filter { area(rect(at: $0)) >= minArea }
                .min { area(rect(at: $0)) < area(rect(at: $1)) }
        }
        func largest(_ indices: [Int], minArea: CGFloat = 0) -> Int? {
            indices
                .filter { area(rect(at: $0)) >= minArea }
                .max { area(rect(at: $0)) < area(rect(at: $1)) }
        }

        // 1. 表格结构优先：整表 / 单元格 / 行 / 列
        //
        // 用户口径（2026-11-28）：「表格只能框整张表」是核心病。鼠标在单元格之间
        // 移动时要逐格精准跳变，滚轮依次切 单元格 → 整行 → 整列 → 整张表格。
        // 所以先看表格层级，而不是一上来就把 .table 定死。

        func isTableStructure(_ kind: SmartCandidateKind) -> Bool {
            kind == .table || kind == .tableCell || kind == .tableRow || kind == .tableColumn
        }
        func withinTableAreaCap(_ index: Int) -> Bool { area(rect(at: index)) <= tableAreaLimit }

        let structureIndices = candidates.indices.filter { isTableStructure(candidates[$0].kind) }
        if !structureIndices.isEmpty {
            // 1a. 最内层有效整表（面积不超过「伪表格」上限）
            let tableIndices = structureIndices.filter {
                candidates[$0].kind == .table && withinTableAreaCap($0)
            }
            let innermostTable = smallest(tableIndices)

            // 1b. 光标贴着表格外边缘（距四边任意一边 ≤ 8pt）→ 一键截整张表格。
            //     这样「轻轻碰一下表格边」就能拿到整表，不用先钻进单元格再滚轮往上翻。
            if let innermostTable,
                !rect(at: innermostTable)
                    .insetBy(dx: tableEdgeTolerance, dy: tableEdgeTolerance)
                    .contains(point)
            {
                return innermostTable
            }

            // 1c. 表格内部 → 最内层单元格 → 整行（无竖线表格）→ 整列
            let cellIndices = structureIndices.filter {
                candidates[$0].kind == .tableCell && withinTableAreaCap($0) && !isBackgroundShell($0)
            }
            if let cell = smallest(cellIndices) { return cell }

            let rowIndices = structureIndices.filter {
                candidates[$0].kind == .tableRow && withinTableAreaCap($0) && !isBackgroundShell($0)
            }
            if let row = smallest(rowIndices) { return row }

            let columnIndices = structureIndices.filter {
                candidates[$0].kind == .tableColumn && withinTableAreaCap($0) && !isBackgroundShell($0)
            }
            if let column = smallest(columnIndices) { return column }

            // 1d. 只剩整张表（表格没有行/列/单元格粒度，或都超面积闸门）
            if let innermostTable { return innermostTable }
        }

        // 2. 不在表格里：无序列表 / 大纲的每一行（列表行精准识别的核心体验）
        let listItemIndices = candidates.indices.filter { index in
            candidates[index].kind == .listItem
                && !isBackgroundShell(index)
                && rect(at: index).height <= listItemMaxHeight
        }
        if let listItem = smallest(listItemIndices) { return listItem }

        // 3. 网页 / GUI 的大块元素与视觉大矩形（均须是「非背景巨壳」）
        let containerIndices = candidates.indices.filter { index in
            let box = rect(at: index)
            return candidates[index].kind == .container
                && !isBackgroundShell(index)
                && box.width >= containerMinWidth && box.height >= containerMinHeight
        }
        let elementIndices = candidates.indices.filter { index in
            let box = rect(at: index)
            return candidates[index].kind == .element
                && !isBackgroundShell(index)
                && box.width >= elementMinWidth && box.height >= elementMinHeight
        }
        let visualIndices = candidates.indices.filter { index in
            let box = rect(at: index)
            return candidates[index].kind == .visualRect
                && !isBackgroundShell(index)
                && box.width >= visualRectMinWidth && box.height >= visualRectMinHeight
        }

        // 3a. AX 没给出同样贴合的块时，Vision 的大块矩形（表格框/卡片）直接胜出。
        //     多块时取**最大**的那块：这一层的目的就是「大块优先」，
        //     否则一张贴着单行字的 120×40 细条会抢走整张表格的焦点（细块仍在栈里可滚轮切入）。
        if let visualRect = largest(visualIndices, minArea: significantVisualRectArea) {
            let visualArea = area(rect(at: visualRect))
            let hasFinerAX = (containerIndices + elementIndices).contains {
                area(rect(at: $0)) <= visualArea * finerAXAreaRatio
            }
            if !hasFinerAX { return visualRect }
        }

        // 3b. 独立大块控件（配图/大卡片控件/大输入区）→ 非背景容器 → 视觉大矩形 → 小控件
        if let element = smallest(elementIndices, minArea: significantElementArea) { return element }
        if let container = smallest(containerIndices) { return container }
        if let visualRect = smallest(visualIndices) { return visualRect }
        let anyElement = candidates.indices.filter {
            candidates[$0].kind == .element && !isBackgroundShell($0)
        }
        if let element = smallest(anyElement) { return element }

        // 4. 纯文本流 / 无 AX 权限时的无序列表文本 → 落回单行文本（原有体验）
        if let textLine = candidates.firstIndex(where: { $0.kind == .textLine }) { return textLine }

        // 5. 最终兜底：最具体的一层（例如独立小窗且无子元素）
        return 0
    }

    // MARK: - 几何工具

    static func area(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }

    /// 裁剪 + 有效性校验：null / infinite / 太小一律丢弃
    static func validRect(_ rect: CGRect, within bounds: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite else { return nil }
        let standardized = rect.standardized
        guard !standardized.isNull, !standardized.isInfinite else { return nil }
        let clipped = standardized.intersection(bounds)
        guard !clipped.isNull, !clipped.isInfinite else { return nil }
        guard clipped.width >= minCandidateSide, clipped.height >= minCandidateSide else { return nil }
        return clipped
    }

    /// 命中判定（允许 1pt 容差：光标压在边上也算）
    static func containsPoint(_ rect: CGRect, _ point: CGPoint) -> Bool {
        rect.insetBy(dx: -pointTolerance, dy: -pointTolerance).contains(point)
    }

    static func sortBySpecificity(_ candidates: [SmartSelectionCandidate]) -> [SmartSelectionCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsArea = area(lhs.rectGlobal)
            let rhsArea = area(rhs.rectGlobal)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    /// 相邻近重复合并（四边差 < 4pt 或 IoU > 0.94）
    static func mergeNearDuplicates(
        _ candidates: [SmartSelectionCandidate]
    ) -> [SmartSelectionCandidate] {
        var merged: [SmartSelectionCandidate] = []
        for candidate in candidates {
            guard let last = merged.last else {
                merged.append(candidate)
                continue
            }
            if isNearDuplicate(last, candidate) {
                merged[merged.count - 1] = preferred(last, candidate)
            } else {
                merged.append(candidate)
            }
        }
        return sortBySpecificity(merged)
    }

    static func isNearDuplicate(_ lhs: SmartSelectionCandidate, _ rhs: SmartSelectionCandidate) -> Bool {
        let a = lhs.rectGlobal
        let b = rhs.rectGlobal
        let edgeDelta = max(
            max(abs(a.minX - b.minX), abs(a.minY - b.minY)),
            max(abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
        )
        if edgeDelta < dedupeEdgeDelta { return true }
        return intersectionOverUnion(a, b) > dedupeIoU
    }

    /// 合并时保留谁：优先级高（kind.rawValue 小）者胜；
    /// 但 window 与近似等大的 container 合并时保留 window（否则丢掉 windowID / ownerName）；
    /// 表格结构层级（整表/单元格/行/列）与同位置的近重复块合并时优先保留表格结构。
    static func preferred(
        _ lhs: SmartSelectionCandidate,
        _ rhs: SmartSelectionCandidate
    ) -> SmartSelectionCandidate {
        if lhs.kind == .window || rhs.kind == .window {
            let windowCandidate = lhs.kind == .window ? lhs : rhs
            let other = lhs.kind == .window ? rhs : lhs
            if other.kind == .container, isApproximatelySameSize(windowCandidate.rectGlobal, other.rectGlobal) {
                return windowCandidate
            }
        }
        // 表格结构层级是强结构目标，不能被同位置的文本行 / 识别区域 / 背景区域吞掉
        // （否则「框单元格」会退化成「框那行字」或「框整块区域」）；
        // 表格结构之间（行 vs 列、单元格 vs 行）则交给下面的 rawValue 排序。
        if isTableHierarchy(lhs.kind), isWeaklyStructured(rhs.kind) { return lhs }
        if isTableHierarchy(rhs.kind), isWeaklyStructured(lhs.kind) { return rhs }
        // 同位置的文本行不能盖掉表格/列表项（否则整张表会被它里面那行字吃掉默认优先级）
        let structuredKinds: [SmartCandidateKind] = [.table, .listItem, .tableCell, .tableRow, .tableColumn]
        if structuredKinds.contains(lhs.kind), rhs.kind == .textLine { return lhs }
        if structuredKinds.contains(rhs.kind), lhs.kind == .textLine { return rhs }
        // 其余按 kind.rawValue 升序（同面积时也是这个口径；行与列面积相等就都留着，
        // 它们几何不重叠、IoU 天然很低，根本不会互相合并）
        return lhs.kind.rawValue <= rhs.kind.rawValue ? lhs : rhs
    }

    /// 表格结构层级（整表 / 单元格 / 行 / 列）
    static func isTableHierarchy(_ kind: SmartCandidateKind) -> Bool {
        kind == .table || kind == .tableCell || kind == .tableRow || kind == .tableColumn
    }

    /// 弱结构化块（近重复时接受让位给表格结构）：文本行 / 识别区域 / 区域 / 列表项
    static func isWeaklyStructured(_ kind: SmartCandidateKind) -> Bool {
        kind == .textLine || kind == .visualRect || kind == .container || kind == .listItem
    }

    static func isApproximatelySameSize(_ a: CGRect, _ b: CGRect) -> Bool {
        let areaA = area(a)
        let areaB = area(b)
        let larger = max(areaA, areaB)
        guard larger > 0 else { return false }
        return abs(areaA - areaB) <= larger * sameSizeAreaTolerance
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        let intersectionArea = area(intersection)
        let unionArea = area(a) + area(b) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    /// 近似满屏大窗（相对当前屏幕尺寸）
    static func isNearFullscreen(_ rect: CGRect, screenFrame: CGRect) -> Bool {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return false }
        return rect.width >= screenFrame.width * nearFullscreenWidthRatio
            && rect.height >= screenFrame.height * nearFullscreenHeightRatio
    }
}
