import CoreGraphics
import Vision

/// 单条 OCR 识别结果（Sendable 值类型，跨线程传递）。
///
/// 坐标为图像归一化坐标（0~1），且已把 Vision 的左下原点翻转为左上原点，
/// 便于按视觉阅读顺序（先上后下）排序。
struct OCRTextItem: Sendable {
    let text: String
    let minX: Double
    let minY: Double
    let maxY: Double
}

/// OCR 取字（Vision 本地离线识别，docs/05 §OCR：不引入外部模型管理）。
enum TextRecognizer {
    /// 对图像做本地离线 OCR。
    ///
    /// - VNRecognizeTextRequest，recognitionLevel = .accurate，
    ///   recognitionLanguages = ["zh-Hans", "en-US"]，usesLanguageCorrection = true
    /// - 结果按视觉阅读顺序拼接：先上后下分行，行内左到右
    /// - 空结果不抛错，返回空字符串
    /// - 成功打 `ocr.done`（ms / chars），失败打 `ocr.fail` 并返回空串
    static func recognize(_ image: CGImage) async throws -> String {
        let start = ContinuousClock.now
        do {
            let items = try await runRecognition(image)
            let text = OCRTextAssembler.assemble(items)
            let ms = elapsedMs(since: start)
            Log.event(.ocr, "ocr.done", ["ms": ms, "chars": "\(text.count)"])
            return text
        } catch {
            Log.error(.ocr, "ocr.fail", ["err": "\(error.localizedDescription)"])
            return ""
        }
    }

    /// 结构化识别：同一 Vision Handler 内并行识别文字块与二维码，并尝试提取 Markdown 表格。
    static func recognizeStructured(_ image: CGImage) async throws -> StructuredOCRResult {
        let start = ContinuousClock.now
        do {
            let (blocks, qrPayloads) = try await runStructuredRecognition(image)
            let items = blocks.map {
                OCRTextItem(text: $0.text, minX: $0.minX, minY: $0.minY, maxY: $0.maxY)
            }
            let plainText = OCRTextAssembler.assemble(items)
            let qrCodes = qrPayloads.map(StructuredOCRFormatter.makeQRCode(payload:))
            let table = StructuredOCRFormatter.detectMarkdownTable(from: blocks)
            let ms = elapsedMs(since: start)
            Log.event(.ocr, "ocr.structured.done", [
                "ms": ms,
                "chars": "\(plainText.count)",
                "qrs": "\(qrCodes.count)",
                "table": table != nil ? "\(table!.rows)x\(table!.columns)" : "none",
            ])
            return StructuredOCRResult(
                plainText: plainText,
                qrCodes: qrCodes,
                markdownTable: table?.markdown,
                tableRowCount: table?.rows ?? 0,
                tableColumnCount: table?.columns ?? 0
            )
        } catch {
            Log.error(.ocr, "ocr.structured.fail", ["err": "\(error.localizedDescription)"])
            return StructuredOCRResult(
                plainText: "",
                qrCodes: [],
                markdownTable: nil,
                tableRowCount: 0,
                tableColumnCount: 0
            )
        }
    }

    /// 检测图中全部敏感信息的精确词级包围盒（100% 本地离线 Vision + Core 规则引擎）。
    ///
    /// 关闭语言自动纠错（usesLanguageCorrection = false），防止 Vision 把 API Key、
    /// 邮箱、Token 或 IP 地址强行纠错为英文单词；并通过 `candidate.boundingBox(for:)`
    /// 获取命中的精确子串坐标，绝不误盖同行其余正常文字。
    static func detectSensitiveRegions(_ image: CGImage) async throws -> [DetectedSensitiveRegion] {
        let start = ContinuousClock.now
        do {
            let regions = try await runSensitiveDetection(image)
            let ms = elapsedMs(since: start)
            Log.event(.ocr, "redact.detect", ["ms": ms, "matches": "\(regions.count)"])
            return regions
        } catch {
            Log.error(.ocr, "redact.detect.fail", ["err": "\(error.localizedDescription)"])
            return []
        }
    }

    private static func runSensitiveDetection(_ image: CGImage) async throws -> [DetectedSensitiveRegion] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = false
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    var regions: [DetectedSensitiveRegion] = []
                    for observation in request.results ?? [] {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let text = candidate.string
                        let matches = SensitiveTextDetector.detectRanges(in: text)
                        guard !matches.isEmpty else { continue }

                        let lineBox = observation.boundingBox
                        let totalChars = max(1, text.count)

                        for match in matches {
                            let visionRect: CGRect
                            if let exact = try? candidate.boundingBox(for: match.range)?.boundingBox,
                               exact.width > 0.001, exact.height > 0.001 {
                                visionRect = exact
                            } else {
                                // 兜底：若 Vision 无法返回子串框，按字符偏移比例在行框内线性切分
                                let startOffset = text.distance(from: text.startIndex, to: match.range.lowerBound)
                                let matchLen = max(1, text.distance(from: match.range.lowerBound, to: match.range.upperBound))
                                let fracStart = CGFloat(startOffset) / CGFloat(totalChars)
                                let fracWidth = CGFloat(matchLen) / CGFloat(totalChars)
                                visionRect = CGRect(
                                    x: lineBox.minX + lineBox.width * fracStart,
                                    y: lineBox.minY,
                                    width: lineBox.width * fracWidth,
                                    height: lineBox.height
                                )
                            }
                            // Vision 原点左下（Y-up）→ 统一转为左上原点（Y-down）归一化矩形
                            let topLeftRect = CGRect(
                                x: visionRect.minX,
                                y: 1.0 - visionRect.maxY,
                                width: visionRect.width,
                                height: visionRect.height
                            )
                            regions.append(DetectedSensitiveRegion(kind: match.kind, normalizedRect: topLeftRect))
                        }
                    }
                    continuation.resume(returning: regions)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 识别跑在全局并发队列（Vision 的 perform 是同步阻塞调用，不占协作线程池）。
    /// 返回值是 Sendable 值类型数组，安全跨隔离域。
    private static func runRecognition(_ image: CGImage) async throws -> [OCRTextItem] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = true
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    let items: [OCRTextItem] = (request.results ?? []).compactMap { observation -> OCRTextItem? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        // VNRecognizedText 上 boundingBox 解析到同名方法 boundingBox(for:)，
                        // 直接用 observation 自身的 boundingBox（同一矩形区域）
                        let bb = observation.boundingBox
                        // Vision 坐标系：原点在图像左下 → 翻转为距顶部的 minY
                        return OCRTextItem(
                            text: candidate.string,
                            minX: Double(bb.minX),
                            minY: Double(1 - bb.maxY),
                            maxY: Double(1 - bb.minY)
                        )
                    }
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runStructuredRecognition(
        _ image: CGImage
    ) async throws -> (blocks: [OCRPositionedBlock], qrPayloads: [String]) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let textRequest = VNRecognizeTextRequest()
                    textRequest.recognitionLevel = .accurate
                    textRequest.recognitionLanguages = ["zh-Hans", "en-US"]
                    textRequest.usesLanguageCorrection = true

                    let barcodeRequest = VNDetectBarcodesRequest()
                    barcodeRequest.symbologies = [.qr]

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([textRequest, barcodeRequest])

                    let blocks: [OCRPositionedBlock] = (textRequest.results ?? []).compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        let bb = observation.boundingBox
                        return OCRPositionedBlock(
                            text: candidate.string,
                            minX: Double(bb.minX),
                            maxX: Double(bb.maxX),
                            minY: Double(1 - bb.maxY),
                            maxY: Double(1 - bb.minY)
                        )
                    }

                    var seenPayloads: Set<String> = []
                    var qrPayloads: [String] = []
                    for observation in barcodeRequest.results ?? [] {
                        guard let raw = observation.payloadStringValue else { continue }
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, seenPayloads.insert(trimmed).inserted else { continue }
                        qrPayloads.append(trimmed)
                    }

                    continuation.resume(returning: (blocks: blocks, qrPayloads: qrPayloads))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> String {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        let ms = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        return String(format: "%.0f", ms)
    }
}

/// 阅读顺序拼装：先上后下分行（垂直区间明显重叠视为同一行），行内左到右。
enum OCRTextAssembler {
    static func assemble(_ items: [OCRTextItem]) -> String {
        guard !items.isEmpty else { return "" }

        // 按顶部 y 升序（Vision 翻转后 minY 越小越靠上），同高再按 x
        let sorted = items.sorted {
            ($0.minY, $0.minX) < ($1.minY, $1.minX)
        }

        var lines: [[OCRTextItem]] = []
        var current: [OCRTextItem] = []
        for item in sorted {
            if let last = current.last, sameLine(last, item) {
                current.append(item)
            } else {
                if !current.isEmpty { lines.append(current) }
                current = [item]
            }
        }
        if !current.isEmpty { lines.append(current) }

        return lines
            .map { line in
                line.sorted { $0.minX < $1.minX }
                    .map(\.text)
                    .reduce(into: "") { joined, segment in join(&joined, segment) }
            }
            .joined(separator: "\n")
    }

    /// 垂直重叠超过两者较矮高度的 50% 视为同一行
    private static func sameLine(_ a: OCRTextItem, _ b: OCRTextItem) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap > 0 else { return false }
        let shorter = min(a.maxY - a.minY, b.maxY - b.minY)
        return shorter > 0 && overlap > 0.5 * shorter
    }

    /// 行内拼接：相邻段任一侧是 CJK 时不加空格（中文 OCR 断行不该引入空格），否则空格分隔
    private static func join(_ joined: inout String, _ segment: String) {
        if let last = joined.last, isCJK(last) || firstScalar(of: segment).map(isCJK) == true {
            joined += segment
        } else if joined.isEmpty {
            joined = segment
        } else {
            joined += " " + segment
        }
    }

    private static func firstScalar(of string: String) -> Character? {
        string.first
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
