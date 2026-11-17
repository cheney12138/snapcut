import CoreGraphics
import Foundation

/// Tile-NCC 位移估计器（SnowShot snow-stitch-images 同思想,Swift 轻量实现）
///
/// 背景（病例 2026-11-17 Safari 卡片页「没拼接成功」三轮实录）：
/// 行签名（整行 64 点平均亮度）对「90% 行静止 + 卡片局部滚动」的结构性误判
/// ——静止区采样点稀释滚动区,任何大 overlap 候选都能糊弄过去 → 每帧贡献
/// 1-5px → 10 帧拼出 2 屏。SnowShot 的解法核心：
/// 1. 帧降采样灰度 → 切 tile 网格 → **per-tile NCC**（纹理方差归一）
/// 2. **无纹理 tile 剔除**（方差 < 阈值 = 纯色背景/页眉,不参与投票）
/// 3. 位移候选由 tile 投票产生,不是整行匹配
///
/// 本实现（tile NCC + 位移直方图投票,免 ORB）：
/// - `estimateShift`：对候选位移全量枚举（粗步长）,每个位移的得分 =
///   Σ(纹理权重 × tile NCC)；最优位移 = 得分峰
/// - 局部滚动的卡片 tile 会在真实位移处贡献高分,静止区 tile 在 offset=0
///   处贡献高分——两派竞争,**覆盖面积大的一方胜**（整页滚动 offset=0 但
///   全页 tile 都在动;卡片页卡片 tile 数量多则卡片位移胜出）
/// - 返回 (dy, confidence)：dy<0 = cur 相对 prev 向下滚（正贡献）；dy=0
///   且高分 = 静止
enum TileMotionEstimator {

    struct Estimate {
        /// 帧间位移（像素, Y-down：正值 = cur 内容相对 prev 下移 = 页面下滚）
        let dy: Int
        /// 峰值得分 / 总纹理权重（0-1）
        let confidence: Double
        /// 参与投票的纹理 tile 数
        let texturedTiles: Int
    }

    /// 参数
    struct Options {
        /// 降采样倍率（性能：4x 后 3840x2100 → 960x525）
        var downsample: Int = 4
        /// tile 边长（降采样坐标系）
        var tileSize: Int = 24
        /// 纹理阈值：tile 亮度方差低于此 = 无纹理,剔除投票
        var textureThreshold: Double = 0.0005
        /// NCC 视为「同内容」的相似度下限
        var nccAccept: Double = 0.6
        /// 候选位移枚举范围（± maxRatio×帧高）与粗步长
        var maxShiftRatio: Double = 0.85
        var coarseStep: Int = 2
    }

    // MARK: - 入口

    /// 估计 ref → cur 的垂直位移。
    /// 线程语义：纯函数,任意线程可调用（建议后台——两帧 tile 化有解码成本）。
    static func estimateShift(ref: CGImage, cur: CGImage, options: Options = Options()) -> Estimate? {
        guard ref.width == cur.width, ref.height == cur.height, ref.height > 64 else { return nil }
        let grayRef = grayscaleTiles(image: ref, options: options)
        let grayCur = grayscaleTiles(image: cur, options: options)
        guard let grayRef, let grayCur else { return nil }

        let tiles = tileGrid(width: grayRef.width, height: grayRef.height, tileSize: options.tileSize)
        guard !tiles.isEmpty else { return nil }

        // 纹理 tile：方差 ≥ 阈值（双方都要有纹理）
        var refTiles: [Tile] = []
        refTiles.reserveCapacity(tiles.count)
        for t in tiles {
            if let tile = extractTile(gray: grayRef, rect: t), tile.variance >= options.textureThreshold {
                refTiles.append(tile)
            }
        }
        guard refTiles.count >= 6 else {
            // 几乎无纹理（纯色页）——无法判定,交给上层按静止处理
            return Estimate(dy: 0, confidence: 0, texturedTiles: refTiles.count)
        }

        let maxShift = Int(Double(grayRef.height) * options.maxShiftRatio)
        let step = max(1, options.coarseStep)

        // 位移投票：每个候选 dy 的加权 NCC 得分
        var bestDy = 0
        var bestScore = 0.0
        var totalTextureWeight = 0.0
        for tile in refTiles { totalTextureWeight += textureWeight(tile.variance) }

        for dy in stride(from: -maxShift, through: maxShift, by: step) {
            var score = 0.0
            for tile in refTiles {
                let sampleY = Int(tile.cy) + dy
                guard sampleY >= 0, sampleY + options.tileSize <= grayCur.height else { continue }
                let ncc = tileNCC(
                    refGray: grayRef, refTile: tile,
                    curGray: grayCur, curOrigin: (Int(tile.cx), sampleY),
                    size: options.tileSize)
                if ncc >= options.nccAccept {
                    score += textureWeight(tile.variance) * ncc
                }
            }
            if score > bestScore {
                bestScore = score
                bestDy = dy
            }
        }

        let confidence = totalTextureWeight > 0 ? bestScore / totalTextureWeight : 0
        return Estimate(dy: bestDy, confidence: confidence, texturedTiles: refTiles.count)
    }

    // MARK: - 灰度 tile 化

    private struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]   // 单通道
    }

    private struct Tile {
        let cx: Int    // tile 左上（降采样坐标）
        let cy: Int
        let variance: Double
        let mean: Double
        let data: [Double]   // 中心化亮度（用于 NCC）
    }

    private static func grayscaleTiles(image: CGImage, options: Options) -> GrayImage? {
        let ds = max(1, options.downsample)
        let w = max(1, image.width / ds)
        let h = max(1, image.height / ds)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = ctx.data else { return nil }
        return GrayImage(width: w, height: h,
                         pixels: Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: w * h)))
    }

    private static func tileGrid(width: Int, height: Int, tileSize: Int) -> [CGRect] {
        var rects: [CGRect] = []
        let cols = width / tileSize
        let rows = height / tileSize
        for r in 0..<rows {
            for c in 0..<cols {
                rects.append(CGRect(x: c * tileSize, y: r * tileSize,
                                    width: tileSize, height: tileSize))
            }
        }
        return rects
    }

    private static func extractTile(gray: GrayImage, rect: CGRect) -> Tile? {
        let ts = Int(rect.width)
        let x0 = Int(rect.minX), y0 = Int(rect.minY)
        var sum = 0.0
        var values: [Double] = []
        values.reserveCapacity(ts * ts)
        for y in y0..<(y0 + ts) {
            let row = y * gray.width
            for x in x0..<(x0 + ts) {
                let v = Double(gray.pixels[row + x])
                values.append(v)
                sum += v
            }
        }
        let mean = sum / Double(values.count)
        var variance = 0.0
        for v in values { let d = v - mean; variance += d * d }
        variance /= Double(values.count)
        // 中心化
        for i in 0..<values.count { values[i] -= mean }
        return Tile(cx: x0, cy: y0, variance: variance, mean: mean, data: values)
    }

    private static func textureWeight(_ variance: Double) -> Double {
        // 线性截断：方差 0→0（无纹理零票）,≥0.01 满票
        min(1.0, variance / 0.01)
    }

    // MARK: - NCC

    private static func tileNCC(
        refGray: GrayImage, refTile: Tile,
        curGray: GrayImage, curOrigin: (Int, Int), size: Int
    ) -> Double {
        let (cx0, cy0) = curOrigin
        let ts = size
        var sumCur = 0.0
        for y in cy0..<(cy0 + ts) {
            let row = y * curGray.width
            for x in cx0..<(cx0 + ts) { sumCur += Double(curGray.pixels[row + x]) }
        }
        let meanCur = sumCur / Double(ts * ts)
        var dot = 0.0
        var energyCur = 0.0
        var i = 0
        for y in cy0..<(cy0 + ts) {
            let row = y * curGray.width
            for x in cx0..<(cx0 + ts) {
                let dc = Double(curGray.pixels[row + x]) - meanCur
                dot += refTile.data[i] * dc
                energyCur += dc * dc
                i += 1
            }
        }
        let energyRef = refTile.data.reduce(0.0) { $0 + $1 * $1 }
        let denom = (energyRef * energyCur).squareRoot()
        guard denom > 1e-9 else { return 0 }
        let ncc = dot / denom
        return ncc < 0 ? 0 : Double(ncc)
    }
}
