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
