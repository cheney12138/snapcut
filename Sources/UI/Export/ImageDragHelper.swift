import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 出图拖拽底座（功能 #2「随手拖拽出图」）：把「一张图」变成一次系统原生文件拖拽会话。
///
/// 设计要点（对齐 `Sources/UI/Permission/DragSourceCoordinator.swift` 的成熟写法）：
/// - 负载用 `fileURL as NSURL`（pasteboard type = `public.file-url`）：与在 Finder 里
///   拖一个 png 文件逐字等价，飞书 / Slack / 微信 / Chrome / Figma / Finder 全部认；
///   SwiftUI `onDrag` 的 NSItemProvider 负载在部分接收方不认，勿改；
/// - 拖拽源的持久性：`beginDraggingSession` 的 source 在会话期间不能释放 ⇒ 单例；
/// - Swift 6 严格并发：NSDraggingSource 回调走 `MainActor.assumeIsolated` 桥接；
/// - CGImage 先落成临时 PNG（`~/tmp/SnapcutDrag`），并自动滚动清理最旧文件，
///   避免临时目录无限增长（保留 24 份，正在拖的那份永不删）。
@MainActor
final class ImageDragCoordinator: NSObject {
    static let shared = ImageDragCoordinator()

    /// 拖拽进行中（面板/浮窗据此挂起「失焦自动关闭」等打断逻辑）
    private(set) var isDragging = false

    // MARK: - 常量

    /// 临时 PNG 目录名（位于 FileManager.temporaryDirectory 下）
    private static let temporaryDirectoryName = "SnapcutDrag"
    /// 临时目录最多保留文件数（超出按修改时间从旧到新删除）
    private static let maxTemporaryFiles = 24
    /// 预览圆角（对齐贴图/卡片语言）
    private static let previewCornerRadius: CGFloat = 8
    /// 预览渲染倍率：2x 出图保证拖拽影像在 Retina 上锐利
    private static let previewRenderScale: CGFloat = 2

    /// 拖拽会话进行中的回调（会话结束即清空，防止闭包跨会话串味）
    private var onStartHandler: (() -> Void)?
    private var onEndHandler: ((Bool) -> Void)?
    /// 本次会话的负载文件名（日志用）
    private var activeFileName = "-"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private override init() {
        super.init()
    }

    // MARK: - 公开 API

    /// CGImage 出图：先写临时 PNG，再走文件拖拽（最常用路径）。
    ///
    /// - Parameters:
    ///   - suggestedName: 建议文件名（不带扩展名也可；非法字符会被清洗，空则自动生成时间戳名）
    ///   - onEnd: `dropped == true` 表示接收方接受了这次拖放（operation != [])
    /// - Returns: 是否成功发起拖拽会话（写盘失败 / 已有会话在跑时返回 false）
    @discardableResult
    func beginImageDrag(
        cgImage: CGImage,
        suggestedName: String? = nil,
        from view: NSView,
        event: NSEvent,
        previewMaxSide: CGFloat = 120,
        onStart: (() -> Void)? = nil,
        onEnd: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard let fileURL = Self.writeTemporaryPNG(cgImage, suggestedName: suggestedName) else {
            Log.error(.export, "drag.image.write_fail", [
                "pxW": "\(cgImage.width)", "pxH": "\(cgImage.height)",
            ])
            return false
        }
        // 预览直接用内存里的 CGImage 渲染（绝不重新解码刚写下的 PNG：5K 图要 50ms+）
        let preview = Self.roundedPreview(from: cgImage, maxSide: previewMaxSide)
        let started = beginDragSession(
            fileURL: fileURL,
            preview: preview,
            from: view,
            event: event,
            onStart: onStart,
            onEnd: onEnd
        )
        if !started {
            // 发起失败：立刻回收刚写的临时文件，别留垃圾
            try? FileManager.default.removeItem(at: fileURL)
            Log.event(.export, "drag.image.abort", ["name": fileURL.lastPathComponent])
        }
        return started
    }

    /// 现成文件出图（视觉记忆库卡片等）：不做任何重新编码，拖原文件本身。
    ///
    /// ⚠️ 文件名安全闸门（病例 2026-11-28：视觉记忆库拖到大象报「文件名包含不支持的字符“/”」）：
    /// `HistoryStore` 落盘用 ISO8601 名（`2026-11-27T15:40:43Z-E946.png`），含 POSIX 冒号 `:`；
    /// macOS 会把文件名里的 `:` 桥接给 Finder / Electron（大象、飞书）显示成 `/`，接收方校验
    /// 直接拒收。所以这里先过 `dragFileURL(for:)`：名字不安全就在临时目录里用硬链接（退回复制）
    /// 造一份安全文件名的**零重编码**副本，原历史文件一个字节都不动。
    @discardableResult
    func beginFileDrag(
        fileURL: URL,
        previewImage: NSImage?,
        from view: NSView,
        event: NSEvent,
        previewMaxSide: CGFloat = 120,
        onStart: (() -> Void)? = nil,
        onEnd: ((Bool) -> Void)? = nil
    ) -> Bool {
        let dragURL = Self.dragFileURL(for: fileURL)
        let preview = Self.makePreview(
            image: previewImage,
            fileURL: fileURL,
            maxSide: previewMaxSide
        )
        let started = beginDragSession(
            fileURL: dragURL,
            preview: preview,
            from: view,
            event: event,
            onStart: onStart,
            onEnd: onEnd
        )
        if !started, dragURL != fileURL {
            // 未起拖：回收刚建的暂存副本（滚动清理之外再收一次，别留孤儿文件）
            try? FileManager.default.removeItem(at: dragURL)
        }
        return started
    }

    // MARK: - 会话发起

    private func beginDragSession(
        fileURL: URL,
        preview: NSImage,
        from view: NSView,
        event: NSEvent,
        onStart: (() -> Void)?,
        onEnd: ((Bool) -> Void)?
    ) -> Bool {
        guard !isDragging else {
            Log.event(.export, "drag.image.busy", ["name": fileURL.lastPathComponent])
            return false
        }
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            Log.error(.export, "drag.image.missing_file", ["name": fileURL.lastPathComponent])
            return false
        }
        guard view.window != nil else {
            Log.error(.export, "drag.image.no_window", ["name": fileURL.lastPathComponent])
            return false
        }

        // 负载：NSURL file-URL ⇒ public.file-url（与 Finder 拖文件一致）
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        // ⚠️ AppKit 把起拖视图的 visibleRect 当作拖拽影像的裁剪框（NSView.h beginDraggingSession：
        // “The visible area of the view is used as the clip rect”）——从 20pt 圆钮起拖会把
        // 120pt 缩略图剪成纽扣。所以往上找一个容得下预览的祖先视图起拖（不越过窗口 contentView）。
        let sourceView = dragSourceView(for: view, previewSize: preview.size)
        // 热点 = 按下点，缩略图以它为中心（AppKit 按起拖视图的坐标系换算，翻转视图同样成立）
        let location = sourceView.convert(event.locationInWindow, from: nil)
        let size = preview.size
        let frame = NSRect(
            x: (location.x - size.width / 2).rounded(),
            y: (location.y - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        item.setDraggingFrame(frame, contents: preview)

        onStartHandler = onStart
        onEndHandler = onEnd
        activeFileName = fileURL.lastPathComponent

        let session = sourceView.beginDraggingSession(with: [item], event: event, source: self)
        // 取消/失败时拖拽影像滑回起点（比原地消失自然）
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    /// 找一个容得下预览图的起拖视图（避免拖拽影像被小视图的 visibleRect 剪掉）
    private func dragSourceView(for view: NSView, previewSize: NSSize) -> NSView {
        let limit = view.window?.contentView
        var candidate = view
        while (candidate.bounds.width < previewSize.width || candidate.bounds.height < previewSize.height),
              let superview = candidate.superview,
              candidate !== limit {
            candidate = superview
        }
        return candidate
    }
}

// MARK: - NSDraggingSource（回调在主线程，用 assumeIsolated 桥接）

extension ImageDragCoordinator: NSDraggingSource {
    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // 只允许「拷贝」：拖出是单向出图，绝不允许接收方把源文件移走
        .copy
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint
    ) {
        MainActor.assumeIsolated {
            isDragging = true
            Log.event(.export, "drag.image.begin", [
                "name": activeFileName,
                "x": "\(Int(screenPoint.x.rounded()))",
                "y": "\(Int(screenPoint.y.rounded()))",
            ])
            onStartHandler?()
        }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        MainActor.assumeIsolated {
            isDragging = false
            let dropped = operation != []
            Log.event(.export, "drag.image.end", [
                "name": activeFileName,
                "dropped": "\(dropped)",
                "op": "\(operation.rawValue)",
            ])
            let endHandler = onEndHandler
            // 先清状态再回调：回调里若再次发起拖拽（快速连拖）不会被 busy 闸门挡住
            onStartHandler = nil
            onEndHandler = nil
            activeFileName = "-"
            endHandler?(dropped)
        }
    }
}

// MARK: - 不安全文件名暂存（零重编码）

private extension ImageDragCoordinator {
    /// 拖出去的文件名里绝不能出现的字符：POSIX `:` 是罪魁（macOS 双 API 历史包袱把
    /// 文件名里的 `:` 与 `/` 互相桥接，Finder/Electron 侧直接显示成 `/` 并被判非法）。
    static let unsafeNameCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")

    /// 真正用于拖拽会话的文件 URL：名字安全就用原文件；不安全就在临时目录暂存一份安全名副本。
    static func dragFileURL(for fileURL: URL) -> URL {
        guard isUnsafeFileName(fileURL.lastPathComponent) else { return fileURL }
        guard let staged = stageSafeNameCopy(of: fileURL) else {
            // 暂存失败（磁盘满/权限/只读卷）：宁可拖原名也别让「拖出」整件事失败
            Log.error(.export, "drag.stage.fail", ["name": fileURL.lastPathComponent])
            return fileURL
        }
        Log.event(.export, "drag.stage.copy", [
            "from": fileURL.lastPathComponent,
            "to": staged.lastPathComponent,
        ])
        return staged
    }

    static func isUnsafeFileName(_ name: String) -> Bool {
        name.unicodeScalars.contains { unsafeNameCharacters.contains($0) }
    }

    /// 清洗文件名：`:` → `-`（时间戳读起来仍是时间），其余非法字符 → `_`；
    /// 保留原扩展名（不清洗扩展名，接收方靠它判类型），前缀 `Snapcut_` 明确出自本产品。
    /// 例：`2026-11-27T15:40:43Z-E946.png` → `Snapcut_2026-11-27T15-40-43Z-E946.png`
    static func sanitizedDragFileName(_ name: String) -> String {
        let nsName = name as NSString
        let ext = nsName.pathExtension.lowercased()
        let strippedBase = nsName.deletingPathExtension
        let base = strippedBase.isEmpty ? name : strippedBase
        let illegal = Set("/\\:*?\"<>|\n\r\t")
        var cleaned = String(base.map { character -> Character in
            guard illegal.contains(character) else { return character }
            return character == ":" ? "-" : "_"
        })
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        // 文件系统单段上限 255 字节；CJK 3 字节/字 ⇒ 72 字符 + 前缀尾巴绝对安全
        if cleaned.count > 72 { cleaned = String(cleaned.prefix(72)) }
        if cleaned.isEmpty { cleaned = timestampFormatter.string(from: Date()) }
        return "Snapcut_\(cleaned).\(ext.isEmpty ? "png" : ext)"
    }

    /// 把现成文件「零重编码」暂存成安全文件名：
    /// 硬链接优先（APFS 同卷瞬时完成、不占额外空间），跨卷/不支持时回落字节级复制。
    /// 两种情况都不重新编码图像，耗时 <1ms。
    static func stageSafeNameCopy(of fileURL: URL) -> URL? {
        let fileManager = FileManager.default
        let directory = temporaryDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let baseName = sanitizedDragFileName(fileURL.lastPathComponent)
        var staged = directory.appendingPathComponent(baseName)
        if fileManager.fileExists(atPath: staged.path) {
            // 同名残留（同一张图连拖）：换尾缀，绝不覆盖可能正被接收方读取的那一份
            let nsBase = baseName as NSString
            staged = directory.appendingPathComponent(
                "\(nsBase.deletingPathExtension)_\(randomSuffix()).\(nsBase.pathExtension)"
            )
            try? fileManager.removeItem(at: staged)
        }

        do {
            try fileManager.linkItem(at: fileURL, to: staged)
        } catch {
            do {
                try fileManager.copyItem(at: fileURL, to: staged)
            } catch {
                Log.error(.export, "drag.stage.write_fail", [
                    "name": fileURL.lastPathComponent,
                    "err": "\(error.localizedDescription)",
                ])
                return nil
            }
        }
        pruneTemporaryFiles(keeping: staged)
        return staged
    }
}

// MARK: - 临时 PNG 落盘 + 滚动清理

private extension ImageDragCoordinator {
    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryDirectoryName, isDirectory: true)
    }

    /// 把 CGImage 写成 PNG 到临时目录；成功后清理最旧文件（保留 24 份）
    static func writeTemporaryPNG(_ image: CGImage, suggestedName: String?) -> URL? {
        let fileManager = FileManager.default
        let directory = temporaryDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.error(.export, "drag.temp.mkdir_fail", ["err": "\(error.localizedDescription)"])
            return nil
        }

        let url = directory.appendingPathComponent(temporaryFileName(for: suggestedName, in: directory))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            Log.error(.export, "drag.temp.dest_fail", ["name": url.lastPathComponent])
            return nil
        }
        // 144dpi：保留 2x Retina 语义（与 HistoryStore.encodePNG 同口径），
        // 否则接收方会按 72dpi 把图显示成两倍大
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 144,
            kCGImagePropertyDPIHeight: 144,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            Log.error(.export, "drag.temp.finalize_fail", ["name": url.lastPathComponent])
            return nil
        }

        pruneTemporaryFiles(keeping: url)
        return url
    }

    /// 文件名：清洗后的 suggestedName，否则 `Snapcut_yyyy-MM-dd_HH-mm-ss_xxxx.png`
    static func temporaryFileName(for suggestedName: String?, in directory: URL) -> String {
        if let base = sanitizedBaseName(suggestedName) {
            var candidate = "\(base).png"
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                // 同名文件还在（1 秒内连拖同一张图）⇒ 加随机尾缀，避免覆盖正在被读取的文件
                candidate = "\(base)_\(randomSuffix()).png"
            }
            return candidate
        }
        let stamp = timestampFormatter.string(from: Date())
        return "Snapcut_\(stamp)_\(randomSuffix()).png"
    }

    static func sanitizedBaseName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        if name.lowercased().hasSuffix(".png") {
            name = String(name.dropLast(4))
        }
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        name = name.components(separatedBy: illegal).joined(separator: "_")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        // 文件系统单段上限 255 字节；CJK 3 字节/字 ⇒ 截到 80 字符绝对安全
        if name.count > 80 {
            name = String(name.prefix(80))
        }
        return name.isEmpty ? nil : name
    }

    static func randomSuffix() -> String {
        String(format: "%04x", Int.random(in: 0..<0xFFFF))
    }

    /// 滚动清理：按修改时间新 → 旧保留 24 份，其余删除（保证正在拖的那份永不删）
    static func pruneTemporaryFiles(keeping current: URL) {
        let fileManager = FileManager.default
        let directory = temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), entries.count > maxTemporaryFiles else {
            return
        }
        let sorted = entries.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            return left > right
        }
        var removed = 0
        for url in sorted.dropFirst(maxTemporaryFiles) {
            if url.standardizedFileURL == current.standardizedFileURL { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            Log.event(.export, "drag.temp.prune", ["removed": "\(removed)"])
        }
    }
}

// MARK: - 拖拽预览（等比缩放 + 圆角 + 发丝描边）

private extension ImageDragCoordinator {
    /// 现成文件/缩略图的预览：优先用调用方给的 NSImage，否则退回文件自身解码，最后退到系统文件图标
    static func makePreview(image: NSImage?, fileURL: URL, maxSide: CGFloat) -> NSImage {
        if let image, let source = cgImage(from: image) {
            return roundedPreview(from: source, maxSide: maxSide)
        }
        if let decoded = NSImage(contentsOf: fileURL), let source = cgImage(from: decoded) {
            return roundedPreview(from: source, maxSide: maxSide)
        }
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        let side = max(48, maxSide)
        icon.size = NSSize(width: side, height: side)
        return icon
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        var proposed = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    /// 精致缩略预览：等比缩到最大边 maxSide（2x 渲染）、8pt 圆角裁切、
    /// 外圈 0.5pt 暗影线 + 内圈 0.5pt 亮边（与贴图本体的双重发丝边界同族）
    static func roundedPreview(from source: CGImage, maxSide: CGFloat) -> NSImage {
        let pixelW = CGFloat(source.width)
        let pixelH = CGFloat(source.height)
        guard pixelW > 0, pixelH > 0 else {
            return NSImage(size: NSSize(width: maxSide, height: maxSide))
        }

        let scale = previewRenderScale
        let limit = max(32, maxSide) * scale
        let fit = min(limit / pixelW, limit / pixelH)
        let drawW = max(16, (pixelW * fit).rounded())
        let drawH = max(16, (pixelH * fit).rounded())
        let pxW = Int(drawW)
        let pxH = Int(drawH)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(cgImage: source, size: NSSize(width: drawW / scale, height: drawH / scale))
        }
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true)

        let rect = CGRect(x: 0, y: 0, width: drawW, height: drawH)
        let radius = min(previewCornerRadius * scale, min(drawW, drawH) / 2)

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(source, in: rect)
        ctx.restoreGState()

        // 外圈暗影线（贴亮底也立得住）
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5 * scale)
        ctx.addPath(CGPath(
            roundedRect: rect.insetBy(dx: 0.25 * scale, dy: 0.25 * scale),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        ))
        ctx.strokePath()
        // 内圈亮边（贴暗底有轮廓）
        let innerInset = 0.75 * scale
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
        ctx.setLineWidth(0.5 * scale)
        ctx.addPath(CGPath(
            roundedRect: rect.insetBy(dx: innerInset, dy: innerInset),
            cornerWidth: max(1, radius - innerInset / 2),
            cornerHeight: max(1, radius - innerInset / 2),
            transform: nil
        ))
        ctx.strokePath()

        guard let output = ctx.makeImage() else {
            return NSImage(cgImage: source, size: NSSize(width: drawW / scale, height: drawH / scale))
        }
        return NSImage(cgImage: output, size: NSSize(width: drawW / scale, height: drawH / scale))
    }
}
