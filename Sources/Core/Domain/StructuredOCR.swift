import CoreGraphics
import Foundation

/// 带归一化位置坐标的单块 OCR 文本（纯 Core，坐标原点左上 Y-down，范围 0…1）。
public struct OCRPositionedBlock: Equatable, Sendable {
    public let text: String
    public let minX: Double
    public let maxX: Double
    public let minY: Double
    public let maxY: Double

    public init(text: String, minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.text = text
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }
}

/// 识别到的二维码结果及安全可直达 URL 解析结果。
public struct DetectedQRCode: Equatable, Sendable {
    public let payload: String
    public let openableURL: URL?

    public var isOpenableURL: Bool { openableURL != nil }

    public init(payload: String, openableURL: URL?) {
        self.payload = payload
        self.openableURL = openableURL
    }
}

/// 文档列表条目（`level` 0 = 顶层，1 = 二级缩进；`ordinal` 为有序列表序号，无序为 nil）。
public struct OCRListItem: Equatable, Sendable {
    public let text: String
    public let level: Int
    public let ordinal: Int?

    public init(text: String, level: Int = 0, ordinal: Int? = nil) {
        self.text = text
        self.level = level
        self.ordinal = ordinal
    }
}

/// 结构化文档块：标题 / 自然段 / 无序列表 / 有序列表 / 表格。
public enum OCRDocumentBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bulletList(items: [OCRListItem])
    case orderedList(items: [OCRListItem])
    case table(headers: [String], rows: [[String]])
}

/// 结构化文档（按阅读顺序的块序列），支持 Markdown / HTML / 纯文本三种渲染输出。
public struct OCRDocument: Equatable, Sendable {
    public let blocks: [OCRDocumentBlock]

    public init(blocks: [OCRDocumentBlock]) {
        self.blocks = blocks
    }

    /// 含任意标题 / 列表 / 表格，或自然段数量 ≥ 2 即视为有富结构（单段短文不算）。
    public var hasRichStructure: Bool {
        var paragraphCount = 0
        for block in blocks {
            switch block {
            case .heading, .bulletList, .orderedList, .table:
                return true
            case .paragraph:
                paragraphCount += 1
            }
        }
        return paragraphCount >= 2
    }

    public var hasTable: Bool {
        for block in blocks {
            if case .table = block { return true }
        }
        return false
    }

    /// 首个表格的维度（含表头行）。
    public var primaryTableDimensions: (rows: Int, columns: Int)? {
        for block in blocks {
            if case let .table(headers, rows) = block {
                return (rows: 1 + rows.count, columns: headers.count)
            }
        }
        return nil
    }

    // MARK: - Markdown

    public func renderMarkdown() -> String {
        var result = ""

        for (index, block) in blocks.enumerated() {
            let fragment: String
            switch block {
            case let .heading(level, text):
                let hashes = String(repeating: "#", count: max(1, min(level, 6)))
                fragment = hashes + " " + text
            case let .paragraph(text):
                fragment = text
            case let .bulletList(items):
                let lines = items.map { item -> String in
                    (item.level >= 1 ? "  " : "") + "- " + item.text
                }
                fragment = lines.joined(separator: "\n")
            case let .orderedList(items):
                var counters: [Int: Int] = [:]
                var lines: [String] = []
                for item in items {
                    let level = min(max(item.level, 0), 1)
                    let number: Int
                    if let ordinal = item.ordinal {
                        number = ordinal
                    } else {
                        number = (counters[level] ?? 0) + 1
                    }
                    counters[level] = number
                    lines.append((level >= 1 ? "  " : "") + "\(number). " + item.text)
                }
                fragment = lines.joined(separator: "\n")
            case let .table(headers, rows):
                let columnCount = max(1, headers.count)
                let headerLine = "| " + headers.map(StructuredOCRFormatter.escapeMarkdownCell).joined(separator: " | ") + " |"
                let separatorLine = "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
                var lines = [headerLine, separatorLine]
                for row in rows {
                    let cells = (0..<columnCount).map { index -> String in
                        index < row.count ? StructuredOCRFormatter.escapeMarkdownCell(row[index]) : ""
                    }
                    lines.append("| " + cells.joined(separator: " | ") + " |")
                }
                fragment = lines.joined(separator: "\n")
            }
            guard !fragment.isEmpty else { continue }
            if !result.isEmpty {
                // 父列表紧接缩进子列表（如 1. 下挂 2 格缩进的 - 子项）用单换行紧贴，维持嵌套列表语义
                let previousIsList = index > 0 && Self.isListBlock(blocks[index - 1])
                let currentIsNestedChild = Self.startsAtNestedLevel(block)
                result += (previousIsList && currentIsNestedChild) ? "\n" : "\n\n"
            }
            result += fragment
        }

        return result
    }

    // MARK: - HTML

    /// 语义 HTML 片段（全部文本严格转义，可直接粘贴到飞书 / Notion / Word / 备忘录还原结构）。
    public func renderHTML() -> String {
        var parts: [String] = []
        parts.reserveCapacity(blocks.count)

        for (index, block) in blocks.enumerated() {
            switch block {
            case let .heading(level, text):
                let tag = level <= 1 ? "h1" : "h2"
                parts.append("<\(tag)>\(Self.escapeHTML(text))</\(tag)>")
            case let .paragraph(text):
                parts.append("<p>\(Self.escapeHTML(text))</p>")
            case let .bulletList(items):
                let listHTML = Self.renderHTMLList(items: items, ordered: false)
                if index > 0, Self.isListBlock(blocks[index - 1]), Self.startsAtNestedLevel(block),
                   !parts.isEmpty, Self.embedNestedList(listHTML, intoParentHTML: &parts[parts.count - 1]) {
                    continue
                }
                parts.append(listHTML)
            case let .orderedList(items):
                let listHTML = Self.renderHTMLList(items: items, ordered: true)
                if index > 0, Self.isListBlock(blocks[index - 1]), Self.startsAtNestedLevel(block),
                   !parts.isEmpty, Self.embedNestedList(listHTML, intoParentHTML: &parts[parts.count - 1]) {
                    continue
                }
                parts.append(listHTML)
            case let .table(headers, rows):
                parts.append(Self.renderHTMLTable(headers: headers, rows: rows))
            }
        }

        return parts.joined(separator: "\n")
    }

    private static func isListBlock(_ block: OCRDocumentBlock) -> Bool {
        switch block {
        case .bulletList, .orderedList: return true
        default: return false
        }
    }

    private static func startsAtNestedLevel(_ block: OCRDocumentBlock) -> Bool {
        switch block {
        case let .bulletList(items), let .orderedList(items):
            return (items.first?.level ?? 0) >= 1
        default:
            return false
        }
    }

    /// 把缩进子列表（如 `<ul>...</ul>`）嵌进父列表最后一个 `<li>...</li>` 内部。
    private static func embedNestedList(_ childHTML: String, intoParentHTML parent: inout String) -> Bool {
        for closing in ["</li></ol>", "</li></ul>"] {
            if parent.hasSuffix(closing) {
                let outerClose = String(closing.dropFirst(5)) // "</ol>" or "</ul>"
                parent.removeLast(closing.count)
                parent += childHTML + "</li>" + outerClose
                return true
            }
        }
        return false
    }

    private static func renderHTMLList(items: [OCRListItem], ordered: Bool) -> String {
        guard !items.isEmpty else { return "" }
        let tag = ordered ? "ol" : "ul"
        // 若列表整体以二级缩进起头（挂在父列表下），内部相对层级以最小 level 为基准避免多包一层空列表
        let baseLevel = items.map { min(max($0.level, 0), 1) }.min() ?? 0
        var html = "<\(tag)>"
        var nestedOpen = false
        var nestedAttachedToLI = false
        var counters: [Int: Int] = [:]

        for item in items {
            let level = max(0, min(max(item.level, 0), 1) - baseLevel)
            let number: Int
            if let ordinal = item.ordinal {
                number = ordinal
            } else {
                number = (counters[level] ?? 0) + 1
            }
            counters[level] = number

            if level >= 1 {
                if !nestedOpen {
                    if html.hasSuffix("</li>") {
                        // 嵌套子列表挂在上一级 <li> 内部，待子列表闭合时再补 </li>
                        html.removeLast(5)
                        nestedAttachedToLI = true
                    } else {
                        nestedAttachedToLI = false
                    }
                    html += "<\(tag)>"
                    nestedOpen = true
                }
                html += "<li>\(escapeHTML(item.text))</li>"
            } else {
                if nestedOpen {
                    html += nestedAttachedToLI ? "</\(tag)></li>" : "</\(tag)>"
                    nestedOpen = false
                    nestedAttachedToLI = false
                }
                html += "<li>\(escapeHTML(item.text))</li>"
            }
        }

        if nestedOpen {
            html += nestedAttachedToLI ? "</\(tag)></li>" : "</\(tag)>"
        }
        html += "</\(tag)>"
        return html
    }

    private static func renderHTMLTable(headers: [String], rows: [[String]]) -> String {
        let columnCount = max(1, headers.count)
        var html = "<table style=\"border-collapse:collapse;\">"
        if !headers.isEmpty {
            html += "<thead><tr>"
            for header in headers {
                html += "<th style=\"border:1px solid #d0d7de;padding:6px 10px;background:#f6f8fa;text-align:left;\">"
                html += escapeHTML(header)
                html += "</th>"
            }
            html += "</tr></thead>"
        }
        html += "<tbody>"
        for row in rows {
            html += "<tr>"
            for index in 0..<columnCount {
                let cell = index < row.count ? row[index] : ""
                html += "<td style=\"border:1px solid #d0d7de;padding:6px 10px;\">\(escapeHTML(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    private static func escapeHTML(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    // MARK: - 纯文本

    /// 干净纯文本：段落间空行，列表带符号，表格用制表符分列（粘贴到 Excel / Numbers 可直接分列）。
    public func renderCleanPlainText() -> String {
        var parts: [String] = []
        parts.reserveCapacity(blocks.count)

        for block in blocks {
            switch block {
            case let .heading(_, text):
                parts.append(text)
            case let .paragraph(text):
                parts.append(text)
            case let .bulletList(items):
                let lines = items.map { item -> String in
                    (item.level >= 1 ? "  ◦ " : "• ") + item.text
                }
                parts.append(lines.joined(separator: "\n"))
            case let .orderedList(items):
                var counters: [Int: Int] = [:]
                var lines: [String] = []
                for item in items {
                    let level = min(max(item.level, 0), 1)
                    let number: Int
                    if let ordinal = item.ordinal {
                        number = ordinal
                    } else {
                        number = (counters[level] ?? 0) + 1
                    }
                    counters[level] = number
                    lines.append((level >= 1 ? "  " : "") + "\(number). " + item.text)
                }
                parts.append(lines.joined(separator: "\n"))
            case let .table(headers, rows):
                let columnCount = max(1, headers.count)
                let allRows: [[String]] = [headers] + rows.map { row in
                    (0..<columnCount).map { index -> String in
                        index < row.count ? row[index] : ""
                    }
                }
                parts.append(allRows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
            }
        }

        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// 结构化 OCR 结果：纯文本、二维码列表、Markdown 表格及维度元数据。
public struct StructuredOCRResult: Equatable, Sendable {
    public let plainText: String
    public let qrCodes: [DetectedQRCode]
    public let markdownTable: String?
    public let tableRowCount: Int
    public let tableColumnCount: Int
    /// 富结构文档（标题 / 段落 / 列表 / 表格），旧调用方不传时为 nil。
    public let document: OCRDocument?

    public var hasAnyContent: Bool { !plainText.isEmpty || !qrCodes.isEmpty }
    public var hasRichStructure: Bool { document?.hasRichStructure ?? (markdownTable != nil) }

    public init(
        plainText: String,
        qrCodes: [DetectedQRCode],
        markdownTable: String?,
        tableRowCount: Int,
        tableColumnCount: Int,
        document: OCRDocument? = nil
    ) {
        self.plainText = plainText
        self.qrCodes = qrCodes
        self.markdownTable = markdownTable
        self.tableRowCount = tableRowCount
        self.tableColumnCount = tableColumnCount
        self.document = document
    }
}

/// 纯 Core 结构化 OCR 解析器：二维码安全协议校验 + 表格布局聚类转 GitHub Flavored Markdown。
public enum StructuredOCRFormatter {
    private static let allowedURLSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    private static let minColumnGap = 0.025
    private static let columnMinXTolerance = 0.055
    private static let columnMidXTolerance = 0.05

    /// 构造 `DetectedQRCode`，仅对安全显式协议（http / https / mailto / tel）解析 `openableURL`。
    public static func makeQRCode(payload: String) -> DetectedQRCode {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .newlines) == nil,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              allowedURLSchemes.contains(scheme) else {
            return DetectedQRCode(payload: payload, openableURL: nil)
        }

        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else {
                return DetectedQRCode(payload: payload, openableURL: nil)
            }
            return DetectedQRCode(payload: payload, openableURL: url)
        case "mailto":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !components.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return DetectedQRCode(payload: payload, openableURL: nil)
            }
            return DetectedQRCode(payload: payload, openableURL: url)
        case "tel":
            let remainder = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty, remainder.rangeOfCharacter(from: .decimalDigits) != nil else {
                return DetectedQRCode(payload: payload, openableURL: nil)
            }
            return DetectedQRCode(payload: payload, openableURL: url)
        default:
            return DetectedQRCode(payload: payload, openableURL: nil)
        }
    }

    /// 从带坐标的 OCR 块检测表格结构并输出 GitHub Flavored Markdown 表格。
    ///
    /// 对普通单列段落、稀疏标题+页码等非表格文本保持零误判，不满足结构条件时返回 `nil`。
    public static func detectMarkdownTable(
        from blocks: [OCRPositionedBlock]
    ) -> (markdown: String, rows: Int, columns: Int)? {
        guard let grid = buildTable(from: blocks) else { return nil }
        return (markdown: grid.markdown, rows: grid.rowCount, columns: grid.columnCount)
    }

    /// 表格聚类主流程：行聚类 → 列聚类 → 结构验证 → 网格 + Markdown。
    private static func buildTable(from blocks: [OCRPositionedBlock]) -> TableGrid? {
        let cleanBlocks = sanitizeBlocks(blocks)
        guard cleanBlocks.count >= 2 else { return nil }

        // 1) 行聚类：按 minY 排序，中线落入行区间或垂直重叠 ≥ 40% 视为同一行
        let rows = clusterRows(cleanBlocks)
        guard rows.count >= 2 else { return nil }

        // 2) 行内水平分段：gap < 0.025（或重叠）视为同格片段，≥ 0.025 视为水平分离块
        let rowSegments = mergeRowSegments(rows)
        let multiCellRowCount = rowSegments.filter { $0.count >= 2 }.count
        guard multiCellRowCount >= 2 else { return nil }

        // 3) 列聚类：结合左缘（minX）与中心（midX）容差聚合，禁止同行分离块落入同列
        guard let clustered = clusterColumns(rowSegments) else { return nil }
        let colCount = clustered.columnCount
        guard (2...12).contains(colCount) else { return nil }

        // 4) 填充二维表格并验证结构化特征
        var grid = Array(
            repeating: Array(repeating: "", count: colCount),
            count: rows.count
        )
        for seg in clustered.assignments {
            let existing = grid[seg.segment.rowIndex][seg.columnIndex]
            if existing.isEmpty {
                grid[seg.segment.rowIndex][seg.columnIndex] = seg.segment.text
            } else {
                grid[seg.segment.rowIndex][seg.columnIndex] = joinSegmentText(existing, seg.segment.text)
            }
        }

        let rowsWithTwoPlusCols = grid.filter { row in
            row.filter { !$0.isEmpty }.count >= 2
        }.count
        guard Double(rowsWithTwoPlusCols) / Double(rows.count) >= 0.60 else { return nil }

        let totalCells = rows.count * colCount
        let nonEmptyCells = grid.reduce(0) { partial, row in
            partial + row.filter { !$0.isEmpty }.count
        }
        guard totalCells > 0, Double(nonEmptyCells) / Double(totalCells) >= 0.45 else { return nil }

        // 反阶梯假表格门禁：真表格至少要有 2 列各自在 ≥2 行中垂直对齐，
        // 避免两行含行内图标/徽章留白的普通折行文字错位聚出 2×3 假表格
        let alignedColumnCount = (0..<colCount).filter { col in
            grid.reduce(0) { $0 + ($1[col].isEmpty ? 0 : 1) } >= 2
        }.count
        guard alignedColumnCount >= 2 else { return nil }

        if rows.count == 2 {
            let maxSegmentsInAnyRow = rowSegments.map(\.count).max() ?? 0
            // 仅 2 行时不允许聚出比单行最大段数还多的错位列，且填充率须 ≥ 75%
            guard colCount <= maxSegmentsInAnyRow,
                  Double(nonEmptyCells) / Double(totalCells) >= 0.75 else { return nil }
        }

        // 5) 输出标准 GitHub Flavored Markdown 表格
        let escapedGrid = grid.map { row in
            row.map(escapeMarkdownCell)
        }
        let headerLine = "| " + escapedGrid[0].joined(separator: " | ") + " |"
        let separatorLine = "| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |"
        let bodyLines = escapedGrid.dropFirst().map { row in
            "| " + row.joined(separator: " | ") + " |"
        }

        let markdown = ([headerLine, separatorLine] + bodyLines).joined(separator: "\n")
        return TableGrid(grid: grid, markdown: markdown)
    }

    /// 表格聚类结果：原始网格 + 渲染好的 Markdown。
    private struct TableGrid {
        let grid: [[String]]
        let markdown: String

        var rowCount: Int { grid.count }
        var columnCount: Int { grid.first?.count ?? 0 }
    }

    private static func sanitizeBlocks(_ blocks: [OCRPositionedBlock]) -> [OCRPositionedBlock] {
        blocks.compactMap { block -> OCRPositionedBlock? in
            let trimmed = normalizeCellWhitespace(block.text)
            guard !trimmed.isEmpty else { return nil }
            return OCRPositionedBlock(
                text: trimmed,
                minX: block.minX,
                maxX: max(block.minX, block.maxX),
                minY: block.minY,
                maxY: max(block.minY, block.maxY)
            )
        }
    }

    // MARK: - 结构化文档解析

    /// 把带坐标的 OCR 块解析成富结构文档（标题 / 自然段 / 列表 / 混排局部表格）。
    ///
    /// 非表格文本保持零误判：单行 / 单段短文只产出一个 `.paragraph`，`hasRichStructure` 为 false。
    public static func parseDocument(from blocks: [OCRPositionedBlock]) -> OCRDocument {
        let cleanBlocks = sanitizeBlocks(blocks)
        guard !cleanBlocks.isEmpty else { return OCRDocument(blocks: []) }

        let lines = makeVisualLines(from: cleanBlocks)
        guard !lines.isEmpty else { return OCRDocument(blocks: []) }

        let metrics = DocumentMetrics(lines: lines)

        // 整图纯表格快速通道：全文所有行都落入同一张表 ⇒ 直接输出单表（兼容旧表格路径）
        if let whole = buildTable(from: cleanBlocks), whole.rowCount == lines.count {
            return OCRDocument(blocks: [tableBlock(from: whole)])
        }

        var output: [OCRDocumentBlock] = []
        var textLines: [VisualLine] = []
        var index = 0

        while index < lines.count {
            if lines[index].isMultiCell, let run = tableRun(startingAt: index, in: lines) {
                // 仅 2 行的局部切片若首行本身就是列表项（如 `2. xxx [图标] yyy` 折两行），绝不误切为表格
                let isTwoLineListItem = run.lines.count == 2
                    && (detectOrderedMarker(run.lines[0]) != nil || detectBulletMarker(run.lines[0]) != nil)
                var runBlocks: [OCRPositionedBlock] = []
                if !isTwoLineListItem {
                    for line in run.lines {
                        runBlocks.append(contentsOf: line.blocks())
                    }
                }
                if !runBlocks.isEmpty, let grid = buildTable(from: runBlocks) {
                    if !textLines.isEmpty {
                        output.append(contentsOf: parseTextLines(
                            textLines,
                            metrics: metrics,
                            totalLineCount: lines.count
                        ))
                        textLines.removeAll(keepingCapacity: true)
                    }
                    output.append(tableBlock(from: grid))
                    index = run.endIndex
                    continue
                }
            }
            textLines.append(lines[index])
            index += 1
        }

        if !textLines.isEmpty {
            output.append(contentsOf: parseTextLines(
                textLines,
                metrics: metrics,
                totalLineCount: lines.count
            ))
        }

        return OCRDocument(blocks: output)
    }

    /// 扫描从 `start` 开始的局部表格切片：连续多格行，允许内部夹杂最多 1 行单格行。
    private static func tableRun(
        startingAt start: Int,
        in lines: [VisualLine]
    ) -> (lines: [VisualLine], endIndex: Int)? {
        var collected: [VisualLine] = [lines[start]]
        var multiCellCount = 1
        var cursor = start + 1

        while cursor < lines.count {
            let line = lines[cursor]
            if line.isMultiCell {
                collected.append(line)
                multiCellCount += 1
                cursor += 1
                continue
            }
            // 只允许「内部」夹杂的单格行：后面必须紧跟多格行
            guard cursor + 1 < lines.count, lines[cursor + 1].isMultiCell else { break }
            collected.append(line)
            cursor += 1
        }

        guard multiCellCount >= 2 else { return nil }
        return (lines: collected, endIndex: start + collected.count)
    }

    private static func tableBlock(from grid: TableGrid) -> OCRDocumentBlock {
        let headers = grid.grid.first ?? []
        let rows = Array(grid.grid.dropFirst())
        return .table(headers: headers, rows: rows)
    }

    // MARK: - 视觉行聚合

    private struct VisualSegment {
        let text: String
        let minX: Double
        let maxX: Double
    }

    private struct VisualLine {
        let segments: [VisualSegment]
        let minY: Double
        let maxY: Double

        var minX: Double { segments.first?.minX ?? 0 }
        var maxX: Double { segments.last?.maxX ?? 0 }
        var height: Double { max(0, maxY - minY) }
        var isMultiCell: Bool { segments.count >= 2 }

        var fullText: String {
            segments.reduce(into: "") { joined, segment in
                joined = StructuredOCRFormatter.joinSegmentText(joined, segment.text)
            }
        }

        func blocks() -> [OCRPositionedBlock] {
            segments.map { segment in
                OCRPositionedBlock(
                    text: segment.text,
                    minX: segment.minX,
                    maxX: segment.maxX,
                    minY: minY,
                    maxY: maxY
                )
            }
        }
    }

    private static func makeVisualLines(from blocks: [OCRPositionedBlock]) -> [VisualLine] {
        let rows = clusterRows(blocks)
        let segmented = mergeRowSegments(rows)

        var lines: [VisualLine] = []
        lines.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard index < segmented.count, !segmented[index].isEmpty else { continue }
            let minY = row.map(\.minY).min() ?? 0
            let maxY = row.map(\.maxY).max() ?? 0
            let segments = segmented[index].map { segment in
                VisualSegment(text: segment.text, minX: segment.minX, maxX: segment.maxX)
            }
            lines.append(VisualLine(segments: segments, minY: minY, maxY: maxY))
        }
        return lines
    }

    // MARK: - 版面尺度

    private struct DocumentMetrics {
        let medianHeight: Double
        let baseLeftX: Double
        let baseRightX: Double
        let typicalLineGap: Double
        let breakGap: Double
        let indentThreshold: Double
        let columnWidth: Double

        init(lines: [VisualLine]) {
            let heights = lines.map(\.height).filter { $0 > 0 }
            let medianHeight = max(StructuredOCRFormatter.percentile(heights, 0.5), 0.0001)
            let baseLeftX = StructuredOCRFormatter.percentile(lines.map(\.minX), 0.25)
            let baseRightX = StructuredOCRFormatter.percentile(lines.map(\.maxX), 0.9)

            var gaps: [Double] = []
            if lines.count > 1 {
                for index in 1..<lines.count {
                    let gap = lines[index].minY - lines[index - 1].maxY
                    if gap > 0 { gaps.append(gap) }
                }
            }
            let typicalLineGap: Double
            if gaps.isEmpty {
                typicalLineGap = medianHeight * 0.35
            } else {
                let sorted = gaps.sorted()
                let index = min(sorted.count / 4, sorted.count - 1)
                typicalLineGap = max(sorted[index], 0.000001)
            }

            self.medianHeight = medianHeight
            self.baseLeftX = baseLeftX
            self.baseRightX = baseRightX
            self.typicalLineGap = typicalLineGap
            self.breakGap = max(typicalLineGap * 1.65, medianHeight * 0.65)
            self.indentThreshold = max(0.03, medianHeight * 1.1)
            self.columnWidth = max(baseRightX - baseLeftX, 0.0001)
        }

        /// 列表悬挂折行的最大可归并间距。
        var wrapGap: Double { max(typicalLineGap * 1.45, medianHeight * 0.65) }
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rawIndex = Double(sorted.count - 1) * fraction
        let index = min(max(Int(rawIndex.rounded()), 0), sorted.count - 1)
        return sorted[index]
    }

    // MARK: - 标题 / 列表 / 自然段

    private static func parseTextLines(
        _ lines: [VisualLine],
        metrics: DocumentMetrics,
        totalLineCount: Int
    ) -> [OCRDocumentBlock] {
        var blocks: [OCRDocumentBlock] = []
        var index = 0
        // 记录最近一次顶层列表的左缘：支持「1. 有序父项 → 缩进 • 无序子项」跨块继承二级层级
        var lastTopListLeftX: Double?

        while index < lines.count {
            let line = lines[index]

            if detectBulletMarker(line) != nil {
                let isChildOfPreviousList = lastTopListLeftX.map { (line.minX - $0) >= 0.025 } ?? false
                let collected = collectList(
                    from: lines,
                    start: index,
                    ordered: false,
                    metrics: metrics,
                    baseLevel: isChildOfPreviousList ? 1 : 0
                )
                blocks.append(.bulletList(items: collected.items))
                if !isChildOfPreviousList { lastTopListLeftX = line.minX }
                index = collected.nextIndex
                continue
            }

            if detectOrderedMarker(line) != nil {
                let isChildOfPreviousList = lastTopListLeftX.map { (line.minX - $0) >= 0.025 } ?? false
                let collected = collectList(
                    from: lines,
                    start: index,
                    ordered: true,
                    metrics: metrics,
                    baseLevel: isChildOfPreviousList ? 1 : 0
                )
                blocks.append(.orderedList(items: collected.items))
                if !isChildOfPreviousList { lastTopListLeftX = line.minX }
                index = collected.nextIndex
                continue
            }

            lastTopListLeftX = nil

            if let heading = parseHeading(
                line,
                metrics: metrics,
                totalLineCount: totalLineCount
            ) {
                blocks.append(heading)
                index += 1
                continue
            }

            let paragraph = collectParagraph(
                from: lines,
                start: index,
                metrics: metrics,
                totalLineCount: totalLineCount
            )
            blocks.append(.paragraph(text: paragraph.text))
            index = paragraph.nextIndex
        }

        return blocks
    }

    private static func parseHeading(
        _ line: VisualLine,
        metrics: DocumentMetrics,
        totalLineCount: Int
    ) -> OCRDocumentBlock? {
        // 需要存在正文参照（全文 ≥ 2 行），否则单行短文会被误当标题
        guard totalLineCount >= 2 else { return nil }
        guard detectBulletMarker(line) == nil, detectOrderedMarker(line) == nil else { return nil }

        let text = line.fullText
        guard !text.isEmpty, text.count <= 60 else { return nil }
        guard !endsSentence(text) else { return nil }

        if line.height >= metrics.medianHeight * 1.45 {
            return .heading(level: 1, text: text)
        }
        if line.height >= metrics.medianHeight * 1.22 {
            return .heading(level: 2, text: text)
        }
        return nil
    }

    private static func collectList(
        from lines: [VisualLine],
        start: Int,
        ordered: Bool,
        metrics: DocumentMetrics,
        baseLevel: Int = 0
    ) -> (items: [OCRListItem], nextIndex: Int) {
        let topLeftX = lines[start].minX
        var items: [OCRListItem] = []
        var index = start
        var lastLine = lines[start]
        var isFirstItem = true

        while index < lines.count {
            let line = lines[index]
            let marker = ordered ? detectOrderedMarker(line) : detectBulletMarker(line)
            guard let marker else { break }

            if !isFirstItem {
                let gap = line.minY - lastLine.maxY
                if gap > metrics.breakGap { break }
            }

            // 悬挂折行归并：紧随列表项后的非列表普通行，间距小且不明显左偏时并入上一项
            var text = marker.content
            var consumed = line
            var cursor = index + 1
            while cursor < lines.count {
                let next = lines[cursor]
                if detectBulletMarker(next) != nil || detectOrderedMarker(next) != nil { break }
                let gap = next.minY - consumed.maxY
                guard gap <= metrics.wrapGap else { break }
                guard next.minX >= marker.symbolMinX - 0.015 else { break }
                text = joinSegmentText(text, next.fullText)
                consumed = next
                cursor += 1
            }

            let relativeLevel = (line.minX - topLeftX) >= 0.025 ? 1 : 0
            let level = min(1, baseLevel + relativeLevel)
            items.append(OCRListItem(text: text, level: level, ordinal: marker.ordinal))
            lastLine = consumed
            index = cursor
            isFirstItem = false
        }

        return (items, index)
    }

    private static func collectParagraph(
        from lines: [VisualLine],
        start: Int,
        metrics: DocumentMetrics,
        totalLineCount: Int
    ) -> (text: String, nextIndex: Int) {
        var text = lines[start].fullText
        var last = lines[start]
        var index = start + 1

        while index < lines.count {
            let next = lines[index]
            if detectBulletMarker(next) != nil || detectOrderedMarker(next) != nil { break }
            if parseHeading(next, metrics: metrics, totalLineCount: totalLineCount) != nil { break }

            let gap = next.minY - last.maxY
            if gap > metrics.breakGap { break }

            let indent = next.minX - metrics.baseLeftX
            let previousIndent = last.minX - metrics.baseLeftX
            if indent >= metrics.indentThreshold, previousIndent < metrics.indentThreshold { break }

            let shortTail = (metrics.baseRightX - last.maxX) > max(0.08, metrics.columnWidth * 0.22)
            if shortTail, endsSentence(last.fullText) { break }

            text = joinSegmentText(text, next.fullText)
            last = next
            index += 1
        }

        return (text, index)
    }

    // MARK: - 列表标记

    private struct ListMarker {
        let content: String
        let ordinal: Int?
        let symbolMinX: Double
    }

    private static let bulletGlyphs: Set<Character> = [
        "•", "·", "▪", "▫", "◦", "●", "○", "■", "□", "◆", "◇", "▸", "▹", "‣", "⁃",
    ]

    private static let dashGlyphs: Set<Character> = ["-", "–", "—", "*"]

    private static let chineseOrdinals: [Character: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    private static let orderedSeparators: Set<Character> = [".", "．", "、", ")"]

    /// 只认 ASCII 数字：`Character.isNumber` 对「一」「五」等 CJK 数字也为 true，会吞掉中文序号。
    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static let sentenceTerminators: Set<Character> = [
        "。", "．", ".", "；", ";", "！", "!", "？", "?", "：", ":",
    ]

    private static let closingQuotes: Set<Character> = ["”", "\"", "」", "』", "）", ")", "】"]

    private static let cjkLeadingPunctuation: Set<Character> = [
        "「", "『", "“", "（", "【", "《", "［",
    ]

    private static func detectBulletMarker(_ line: VisualLine) -> ListMarker? {
        let text = line.fullText
        guard let first = text.first else { return nil }
        let isDedicatedBullet = bulletGlyphs.contains(first)
        let isDash = dashGlyphs.contains(first)
        guard isDedicatedBullet || isDash else { return nil }

        let rest = text.dropFirst()
        guard let next = rest.first else { return nil }
        if isDash {
            // `-` / `*` 后必须紧跟空白：`-5` / `-3.14` / `*斜体*` 不会误判为列表
            guard next == " " || next == "\t" else { return nil }
        } else {
            // 专用圆点符号（`•` / `▪` / `◦` 等）不要求后接空格：Vision 与中文 CJK 拼接常吞掉圆点后空格
            // 仅排除连续重复符号（如 `•••` 省略号/更多图标）
            guard !bulletGlyphs.contains(next) else { return nil }
        }
        let content = rest.drop(while: { $0 == " " || $0 == "\t" })
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ListMarker(content: trimmed, ordinal: nil, symbolMinX: line.minX)
    }

    private static func detectOrderedMarker(_ line: VisualLine) -> ListMarker? {
        let text = line.fullText
        guard let first = text.first else { return nil }

        // (1) / （1） 括号码
        if first == "(" || first == "（" {
            let closing: Character = first == "(" ? ")" : "）"
            let body = text.dropFirst()
            let digits = body.prefix(while: { isASCIIDigit($0) })
            guard !digits.isEmpty, digits.count <= 3, let ordinal = Int(String(digits)) else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard afterDigits.first == closing else { return nil }
            return makeMarker(content: afterDigits.dropFirst(), ordinal: ordinal, symbolMinX: line.minX)
        }

        // 阿拉伯数字：1. / 2) / 3、/ 4．
        let digits = text.prefix(while: { isASCIIDigit($0) })
        if !digits.isEmpty, digits.count <= 3 {
            guard let ordinal = Int(String(digits)), (1...999).contains(ordinal) else { return nil }
            let rest = text.dropFirst(digits.count)
            guard let separator = rest.first, orderedSeparators.contains(separator) else { return nil }
            let tail = rest.dropFirst()
            if separator == "." || separator == "．" {
                guard let next = tail.first else { return nil }
                // 小数 / 版本号 / 英文文件名不当列表：`3.14`、`1.swift`；
                // 但中文场景 Vision 常吞掉 `1. ` 后的空格（如 `1.纯Core`、`3.测试与文档`），允许后接空格或 CJK/中文左引号
                if isASCIIDigit(next) { return nil }
                let allowedAfterDot = (next == " " || next == "\t")
                    || isCJK(next)
                    || cjkLeadingPunctuation.contains(next)
                guard allowedAfterDot else { return nil }
            }
            return makeMarker(content: tail, ordinal: ordinal, symbolMinX: line.minX)
        }

        // 中文序号：一、 / 二、
        if let ordinal = chineseOrdinals[first] {
            let rest = text.dropFirst()
            guard let separator = rest.first, orderedSeparators.contains(separator) else { return nil }
            return makeMarker(content: rest.dropFirst(), ordinal: ordinal, symbolMinX: line.minX)
        }

        return nil
    }

    private static func makeMarker(
        content: Substring,
        ordinal: Int,
        symbolMinX: Double
    ) -> ListMarker? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ListMarker(content: trimmed, ordinal: ordinal, symbolMinX: symbolMinX)
    }

    /// 句末标点判定（允许句末带右引号 / 右括号）。
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        if sentenceTerminators.contains(last) { return true }
        if closingQuotes.contains(last) {
            let trimmed = text.dropLast()
            guard let inner = trimmed.last else { return false }
            return sentenceTerminators.contains(inner)
        }
        return false
    }

    // MARK: - 行/列聚类内部实现

    private struct HorizontalSegment {
        let rowIndex: Int
        let text: String
        let minX: Double
        let maxX: Double
        var midX: Double { (minX + maxX) * 0.5 }
    }

    private struct ColumnCluster {
        let id: Int
        var rowIndices: Set<Int>
        var minXSum: Double
        var midXSum: Double
        var count: Int
        var minEdge: Double
        var maxEdge: Double

        var anchorMinX: Double { minXSum / Double(count) }
        var anchorMidX: Double { midXSum / Double(count) }

        mutating func add(_ segment: HorizontalSegment) {
            rowIndices.insert(segment.rowIndex)
            minXSum += segment.minX
            midXSum += segment.midX
            count += 1
            minEdge = min(minEdge, segment.minX)
            maxEdge = max(maxEdge, segment.maxX)
        }
    }

    private struct AssignedSegment {
        let segment: HorizontalSegment
        let clusterID: Int
    }

    private struct ColumnAssignmentResult {
        let columnCount: Int
        let assignments: [(segment: HorizontalSegment, columnIndex: Int)]
    }

    private static func clusterRows(_ blocks: [OCRPositionedBlock]) -> [[OCRPositionedBlock]] {
        let sorted = blocks.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        var rows: [[OCRPositionedBlock]] = []
        var current: [OCRPositionedBlock] = []
        var sumMinY = 0.0
        var sumMaxY = 0.0

        for block in sorted {
            if !current.isEmpty {
                let n = Double(current.count)
                let avgMinY = sumMinY / n
                let avgMaxY = sumMaxY / n
                if isSameRow(rowMinY: avgMinY, rowMaxY: avgMaxY, block: block) {
                    current.append(block)
                    sumMinY += block.minY
                    sumMaxY += block.maxY
                    continue
                }
                rows.append(current.sorted { ($0.minX, $0.maxX) < ($1.minX, $1.maxX) })
            }
            current = [block]
            sumMinY = block.minY
            sumMaxY = block.maxY
        }

        if !current.isEmpty {
            rows.append(current.sorted { ($0.minX, $0.maxX) < ($1.minX, $1.maxX) })
        }
        return rows
    }

    private static func isSameRow(rowMinY: Double, rowMaxY: Double, block: OCRPositionedBlock) -> Bool {
        let rowMidY = (rowMinY + rowMaxY) * 0.5
        let blockMidY = (block.minY + block.maxY) * 0.5
        if (blockMidY >= rowMinY && blockMidY <= rowMaxY) || (rowMidY >= block.minY && rowMidY <= block.maxY) {
            return true
        }
        let overlap = min(rowMaxY, block.maxY) - max(rowMinY, block.minY)
        let shorter = min(max(0, rowMaxY - rowMinY), max(0, block.maxY - block.minY))
        return overlap > 0 && shorter > 0 && overlap >= 0.4 * shorter
    }

    private static func mergeRowSegments(_ rows: [[OCRPositionedBlock]]) -> [[HorizontalSegment]] {
        rows.enumerated().map { rowIndex, row in
            guard let first = row.first else { return [] }
            var segments: [HorizontalSegment] = []
            var current = HorizontalSegment(
                rowIndex: rowIndex,
                text: first.text,
                minX: first.minX,
                maxX: first.maxX
            )

            for block in row.dropFirst() {
                let gap = block.minX - current.maxX
                if gap >= minColumnGap {
                    segments.append(current)
                    current = HorizontalSegment(
                        rowIndex: rowIndex,
                        text: block.text,
                        minX: block.minX,
                        maxX: block.maxX
                    )
                } else {
                    current = HorizontalSegment(
                        rowIndex: rowIndex,
                        text: joinSegmentText(current.text, block.text),
                        minX: min(current.minX, block.minX),
                        maxX: max(current.maxX, block.maxX)
                    )
                }
            }
            segments.append(current)
            return segments
        }
    }

    private static func clusterColumns(_ rowSegments: [[HorizontalSegment]]) -> ColumnAssignmentResult? {
        // 按列数由多到少处理行，优先确立完整列锚点，防止缺单元格行造成列漂移
        let orderedRows = rowSegments
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs[0].rowIndex < rhs[0].rowIndex
            }

        var clusters: [ColumnCluster] = []
        var nextID = 0
        var assigned: [AssignedSegment] = []

        for segments in orderedRows {
            var usedClusterIndices: Set<Int> = []
            var candidates: [(segIdx: Int, clusterIdx: Int, cost: Double)] = []

            for (segIdx, seg) in segments.enumerated() {
                for (clusterIdx, cluster) in clusters.enumerated() {
                    if let cost = matchCost(segment: seg, cluster: cluster) {
                        candidates.append((segIdx, clusterIdx, cost))
                    }
                }
            }

            candidates.sort { $0.cost < $1.cost }
            var matchedSegIndices: Set<Int> = []
            var segToClusterIdx: [Int: Int] = [:]

            for cand in candidates {
                guard !matchedSegIndices.contains(cand.segIdx),
                      !usedClusterIndices.contains(cand.clusterIdx) else { continue }
                matchedSegIndices.insert(cand.segIdx)
                usedClusterIndices.insert(cand.clusterIdx)
                segToClusterIdx[cand.segIdx] = cand.clusterIdx
            }

            for (segIdx, seg) in segments.enumerated() {
                if let clusterIdx = segToClusterIdx[segIdx] {
                    clusters[clusterIdx].add(seg)
                    assigned.append(AssignedSegment(segment: seg, clusterID: clusters[clusterIdx].id))
                } else {
                    let cluster = ColumnCluster(
                        id: nextID,
                        rowIndices: [seg.rowIndex],
                        minXSum: seg.minX,
                        midXSum: seg.midX,
                        count: 1,
                        minEdge: seg.minX,
                        maxEdge: seg.maxX
                    )
                    nextID += 1
                    clusters.append(cluster)
                    assigned.append(AssignedSegment(segment: seg, clusterID: cluster.id))
                }
            }
        }

        // 合并彼此在任何行都未同框且锚点接近的碎片列
        clusters.sort { ($0.anchorMinX, $0.anchorMidX) < ($1.anchorMinX, $1.anchorMidX) }
        var idRedirect: [Int: Int] = [:]
        for c in clusters { idRedirect[c.id] = c.id }

        var mergedClusters: [ColumnCluster] = []
        for cluster in clusters {
            if var last = mergedClusters.last,
               last.rowIndices.isDisjoint(with: cluster.rowIndices),
               (abs(cluster.anchorMinX - last.anchorMinX) <= columnMinXTolerance
                || (abs(cluster.anchorMidX - last.anchorMidX) <= columnMidXTolerance
                    && min(cluster.maxEdge, last.maxEdge) > max(cluster.minEdge, last.minEdge))) {
                last.rowIndices.formUnion(cluster.rowIndices)
                last.minXSum += cluster.minXSum
                last.midXSum += cluster.midXSum
                last.count += cluster.count
                last.minEdge = min(last.minEdge, cluster.minEdge)
                last.maxEdge = max(last.maxEdge, cluster.maxEdge)
                mergedClusters[mergedClusters.count - 1] = last
                idRedirect[cluster.id] = last.id
            } else {
                mergedClusters.append(cluster)
            }
        }

        let sortedClusters = mergedClusters.sorted { ($0.anchorMinX, $0.anchorMidX) < ($1.anchorMinX, $1.anchorMidX) }
        var clusterIDToColIndex: [Int: Int] = [:]
        for (idx, c) in sortedClusters.enumerated() {
            clusterIDToColIndex[c.id] = idx
        }

        let finalAssignments: [(segment: HorizontalSegment, columnIndex: Int)] = assigned.compactMap { item in
            let rootID = idRedirect[item.clusterID] ?? item.clusterID
            guard let colIdx = clusterIDToColIndex[rootID] else { return nil }
            return (item.segment, colIdx)
        }

        return ColumnAssignmentResult(columnCount: sortedClusters.count, assignments: finalAssignments)
    }

    private static func matchCost(segment: HorizontalSegment, cluster: ColumnCluster) -> Double? {
        let minXDiff = abs(segment.minX - cluster.anchorMinX)
        if minXDiff <= columnMinXTolerance {
            return minXDiff
        }
        let midXDiff = abs(segment.midX - cluster.anchorMidX)
        let overlapsHorizontally = min(segment.maxX, cluster.maxEdge) > max(segment.minX, cluster.minEdge)
        if midXDiff <= columnMidXTolerance && overlapsHorizontally {
            return midXDiff + 0.005
        }
        return nil
    }

    private static func normalizeCellWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func escapeMarkdownCell(_ text: String) -> String {
        normalizeCellWhitespace(text).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func joinSegmentText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        if let last = lhs.last, isCJK(last) || rhs.first.map(isCJK) == true {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3000...0x303F).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }
}
