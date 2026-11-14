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
    /// 索引文件：目录里每张 png 的元数据（尺寸/时间）都记在这里
    static let indexURL = directory.appendingPathComponent("index.json")
}

// MARK: - 索引条目（index.json 的 Codable 形态，CGSize 拆成宽高）

private struct HistoryIndexEntry: Codable, Sendable {
    let id: String
    let date: Date
    let width: CGFloat
    let height: CGFloat

    var pixelSize: CGSize { CGSize(width: width, height: height) }
    var fileURL: URL { HistoryPaths.directory.appendingPathComponent("\(id).png") }
}

/// 历史记录（docs/03 §10：PNG 落盘 + index.json 索引，保留最近 30 条）。
///
/// 线程模型（Swift 6 strict concurrency）：
/// - `@MainActor` 只维护内存索引 `itemsCache`（新 → 旧）；
/// - PNG 编码、落盘、文件删除、index.json 写回全部走后台 Task；
/// - `record` 失败只写日志，绝不抛错打断截图流程；
/// - index.json 写回经 `indexWriteTask` 串行链，避免后台并发互相覆盖。
@MainActor
final class HistoryStore {

    static let shared = HistoryStore()

    struct Item: Identifiable, Sendable {
        let id: String
        let date: Date
        let pixelSize: CGSize
        let url: URL
    }

    /// 保留上限，超出删最旧（PNG 与索引条目一起删）
    static let maxItems = 30

    /// 内存索引（新 → 旧），MainActor 独占
    private var itemsCache: [Item] = []

    /// 缩略图缓存（key = id#maxSize）
    private let thumbnailCache = NSCache<NSString, NSImage>()

    /// index.json 后台写回的串行链（后一次写等前一次完成，快照永不乱序）
    private var indexWriteTask: Task<Void, Never>?

    private init() {
        thumbnailCache.countLimit = Self.maxItems
        if let entries = Self.readIndexEntries() {
            // 索引可用：≤30 条的小 JSON，同步读保证 items() 首次调用即有数据；
            // png 已被用户手动删掉的条目直接丢弃并回写索引
            let valid = entries.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
            itemsCache = valid.map { Self.item(from: $0) }
            if valid.count != entries.count { persistIndex() }
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

    /// 记录一张截图：后台编码 PNG → 落盘 → 更新索引；失败只写日志
    func record(_ image: CGImage) {
        let date = Date()
        let id = Self.makeID(date: date)
        let url = HistoryPaths.directory.appendingPathComponent("\(id).png")
        let width = image.width
        let height = image.height

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = Self.encodePNG(image) else {
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
            await self?.commit(id: id, date: date, width: width, height: height, bytes: data.count)
        }
    }

    /// 当前历史（新 → 旧）
    func items() -> [Item] {
        itemsCache
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
        Log.event(.history, "history.copy", [
            "id": item.id, "fmts": written.joined(separator: "+"), "ok": "\(ok)",
        ])
        return ok
    }

    /// 一键清空：内存索引立即置空，磁盘删除放后台
    func clearAll() {
        let removed = itemsCache.count
        itemsCache = []
        thumbnailCache.removeAllObjects()
        Log.event(.history, "history.clear", ["removed": "\(removed)"])
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
        let key = "\(item.id)#\(Int(maxSize))" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        let maxPixelSize = max(1, maxSize * 2) // Retina 2x 像素密度
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as [CFString: Any] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            Log.error(.history, "history.thumb.fail", ["id": item.id])
            return nil
        }
        let aspect = min(
            maxSize / max(1, item.pixelSize.width),
            maxSize / max(1, item.pixelSize.height)
        )
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: item.pixelSize.width * aspect, height: item.pixelSize.height * aspect)
        )
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - 私有：索引状态维护（MainActor）

    /// 落盘成功后并入内存索引（后台任务完成顺序不定，按时间排序兜底）
    private func commit(id: String, date: Date, width: Int, height: Int, bytes: Int) {
        let item = Item(
            id: id,
            date: date,
            pixelSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
            url: HistoryPaths.directory.appendingPathComponent("\(id).png")
        )
        itemsCache.insert(item, at: 0)
        itemsCache.sort { $0.date > $1.date }
        let evicted = pruneIfNeeded()
        Log.event(.history, "history.record", ["id": id, "count": "\(itemsCache.count)", "bytes": "\(bytes)"])
        if !evicted.isEmpty {
            Log.event(.history, "history.pruned", ["removed": "\(evicted.count)"])
        }
        deleteFiles(evicted)
        persistIndex()
    }

    /// 超出保留上限删最旧（只摘内存条目，文件删除交给 deleteFiles）
    private func pruneIfNeeded() -> [URL] {
        var evicted: [URL] = []
        while itemsCache.count > Self.maxItems {
            evicted.append(itemsCache.removeLast().url)
        }
        return evicted
    }

    /// 后台删除被逐出条目的 png
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
                id: $0.id, date: $0.date,
                width: $0.pixelSize.width, height: $0.pixelSize.height)
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
        deleteFiles(evicted)
        Log.event(.history, "history.index.rebuilt", ["count": "\(itemsCache.count)"])
        persistIndex()
    }

    // MARK: - 私有：条目换算（MainActor）

    private static func item(from entry: HistoryIndexEntry) -> Item {
        Item(id: entry.id, date: entry.date, pixelSize: entry.pixelSize, url: entry.fileURL)
    }

    // MARK: - 私有：磁盘 / 编码（非隔离静态，供后台任务直接使用）

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

    /// 索引缺失/损坏时扫描目录重建：按 png 文件修改时间排序，尺寸读 PNG 头属性
    private nonisolated static func rebuildEntriesFromDirectory() -> [HistoryIndexEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: HistoryPaths.directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)
        else { return [] }
        let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
        return pngs
            .sorted { modifiedAt($0) > modifiedAt($1) }
            .compactMap { url in
                guard let size = pixelSize(at: url) else { return nil }
                return HistoryIndexEntry(
                    id: url.deletingPathExtension().lastPathComponent,
                    date: modifiedAt(url),
                    width: size.width,
                    height: size.height)
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

    /// CGImage → PNG Data（ImageIO，不依赖 AppKit，线程安全）
    private nonisolated static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// id = ISO8601 时间戳 + 4 位随机大写十六进制后缀（同秒多次截图不冲突）
    private nonisolated static func makeID(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let suffix = String(format: "%04X", Int.random(in: 0..<0x10000))
        return formatter.string(from: date) + "-" + suffix
    }
}
