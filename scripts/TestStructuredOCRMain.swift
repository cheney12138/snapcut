import CoreGraphics
import Foundation

/// structured OCR 文档解析真实验证入口（纯 Core，不依赖 App / Vision / AppKit）。
/// 由 scripts/test-structured-ocr.sh 编译运行：StructuredOCR.swift + 本文件。
///
/// 9 个场景全部直接喂带坐标的 `OCRPositionedBlock`（等价于 Vision 输出的归一化包围盒），
/// 断言解析出的文档块序列、列表层级 / 序号、表格切片、三种渲染输出与二维码安全校验。
@main
struct TestStructuredOCRMain {
    static func main() {
        do {
            try test1SingleShortText()
            try test2SoftWrapAndBlankLine()
            try test3ShortTailAndIndent()
            try test4Headings()
            try test5BulletList()
            try test6OrderedList()
            try test7PureTableBackwardCompat()
            try test8MixedDocument()
            try test9RendersAndQR()
            try test10NoSpaceCJKListAndMixedNesting()
            print("[TestStructuredOCR] ALL PASS ✅")
        } catch {
            print("[TestStructuredOCR] FAILED ❌: \(error)")
            exit(1)
        }
    }

    // MARK: - 场景 1：单行 / 单段普通短文，零误判

    static func test1SingleShortText() throws {
        print("[TestStructuredOCR] 场景1: 单行短文零误判 + 软换行单段不算富结构")

        let single = [blk("今天天气不错，适合出门散步。", x: 0.08, y: 0.10, w: 0.55)]
        let doc = StructuredOCRFormatter.parseDocument(from: single)
        try expectEqual(doc.blocks.count, 1, "单行短文块数")
        try expectBlock(doc.blocks.first, .paragraph(text: "今天天气不错，适合出门散步。"), "单行短文块")
        try expectFalse(doc.hasRichStructure, "单段短文 hasRichStructure")
        try expectFalse(doc.hasTable, "单段短文 hasTable")
        try expectTrue(doc.primaryTableDimensions == nil, "单段短文无表格维度")
        try expectTrue(
            StructuredOCRFormatter.detectMarkdownTable(from: single) == nil,
            "单行短文表格检测零误判"
        )

        let writhed = [
            blk("第一行内容写到一半，", x: 0.08, y: 0.10, w: 0.30),
            blk("接着写第二行内容。", x: 0.08, y: 0.122, w: 0.32),
        ]
        let doc2 = StructuredOCRFormatter.parseDocument(from: writhed)
        try expectEqual(doc2.blocks.count, 1, "软换行合并单段块数")
        try expectBlock(
            doc2.blocks.first,
            .paragraph(text: "第一行内容写到一半，接着写第二行内容。"),
            "软换行 CJK 智能拼接"
        )
        try expectFalse(doc2.hasRichStructure, "软换行单段 hasRichStructure")
    }

    // MARK: - 场景 2：软换行合并 + 明显空行拆段

    static func test2SoftWrapAndBlankLine() throws {
        print("[TestStructuredOCR] 场景2: 软换行合并 + 空行拆出 2 个自然段")

        let blocks = [
            blk("第一段第一行内容，", x: 0.08, y: 0.10, w: 0.40),
            blk("接着写第一段第二行。", x: 0.08, y: 0.122, w: 0.40),
            blk("这是第二段的内容。", x: 0.08, y: 0.19, w: 0.42),
        ]
        let doc = StructuredOCRFormatter.parseDocument(from: blocks)
        try expectEqual(doc.blocks.count, 2, "空行拆段块数")
        try expectBlock(doc.blocks[0], .paragraph(text: "第一段第一行内容，接着写第一段第二行。"), "第一段合并")
        try expectBlock(doc.blocks[1], .paragraph(text: "这是第二段的内容。"), "第二段独立")
        try expectTrue(doc.hasRichStructure, "两个自然段算富结构")
    }

    // MARK: - 场景 3：句末短行断段 + 首行缩进断段

    static func test3ShortTailAndIndent() throws {
        print("[TestStructuredOCR] 场景3: 句末短行断段 + 首行缩进断段")

        let blocks = [
            blk("这是第一段的最后一句。", x: 0.08, y: 0.10, w: 0.30),
            blk("第二段开始", x: 0.08, y: 0.122, w: 0.30),
            blk("缩进后的新段落内容。", x: 0.14, y: 0.144, w: 0.40),
        ]
        let doc = StructuredOCRFormatter.parseDocument(from: blocks)
        try expectEqual(doc.blocks.count, 3, "句末短行 + 缩进共 3 段")
        try expectBlock(doc.blocks[0], .paragraph(text: "这是第一段的最后一句。"), "短行断段")
        try expectBlock(doc.blocks[1], .paragraph(text: "第二段开始"), "第二段")
        try expectBlock(doc.blocks[2], .paragraph(text: "缩进后的新段落内容。"), "缩进断段")
    }

    // MARK: - 场景 4：标题 H1 / H2 + 正文层级

    static func test4Headings() throws {
        print("[TestStructuredOCR] 场景4: H1 / H2 字号层级识别")

        let blocks = [
            blk("季度经营分析报告", x: 0.10, y: 0.08, w: 0.40, h: 0.030),
            blk("背景说明", x: 0.10, y: 0.125, w: 0.24, h: 0.024),
            blk("本期整体经营情况稳健，各业务线均实现同比增长，", x: 0.10, y: 0.165, w: 0.70),
            blk("成本端通过精细化运营持续优化，费用率同比下降，", x: 0.10, y: 0.187, w: 0.70),
            blk("后续仍需关注获客成本。", x: 0.10, y: 0.209, w: 0.40),
        ]
        let doc = StructuredOCRFormatter.parseDocument(from: blocks)
        try expectEqual(doc.blocks.count, 3, "标题 + 标题 + 一段正文")
        try expectBlock(doc.blocks[0], .heading(level: 1, text: "季度经营分析报告"), "H1")
        try expectBlock(doc.blocks[1], .heading(level: 2, text: "背景说明"), "H2")
        try expectBlock(
            doc.blocks[2],
            .paragraph(text: "本期整体经营情况稳健，各业务线均实现同比增长，成本端通过精细化运营持续优化，费用率同比下降，后续仍需关注获客成本。"),
            "正文合并"
        )

        let markdown = doc.renderMarkdown()
        try expectTrue(markdown.hasPrefix("# 季度经营分析报告\n\n## 背景说明\n\n"), "Markdown 标题层级")
    }

    // MARK: - 场景 5：无序列表 + 二级缩进 + 悬挂折行

    static func test5BulletList() throws {
        print("[TestStructuredOCR] 场景5: 无序列表多符号 + 二级缩进 + 悬挂折行归并")

        let blocks = [
            blk("• 第一条要点", x: 0.08, y: 0.10, w: 0.30),
            blk("· 第二条要点", x: 0.08, y: 0.125, w: 0.30),
            blk("◦ 子要点说明", x: 0.13, y: 0.15, w: 0.26),
            blk("- 第三条要点", x: 0.08, y: 0.175, w: 0.30),
            blk("继续补充的说明内容", x: 0.105, y: 0.197, w: 0.34),
        ]
        let doc = StructuredOCRFormatter.parseDocument(from: blocks)
        try expectEqual(doc.blocks.count, 1, "连续无序项聚合为 1 个列表")
        guard case let .bulletList(items)? = doc.blocks.first else {
            throw Failure.message("期望 bulletList，实际 \(String(describing: doc.blocks.first))")
        }
        try expectEqual(items.count, 4, "无序列表条目数")
        try expectEqual(items.map(\.level), [0, 0, 1, 0], "无序列表层级")
        try expectEqual(items.map(\.text), ["第一条要点", "第二条要点", "子要点说明", "第三条要点继续补充的说明内容"], "无序列表文本")
        try expectTrue(doc.hasRichStructure, "列表算富结构")

        try expectEqual(
            doc.renderMarkdown(),
            "- 第一条要点\n- 第二条要点\n  - 子要点说明\n- 第三条要点继续补充的说明内容",
            "无序列表 Markdown"
        )
        try expectEqual(
            doc.renderCleanPlainText(),
            "• 第一条要点\n• 第二条要点\n  ◦ 子要点说明\n• 第三条要点继续补充的说明内容",
            "无序列表纯文本"
        )
    }

    // MARK: - 场景 6：有序列表（阿拉伯 + 中文序号）+ 折行归并

    static func test6OrderedList() throws {
        print("[TestStructuredOCR] 场景6: 有序列表序号提取 + 中文序号 + 折行归并")

        let blocks = [
            blk("1. 第一步准备素材", x: 0.08, y: 0.10, w: 0.36),
            blk("2) 第二步执行拍摄", x: 0.08, y: 0.125, w: 0.36),
            blk("3、第三步输出成片", x: 0.08, y: 0.15, w: 0.36),
            blk("补充说明延续同一项", x: 0.11, y: 0.172, w: 0.36),
            blk("（4）二级子项说明", x: 0.13, y: 0.194, w: 0.34),
            blk("一、中文序号第一项", x: 0.08, y: 0.23, w: 0.36),
            blk("二、中文序号第二项", x: 0.08, y: 0.255, w: 0.36),
        ]
        let doc = StructuredOCRFormatter.parseDocument(from: blocks)
        try expectEqual(doc.blocks.count, 2, "两段有序列表")
        guard case let .orderedList(first)? = doc.blocks.first else {
            throw Failure.message("期望 orderedList，实际 \(String(describing: doc.blocks.first))")
        }
        try expectEqual(first.map(\.ordinal), [1, 2, 3, 4], "阿拉伯序号")
        try expectEqual(first.map(\.level), [0, 0, 0, 1], "阿拉伯列表层级（含二级缩进）")
        try expectEqual(first.last?.text, "二级子项说明", "括号码二级子项")
        try expectEqual(first[2].text, "第三步输出成片补充说明延续同一项", "有序项折行归并")

        guard case let .orderedList(second)? = doc.blocks.last else {
            throw Failure.message("期望第二段 orderedList，实际 \(String(describing: doc.blocks.last))")
        }
        try expectEqual(second.map(\.ordinal), [1, 2], "中文序号转换")
        try expectEqual(second.map(\.text), ["中文序号第一项", "中文序号第二项"], "中文序号文本")

        try expectEqual(
            doc.renderMarkdown(),
            "1. 第一步准备素材\n2. 第二步执行拍摄\n3. 第三步输出成片补充说明延续同一项\n  4. 二级子项说明\n\n1. 中文序号第一项\n2. 中文序号第二项",
            "有序列表 Markdown"
        )
    }

    // MARK: - 场景 7：整图纯表格（向后兼容）

    static func test7PureTableBackwardCompat() throws {
        print("[TestStructuredOCR] 场景7: 整图纯表格向后兼容（4×3）")

        let headersRow = ["指标", "本月", "上月"]
        let rows: [[String]] = [
            ["收入", "1200", "980"],
            ["成本", "800", "760"],
            ["毛利", "400", "220"],
        ]
        var blocks: [OCRPositionedBlock] = []
        let columnXs = [0.08, 0.35, 0.62]
        for (rowIndex, row) in ([headersRow] + rows).enumerated() {
            let y = 0.10 + Double(rowIndex) * 0.04
            for (columnIndex, cell) in row.enumerated() {
                blocks.append(blk(cell, x: columnXs[columnIndex], y: y, w: 0.22))
            }
        }

        guard let table = StructuredOCRFormatter.detectMarkdownTable(from: blocks) else {
            throw Failure.message("整图表格检测失败（向后兼容被破坏）")
        }
        try expectEqual(table.rows, 4, "旧路径行数")
        try expectEqual(table.columns, 3, "旧路径列数")

        let doc = StructuredOCRFormatter.parseDocument(from: blocks)
        try expectEqual(doc.blocks.count, 1, "整图表格输出单块")
        try expectTrue(doc.hasTable, "整图表格 hasTable")
        let dimensions = doc.primaryTableDimensions
        try expectEqual(dimensions?.rows, 4, "文档表格行数")
        try expectEqual(dimensions?.columns, 3, "文档表格列数")
        guard case let .table(headers, tableRows)? = doc.blocks.first else {
            throw Failure.message("期望 table 块，实际 \(String(describing: doc.blocks.first))")
        }
        try expectEqual(headers, headersRow, "表头")
        try expectEqual(tableRows, rows, "表体")
        try expectEqual(doc.renderMarkdown(), table.markdown, "文档 Markdown 与旧路径一致")

        let plain = doc.renderCleanPlainText()
        try expectTrue(plain.hasPrefix("指标\t本月\t上月"), "纯文本制表符分列")
        try expectTrue(plain.contains("收入\t1200\t980"), "纯文本数据行")
    }

    // MARK: - 场景 8：混排文档（标题 + 段落 + 局部表格 + 列表）

    static func test8MixedDocument() throws {
        print("[TestStructuredOCR] 场景8: 标题 + 介绍段落 + 3×3 局部表格 + 无序要点")

        var blocks: [OCRPositionedBlock] = [
            blk("月度经营简报", x: 0.08, y: 0.06, w: 0.45, h: 0.030),
            blk("本月整体经营情况稳健，各业务线均有同比增长，成本控制良好。", x: 0.08, y: 0.105, w: 0.82),
        ]
        let columnXs = [0.08, 0.35, 0.62]
        let tableRows = [
            ["指标", "本月", "上月"],
            ["收入", "1200", "980"],
            ["成本", "800", "760"],
        ]
        for (rowIndex, row) in tableRows.enumerated() {
            let y = 0.145 + Double(rowIndex) * 0.03
            for (columnIndex, cell) in row.enumerated() {
                blocks.append(blk(cell, x: columnXs[columnIndex], y: y, w: 0.22))
            }
        }
        blocks.append(blk("• 要点一：收入增长", x: 0.08, y: 0.245, w: 0.36))
        blocks.append(blk("• 要点二：成本下降", x: 0.08, y: 0.27, w: 0.36))

        let doc = StructuredOCRFormatter.parseDocument(from: blocks)
        try expectEqual(doc.blocks.count, 4, "混排文档块数")
        try expectBlock(doc.blocks[0], .heading(level: 1, text: "月度经营简报"), "混排 H1")
        try expectBlock(
            doc.blocks[1],
            .paragraph(text: "本月整体经营情况稳健，各业务线均有同比增长，成本控制良好。"),
            "混排介绍段落"
        )
        guard case let .table(headers, rows) = doc.blocks[2] else {
            throw Failure.message("混排第 3 块应为表格，实际 \(doc.blocks[2])")
        }
        try expectEqual(headers, ["指标", "本月", "上月"], "混排表头")
        try expectEqual(rows, [["收入", "1200", "980"], ["成本", "800", "760"]], "混排表体")
        guard case let .bulletList(items) = doc.blocks[3] else {
            throw Failure.message("混排第 4 块应为列表，实际 \(doc.blocks[3])")
        }
        try expectEqual(items.map(\.text), ["要点一：收入增长", "要点二：成本下降"], "混排要点")

        try expectTrue(doc.hasRichStructure, "混排 hasRichStructure")
        try expectTrue(doc.hasTable, "混排 hasTable")
        try expectEqual(doc.primaryTableDimensions?.rows, 3, "混排表格行数")
        try expectEqual(doc.primaryTableDimensions?.columns, 3, "混排表格列数")

        // 混排局部表格：旧的整图表格检测必须保持 nil（原文不是一张表）
        try expectTrue(
            StructuredOCRFormatter.detectMarkdownTable(from: blocks) == nil,
            "混排文档整图表格检测不误判"
        )
    }

    // MARK: - 场景 9：三种渲染输出 + 二维码零回归

    static func test9RendersAndQR() throws {
        print("[TestStructuredOCR] 场景9: Markdown / HTML / 纯文本渲染 + 转义 + 二维码")

        let doc = OCRDocument(blocks: [
            .heading(level: 1, text: "标题一"),
            .heading(level: 2, text: "小节标题"),
            .paragraph(text: "含 <script>alert(\"x\")</script> & 'quote' 与 | 竖线"),
            .bulletList(items: [
                OCRListItem(text: "一级要点"),
                OCRListItem(text: "二级要点", level: 1),
            ]),
            .orderedList(items: [
                OCRListItem(text: "条目一"),
                OCRListItem(text: "条目二"),
            ]),
            .table(headers: ["列|A", "列B"], rows: [["1", "2"], ["3", "4"]]),
        ])

        // Markdown
        let markdown = doc.renderMarkdown()
        try expectTrue(markdown.contains("# 标题一"), "Markdown H1")
        try expectTrue(markdown.contains("## 小节标题"), "Markdown H2")
        try expectTrue(markdown.contains("- 一级要点\n  - 二级要点"), "Markdown 嵌套列表")
        try expectTrue(markdown.contains("1. 条目一\n2. 条目二"), "Markdown 有序列表顺延")
        try expectTrue(markdown.contains("| 列\\|A | 列B |"), "Markdown 表格转义")
        try expectTrue(markdown.contains("| --- | --- |"), "Markdown 表格分隔行")
        try expectTrue(markdown.contains("| 3 | 4 |"), "Markdown 表格数据行")

        // HTML：严格转义，零注入
        let html = doc.renderHTML()
        try expectTrue(html.contains("<h1>标题一</h1>"), "HTML H1")
        try expectTrue(html.contains("<h2>小节标题</h2>"), "HTML H2")
        try expectTrue(html.contains("<p>含 &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;quote&#39; 与 | 竖线</p>"), "HTML 严格转义")
        try expectFalse(html.contains("<script>"), "HTML 无注入")
        try expectTrue(html.contains("<ul><li>一级要点<ul><li>二级要点</li></ul></li></ul>"), "HTML 嵌套子列表")
        try expectTrue(html.contains("<ol><li>条目一</li><li>条目二</li></ol>"), "HTML 有序列表")
        try expectTrue(html.contains("<table style=\"border-collapse:collapse;\">"), "HTML 表格样式")
        try expectTrue(html.contains("<thead><tr><th style=\"border:1px solid #d0d7de;padding:6px 10px;background:#f6f8fa;text-align:left;\">列|A</th>"), "HTML 表头样式")
        try expectTrue(html.contains("<td style=\"border:1px solid #d0d7de;padding:6px 10px;\">4</td>"), "HTML 单元格样式")

        // 纯文本：表格制表符分列，粘贴 Excel 可直接分列
        let plain = doc.renderCleanPlainText()
        try expectTrue(plain.hasPrefix("标题一\n\n小节标题\n\n"), "纯文本标题")
        try expectTrue(plain.contains("• 一级要点\n  ◦ 二级要点"), "纯文本无序列表符号")
        try expectTrue(plain.contains("1. 条目一\n2. 条目二"), "纯文本有序列表")
        try expectTrue(plain.contains("列|A\t列B\n1\t2\n3\t4"), "纯文本表格制表符")

        // 二维码安全校验零回归
        try expectTrue(StructuredOCRFormatter.makeQRCode(payload: "https://example.com/a").isOpenableURL, "https 可直达")
        try expectTrue(StructuredOCRFormatter.makeQRCode(payload: "mailto:a@b.com").isOpenableURL, "mailto 可直达")
        try expectTrue(StructuredOCRFormatter.makeQRCode(payload: "tel:13800000000").isOpenableURL, "tel 可直达")
        try expectFalse(StructuredOCRFormatter.makeQRCode(payload: "javascript:alert(1)").isOpenableURL, "危险协议被拒")
        try expectFalse(StructuredOCRFormatter.makeQRCode(payload: "随便一段文字").isOpenableURL, "非 URL 被拒")
        try expectFalse(StructuredOCRFormatter.makeQRCode(payload: "https://").isOpenableURL, "空 host 被拒")

        // StructuredOCRResult 向后兼容：不传 document 时行为不变
        let legacy = StructuredOCRResult(
            plainText: "hello",
            qrCodes: [StructuredOCRFormatter.makeQRCode(payload: "https://example.com")],
            markdownTable: "| a |\n| --- |\n| 1 |",
            tableRowCount: 2,
            tableColumnCount: 1
        )
        try expectTrue(legacy.hasAnyContent, "legacy hasAnyContent")
        try expectTrue(legacy.hasRichStructure, "legacy 有表格即富结构")
        try expectTrue(legacy.document == nil, "legacy document 默认为 nil")

        let empty = StructuredOCRResult(
            plainText: "",
            qrCodes: [],
            markdownTable: nil,
            tableRowCount: 0,
            tableColumnCount: 0
        )
        try expectFalse(empty.hasAnyContent, "空结果 hasAnyContent")
        try expectFalse(empty.hasRichStructure, "空结果 hasRichStructure")

        let rich = StructuredOCRResult(
            plainText: "x",
            qrCodes: [],
            markdownTable: nil,
            tableRowCount: 0,
            tableColumnCount: 0,
            document: doc
        )
        try expectTrue(rich.hasRichStructure, "带 document 时以文档为准")
    }

    // MARK: - 场景 10：真实中文无空格列表标记（1.纯Core / •基于）+ 有序下挂无序二级嵌套

    static func test10NoSpaceCJKListAndMixedNesting() throws {
        print("[TestStructuredOCR] 场景10: 中文吞空格列表标记与有序下挂无序嵌套")
        let blocks = [
            blk("核心交付", x: 0.06, y: 0.04, w: 0.20, h: 0.028),
            blk("1.纯Core 结构化文档引擎 — StructuredOCR.swift", x: 0.06, y: 0.09, w: 0.72),
            blk("•基于 Vision 包围盒 0ms 本地识别标题与列表", x: 0.10, y: 0.12, w: 0.72),
            blk("以及混排局部表格，单段零误判。", x: 0.12, y: 0.145, w: 0.55),
            blk("•一份 OCRDocument AST 直接输出多种格式。", x: 0.10, y: 0.175, w: 0.65),
            blk("2. 零 WebView 原生富文本渲染", x: 0.06, y: 0.21, w: 0.35),
            // 模拟行内文件图标造成水平空隙（gap > 0.025），且下一行折行后又带一个图标空隙：绝不能误切为 2×3 假表格
            blk("OCRDocumentRenderer.swift（新", x: 0.46, y: 0.21, w: 0.32),
            blk("建）、", x: 0.08, y: 0.232, w: 0.08),
            blk("OCRResultPanel.swift", x: 0.22, y: 0.232, w: 0.25),
            blk("•直接复用原生 NSTextView 呈现真表格。", x: 0.10, y: 0.262, w: 0.65),
            blk("•仅当识别出结构时出现切换滑块。", x: 0.10, y: 0.290, w: 0.62),
            blk("3.测试与文档", x: 0.06, y: 0.325, w: 0.30),
            blk("•同步更新 CHANGELOG.md。", x: 0.10, y: 0.355, w: 0.45),
        ]
        let doc = StructuredOCRFormatter.parseDocument(from: blocks)
        try expectFalse(doc.hasTable, "行内图标留白折行绝不误判为表格")
        try expectEqual(doc.blocks.count, 7, "标题 + 3 组(有序父项 + 缩进无序子列表)")
        try expectBlock(doc.blocks[0], .heading(level: 1, text: "核心交付"), "标题")
        try expectBlock(
            doc.blocks[1],
            .orderedList(items: [OCRListItem(text: "纯Core 结构化文档引擎 — StructuredOCR.swift", level: 0, ordinal: 1)]),
            "有序父项 1（无空格）"
        )
        try expectBlock(
            doc.blocks[2],
            .bulletList(items: [
                OCRListItem(text: "基于 Vision 包围盒 0ms 本地识别标题与列表以及混排局部表格，单段零误判。", level: 1, ordinal: nil),
                OCRListItem(text: "一份 OCRDocument AST 直接输出多种格式。", level: 1, ordinal: nil),
            ]),
            "有序 1 下的缩进无序子列表"
        )
        try expectBlock(
            doc.blocks[5],
            .orderedList(items: [OCRListItem(text: "测试与文档", level: 0, ordinal: 3)]),
            "有序父项 3（无空格）"
        )
        let md = doc.renderMarkdown()
        try expectTrue(
            md.contains("1. 纯Core 结构化文档引擎 — StructuredOCR.swift\n  - 基于 Vision"),
            "Markdown 父子列表单换行紧贴嵌套"
        )
        let html = doc.renderHTML()
        try expectTrue(
            html.contains("<ol><li>纯Core 结构化文档引擎 — StructuredOCR.swift<ul><li>基于 Vision"),
            "HTML 子列表嵌入父 <li> 内"
        )
        try expectFalse(html.contains("</ul></li></ul>"), "HTML 无多余 </li> 闭合错位")
    }

    // MARK: - 断言工具

    enum Failure: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case let .message(text): return text
            }
        }
    }

    static func expectTrue(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.message("\(label): 期望 true，实际 false") }
    }

    static func expectFalse(_ condition: Bool, _ label: String) throws {
        guard !condition else { throw Failure.message("\(label): 期望 false，实际 true") }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else {
            throw Failure.message("\(label): 期望 \(expected)，实际 \(actual)")
        }
    }

    static func expectBlock(
        _ actual: OCRDocumentBlock?,
        _ expected: OCRDocumentBlock,
        _ label: String
    ) throws {
        guard let actual else { throw Failure.message("\(label): 块缺失（期望 \(expected)）") }
        guard actual == expected else {
            throw Failure.message("\(label): 期望 \(expected)，实际 \(actual)")
        }
    }

    /// 造一块带归一化包围盒的 OCR 文本（默认正文字高 0.018 / 宽 0.6）。
    static func blk(
        _ text: String,
        x: Double,
        y: Double,
        w: Double = 0.6,
        h: Double = 0.018
    ) -> OCRPositionedBlock {
        OCRPositionedBlock(text: text, minX: x, maxX: x + w, minY: y, maxY: y + h)
    }
}
