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
        /// 原始关键帧档案条目：`offsetY` 为该帧首行在画布坐标系（Y-down，长图顶 = 0）中的绝对偏移。
        private struct KeyframeAnchor {
            var offsetY: Int
            let frame: TileMotionEstimator.PreparedFrame
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
        /// 原始关键帧档案（**始终是未剥离 sticky UI 的原始帧**）——回滚重定位与边界防重的唯一依据。
        /// 绝对不能用 `canvasPixels` 切片当参考：那份像素已剥掉 sticky 顶栏、且重复盖印了 sticky 侧栏，
        /// 固定 UI 屏蔽会失效，在高度重复的表格行上疯狂漂移（Raptor 网页实机病例根因）。
        private var keyframes: [KeyframeAnchor] = []
        /// 关键帧内存上限：超出后保留首尾锚点，中间按间距稀疏淘汰（4K 长滚动不占满内存）
        private let maxKeyframes = 12
        /// 是否发生过向下扩展（Append）：为 true 时向上越界必须由顶锚点高置信度确认才放行 Prepend
        private var hasAppendedDownward = false
        /// 最近一次 `push` 的诊断信息（供实时日志排查）
        private(set) var lastEstimate: TileMotionEstimator.Estimate?
        private(set) var lastPrepMs: Int = 0
        private(set) var lastEstMs: Int = 0

        var hasScrolled: Bool { contributingFrameCount > 1 || maxViewportPosition > 0 }

        init(options: Options = Options()) {
            self.options = options
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
                keyframes = [KeyframeAnchor(offsetY: 0, frame: prepared)]
                hasAppendedDownward = false
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

            // 已采关键帧快判（<0.1ms）：画面回到曾采集过的位置时直接锚回，
            // 避免「反复来回滚动」在重复表格行上逐帧累计漂移。
            if let hit = matchCapturedKeyframe(cur: cur) {
                referenceFrame = cur
                lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                if abs(viewportPosition - hit.offsetY) <= 2 {
                    return .staticFrame
                }
                viewportPosition = hit.offsetY
                return .contained(positionY: hit.offsetY, totalHeight: canvasHeight)
            }

            // 主位移估计**始终**用原始帧 rawRef：canvasPixels 切片已剥掉 sticky 顶栏、且重复盖印侧栏，
            // 拿它当主参考会让 fixed UI 屏蔽失效（Raptor 网页实机病例：重复表格行上 posY 疯狂漂移）。
            guard let rawEstimate = TileMotionEstimator.estimateShift(
                ref: rawRef, cur: cur, options: options.estimatorOptions) else {
                lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                return .skipped
            }
            lastEstimate = rawEstimate

            switch rawEstimate.outcome {
            case .noMotion:
                lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                return .staticFrame
            case .indeterminate:
                // 兜底重定位：高速扇屏/跳帧后恰好落回已采关键帧附近时直接锚回已拼区域
                let anchored = reanchorAfterIndeterminate(cur: cur)
                lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                if let anchored {
                    referenceFrame = cur
                    viewportPosition = anchored
                    return .contained(positionY: anchored, totalHeight: canvasHeight)
                }
                return .skipped
            case .motion(let dy):
                guard dy != 0 else {
                    lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                    return .staticFrame
                }
                let minH = min(rawRef.height, cur.height)
                let overlap = minH - abs(dy)
                guard overlap >= options.minOverlap else {
                    lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                    return .skipped
                }

                let curH = cur.height
                let rowBytes = canvasWidth * 4
                // 关键帧重定位 + 边界防重闸门（顶锚点核验 / 底锚点核验 / 内部零漂移锚定）
                let candidate = reanchorWithKeyframes(
                    cur: cur, candidate: viewportPosition - dy, curH: curH).pos
                lastEstMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)

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
                    recordKeyframe(offsetY: candidate, frame: cur)
                    hasAppendedDownward = true
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
                    // 在已合成画布范围内回弹/回滚（Contained）：不破坏画布，靠关键帧档案保持零漂移
                    viewportPosition = candidate
                    referenceFrame = cur
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
                    shiftKeyframes(deltaY: growth)
                    recordKeyframe(offsetY: 0, frame: cur)
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

        // MARK: - 原始关键帧档案与关键帧重定位

        /// 记录一个原始关键帧（按 `offsetY` 去重后插入）并做裁剪。
        private func recordKeyframe(offsetY: Int, frame: TileMotionEstimator.PreparedFrame) {
            keyframes.removeAll { $0.offsetY == offsetY }
            keyframes.append(KeyframeAnchor(offsetY: offsetY, frame: frame))
            trimKeyframes()
        }

        /// Prepend 后已有关键帧在画布坐标系整体下移 `deltaY`。
        private func shiftKeyframes(deltaY: Int) {
            for i in keyframes.indices {
                keyframes[i].offsetY += deltaY
            }
        }

        /// 关键帧数量裁剪：保留首帧（顶锚点）与末帧（底锚点），中间按间距稀疏淘汰。
        private func trimKeyframes() {
            keyframes.sort { $0.offsetY < $1.offsetY }
            guard keyframes.count > maxKeyframes, let first = keyframes.first,
                  let last = keyframes.last else { return }
            let middle = Array(keyframes[1..<(keyframes.count - 1)])
            guard !middle.isEmpty else { return }
            let slots = max(1, maxKeyframes - 2)
            var kept: [KeyframeAnchor] = []
            var seen = Set<Int>()
            for slot in 0..<slots {
                let idx = min(middle.count - 1, (slot * middle.count) / slots)
                let anchor = middle[idx]
                if seen.insert(anchor.offsetY).inserted {
                    kept.append(anchor)
                }
            }
            keyframes = [first] + kept + [last]
        }

        /// 找离 `position` 最近的、且不是 `excludingImage` 的关键帧（不重复计算同一个 prepared frame）。
        private func nearestKeyframe(
            to position: Int,
            excludingImage: CGImage? = nil
        ) -> KeyframeAnchor? {
            var best: KeyframeAnchor?
            var bestDistance = Int.max
            for anchor in keyframes {
                if let excludingImage, anchor.frame.cgImage === excludingImage { continue }
                let distance = abs(anchor.offsetY - position)
                if distance < bestDistance {
                    bestDistance = distance
                    best = anchor
                }
            }
            return best
        }

        /// 已访问边界快判：当前帧是否就是某个已知关键帧（顶锚点 / 底锚点 / 离视口最近的关键帧）。
        /// 命中说明位置完全已知，直接锚回，不再依赖位移估计（全采样比对，< 0.1ms）。
        private func matchCapturedKeyframe(
            cur: TileMotionEstimator.PreparedFrame
        ) -> KeyframeAnchor? {
            var probes: [KeyframeAnchor] = []
            if let top = keyframes.first(where: { $0.offsetY == 0 }) {
                probes.append(top)
            }
            if maxViewportPosition > 0,
               let bottom = keyframes.last(where: { $0.offsetY == maxViewportPosition }) {
                probes.append(bottom)
            }
            if let nearest = nearestKeyframe(to: viewportPosition) {
                probes.append(nearest)
            }
            var checked = Set<Int>()
            for probe in probes {
                guard checked.insert(probe.offsetY).inserted else { continue }
                guard probe.frame.height == cur.height else { continue }
                guard probe.frame.cgImage !== cur.cgImage else { continue }
                if Self.fastFramesIdentical(ref: probe.frame, cur: cur) {
                    return probe
                }
            }
            return nil
        }

        /// `.indeterminate` 的兜底重定位：高速甩屏 / 跳帧后恰好落回已采关键帧附近时直接锚回。
        /// 最多额外跑 2 次关键帧复核，保证单帧耗时可控。
        private func reanchorAfterIndeterminate(
            cur: TileMotionEstimator.PreparedFrame
        ) -> Int? {
            let rawImage = referenceFrame?.cgImage
            var probes: [KeyframeAnchor] = []
            if let nearest = nearestKeyframe(to: viewportPosition, excludingImage: rawImage) {
                probes.append(nearest)
            }
            if let top = keyframes.first(where: { $0.offsetY == 0 }), top.frame.cgImage !== rawImage {
                probes.append(top)
            }
            if maxViewportPosition > 0,
               let bottom = keyframes.last(where: { $0.offsetY == maxViewportPosition }),
               bottom.frame.cgImage !== rawImage {
                probes.append(bottom)
            }
            var tried = Set<Int>()
            for probe in probes.prefix(2) {
                guard tried.insert(probe.offsetY).inserted else { continue }
                guard let estimate = TileMotionEstimator.estimateShift(
                    ref: probe.frame, cur: cur, options: options.estimatorOptions) else { continue }
                guard estimate.confidence >= 0.65, estimate.preciseError <= 0.025,
                      case .motion(let probeDy) = estimate.outcome else { continue }
                let anchoredPos = probe.offsetY - probeDy
                if anchoredPos >= 0, anchoredPos <= maxViewportPosition {
                    return anchoredPos
                }
            }
            return nil
        }

        /// 关键帧重定位 + 边界防重闸门（去重核心）：
        /// - **顶边界核验**：准备向上越界时用顶锚点（`offsetY == 0`）反查真实位置，封堵漂移导致的假 Prepend；
        /// - **底边界核验**：准备向下越界时用底锚点（`offsetY == maxViewportPosition`）反查，封堵重复 Append；
        /// - **内部区间零漂移锚定**：落在已采区域内时用最近的原始关键帧锁住位置；
        /// - **已向下滚过的严格 Prepend 守卫**：必须由顶锚点高置信度确认真的向上越界才放行。
        private func reanchorWithKeyframes(
            cur: TileMotionEstimator.PreparedFrame,
            candidate: Int,
            curH: Int
        ) -> (pos: Int, matchedTop: Bool, matchedBottom: Bool, topEst: TileMotionEstimator.Estimate?) {
            var pos = candidate
            var matchedTop = false
            var matchedBottom = false
            var topEst: TileMotionEstimator.Estimate?
            let rawImage = referenceFrame?.cgImage
            let topKF = keyframes.first(where: { $0.offsetY == 0 })

            // 1) 顶边界核验（同一 prepared frame 直接跳过，不做冗余计算）
            if pos < curH / 2, let topKF, topKF.frame.cgImage !== rawImage,
               let estimate = TileMotionEstimator.estimateShift(
                   ref: topKF.frame, cur: cur, options: options.estimatorOptions) {
                topEst = estimate
                switch estimate.outcome {
                case .noMotion:
                    // 已在顶部：禁止 Prepend
                    pos = topKF.offsetY
                    matchedTop = true
                case .motion(let topDy):
                    let topOverlap = min(topKF.frame.height, curH) - abs(topDy)
                    if topOverlap >= options.minOverlap,
                       estimate.confidence >= 0.55, estimate.preciseError <= 0.035 {
                        let topPos = topKF.offsetY - topDy
                        pos = topPos
                        if topPos >= 0 { matchedTop = true }
                    }
                case .indeterminate:
                    break
                }
            }

            // 2) 底边界核验（仅在真正有「已采底部」时才做）
            if pos + curH > canvasHeight - curH / 2, maxViewportPosition > 0,
               let botKF = keyframes.last(where: { $0.offsetY == maxViewportPosition }),
               botKF.frame.cgImage !== rawImage,
               let estimate = TileMotionEstimator.estimateShift(
                   ref: botKF.frame, cur: cur, options: options.estimatorOptions) {
                switch estimate.outcome {
                case .noMotion:
                    // 已在底部：禁止重复 Append
                    pos = botKF.offsetY
                    matchedBottom = true
                case .motion(let botDy):
                    let botOverlap = min(botKF.frame.height, curH) - abs(botDy)
                    if botOverlap >= options.minOverlap,
                       estimate.confidence >= 0.55, estimate.preciseError <= 0.035 {
                        let botPos = botKF.offsetY - botDy
                        pos = botPos
                        if botPos <= maxViewportPosition { matchedBottom = true }
                    }
                case .indeterminate:
                    break
                }
            }

            // 3) 已采区间内部零漂移锚定（关键帧是原始画面，完整保留 sticky 顶栏/侧栏屏蔽能力）
            if !matchedTop, pos > 0, pos + curH <= canvasHeight,
               let anchor = nearestKeyframe(to: pos, excludingImage: rawImage),
               abs(anchor.offsetY - pos) < (curH * 65) / 100,
               let estimate = TileMotionEstimator.estimateShift(
                   ref: anchor.frame, cur: cur, options: options.estimatorOptions),
               case .motion(let anchorDy) = estimate.outcome,
               estimate.confidence >= 0.65, estimate.preciseError <= 0.025 {
                let anchoredPos = anchor.offsetY - anchorDy
                if anchoredPos >= 0, anchoredPos <= maxViewportPosition {
                    pos = anchoredPos
                }
            }

            // 4) 已向下滚动后的严格 Prepend 守卫：必须由顶锚点高置信度确认真的向上越界
            if hasAppendedDownward, pos < 0 {
                var confirmedOverflow = false
                if let topEst, case .motion(let topDy) = topEst.outcome, let topKF {
                    confirmedOverflow = (topKF.offsetY - topDy) < 0
                        && topEst.confidence >= 0.65
                        && topEst.preciseError <= 0.025
                }
                if !confirmedOverflow {
                    // 视为漂移/误判：钳制回顶部已拼区域，绝不把顶栏/侧栏重复贴到画布上方
                    pos = 0
                    matchedTop = true
                }
            }

            return (pos: pos, matchedTop: matchedTop, matchedBottom: matchedBottom, topEst: topEst)
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
