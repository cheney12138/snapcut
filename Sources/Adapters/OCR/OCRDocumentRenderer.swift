import AppKit

/// OCR 富文本渲染器：把 `OCRDocument` 的语义块渲染成 AppKit 原生 `NSAttributedString`
/// （标题 / 段落 / 悬挂缩进列表 / 原生 NSTextTable 表格），零 WebView。
///
/// 为什么全用原生控件而不是 WebView：
/// - NSTextView 直接承接选中、拖选、⌘C，划选半张表格也能带结构复制；
/// - `NSTextList` / `NSTextTableBlock` 是 AppKit 自己的语义对象，导出 RTF / HTML 时
///   自动生成 `<ul><li>`、`<table><tr><td>` 与 `\listtable`、`\trowd`，
///   粘进飞书 / Notion / Word / 备忘录能还原真表格与真列表；
/// - 玻璃 HUD 上不会出现 WebView 的合成层卡顿与焦点劫持。
///
/// 列表字符串形态严格按 AppKit 自己的约定（实测 HTML 往返验证）：
/// `"\t\(marker)\t\(text)\n"` + `paragraphStyle.textLists` + 两个 NSTextTab，
/// 标记与正文像素级对齐，且导出时 <li> 内不会重复出现标记字符。
@MainActor
enum OCRDocumentRenderer {

    // MARK: - 排版度量（字阶 / 色一律取自 DesignTokens，禁止文件内私设色值）

    @MainActor
    private enum Metrics {
        static let h1Font = NSFont.systemFont(ofSize: 16.5, weight: .semibold)
        static let h2Font = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
        static let bodyFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        static let tableHeaderFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        static let tableFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        static let markdownFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        /// 列表悬挂缩进：一级标记 20pt / 正文 38pt，二级整体再进 18pt
        static let listMarkerIndent: CGFloat = 20
        static let listLevelStep: CGFloat = 18
        static let listTextGap: CGFloat = 18
        static let listLineSpacing: CGFloat = 4
        static let listItemGap: CGFloat = 3.5
        static let listTrailingGap: CGFloat = 8

        static let bodyLineSpacing: CGFloat = 4.5
        static let bodyBlockGap: CGFloat = 8
        static let headingLineSpacing: CGFloat = 3

        /// 表格单元格内衬：左右 8pt、上下 5pt；边框 0.5pt 发丝
        static let cellPadH: CGFloat = 8
        static let cellPadV: CGFloat = 5
        static let cellBorder: CGFloat = 0.5
        static let cellLineSpacing: CGFloat = 2
        static let tableTrailingGap: CGFloat = 8
    }

    // MARK: - 文档主渲染

    static func render(_ document: OCRDocument) -> NSAttributedString {
        let blocks = document.blocks
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let isFirst = index == 0
            let isLast = index == blocks.count - 1
            let followedByNestedList: Bool = {
                guard index + 1 < blocks.count else { return false }
                switch blocks[index + 1] {
                case let .bulletList(items), let .orderedList(items):
                    return (items.first?.level ?? 0) >= 1
                default:
                    return false
                }
            }()
            switch block {
            case let .heading(level, text):
                out.append(heading(level: level, text: text, isFirst: isFirst, isLast: isLast))
            case let .paragraph(text):
                out.append(paragraph(text: text, isLast: isLast))
            case let .bulletList(items):
                out.append(list(items: items, ordered: false, isLast: isLast, tightTail: followedByNestedList))
            case let .orderedList(items):
                out.append(list(items: items, ordered: true, isLast: isLast, tightTail: followedByNestedList))
            case let .table(headers, rows):
                out.append(table(headers: headers, rows: rows, isLast: isLast))
            }
        }
        return out
    }

    /// Markdown 源码视图（等宽字阶，行距 4.5pt，供「Markdown」模式直接显示与编辑）
    static func renderMarkdownSource(_ markdown: String) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = Metrics.bodyLineSpacing
        ps.lineBreakMode = .byWordWrapping
        ps.paragraphSpacing = 0
        return NSAttributedString(string: markdown, attributes: [
            .font: Metrics.markdownFont,
            .foregroundColor: DesignTokens.label1,
            .paragraphStyle: ps,
        ])
    }

    // MARK: - 标题 / 段落

    private static func heading(level: Int, text: String, isFirst: Bool, isLast: Bool) -> NSAttributedString {
        let isH1 = level <= 1
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = Metrics.headingLineSpacing
        ps.lineBreakMode = .byWordWrapping
        // 段前 10 / 8pt，首块不吃段前；段后 4 / 3pt，末块收尾不留白
        ps.paragraphSpacingBefore = isFirst ? 0 : (isH1 ? 10 : 8)
        ps.paragraphSpacing = isLast ? 0 : (isH1 ? 4 : 3)
        return NSAttributedString(string: text + "\n", attributes: [
            .font: isH1 ? Metrics.h1Font : Metrics.h2Font,
            .foregroundColor: DesignTokens.label1,
            .paragraphStyle: ps,
        ])
    }

    private static func paragraph(text: String, isLast: Bool) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = Metrics.bodyLineSpacing
        ps.lineBreakMode = .byWordWrapping
        ps.paragraphSpacingBefore = 0
        ps.paragraphSpacing = isLast ? 0 : Metrics.bodyBlockGap
        return NSAttributedString(string: text + "\n", attributes: [
            .font: Metrics.bodyFont,
            .foregroundColor: DesignTokens.label1,
            .paragraphStyle: ps,
        ])
    }

    // MARK: - 列表（原生 NSTextList：悬挂缩进 + 完整列表语义）

    private static func list(
        items: [OCRListItem],
        ordered: Bool,
        isLast: Bool,
        tightTail: Bool = false
    ) -> NSAttributedString {
        guard !items.isEmpty else { return NSAttributedString() }
        let out = NSMutableAttributedString()

        // 每个嵌套层级一个 NSTextList：语义（RTF / HTML 导出）与标记格式各自独立
        var listsByLevel: [Int: NSTextList] = [:]
        let firstOrdinal = ordered ? (items.first(where: { ($0.ordinal ?? 0) > 0 })?.ordinal ?? 1) : 1

        func list(forLevel level: Int) -> NSTextList {
            if let existing = listsByLevel[level] { return existing }
            let format: NSTextList.MarkerFormat = ordered
                ? .decimal
                : (level == 0 ? .disc : .circle)
            let created = NSTextList(markerFormat: format, options: 0)
            // 有序列表首项序号 > 1（OCR 常只截到列表中段）时让编号从真实序号起算
            if ordered, level == 0, firstOrdinal > 1 {
                created.startingItemNumber = firstOrdinal
            }
            listsByLevel[level] = created
            return created
        }

        for (index, item) in items.enumerated() {
            let level = min(max(item.level, 0), 2)
            let markerIndent = Metrics.listMarkerIndent + CGFloat(level) * Metrics.listLevelStep
            let textIndent = markerIndent + Metrics.listTextGap

            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = Metrics.listLineSpacing
            ps.lineBreakMode = .byWordWrapping
            // 首行从 0 起，靠第一个 tab 落到标记位，第二个 tab 落到正文位 —— 悬挂缩进的标准形态
            ps.firstLineHeadIndent = 0
            ps.headIndent = textIndent
            ps.tabStops = [
                NSTextTab(textAlignment: .left, location: markerIndent),
                NSTextTab(textAlignment: .left, location: textIndent),
            ]
            ps.defaultTabInterval = textIndent
            ps.paragraphSpacingBefore = 0
            ps.paragraphSpacing = index == items.count - 1
                ? (isLast ? 0 : (tightTail ? Metrics.listItemGap : Metrics.listTrailingGap))
                : Metrics.listItemGap
            ps.textLists = (0...level).map { list(forLevel: $0) }

            let marker: String
            if ordered {
                marker = "\(item.ordinal ?? (index + 1))."
            } else {
                marker = level == 0 ? "•" : "◦"
            }

            out.append(NSAttributedString(string: "\t\(marker)\t\(item.text)\n", attributes: [
                .font: Metrics.bodyFont,
                .foregroundColor: DesignTokens.label1,
                .paragraphStyle: ps,
            ]))
        }
        return out
    }

    // MARK: - 表格（原生 NSTextTable：真表格语义，粘出去是 <table>）

    private static func table(headers: [String], rows: [[String]], isLast: Bool) -> NSAttributedString {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0, !(headers.isEmpty && rows.isEmpty) else { return NSAttributedString() }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        var allRows: [(cells: [String], isHeader: Bool)] = []
        if !headers.isEmpty { allRows.append((headers, true)) }
        for row in rows { allRows.append((row, false)) }

        let out = NSMutableAttributedString()
        for (rowIndex, row) in allRows.enumerated() {
            for column in 0..<columnCount {
                let text = column < row.cells.count ? row.cells[column] : ""
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                applyCellChrome(to: block, isHeader: row.isHeader)

                let ps = NSMutableParagraphStyle()
                ps.textBlocks = [block]
                ps.lineSpacing = Metrics.cellLineSpacing
                ps.lineBreakMode = .byWordWrapping
                ps.paragraphSpacingBefore = 0
                ps.paragraphSpacing = 0
                ps.alignment = .left

                // AppKit NSTextTableBlock 要求每个单元格以段落结束符结尾
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: row.isHeader ? Metrics.tableHeaderFont : Metrics.tableFont,
                    .foregroundColor: DesignTokens.label1,
                    .paragraphStyle: ps,
                ]))
            }
        }

        if !isLast { out.append(tableTerminator()) }
        return out
    }

    private static func applyCellChrome(to block: NSTextTableBlock, isHeader: Bool) {
        block.setWidth(Metrics.cellPadH, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(Metrics.cellPadH, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(Metrics.cellPadV, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(Metrics.cellPadV, type: .absoluteValueType, for: .padding, edge: .maxY)
        for edge in [NSRectEdge.minX, NSRectEdge.maxX, NSRectEdge.minY, NSRectEdge.maxY] {
            block.setWidth(Metrics.cellBorder, type: .absoluteValueType, for: .border, edge: edge)
            block.setBorderColor(DesignTokens.stroke, for: edge)
        }
        // 表头轻底 + 半粗字是唯一的层级提示，不做斑马纹（暗玻璃上会脏）
        block.backgroundColor = isHeader ? DesignTokens.fillCard : nil
    }

    /// 表格尾声：把后面的块从表格里「收」出来，并留 6pt 呼吸
    private static func tableTerminator() -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = 0.1
        ps.maximumLineHeight = 0.1
        ps.paragraphSpacingBefore = Metrics.tableTrailingGap
        ps.paragraphSpacing = 0
        return NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .paragraphStyle: ps,
        ])
    }

    // MARK: - 高度实测（供面板 computeFrame：表格 / 列表都按真实排版高度算）

    static func measuredHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 16 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height
    }

    // MARK: - 多格式剪贴板（原子写入 HTML + RTF + 纯文本）

    /// 一次性写入三种格式，一个 pasteboardItem 承载：
    /// - `.html`：优先用 `OCRDocument.renderHTML()` 的语义 HTML（干净 <table>/<ul>），否则由 attributed 导出；
    /// - `.rtf`：由 attributed 导出（带 \listtable / \trowd，Word / 备忘录原生还原）；
    /// - `.string`：干净纯文本，终端 / 纯文本框 / 搜索框落这个。
    static func writeRichToPasteboard(attributed: NSAttributedString, semanticHTML: String?, plainText: String) {
        let range = NSRange(location: 0, length: attributed.length)
        let documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        let html: String? = {
            if let semanticHTML {
                let trimmed = semanticHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            guard range.length > 0,
                  let data = try? attributed.data(from: range, documentAttributes: documentAttributes),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            return decoded
        }()

        let rtf: Data? = range.length > 0
            ? attributed.rtf(from: range, documentAttributes: [:])
            : nil

        let fallbackPlain = plainText.isEmpty ? attributed.string : plainText

        let item = NSPasteboardItem()
        if let html, let htmlData = html.data(using: .utf8) {
            item.setData(htmlData, forType: .html)
        }
        if let rtf {
            item.setData(rtf, forType: .rtf)
        }
        item.setString(fallbackPlain, forType: .string)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        // 自写标记：剪贴板图片感知据此跳过 Snapcut 自己写的内容
        ClipboardWriter.markOwnWrite()
    }
}
