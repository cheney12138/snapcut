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

/// 结构化 OCR 结果：纯文本、二维码列表、Markdown 表格及维度元数据。
public struct StructuredOCRResult: Equatable, Sendable {
    public let plainText: String
    public let qrCodes: [DetectedQRCode]
    public let markdownTable: String?
    public let tableRowCount: Int
    public let tableColumnCount: Int

    public var hasAnyContent: Bool { !plainText.isEmpty || !qrCodes.isEmpty }

    public init(
        plainText: String,
        qrCodes: [DetectedQRCode],
        markdownTable: String?,
        tableRowCount: Int,
        tableColumnCount: Int
    ) {
        self.plainText = plainText
        self.qrCodes = qrCodes
        self.markdownTable = markdownTable
        self.tableRowCount = tableRowCount
        self.tableColumnCount = tableColumnCount
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
        let cleanBlocks = blocks.compactMap { block -> OCRPositionedBlock? in
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
        return (markdown: markdown, rows: rows.count, columns: colCount)
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

    private static func escapeMarkdownCell(_ text: String) -> String {
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
