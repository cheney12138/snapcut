import CoreGraphics
import Foundation
import Vision

/// 智能框选的「像素层」适配器：Vision 文本行 / 视觉矩形候选。
///
/// ## 为什么是这两个请求
/// - 文本行用 `VNDetectTextRectanglesRequest`（字符框检测器，毫秒级）；
///   **绝不用 `VNRecognizeTextRequest`** —— 那是完整 OCR，一次几十到几百 ms，
///   悬停路径每秒都在跑，用它等于拿主线程当试验场。
/// - 视觉矩形用 `VNDetectRectanglesRequest`：卡片、按钮、图片、输入框这类
///   「规整块」在像素上就是四边形，比 AX 树可靠（AX 树在 Electron 里常常是空的）。
///
/// ## 坐标系
/// Vision 的 `boundingBox` 是**归一化坐标、原点图像左下、Y 向上**；
/// AppKit 全局坐标是**原点主屏左下、Y 向上** —— 两者 Y 方向一致，
/// 所以只需按 `screenFrame` 平移缩放，**不要翻转 Y**。
///
/// 但 `detectVisualTables` 走的是另一条路：**CGImage 像素坐标原点在左上、Y 向下**，
/// 与 AppKit 正好相反。映射与回推口径集中写在 `tableGrid(for:image:screenFrame:)`，
/// 实测口径（`CGBitmapContext` 恒等 CTM + `CGContext.draw` 、`CGImage.cropping(to:)`）：
/// 灰度缓冲区第 0 行 = 图像最上面一行 = 区域顶部（`regionGlobal.maxY`），**不要二次翻转**。
///
/// ## 隔离
/// Vision 的 `perform` 是同步阻塞调用，一律丢到全局并发队列执行，
/// 不占协作线程池；返回值是 `[CGRect]`（Sendable 值类型）可安全跨隔离域。
struct VisionSmartDetector: SmartVisionDetecting {
    /// 视觉大块矩形参数：专攻网页/文档/图片里的**表格框与大块卡片**
    ///
    /// 口径：宁可多吐几个候选（后面还有 AX 与领域层闸门），也不要漏掉那张
    /// 用户真正想要的表格；但下限要够硬，避免图标碎片 / 单字笔画混进来。
    private static let maxVisualObservations = 24
    private static let visualRectMinWidth: CGFloat = 48
    private static let visualRectMinHeight: CGFloat = 32

    func detectTextLines(in image: CGImage, screenFrame: CGRect) async -> [CGRect] {
        let start = ContinuousClock.now
        let normalizedBoxes = await runTextRectangles(image)
        if Task.isCancelled { return [] }

        var rects: [CGRect] = []
        rects.reserveCapacity(normalizedBoxes.count)
        for box in normalizedBoxes {
            let raw = Self.globalRect(fromNormalized: box, screenFrame: screenFrame)
            // 轻微舒适外扩（横向多给 4pt、纵向 2pt），再夹回屏幕，避免越界候选
            let padded = raw.insetBy(dx: -4, dy: -2).intersection(screenFrame)
            guard !padded.isNull, !padded.isEmpty else { continue }
            // 噪点闸：过小的框（标点、分隔线、图标碎片）不进候选
            guard padded.width >= 12, padded.height >= 10 else { continue }
            rects.append(padded)
        }

        Log.event(.ocr, "smartVision.textLines", [
            "ms": Self.elapsedMs(since: start),
            "n": "\(rects.count)",
        ])
        return rects
    }

    /// 视觉大块矩形（表格框 / 卡片 / 图片边界）
    ///
    /// 比文本行更「实在」：一张表格被整块框住，比它里面每一行的文字有用得多。
    /// 所以这里的参数向大块矩形倾斜（更多观测 / 更低置信度 / 更小最小尺寸），
    /// 再用 48×32 的下限与「贴满整屏」闸门把碎块和背景排掉。
    func detectVisualRects(in image: CGImage, screenFrame: CGRect) async -> [CGRect] {
        let start = ContinuousClock.now
        let normalizedBoxes = await runRectangleDetection(image)
        if Task.isCancelled { return [] }

        var rects: [CGRect] = []
        rects.reserveCapacity(normalizedBoxes.count)
        for box in normalizedBoxes {
            let global = Self.globalRect(fromNormalized: box, screenFrame: screenFrame)
            guard !global.isNull, !global.isEmpty else { continue }
            // 太小的是图标碎片 / 文字笔画框
            guard global.width >= Self.visualRectMinWidth,
                global.height >= Self.visualRectMinHeight else { continue }
            // 贴满整屏的框（壁纸、整窗背景）没有框选价值
            let coversAll = global.width >= screenFrame.width * 0.92
                && global.height >= screenFrame.height * 0.90
            guard !coversAll else { continue }
            rects.append(global.intersection(screenFrame))
        }

        Log.event(.overlay, "smartVision.rects", [
            "ms": Self.elapsedMs(since: start),
            "n": "\(rects.count)",
        ])
        return rects
    }

    // MARK: - 后台执行

    /// 文本行检测（返回 Vision 归一化框，Y 上）
    private func runTextRectangles(_ image: CGImage) async -> [CGRect] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectTextRectanglesRequest()
                request.reportCharacterBoxes = false
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    Log.error(.ocr, "smartVision.textLines.fail", [
                        "err": "\(error.localizedDescription)",
                    ])
                    continuation.resume(returning: [])
                    return
                }
                let boxes = (request.results ?? []).map(\.boundingBox)
                continuation.resume(returning: boxes)
            }
        }
    }

    /// 规整矩形检测（返回 Vision 归一化框，Y 上）
    private func runRectangleDetection(_ image: CGImage) async -> [CGRect] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectRectanglesRequest()
                request.maximumObservations = Self.maxVisualObservations
                request.minimumConfidence = 0.55
                request.minimumAspectRatio = 0.08
                request.maximumAspectRatio = 1.0
                request.minimumSize = 0.04
                request.quadratureTolerance = 18
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    Log.error(.overlay, "smartVision.rects.fail", [
                        "err": "\(error.localizedDescription)",
                    ])
                    continuation.resume(returning: [])
                    return
                }
                let boxes = (request.results ?? []).map(\.boundingBox)
                continuation.resume(returning: boxes)
            }
        }
    }

    // MARK: - 视觉表格网格线切分

    /// 候选表格区域下限（逻辑点）：小于它的矩形是按钮/卡片/单行，不值得做网格线扫描
    private static let tableRegionMinWidth: CGFloat = 160
    private static let tableRegionMinHeight: CGFloat = 80
    /// 一次最多扫几个区域（按面积降序）
    private static let tableRegionCap = 8

    /// 灰度网格线解析参数
    private static let lineEdgeDelta = 6
    private static let horizontalCoverage = 0.58
    private static let verticalCoverage = 0.50
    private static let rowMergeGap: CGFloat = 18
    private static let columnMergeGap: CGFloat = 28
    private static let rowEdgeMargin = 16
    private static let columnEdgeMargin = 24
    private static let maxRowCount = 60
    private static let maxColumnCount = 20
    private static let minAverageRowHeight: CGFloat = 20

    /// 从像素里直接切出表格网格（行 / 列 / 单元格）
    ///
    /// ## 为什么需要它
    /// AX 树只在「能激活 + 授权成功」时才有表格语义；纯静态表格截图、Canvas 表格、
    /// 没给辅助功能权限的网页大表格，AX 层什么都给不出。而表格在像素上就是一组
    /// 浅灰分隔线构成的二维网格，直接读像素反而最稳。
    ///
    /// ## 做法
    /// 1. 从候选矩形里挑出够大的几张（去重、最多 8 张）；
    /// 2. 每张按「逻辑点 1x」重采样成 8-bit 灰度图（`#EAEAEA` 这类浅线也能拉开 ≥ 6 的台阶）；
    /// 3. 扫横向线（行分隔线）/ 纵向线（列分隔线），合并相邻线、去掉贴边线；
    /// 4. 有效性闸门（防把普通卡片当表格）→ 回推成 AppKit 全局矩形。
    func detectVisualTables(
        in image: CGImage,
        screenFrame: CGRect,
        candidateRects: [CGRect]
    ) async -> [DetectedVisualTable] {
        guard !candidateRects.isEmpty,
            screenFrame.width > 0, screenFrame.height > 0 else { return [] }
        let regions = Self.tableRegions(from: candidateRects, screenFrame: screenFrame)
        guard !regions.isEmpty else { return [] }
        let start = ContinuousClock.now
        let tables = await runTableGridDetection(image, screenFrame: screenFrame, regions: regions)
        if Task.isCancelled { return [] }
        Log.event(.overlay, "smartVision.tables", [
            "ms": Self.elapsedMs(since: start),
            "n": "\(tables.count)",
        ])
        return tables
    }

    /// 挑候选区域：够大、按面积降序、去掉互相高度重叠的重复框（Vision 常对同一张表吐多个框）
    private static func tableRegions(from candidateRects: [CGRect], screenFrame: CGRect) -> [CGRect] {
        var eligible: [CGRect] = []
        eligible.reserveCapacity(candidateRects.count)
        for rect in candidateRects {
            let clipped = rect.intersection(screenFrame)
            guard !clipped.isNull,
                  clipped.width >= tableRegionMinWidth,
                  clipped.height >= tableRegionMinHeight else { continue }
            eligible.append(clipped)
        }
        eligible.sort { lhs, rhs in
            (lhs.width * lhs.height) > (rhs.width * rhs.height)
        }

        var picked: [CGRect] = []
        for rect in eligible {
            let duplicated = picked.contains { kept in
                let overlap = kept.intersection(rect)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return false }
                let smaller = min(kept.width * kept.height, rect.width * rect.height)
                guard smaller > 0 else { return false }
                // 大半落在已选区域内 ⇒ 同一张表的重复框
                return overlap.width * overlap.height / smaller >= 0.7
            }
            guard !duplicated else { continue }
            picked.append(rect)
            if picked.count >= tableRegionCap { break }
        }
        return picked
    }

    // MARK: - 后台执行（网格线解析）

    private func runTableGridDetection(
        _ image: CGImage,
        screenFrame: CGRect,
        regions: [CGRect]
    ) async -> [DetectedVisualTable] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var tables: [DetectedVisualTable] = []
                tables.reserveCapacity(regions.count)
                for region in regions {
                    if let table = Self.tableGrid(for: region, image: image, screenFrame: screenFrame) {
                        tables.append(table)
                    }
                }
                continuation.resume(returning: tables)
            }
        }
    }

    /// 单张候选区域的网格切分
    ///
    /// ## 坐标映射（Y 方向是唯一容易错的地方，按这段写）
    /// - `rectGlobal` / `screenFrame`：AppKit 全局，原点主屏左下，**Y 向上**
    /// - `CGImage` 像素：原点左上，**Y 向下**
    /// - 像素偏移：`pxY = (screenFrame.maxY - rectGlobal.maxY) * sy`
    ///   （屏幕顶到区域顶的距离就是 Y 向下的起点，**这一步就是翻转全部**）
    /// - 灰度缓冲区第 0 行 = 区域顶部 = `rectGlobal.maxY`；所以 `[y0, y1]` 回推为
    ///   `globalMinY = rectGlobal.maxY - y1`、`height = y1 - y0`，无需再翻
    private static func tableGrid(
        for region: CGRect,
        image: CGImage,
        screenFrame: CGRect
    ) -> DetectedVisualTable? {
        let sx = CGFloat(image.width) / screenFrame.width
        let sy = CGFloat(image.height) / screenFrame.height
        guard sx > 0, sy > 0 else { return nil }

        let pixelRect = CGRect(
            x: (region.minX - screenFrame.minX) * sx,
            y: (screenFrame.maxY - region.maxY) * sy,  // ← Y 反转：屏幕顶往下量
            width: region.width * sx,
            height: region.height * sy
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelRect.isNull, pixelRect.width >= 4, pixelRect.height >= 4,
            let cropped = image.cropping(to: pixelRect) else { return nil }

        // 渲染到 1x 逻辑分辨率灰度图：既快（比 Retina 少 4 倍像素）又自动抹平细线采样抖动
        let width = Int(region.width.rounded())
        let height = Int(region.height.rounded())
        guard let raster = GrayRaster(width: width, height: height, image: cropped) else { return nil }

        // 1) 行分隔线（横向）
        let rawRows = raster.horizontalLinePositions(edgeDelta: lineEdgeDelta,
                                                    coverage: horizontalCoverage)
        let rowLines = Self.mergedLines(rawRows, minGap: rowMergeGap)
            .filter { $0 >= rowEdgeMargin && $0 <= height - rowEdgeMargin }
        let rowSplits = [0] + rowLines + [height]

        // 2) 列分隔线（纵向）
        let rawColumns = raster.verticalLinePositions(edgeDelta: lineEdgeDelta,
                                                     coverage: verticalCoverage)
        let columnLines = Self.mergedLines(rawColumns, minGap: columnMergeGap)
            .filter { $0 >= columnEdgeMargin && $0 <= width - columnEdgeMargin }
        let colSplits = [0] + columnLines + [width]

        // 3) 有效性闸门：至少 2 行，且「有竖线（真二维网格）」或「至少 3 行（无竖线表格）」
        let rowCount = rowSplits.count - 1
        let columnCount = colSplits.count - 1
        guard rowCount >= 2 else { return nil }
        guard colSplits.count >= 3 || rowSplits.count >= 4 else { return nil }
        guard rowCount <= maxRowCount, columnCount <= maxColumnCount else { return nil }
        guard CGFloat(height) / CGFloat(rowCount) >= minAverageRowHeight else { return nil }

        // 4) 回推 AppKit 全局坐标（Y 向上）
        func globalRect(x0: Int, x1: Int, y0: Int, y1: Int) -> CGRect {
            CGRect(
                x: region.minX + CGFloat(x0),
                y: region.maxY - CGFloat(y1),  // ← 唯一翻转点：灰度 y 从区域顶往下
                width: CGFloat(x1 - x0),
                height: CGFloat(y1 - y0)
            )
        }

        var rowRects: [CGRect] = []
        rowRects.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            rowRects.append(globalRect(
                x0: 0, x1: width, y0: rowSplits[index], y1: rowSplits[index + 1]
            ))
        }

        var columnRects: [CGRect] = []
        var cellRects: [CGRect] = []
        if colSplits.count >= 3 {
            columnRects.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                columnRects.append(globalRect(
                    x0: colSplits[index], x1: colSplits[index + 1], y0: 0, y1: height
                ))
            }
            cellRects.reserveCapacity(rowCount * columnCount)
            for rowIndex in 0..<rowCount {
                for columnIndex in 0..<columnCount {
                    cellRects.append(globalRect(
                        x0: colSplits[columnIndex], x1: colSplits[columnIndex + 1],
                        y0: rowSplits[rowIndex], y1: rowSplits[rowIndex + 1]
                    ))
                }
            }
        }

        return DetectedVisualTable(
            tableRect: region,
            rowRects: rowRects,
            columnRects: columnRects,
            cellRects: cellRects
        )
    }

    /// 相邻候选线合并为其中心（扫描时同一条粗线会命中好几行像素）
    private static func mergedLines(_ raw: [Int], minGap: CGFloat) -> [Int] {
        guard let first = raw.first else { return [] }
        var merged: [Int] = []
        var groupStart = first
        var groupLast = first
        for value in raw.dropFirst() {
            if CGFloat(value - groupLast) < minGap {
                groupLast = value
            } else {
                merged.append((groupStart + groupLast) / 2)
                groupStart = value
                groupLast = value
            }
        }
        merged.append((groupStart + groupLast) / 2)
        return merged
    }

    // MARK: - 坐标换算

    /// Vision 归一化框（原点左下、Y 上）→ AppKit 全局矩形
    ///
    /// Y 方向两者一致，只做平移 + 缩放。
    static func globalRect(fromNormalized box: CGRect, screenFrame: CGRect) -> CGRect {
        guard box.minX.isFinite, box.minY.isFinite,
              box.width.isFinite, box.height.isFinite else { return .null }
        return CGRect(
            x: screenFrame.minX + box.minX * screenFrame.width,
            y: screenFrame.minY + box.minY * screenFrame.height,
            width: box.width * screenFrame.width,
            height: box.height * screenFrame.height
        )
    }

    // MARK: - 计时

    private static func elapsedMs(since start: ContinuousClock.Instant) -> String {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        let ms = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        return String(format: "%.0f", ms)
    }
}

// MARK: - 灰度光栅（网格线解析用）

/// 1x 逻辑分辨率的 8-bit 灰度缓冲，只在后台队列里短暂存活。
///
/// 行序实测口径（不要凭印象改）：`CGBitmapContext` 用恒等 CTM + `CGContext.draw(image:)`
/// 画进去后，缓冲区第 0 行就是图像的**最上面一行**，因此 `y = 0` 对应区域顶部。
private struct GrayRaster {
    /// 横/纵扫描时两端各留的内边距（逻辑点）：贴边的圆角/阴影会被当成线
    private static let scanPad = 4

    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(width: Int, height: Int, image: CGImage) {
        guard width > 4, height > 4 else { return nil }
        var buffer = [UInt8](repeating: 255, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0).rawValue
            ) else { return false }
            // 缩小要用高质量插值，否则 Retina 上的 1px 浅灰线会被最近邻采样直接丢掉
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = buffer
    }

    @inline(__always)
    private func level(_ x: Int, _ y: Int) -> Int {
        Int(pixels[y * width + x])
    }

    /// 横线候选（行分隔线）的 y 集合，升序；`coverage` = 该行上需满足边判据的横向像素占比
    ///
    /// 判据 1 抓「细网格线」：本行亮度明显偏离上下两行的均值
    /// （`#EAEAEA` 压在白底上只有 ~21 的台阶，采样到 1x 后仍剩 ≥ 6，能稳定抓到）；
    /// 判据 2 抓「底色切换」：表头灰底→正文白底、斑马纹行交替，
    /// 两侧颜色不同而中间行介于两者之间。
    func horizontalLinePositions(edgeDelta: Int, coverage: Double) -> [Int] {
        let padX = min(Self.scanPad, max(0, width / 4))
        guard height > 2, width > 2 * padX + 1 else { return [] }
        var hits: [Int] = []
        for y in 1..<(height - 1) {
            var matched = 0
            var total = 0
            var x = padX
            while x < width - padX {
                total += 1
                if Self.isHorizontalEdge(
                    center: level(x, y),
                    up: level(x, y - 1),
                    down: level(x, y + 1),
                    edgeDelta: edgeDelta
                ) {
                    matched += 1
                }
                x += 1
            }
            guard total > 0 else { continue }
            if Double(matched) / Double(total) >= coverage { hits.append(y) }
        }
        return hits
    }

    /// 竖线候选（列分隔线）的 x 集合，升序；50% 覆盖率就够稳（文字偶尔压线不影响）
    func verticalLinePositions(edgeDelta: Int, coverage: Double) -> [Int] {
        let padY = min(Self.scanPad, max(0, height / 4))
        guard width > 2, height > 2 * padY + 1 else { return [] }
        var hits: [Int] = []
        for x in 1..<(width - 1) {
            var matched = 0
            var total = 0
            var y = padY
            while y < height - padY {
                let center = level(x, y)
                let left = level(x - 1, y)
                let right = level(x + 1, y)
                total += 1
                if abs(center - (left + right) / 2) >= edgeDelta || abs(right - left) >= edgeDelta {
                    matched += 1
                }
                y += 1
            }
            guard total > 0 else { continue }
            if Double(matched) / Double(total) >= coverage { hits.append(x) }
        }
        return hits
    }

    private static func isHorizontalEdge(
        center: Int,
        up: Int,
        down: Int,
        edgeDelta: Int
    ) -> Bool {
        if abs(center - (up + down) / 2) >= edgeDelta { return true }
        return abs(down - up) >= edgeDelta
            && abs(center - up) <= edgeDelta
            && abs(down - center) <= edgeDelta
    }
}
