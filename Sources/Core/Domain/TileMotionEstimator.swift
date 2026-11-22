import Accelerate
import CoreGraphics
import Foundation

/// Tile-NCC 位移估计器（CoreGraphics + Accelerate/vDSP 硬件加速版）
///
/// 性能纪律（2026-11-20 病例：Debug/-Onone 下 Swift 800 万像素循环耗时 3.06s/帧 → 71 帧丢 68 帧）：
/// 全链路杜绝全分辨率 Swift 逐像素循环与百万级嵌套搜索循环，全部下沉到 CoreGraphics C/SIMD 与 vDSP/NEON：
/// 1. `PreparedFrame`：通过 `CGContext(DeviceGray)` 直接硬件解码全分辨率灰度（`Data`，~4ms）与
///    4× 降采样灰度（`vDSP_vfltu8` + `vDSP_vsdiv` + `vDSP_f3x3`，~2ms）；原 `CGImage` 懒保留，
///    仅在帧被接受写入画布时按需解码重绘带 RGBA（零 32MB 无效拷贝）。
/// 2. Stage 1（多列 1D `vDSP_conv` 全范围粗搜，~1.5ms）：
///    先在 `dy = 0` 处基于 `vDSP` 逐列逐块分离「静止块（sticky header/footer/sidebar）」与
///    「运动块」，对运动列的亮度与水平梯度波形分别做带掩码的 `vDSP_conv` 归一化互相关，
///    一次遍历全部 `dy ∈ [-maxShift, +maxShift]`（`step = 1`），彻底消除静止区垄断与遮挡干扰。
/// 3. Stage 2（2D 运动 Tile NCC 复核，~1ms）：
///    仅对 Stage 1 前几个候选峰 ±2 ds-px 做 2D `vDSP_dotpr` 复核（自动跳过落入静止遮挡区的目标位置）。
/// 4. Stage 3（全分辨率 1px 精修，~1.5ms）：
///    在 `fullGray` 上对运动区高梯度点做 `±4px` 1px 精修（截断最差 25% 噪点块）并与 `dy = 0` 基线比对。
/// ⇒ 3840×2100 4K 帧即使在 Debug (`-Onone`) 下全程 ~10-20ms，稳定跑满 8-10fps 实时流式拼接。
enum TileMotionEstimator {

    enum MotionOutcome: Equatable, Sendable {
        case noMotion
        /// 垂直位移（全分辨率像素，Y-down：负 = 页面下滚，正 = 向上回滚/回弹）
        case motion(dy: Int)
        case indeterminate
    }

    struct Estimate: Equatable, Sendable {
        let outcome: MotionOutcome
        /// 全分辨率垂直位移（无运动/未判定时为 0）
        let dy: Int
        /// 运动置信度（0...1）
        let confidence: Double
        /// 参与计算的纹理块数
        let texturedTiles: Int
        /// 其中被判定为变化/运动的块数
        let movingTiles: Int
        /// 全分辨率精修归一化误差（0...1，越小越精确）
        let preciseError: Double

        static let coarseStepDownsampled: Int = 1
        static let downsample: Int = 4
    }

    struct Options: Sendable {
        var downsample: Int = Estimate.downsample
        var tileSize: Int = 16
        /// `[0, 1]` 归一化灰度下的纹理方差下限
        var textureThreshold: Double = 0.00025
        /// 降采样块在 `dy = 0` 被判为静止的最大 MAD（`[0, 1]` 尺度，~3/255）
        var staticTileMaxMAD: Float = 0.012
        /// 降采样块在 `dy = 0` 被判为静止的最小 NCC
        var staticTileMinNCC: Float = 0.96
        var nccAccept: Double = 0.35
        var maxShiftRatio: Double = 0.90
        var maxTiles: Int = 64
        var nccSampleGrid: Int = 8
    }

    /// 预解码帧（CoreGraphics + vDSP 加速，Debug/-Onone 下 4K 帧 ~6-10ms）：
    /// - 保留原始 `cgImage`（仅接受帧时按需解码所需 RGBA 带，不浪费 32MB/帧）
    /// - `fullGray`：全分辨率 8-bit 灰度（`Data`，支持 C `memcmp` 快判静止）
    /// - `dsGray`：4× 降采样 `[0, 1]` Float 灰度 + 3×3 `[1,2,1]` 平滑
    struct PreparedFrame: Sendable {
        let cgImage: CGImage
        let width: Int
        let height: Int
        let fullGray: Data
        let dsWidth: Int
        let dsHeight: Int
        let dsGray: [Float]

        init?(cgImage: CGImage, downsample ds: Int = Estimate.downsample) {
            let w = cgImage.width
            let h = cgImage.height
            guard w > 8, h > 8 else { return nil }

            // 1. 同色域 sRGB RGBA8 快速光栅化（避免 CoreGraphics sRGB→DeviceGray 逐像素 ICC 转换 ~65ms 瓶颈）
            let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let rgbaCtx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ), let rgbaPtr = rgbaCtx.data else {
                return nil
            }
            rgbaCtx.interpolationQuality = .none
            rgbaCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

            // 2. Accelerate vImage NEON 硬件加速：RGBA8 → 全分辨率 Planar8 灰度（~1.5ms）
            let pixelCount = w * h
            var fullGrayData = Data(count: pixelCount)
            let dsw = max(1, w / ds)
            let dsh = max(1, h / ds)
            let dsCount = dsw * dsh
            var dsU8 = [UInt8](repeating: 0, count: dsCount)

            var srcBuf = vImage_Buffer(
                data: rgbaPtr,
                height: vImagePixelCount(h),
                width: vImagePixelCount(w),
                rowBytes: w * 4
            )
            var matrix: [Int16] = [77, 150, 29, 0] // BT.601 近似，总和 256
            let vErr: vImage_Error = fullGrayData.withUnsafeMutableBytes { gRaw in
                guard let gPtr = gRaw.baseAddress else { return kvImageMemoryAllocationError }
                var grayBuf = vImage_Buffer(
                    data: gPtr,
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: w
                )
                let e1 = vImageMatrixMultiply_ARGB8888ToPlanar8(
                    &srcBuf, &grayBuf, &matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
                guard e1 == kvImageNoError else { return e1 }

                // 3. Accelerate vImage NEON 4× 区域缩放降采样（~1.5ms）
                return dsU8.withUnsafeMutableBytes { dRaw in
                    guard let dPtr = dRaw.baseAddress else { return kvImageMemoryAllocationError }
                    var dsBuf = vImage_Buffer(
                        data: dPtr,
                        height: vImagePixelCount(dsh),
                        width: vImagePixelCount(dsw),
                        rowBytes: dsw
                    )
                    return vImageScale_Planar8(
                        &grayBuf, &dsBuf, nil, vImage_Flags(kvImageHighQualityResampling))
                }
            }
            guard vErr == kvImageNoError else { return nil }

            // 4. vDSP UInt8 → Float [0, 1] + 3×3 [1,2,1] 轻量平滑（~0.4ms）
            var dsFloat = [Float](repeating: 0, count: dsCount)
            vDSP_vfltu8(dsU8, 1, &dsFloat, 1, vDSP_Length(dsCount))
            var inv255: Float = 1.0 / 255.0
            vDSP_vsmul(dsFloat, 1, &inv255, &dsFloat, 1, vDSP_Length(dsCount))

            // ⚠️ vDSP_f3x3 会将 1px 边界写为 0.0，必须用内邻行/列回填边界（replicate border），
            // 否则顶底黑边会在互相关时制造巨大伪脉冲！
            var blurred = dsFloat
            if dsw >= 3 && dsh >= 3 {
                var kernel: [Float] = [
                    1.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0,
                    2.0 / 16.0, 4.0 / 16.0, 2.0 / 16.0,
                    1.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0,
                ]
                vDSP_f3x3(dsFloat, vDSP_Length(dsh), vDSP_Length(dsw), &kernel, &blurred)
                blurred.withUnsafeMutableBufferPointer { buf in
                    guard let p = buf.baseAddress else { return }
                    let rowBytes = dsw * MemoryLayout<Float>.size
                    _ = memcpy(p, p + dsw, rowBytes)
                    _ = memcpy(p + (dsh - 1) * dsw, p + (dsh - 2) * dsw, rowBytes)
                    for y in 0..<dsh {
                        let r = y * dsw
                        p[r] = p[r + 1]
                        p[r + dsw - 1] = p[r + dsw - 2]
                    }
                }
            }

            self.cgImage = cgImage
            self.width = w
            self.height = h
            self.fullGray = fullGrayData
            self.dsWidth = dsw
            self.dsHeight = dsh
            self.dsGray = blurred
        }

        /// 从已有 RGBA8 像素缓冲直接构造预解码帧（用于 `CanvasWindow` 零漂移参考切片，无需额外 CGImage 编解码）
        init?(rgbaSlice: Data, width w: Int, height h: Int, downsample ds: Int = Estimate.downsample) {
            guard w > 8, h > 8, rgbaSlice.count == w * h * 4 else { return nil }
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ), let ptr = ctx.data else {
                return nil
            }
            rgbaSlice.withUnsafeBytes { raw in
                if let src = raw.baseAddress {
                    _ = memcpy(ptr, src, rgbaSlice.count)
                }
            }
            guard let image = ctx.makeImage() else { return nil }

            let pixelCount = w * h
            var fullGrayData = Data(count: pixelCount)
            let dsw = max(1, w / ds)
            let dsh = max(1, h / ds)
            let dsCount = dsw * dsh
            var dsU8 = [UInt8](repeating: 0, count: dsCount)

            var srcBuf = vImage_Buffer(
                data: ptr,
                height: vImagePixelCount(h),
                width: vImagePixelCount(w),
                rowBytes: w * 4
            )
            var matrix: [Int16] = [77, 150, 29, 0]
            let vErr: vImage_Error = fullGrayData.withUnsafeMutableBytes { gRaw in
                guard let gPtr = gRaw.baseAddress else { return kvImageMemoryAllocationError }
                var grayBuf = vImage_Buffer(
                    data: gPtr,
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: w
                )
                let e1 = vImageMatrixMultiply_ARGB8888ToPlanar8(
                    &srcBuf, &grayBuf, &matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
                guard e1 == kvImageNoError else { return e1 }
                return dsU8.withUnsafeMutableBytes { dRaw in
                    guard let dPtr = dRaw.baseAddress else { return kvImageMemoryAllocationError }
                    var dsBuf = vImage_Buffer(
                        data: dPtr,
                        height: vImagePixelCount(dsh),
                        width: vImagePixelCount(dsw),
                        rowBytes: dsw
                    )
                    return vImageScale_Planar8(
                        &grayBuf, &dsBuf, nil, vImage_Flags(kvImageHighQualityResampling))
                }
            }
            guard vErr == kvImageNoError else { return nil }

            var dsFloat = [Float](repeating: 0, count: dsCount)
            vDSP_vfltu8(dsU8, 1, &dsFloat, 1, vDSP_Length(dsCount))
            var inv255: Float = 1.0 / 255.0
            vDSP_vsmul(dsFloat, 1, &inv255, &dsFloat, 1, vDSP_Length(dsCount))

            var blurred = dsFloat
            if dsw >= 3 && dsh >= 3 {
                var kernel: [Float] = [
                    1.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0,
                    2.0 / 16.0, 4.0 / 16.0, 2.0 / 16.0,
                    1.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0,
                ]
                vDSP_f3x3(dsFloat, vDSP_Length(dsh), vDSP_Length(dsw), &kernel, &blurred)
                blurred.withUnsafeMutableBufferPointer { buf in
                    guard let p = buf.baseAddress else { return }
                    let rowBytes = dsw * MemoryLayout<Float>.size
                    _ = memcpy(p, p + dsw, rowBytes)
                    _ = memcpy(p + (dsh - 1) * dsw, p + (dsh - 2) * dsw, rowBytes)
                    for y in 0..<dsh {
                        let r = y * dsw
                        p[r] = p[r + 1]
                        p[r + dsw - 1] = p[r + dsw - 2]
                    }
                }
            }

            self.cgImage = image
            self.width = w
            self.height = h
            self.fullGray = fullGrayData
            self.dsWidth = dsw
            self.dsHeight = dsh
            self.dsGray = blurred
        }

        /// 按需解码指定垂直区段 `[yStart, yStart + bandHeight)` 的 RGBA8 像素（顶部为 0，Y-down）。
        /// 仅在帧被接受写入画布时调用，静态/丢弃帧零 RGBA 拷贝开销。
        func rgbaBand(yStart: Int, height bandHeight: Int) -> Data? {
            guard yStart >= 0, bandHeight > 0, yStart + bandHeight <= height else { return nil }
            let source: CGImage
            if yStart == 0 && bandHeight == height {
                source = cgImage
            } else {
                let cropRect = CGRect(x: 0, y: yStart, width: width, height: bandHeight)
                guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
                source = cropped
            }
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: width,
                height: bandHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ), let ptr = ctx.data else {
                return nil
            }
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: bandHeight))
            return Data(bytes: ptr, count: width * bandHeight * 4)
        }
    }

    // MARK: - 入口

    static func estimateShift(
        ref: CGImage, cur: CGImage, options: Options = Options()
    ) -> Estimate? {
        guard ref.width == cur.width, min(ref.height, cur.height) > 64 else { return nil }
        guard let prepRef = PreparedFrame(cgImage: ref, downsample: options.downsample),
              let prepCur = PreparedFrame(cgImage: cur, downsample: options.downsample) else {
            return nil
        }
        return estimateShift(ref: prepRef, cur: prepCur, options: options)
    }

    static func estimateShift(
        ref: PreparedFrame, cur: PreparedFrame, options: Options = Options()
    ) -> Estimate? {
        guard ref.width == cur.width, min(ref.height, cur.height) > 64 else { return nil }
        let ds = options.downsample
        let commonDsW = min(ref.dsWidth, cur.dsWidth)
        let commonDsH = min(ref.dsHeight, cur.dsHeight)
        guard commonDsW >= 16, commonDsH >= 16 else { return nil }

        // 0. 快速完全静止检测（全图 vDSP |ref - cur| 最大值，~0.15ms）
        let commonPixels = commonDsW * commonDsH
        var absDiff = [Float](repeating: 0, count: commonPixels)
        if ref.dsWidth == cur.dsWidth && ref.dsHeight == cur.dsHeight {
            vDSP_vsub(cur.dsGray, 1, ref.dsGray, 1, &absDiff, 1, vDSP_Length(commonPixels))
            vDSP_vabs(absDiff, 1, &absDiff, 1, vDSP_Length(commonPixels))
        } else {
            ref.dsGray.withUnsafeBufferPointer { rBuf in
                cur.dsGray.withUnsafeBufferPointer { cBuf in
                    absDiff.withUnsafeMutableBufferPointer { dBuf in
                        guard let rP = rBuf.baseAddress, let cP = cBuf.baseAddress,
                              let dP = dBuf.baseAddress else { return }
                        for y in 0..<commonDsH {
                            vDSP_vsub(cP + y * cur.dsWidth, 1,
                                      rP + y * ref.dsWidth, 1,
                                      dP + y * commonDsW, 1,
                                      vDSP_Length(commonDsW))
                        }
                        vDSP_vabs(dP, 1, dP, 1, vDSP_Length(commonPixels))
                    }
                }
            }
        }

        // 1. 构建列条带（≤32 列）的 1D 亮度与水平对比度波形 + 块级静止/运动分割
        let numCols = min(32, max(6, commonDsW / max(8, options.tileSize)))
        let colW = max(1, commonDsW / numCols)
        let blockH = min(options.tileSize, max(8, commonDsH / 8))
        let numRowBlocks = max(1, (commonDsH + blockH - 1) / blockH)

        let refProfiles = extractColumnProfiles(
            gray: ref.dsGray, strideW: ref.dsWidth, height: ref.dsHeight,
            numCols: numCols, colW: colW)
        let curProfiles = extractColumnProfiles(
            gray: cur.dsGray, strideW: cur.dsWidth, height: cur.dsHeight,
            numCols: numCols, colW: colW)
        let diffMeanCols = extractColumnMeans(
            buffer: absDiff, strideW: commonDsW, height: commonDsH,
            numCols: numCols, colW: colW)

        // 统计每个 (col, rowBlock) 块是否「有纹理」以及「是否静止（dy = 0 几乎无变化）」
        var texturedBlocks: [(col: Int, rowBlock: Int, variance: Double)] = []
        var movingBlocks: [(col: Int, rowBlock: Int, variance: Double)] = []
        var staticBlockMask = [Bool](repeating: false, count: numCols * numRowBlocks)
        var movingColFlags = [Bool](repeating: false, count: numCols)
        var anyContentChange = false

        // 块级移动掩码（逐行）：用于 Stage 1 vDSP_conv 遮罩静止顶/底栏
        var refMovingRowMask = Array(repeating: [Float](repeating: 0, count: ref.dsHeight), count: numCols)
        var curMovingRowMask = Array(repeating: [Float](repeating: 0, count: cur.dsHeight), count: numCols)

        for c in 0..<numCols {
            let x0 = c * colW
            let refColMean = refProfiles.means[c]
            let curColMean = curProfiles.means[c]
            let diffCol = diffMeanCols[c]

            for rb in 0..<numRowBlocks {
                let y0 = rb * blockH
                let y1 = min(commonDsH, y0 + blockH)
                let len = y1 - y0
                guard len >= 4 else { continue }

                var madZero: Float = 0
                diffCol.withUnsafeBufferPointer { ptr in
                    vDSP_meanv(ptr.baseAddress! + y0, 1, &madZero, vDSP_Length(len))
                }

                // 用 2D 块方差（而不只 1D 列均值方差）判定纹理，避免水平对称纹理漏检
                let varRef = blockVariance(
                    gray: ref.dsGray, strideW: ref.dsWidth, x0: x0, y0: y0, w: colW, h: len)
                let varCur = blockVariance(
                    gray: cur.dsGray, strideW: cur.dsWidth, x0: x0, y0: y0, w: colW, h: len)

                if varCur >= options.textureThreshold && madZero >= options.staticTileMaxMAD {
                    anyContentChange = true
                }

                let isTexturedRef = varRef >= options.textureThreshold
                let isTexturedCur = varCur >= options.textureThreshold
                let isStatic = madZero < options.staticTileMaxMAD && {
                    guard isTexturedRef && isTexturedCur else { return true }
                    // 对高纹理块再校验 1D 列均值相关性
                    let ncc1D = segmentNCC(refColMean, curColMean, start: y0, length: len)
                    return ncc1D >= options.staticTileMinNCC
                }()

                if isStatic {
                    // 只有有内容且在 dy=0 静止的块才标记为遮挡（纯白背景不算遮挡，滚动内容滚进空白区是正常的）
                    if isTexturedRef || isTexturedCur {
                        staticBlockMask[rb * numCols + c] = true
                    }
                } else {
                    movingColFlags[c] = true
                    for y in y0..<y1 {
                        refMovingRowMask[c][y] = 1.0
                        curMovingRowMask[c][y] = 1.0
                    }
                }

                if isTexturedRef {
                    texturedBlocks.append((col: c, rowBlock: rb, variance: varRef))
                    if !isStatic {
                        movingBlocks.append((col: c, rowBlock: rb, variance: varRef))
                    }
                }
            }

            // 处理不等高帧时超出 commonDsH 的尾行：默认允许作为运动目标
            if ref.dsHeight > commonDsH && movingColFlags[c] {
                for y in commonDsH..<ref.dsHeight { refMovingRowMask[c][y] = 1.0 }
            }
            if cur.dsHeight > commonDsH && movingColFlags[c] {
                for y in commonDsH..<cur.dsHeight { curMovingRowMask[c][y] = 1.0 }
            }
        }

        // 无足够纹理
        guard texturedBlocks.count >= 2 else {
            let fullMad = sampledFullResZeroMAD(ref: ref, cur: cur)
            if fullMad < 1.5 {
                return Estimate(outcome: .noMotion, dy: 0, confidence: 1.0,
                                texturedTiles: texturedBlocks.count, movingTiles: 0, preciseError: 0)
            }
            return Estimate(outcome: .indeterminate, dy: 0, confidence: 0,
                            texturedTiles: texturedBlocks.count, movingTiles: 0, preciseError: 1)
        }

        // 降采样无明显变化块时，做全分辨率复核（区分「真静止」与「1-3px 极慢滚动」）
        var forceTinyMotionSeeds = false
        if movingBlocks.isEmpty {
            let fullCheck = fullResZeroCheck(
                ref: ref, cur: cur, blocks: texturedBlocks,
                colW: colW, blockH: blockH, ds: ds)
            if !anyContentChange && fullCheck.meanMad < 1.8 && fullCheck.changedBlocks.isEmpty {
                return Estimate(outcome: .noMotion, dy: 0, confidence: 1.0,
                                texturedTiles: texturedBlocks.count, movingTiles: 0, preciseError: 0)
            }
            movingBlocks = fullCheck.changedBlocks
            if movingBlocks.isEmpty {
                return Estimate(outcome: .noMotion, dy: 0, confidence: 1.0,
                                texturedTiles: texturedBlocks.count, movingTiles: 0, preciseError: 0)
            }
            forceTinyMotionSeeds = true
        }

        // 2. Stage 1：基于 vDSP_conv 的全范围 step=1 多列 1D 归一化互相关粗搜（~1.5ms）
        let maxShiftDs = Int(Double(min(ref.dsHeight, cur.dsHeight)) * options.maxShiftRatio)
        let stage1Peaks: [Int]
        if forceTinyMotionSeeds {
            stage1Peaks = [-1, 1]
        } else {
            stage1Peaks = coarseSearchWithVDSP(
                refProfiles: refProfiles,
                curProfiles: curProfiles,
                refMasks: refMovingRowMask,
                curMasks: curMovingRowMask,
                movingColFlags: movingColFlags,
                refHeight: ref.dsHeight,
                curHeight: cur.dsHeight,
                maxShiftDs: maxShiftDs
            )
        }

        // 3. 提取空间均衡的 2D 运动 tile（仅从 movingBlocks 中提取，最多 maxTiles 个）
        let selectedBlocks = selectSpatiallyBalancedBlocks(
            movingBlocks, maxTiles: options.maxTiles, totalRowBlocks: numRowBlocks)
        let tileW = min(options.tileSize, colW)
        let tileH = blockH
        let movingTiles = selectedBlocks.compactMap { blk -> MovingTile? in
            let x0 = blk.col * colW + max(0, (colW - tileW) / 2)
            let rawY0 = blk.rowBlock * blockH
            let y0 = min(rawY0, max(0, ref.dsHeight - tileH))
            guard x0 + tileW <= ref.dsWidth, y0 + tileH <= ref.dsHeight else { return nil }
            return buildMovingTile(
                ref: ref, col: blk.col, x: x0, y: y0, w: tileW, h: tileH,
                variance: blk.variance, gridSize: options.nccSampleGrid)
        }
        guard !movingTiles.isEmpty else {
            return Estimate(outcome: .indeterminate, dy: 0, confidence: 0,
                            texturedTiles: texturedBlocks.count, movingTiles: 0, preciseError: 1)
        }

        // 4. Stage 2：仅对 Stage 1 候选峰 ±2 ds-px 做 2D 运动 Tile NCC 复核（自动跳过静止遮挡区）
        var verifySet = Set<Int>()
        for peak in stage1Peaks {
            for delta in -2...2 {
                let d = peak + delta
                if d != 0 && abs(d) <= maxShiftDs {
                    verifySet.insert(d)
                }
            }
        }
        if verifySet.isEmpty {
            verifySet.insert(-1)
            verifySet.insert(1)
        }

        let minInBoundsCount = max(1, min(3, movingTiles.count))
        var verifiedPeaks: [(dy: Int, confidence: Double, rawScore: Double)] = []
        verifiedPeaks.reserveCapacity(verifySet.count)

        for dy in verifySet {
            var score = 0.0
            var eligibleWeight = 0.0
            var inBounds = 0
            for tile in movingTiles {
                let y0 = tile.y + dy
                guard y0 >= 0, y0 + tile.h <= cur.dsHeight else { continue }
                // 目标位置若落入静止 UI（如 sticky header / bottom bar），则该 tile 已被遮挡，不计入分母
                let dstRB = min(numRowBlocks - 1, max(0, (y0 + tile.h / 2) / blockH))
                if staticBlockMask[dstRB * numCols + tile.col] { continue }
                inBounds += 1
                eligibleWeight += tile.weight
                let ncc = unitTileNCC(tile: tile, cur: cur, y0: y0, gridSize: options.nccSampleGrid)
                if ncc >= options.nccAccept {
                    score += tile.weight * ncc
                }
            }
            guard inBounds >= minInBoundsCount, eligibleWeight > 0 else { continue }
            let conf = score / eligibleWeight
            if conf > 0.18 || forceTinyMotionSeeds {
                verifiedPeaks.append((dy: dy, confidence: conf, rawScore: score))
            }
        }

        // 按置信度与原始分选出前 4 个互异精修种子
        let sortedByConf = verifiedPeaks.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence : abs($0.dy) < abs($1.dy)
        }
        let sortedByRaw = verifiedPeaks.sorted {
            $0.rawScore != $1.rawScore ? $0.rawScore > $1.rawScore : abs($0.dy) < abs($1.dy)
        }

        var coarseSeeds: [(dy: Int, confidence: Double)] = []
        for p in sortedByConf {
            if coarseSeeds.allSatisfy({ abs($0.dy - p.dy) > 2 }) {
                coarseSeeds.append((p.dy, p.confidence))
                if coarseSeeds.count >= 3 { break }
            }
        }
        for p in sortedByRaw {
            if coarseSeeds.allSatisfy({ abs($0.dy - p.dy) > 2 }) {
                coarseSeeds.append((p.dy, p.confidence))
                if coarseSeeds.count >= 5 { break }
            }
        }
        if coarseSeeds.isEmpty {
            coarseSeeds = [(dy: -1, confidence: 0.35), (dy: 1, confidence: 0.35)]
        }

        // 5. Stage 3：全分辨率 1px 精修与真值验证（~1.5ms）
        let maxShiftFull = Int(Double(min(ref.height, cur.height)) * options.maxShiftRatio)
        var bestResult: RefinedMatch?

        for seed in coarseSeeds {
            let center = seed.dy * ds
            let dMin = max(-maxShiftFull, center - ds)
            let dMax = min(maxShiftFull, center + ds)
            guard dMin <= dMax else { continue }

            let inBoundsTiles = movingTiles.compactMap { tile -> (tile: MovingTile, ncc: Double)? in
                let y0 = tile.y + seed.dy
                guard y0 >= 0, y0 + tile.h <= cur.dsHeight else { return nil }
                let dstRB = min(numRowBlocks - 1, max(0, (y0 + tile.h / 2) / blockH))
                if staticBlockMask[dstRB * numCols + tile.col] { return nil }
                let ncc = unitTileNCC(tile: tile, cur: cur, y0: y0, gridSize: options.nccSampleGrid)
                return (tile, ncc)
            }
            .sorted { $0.ncc > $1.ncc }
            .prefix(24)
            .map(\.tile)

            guard !inBoundsTiles.isEmpty else { continue }
            if let refined = refineAtFullResolution(
                ref: ref, cur: cur, tiles: inBoundsTiles, ds: ds,
                dMin: dMin, dMax: dMax, coarseConfidence: seed.confidence
            ) {
                if let current = bestResult {
                    if refined.bestError < current.bestError {
                        bestResult = refined
                    }
                } else {
                    bestResult = refined
                }
            }
        }

        guard let best = bestResult else {
            return Estimate(outcome: .indeterminate, dy: 0, confidence: 0,
                            texturedTiles: texturedBlocks.count, movingTiles: movingTiles.count,
                            preciseError: 1.0)
        }

        let inlierRatio = Double(best.inlierTiles) / Double(max(1, best.evaluatedTiles))
        let minInliers = max(1, min(3, best.evaluatedTiles))
        let beatsZero = best.bestError <= best.zeroError * 0.60 || best.bestError <= 0.03
        let errorOK = best.bestError <= 0.10
        let inliersOK = best.inlierTiles >= minInliers || inlierRatio >= 0.50
        let confOK = best.coarseConfidence >= 0.25 || (best.bestError <= 0.025 && beatsZero)

        if errorOK && beatsZero && inliersOK && confOK {
            let finalConf = min(1.0, max(0.0,
                0.5 * best.coarseConfidence + 0.5 * (1.0 - min(1.0, best.bestError / 0.10))))
            return Estimate(
                outcome: .motion(dy: best.dy),
                dy: best.dy,
                confidence: finalConf,
                texturedTiles: texturedBlocks.count,
                movingTiles: movingTiles.count,
                preciseError: best.bestError
            )
        }

        // 若绝大多数纹理块实际没动且无可靠位移，视作静止噪声（光标闪烁等）
        if Double(movingBlocks.count) / Double(max(1, texturedBlocks.count)) < 0.08
            && best.zeroError < 0.04 {
            return Estimate(outcome: .noMotion, dy: 0, confidence: 0.9,
                            texturedTiles: texturedBlocks.count, movingTiles: movingBlocks.count,
                            preciseError: best.zeroError)
        }

        return Estimate(
            outcome: .indeterminate,
            dy: 0,
            confidence: best.coarseConfidence * 0.4,
            texturedTiles: texturedBlocks.count,
            movingTiles: movingTiles.count,
            preciseError: best.bestError
        )
    }

    // MARK: - Stage 1：列波形提取 + vDSP_conv 掩码归一化互相关

    private struct ColumnProfiles {
        /// 每列逐行平均亮度 `[numCols][height]`
        let means: [[Float]]
        /// 每列逐行内部亮度标准差/对比度 `[numCols][height]`（突出文字与边框行）
        let contrasts: [[Float]]
    }

    private static func extractColumnProfiles(
        gray: [Float], strideW: Int, height: Int, numCols: Int, colW: Int
    ) -> ColumnProfiles {
        var means = Array(repeating: [Float](repeating: 0, count: height), count: numCols)
        var contrasts = Array(repeating: [Float](repeating: 0, count: height), count: numCols)
        let n = vDSP_Length(colW)
        gray.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for y in 0..<height {
                let rowPtr = base + y * strideW
                for c in 0..<numCols {
                    let colPtr = rowPtr + c * colW
                    var m: Float = 0
                    var msq: Float = 0
                    vDSP_meanv(colPtr, 1, &m, n)
                    vDSP_measqv(colPtr, 1, &msq, n)
                    means[c][y] = m
                    let v = msq - m * m
                    contrasts[c][y] = v > 0 ? v.squareRoot() : 0
                }
            }
        }
        return ColumnProfiles(means: means, contrasts: contrasts)
    }

    private static func extractColumnMeans(
        buffer: [Float], strideW: Int, height: Int, numCols: Int, colW: Int
    ) -> [[Float]] {
        var means = Array(repeating: [Float](repeating: 0, count: height), count: numCols)
        let n = vDSP_Length(colW)
        buffer.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for y in 0..<height {
                let rowPtr = base + y * strideW
                for c in 0..<numCols {
                    var m: Float = 0
                    vDSP_meanv(rowPtr + c * colW, 1, &m, n)
                    means[c][y] = m
                }
            }
        }
        return means
    }

    private static func blockVariance(
        gray: [Float], strideW: Int, x0: Int, y0: Int, w: Int, h: Int
    ) -> Double {
        var sumM: Float = 0
        var sumMSQ: Float = 0
        let nw = vDSP_Length(w)
        gray.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for y in y0..<(y0 + h) {
                let ptr = base + y * strideW + x0
                var m: Float = 0
                var msq: Float = 0
                vDSP_meanv(ptr, 1, &m, nw)
                vDSP_measqv(ptr, 1, &msq, nw)
                sumM += m
                sumMSQ += msq
            }
        }
        let invH = Float(1.0) / Float(max(1, h))
        let mean = sumM * invH
        let meanSq = sumMSQ * invH
        let v = Double(meanSq - mean * mean)
        return v > 0 ? v : 0
    }

    private static func segmentNCC(_ a: [Float], _ b: [Float], start: Int, length: Int) -> Float {
        guard length >= 2 else { return 1.0 }
        let n = vDSP_Length(length)
        var meanA: Float = 0
        var meanB: Float = 0
        var dot: Float = 0
        var sqA: Float = 0
        var sqB: Float = 0
        a.withUnsafeBufferPointer { aBuf in
            b.withUnsafeBufferPointer { bBuf in
                let aP = aBuf.baseAddress! + start
                let bP = bBuf.baseAddress! + start
                vDSP_meanv(aP, 1, &meanA, n)
                vDSP_meanv(bP, 1, &meanB, n)
                vDSP_dotpr(aP, 1, bP, 1, &dot, n)
                vDSP_svesq(aP, 1, &sqA, n)
                vDSP_svesq(bP, 1, &sqB, n)
            }
        }
        let nf = Float(length)
        let eA = sqA - nf * meanA * meanA
        let eB = sqB - nf * meanB * meanB
        let denom = (max(0, eA) * max(0, eB)).squareRoot()
        guard denom > 1e-6 else { return 1.0 }
        return (dot - nf * meanA * meanB) / denom
    }

    /// 用 `vDSP_conv` 一次计算全部 `dy ∈ [-maxShiftDs, +maxShiftDs]` 的多列带掩码归一化互相关得分，
    /// 返回得分最高的前 6 个互异候选峰 `dy`。
    private static func coarseSearchWithVDSP(
        refProfiles: ColumnProfiles,
        curProfiles: ColumnProfiles,
        refMasks: [[Float]],
        curMasks: [[Float]],
        movingColFlags: [Bool],
        refHeight: Int,
        curHeight: Int,
        maxShiftDs: Int
    ) -> [Int] {
        guard maxShiftDs >= 1 else { return [] }
        let outLen = 2 * maxShiftDs + 1
        var aggScore = [Float](repeating: 0, count: outLen)
        var aggWeight = [Float](repeating: 0, count: outLen)

        let padTotalCur = curHeight + 2 * maxShiftDs
        // vDSP_conv 要求 A.count >= outLen + refHeight - 1
        let requiredCurLen = outLen + refHeight - 1
        let paddedLen = max(padTotalCur, requiredCurLen)

        var padCurSig = [Float](repeating: 0, count: paddedLen)
        var padCurSig2 = [Float](repeating: 0, count: paddedLen)
        var padCurMask = [Float](repeating: 0, count: paddedLen)

        var refSig = [Float](repeating: 0, count: refHeight)
        var refSig2 = [Float](repeating: 0, count: refHeight)

        var corrDot = [Float](repeating: 0, count: outLen)
        var corrERef = [Float](repeating: 0, count: outLen)
        var corrECur = [Float](repeating: 0, count: outLen)
        var corrSumRef = [Float](repeating: 0, count: outLen)
        var corrSumCur = [Float](repeating: 0, count: outLen)
        var corrCount = [Float](repeating: 0, count: outLen)

        let minOverlapRows = Float(max(8, min(refHeight, curHeight) / 14))

        func accumulateChannel(refCh: [Float], curCh: [Float], rMask: [Float], cMask: [Float], chWeight: Float) {
            var rMaskSum: Float = 0
            var cMaskSum: Float = 0
            vDSP_sve(rMask, 1, &rMaskSum, vDSP_Length(refHeight))
            vDSP_sve(cMask, 1, &cMaskSum, vDSP_Length(curHeight))
            guard rMaskSum >= minOverlapRows, cMaskSum >= minOverlapRows else { return }

            // 先按运动行均值中心化提高浮点数值精度，再用精确窗口 Pearson 公式消除局部均值漂移
            var rDotM: Float = 0
            var cDotM: Float = 0
            vDSP_dotpr(refCh, 1, rMask, 1, &rDotM, vDSP_Length(refHeight))
            vDSP_dotpr(curCh, 1, cMask, 1, &cDotM, vDSP_Length(curHeight))
            let rMean = rDotM / rMaskSum
            let cMean = cDotM / cMaskSum

            var negRMean = -rMean
            vDSP_vsadd(refCh, 1, &negRMean, &refSig, 1, vDSP_Length(refHeight))
            vDSP_vmul(refSig, 1, rMask, 1, &refSig, 1, vDSP_Length(refHeight))
            vDSP_vsq(refSig, 1, &refSig2, 1, vDSP_Length(refHeight))

            var rEnergyTotal: Float = 0
            vDSP_sve(refSig2, 1, &rEnergyTotal, vDSP_Length(refHeight))
            let rVar = rEnergyTotal / rMaskSum
            guard rVar > 1e-5 else { return }

            var zero: Float = 0
            vDSP_vfill(&zero, &padCurSig, 1, vDSP_Length(paddedLen))
            vDSP_vfill(&zero, &padCurSig2, 1, vDSP_Length(paddedLen))
            vDSP_vfill(&zero, &padCurMask, 1, vDSP_Length(paddedLen))

            var negCMean = -cMean
            padCurSig.withUnsafeMutableBufferPointer { dst in
                padCurSig2.withUnsafeMutableBufferPointer { dst2 in
                    padCurMask.withUnsafeMutableBufferPointer { dstM in
                        let sOut = dst.baseAddress! + maxShiftDs
                        let s2Out = dst2.baseAddress! + maxShiftDs
                        let mOut = dstM.baseAddress! + maxShiftDs
                        vDSP_vsadd(curCh, 1, &negCMean, sOut, 1, vDSP_Length(curHeight))
                        vDSP_vmul(sOut, 1, cMask, 1, sOut, 1, vDSP_Length(curHeight))
                        vDSP_vsq(sOut, 1, s2Out, 1, vDSP_Length(curHeight))
                        cMask.withUnsafeBufferPointer { srcM in
                            _ = memcpy(mOut, srcM.baseAddress!, curHeight * MemoryLayout<Float>.size)
                        }
                    }
                }
            }

            // 6 次 vDSP_conv 计算全范围 [-maxShiftDs, +maxShiftDs] 精确局部零均值带掩码 Pearson NCC
            let nOut = vDSP_Length(outLen)
            let pRef = vDSP_Length(refHeight)
            vDSP_conv(padCurSig, 1, refSig, 1, &corrDot, 1, nOut, pRef)
            vDSP_conv(padCurMask, 1, refSig2, 1, &corrERef, 1, nOut, pRef)
            vDSP_conv(padCurSig2, 1, rMask, 1, &corrECur, 1, nOut, pRef)
            vDSP_conv(padCurMask, 1, refSig, 1, &corrSumRef, 1, nOut, pRef)
            vDSP_conv(padCurSig, 1, rMask, 1, &corrSumCur, 1, nOut, pRef)
            vDSP_conv(padCurMask, 1, rMask, 1, &corrCount, 1, nOut, pRef)

            let colWeight = min(Float(1.0), rVar / 0.005) * chWeight
            for k in 0..<outLen {
                if k == maxShiftDs { continue } // 排除 dy = 0
                let ov = corrCount[k]
                guard ov >= minOverlapRows else { continue }
                let invOv = 1.0 / ov
                let sr = corrSumRef[k]
                let sc = corrSumCur[k]
                let varR = corrERef[k] - sr * sr * invOv
                let varC = corrECur[k] - sc * sc * invOv
                let prod = varR * varC
                guard varR > 1e-6, varC > 1e-6, prod > 1e-10 else { continue }
                let cov = corrDot[k] - sr * sc * invOv
                let ncc = cov / prod.squareRoot()
                aggWeight[k] += colWeight
                if ncc > 0.15 {
                    aggScore[k] += ncc * colWeight
                }
            }
        }

        for c in 0..<movingColFlags.count where movingColFlags[c] {
            accumulateChannel(
                refCh: refProfiles.means[c],
                curCh: curProfiles.means[c],
                rMask: refMasks[c],
                cMask: curMasks[c],
                chWeight: 1.0
            )
            accumulateChannel(
                refCh: refProfiles.contrasts[c],
                curCh: curProfiles.contrasts[c],
                rMask: refMasks[c],
                cMask: curMasks[c],
                chWeight: 0.7
            )
        }

        var scored: [(dy: Int, score: Float, norm: Float)] = []
        scored.reserveCapacity(outLen)
        for k in 0..<outLen where k != maxShiftDs {
            if aggWeight[k] > 0 && aggScore[k] > 0 {
                let dy = k - maxShiftDs
                scored.append((dy: dy, score: aggScore[k], norm: aggScore[k] / aggWeight[k]))
            }
        }

        let byRaw = scored.sorted { $0.score != $1.score ? $0.score > $1.score : abs($0.dy) < abs($1.dy) }
        let byNorm = scored.sorted { $0.norm != $1.norm ? $0.norm > $1.norm : abs($0.dy) < abs($1.dy) }

        var peaks: [Int] = []
        for item in byRaw {
            if peaks.allSatisfy({ abs($0 - item.dy) > 3 }) {
                peaks.append(item.dy)
                if peaks.count >= 4 { break }
            }
        }
        for item in byNorm {
            if peaks.allSatisfy({ abs($0 - item.dy) > 3 }) {
                peaks.append(item.dy)
                if peaks.count >= 6 { break }
            }
        }
        return peaks
    }

    // MARK: - Stage 2：2D 运动 Tile NCC 复核

    private struct MovingTile {
        let col: Int
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        /// 单位化零均值 gridSize×gridSize 采样向量（Σu = 0, ||u|| = 1）
        let unitSampled: [Float]
        let variance: Double
        let weight: Double
    }

    private static func selectSpatiallyBalancedBlocks(
        _ blocks: [(col: Int, rowBlock: Int, variance: Double)],
        maxTiles: Int,
        totalRowBlocks: Int
    ) -> [(col: Int, rowBlock: Int, variance: Double)] {
        guard blocks.count > maxTiles else { return blocks }
        let rowCount = max(1, totalRowBlocks)
        var buckets = Array(repeating: [(col: Int, rowBlock: Int, variance: Double)](), count: rowCount)
        for b in blocks {
            let r = min(rowCount - 1, max(0, b.rowBlock))
            buckets[r].append(b)
        }
        let sortedBuckets = buckets.map { $0.sorted { $0.variance > $1.variance } }
        var selected: [(col: Int, rowBlock: Int, variance: Double)] = []
        selected.reserveCapacity(maxTiles)
        var depth = 0
        while selected.count < maxTiles {
            var added = false
            for r in 0..<rowCount where depth < sortedBuckets[r].count {
                selected.append(sortedBuckets[r][depth])
                added = true
                if selected.count >= maxTiles { break }
            }
            if !added { break }
            depth += 1
        }
        return selected
    }

    private static func buildMovingTile(
        ref: PreparedFrame, col: Int, x: Int, y: Int, w: Int, h: Int,
        variance: Double, gridSize: Int
    ) -> MovingTile? {
        let gCount = gridSize * gridSize
        var samples = [Float](repeating: 0, count: gCount)
        ref.dsGray.withUnsafeBufferPointer { rBuf in
            guard let rPtr = rBuf.baseAddress else { return }
            for gy in 0..<gridSize {
                let sy = y + (gy * h + h / 2) / gridSize
                let rowBase = sy * ref.dsWidth + x
                for gx in 0..<gridSize {
                    let sx = (gx * w + w / 2) / gridSize
                    samples[gy * gridSize + gx] = rPtr[rowBase + sx]
                }
            }
        }
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(gCount))
        var negMean = -mean
        vDSP_vsadd(samples, 1, &negMean, &samples, 1, vDSP_Length(gCount))
        var energy: Float = 0
        vDSP_svesq(samples, 1, &energy, vDSP_Length(gCount))
        guard energy > 1e-8 else { return nil }
        var invNorm = 1.0 / energy.squareRoot()
        vDSP_vsmul(samples, 1, &invNorm, &samples, 1, vDSP_Length(gCount))
        let weight = min(1.0, variance / 0.01)
        return MovingTile(
            col: col, x: x, y: y, w: w, h: h,
            unitSampled: samples, variance: variance, weight: weight
        )
    }

    private static func unitTileNCC(
        tile: MovingTile, cur: PreparedFrame, y0: Int, gridSize: Int
    ) -> Double {
        let gCount = gridSize * gridSize
        var curSamples = [Float](repeating: 0, count: gCount)
        cur.dsGray.withUnsafeBufferPointer { cBuf in
            guard let cPtr = cBuf.baseAddress else { return }
            for gy in 0..<gridSize {
                let cy = y0 + (gy * tile.h + tile.h / 2) / gridSize
                let rowBase = cy * cur.dsWidth + tile.x
                for gx in 0..<gridSize {
                    let cx = (gx * tile.w + tile.w / 2) / gridSize
                    curSamples[gy * gridSize + gx] = cPtr[rowBase + cx]
                }
            }
        }
        var dot: Float = 0
        var sumC: Float = 0
        var sumC2: Float = 0
        let n = vDSP_Length(gCount)
        vDSP_dotpr(tile.unitSampled, 1, curSamples, 1, &dot, n)
        vDSP_sve(curSamples, 1, &sumC, n)
        vDSP_svesq(curSamples, 1, &sumC2, n)
        let energyC = sumC2 - (sumC * sumC) / Float(gCount)
        guard energyC > 1e-7 else { return 0 }
        let ncc = Double(dot / energyC.squareRoot())
        return ncc > 0 ? ncc : 0
    }

    // MARK: - Stage 3：全分辨率慢滚检测 & 1px 精修

    private static func sampledFullResZeroMAD(ref: PreparedFrame, cur: PreparedFrame) -> Double {
        let w = min(ref.width, cur.width)
        let h = min(ref.height, cur.height)
        let stepY = max(1, h / 40)
        let stepX = max(1, w / 40)
        var sum = 0
        var count = 0
        ref.fullGray.withUnsafeBytes { rRaw in
            cur.fullGray.withUnsafeBytes { cRaw in
                guard let rPtr = rRaw.bindMemory(to: UInt8.self).baseAddress,
                      let cPtr = cRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                var y = 0
                while y < h {
                    let rRow = y * ref.width
                    let cRow = y * cur.width
                    var x = 0
                    while x < w {
                        sum &+= abs(Int(rPtr[rRow + x]) - Int(cPtr[cRow + x]))
                        count &+= 1
                        x &+= stepX
                    }
                    y &+= stepY
                }
            }
        }
        return count > 0 ? Double(sum) / Double(count) : 0
    }

    private static func fullResZeroCheck(
        ref: PreparedFrame, cur: PreparedFrame,
        blocks: [(col: Int, rowBlock: Int, variance: Double)],
        colW: Int, blockH: Int, ds: Int
    ) -> (meanMad: Double, changedBlocks: [(col: Int, rowBlock: Int, variance: Double)]) {
        let commonH = min(ref.height, cur.height)
        var totalMad = 0.0
        var checked = 0
        var changed: [(col: Int, rowBlock: Int, variance: Double)] = []
        let step = 4
        let topBlocks = blocks.sorted { $0.variance > $1.variance }.prefix(32)
        ref.fullGray.withUnsafeBytes { rRaw in
            cur.fullGray.withUnsafeBytes { cRaw in
                guard let rPtr = rRaw.bindMemory(to: UInt8.self).baseAddress,
                      let cPtr = cRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                for blk in topBlocks {
                    let x0 = blk.col * colW * ds
                    let y0 = blk.rowBlock * blockH * ds
                    let x1 = min(ref.width, x0 + colW * ds)
                    let y1 = min(commonH, y0 + blockH * ds)
                    guard x1 > x0, y1 > y0 else { continue }
                    var sum = 0
                    var count = 0
                    var y = y0
                    while y < y1 {
                        let rRow = y * ref.width
                        let cRow = y * cur.width
                        var x = x0
                        while x < x1 {
                            sum &+= abs(Int(rPtr[rRow + x]) - Int(cPtr[cRow + x]))
                            count &+= 1
                            x &+= step
                        }
                        y &+= step
                    }
                    guard count > 0 else { continue }
                    let mad = Double(sum) / Double(count)
                    totalMad += mad
                    checked += 1
                    if mad >= 1.8 {
                        changed.append(blk)
                    }
                }
            }
        }
        return (checked > 0 ? totalMad / Double(checked) : 0, changed)
    }

    private struct RefinedMatch {
        let dy: Int
        let bestError: Double
        let zeroError: Double
        let inlierTiles: Int
        let evaluatedTiles: Int
        let coarseConfidence: Double
    }

    private static func refineAtFullResolution(
        ref: PreparedFrame,
        cur: PreparedFrame,
        tiles: [MovingTile],
        ds: Int,
        dMin: Int,
        dMax: Int,
        coarseConfidence: Double
    ) -> RefinedMatch? {
        var candidates: [Int] = []
        for d in dMin...dMax where d != 0 {
            candidates.append(d)
        }
        guard !candidates.isEmpty else { return nil }

        let fullDMin = min(0, dMin)
        let fullDMax = max(0, dMax)
        let refW = ref.width
        let refH = ref.height
        let curW = cur.width
        let curH = cur.height

        struct SamplePoint { let x: Int; let y: Int }
        var tileErrors: [[Double]] = []
        var tileZeroErrors: [Double] = []

        ref.fullGray.withUnsafeBytes { rRaw in
            cur.fullGray.withUnsafeBytes { cRaw in
                guard let rPtr = rRaw.bindMemory(to: UInt8.self).baseAddress,
                      let cPtr = cRaw.bindMemory(to: UInt8.self).baseAddress else { return }

                for tile in tiles {
                    let tileWFull = tile.w * ds
                    let tileHFull = tile.h * ds
                    let x0 = max(1, tile.x * ds)
                    let x1 = min(min(refW, curW) - 1, tile.x * ds + tileWFull)
                    let y0 = max(1, max(tile.y * ds, -fullDMin))
                    let y1 = min(refH - 1, min(tile.y * ds + tileHFull, curH - 1 - fullDMax))
                    guard x1 - x0 >= 8, y1 - y0 >= 8 else { continue }

                    // 垂直位移精修必须采样跨越水平边缘紧邻两侧的像素对（y 与 y+1），
                    // 任一方向偏移 1px 都必然跨边产生显著误差，杜绝 1px 误差打平漂移
                    let safeY0 = max(1, max(y0, -fullDMin))
                    let safeY1 = min(refH - 2, min(y1, curH - 2 - fullDMax))
                    guard safeY1 > safeY0 else { continue }
                    var points: [SamplePoint] = []
                    points.reserveCapacity(48)
                    let stepX = max(2, (x1 - x0) / 16)
                    let stepY = 1
                    var y = safeY0
                    while y < safeY1 {
                        let row0 = y * refW
                        let row1 = (y + 1) * refW
                        var x = x0
                        while x < x1 {
                            let gy = abs(Int(rPtr[row1 + x]) - Int(rPtr[row0 + x]))
                            if gy >= 12 {
                                points.append(SamplePoint(x: x, y: y))
                                points.append(SamplePoint(x: x, y: y + 1))
                            }
                            x &+= stepX
                        }
                        y &+= stepY
                    }

                    if points.count < 8 {
                        points.removeAll(keepingCapacity: true)
                        let fStepY = max(2, (safeY1 - safeY0) / 14)
                        var yy = safeY0
                        while yy < safeY1 {
                            let row = yy * refW
                            var xx = x0
                            while xx < x1 {
                                let gx = abs(Int(rPtr[row + xx + 1]) - Int(rPtr[row + xx - 1]))
                                let gy = abs(Int(rPtr[(yy + 1) * refW + xx]) - Int(rPtr[(yy - 1) * refW + xx]))
                                if gx + gy >= 12 {
                                    points.append(SamplePoint(x: xx, y: yy))
                                }
                                xx &+= stepX
                            }
                            yy &+= fStepY
                        }
                    }
                    if points.count < 8 {
                        points.removeAll(keepingCapacity: true)
                        let gStepX = max(2, (x1 - x0) / 6)
                        let gStepY = max(2, (safeY1 - safeY0) / 6)
                        var yy = safeY0
                        while yy < safeY1 {
                            var xx = x0
                            while xx < x1 {
                                points.append(SamplePoint(x: xx, y: yy))
                                xx &+= gStepX
                            }
                            yy &+= gStepY
                        }
                    }
                    guard points.count >= 4 else { continue }

                    if points.count > 48 {
                        // 偶数步进保留成对的 (y-1, y+1) 边缘两侧采样
                        let pairCount = points.count / 2
                        let pairStride = max(1, pairCount / 24)
                        var sub: [SamplePoint] = []
                        sub.reserveCapacity(48)
                        var pIdx = 0
                        while pIdx * 2 + 1 < points.count && sub.count < 48 {
                            sub.append(points[pIdx * 2])
                            sub.append(points[pIdx * 2 + 1])
                            pIdx &+= pairStride
                        }
                        points = sub
                    }

                    let invNorm = 1.0 / (Double(points.count) * 255.0)
                    var zeroSum = 0
                    for pt in points {
                        zeroSum &+= abs(Int(rPtr[pt.y * refW + pt.x]) - Int(cPtr[pt.y * curW + pt.x]))
                    }
                    tileZeroErrors.append(Double(zeroSum) * invNorm)

                    var cErrs = [Double](repeating: 0, count: candidates.count)
                    for (ci, dy) in candidates.enumerated() {
                        var errSum = 0
                        for pt in points {
                            errSum &+= abs(Int(rPtr[pt.y * refW + pt.x]) - Int(cPtr[(pt.y + dy) * curW + pt.x]))
                        }
                        cErrs[ci] = Double(errSum) * invNorm
                    }
                    tileErrors.append(cErrs)
                }
            }
        }

        let tileCount = tileErrors.count
        guard tileCount >= 1 else { return nil }

        let retained = max(1, (tileCount * 3 + 3) / 4)
        var sortedZero = tileZeroErrors
        sortedZero.sort()
        let zeroErr = sortedZero.prefix(retained).reduce(0, +) / Double(retained)

        var bestIndex = 0
        var bestErr = Double.infinity
        for ci in 0..<candidates.count {
            var errs = tileErrors.map { $0[ci] }
            errs.sort()
            let trimmed = errs.prefix(retained).reduce(0, +) / Double(retained)
            if trimmed < bestErr {
                bestErr = trimmed
                bestIndex = ci
            }
        }

        var inliers = 0
        for t in 0..<tileCount {
            let e = tileErrors[t][bestIndex]
            let z = tileZeroErrors[t]
            if e <= 0.08 && (e < z * 0.70 || e <= 0.025) {
                inliers += 1
            }
        }

        return RefinedMatch(
            dy: candidates[bestIndex],
            bestError: bestErr,
            zeroError: zeroErr,
            inlierTiles: inliers,
            evaluatedTiles: tileCount,
            coarseConfidence: coarseConfidence
        )
    }
}
