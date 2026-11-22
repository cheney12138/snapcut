import CoreGraphics
import Foundation

/// 可重编历史会话载荷（落盘为独立 sidecar JSON，支持 ⌘Z 逐条撤回与画布等比还原）
public struct EditableSessionPayload: Equatable, Codable, Sendable {
    /// 导出时选区的逻辑 pt 尺寸，重开时可按新画布比例精确缩放还原标注
    public var canvasSize: CGSize
    public var annotations: [AnnotationModel]
    public var strokeWidth: CGFloat

    public init(
        canvasSize: CGSize,
        annotations: [AnnotationModel],
        strokeWidth: CGFloat = 2
    ) {
        self.canvasSize = canvasSize
        self.annotations = annotations
        self.strokeWidth = strokeWidth
    }

    private enum CodingKeys: String, CodingKey {
        case canvasSize
        case annotations
        case strokeWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canvasSize = try container.decode(CGSize.self, forKey: .canvasSize)
        annotations = try container.decodeIfPresent([AnnotationModel].self, forKey: .annotations) ?? []
        strokeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .strokeWidth) ?? 2
    }
}

/// 导出写入历史时携带的可选上下文（内存瞬态，不直接序列化进 index JSON）
public struct HistoryCaptureMetadata: Sendable {
    public var sourceApp: String?
    public var windowTitle: String?
    public var baseImage: CGImage?
    public var canvasSize: CGSize?
    public var annotations: [AnnotationModel]
    public var strokeWidth: CGFloat

    public init(
        sourceApp: String? = nil,
        windowTitle: String? = nil,
        baseImage: CGImage? = nil,
        canvasSize: CGSize? = nil,
        annotations: [AnnotationModel] = [],
        strokeWidth: CGFloat = 2
    ) {
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.baseImage = baseImage
        self.canvasSize = canvasSize
        self.annotations = annotations
        self.strokeWidth = strokeWidth
    }
}

/// 历史条目元数据（可持久化索引与跨会话搜索的纯领域模型）
public struct HistoryRecord: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let createdAt: Date
    public let width: Int
    public let height: Int
    public var sourceApp: String?
    public var windowTitle: String?
    public var ocrText: String
    public var hasEditableAnnotations: Bool

    public init(
        id: String,
        createdAt: Date,
        width: Int,
        height: Int,
        sourceApp: String? = nil,
        windowTitle: String? = nil,
        ocrText: String = "",
        hasEditableAnnotations: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.width = width
        self.height = height
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.ocrText = ocrText
        self.hasEditableAnnotations = hasEditableAnnotations
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case width
        case height
        case sourceApp
        case windowTitle
        case ocrText
        case hasEditableAnnotations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 0
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText) ?? ""
        hasEditableAnnotations = try container.decodeIfPresent(Bool.self, forKey: .hasEditableAnnotations) ?? false
    }
}

/// 历史搜索命中结果
public struct HistorySearchMatch: Identifiable, Equatable, Sendable {
    public let record: HistoryRecord
    public var id: String { record.id }
    public let matchedSnippet: String?
    public let matchedTerms: [String]
    public let score: Int

    public init(
        record: HistoryRecord,
        matchedSnippet: String?,
        matchedTerms: [String],
        score: Int
    ) {
        self.record = record
        self.matchedSnippet = matchedSnippet
        self.matchedTerms = matchedTerms
        self.score = score
    }
}

/// 历史检索纯领域算法（零 UI/存储依赖）
public enum HistorySearch {
    /// 按查询词过滤并排序历史记录
    public static func filter(_ records: [HistoryRecord], query: String) -> [HistorySearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return records
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt > rhs.createdAt
                    }
                    return lhs.id > rhs.id
                }
                .map { record in
                    HistorySearchMatch(
                        record: record,
                        matchedSnippet: extractSnippet(from: record.ocrText, terms: []),
                        matchedTerms: [],
                        score: 0
                    )
                }
        }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let calendar = Calendar.current

        var matches: [HistorySearchMatch] = []
        matches.reserveCapacity(records.count)

        for record in records {
            let sizeText = "\(record.width)x\(record.height)"
            let sizeCrossText = "\(record.width)×\(record.height)"
            let comps = calendar.dateComponents([.year, .month, .day], from: record.createdAt)
            let dateFull = String(
                format: "%04d-%02d-%02d",
                comps.year ?? 0,
                comps.month ?? 0,
                comps.day ?? 0
            )
            let dateShort = String(
                format: "%02d-%02d",
                comps.month ?? 0,
                comps.day ?? 0
            )

            var allMatched = true
            var score = 0
            var anyOCRHit = false

            for token in tokens {
                let hitOCR = record.ocrText.localizedCaseInsensitiveContains(token)
                let hitApp = record.sourceApp?.localizedCaseInsensitiveContains(token) ?? false
                let hitTitle = record.windowTitle?.localizedCaseInsensitiveContains(token) ?? false
                let hitMeta = sizeText.localizedCaseInsensitiveContains(token)
                    || sizeCrossText.localizedCaseInsensitiveContains(token)
                    || dateFull.localizedCaseInsensitiveContains(token)
                    || dateShort.localizedCaseInsensitiveContains(token)

                guard hitOCR || hitApp || hitTitle || hitMeta else {
                    allMatched = false
                    break
                }

                if hitOCR { anyOCRHit = true; score += 20 }
                if hitApp { score += 30 }
                if hitTitle { score += 25 }
                if hitMeta { score += 10 }
            }

            guard allMatched else { continue }

            // 全串精确命中加分（sourceApp / windowTitle / ocrText）
            if let app = record.sourceApp {
                if app.caseInsensitiveCompare(trimmed) == .orderedSame {
                    score += 120
                } else if app.localizedCaseInsensitiveContains(trimmed) {
                    score += 80
                }
            }
            if let title = record.windowTitle, title.localizedCaseInsensitiveContains(trimmed) {
                score += 60
            }
            if record.ocrText.localizedCaseInsensitiveContains(trimmed) {
                score += 50
            }

            let snippet: String?
            if anyOCRHit {
                snippet = extractSnippet(from: record.ocrText, terms: tokens)
            } else if let title = record.windowTitle,
                      let titleSnippet = extractSnippet(from: title, terms: tokens) {
                snippet = titleSnippet
            } else if let app = record.sourceApp,
                      let appSnippet = extractSnippet(from: app, terms: tokens) {
                snippet = appSnippet
            } else {
                snippet = nil
            }

            matches.append(
                HistorySearchMatch(
                    record: record,
                    matchedSnippet: snippet,
                    matchedTerms: tokens,
                    score: score
                )
            )
        }

        return matches.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.record.createdAt != rhs.record.createdAt {
                return lhs.record.createdAt > rhs.record.createdAt
            }
            return lhs.record.id > rhs.record.id
        }
    }

    /// 压缩换行与多余空白，定位首个命中词并居中截取干净单行摘要（必要时首尾加 `…`）
    public static func extractSnippet(
        from text: String,
        terms: [String],
        maxLength: Int = 96
    ) -> String? {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty, maxLength > 0 else { return nil }

        let totalCount = normalized.count
        if totalCount <= maxLength {
            return normalized
        }

        // 查找最早出现的非空检索词
        var earliestRange: Range<String.Index>?
        for term in terms where !term.isEmpty {
            if let range = normalized.range(of: term, options: .caseInsensitive) {
                if let current = earliestRange {
                    if range.lowerBound < current.lowerBound {
                        earliestRange = range
                    }
                } else {
                    earliestRange = range
                }
            }
        }

        guard let matchRange = earliestRange else {
            if maxLength == 1 {
                return String(normalized.prefix(1))
            }
            return String(normalized.prefix(maxLength - 1)) + "…"
        }

        let matchStart = normalized.distance(from: normalized.startIndex, to: matchRange.lowerBound)
        let matchLength = normalized.distance(from: matchRange.lowerBound, to: matchRange.upperBound)

        let rawContextBudget = max(0, maxLength - matchLength)
        let rawStart = max(0, matchStart - rawContextBudget / 2)
        let rawEnd = min(totalCount, rawStart + maxLength)
        let adjustedRawStart = (rawEnd == totalCount) ? max(0, rawEnd - maxLength) : rawStart

        let needsLeading = adjustedRawStart > 0
        let needsTrailing = rawEnd < totalCount
        let ellipsisCost = (needsLeading ? 1 : 0) + (needsTrailing ? 1 : 0)
        let contentBudget = max(1, maxLength - ellipsisCost)

        let sliceStart: Int
        let sliceEnd: Int
        if matchLength >= contentBudget {
            sliceStart = matchStart
            sliceEnd = min(totalCount, matchStart + contentBudget)
        } else {
            let before = (contentBudget - matchLength) / 2
            var start = max(0, matchStart - before)
            let end = min(totalCount, start + contentBudget)
            if end == totalCount {
                start = max(0, end - contentBudget)
            }
            sliceStart = start
            sliceEnd = end
        }

        let startIndex = normalized.index(normalized.startIndex, offsetBy: sliceStart)
        let endIndex = normalized.index(normalized.startIndex, offsetBy: sliceEnd)
        var snippet = String(normalized[startIndex..<endIndex])

        if sliceStart > 0 {
            snippet = "…" + snippet
        }
        if sliceEnd < totalCount {
            snippet += "…"
        }
        return snippet
    }
}
