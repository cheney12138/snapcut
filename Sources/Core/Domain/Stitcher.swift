import CoreGraphics
import Foundation

/// 滚动截图拼接器（Stitcher）
///
/// 提供两种使用方式：
/// 1. **流式增量会话（`Stitcher.Session`）**：采集期每帧 `push(frame)` 仅做一次解码与运动估计，
///    采用 SnowShot 的 `band_height` 重绘带策略增量写入画布（天然剔除 sticky header/footer 重复印痕，
///    容忍回弹/回滚），`finish()` 毫秒级直接出图；
/// 2. **批量同步入口（`Stitcher.stitch(frames:options:)`）**：底层复用同一套运动估计与洁净合成核心，
///    兼容原有 `Result` / `SeamInfo` 契约与不等高帧场景。
enum Stitcher {

    // MARK: - 公共类型

    /// 单帧在长图中的接缝信息
    struct SeamInfo: Equatable, Sendable {
        /// 帧在输入序列中的下标（0 起始）
        let frameIndex: Int
        /// 该帧与上一状态检测到的重叠行数（首帧为 0）
        let overlapRows: Int
        /// 该帧对长图的净贡献行数（首帧 = 帧高）
        let contributedRows: Int
        /// 该帧第 0 行在输出长图中的 y 偏移（像素，长图顶部为 0）
        let offsetY: Int
    }

    /// 拼接结果
    struct Result: Sendable {
        /// 拼接成的长图（宽 = 输入帧宽，高 = 最终画布高度）
        let image: CGImage
        /// 每帧的接缝信息
        let seams: [SeamInfo]
    }

    /// 可调参数
    struct Options: Sendable {
        /// 相邻帧最小可信重叠行数（小于此值不认为是滚动重叠）
        var minOverlap: Int = 16
        /// 保留兼容字段（PixelBuffer 行比对 / TestStitchMain 容差参考）
        var rowDiffThreshold: UInt32 = 24
        var maxMismatchRatio: Double = 0.10
        var signatureSamples: Int = 64
        /// 运动估计选项
        var estimatorOptions: TileMotionEstimator.Options = TileMotionEstimator.Options()
    }

    /// 增量会话单帧推送结论
    enum PushStatus: Equatable, Sendable {
        case firstFrame
        case appended(growthRows: Int, totalHeight: Int)
        case prepended(growthRows: Int, totalHeight: Int)
        case contained(positionY: Int, totalHeight: Int)
        case staticFrame
        case skipped
    }

    // MARK: - 错误

    enum StitcherError: LocalizedError {
        case cancelled
        case noFrames
        case widthMismatch(expected: Int, actual: Int, frameIndex: Int)
        case frameTooSmall(frameIndex: Int, height: Int, minOverlap: Int)
        case noOverlapFound(frameIndex: Int)
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "拼接被取消（超时）"
            case .noFrames:
                return "帧序列为空，无法拼接"
            case .widthMismatch(let expected, let actual, let index):
                return "第 \(index) 帧宽度 \(actual) 与首帧宽度 \(expected) 不一致"
            case .frameTooSmall(let index, let height, let minOverlap):
                return "第 \(index) 帧高度 \(height) 过小（需 > 最小重叠 \(minOverlap)）"
            case .noOverlapFound(let index):
                return "第 \(index) 帧与前一帧未找到可信的垂直重叠（画面未滚动？）"
            case .renderFailed(let reason):
                return "长图画布创建/绘制失败：\(reason)"
            }
        }
    }

    // MARK: - 流式增量拼接会话

    /// 流式增量拼接会话（非线程安全；由调用方在串行 actor / 队列内驱动）。
    final class Session {
        private enum ReferenceMode {
            case previousFrame
            case canvasWindow
        }

        private let options: Options
        private(set) var canvasWidth: Int = 0
        private(set) var canvasHeight: Int = 0
        private(set) var viewportHeight: Int = 0
        private(set) var viewportPosition: Int = 0
        private(set) var maxViewportPosition: Int = 0
        private(set) var pushedCount: Int = 0
        /// 对画布有净贡献的帧数（首帧 + 每次扩展画布的帧）
        private(set) var contributingFrameCount: Int = 0
        private(set) var seams: [SeamInfo] = []
        private(set) var firstFrameImage: CGImage?

        private var canvasPixels = Data()
        private var referenceFrame: TileMotionEstimator.PreparedFrame?
        /// 回滚进入已拼画布内部后切换为 CanvasWindow 对齐参考（对齐 SnowShot 零漂移策略）
        private var referenceMode: ReferenceMode = .previousFrame
        private var cachedCanvasWindowPos: Int?
        private var cachedCanvasWindowFrame: TileMotionEstimator.PreparedFrame?
        /// 最近一次 `push` 的诊断信息（供实时日志排查）
        private(set) var lastEstimate: TileMotionEstimator.Estimate?
        private(set) var lastPrepMs: Int = 0
        private(set) var lastEstMs: Int = 0

        var hasScrolled: Bool { contributingFrameCount > 1 || maxViewportPosition > 0 }

        init(options: Options = Options()) {
            self.options = options
        }

        /// 从已拼画布提取当前 `viewportPosition` 处高度为 `height` 的参考切片（零漂移对齐用）
        private func loadCanvasWindowReference(height: Int) -> TileMotionEstimator.PreparedFrame? {
            guard canvasWidth > 8, height > options.minOverlap,
                  viewportPosition >= 0, viewportPosition + height <= canvasHeight else {
                return nil
            }
            if let cached = cachedCanvasWindowFrame,
               cachedCanvasWindowPos == viewportPosition,
               cached.height == height {
                return cached
            }
            let rowBytes = canvasWidth * 4
            let byteStart = viewportPosition * rowBytes
            let byteEnd = (viewportPosition + height) * rowBytes
            guard byteStart >= 0, byteEnd <= canvasPixels.count else { return nil }
            let slice = canvasPixels.subdata(in: byteStart..<byteEnd)
            guard let prepared = TileMotionEstimator.PreparedFrame(
                rgbaSlice: slice, width: canvasWidth, height: height,
                downsample: options.estimatorOptions.downsample) else {
                return nil
            }
            cachedCanvasWindowPos = viewportPosition
            cachedCanvasWindowFrame = prepared
            return prepared
        }

        /// 推入一帧并立即完成运动估计与增量画布合成。
        @discardableResult
        func push(_ frame: CGImage) -> PushStatus {
            pushedCount += 1
            lastEstimate = nil
            lastPrepMs = 0
            lastEstMs = 0
            let t0 = DispatchTime.now().uptimeNanoseconds

            if referenceFrame == nil {
                guard frame.width > 8, frame.height > options.minOverlap,
                      let prepared = TileMotionEstimator.PreparedFrame(
                          cgImage: frame, downsample: options.estimatorOptions.downsample),
                      let initialRGBA = prepared.rgbaBand(yStart: 0, height: prepared.height) else {
                    lastPrepMs = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
                    return .skipped
                }
                lastPrepMs = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
                canvasWidth = prepared.width
                canvasHeight = prepared.height
                viewportHeight = prepared.height
                viewportPosition = 0
                maxViewportPosition = 0
                contributingFrameCount = 1
                firstFrameImage = frame
                canvasPixels = Data(capacity: initialRGBA.count * 3)
                canvasPixels.append(initialRGBA)
                referenceFrame = prepared
                referenceMode = .previousFrame
                cachedCanvasWindowPos = nil
                cachedCanvasWindowFrame = nil
                seams = [SeamInfo(
                    frameIndex: 0, overlapRows: 0,
                    contributedRows: prepared.height, offsetY: 0)]
                return .firstFrame
            }

            guard let rawRef = referenceFrame,
                  frame.width == canvasWidth,
                  frame.height > options.minOverlap,
                  let cur = TileMotionEstimator.PreparedFrame(
                      cgImage: frame, downsample: options.estimatorOptions.downsample) else {
                lastPrepMs = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
                return .skipped
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            lastPrepMs = Int((t1 - t0) / 1_000_000)

            // C memcmp 精确静止快判（始终对比最近原始帧，8MB < 0.4ms）+ 采样近静止快判
            if rawRef.height == cur.height && (rawRef.fullGray == cur.fullGray || Self.fastFramesIdentical(ref: rawRef, cur: cur)) {
                lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                return .staticFrame
            }

            // 回滚进入已拼区域后，优先用 CanvasWindow 与当前帧直接对齐以消除来回滚动累计漂移；
            // 若 CanvasWindow 未命中（如大幅越过边界或顶底栏占比较高），自动回退到 rawRef 兜底。
            var estimate: TileMotionEstimator.Estimate?
            var matchedRefHeight = rawRef.height
            if referenceMode == .canvasWindow,
               let canvasRef = loadCanvasWindowReference(height: cur.height),
               let canvasEst = TileMotionEstimator.estimateShift(
                   ref: canvasRef, cur: cur, options: options.estimatorOptions) {
                if case .motion = canvasEst.outcome {
                    estimate = canvasEst
                    matchedRefHeight = canvasRef.height
                }
            }
            if estimate == nil {
                estimate = TileMotionEstimator.estimateShift(
                    ref: rawRef, cur: cur, options: options.estimatorOptions)
                matchedRefHeight = rawRef.height
            }

            guard let estimate else {
                lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                return .skipped
            }
            lastEstimate = estimate
            lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)

            switch estimate.outcome {
            case .noMotion:
                return .staticFrame
            case .indeterminate:
                return .skipped
            case .motion(let dy):
                guard dy != 0 else { return .staticFrame }
                let minH = min(matchedRefHeight, cur.height)
                let overlap = minH - abs(dy)
                guard overlap >= options.minOverlap else {
                    return .skipped
                }

                let curH = cur.height
                let rowBytes = canvasWidth * 4
                let candidate = viewportPosition - dy

                // 检测相邻原始帧的静态顶栏/底栏带（必须用 rawRef 与 cur 比较，才能检出固定顶底栏）
                let (staticTop, staticBottom) = rawRef.height == cur.height
                    ? Self.detectStaticVerticalBands(ref: rawRef, cur: cur)
                    : (0, 0)

                if candidate + curH > canvasHeight {
                    // 向下扩展画布（Append）
                    let growth = (candidate + curH) - canvasHeight
                    guard growth > 0, growth < curH else { return .skipped }
                    let desiredBand = max(curH / 2, max(curH / 4 + growth, growth + staticBottom))
                    let maxCleanBand = max(growth, curH - staticTop)
                    let band = min(curH, min(desiredBand, maxCleanBand))
                    let bandOverlap = band - growth
                    guard bandOverlap >= 0, bandOverlap <= canvasHeight else { return .skipped }

                    let oldEnd = canvasHeight - bandOverlap
                    let incomingStart = curH - band
                    guard let bandRGBA = cur.rgbaBand(yStart: incomingStart, height: band) else {
                        return .skipped
                    }
                    if bandOverlap > 0 {
                        canvasPixels.removeLast(bandOverlap * rowBytes)
                    }
                    canvasPixels.append(bandRGBA)
                    canvasHeight = oldEnd + band
                    viewportPosition = candidate
                    maxViewportPosition = max(maxViewportPosition, candidate)
                    referenceFrame = cur
                    referenceMode = .previousFrame
                    cachedCanvasWindowPos = nil
                    cachedCanvasWindowFrame = nil
                    contributingFrameCount += 1

                    let seamOverlap = curH - growth
                    seams.append(SeamInfo(
                        frameIndex: seams.count,
                        overlapRows: seamOverlap,
                        contributedRows: growth,
                        offsetY: candidate
                    ))
                    return .appended(growthRows: growth, totalHeight: canvasHeight)
                } else if candidate >= 0 {
                    // 在已合成画布范围内回弹/回滚（Contained）：不破坏画布，切到 CanvasWindow 参考模式防漂移
                    viewportPosition = candidate
                    referenceFrame = cur
                    referenceMode = .canvasWindow
                    return .contained(positionY: candidate, totalHeight: canvasHeight)
                } else {
                    // 向上超出画布顶部（Prepend）
                    let growth = -candidate
                    guard growth > 0, growth < curH else { return .skipped }
                    let desiredBand = max(curH / 2, max(curH / 4 + growth, growth + staticTop))
                    let maxCleanBand = max(growth, curH - staticBottom)
                    let band = min(curH, min(desiredBand, maxCleanBand))
                    let oldStart = band - growth
                    guard oldStart >= 0, oldStart <= canvasHeight else { return .skipped }
                    guard let bandRGBA = cur.rgbaBand(yStart: 0, height: band) else {
                        return .skipped
                    }

                    var nextCanvas = Data(capacity: (canvasHeight + growth) * rowBytes)
                    nextCanvas.append(bandRGBA)
                    nextCanvas.append(canvasPixels[(oldStart * rowBytes)..<(canvasHeight * rowBytes)])
                    canvasPixels = nextCanvas
                    canvasHeight += growth
                    viewportPosition = 0
                    maxViewportPosition += growth
                    referenceFrame = cur
                    referenceMode = .previousFrame
                    cachedCanvasWindowPos = nil
                    cachedCanvasWindowFrame = nil
                    contributingFrameCount += 1

                    seams = seams.map { seam in
                        SeamInfo(
                            frameIndex: seam.frameIndex + 1,
                            overlapRows: seam.overlapRows,
                            contributedRows: seam.contributedRows,
                            offsetY: seam.offsetY + growth
                        )
                    }
                    seams.insert(SeamInfo(
                        frameIndex: 0,
                        overlapRows: curH - growth,
                        contributedRows: growth,
                        offsetY: 0
                    ), at: 0)
                    return .prepended(growthRows: growth, totalHeight: canvasHeight)
                }
            }
        }

        /// 将增量画布毫秒级导出为 CGImage。
        func finish() throws -> Result {
            guard canvasWidth > 0, canvasHeight > 0, !canvasPixels.isEmpty else {
                throw StitcherError.noFrames
            }
            if contributingFrameCount == 1, let single = firstFrameImage,
               single.width == canvasWidth, single.height == canvasHeight {
                return Result(image: single, seams: seams)
            }
            guard let ctx = PixelBuffer.makeContext(
                width: canvasWidth,
                height: canvasHeight,
                bytesPerRow: canvasWidth * 4,
                preferredColorSpace: firstFrameImage?.colorSpace
            ), let ptr = ctx.data else {
                throw StitcherError.renderFailed("CGContext 创建失败（\(canvasWidth)x\(canvasHeight)）")
            }
            canvasPixels.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    memcpy(ptr, base, canvasPixels.count)
                }
            }
            guard let image = ctx.makeImage() else {
                throw StitcherError.renderFailed("makeImage 失败")
            }
            return Result(image: image, seams: seams)
        }

        // MARK: - 静态带检测与快判

        private static func fastFramesIdentical(
            ref: TileMotionEstimator.PreparedFrame,
            cur: TileMotionEstimator.PreparedFrame
        ) -> Bool {
            let w = ref.width
            let h = ref.height
            let stepY = max(1, h / 32)
            let stepX = max(1, w / 32)
            var sum = 0
            var count = 0
            var maxDiff = 0
            ref.fullGray.withUnsafeBytes { rRaw in
                cur.fullGray.withUnsafeBytes { cRaw in
                    guard let rPtr = rRaw.bindMemory(to: UInt8.self).baseAddress,
                          let cPtr = cRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                    var y = 0
                    while y < h {
                        let row = y * w
                        var x = 0
                        while x < w {
                            let d = abs(Int(rPtr[row + x]) - Int(cPtr[row + x]))
                            sum += d
                            if d > maxDiff { maxDiff = d }
                            count += 1
                            x += stepX
                        }
                        y += stepY
                    }
                }
            }
            return count > 0 && maxDiff <= 3 && Double(sum) / Double(count) < 0.8
        }

        /// 检测相邻两帧在顶缘与底缘的静止带（如 sticky header / footer），返回像素行数上限各 ≤ 45% 帧高。
        private static func detectStaticVerticalBands(
            ref: TileMotionEstimator.PreparedFrame,
            cur: TileMotionEstimator.PreparedFrame
        ) -> (top: Int, bottom: Int) {
            let w = ref.width
            let h = min(ref.height, cur.height)
            let maxBand = (h * 45) / 100
            let stepX = max(1, w / 48)

            func rowMatches(_ y: Int, rPtr: UnsafePointer<UInt8>, cPtr: UnsafePointer<UInt8>) -> Bool {
                let row = y * w
                var sum = 0
                var count = 0
                var x = 0
                while x < w {
                    sum += abs(Int(rPtr[row + x]) - Int(cPtr[row + x]))
                    count += 1
                    x += stepX
                }
                return count > 0 && (sum * 10) <= (count * 35) // mean diff <= 3.5
            }

            var topRows = 0
            var bottomRows = 0
            ref.fullGray.withUnsafeBytes { rRaw in
                cur.fullGray.withUnsafeBytes { cRaw in
                    guard let rPtr = rRaw.bindMemory(to: UInt8.self).baseAddress,
                          let cPtr = cRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                    for y in 0..<maxBand {
                        if rowMatches(y, rPtr: rPtr, cPtr: cPtr) {
                            topRows += 1
                        } else {
                            break
                        }
                    }
                    for offset in 0..<maxBand {
                        let y = h - 1 - offset
                        if y <= topRows { break }
                        if rowMatches(y, rPtr: rPtr, cPtr: cPtr) {
                            bottomRows += 1
                        } else {
                            break
                        }
                    }
                }
            }
            // 仅把连续 ≥ 12px 的静止带视为 sticky UI，避免单行空白边缘误触发
            return (topRows >= 12 ? topRows : 0, bottomRows >= 12 ? bottomRows : 0)
        }
    }

    // MARK: - 批量入口

    /// 拼接帧序列为纵向长图（底层复用 `Stitcher.Session` 与 `TileMotionEstimator`）。
    static func stitch(frames: [CGImage], options: Options = Options()) throws -> Result {
        guard !frames.isEmpty else { throw StitcherError.noFrames }

        let expectedWidth = frames[0].width
        for (index, frame) in frames.enumerated() {
            if frame.width != expectedWidth {
                throw StitcherError.widthMismatch(
                    expected: expectedWidth, actual: frame.width, frameIndex: index)
            }
            if frame.height <= options.minOverlap {
                throw StitcherError.frameTooSmall(
                    frameIndex: index, height: frame.height, minOverlap: options.minOverlap)
            }
        }

        let session = Session(options: options)
        for (index, frame) in frames.enumerated() {
            if index % 2 == 0, Task.isCancelled { throw StitcherError.cancelled }
            let status = session.push(frame)
            if index == 0 {
                guard case .firstFrame = status else {
                    throw StitcherError.frameTooSmall(
                        frameIndex: 0, height: frame.height, minOverlap: options.minOverlap)
                }
                continue
            }
            switch status {
            case .appended, .prepended, .contained:
                break
            case .staticFrame, .skipped, .firstFrame:
                throw StitcherError.noOverlapFound(frameIndex: index)
            }
        }
        return try session.finish()
    }
}

// MARK: - 像素缓冲与行签名（保留供校验工具与外部对比使用）

/// 单帧的只读像素缓冲（RGBA8）+ 预计算行签名。
struct PixelBuffer: Sendable {
    let width: Int
    let height: Int
    private let data: [UInt8]
    /// 每行签名：沿宽度均匀采样 `samples` 个点的亮度值（0...255）
    let signature: [[UInt8]]

    init(cgImage: CGImage, samples: Int = 64) {
        let w = cgImage.width
        let h = cgImage.height
        self.width = w
        self.height = h

        guard let ctx = Self.makeContext(
            width: w,
            height: h,
            bytesPerRow: w * 4,
            preferredColorSpace: cgImage.colorSpace
        ) else {
            self.data = []
            self.signature = []
            return
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let ptr = ctx.data {
            self.data = Array(UnsafeBufferPointer(
                start: ptr.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        } else {
            self.data = []
        }
        let pixelData = self.data
        self.signature = (0..<h).map { row in
            Self.rowSignatureY(data: pixelData, width: w, y: row, samples: samples)
        }
    }

    /// 优先沿用源图 RGB 色域（如 Display P3），避免每帧做广色域→sRGB 重采样与色偏；不支持时回落 sRGB
    static func makeContext(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        preferredColorSpace: CGColorSpace?
    ) -> CGContext? {
        if let preferred = preferredColorSpace,
           preferred.model == .rgb,
           !CGColorSpaceUsesExtendedRange(preferred),
           let ctx = CGContext(
               data: nil,
               width: width,
               height: height,
               bitsPerComponent: 8,
               bytesPerRow: bytesPerRow,
               space: preferred,
               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
           ) {
            return ctx
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    private static func rowSignatureY(data: [UInt8], width: Int, y: Int, samples: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: samples)
        let base = y * width * 4
        guard !data.isEmpty else { return out }
        for s in 0..<samples {
            let x = (2 * s + 1) * width / (2 * samples)
            let p = base + x * 4
            let r = UInt32(data[p])
            let g = UInt32(data[p + 1])
            let b = UInt32(data[p + 2])
            out[s] = UInt8(truncatingIfNeeded: (77 * r + 150 * g + 29 * b) >> 8)
        }
        return out
    }

    static func rowMatches(_ a: [UInt8], _ b: [UInt8], threshold: UInt32) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var total: UInt32 = 0
        for i in 0..<a.count {
            let d = a[i] > b[i] ? UInt32(a[i] - b[i]) : UInt32(b[i] - a[i])
            total += d
        }
        let mean = total / UInt32(a.count)
        return mean <= threshold
    }
}
