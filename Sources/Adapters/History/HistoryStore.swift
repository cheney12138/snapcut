import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - 存储路径（非隔离常量，后台任务可直接使用）

private enum HistoryPaths {
    /// ~/Library/Application Support/Snapcut/history/
    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snapcut/history", isDirectory: true)
    /// 索引文件：目录里每张 png 的元数据（尺寸/时间/来源/OCR/可重编标记）都记在这里
    static let indexURL = directory.appendingPathComponent("index.json")

    static func imageURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).png")
    }

    static func baseImageURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).base.png")
    }

    static func annotationsURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).annotations.json")
    }
}

// MARK: - 索引条目（index.json 的 Codable 形态，CGSize 拆成宽高）

private struct HistoryIndexEntry: Codable, Sendable {
    let id: String
    let date: Date
    let width: CGFloat
    let height: CGFloat
    var sourceApp: String?
    var windowTitle: String?
    var ocrText: String
    var hasEditableAnnotations: Bool

    init(
        id: String,
        date: Date,
        width: CGFloat,
        height: CGFloat,
        sourceApp: String? = nil,
        windowTitle: String? = nil,
        ocrText: String = "",
        hasEditableAnnotations: Bool = false
    ) {
        self.id = id
        self.date = date
        self.width = width
        self.height = height
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.ocrText = ocrText
        self.hasEditableAnnotations = hasEditableAnnotations
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case width
        case height
        case sourceApp
        case windowTitle
        case ocrText
        case hasEditableAnnotations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        width = try container.decode(CGFloat.self, forKey: .width)
        height = try container.decode(CGFloat.self, forKey: .height)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText) ?? ""
        hasEditableAnnotations = try container.decodeIfPresent(Bool.self, forKey: .hasEditableAnnotations) ?? false
    }

    var pixelSize: CGSize { CGSize(width: width, height: height) }
    var fileURL: URL { HistoryPaths.imageURL(for: id) }
}

/// 历史记录（docs/03 §10 + v0.3 M2 视觉记忆库）：
/// - PNG 落盘 + index.json 索引（向后兼容旧版 4 字段 JSON）
/// - 最近 20 条可重编标注保留 `<id>.base.png` + `<id>.annotations.json` sidecar
/// - 低优先级串行后台 OCR 索引队列，不阻塞前台截图与主线程
///
/// 线程模型（Swift 6 strict concurrency）：
/// - `@MainActor` 只维护内存索引 `itemsCache`（新 → 旧）；
/// - PNG 编码、落盘、sidecar 写入、文件删除、index.json 写回与 OCR 全部走后台 Task；
/// - `record` 失败只写日志，绝不抛错打断截图流程；
/// - index.json 写回经 `indexWriteTask` 串行链，避免后台并发互相覆盖；
/// - 增量 OCR 经 `ocrQueueTask` 串行链，启动补齐经 `backfillTask` 低优先级逐条串行。
@MainActor
final class HistoryStore {

    static let shared = HistoryStore()

    struct Item: Identifiable, Sendable {
        let id: String
        let date: Date
        let pixelSize: CGSize
        let url: URL
        var sourceApp: String? = nil
        var windowTitle: String? = nil
        var ocrText: String = ""
        var hasEditableAnnotations: Bool = false

        var record: HistoryRecord {
            HistoryRecord(
                id: id,
                createdAt: date,
                width: Int(pixelSize.width.rounded()),
                height: Int(pixelSize.height.rounded()),
                sourceApp: sourceApp,
                windowTitle: windowTitle,
                ocrText: ocrText,
                hasEditableAnnotations: hasEditableAnnotations
            )
        }
    }

    /// 保留上限，超出删最旧（成品 PNG、sidecar 与索引条目一起删）
    /// 保留条数（由设置面板配置，默认 30）
    var maxItems = 30 {
        didSet {
            thumbnailCache.countLimit = max(1, maxItems * 2)
        }
    }

    /// 可重编矢量标注 sidecar（.base.png + .annotations.json）保留上限
    var maxEditableItems = 20

    /// 外部注入的文字识别端口（严禁在 HistoryStore 直接 import Vision）
    var textRecognizer: (any TextRecognizing)?

    /// 导出后是否自动后台执行本地 OCR 文本索引
    var autoIndexOCREnabled: Bool = true

    /// 条目新增、清空或后台 OCR 回填完成时在 MainActor 通知 UI（如刷新 Spotlight 面板）
    var onItemsChanged: (() -> Void)?

    /// 内存索引（新 → 旧），MainActor 独占
    private var itemsCache: [Item] = []

    /// 缩略图缓存（key = id#maxSize）
    private let thumbnailCache = NSCache<NSString, NSImage>()

    /// index.json 后台写回的串行链（后一次写等前一次完成，快照永不乱序）
    private var indexWriteTask: Task<Void, Never>?

    /// 增量 OCR 后台串行队列（低优先级 .utility）
    private var ocrQueueTask: Task<Void, Never>?

    /// 启动后低优先级补齐存量缺失 OCR 的后台任务
    private var backfillTask: Task<Void, Never>?

    /// 首屏缩略图后台静默预热任务（冷启动延迟触发，可被新一轮预热取消）
    private var prewarmTask: Task<Void, Never>?

    private init() {
        thumbnailCache.countLimit = max(1, maxItems * 2)
        if let entries = Self.readIndexEntries() {
            // 索引可用：同步读保证 items() 首次调用即有数据；
            // png 已被用户手动删掉的条目直接丢弃并回写索引；
            // sidecar 被删的条目自动修正 hasEditableAnnotations
            var needsPersist = false
            let valid = entries.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
            if valid.count != entries.count { needsPersist = true }

            itemsCache = valid.map { entry in
                var item = Self.item(from: entry)
                if item.hasEditableAnnotations && !Self.hasEditableSidecar(id: item.id) {
                    item.hasEditableAnnotations = false
                    needsPersist = true
                }
                return item
            }
            itemsCache.sort { $0.date > $1.date }

            let prunedSidecars = pruneEditableSidecarsIfNeeded()
            if !prunedSidecars.isEmpty {
                needsPersist = true
                deleteFiles(prunedSidecars)
            }
            if needsPersist { persistIndex() }
            Log.event(.history, "history.load", ["count": "\(itemsCache.count)", "source": "index"])
        } else {
            // 索引缺失/损坏：后台扫描目录里的 png 按文件时间重建，不阻塞启动
            Log.event(.history, "history.load", ["count": "0", "source": "rebuild"])
            Task.detached(priority: .utility) { [weak self] in
                let rebuilt = Self.rebuildEntriesFromDirectory()
                await self?.adoptRebuilt(rebuilt)
            }
        }
    }

    // MARK: - 公开 API

    /// 记录一张截图：转发到带可选元数据的版本
    func record(_ image: CGImage) {
        record(image, metadata: nil)
    }

    /// 记录一张截图（含可选来源/底图/可重编标注）：后台编码落盘 → 更新索引 → 排队静默 OCR
    func record(_ image: CGImage, metadata: HistoryCaptureMetadata?) {
        let date = Date()
        let id = Self.makeID(date: date)
        let url = HistoryPaths.imageURL(for: id)
        let width = image.width
        let height = image.height
        let sourceApp = Self.normalizedOptionalText(metadata?.sourceApp)
        let windowTitle = Self.normalizedOptionalText(metadata?.windowTitle)
        let baseImage = metadata?.baseImage
        let canvasSize = metadata?.canvasSize
        let annotations = metadata?.annotations ?? []
        let strokeWidth = metadata?.strokeWidth ?? 2
        let dpi = Self.preferredRetinaDPI(forCanvasWidth: canvasSize?.width, pixelWidth: width)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = Self.encodePNG(image, dpi: dpi) else {
                Log.error(.history, "history.record.encode_fail", ["id": id])
                return
            }
            do {
                // 目录不存在自动创建
                try FileManager.default.createDirectory(
                    at: HistoryPaths.directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.error(.history, "history.record.write_fail", [
                    "id": id, "err": error.localizedDescription,
                ])
                return
            }

            var hasEditableAnnotations = false
            if let baseImage,
               let canvasSize,
               canvasSize.width > 0,
               canvasSize.height > 0,
               !annotations.isEmpty {
                hasEditableAnnotations = Self.writeEditableSidecar(
                    id: id,
                    baseImage: baseImage,
                    canvasSize: canvasSize,
                    annotations: annotations,
                    strokeWidth: strokeWidth
                )
            }

            await self?.commit(
                id: id,
                date: date,
                width: width,
                height: height,
                bytes: data.count,
                sourceApp: sourceApp,
                windowTitle: windowTitle,
                hasEditableAnnotations: hasEditableAnnotations,
                imageForOCR: image
            )
        }
    }

    /// 当前历史（新 → 旧）
    func items() -> [Item] {
        itemsCache
    }

    /// 当前历史纯领域记录（新 → 旧）
    func records() -> [HistoryRecord] {
        itemsCache.map(\.record)
    }

    /// 按 id 查找历史条目
    func item(for id: String) -> Item? {
        itemsCache.first { $0.id == id }
    }

    /// 内存级多字段历史检索（OCR 文本 / 应用名 / 窗口标题 / 尺寸 / 日期）
    func search(query: String) -> [HistorySearchMatch] {
        HistorySearch.filter(records(), query: query)
    }

    /// 从 `<id>.png` 解码完整原图
    func loadFullImage(for id: String) -> CGImage? {
        let url = HistoryPaths.imageURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let image = Self.decodeCGImage(at: url) else {
            Log.error(.history, "history.load_image.fail", ["id": id])
            return nil
        }
        return image
    }

    /// 记录主图片文件路径（`<id>.png`，用于拖出到 Finder/飞书等）；文件不存则返回 nil
    func imageFileURL(for id: String) -> URL? {
        let url = HistoryPaths.imageURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 读取可重编会话（`<id>.base.png` + `<id>.annotations.json`）；任一缺失或损坏返回 `nil`
    func loadEditableSession(for id: String) -> (baseImage: CGImage, payload: EditableSessionPayload)? {
        let baseURL = HistoryPaths.baseImageURL(for: id)
        let annotationsURL = HistoryPaths.annotationsURL(for: id)
        guard FileManager.default.fileExists(atPath: baseURL.path),
              FileManager.default.fileExists(atPath: annotationsURL.path),
              let baseImage = Self.decodeCGImage(at: baseURL),
              let data = try? Data(contentsOf: annotationsURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(EditableSessionPayload.self, from: data) else {
            Log.error(.history, "history.editable.decode_fail", ["id": id])
            return nil
        }
        return (baseImage, payload)
    }

    /// 把指定历史条目复制到系统剪贴板（PNG + TIFF 双表示，对齐 ClipboardWriter）
    func copyToPasteboard(_ item: Item) -> Bool {
        guard let pngData = try? Data(contentsOf: item.url),
              let rep = NSBitmapImageRep(data: pngData) else {
            Log.error(.history, "history.copy.read_fail", ["id": item.id])
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var written: [String] = []
        if pasteboard.setData(pngData, forType: .png) { written.append("png") }
        if let tiffData = rep.tiffRepresentation,
           pasteboard.setData(tiffData, forType: .tiff) {
            written.append("tiff")
        }
        let ok = !written.isEmpty
        // 自写标记：剪贴板图片感知据此跳过 Snapcut 自己写的内容（否则自己触发自己）
        if ok { ClipboardWriter.markOwnWrite() }
        Log.event(.history, "history.copy", [
            "id": item.id, "fmts": written.joined(separator: "+"), "ok": "\(ok)",
        ])
        return ok
    }

    /// 按 id 把历史图片复制到系统剪贴板（便捷封装）
    @discardableResult
    func copyToPasteboard(id: String) -> Bool {
        if let existing = item(for: id) {
            return copyToPasteboard(existing)
        }
        let url = HistoryPaths.imageURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.error(.history, "history.copy.missing", ["id": id])
            return false
        }
        let fallback = Item(id: id, date: Date(), pixelSize: .zero, url: url)
        return copyToPasteboard(fallback)
    }

    /// 一键清空：内存索引立即置空，磁盘删除放后台
    func clearAll() {
        let removed = itemsCache.count
        itemsCache = []
        thumbnailCache.removeAllObjects()
        prewarmTask?.cancel()
        prewarmTask = nil
        backfillTask?.cancel()
        backfillTask = nil
        ocrQueueTask?.cancel()
        ocrQueueTask = nil
        Log.event(.history, "history.clear", ["removed": "\(removed)"])
        onItemsChanged?()
        let previous = indexWriteTask
        indexWriteTask = Task.detached(priority: .utility) {
            await previous?.value
            let fm = FileManager.default
            if let children = try? fm.contentsOfDirectory(
                at: HistoryPaths.directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles) {
                for child in children { try? fm.removeItem(at: child) }
            }
        }
    }

    /// 缩略图（CGImageSource 按需解码 + NSCache 缓存）
    func thumbnail(for item: Item, maxSize: CGFloat) -> NSImage? {
        thumbnail(forRecordID: item.id, pixelSize: item.pixelSize, maxSize: maxSize)
    }

    /// 纯内存查询缩略图（0 磁盘 I/O）：只查 thumbnailCache，未命中直接返回 `nil`
    ///
    /// Spotlight 面板同步布局阶段只能调它 —— 绝不在主线程解码磁盘 PNG（冷启动首开卡顿 1.46s 的根因）。
    func cachedThumbnail(forRecordID id: String, maxSize: CGFloat) -> NSImage? {
        thumbnailCache.object(forKey: Self.thumbnailCacheKey(id: id, maxSize: maxSize))
    }

    /// 按记录 ID 取缩略图（同步版本：命中缓存直接返回，否则当前线程解码）
    ///
    /// 仍保留给托盘菜单等既有调用点（零回归）；有 UI 交互的调用点应改用 `loadThumbnailAsync`。
    func thumbnail(forRecordID id: String, pixelSize: CGSize, maxSize: CGFloat) -> NSImage? {
        let key = Self.thumbnailCacheKey(id: id, maxSize: maxSize)
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        guard let decoded = Self.decodeThumbnailCGImage(
            url: HistoryPaths.imageURL(for: id),
            pixelSize: pixelSize,
            maxSize: maxSize
        ) else {
            Log.error(.history, "history.thumb.fail", ["id": id])
            return nil
        }
        let image = NSImage(cgImage: decoded.cgImage, size: decoded.targetSize)
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// 异步缩略图：先查纯内存缓存，未命中在后台 `.userInitiated` 解码，回主线程建 NSImage 并写缓存
    ///
    /// 跨 actor 只传 Sendable 的 CGImage + NSSize，NSImage 始终在 MainActor 上创建。
    func loadThumbnailAsync(
        forRecordID id: String,
        pixelSize: CGSize,
        maxSize: CGFloat
    ) async -> NSImage? {
        if let cached = cachedThumbnail(forRecordID: id, maxSize: maxSize) { return cached }

        guard let decoded = await Self.decodeThumbnailOffMain(
            url: HistoryPaths.imageURL(for: id),
            pixelSize: pixelSize,
            maxSize: maxSize
        ) else {
            Log.error(.history, "history.thumb.fail", ["id": id, "async": "1"])
            return nil
        }
        guard !Task.isCancelled else { return nil }
        // 解码期间可能有别的调用先写入了缓存，以先到者为准，避免重复替换造成重绘
        if let existing = cachedThumbnail(forRecordID: id, maxSize: maxSize) { return existing }

        let image = NSImage(cgImage: decoded.cgImage, size: decoded.targetSize)
        thumbnailCache.setObject(image, forKey: Self.thumbnailCacheKey(id: id, maxSize: maxSize))
        return image
    }

    /// 后台静默预热首屏缩略图（冷启动后由 AppCoordinator 延迟 1.2s 调用）
    ///
    /// 逐张低优先级解码，张与张之间 30ms 间隔，绝不与前台交互抢 CPU；新一轮预热会取消上一轮。
    func prewarmThumbnails(limit: Int = 9, maxSize: CGFloat = 440) {
        prewarmTask?.cancel()
        prewarmTask = nil

        var candidates: [(id: String, pixelSize: CGSize)] = []
        for item in itemsCache.prefix(max(0, limit)) {
            guard cachedThumbnail(forRecordID: item.id, maxSize: maxSize) == nil else { continue }
            candidates.append((item.id, item.pixelSize))
        }
        guard !candidates.isEmpty else { return }

        prewarmTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runPrewarm(candidates, maxSize: maxSize)
        }
    }

    /// 预热实际执行体（MainActor 隔离，解码在后台，写缓存在主线程）
    private func runPrewarm(_ candidates: [(id: String, pixelSize: CGSize)], maxSize: CGFloat) async {
        for (offset, candidate) in candidates.enumerated() {
            if Task.isCancelled { break }
            if offset > 0 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                if Task.isCancelled { break }
            }
            guard let decoded = await Self.decodeThumbnailOffMain(
                url: HistoryPaths.imageURL(for: candidate.id),
                pixelSize: candidate.pixelSize,
                maxSize: maxSize
            ) else { continue }
            guard !Task.isCancelled else { break }

            let image = NSImage(cgImage: decoded.cgImage, size: decoded.targetSize)
            thumbnailCache.setObject(
                image,
                forKey: Self.thumbnailCacheKey(id: candidate.id, maxSize: maxSize)
            )
            await Task.yield()
        }
        // 被新一轮预热/clearAll 取消说明引用已被替换，不要清空别人刚注册的任务
        if !Task.isCancelled { prewarmTask = nil }
    }

    /// 启动后低优先级懒补齐尚未有 OCR 文本的存量记录（逐条串行、间隔 150ms、可中途取消）
    func backfillMissingOCRIfNeeded() {
        guard autoIndexOCREnabled, let recognizer = textRecognizer else { return }
        guard backfillTask == nil else { return }

        let candidateIDs = itemsCache
            .filter { $0.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.id)
        guard !candidateIDs.isEmpty else { return }

        backfillTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            for (offset, id) in candidateIDs.enumerated() {
                if Task.isCancelled { break }
                let canContinue = await MainActor.run {
                    self.autoIndexOCREnabled && self.textRecognizer != nil
                }
                guard canContinue else { break }

                if offset > 0 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { break }
                    let stillEnabled = await MainActor.run {
                        self.autoIndexOCREnabled && self.textRecognizer != nil
                    }
                    guard stillEnabled else { break }
                }

                // 若前台新截图正在做增量 OCR，等它完成后再执行，避免后台抢占 Vision CPU
                if let pendingOCR = await MainActor.run(body: { self.ocrQueueTask }) {
                    await pendingOCR.value
                    if Task.isCancelled { break }
                }

                let stillNeedsOCR = await MainActor.run {
                    guard self.autoIndexOCREnabled,
                          let item = self.itemsCache.first(where: { $0.id == id }) else {
                        return false
                    }
                    return item.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard stillNeedsOCR else { continue }

                guard let image = Self.decodeCGImage(at: HistoryPaths.imageURL(for: id)) else {
                    continue
                }

                do {
                    let raw = try await recognizer.recognize(image)
                    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    await self.applyBackfillOCRResult(id: id, text: normalized)
                } catch {
                    Log.error(.history, "history.ocr.fail", ["id": id, "err": error.localizedDescription])
                }
            }

            await MainActor.run {
                self.backfillTask = nil
            }
        }
    }

    // MARK: - 私有：索引状态维护（MainActor）

    /// 落盘成功后并入内存索引（后台任务完成顺序不定，按时间排序兜底）
    private func commit(
        id: String,
        date: Date,
        width: Int,
        height: Int,
        bytes: Int,
        sourceApp: String?,
        windowTitle: String?,
        hasEditableAnnotations: Bool,
        imageForOCR: CGImage
    ) {
        let item = Item(
            id: id,
            date: date,
            pixelSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
            url: HistoryPaths.imageURL(for: id),
            sourceApp: sourceApp,
            windowTitle: windowTitle,
            ocrText: "",
            hasEditableAnnotations: hasEditableAnnotations
        )
        itemsCache.insert(item, at: 0)
        itemsCache.sort { $0.date > $1.date }
        let evicted = pruneIfNeeded()
        let evictedSidecars = pruneEditableSidecarsIfNeeded()
        Log.event(.history, "history.record", [
            "id": id,
            "count": "\(itemsCache.count)",
            "bytes": "\(bytes)",
            "editable": "\(hasEditableAnnotations)",
        ])
        if !evicted.isEmpty {
            Log.event(.history, "history.pruned", ["removed": "\(evicted.count)"])
        }
        if !evictedSidecars.isEmpty {
            Log.event(.history, "history.sidecar.pruned", ["removed": "\(evictedSidecars.count)"])
        }
        deleteFiles(evicted + evictedSidecars)
        persistIndex()
        onItemsChanged?()
        enqueueOCRIfNeeded(id: id, image: imageForOCR)
    }

    /// 为新落盘的条目排队执行低优先级串行 OCR 索引
    private func enqueueOCRIfNeeded(id: String, image: CGImage) {
        guard autoIndexOCREnabled, let recognizer = textRecognizer else { return }
        let previous = ocrQueueTask
        ocrQueueTask = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            guard let self else { return }
            let shouldRun = await MainActor.run {
                self.autoIndexOCREnabled && self.itemsCache.contains { $0.id == id }
            }
            guard shouldRun else { return }

            do {
                let raw = try await recognizer.recognize(image)
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                await self.applyOCRResult(id: id, text: normalized)
            } catch {
                Log.error(.history, "history.ocr.fail", ["id": id, "err": error.localizedDescription])
            }
        }
    }

    /// 增量 OCR 完成后回填内存索引并通知 UI
    private func applyOCRResult(id: String, text: String) {
        guard let idx = itemsCache.firstIndex(where: { $0.id == id }) else { return }
        itemsCache[idx].ocrText = text
        Log.event(.history, "history.ocr.indexed", ["id": id, "chars": "\(text.count)"])
        persistIndex()
        onItemsChanged?()
    }

    /// 存量补齐 OCR 结果回填（仅当非空或首次记录时落盘并通知 UI）
    private func applyBackfillOCRResult(id: String, text: String) {
        guard autoIndexOCREnabled else { return }
        guard let idx = itemsCache.firstIndex(where: { $0.id == id }) else { return }
        if text.isEmpty {
            Log.event(.history, "history.ocr.indexed", ["id": id, "chars": "0"])
            return
        }
        itemsCache[idx].ocrText = text
        Log.event(.history, "history.ocr.indexed", ["id": id, "chars": "\(text.count)"])
        persistIndex()
        onItemsChanged?()
    }

    /// 超出保留上限删最旧（只摘内存条目，成品 PNG + sidecar 文件删除交给 deleteFiles）
    private func pruneIfNeeded() -> [URL] {
        var evicted: [URL] = []
        let limit = max(1, maxItems)
        while itemsCache.count > limit {
            let removed = itemsCache.removeLast()
            evicted.append(removed.url)
            evicted.append(HistoryPaths.baseImageURL(for: removed.id))
            evicted.append(HistoryPaths.annotationsURL(for: removed.id))
        }
        return evicted
    }

    /// 可重编 sidecar 最多保留最近 `maxEditableItems` 条；超出条目清理 sidecar 并保留成品 PNG 与 OCR
    private func pruneEditableSidecarsIfNeeded() -> [URL] {
        var urlsToDelete: [URL] = []
        var editableCount = 0
        let editableLimit = max(0, maxEditableItems)
        for index in itemsCache.indices where itemsCache[index].hasEditableAnnotations {
            editableCount += 1
            if editableCount > editableLimit {
                let id = itemsCache[index].id
                itemsCache[index].hasEditableAnnotations = false
                urlsToDelete.append(HistoryPaths.baseImageURL(for: id))
                urlsToDelete.append(HistoryPaths.annotationsURL(for: id))
            }
        }
        return urlsToDelete
    }

    /// 后台删除被逐出条目的文件
    private func deleteFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// 把内存索引快照交给后台串行链写回 index.json
    private func persistIndex() {
        let entries = itemsCache.map {
            HistoryIndexEntry(
                id: $0.id,
                date: $0.date,
                width: $0.pixelSize.width,
                height: $0.pixelSize.height,
                sourceApp: $0.sourceApp,
                windowTitle: $0.windowTitle,
                ocrText: $0.ocrText,
                hasEditableAnnotations: $0.hasEditableAnnotations
            )
        }
        let previous = indexWriteTask
        indexWriteTask = Task.detached(priority: .utility) {
            await previous?.value
            Self.writeIndexSync(entries)
        }
    }

    /// 启动期索引缺失/损坏时的后台重建结果并入内存索引
    private func adoptRebuilt(_ rebuilt: [HistoryIndexEntry]) {
        var byID = [String: Item](uniqueKeysWithValues: itemsCache.map { ($0.id, $0) })
        for entry in rebuilt where byID[entry.id] == nil {
            byID[entry.id] = Self.item(from: entry)
        }
        itemsCache = byID.values.sorted { $0.date > $1.date }
        let evicted = pruneIfNeeded()
        let evictedSidecars = pruneEditableSidecarsIfNeeded()
        deleteFiles(evicted + evictedSidecars)
        Log.event(.history, "history.index.rebuilt", ["count": "\(itemsCache.count)"])
        persistIndex()
        onItemsChanged?()
    }

    // MARK: - 私有：条目换算（MainActor）

    private static func item(from entry: HistoryIndexEntry) -> Item {
        Item(
            id: entry.id,
            date: entry.date,
            pixelSize: entry.pixelSize,
            url: entry.fileURL,
            sourceApp: entry.sourceApp,
            windowTitle: entry.windowTitle,
            ocrText: entry.ocrText,
            hasEditableAnnotations: entry.hasEditableAnnotations
        )
    }

    // MARK: - 私有：磁盘 / 编码（非隔离静态，供后台任务直接使用）

    private nonisolated static func normalizedOptionalText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private nonisolated static func hasEditableSidecar(id: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: HistoryPaths.baseImageURL(for: id).path)
            && fm.fileExists(atPath: HistoryPaths.annotationsURL(for: id).path)
    }

    private nonisolated static func writeEditableSidecar(
        id: String,
        baseImage: CGImage,
        canvasSize: CGSize,
        annotations: [AnnotationModel],
        strokeWidth: CGFloat
    ) -> Bool {
        let baseURL = HistoryPaths.baseImageURL(for: id)
        let annotationsURL = HistoryPaths.annotationsURL(for: id)

        guard let baseData = encodePNG(baseImage) else {
            Log.error(.history, "history.sidecar.encode_fail", ["id": id])
            return false
        }

        do {
            let payload = EditableSessionPayload(
                canvasSize: canvasSize,
                annotations: annotations,
                strokeWidth: strokeWidth
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payloadData = try encoder.encode(payload)

            try baseData.write(to: baseURL, options: .atomic)
            try payloadData.write(to: annotationsURL, options: .atomic)
            return true
        } catch {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: annotationsURL)
            Log.error(.history, "history.sidecar.write_fail", [
                "id": id, "err": error.localizedDescription,
            ])
            return false
        }
    }

    private nonisolated static func decodeCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private nonisolated static func thumbnailCacheKey(id: String, maxSize: CGFloat) -> NSString {
        "\(id)#\(Int(maxSize))" as NSString
    }

    /// 在后台线程解码缩略图（线程安全：不碰 NSImage，只返回 Sendable 的 CGImage + 目标尺寸）
    private nonisolated static func decodeThumbnailCGImage(
        url: URL,
        pixelSize: CGSize,
        maxSize: CGFloat
    ) -> (cgImage: CGImage, targetSize: NSSize)? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxSize * 2), // Retina 2x 像素密度
            kCGImageSourceShouldCacheImmediately: true,
        ] as [CFString: Any] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        let referenceSize: CGSize
        if pixelSize.width > 0 && pixelSize.height > 0 {
            referenceSize = pixelSize
        } else {
            referenceSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        }
        let aspect = min(
            maxSize / max(1, referenceSize.width),
            maxSize / max(1, referenceSize.height)
        )
        let targetSize = NSSize(
            width: max(1, referenceSize.width * aspect),
            height: max(1, referenceSize.height * aspect)
        )
        return (cgImage, targetSize)
    }

    /// 把上面的同步解码丢到 detached 任务里执行（调用方保持在 MainActor）
    private nonisolated static func decodeThumbnailOffMain(
        url: URL,
        pixelSize: CGSize,
        maxSize: CGFloat
    ) async -> (cgImage: CGImage, targetSize: NSSize)? {
        await Task.detached(priority: .userInitiated) {
            decodeThumbnailCGImage(url: url, pixelSize: pixelSize, maxSize: maxSize)
        }.value
    }

    /// 读 index.json；缺失或损坏返回 nil（触发重建）
    private nonisolated static func readIndexEntries() -> [HistoryIndexEntry]? {
        guard let data = try? Data(contentsOf: HistoryPaths.indexURL), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([HistoryIndexEntry].self, from: data)
    }

    /// 同步写 index.json（原子写；调用方已保证串行）
    private nonisolated static func writeIndexSync(_ entries: [HistoryIndexEntry]) {
        do {
            try FileManager.default.createDirectory(
                at: HistoryPaths.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: HistoryPaths.indexURL, options: .atomic)
        } catch {
            Log.error(.history, "history.index.write_fail", ["err": error.localizedDescription])
        }
    }

    /// 索引缺失/损坏时扫描目录重建：按主图 `<id>.png` 修改时间排序（严格排除 `*.base.png`），
    /// 并探测配对 sidecar 还原 `hasEditableAnnotations`
    private nonisolated static func rebuildEntriesFromDirectory() -> [HistoryIndexEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: HistoryPaths.directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)
        else { return [] }
        let pngs = files.filter { url in
            let filename = url.lastPathComponent.lowercased()
            return url.pathExtension.lowercased() == "png" && !filename.hasSuffix(".base.png")
        }
        return pngs
            .sorted { modifiedAt($0) > modifiedAt($1) }
            .compactMap { url in
                let id = url.deletingPathExtension().lastPathComponent
                guard !id.isEmpty, let size = pixelSize(at: url) else { return nil }
                return HistoryIndexEntry(
                    id: id,
                    date: modifiedAt(url),
                    width: size.width,
                    height: size.height,
                    sourceApp: nil,
                    windowTitle: nil,
                    ocrText: "",
                    hasEditableAnnotations: hasEditableSidecar(id: id)
                )
            }
    }

    private nonisolated static func modifiedAt(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private nonisolated static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// CGImage → PNG Data（ImageIO，不依赖 AppKit，线程安全；写入 Retina DPI 元数据对齐原生截图）
    private nonisolated static func encodePNG(_ image: CGImage, dpi: CGFloat = 144) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let safeDPI = max(72, dpi)
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: safeDPI,
            kCGImagePropertyDPIHeight: safeDPI,
        ]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    private static func preferredRetinaDPI(forCanvasWidth canvasWidth: CGFloat?, pixelWidth: Int) -> CGFloat {
        if let canvasWidth, canvasWidth > 1 {
            let inferredScale = min(4, max(1, (CGFloat(pixelWidth) / canvasWidth).rounded()))
            return inferredScale * 72
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return max(1, screen?.backingScaleFactor ?? 2) * 72
    }

    /// id = ISO8601 时间戳 + 4 位随机大写十六进制后缀（同秒多次截图不冲突）
    private nonisolated static func makeID(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let suffix = String(format: "%04X", Int.random(in: 0..<0x10000))
        return formatter.string(from: date) + "-" + suffix
    }
}
