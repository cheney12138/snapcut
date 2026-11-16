import CoreGraphics
import Foundation

/// 滚动截图拼接器（Stitcher）
///
/// 输入按时间顺序排列的帧（相邻帧之间存在垂直重叠），输出一张纵向长图与接缝信息。
///
/// 算法概述：
/// 1. 每帧解码为 RGBA8 像素缓冲，并预计算每行的「行签名」（沿宽度均匀采样的亮度序列）；
/// 2. 相邻两帧 (prev, cur) 之间，候选重叠行数从大到小枚举（overlap = prevH - d，
///    d 为 cur 第 0 行对齐到 prev 的行号）；对每个候选，逐行比对 prev[d+i] 与 cur[i] 的
///    行签名，行级容差（平均绝对差 ≤ 阈值）用于吸收 Retina 采样 / 抗锯齿噪声；
///    不匹配行占比 ≤ 容差比例即视为该候选成立，取第一个（即最大重叠）成立的候选；
/// 3. 从第一帧开始按累计偏移逐帧把 CGImage 画进同一个输出 CGContext（逐段 draw，
///    不做整图像素级拷贝），最终 makeImage 得到长图。
///
/// 内存约束：除输入帧本身外，额外内存只有每帧的行签名（行数 × 采样数，约几十 KB）
/// 和一张输出画布；输出画布通过 CGContext 逐帧 draw 合成，不会把长图展开成多份 RGBA。
///
/// 线程语义：`Stitcher` 是无状态的纯函数入口，`stitch` 为同步 CPU 密集型操作，
/// 可在任意线程 / 队列调用（不要在主线程调用大图拼接）；内部不共享任何可变状态，
/// 传入的 CGImage 在拼接过程中只读。
enum Stitcher {

    // MARK: - 公共类型

    /// 单帧在长图中的接缝信息
    struct SeamInfo: Equatable {
        /// 帧在输入数组中的下标（0 起始）
        let frameIndex: Int
        /// 该帧与上一帧检测到的重叠行数（首帧为 0）
        let overlapRows: Int
        /// 该帧对长图的净贡献行数 = 帧高 - 重叠行数（首帧 = 帧高）
        let contributedRows: Int
        /// 该帧第 0 行在输出长图中的 y 偏移（像素，长图顶部为 0）
        let offsetY: Int
    }

    /// 拼接结果
    struct Result {
        /// 拼接成的长图（宽 = 输入帧宽，高 = Σ各帧净贡献行数）
        let image: CGImage
        /// 每帧的接缝信息，与输入帧顺序一致
        let seams: [SeamInfo]
    }

    /// 可调参数
    struct Options {
        /// 相邻帧最小可信重叠行数（小于此值不认为是滚动重叠）
        var minOverlap: Int = 16
        /// 行签名比对容差：一行内采样点平均绝对亮度差超过该值视为「不匹配行」
        /// （Retina 缩放 / 抗锯齿噪声通常在个位数）
        /// 行签名比对容差：一行内采样点平均绝对亮度差超过该值视为「不匹配行」
        /// （Retina 缩放 / 抗锯齿噪声通常在个位数；真实滚动帧实测需要 24：
        /// 抗锯齿 + 滚动条 + 子像素位移会把正确对齐的行差拉到 17-23）
        var rowDiffThreshold: UInt32 = 24
        /// 允许的「不匹配行」占比上限（0.10 = 10%；默认 2% 在真实帧上
        /// 会把正确对齐误判为不匹配——2026-11-14 ScrollHost 实测病例）
        var maxMismatchRatio: Double = 0.10
        /// 行签名沿宽度方向的采样点数
        var signatureSamples: Int = 64
    }

    // MARK: - 错误

    enum StitcherError: LocalizedError {
        case noFrames
        case widthMismatch(expected: Int, actual: Int, frameIndex: Int)
        case frameTooSmall(frameIndex: Int, height: Int, minOverlap: Int)
        case noOverlapFound(frameIndex: Int)
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
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

    // MARK: - 入口

    /// 拼接帧序列为纵向长图。
    ///
    /// - Parameters:
    ///   - frames: 按时间顺序排列的帧，宽度必须一致（行数可以不等——滚动区域
    ///     grow 后新帧更高是正常序列，纵向拼接按内容行对齐）；相邻帧需存在垂直重叠。
    ///   - options: 可调参数，见 `Options`。
    /// - Returns: 长图与每帧接缝信息。
    /// - Throws: `StitcherError`。
    ///
    /// 线程语义：同步、阻塞、无状态；可在任意线程调用，大图建议放后台队列。
    static func stitch(frames: [CGImage], options: Options = Options()) throws -> Result {
        guard !frames.isEmpty else { throw StitcherError.noFrames }

        let buffers = try frames.enumerated().map { index, image -> PixelBuffer in
            guard index == 0 || image.width == frames[0].width else {
                throw StitcherError.widthMismatch(
                    expected: frames[0].width, actual: image.width, frameIndex: index)
            }
            return PixelBuffer(cgImage: image)
        }

        var seams: [SeamInfo] = []
        var offsets: [Int] = []
        var runningY = 0

        for (index, buffer) in buffers.enumerated() {
            if index == 0 {
                guard buffer.height > options.minOverlap else {
                    throw StitcherError.frameTooSmall(
                        frameIndex: 0, height: buffer.height, minOverlap: options.minOverlap)
                }
                seams.append(SeamInfo(
                    frameIndex: 0, overlapRows: 0,
                    contributedRows: buffer.height, offsetY: 0))
                offsets.append(0)
                // runningY 语义：当前帧第 0 行在输出中的偏移（帧 0 = 0）
                runningY = 0
                continue
            }

            let (overlap, _) = try findOverlap(
                prev: buffers[index - 1], cur: buffer, options: options, frameIndex: index)
            let contributed = buffer.height - overlap
            // cur 第 0 行在输出中的位置 = prev 第 0 行位置 + prev 高度 - 重叠
            runningY += buffers[index - 1].height - overlap
            seams.append(SeamInfo(
                frameIndex: index, overlapRows: overlap,
                contributedRows: contributed, offsetY: runningY))
            offsets.append(runningY)
        }

        // 总高 = 最后一帧第 0 行位置 + 最后一帧高度
        let totalHeight = runningY + buffers[buffers.count - 1].height
        let image = try compose(frames: frames, offsets: offsets,
                                totalHeight: totalHeight, width: frames[0].width)
        return Result(image: image, seams: seams)
    }

    // MARK: - 重叠检测

    /// 在 prev / cur 之间寻找最大可信垂直重叠。
    /// 返回 `(overlap, d)`：cur 的第 i 行对齐 prev 的第 d+i 行，overlap = prevH - d。
    /// 线程语义：纯函数，任意线程可调用。
    static func findOverlap(
        prev: PixelBuffer, cur: PixelBuffer, options: Options, frameIndex: Int
    ) throws -> (overlap: Int, d: Int) {
        guard prev.height > options.minOverlap, cur.height > options.minOverlap else {
            throw StitcherError.frameTooSmall(
                frameIndex: frameIndex, height: min(prev.height, cur.height),
                minOverlap: options.minOverlap)
        }
        // cur 必须至少净贡献 1 行，否则会死循环拼接静止画面
        let maxOverlap = min(prev.height, cur.height) - 1
        guard maxOverlap >= options.minOverlap else {
            throw StitcherError.noOverlapFound(frameIndex: frameIndex)
        }

        // 重叠从大到小枚举：滚动捕获场景下最大可信重叠即真实重叠
        for overlap in stride(from: maxOverlap, through: options.minOverlap, by: -1) {
            let d = prev.height - overlap
            if alignmentPasses(prev: prev, cur: cur, d: d, overlap: overlap, options: options) {
                return (overlap, d)
            }
        }
        throw StitcherError.noOverlapFound(frameIndex: frameIndex)
    }

    /// 校验对齐假设：prev 第 d+i 行 ≈ cur 第 i 行（i ∈ [0, overlap)）。
    /// 行级容差见 `Options.rowDiffThreshold` / `maxMismatchRatio`；不匹配行超限即刻短路返回。
    ///
    /// 性能（病例：3840×2098 两帧候选 ~2080 个 × 全行比对 ⇒ compose 卡 10s）：
    /// 两阶段扫描——① 粗筛探针：每 overlap/24 行抽 1 行（行签名本身已是灰度降采样，
    /// 64 采样点/行），伪候选在 ~几行内即被否掉（绝大多数候选在此剪枝，成本 ~24 次
    /// rowMatch）；② 细验：只对通过粗筛的候选补齐其余行，最终判据与逐行全查完全
    /// 一致（不匹配行总数 ≤ maxMismatch），无误放行。
    /// 线程语义：纯函数，任意线程可调用。
    private static func alignmentPasses(
        prev: PixelBuffer, cur: PixelBuffer, d: Int, overlap: Int, options: Options
    ) -> Bool {
        var mismatches = 0
        let maxMismatch = Int(Double(overlap) * options.maxMismatchRatio)
        let probeStride = max(1, overlap / 24)
        // ① 粗筛探针（剪枝）
        var row = 0
        while row < overlap {
            if !PixelBuffer.rowMatches(prev.signature[d + row], cur.signature[row],
                                       threshold: options.rowDiffThreshold) {
                mismatches += 1
                if mismatches > maxMismatch { return false }
            }
            row += probeStride
        }
        // ② 细验：粗筛未覆盖的行（保持与全量逐行一致的判据）
        for i in 0..<overlap where i % probeStride != 0 {
            if !PixelBuffer.rowMatches(prev.signature[d + i], cur.signature[i],
                                       threshold: options.rowDiffThreshold) {
                mismatches += 1
                if mismatches > maxMismatch { return false }
            }
        }
        return true
    }

    // MARK: - 合成

    /// 把各帧按 offsetY 逐段 draw 进同一张输出画布（CGContext 逐帧 draw，
    /// 不做长图整份像素拷贝），返回最终 CGImage。
    /// 线程语义：纯函数，任意线程可调用。
    private static func compose(
        frames: [CGImage], offsets: [Int], totalHeight: Int, width: Int
    ) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw StitcherError.renderFailed("CGContext 创建失败（\(width)x\(totalHeight)）")
        }
        // CGContext 坐标系原点在左下：第 i 帧顶部需落在长图第 offsetY_i 行，
        // 故绘制矩形 y = totalHeight - offsetY - frameHeight（无翻转变换，
        // 图像内容保持正向）。
        for (index, frame) in frames.enumerated() {
            let y = totalHeight - offsets[index] - frame.height
            ctx.draw(frame, in: CGRect(x: 0, y: CGFloat(y),
                                       width: CGFloat(frame.width),
                                       height: CGFloat(frame.height)))
        }
        guard let image = ctx.makeImage() else {
            throw StitcherError.renderFailed("makeImage 失败")
        }
        return image
    }
}

// MARK: - 像素缓冲与行签名

/// 单帧的只读像素缓冲（RGBA8）+ 预计算行签名。
///
/// 线程语义：初始化后完全不可变，可在任意线程并发读取。
struct PixelBuffer {
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

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // 统一转成 RGBA8（RGBX），屏蔽输入图各自的字节序 / alpha 布局差异
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            // 极端情况（超大图分配失败）——给空缓冲，后续比对自然失败并报 noOverlap
            self.data = []
            self.signature = []
            print("[Stitcher] PixelBuffer: CGContext 创建失败 (\(w)x\(h))")
            return
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let ptr = ctx.data {
            self.data = Array(UnsafeBufferPointer(
                start: ptr.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        } else {
            self.data = []
            print("[Stitcher] PixelBuffer: 位图数据指针为空 (\(w)x\(h))")
        }
        let pixelData = self.data
        self.signature = (0..<h).map { row in
            Self.rowSignatureY(data: pixelData, width: w, y: row, samples: samples)
        }
    }

    /// 计算第 y 行的亮度签名（77R+150G+29B 近似 BT.601 亮度）。
    private static func rowSignatureY(data: [UInt8], width: Int, y: Int, samples: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: samples)
        let base = y * width * 4
        guard !data.isEmpty else { return out }
        for s in 0..<samples {
            // 等距采样，落在像素中心
            let x = (2 * s + 1) * width / (2 * samples)
            let p = base + x * 4
            let r = UInt32(data[p])
            let g = UInt32(data[p + 1])
            let b = UInt32(data[p + 2])
            out[s] = UInt8(truncatingIfNeeded: (77 * r + 150 * g + 29 * b) >> 8)
        }
        return out
    }

    /// 两行签名是否在容差内视为同一行。
    /// 判据：采样点平均绝对亮度差 ≤ threshold（Retina 噪声 / 抗锯齿通常 < 5）。
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
