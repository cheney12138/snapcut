import CoreGraphics
import Foundation

/// 智能框选候选栈真实验证入口（纯 Core，不依赖 App / AX / Vision / AppKit）。
/// 由 scripts/test-smart-selection.sh 编译运行：SmartSelectionModel.swift + 本文件。
///
/// 覆盖（对齐用户口径「优先表格/大块元素，没表格再列表行，最后才单行字」）：
/// 空输入 / 近似满屏大窗剪枝与「有大窗仍可滚轮切出」/ 面积排序与近重复去重 /
/// 表格绝对优先（场景 A）/ 列表项优先（场景 B）/ 卡片与大块控件优先（场景 C）/
/// 背景巨壳回落单行文本（场景 D）/ Vision 大块矩形压制碎文本行（场景 E）/
/// 裁剪与 <12pt 噪点过滤 / 视觉矩形兜底与 AX 结构化时抑制 /
/// 表格四级识别（场景 F：单元格 / 行 / 列 / 整表）/ 表格外边缘一键整表（场景 G）/
/// 无竖线表格整行（场景 H）/ 视觉表格 visualTables 兜底（场景 I）/ AX 已有粒度时不融合（场景 J）。
@main
struct TestSmartSelectionMain {
    /// 测试屏幕：1440x900，全局坐标 Y 向上（原点主屏左下）
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// 常用光标落点
    static let point = CGPoint(x: 700, y: 450)
    /// 屏幕面积（= referenceArea 的屏幕口径）
    static let screenArea: CGFloat = 1440 * 900

    static func main() {
        do {
            try test1EmptyInput()
            try test2NearFullscreenWindowPruning()
            try test3SortingAndNearDuplicateMerge()
            try test4TablePriority()
            try test5ListItemPriority()
            try test6BigBlockPriority()
            try test7BackgroundShellTextFallback()
            try test8VisionBigRectBeatsTextLine()
            try test9ClippingAndNoiseFiltering()
            try test10VisualRectsFallback()
            try test11TableCellHierarchy()
            try test12TableOuterEdgeSelectsWholeTable()
            try test13RowOnlyTableSelectsRow()
            try test14VisualTablesFallback()
            try test15AXGranularitySuppressesVisualTables()
            print("[TestSmartSelection] ALL PASS ✅")
        } catch {
            print("[TestSmartSelection] FAILED ❌: \(error)")
            exit(1)
        }
    }

    // MARK: - 场景 1：空输入

    static func test1EmptyInput() throws {
        print("[TestSmartSelection] 场景1: 空输入返回 empty")

        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectTrue(stack.isEmpty, "空输入 isEmpty")
        try expectEqual(stack.candidates.count, 0, "空输入候选数")
        try expectEqual(stack.defaultIndex, 0, "空输入 defaultIndex")
        try expectTrue(stack.candidate(at: 0) == nil, "空输入 candidate(at:0) 为 nil")
        try expectTrue(stack == .empty, "空输入等价 .empty")
        try expectEqual(SmartCandidateResolver.decideDefaultIndex([], referenceArea: screenArea, atGlobalPoint: point), 0,
                        "空栈默认层级兜底为 0")

        // 屏幕 frame 非法（零尺寸）也不应崩溃，直接 empty
        let zeroScreen = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: .zero,
            textLines: [CGRect(x: 600, y: 400, width: 200, height: 100)],
            visualRects: [],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectTrue(zeroScreen.isEmpty, "零尺寸屏幕 isEmpty")
    }

    // MARK: - 场景 2：近似满屏大窗

    static func test2NearFullscreenWindowPruning() throws {
        print("[TestSmartSelection] 场景2: 近似满屏大窗剪枝 / 有子元素时留在栈顶")

        // 只有一块近似满屏大窗（1400x880 ≥ 0.88*1440 & 0.86*900）→ 不给「一开就框全屏」的观感
        let fullscreenWindow = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 0, y: 0, width: 1400, height: 880),
            kind: .window,
            windowID: 42,
            ownerName: "Safari",
            title: "首页"
        )
        let onlyWindow = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [],
            windowCandidate: fullscreenWindow
        )
        try expectTrue(onlyWindow.isEmpty, "仅近似满屏大窗 → empty")

        // 小窗口保留（不误剪）
        let smallWindow = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 200, y: 200, width: 600, height: 400),
            kind: .window,
            windowID: 7,
            ownerName: "Finder",
            title: "窗口"
        )
        let smallStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [],
            windowCandidate: smallWindow
        )
        try expectEqual(smallStack.candidates.count, 1, "小窗口候选数")
        try expectEqual(smallStack.candidates[0].kind, .window, "小窗口 kind")
        try expectEqual(smallStack.defaultIndex, 0, "小窗口 defaultIndex")
        try expectEqual(smallStack.candidates[0].windowID, 7, "小窗口 windowID 保留")

        // 近似满屏大窗 + 更细子元素 → 大窗留在栈顶（数组末尾）供滚轮逐级切出；
        // 默认落在大块控件（图片/卡片按钮），不再落单行字（用户口径：大块优先）
        let element = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 600, y: 400, width: 200, height: 100),
            kind: .element
        )
        let mixed = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [CGRect(x: 620, y: 440, width: 160, height: 20)],
            visualRects: [],
            axCandidates: [element],
            windowCandidate: fullscreenWindow
        )
        try expectEqual(mixed.candidates.count, 3, "大窗+子元素候选数")
        try expectEqual(mixed.candidates.last?.kind, .window, "大窗留在栈顶（末尾）")
        try expectEqual(mixed.candidates.last?.windowID, 42, "大窗 windowID 保留")
        try expectEqual(mixed.candidates.first?.kind, .textLine, "最具体候选排在最前")
        try expectEqual(mixed.candidates[mixed.defaultIndex].kind, .element, "默认落在大块控件")
        try expectTrue(
            mixed.candidates.contains { $0.kind == .textLine },
            "单行文本仍在栈中（滚轮可切回）"
        )
    }

    // MARK: - 场景 3：排序 + 近重复去重

    static func test3SortingAndNearDuplicateMerge() throws {
        print("[TestSmartSelection] 场景3: 面积排序 + 四边差<4 / IoU>0.94 去重")

        let outerContainer = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 400, y: 200, width: 600, height: 500),
            kind: .container
        )
        let element = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 600, y: 400, width: 200, height: 100),
            kind: .element
        )
        // 四边差 = 1pt → 与 element 近重复
        let elementShifted = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 601, y: 401, width: 199, height: 100),
            kind: .element
        )
        // 高度少 2pt：四边差 = 2pt → 仍属近重复
        let elementSquashed = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 600, y: 400, width: 200, height: 98),
            kind: .element
        )

        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [element, elementShifted, elementSquashed, outerContainer],
            windowCandidate: nil
        )
        try expectEqual(stack.candidates.count, 2, "近重复合并后候选数")
        try expectEqual(stack.candidates[0].kind, .element, "面积小者排前")
        try expectEqual(stack.candidates[1].kind, .container, "面积大者排后")
        try expectTrue(
            area(stack.candidates[0].rectGlobal) < area(stack.candidates[1].rectGlobal),
            "面积升序"
        )
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .element, "默认落在更具体的元素")

        // 四边差恰好 4pt（不满足 < 4）但 IoU ≈ 0.96 > 0.94 → 仍合并
        let bigBase = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 400, y: 400, width: 600, height: 300),
            kind: .container
        )
        let bigShifted = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 404, y: 404, width: 600, height: 300),
            kind: .container
        )
        let iouStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [bigBase, bigShifted],
            windowCandidate: nil
        )
        try expectEqual(iouStack.candidates.count, 1, "IoU > 0.94 合并（四边差 4pt 不算）")

        // 面积相等时按 kind 优先级（textLine = 0 在 element = 2 之前）
        let textLine = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 690, y: 440, width: 20, height: 100),
            kind: .textLine
        )
        let sameAreaElement = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 600, y: 440, width: 100, height: 20),
            kind: .element
        )
        let tieStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [sameAreaElement, textLine],
            windowCandidate: nil
        )
        try expectEqual(tieStack.candidates.count, 2, "同面积不误合并")
        try expectEqual(tieStack.candidates[0].kind, .textLine, "同面积按 kind 升序（文本行在前）")
        try expectEqual(tieStack.candidates[1].kind, .element, "同面积按 kind 升序（控件在后）")

        // 同位置的文本行不能盖掉表格/列表项（否则整张表被它里面那行字吃掉优先级）
        let table = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 400, y: 300, width: 600, height: 300),
            kind: .table
        )
        let coveringText = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 401, y: 301, width: 598, height: 298),
            kind: .textLine
        )
        let tableStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [coveringText, table],
            windowCandidate: nil
        )
        try expectEqual(tableStack.candidates.count, 1, "同位置文本行与表格合并为一条")
        try expectEqual(tableStack.candidates[0].kind, .table, "合并后保留表格")

        // 等大 container 与 window 合并时保留 window（保住 windowID / ownerName）
        let window = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 200, y: 200, width: 700, height: 500),
            kind: .window,
            windowID: 99,
            ownerName: "Notes",
            title: "备忘录"
        )
        let sameContainer = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 200, y: 200, width: 700, height: 500),
            kind: .container
        )
        let windowStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [sameContainer],
            windowCandidate: window
        )
        try expectEqual(windowStack.candidates.count, 1, "等大 window/container 合并为一条")
        try expectEqual(windowStack.candidates[0].kind, .window, "合并后保留 window")
        try expectEqual(windowStack.candidates[0].windowID, 99, "合并后 windowID 保留")
    }

    // MARK: - 场景 A：表格绝对优先

    static func test4TablePriority() throws {
        print("[TestSmartSelection] 场景A: 表格内单行字/列表项/控件都在，默认仍选整张表")

        let textLine = CGRect(x: 640, y: 440, width: 120, height: 20)  // 2400
        let axCandidates: [SmartSelectionCandidate] = [
            SmartSelectionCandidate(rectGlobal: CGRect(x: 600, y: 430, width: 200, height: 40), kind: .element),
            SmartSelectionCandidate(rectGlobal: CGRect(x: 500, y: 420, width: 400, height: 60), kind: .listItem),
            SmartSelectionCandidate(rectGlobal: CGRect(x: 400, y: 300, width: 600, height: 300), kind: .table),
        ]

        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: axCandidates,
            windowCandidate: nil
        )
        try expectEqual(stack.candidates.count, 4, "表格场景候选数")
        try expectEqual(stack.candidates[0].kind, .textLine, "最具体的单行文本仍排最前")
        try expectEqual(stack.candidates.last?.kind, .table, "表格是最大的一块（栈尾）")
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .table, "默认选中整张表格")
        try expectEqual(
            stack.candidates[stack.defaultIndex].rectGlobal,
            CGRect(x: 400, y: 300, width: 600, height: 300),
            "默认矩形就是整张表格"
        )
        // 契约方法（无 screenHeight）与 buildStack 内口径一致
        try expectEqual(
            SmartCandidateResolver.decideDefaultIndex(
                stack.candidates,
                referenceArea: screenArea,
                atGlobalPoint: point
            ),
            stack.defaultIndex,
            "decideDefaultIndex(_:referenceArea:atGlobalPoint:) 与 buildStack 一致"
        )

        // 多张表：选面积最小（最具体）的那张
        let twoTables = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: axCandidates + [
                SmartSelectionCandidate(rectGlobal: CGRect(x: 300, y: 200, width: 800, height: 500), kind: .table)
            ],
            windowCandidate: nil
        )
        try expectEqual(twoTables.candidates[twoTables.defaultIndex].kind, .table, "多表仍选表格")
        try expectEqual(
            area(twoTables.candidates[twoTables.defaultIndex].rectGlobal),
            600 * 300,
            "多表时选面积最小的那张"
        )

        // 贴满整页的「伪表格」（> 0.90 参考面积）不参与表格绝对优先 → 回落单行文本
        let pageWideTable = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: CGRect(x: 50, y: 20, width: 1380, height: 870), kind: .table)
            ],
            windowCandidate: nil
        )
        try expectEqual(pageWideTable.candidates[pageWideTable.defaultIndex].kind, .textLine,
                        "整页伪表格不抢焦点，回落单行文本")
    }

    // MARK: - 场景 B：无表格时列表项优先

    static func test5ListItemPriority() throws {
        print("[TestSmartSelection] 场景B: 无表格时无序列表的每一行优先")

        let textLine = CGRect(x: 660, y: 445, width: 80, height: 18)  // 1440
        let axCandidates: [SmartSelectionCandidate] = [
            SmartSelectionCandidate(rectGlobal: CGRect(x: 620, y: 420, width: 160, height: 60), kind: .element),   // 9600
            SmartSelectionCandidate(rectGlobal: CGRect(x: 500, y: 400, width: 600, height: 60), kind: .listItem),  // 36000
            SmartSelectionCandidate(rectGlobal: CGRect(x: 400, y: 300, width: 800, height: 400), kind: .container), // 320000
        ]
        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: axCandidates,
            windowCandidate: nil
        )
        try expectEqual(stack.candidates.count, 4, "列表场景候选数")
        try expectEqual(stack.candidates[0].kind, .textLine, "单行文本仍在栈首（滚轮可切回）")
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .listItem, "默认选中列表项")
        try expectEqual(
            stack.candidates[stack.defaultIndex].rectGlobal,
            CGRect(x: 500, y: 400, width: 600, height: 60),
            "默认矩形就是那一行列表项"
        )

        // 整块列表面板（高度 > 屏幕 35%）不该被当成单个列表行 → 回落容器
        let giantListPanel = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: CGRect(x: 500, y: 100, width: 600, height: 400), kind: .listItem),
                SmartSelectionCandidate(rectGlobal: CGRect(x: 400, y: 80, width: 800, height: 700), kind: .container),
            ],
            windowCandidate: nil
        )
        try expectEqual(giantListPanel.candidates[giantListPanel.defaultIndex].kind, .container,
                        "过高的列表行被剔除，默认回落非背景容器")
    }

    // MARK: - 场景 C：网页/GUI 大块卡片与大控件优先

    static func test6BigBlockPriority() throws {
        print("[TestSmartSelection] 场景C: 大卡片容器 / 大块控件优先于单行碎字")

        let textLine = CGRect(x: 660, y: 445, width: 80, height: 18)  // 1440
        let card = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 400, y: 300, width: 800, height: 400),  // 320000
            kind: .container
        )

        // C1: 卡片容器 + 单行文本 → 默认选中大卡片
        let cardOnly = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [card],
            windowCandidate: nil
        )
        try expectEqual(cardOnly.candidates[cardOnly.defaultIndex].kind, .container, "默认选中大卡片")
        try expectEqual(cardOnly.candidates[0].kind, .textLine, "单行文本仍在栈中")

        // C2: 卡片容器 + 大块图片控件（≥ 2400）→ 默认选中控件（更具体的大块）
        let image = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 600, y: 350, width: 400, height: 300),  // 120000
            kind: .element
        )
        let withImage = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [card, image],
            windowCandidate: nil
        )
        try expectEqual(withImage.candidates[withImage.defaultIndex].kind, .element, "默认选中大块控件")
        try expectEqual(
            withImage.candidates[withImage.defaultIndex].rectGlobal,
            CGRect(x: 600, y: 350, width: 400, height: 300),
            "默认矩形就是那张大图"
        )

        // C3: 只有碎小控件（矮于 28pt）→ 大块闸门不认，但「任意控件」仍优先于单行文本
        let tinyControl = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: CGRect(x: 640, y: 442, width: 120, height: 24), kind: .element)
            ],
            windowCandidate: nil
        )
        try expectEqual(tinyControl.candidates[tinyControl.defaultIndex].kind, .element,
                        "碎小控件仍算控件（优先于单行文本）")
        try expectEqual(tinyControl.candidates[0].kind, .textLine, "单行文本仍在栈首可滚轮切回")
    }

    // MARK: - 场景 D：背景巨壳 → 回落单行文本

    static func test7BackgroundShellTextFallback() throws {
        print("[TestSmartSelection] 场景D: 整页背景壳（> 78% 窗口）+ 单行文本 → 回落文本行")

        let textLine = CGRect(x: 660, y: 445, width: 80, height: 18)
        let bigWindow = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 100, y: 50, width: 1300, height: 850),  // 1105000
            kind: .window,
            windowID: 11,
            ownerName: "Safari",
            title: "文档"
        )
        // 整页 AXWebArea 巨壳：> 0.78 * 窗口面积（且与窗口不完全重叠，否则会被去重合并）
        let shell = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 150, y: 80, width: 1200, height: 790),  // 948000 > 0.78*1105000
            kind: .container
        )
        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [shell],
            windowCandidate: bigWindow
        )
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .textLine, "默认落回单行文本")
        try expectEqual(stack.candidates.last?.kind, .window, "大窗仍在栈尾可滚轮切出")
        try expectTrue(stack.candidates.contains { $0.kind == .container }, "背景壳仍在栈中")

        // 普通窗口（非满屏）：巨壳同样按窗口面积判背景，不抢焦点
        let normalWindow = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 300, y: 150, width: 800, height: 600),  // 480000
            kind: .window,
            windowID: 12,
            ownerName: "Chrome",
            title: "文章"
        )
        let shellInWindow = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 330, y: 180, width: 740, height: 540),  // 399600 > 0.78*480000
            kind: .container
        )
        let windowStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [shellInWindow],
            windowCandidate: normalWindow
        )
        try expectEqual(windowStack.candidates[windowStack.defaultIndex].kind, .textLine,
                        "窗口内的背景壳仍不抢焦点")
    }

    // MARK: - 场景 E：Vision 大块矩形压制碎文本行

    static func test8VisionBigRectBeatsTextLine() throws {
        print("[TestSmartSelection] 场景E: AX 只有巨壳时，Vision 大块矩形（div 表格框）优先")

        let textLine = CGRect(x: 660, y: 445, width: 80, height: 18)
        // AX 只给出整页巨壳（Electron / 自定义 div 表格的常态）
        let shell = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 100, y: 50, width: 1300, height: 850),
            kind: .container
        )
        // Vision 抓到的 div 表格框
        let divTable = CGRect(x: 500, y: 350, width: 420, height: 220)  // 92400

        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [divTable],
            axCandidates: [shell],
            windowCandidate: nil
        )
        try expectEqual(stack.candidates.count, 3, "巨壳 + 视觉大矩形 + 文本行")
        try expectEqual(stack.candidates[0].kind, .textLine, "文本行仍是最具体的一层")
        try expectTrue(stack.candidates.contains { $0.kind == .visualRect }, "视觉大块矩形已纳入候选")
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .visualRect, "默认选中视觉大块矩形")
        try expectEqual(
            stack.candidates[stack.defaultIndex].rectGlobal,
            divTable,
            "默认矩形就是那块 div 表格框"
        )

        // AX 已给出同样贴合的块（面积接近视觉矩形）→ 让位给 AX 的精确元素
        let card = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 510, y: 360, width: 400, height: 200),  // 80000 ≤ 92400*1.2
            kind: .container
        )
        let withCard = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [divTable],
            axCandidates: [card],
            windowCandidate: nil
        )
        try expectEqual(withCard.candidates[withCard.defaultIndex].kind, .container,
                        "AX 已细化时默认落 AX 容器")
    }

    // MARK: - 场景 5：裁剪 + 噪点过滤

    static func test9ClippingAndNoiseFiltering() throws {
        print("[TestSmartSelection] 场景9: 超出 screenFrame 裁剪 + <12pt 噪点过滤")

        // 文本行左越界：-100..800 → 裁到 0..800
        let clippedByScreen = SmartCandidateResolver.buildStack(
            atGlobalPoint: CGPoint(x: 100, y: 450),
            screenFrame: screen,
            textLines: [CGRect(x: -100, y: 440, width: 900, height: 20)],
            visualRects: [],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectEqual(clippedByScreen.candidates.count, 1, "越界文本行保留一条")
        try expectEqual(
            clippedByScreen.candidates[0].rectGlobal,
            CGRect(x: 0, y: 440, width: 800, height: 20),
            "文本行按 screenFrame 裁剪"
        )

        // 亚 12pt 噪点（指示灯/分隔线）全部丢弃
        let noise = SmartCandidateResolver.buildStack(
            atGlobalPoint: CGPoint(x: 100, y: 450),
            screenFrame: screen,
            textLines: [
                CGRect(x: 95, y: 445, width: 8, height: 8),
                CGRect(x: 0, y: 450, width: 600, height: 6),
            ],
            visualRects: [CGRect(x: 90, y: 440, width: 20, height: 10)],
            axCandidates: [SmartSelectionCandidate(rectGlobal: CGRect(x: 92, y: 448, width: 4, height: 4), kind: .element)],
            windowCandidate: nil
        )
        try expectTrue(noise.isEmpty, "全部小于 12pt → empty")

        // 子元素先按窗口域裁剪（AX 元素超出窗口右边界）
        let window = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 200, y: 200, width: 600, height: 400),
            kind: .window,
            windowID: 5
        )
        let overflowingElement = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 600, y: 300, width: 400, height: 200),
            kind: .element
        )
        let clippedByWindow = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [overflowingElement],
            windowCandidate: window
        )
        try expectEqual(clippedByWindow.candidates.count, 2, "窗口裁剪后候选数")
        try expectEqual(
            clippedByWindow.candidates[0].rectGlobal,
            CGRect(x: 600, y: 300, width: 200, height: 200),
            "子候选按窗口域裁剪"
        )
        try expectEqual(clippedByWindow.candidates[1].kind, .window, "窗口候选排最后")

        // 光标不在框内（超出 1pt 容差）一律不纳入
        let offPoint = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [CGRect(x: 0, y: 0, width: 200, height: 100)],
            visualRects: [],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectTrue(offPoint.isEmpty, "光标不在任何框内 → empty")
    }

    // MARK: - 场景 10：视觉矩形兜底 / AX 结构化时抑制

    static func test10VisualRectsFallback() throws {
        print("[TestSmartSelection] 场景10: 无 AX 时视觉矩形兜底 / AX 已结构化时抑制视觉噪点")

        let fallback = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [
                CGRect(x: 600, y: 400, width: 200, height: 100),  // 20000
                CGRect(x: 500, y: 300, width: 400, height: 300),  // 120000
            ],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectEqual(fallback.candidates.count, 2, "无 AX 时视觉矩形全部纳入")
        try expectEqual(fallback.candidates[0].kind, .visualRect, "视觉矩形 kind")
        try expectEqual(fallback.candidates[0].rectGlobal.width, 200, "视觉矩形面积升序（小的在前）")
        try expectEqual(fallback.candidates[fallback.defaultIndex].rectGlobal.width, 400,
                        "默认选最大的那块视觉矩形（大块优先）")

        // AX 已给出表格 → 视觉矩形闸门收紧（0.65 倍最深 AX 元素）
        let table = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 400, y: 300, width: 600, height: 300),  // 180000
            kind: .table
        )
        let withTable = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [
                CGRect(x: 450, y: 350, width: 520, height: 240),  // 124800 ≥ 180000*0.65 → 抑制
                CGRect(x: 640, y: 430, width: 100, height: 40),   // 4000 < 117000 → 保留
            ],
            axCandidates: [table],
            windowCandidate: nil
        )
        try expectEqual(withTable.candidates.count, 2, "表格在场时只保留明显更小的视觉矩形")
        try expectEqual(withTable.candidates[0].kind, .visualRect, "更小的视觉矩形排前")
        try expectEqual(withTable.candidates[withTable.defaultIndex].kind, .table, "默认仍是表格")

        // AX 无表格/列表项（只有精确控件）→ 闸门放宽到 0.72，但碎小控件不抢默认焦点
        let element = SmartSelectionCandidate(
            rectGlobal: CGRect(x: 600, y: 400, width: 200, height: 100),  // 20000
            kind: .element
        )
        let withAX = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [],
            visualRects: [
                CGRect(x: 450, y: 250, width: 500, height: 400),  // 200000 ≥ 20000*0.72 → 抑制
                CGRect(x: 640, y: 430, width: 100, height: 40),   // 4000 < 14400 → 保留
            ],
            axCandidates: [element],
            windowCandidate: nil
        )
        try expectEqual(withAX.candidates.count, 2, "AX 控件在场时只保留明显更小的视觉矩形")
        try expectEqual(withAX.candidates[0].kind, .visualRect, "更小的视觉矩形排前")
        try expectEqual(withAX.candidates[withAX.defaultIndex].kind, .element, "默认选大块控件")

        // 无 AX 权限时视觉矩形 + 文本行：视觉大块优先（网页/图片里的表格框）
        let noAXPermission = SmartCandidateResolver.buildStack(
            atGlobalPoint: point,
            screenFrame: screen,
            textLines: [CGRect(x: 660, y: 445, width: 80, height: 18)],
            visualRects: [CGRect(x: 500, y: 350, width: 420, height: 220)],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectEqual(noAXPermission.candidates[noAXPermission.defaultIndex].kind, .visualRect,
                        "无 AX 时视觉大块矩形优先于单行文本")
    }

    // MARK: - 场景 F：表格四级识别（单元格 / 行 / 列 / 整表）

    static func test11TableCellHierarchy() throws {
        print("[TestSmartSelection] 场景F: 表格内部点击 → 默认当前单元格，滚轮逐级 单元格→行→列→表")

        // 表格 (400,300,600,300)；3 列 × 4 行；目标格 (600,375,200,75)
        let tableRect = CGRect(x: 400, y: 300, width: 600, height: 300)
        let cellRect = CGRect(x: 600, y: 375, width: 200, height: 75)
        let rowRect = CGRect(x: 400, y: 375, width: 600, height: 75)
        let columnRect = CGRect(x: 600, y: 300, width: 200, height: 300)
        let textLine = CGRect(x: 640, y: 400, width: 120, height: 20)
        // 距表格四边都 > 8pt 的内部落点
        let interior = CGPoint(x: 700, y: 410)

        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: interior,
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: cellRect, kind: .tableCell),
                SmartSelectionCandidate(rectGlobal: rowRect, kind: .tableRow),
                SmartSelectionCandidate(rectGlobal: columnRect, kind: .tableColumn),
                SmartSelectionCandidate(rectGlobal: tableRect, kind: .table),
            ],
            windowCandidate: nil
        )

        try expectEqual(stack.candidates.count, 5, "表格四级场景候选数")
        try expectEqual(stack.candidates[0].kind, .textLine, "文本行仍是最具体的一层")
        // 面积升序：2400 < 15000 < 45000 < 60000 < 180000
        try expectEqual(stack.candidates[1].kind, .tableCell, "第 2 层是单元格")
        try expectEqual(stack.candidates[2].kind, .tableRow, "第 3 层是整行")
        try expectEqual(stack.candidates[3].kind, .tableColumn, "第 4 层是整列")
        try expectEqual(stack.candidates[4].kind, .table, "第 5 层是整张表格")
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .tableCell, "默认选中当前单元格")
        try expectEqual(stack.candidates[stack.defaultIndex].rectGlobal, cellRect, "默认矩形就是那个单元格")
        try expectEqual(
            SmartCandidateResolver.decideDefaultIndex(
                stack.candidates,
                referenceArea: screenArea,
                atGlobalPoint: interior
            ),
            stack.defaultIndex,
            "decideDefaultIndex 与 buildStack 一致（单元格）"
        )

        // 换一个单元格的落点 → 默认逐格跳变（单元格内部的碎文本行不抢焦点）
        let otherCell = CGRect(x: 800, y: 450, width: 200, height: 75)
        let otherPoint = CGPoint(x: 900, y: 480)
        let otherStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: otherPoint,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: cellRect, kind: .tableCell),
                SmartSelectionCandidate(rectGlobal: otherCell, kind: .tableCell),
                SmartSelectionCandidate(rectGlobal: tableRect, kind: .table),
            ],
            windowCandidate: nil
        )
        try expectEqual(otherStack.candidates[otherStack.defaultIndex].rectGlobal, otherCell,
                        "换单元格落点默认跟着逐格跳变")

        // 行与列面积恰好相等时两者都留在栈里（几何不重叠、IoU 很低，不会被误合并）
        let wideRow = CGRect(x: 400, y: 300, width: 600, height: 100)  // 60000
        let tallColumn = CGRect(x: 400, y: 300, width: 200, height: 300)  // 60000
        let tieStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: CGPoint(x: 500, y: 350),
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: wideRow, kind: .tableRow),
                SmartSelectionCandidate(rectGlobal: tallColumn, kind: .tableColumn),
            ],
            windowCandidate: nil
        )
        try expectEqual(tieStack.candidates.count, 2, "等面积行/列各自保留")
        try expectTrue(tieStack.candidates.contains { $0.kind == .tableRow }, "等面积行在栈中")
        try expectTrue(tieStack.candidates.contains { $0.kind == .tableColumn }, "等面积列在栈中")

        // 枚举契约（层级名 / rawValue）
        try expectEqual(SmartCandidateKind.textLine.rawValue, 0, "rawValue 契约：textLine = 0")
        try expectEqual(SmartCandidateKind.tableCell.rawValue, 1, "rawValue 契约：tableCell = 1")
        try expectEqual(SmartCandidateKind.listItem.rawValue, 2, "rawValue 契约：listItem = 2")
        try expectEqual(SmartCandidateKind.tableRow.rawValue, 3, "rawValue 契约：tableRow = 3")
        try expectEqual(SmartCandidateKind.tableColumn.rawValue, 4, "rawValue 契约：tableColumn = 4")
        try expectEqual(SmartCandidateKind.element.rawValue, 5, "rawValue 契约：element = 5")
        try expectEqual(SmartCandidateKind.table.rawValue, 6, "rawValue 契约：table = 6")
        try expectEqual(SmartCandidateKind.container.rawValue, 7, "rawValue 契约：container = 7")
        try expectEqual(SmartCandidateKind.visualRect.rawValue, 8, "rawValue 契约：visualRect = 8")
        try expectEqual(SmartCandidateKind.window.rawValue, 9, "rawValue 契约：window = 9")
        try expectEqual(SmartCandidateKind.display.rawValue, 10, "rawValue 契约：display = 10")
        try expectEqual(SmartCandidateKind.tableCell.displayName, "单元格", "单元格层级名")
        try expectEqual(SmartCandidateKind.tableRow.displayName, "表格行", "表格行层级名")
        try expectEqual(SmartCandidateKind.tableColumn.displayName, "表格列", "表格列层级名")
        try expectEqual(SmartCandidateKind.table.displayName, "表格", "表格层级名")
    }

    // MARK: - 场景 G：贴表格外边缘 → 一键整表

    static func test12TableOuterEdgeSelectsWholeTable() throws {
        print("[TestSmartSelection] 场景G: 距表格外边缘 3pt → 默认整张表格")

        let tableRect = CGRect(x: 400, y: 300, width: 600, height: 300)  // 顶边 y=600，左边 x=400
        let topLeftCell = CGRect(x: 400, y: 525, width: 200, height: 75)
        let leftMidCell = CGRect(x: 400, y: 375, width: 200, height: 75)

        // 距顶边 3pt + 距左边 3pt
        let nearTopLeft = CGPoint(x: 403, y: 597)
        let topStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: nearTopLeft,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: topLeftCell, kind: .tableCell),
                SmartSelectionCandidate(rectGlobal: tableRect, kind: .table),
            ],
            windowCandidate: nil
        )
        try expectEqual(topStack.candidates.count, 2, "外边缘场景候选数（单元格 + 整表）")
        try expectEqual(topStack.candidates[topStack.defaultIndex].kind, .table, "贴顶边 → 默认整张表格")
        try expectEqual(topStack.candidates[topStack.defaultIndex].rectGlobal, tableRect, "默认矩形就是整张表格")

        // 距左边 3pt（垂直居中处）
        let nearLeft = CGPoint(x: 403, y: 430)
        let leftStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: nearLeft,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: leftMidCell, kind: .tableCell),
                SmartSelectionCandidate(rectGlobal: tableRect, kind: .table),
            ],
            windowCandidate: nil
        )
        try expectEqual(leftStack.candidates[leftStack.defaultIndex].kind, .table, "贴左边 → 默认整张表格")

        // 反之：离开边缘足够远（> 8pt）就回到单元格粒度
        let innerPoint = CGPoint(x: 500, y: 430)
        let innerStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: innerPoint,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: leftMidCell, kind: .tableCell),
                SmartSelectionCandidate(rectGlobal: tableRect, kind: .table),
            ],
            windowCandidate: nil
        )
        try expectEqual(innerStack.candidates[innerStack.defaultIndex].kind, .tableCell,
                        "离边缘 > 8pt → 回到单元格")
    }

    // MARK: - 场景 H：无竖线表格 → 整行

    static func test13RowOnlyTableSelectsRow() throws {
        print("[TestSmartSelection] 场景H: 无竖线表格（只有行）→ 默认整行")

        let tableRect = CGRect(x: 400, y: 300, width: 600, height: 300)
        let rowRect = CGRect(x: 400, y: 375, width: 600, height: 75)
        let textLine = CGRect(x: 640, y: 400, width: 120, height: 20)

        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: CGPoint(x: 700, y: 410),
            screenFrame: screen,
            textLines: [textLine],
            visualRects: [],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: rowRect, kind: .tableRow),
                SmartSelectionCandidate(rectGlobal: tableRect, kind: .table),
            ],
            windowCandidate: nil
        )
        try expectEqual(stack.candidates.count, 3, "无竖线表格候选数")
        try expectEqual(stack.candidates[0].kind, .textLine, "文本行仍在栈首")
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .tableRow, "表格内部默认选中整行")
        try expectEqual(stack.candidates[stack.defaultIndex].rectGlobal, rowRect, "默认矩形就是那一行")
        try expectEqual(stack.candidates.last?.kind, .table, "整表仍在栈尾（滚轮可切到整表）")
    }

    // MARK: - 场景 I：视觉表格 visualTables 兜底（无 AX）

    static func test14VisualTablesFallback() throws {
        print("[TestSmartSelection] 场景I: 无 AX 时视觉表格补齐 单元格/行/列/整表")

        let tableRect = CGRect(x: 400, y: 300, width: 600, height: 300)
        let topLeftCell = CGRect(x: 400, y: 525, width: 200, height: 75)
        let midCell = CGRect(x: 600, y: 375, width: 200, height: 75)
        let topRow = CGRect(x: 400, y: 525, width: 600, height: 75)
        let midRow = CGRect(x: 400, y: 375, width: 600, height: 75)
        let leftColumn = CGRect(x: 400, y: 300, width: 200, height: 300)
        let midColumn = CGRect(x: 600, y: 300, width: 200, height: 300)

        let visualTable = DetectedVisualTable(
            tableRect: tableRect,
            rowRects: [topRow, midRow],
            columnRects: [leftColumn, midColumn],
            cellRects: [topLeftCell, midCell]
        )

        // 表格内部落点 → 四级结构齐全，默认落单元格
        let interior = CGPoint(x: 700, y: 410)
        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: interior,
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            visualTables: [visualTable],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectEqual(stack.candidates.count, 4, "视觉表格补齐四级候选")
        try expectTrue(stack.candidates.contains { $0.kind == .tableCell }, "可产出单元格")
        try expectTrue(stack.candidates.contains { $0.kind == .tableRow }, "可产出表格行")
        try expectTrue(stack.candidates.contains { $0.kind == .tableColumn }, "可产出表格列")
        try expectTrue(stack.candidates.contains { $0.kind == .table }, "可产出整表")
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .tableCell, "表格内部默认单元格")
        try expectEqual(stack.candidates[stack.defaultIndex].rectGlobal, midCell, "默认矩形就是那个单元格")

        // 贴外边缘（距顶边 3pt / 左边 3pt）→ 默认整表
        let edgeStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: CGPoint(x: 403, y: 597),
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            visualTables: [visualTable],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectEqual(edgeStack.candidates[edgeStack.defaultIndex].kind, .table, "贴边缘默认整表")
        try expectEqual(edgeStack.candidates[edgeStack.defaultIndex].rectGlobal, tableRect,
                        "整表矩形来自 visualTable.tableRect")

        // 落点不在表格内 → 视觉表格不产生任何候选
        let outsideStack = SmartCandidateResolver.buildStack(
            atGlobalPoint: CGPoint(x: 1200, y: 200),
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            visualTables: [visualTable],
            axCandidates: [],
            windowCandidate: nil
        )
        try expectTrue(outsideStack.isEmpty, "落点不在表格内 → 视觉表格不产出候选")
    }

    // MARK: - 场景 J：AX 已有表格粒度 → 不融合视觉表格

    static func test15AXGranularitySuppressesVisualTables() throws {
        print("[TestSmartSelection] 场景J: AX 已给出单元格 → 视觉表格不参与融合")

        let tableRect = CGRect(x: 400, y: 300, width: 600, height: 300)
        let axCell = CGRect(x: 600, y: 375, width: 200, height: 75)
        let visualTable = DetectedVisualTable(
            tableRect: tableRect,
            rowRects: [CGRect(x: 400, y: 375, width: 600, height: 75)],
            columnRects: [CGRect(x: 600, y: 300, width: 200, height: 300)],
            cellRects: [axCell]
        )

        let stack = SmartCandidateResolver.buildStack(
            atGlobalPoint: CGPoint(x: 700, y: 410),
            screenFrame: screen,
            textLines: [],
            visualRects: [],
            visualTables: [visualTable],
            axCandidates: [
                SmartSelectionCandidate(rectGlobal: axCell, kind: .tableCell),
                SmartSelectionCandidate(rectGlobal: tableRect, kind: .table),
            ],
            windowCandidate: nil
        )
        try expectEqual(stack.candidates.count, 2, "AX 已细化 → 视觉表格不追加候选")
        try expectTrue(!stack.candidates.contains { $0.kind == .tableRow }, "不应凭空多出视觉表格行")
        try expectTrue(!stack.candidates.contains { $0.kind == .tableColumn }, "不应凭空多出视觉表格列")
        try expectEqual(stack.candidates[stack.defaultIndex].kind, .tableCell, "默认仍是 AX 的单元格")
    }

    // MARK: - 断言工具

    enum Failure: Error {
        case message(String)
    }

    static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    static func expectTrue(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.message("\(label): 期望 true，实际 false") }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else {
            throw Failure.message("\(label): 期望 \(expected)，实际 \(actual)")
        }
    }
}
