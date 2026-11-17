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
/// 性能纪律（病例「直接卡死了」：初版 840 tile × 446 候选位移全量 NCC =
/// ~4.3 亿乘加/帧,0.12s 采样管道被单帧计算吞满 → 36 秒只交付 2 帧）：
/// SnowShot 靠 rayon 并行 + NEON/SIMD 扛全量;本实现走「预算裁剪」路线：
/// - 纹理 tile 取 **top 48**（按方差排序,页眉/纯色全剔除）
/// - 候选位移粗步长 **8px**（降采样系,= 全分辨率 32px——粗定位足够,
///   精修由 Stitcher.findOverlap(hint:) 在 ±32 行窗口内做）
/// - tile NCC 内部 **8×8 均匀采样 64 点**（不逐像素）
/// ⇒ 单帧 ~48×110×64 ≈ 34 万乘加,毫秒级
enum TileMotionEstimator {

    struct Estimate {
        /// 帧间位移（降采样像素,Y-down：负 = 同内容在 cur 更靠上 = 页面下滚）
        let dy: Int
        /// 峰值得分 / 参与纹理权重（0-1）
        let confidence: Double
        /// 参与投票的纹理 tile 数
        let texturedTiles: Int
        /// 粗步长（供精修窗口换算）
        static let coarseStepDownsampled: Int = 8
        /// 降采样倍率（供精修窗口换算）
        static let downsample: Int = 4
    }

    struct Options {
        var downsample: Int = 4
        var tileSize: Int = 24
        var textureThreshold: Double = 0.0005
        var nccAccept: Double = 0.6
        var maxShiftRatio: Double = 0.85
        var coarseStep: Int = Estimate.coarseStepDownsampled
        var maxTiles: Int = 48
        var nccSampleGrid: Int = 8   // 8×8 = 64 采样点
    }

    // MARK: - 入口

    /// 估计 ref → cur 的垂直位移（粗）。
    /// 线程语义：纯函数,任意线程可调用。毫秒级（性能纪律见头注释）。
    static func estimateShift(ref: CGImage, cur: CGImage, options: Options = Options()) -> Estimate? {
        guard ref.width == cur.width, ref.height == cur.height, ref.height > 64 else { return nil }
        guard let grayRef = grayscale(image: ref, ds: options.downsample),
              let grayCur = grayscale(image: cur, ds: options.downsample) else { return nil }

        let tiles = topTextureTiles(gray: grayRef, tileSize: options.tileSize,
                                    textureThreshold: options.textureThreshold,
                                    maxTiles: options.maxTiles)
        guard tiles.count >= 6 else {
            return Estimate(dy: 0, confidence: 0, texturedTiles: tiles.count)
        }

        let maxShift = Int(Double(grayRef.height) * options.maxShiftRatio)
        var totalWeight = 0.0
        for t in tiles { totalWeight += t.weight }
        guard totalWeight > 0 else { return nil }

        var bestDy = 0
        var bestScore = 0.0
        let step = max(1, options.coarseStep)
        for dy in stride(from: -maxShift, through: maxShift, by: step) {
            var score = 0.0
            for tile in tiles {
                let y0 = tile.y + dy
                guard y0 >= 0, y0 + options.tileSize <= grayCur.height else { continue }
                let ncc = tileNCC(tile: tile, cur: grayCur, y0: y0, size: options.tileSize,
                                  sampleGrid: options.nccSampleGrid)
                if ncc >= options.nccAccept { score += tile.weight * ncc }
            }
            if score > bestScore {
                bestScore = score
                bestDy = dy
            }
        }
        return Estimate(dy: bestDy, confidence: bestScore / totalWeight,
                        texturedTiles: tiles.count)
    }

    // MARK: - 灰度化

    private struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private struct Tile {
        let x: Int
        let y: Int
        let data: [Double]      // 中心化亮度（NCC 预备）
        let energy: Double      // Σd²
        let variance: Double
        let weight: Double
    }

    private static func grayscale(image: CGImage, ds: Int) -> GrayImage? {
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
                         pixels: Array(UnsafeBufferPointer(
                            start: ptr.assumingMemoryBound(to: UInt8.self), count: w * h)))
    }

    /// 纹理最强的 top-K tile（方差排序——卡片/文字区胜出,页眉纯色剔除）
    private static func topTextureTiles(
        gray: GrayImage, tileSize: Int, textureThreshold: Double, maxTiles: Int
    ) -> [Tile] {
        let cols = gray.width / tileSize
        let rows = gray.height / tileSize
        var candidates: [Tile] = []
        candidates.reserveCapacity(cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                if let tile = extractTile(gray: gray, x: c * tileSize, y: r * tileSize,
                                          size: tileSize), tile.variance >= textureThreshold {
                    candidates.append(tile)
                }
            }
        }
        candidates.sort { $0.variance > $1.variance }
        return Array(candidates.prefix(maxTiles))
    }

    private static func extractTile(gray: GrayImage, x: Int, y: Int, size: Int) -> Tile? {
        var sum = 0.0
        var values = [Double]()
        values.reserveCapacity(size * size)
        for yy in y..<(y + size) {
            let row = yy * gray.width
            for xx in x..<(x + size) {
                let v = Double(gray.pixels[row + xx])
                values.append(v)
                sum += v
            }
        }
        let mean = sum / Double(values.count)
        var variance = 0.0
        var energy = 0.0
        for i in 0..<values.count {
            let d = values[i] - mean
            values[i] = d
            energy += d * d
            variance += d * d
        }
        variance /= Double(values.count)
        let weight = min(1.0, variance / 0.01)
        return Tile(x: x, y: y, data: values, energy: energy, variance: variance, weight: weight)
    }

    // MARK: - NCC（均匀采样）

    private static func tileNCC(
        tile: Tile, cur: GrayImage, y0: Int, size: Int, sampleGrid: Int
    ) -> Double {
        // 均匀采样 sampleGrid² 个点（性能纪律：64 点/候选,tile 全像素的 1/9）
        let step = max(1, size / sampleGrid)
        var sumCur = 0.0
        var count = 0
        for yy in stride(from: 0, to: size, by: step) {
            let row = (y0 + yy) * cur.width
            for xx in stride(from: 0, to: size, by: step) {
                sumCur += Double(cur.pixels[row + tile.x + xx])
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let meanCur = sumCur / Double(count)
        var dot = 0.0
        var energyCur = 0.0
        for yy in stride(from: 0, to: size, by: step) {
            let row = (y0 + yy) * cur.width
            for xx in stride(from: 0, to: size, by: step) {
                let dc = Double(cur.pixels[row + tile.x + xx]) - meanCur
                // 采样网格坐标的 tile 中心化值（网格一致,可直接索引）
                let tIdx = yy * size + xx
                dot += tile.data[tIdx] * dc
                energyCur += dc * dc
            }
        }
        let denom = (tile.energy * energyCur).squareRoot()
        guard denom > 1e-9 else { return 0 }
        // tile.energy 是全像素中心化能量,dot/energyCur 是采样点——能量口径
        // 不一致会有偏,但 NCC 只用于同帧候选间相对比较,单调性保留
        let ncc = dot / denom
        return ncc < 0 ? 0 : ncc
    }
}
