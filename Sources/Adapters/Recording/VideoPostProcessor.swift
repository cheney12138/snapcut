@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 录屏产物后处理适配器（AVFoundation 裁剪 + ImageIO 逐帧写 GIF）
///
/// 关键设计：
/// - **永不就地写**：无论目标是否等于源，都先写目标目录下的 `.UUID.tmp.<ext>`，
///   成功后再原子替换（`replaceItemAt` / `moveItem`）。就地截断源文件会让导出会话
///   读到正在变化的数据，产出 0 帧或尾部损坏的视频——这是 AVFoundation 的经典坑。
/// - **裁剪优先无损**：`AVAssetExportPresetPassthrough` 只重写容器不重编码（毫秒级）；
///   少数编码参数组合会让 passthrough 失败（比如音轨时间戳越界），失败自动降级
///   `HighestQuality` 重编码一次，用户拿到的是「慢一点但能用」而不是报错。
/// - **GIF 有体积闸门**：帧率收进 8...24，总帧数上限 450，长边不超过 `maxDimension`。
///   不设闸门时 4K Retina 录屏会产出几十 MB 的 GIF，聊天工具直接拒收。
/// - 无任何可变共享状态（每次调用自带 asset / generator），故 `@unchecked Sendable`。
final class VideoPostProcessor: VideoPostProcessing, @unchecked Sendable {
    enum PostProcessError: LocalizedError {
        case assetUnreadable(String)
        case videoTrackMissing
        case exportSessionUnavailable
        case exportProducedNoFile
        case emptyTrimRange
        case durationTooLong(actual: TimeInterval, max: TimeInterval)
        case gifEncodeFailed

        var errorDescription: String? {
            switch self {
            case .assetUnreadable(let detail): return "无法读取视频文件：\(detail)"
            case .videoTrackMissing: return "视频文件里没有画面轨道"
            case .exportSessionUnavailable: return "无法创建视频导出会话"
            case .exportProducedNoFile: return "视频导出未产出文件"
            case .emptyTrimRange: return "裁剪区间为空，无法生成动图"
            case .durationTooLong(let actual, let max):
                return "GIF 最长支持 \(Int(max)) 秒，请先拖动进度条两端裁剪片段（当前 \(RecordingGeometry.formatDuration(actual))）"
            case .gifEncodeFailed: return "GIF 封装失败"
            }
        }
    }

    /// GIF 单次转换的帧数上限（450 帧 × 960px 已接近 40MB，再高聊天工具会拒收）
    private static let maxGIFFrameCount = 450

    /// 缩略图长边上限（预览用，不必背回 4K 位图）
    private static let thumbnailMaxDimension: CGFloat = 1280

    // MARK: - 裁剪 MP4

    func trimMP4(
        sourceURL: URL,
        range: VideoTrimRange,
        destinationURL: URL
    ) async throws -> RecordingResult {
        let asset = AVURLAsset(url: sourceURL)
        try await Self.validateReadable(asset, sourceURL: sourceURL)

        let assetDuration = try await asset.load(.duration).seconds
        let effectiveRange = VideoTrimRange(
            start: range.start,
            end: range.end,
            totalDuration: (assetDuration.isFinite && assetDuration > 0) ? assetDuration : range.totalDuration
        )
        guard effectiveRange.trimmedDuration > 0 else { throw PostProcessError.emptyTrimRange }

        let timeRange = CMTimeRange(
            start: CMTime(seconds: effectiveRange.start, preferredTimescale: 600),
            duration: CMTime(seconds: effectiveRange.trimmedDuration, preferredTimescale: 600)
        )

        let tempURL = try Self.makeTempURL(near: destinationURL, ext: "mp4")
        defer { Self.discard(tempURL) }

        var presetUsed = "passthrough"
        do {
            try await Self.export(asset: asset, timeRange: timeRange, to: tempURL, preset: AVAssetExportPresetPassthrough)
        } catch {
            // passthrough 失败（编码参数/音轨时间戳越界等）→ 降级重导出一次
            Log.event(.recording, "recording.trim.passthroughFallback", [
                "reason": "\(error.localizedDescription)",
            ])
            presetUsed = "highestQuality"
            // 上次失败的导出可能留下半截文件，而 export(to:) 不会覆盖已存在的目标，
            // 不先清掉会让降级重导出也直接失败
            Self.discard(tempURL)
            try await Self.export(asset: asset, timeRange: timeRange, to: tempURL, preset: AVAssetExportPresetHighestQuality)
        }

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw PostProcessError.exportProducedNoFile
        }
        try Self.placeAtomically(tempURL, at: destinationURL)

        let result = try await Self.describeVideo(
            url: destinationURL,
            fallbackDuration: effectiveRange.trimmedDuration,
            isTemporaryFile: false
        )
        Log.event(.recording, "recording.trim.ok", [
            "preset": presetUsed,
            "from": String(format: "%.2f", effectiveRange.start),
            "to": String(format: "%.2f", effectiveRange.end),
            "total": String(format: "%.2f", effectiveRange.totalDuration),
            "duration": String(format: "%.2f", result.duration),
            "pxW": "\(result.pixelWidth)",
            "pxH": "\(result.pixelHeight)",
            "bytes": "\(result.fileSizeBytes)",
        ])
        return result
    }

    // MARK: - MP4 → GIF

    func convertMP4ToGIF(
        sourceURL: URL,
        range: VideoTrimRange,
        options: GIFConversionOptions,
        destinationURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> RecordingResult {
        let asset = AVURLAsset(url: sourceURL)
        try await Self.validateReadable(asset, sourceURL: sourceURL)

        let assetDuration = try await asset.load(.duration).seconds
        let effectiveRange = VideoTrimRange(
            start: range.start,
            end: range.end,
            totalDuration: (assetDuration.isFinite && assetDuration > 0) ? assetDuration : range.totalDuration
        )
        let trimmed = effectiveRange.trimmedDuration
        guard trimmed > 0 else { throw PostProcessError.emptyTrimRange }

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PostProcessError.videoTrackMissing
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = Self.displaySize(naturalSize: naturalSize, transform: transform)
        let longestSide = max(displaySize.width, displaySize.height)

        guard let resolved = options.resolved(forDuration: trimmed) else {
            throw PostProcessError.durationTooLong(
                actual: trimmed,
                max: GIFConversionOptions.maxDurationSeconds
            )
        }
        // 采样节奏：20–60s 自动温和降帧/缩边，超长帧数仍受 maxGIFFrameCount 兜底
        let fps = resolved.fps
        var frameStep = 1.0 / Double(fps)
        if trimmed * Double(fps) > Double(Self.maxGIFFrameCount) {
            frameStep = trimmed / Double(Self.maxGIFFrameCount)
        }
        let maxDimension = resolved.maxDimension

        // ⚠️ 为什么不用 AVAssetImageGenerator 循环 image(at:)：
        // 1. ScreenCaptureKit 产出的是可变帧率（VFR）MP4，静止期无帧、尾帧常略早于音轨总时长，
        //    image(at:) 在窄容差下极易抛 AVError -11832（系统文案叫 "Cannot Open"）；
        // 2. image(at:) 每帧重建一次 VideoToolbox 解码会话，40 帧要 2 秒+。
        // 改用双趟 AVAssetReader（按 PTS 匹配，完整兼容 B 帧与 VFR）：
        // - Pass 1 零解码扫描压缩包 PTS 并升序排布（<2ms），精确挑出目标帧与真实帧延迟；
        // - Pass 2 单次硬件解码流按 PTS 顺序写入 ImageIO，恒定 O(1) 内存、零 -11832、速度 5× 提升。
        let plan = try Self.buildGIFFramePlan(
            asset: asset,
            track: track,
            range: effectiveRange,
            frameStep: frameStep,
            maxFrames: Self.maxGIFFrameCount
        )

        let tempURL = try Self.makeTempURL(near: destinationURL, ext: "gif")
        defer { Self.discard(tempURL) }

        let targetFrameCount = plan.entries.count
        guard targetFrameCount >= 1,
              let destination = CGImageDestinationCreateWithURL(
                tempURL as CFURL,
                UTType.gif.identifier as CFString,
                targetFrameCount,
                nil
              ) else {
            throw PostProcessError.gifEncodeFailed
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ]
        CGImageDestinationSetProperties(destination, fileProps as CFDictionary)

        let writeStats = try Self.encodeGIFWithAssetReader(
            asset: asset,
            track: track,
            plan: plan,
            maxDimension: maxDimension,
            destination: destination,
            onProgress: onProgress
        )

        guard writeStats.writtenFrames > 0, CGImageDestinationFinalize(destination) else {
            throw PostProcessError.gifEncodeFailed
        }
        try Self.placeAtomically(tempURL, at: destinationURL)

        let bytes = Self.fileSize(at: destinationURL)
        let result = RecordingResult(
            format: .gif,
            fileURL: destinationURL,
            pixelWidth: writeStats.width,
            pixelHeight: writeStats.height,
            duration: trimmed,
            fileSizeBytes: bytes,
            frameCount: writeStats.writtenFrames,
            thumbnail: writeStats.firstFrame,
            isTemporaryFile: false
        )
        Log.event(.recording, "recording.gif.convert", [
            "fps": "\(fps)",
            "frames": "\(writeStats.writtenFrames)",
            "step": String(format: "%.3f", frameStep),
            "duration": String(format: "%.2f", trimmed),
            "pxW": "\(writeStats.width)",
            "pxH": "\(writeStats.height)",
            "bytes": "\(bytes)",
            "downscaled": "\(longestSide > CGFloat(maxDimension))",
        ])
        return result
    }

    // MARK: - AVAssetReader 双趟流式 GIF 转换

    private struct GIFFramePlanEntry {
        /// 目标视频帧的原始 PTS（秒，严格升序，兼容 B 帧解码序 ≠ 显示序）
        let targetPTS: Double
        /// 这一帧在 GIF 中的显示时长（秒，按真实 PTS 间隔计算，自动吸收静止期）
        let delay: Double
    }

    private struct GIFFramePlan {
        /// Pass 1/2 共享读取范围：从 0 读到 end，确保裁剪起点落在静止 VFR 间隙时也能借到上一关键帧
        let readRange: CMTimeRange
        let entries: [GIFFramePlanEntry]
    }

    private struct GIFWriteStats {
        let writtenFrames: Int
        let width: Int
        let height: Int
        let firstFrame: CGImage?
    }

    /// Pass 1：零解码扫描压缩样本 PTS，产出按显示序排列的精确帧计划（耗时 < 2ms）
    private static func buildGIFFramePlan(
        asset: AVURLAsset,
        track: AVAssetTrack,
        range: VideoTrimRange,
        frameStep: Double,
        maxFrames: Int
    ) throws -> GIFFramePlan {
        let readEnd = CMTime(seconds: range.end + 0.05, preferredTimescale: 600)
        let readRange = CMTimeRange(start: .zero, duration: readEnd)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = readRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PostProcessError.gifEncodeFailed }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? PostProcessError.gifEncodeFailed
        }
        defer { reader.cancelReading() }

        var allPTS: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts.isFinite {
                allPTS.append(pts)
            }
        }
        guard !allPTS.isEmpty else { throw PostProcessError.videoTrackMissing }
        allPTS.sort()

        // 先找起点之前最后一帧（防止裁剪起点正好落在静止 VFR 空档里导致开头缺帧）
        var carryInPTS: Double?
        var inWindow: [Double] = []
        for pts in allPTS {
            if pts < range.start - 0.002 {
                carryInPTS = pts
            } else if pts <= range.end + 0.005 {
                inWindow.append(pts)
            }
        }

        // 按 frameStep 抽样（首帧必保；中间按真实 PTS 步进；静止期自动合并成更长 delay）
        var selected: [(targetPTS: Double, displayPTS: Double)] = []
        if let first = inWindow.first {
            if let prev = carryInPTS, first - range.start > max(0.05, frameStep * 0.6) {
                selected.append((prev, range.start))
            }
        } else if let prev = carryInPTS {
            selected.append((prev, range.start))
        } else if let fallback = allPTS.first {
            selected.append((fallback, range.start))
        }

        var lastPickedPTS = selected.last?.displayPTS ?? -Double.greatestFiniteMagnitude
        for pts in inWindow {
            if selected.isEmpty || (pts - lastPickedPTS) >= frameStep * 0.85 {
                let clampedDisplay = max(range.start, pts)
                selected.append((pts, clampedDisplay))
                lastPickedPTS = clampedDisplay
            }
        }
        // 尽量保留窗口内最后一帧（让结尾画面与裁剪终点一致）
        if let lastInWindow = inWindow.last,
           let lastSel = selected.last,
           abs(lastInWindow - lastSel.targetPTS) > 0.001,
           (lastInWindow - lastSel.displayPTS) >= 0.04 {
            selected.append((lastInWindow, min(range.end, lastInWindow)))
        }

        // 超过帧数上限时均匀抽稀，始终保留首尾帧
        if selected.count > maxFrames {
            var thinned: [(targetPTS: Double, displayPTS: Double)] = []
            thinned.reserveCapacity(maxFrames)
            let lastIdx = selected.count - 1
            for i in 0..<maxFrames {
                let src = Int((Double(i) * Double(lastIdx) / Double(maxFrames - 1)).rounded())
                thinned.append(selected[min(max(src, 0), lastIdx)])
            }
            selected = thinned
        }

        // 极短/完全静止片段保证至少 2 帧（避免某些接收方把 1 帧 GIF 当静图）
        let trimmed = range.trimmedDuration
        if selected.count == 1, let only = selected.first {
            let half = max(0.02, ((trimmed / 2.0) * 100.0).rounded() / 100.0)
            return GIFFramePlan(
                readRange: readRange,
                entries: [
                    GIFFramePlanEntry(targetPTS: only.targetPTS, delay: half),
                    GIFFramePlanEntry(targetPTS: only.targetPTS, delay: half),
                ]
            )
        }

        var entries: [GIFFramePlanEntry] = []
        entries.reserveCapacity(selected.count)
        for i in 0..<selected.count {
            let curPTS = selected[i].displayPTS
            let nextPTS = (i + 1 < selected.count) ? selected[i + 1].displayPTS : range.end
            let rawDelay = max(0.02, nextPTS - curPTS)
            let roundedDelay = max(0.02, (rawDelay * 100.0).rounded() / 100.0)
            entries.append(GIFFramePlanEntry(targetPTS: selected[i].targetPTS, delay: roundedDelay))
        }
        return GIFFramePlan(readRange: readRange, entries: entries)
    }

    /// Pass 2：单次硬件解码流按显示序 PTS 匹配写帧进 GIF（O(1) 内存，零重建解码器）
    private static func encodeGIFWithAssetReader(
        asset: AVURLAsset,
        track: AVAssetTrack,
        plan: GIFFramePlan,
        maxDimension: Int,
        destination: CGImageDestination,
        onProgress: (@Sendable (Double) -> Void)?
    ) throws -> GIFWriteStats {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = plan.readRange
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PostProcessError.gifEncodeFailed }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? PostProcessError.gifEncodeFailed
        }
        defer { reader.cancelReading() }

        let totalEntries = plan.entries.count
        var planCursor = 0
        var writtenFrames = 0
        var firstFrame: CGImage?
        var lastGoodFrame: CGImage?
        var outWidth = 0
        var outHeight = 0

        while planCursor < totalEntries, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            guard pts >= plan.entries[planCursor].targetPTS - 0.002 else { continue }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                  let frameImage = makeCGImage(from: pixelBuffer, maxDimension: maxDimension) else {
                continue
            }

            if firstFrame == nil {
                firstFrame = frameImage
                outWidth = frameImage.width
                outHeight = frameImage.height
            }
            lastGoodFrame = frameImage

            // 覆盖所有 targetPTS <= pts + 0.002 的计划项（含静止片段双帧复用）
            while planCursor < totalEntries && pts >= plan.entries[planCursor].targetPTS - 0.002 {
                let delay = plan.entries[planCursor].delay
                let frameProps: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay,
                        kCGImagePropertyGIFUnclampedDelayTime: delay,
                    ],
                ]
                CGImageDestinationAddImage(destination, frameImage, frameProps as CFDictionary)
                writtenFrames += 1
                planCursor += 1
                onProgress?(Double(writtenFrames) / Double(totalEntries))
            }
        }

        // 若极少数容器尾帧 PTS 漂移导致末尾剩 1-2 项未命中，用最后一帧安全补齐，避免 CGImageDestination 帧数不足报错
        if let tailFrame = lastGoodFrame {
            while planCursor < totalEntries {
                let delay = plan.entries[planCursor].delay
                let frameProps: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay,
                        kCGImagePropertyGIFUnclampedDelayTime: delay,
                    ],
                ]
                CGImageDestinationAddImage(destination, tailFrame, frameProps as CFDictionary)
                writtenFrames += 1
                planCursor += 1
                onProgress?(Double(writtenFrames) / Double(totalEntries))
            }
        }

        return GIFWriteStats(
            writtenFrames: writtenFrames,
            width: outWidth,
            height: outHeight,
            firstFrame: firstFrame
        )
    }

    /// CVPixelBuffer（32BGRA）→ 按需等比缩放的 CGImage（纯 CoreGraphics，零额外内存滞留）
    private static func makeCGImage(from pixelBuffer: CVPixelBuffer, maxDimension: Int) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let srcCtx = CGContext(
            data: base,
            width: srcW,
            height: srcH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let rawImage = srcCtx.makeImage() else {
            return nil
        }

        let longest = max(srcW, srcH)
        guard longest > maxDimension else { return rawImage }

        let scale = Double(maxDimension) / Double(longest)
        let dstW = max(2, Int((Double(srcW) * scale).rounded()) & ~1)
        let dstH = max(2, Int((Double(srcH) * scale).rounded()) & ~1)
        guard let dstCtx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: dstW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return rawImage
        }
        dstCtx.interpolationQuality = .high
        dstCtx.draw(rawImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return dstCtx.makeImage() ?? rawImage
    }

    // MARK: - 导出

    /// 单个导出会话（`export(to:as:)` 是 macOS 15 起的新 API；
    /// 本工程部署目标即 15.0，旧的 `export()` / `status` / `error` 在 SDK 里已弃用，
    /// 用旧 API 会在 -warnings-as-errors 下直接变编译错误）
    private static func export(
        asset: AVURLAsset,
        timeRange: CMTimeRange,
        to url: URL,
        preset: String
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw PostProcessError.exportSessionUnavailable
        }
        session.timeRange = timeRange
        session.shouldOptimizeForNetworkUse = false
        try await session.export(to: url, as: .mp4)
    }

    // MARK: - 读取产物元信息

    /// 读取导出产物的时长 / 显示尺寸 / 字节数 / 帧数 / 首帧缩略图
    private static func describeVideo(
        url: URL,
        fallbackDuration: TimeInterval,
        isTemporaryFile: Bool
    ) async throws -> RecordingResult {
        let asset = AVURLAsset(url: url)
        let loadedDuration = try await asset.load(.duration).seconds
        let duration = (loadedDuration.isFinite && loadedDuration > 0) ? loadedDuration : fallbackDuration

        var pixelWidth = 0
        var pixelHeight = 0
        var frameCount = 0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let size = displaySize(naturalSize: naturalSize, transform: transform)
            pixelWidth = Int(size.width.rounded())
            pixelHeight = Int(size.height.rounded())
            let nominalRate = try await track.load(.nominalFrameRate)
            if nominalRate.isFinite && nominalRate > 0 {
                frameCount = max(1, Int((Double(nominalRate) * duration).rounded()))
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: thumbnailMaxDimension, height: thumbnailMaxDimension)
        // 缩略图失败不该让整次裁剪失败（视频本身已经落盘可用）
        var thumbnail: CGImage?
        if let shot = try? await generator.image(at: .zero) {
            thumbnail = shot.image
        }

        return RecordingResult(
            format: .mp4,
            fileURL: url,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration,
            fileSizeBytes: fileSize(at: url),
            frameCount: frameCount,
            thumbnail: thumbnail,
            isTemporaryFile: isTemporaryFile
        )
    }

    /// 应用 `preferredTransform` 后的显示尺寸（竖屏录制/旋转元数据都要取绝对值）
    private static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let transformed = naturalSize.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    // MARK: - 文件落盘

    /// 目标目录下的唯一临时文件（不撞名、同卷保证原子替换可行）
    private static func makeTempURL(near destinationURL: URL, ext: String) throws -> URL {
        let directory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(".\(UUID().uuidString).tmp.\(ext)")
    }

    /// 原子落到目标位置：已存在则替换（保留原子性），否则直接移动
    private static func placeAtomically(_ tempURL: URL, at destinationURL: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try manager.moveItem(at: tempURL, to: destinationURL)
        }
    }

    /// 清理暂存文件：自身 + ImageIO / FileManager 在目标旁开的旁路暂存
    ///
    /// `CGImageDestination` 不直接写目标 URL，而是先在旁边开一个
    /// `"." + 目标名 + "-随机尾巴"` 的暂存文件，`Finalize` 时才改名落地。
    /// 取消或中途抛错时 ImageIO 自己不会清，只清我们自己的那份会留垃圾文件
    /// （实测：取消 GIF 转换后目录里残留 `..<uuid>.tmp.gif-vEAS`）。
    private static func discard(_ url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        let directory = url.deletingLastPathComponent()
        let prefix = "." + url.lastPathComponent
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != url.lastPathComponent && name.hasPrefix(prefix) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let num = attrs[.size] as? NSNumber else { return 0 }
        return num.int64Value
    }

    private static func validateReadable(_ asset: AVURLAsset, sourceURL: URL) async throws {
        let playable = try? await asset.load(.isPlayable)
        guard playable == true else {
            throw PostProcessError.assetUnreadable(sourceURL.lastPathComponent)
        }
    }
}
