import CoreGraphics
import Foundation
import ImageIO

/// 拼接算法真实验证入口（不依赖 App，纯 CoreGraphics 绘制真实像素）。
///
/// 由 scripts/test-stitch.sh 单独编译：swiftc Sources/Scroll/Stitcher.swift + 本文件。
/// 验证内容：
/// 1. 用 CGContext 渲染一张 800x1100 的「整页」图（每行颜色随行号按黄金比例相位变化，
///    保证任意两行像素不同，可无歧义地检测重叠）；
/// 2. 从整页裁出两张 800x600 帧（帧 B 从第 500 行开始裁），真实重叠 = 100 行；
/// 3. 调 Stitcher.stitch 拼接，断言：输出尺寸 = 1100（= 600+600-100）、
///    检测到的重叠行数 == 合成真值 100、拼接结果行签名与整页原图逐点一致；
/// 4. 再做一组 3 帧 1600 行的拼接验证；
/// 5. 输出 /tmp/stitch_result.png 供人工检查。
/// 退出码 0 = 全部断言通过。
@main
struct TestStitchMain {
    static func main() {
        do {
            try run()
            print("[TestStitch] ALL PASS ✅")
        } catch {
            print("[TestStitch] FAILED ❌: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        let width = 800
        // ---- 用例 1：2 帧，真值重叠 100 行 ----
        let page1 = try renderPage(width: width, height: 1100, seed: 0)
        let frameA = try cropped(page1, y: 0, height: 600, name: "frameA")
        let frameB = try cropped(page1, y: 500, height: 600, name: "frameB")
        let truth1 = 100

        print("[TestStitch] 用例1: 帧A=800x600(页顶), 帧B=800x600(页 y=500 起), 真值重叠=\(truth1)")
        let result1 = try Stitcher.stitch(frames: [frameA, frameB])

        print("[TestStitch] 检测到重叠: \(result1.seams[1].overlapRows) 行 (期望 \(truth1))")
        try assertEquals(result1.seams[1].overlapRows, truth1, "重叠行数")
        try assertEquals(result1.seams[1].contributedRows, 500, "帧B净贡献行数")
        try assertEquals(result1.image.width, width, "拼接宽度")
        try assertEquals(result1.image.height, 600 + 600 - truth1, "拼接高度")
        try assertEquals(result1.seams[1].offsetY, 500, "帧B offsetY")
        try verifyRows(result1.image, against: page1, rows: [0, 100, 250, 499, 500, 600, 700, 999, 1099])
        try writePNG(result1.image, to: "/tmp/stitch_result.png")
        print("[TestStitch] 用例1 PASS: 输出 800x\(result1.image.height)，已写入 /tmp/stitch_result.png")

        // ---- 用例 2：3 帧，每相邻对真值重叠 100 行，总高 1600 ----
        let page2 = try renderPage(width: width, height: 1600, seed: 7)
        let f0 = try cropped(page2, y: 0, height: 600, name: "3f-0")
        let f1 = try cropped(page2, y: 500, height: 600, name: "3f-1")
        let f2 = try cropped(page2, y: 1000, height: 600, name: "3f-2")
        print("[TestStitch] 用例2: 3 帧 800x600, 真值重叠各 100 行, 期望总高 1600")
        let result2 = try Stitcher.stitch(frames: [f0, f1, f2])
        try assertEquals(result2.seams[1].overlapRows, 100, "用例2 帧1重叠")
        try assertEquals(result2.seams[2].overlapRows, 100, "用例2 帧2重叠")
        try assertEquals(result2.image.height, 1600, "用例2拼接高度")
        try verifyRows(result2.image, against: page2, rows: [0, 300, 599, 600, 900, 1100, 1599])
        try writePNG(result2.image, to: "/tmp/stitch_result_3frames.png")
        print("[TestStitch] 用例2 PASS: 输出 800x\(result2.image.height)，已写入 /tmp/stitch_result_3frames.png")
        for seam in result2.seams {
            print("[TestStitch] seam: frame#\(seam.frameIndex) offsetY=\(seam.offsetY) overlap=\(seam.overlapRows) contributed=\(seam.contributedRows)")
        }

        // ---- 用例 3：无重叠帧应报错（负向验证）----
        let solo = try cropped(page2, y: 0, height: 600, name: "solo")
        let disjoint = try cropped(page2, y: 0, height: 600, name: "disjoint") // 与 solo 相同区域…会重叠
        // 改用页内相距超过帧高的两段：必然无可信重叠
        let far = try cropped(page2, y: 0, height: 600, name: "far-0")
        let farB = try cropped(page1, y: 0, height: 600, name: "far-1") // 不同整页，内容完全不同
        do {
            _ = try Stitcher.stitch(frames: [far, farB])
            // 注意：disjoint/solo 未使用，仅为占位变量命名清晰
            _ = (solo, disjoint)
            throw TestError("用例3：不同页面应检测不到重叠，却拼接成功了")
        } catch let e as Stitcher.StitcherError {
            print("[TestStitch] 用例3 PASS: 无重叠正确报错 → \(e.localizedDescription)")
        }
    }

    // MARK: - 整页渲染

    /// 渲染「整页」：白色底 + 每行基色随行号按黄金比例相位变化（真实感渐变），
    /// 再在每一行画两条位置伪随机的黑色短横线 —— 保证任意两行的行签名亮度差
    /// 远大于拼接容差阈值（16），可无歧义地检测重叠；同时叠若干形状增加真实感。
    static func renderPage(width: Int, height: Int, seed: Int) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError("整页 CGContext 创建失败")
        }
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        // CGContext 原点在左下；第 row 行（图像坐标，顶部为 0）对应 ctx y = height-row-1
        for row in 0..<height {
            let hue = CGFloat((Double(row + seed) * 0.6180339887).truncatingRemainder(dividingBy: 1.0))
            let brightness = 0.45 + 0.15 * sin(Double(row) / 17.0 + Double(seed))
            ctx.setFillColor(CGColor(srgbRed: hue, green: 0.45, blue: CGFloat(brightness), alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(height - row - 1), width: CGFloat(width), height: 1))
        }
        // 叠加一些「内容」形状，让图看起来像真实页面
        ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.72, blue: 0.95, alpha: 0.85))
        for i in 0..<8 {
            let row = 60 + i * (height / 8)
            ctx.fill(CGRect(x: 60, y: CGFloat(height - row - 90), width: CGFloat(width - 120), height: 60))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.35, blue: 0.25, alpha: 0.9))
        for i in 0..<10 {
            let row = 30 + i * (height / 10)
            let x = CGFloat(40 + (i % 2) * 380)
            ctx.fillEllipse(in: CGRect(x: x, y: CGFloat(height - row - 30), width: 90, height: 28))
        }
        // 每行两条伪随机位置的高对比短横线（Knuth 乘法哈希散列行号），
        // 保证任意两行（含相隔较远的行）像素差异显著
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let dashWidth = 40
        let span = width - dashWidth - 10
        for row in 0..<height {
            let y = CGFloat(height - row - 1)
            let x1 = CGFloat(Int((UInt64(row + seed) &* 2_654_435_761) % UInt64(span)))
            let x2 = CGFloat(Int((UInt64(row + seed) &* 40_503) % UInt64(span)))
            ctx.fill(CGRect(x: x1, y: y, width: CGFloat(dashWidth), height: 1))
            ctx.fill(CGRect(x: x2, y: y, width: CGFloat(dashWidth), height: 1))
        }
        guard let image = ctx.makeImage() else {
            throw TestError("整页 makeImage 失败")
        }
        return image
    }

    static func cropped(_ image: CGImage, y: Int, height: Int, name: String) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)),
              cropped.width > 0, cropped.height > 0 else {
            throw TestError("裁剪 \(name) 失败 (y=\(y), h=\(height))")
        }
        return cropped
    }

    // MARK: - 校验

    /// 校验拼接结果的指定行与整页原图对应行逐点一致（行签名级，容差 0 应全等，
    /// 这里允许 ≤2 的采样抖动以覆盖像素格式转换路径）。
    static func verifyRows(_ stitched: CGImage, against page: CGImage, rows: [Int]) throws {
        let a = PixelBuffer(cgImage: stitched)
        let b = PixelBuffer(cgImage: page)
        for row in rows {
            guard row < a.height, row < b.height else {
                throw TestError("verifyRows: 行 \(row) 越界 (stitched=\(a.height), page=\(b.height))")
            }
            let sa = a.signature[row]
            let sb = b.signature[row]
            let maxDiff = zip(sa, sb).map { max($0, $1) - min($0, $1) }.max() ?? 0
            guard maxDiff <= 2 else {
                throw TestError("拼接结果第 \(row) 行与原图不一致 (maxSampleDiff=\(maxDiff))")
            }
        }
        print("[TestStitch] 行像素校验 OK: \(rows) 共 \(rows.count) 行与整页原图一致")
    }

    static func assertEquals<T: Equatable & CustomStringConvertible>(
        _ actual: T, _ expected: T, _ label: String
    ) throws {
        guard actual == expected else {
            throw TestError("\(label): 实际 \(actual) ≠ 期望 \(expected)")
        }
        print("[TestStitch] \(label) = \(actual) ✓")
    }

    // MARK: - PNG 输出

    static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
            throw TestError("无法创建 PNG 目标 \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw TestError("PNG 写入失败 \(path)")
        }
    }
}

struct TestError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}
