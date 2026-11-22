import CoreGraphics
import Foundation
import ImageIO

/// 拼接算法真实验证入口（不依赖 App，纯 CoreGraphics 绘制真实像素）。
/// 由 scripts/test-stitch.sh 编译运行：TileMotionEstimator + Stitcher + 本文件。
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
        try testBasicCases()
        try testRealisticWebUI()
        try testNon32MultipleAndSlowShifts()
        try testStickyHeaderAndFooter()
        try testPartialScrollWithFixedSidebar()
        try testIncrementalSessionWithBounceBack()
        try testWidescreenLightChatDocLayout()
        try testMultiStepRollbackCanvasWindowZeroDrift()
    }

    // MARK: - 用例 1~5：基础 + 负向 + 不等高 + 4K 性能

    static func testBasicCases() throws {
        let width = 800
        // ---- 用例 1：2 帧，真值重叠 100 行 ----
        let page1 = try renderPage(width: width, height: 1100, seed: 0)
        let frameA = try cropped(page1, y: 0, height: 600, name: "frameA")
        let frameB = try cropped(page1, y: 500, height: 600, name: "frameB")
        let truth1 = 100

        print("[TestStitch] 用例1: 帧A=800x600(页顶), 帧B=800x600(页 y=500 起), 真值重叠=\(truth1)")
        let result1 = try Stitcher.stitch(frames: [frameA, frameB])
        try assertEquals(result1.seams[1].overlapRows, truth1, "重叠行数")
        try assertEquals(result1.seams[1].contributedRows, 500, "帧B净贡献行数")
        try assertEquals(result1.image.width, width, "拼接宽度")
        try assertEquals(result1.image.height, 600 + 600 - truth1, "拼接高度")
        try assertEquals(result1.seams[1].offsetY, 500, "帧B offsetY")
        try verifyRows(result1.image, against: page1, rows: [0, 100, 250, 499, 500, 600, 700, 999, 1099])
        try writePNG(result1.image, to: "/tmp/stitch_result.png")
        print("[TestStitch] 用例1 PASS")

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
        print("[TestStitch] 用例2 PASS")

        // ---- 用例 3：无重叠帧应报错（负向验证）----
        let pageInv = try renderPage(width: width, height: 600, seed: 7, invert: true)
        let far = try cropped(page2, y: 0, height: 600, name: "far-0")
        let farB = try cropped(pageInv, y: 0, height: 600, name: "far-inv")
        do {
            _ = try Stitcher.stitch(frames: [far, farB])
            throw TestError("用例3：不同页面应检测不到重叠，却拼接成功了")
        } catch let e as Stitcher.StitcherError {
            print("[TestStitch] 用例3 PASS: 无重叠正确报错 → \(e.localizedDescription)")
        }

        // ---- 用例 4：行数不等（600 + 700, 重叠 100）----
        let page3 = try renderPage(width: width, height: 1300, seed: 3)
        let g0 = try cropped(page3, y: 0, height: 600, name: "grow-0")
        let g1 = try cropped(page3, y: 500, height: 700, name: "grow-1")
        let truth4 = 100
        print("[TestStitch] 用例4: 帧g0=800x600, 帧g1=800x700（行数不等）, 真值重叠=\(truth4)")
        let result4 = try Stitcher.stitch(frames: [g0, g1])
        try assertEquals(result4.seams[1].overlapRows, truth4, "用例4 重叠行数")
        try assertEquals(result4.image.width, width, "用例4 拼接宽度")
        try assertEquals(result4.image.height, 600 + 700 - truth4, "用例4 拼接高度")
        try verifyRows(result4.image, against: page3, rows: [0, 599, 600, 900, 1199])
        print("[TestStitch] 用例4 PASS")

        // ---- 用例 5：大帧性能（4K 级两帧，< 1000ms）----
        let bigPage = try renderPage(width: 3000, height: 4200, seed: 11)
        let b0 = try cropped(bigPage, y: 0, height: 2098, name: "big-0")
        let b1 = try cropped(bigPage, y: 1798, height: 2098, name: "big-1")
        print("[TestStitch] 用例5: 两张 3000x2098 大帧（真值重叠 300 行），计时拼接")
        let perfStart = DispatchTime.now()
        let result5 = try Stitcher.stitch(frames: [b0, b1])
        let perfMs = Int(Double(DispatchTime.now().uptimeNanoseconds - perfStart.uptimeNanoseconds) / 1_000_000)
        try assertEquals(result5.seams[1].overlapRows, 300, "用例5 重叠行数")
        try assertEquals(result5.image.height, 2098 * 2 - 300, "用例5 拼接高度")
        print("[TestStitch] 用例5 耗时: \(perfMs)ms")
        guard perfMs < 1000 else {
            throw TestError("用例5：大帧拼接耗时 \(perfMs)ms ≥ 1000ms")
        }
        print("[TestStitch] 用例5 PASS: 4K 大帧拼接 < 1s 完成")
    }

    // MARK: - 用例 6：真实网页/UI 风格长页（白底 + 文本行块 + 卡片 + 留白边距）

    static func testRealisticWebUI() throws {
        print("[TestStitch] 用例6: 真实网页/UI 风格长页（白底 + 卡片 + 文本块 + 留白）")
        let width = 1000
        let viewportH = 700
        let totalH = 1900
        let webPage = try renderWebUIPage(width: width, height: totalH, seed: 42)
        let offsets = [0, 260, 580, 910, 1200]
        let frames = try offsets.enumerated().map { idx, y in
            try cropped(webPage, y: y, height: viewportH, name: "web-\(idx)")
        }
        let result = try Stitcher.stitch(frames: frames)
        try assertClose(result.image.height, totalH, tolerance: 2, label: "用例6 网页长图总高")
        try verifyRows(result.image, against: webPage, rows: [20, 200, 450, 750, 1050, 1400, 1850])
        print("[TestStitch] 用例6 PASS: 真实网页/UI 长页精确拼接 (\(result.image.width)x\(result.image.height))")
    }

    // MARK: - 用例 7：非 32px 倍数与慢滚位移（13, 27, 45, 117, 313 px）

    static func testNon32MultipleAndSlowShifts() throws {
        print("[TestStitch] 用例7: 非 32px 倍数与慢滚位移 (13, 27, 45, 117, 313 px)")
        let width = 960
        let viewportH = 680
        let shifts = [13, 27, 45, 117, 313]
        let totalShift = shifts.reduce(0, +)
        let totalH = viewportH + totalShift
        let webPage = try renderWebUIPage(width: width, height: totalH, seed: 99)

        var frames: [CGImage] = []
        var y = 0
        frames.append(try cropped(webPage, y: 0, height: viewportH, name: "shift-0"))
        for (i, s) in shifts.enumerated() {
            y += s
            frames.append(try cropped(webPage, y: y, height: viewportH, name: "shift-\(i + 1)"))
        }

        let result = try Stitcher.stitch(frames: frames)
        for (i, truthShift) in shifts.enumerated() {
            let detectedShift = result.seams[i + 1].contributedRows
            try assertClose(detectedShift, truthShift, tolerance: 1, label: "用例7 第\(i + 1)步位移")
        }
        try assertClose(result.image.height, totalH, tolerance: 2, label: "用例7 总高")
        try verifyRows(result.image, against: webPage, rows: [15, 120, 340, 560, 820, totalH - 40])
        print("[TestStitch] 用例7 PASS: 非 32px 倍数慢滚位移全部像素级命中")
    }

    // MARK: - 用例 8：固定顶栏（sticky header）+ 固定底栏（sticky footer）洁净合成

    static func testStickyHeaderAndFooter() throws {
        print("[TestStitch] 用例8: sticky header (80px) + sticky footer (60px) 洁净合成")
        let width = 960
        let viewportH = 680
        let headerH = 80
        let footerH = 60
        let bodyViewportH = viewportH - headerH - footerH // 540
        let shifts = [45, 137, 211, 189]
        let totalBodyH = bodyViewportH + shifts.reduce(0, +) // 1122
        let expectedTotalH = headerH + totalBodyH + footerH  // 1262

        let bodyPage = try renderWebUIPage(width: width, height: totalBodyH, seed: 123)
        let headerImg = try renderStickyBar(width: width, height: headerH, isHeader: true)
        let footerImg = try renderStickyBar(width: width, height: footerH, isHeader: false)

        // 构造真值整页：顶栏 + 完整内容 + 底栏
        let truthPage = try composeTruthStickyPage(
            width: width, header: headerImg, body: bodyPage, footer: footerImg)

        // 构造每帧视口截图：每帧顶部都是 sticky header，底部都是 sticky footer，中间是滑动的 body 窗口
        var frames: [CGImage] = []
        var scrollY = 0
        frames.append(try composeStickyViewport(
            width: width, viewportH: viewportH,
            header: headerImg, body: bodyPage, bodyOffset: scrollY, footer: footerImg))
        for shift in shifts {
            scrollY += shift
            frames.append(try composeStickyViewport(
                width: width, viewportH: viewportH,
                header: headerImg, body: bodyPage, bodyOffset: scrollY, footer: footerImg))
        }

        let result = try Stitcher.stitch(frames: frames)
        try assertClose(result.image.height, expectedTotalH, tolerance: 2, label: "用例8 洁净长图总高")
        // 顶栏（0..<80）仅在顶部，底栏（totalH-60..<totalH）仅在底部，中间绝无重复顶/底栏
        try verifyRegionExact(result.image, against: truthPage, startRow: 0, endRow: headerH, label: "顶栏仅在顶部")
        try verifyRegionExact(result.image, against: truthPage, startRow: expectedTotalH - footerH, endRow: expectedTotalH, label: "底栏仅在底部")
        try verifyRegionExact(result.image, against: truthPage, startRow: headerH + 20, endRow: expectedTotalH - footerH - 20, label: "长图中间洁净无重复栏")
        print("[TestStitch] 用例8 PASS: 顶栏仅顶部、底栏仅底部、中间零重影")
    }

    // MARK: - 用例 9：局部滚动页（固定侧边栏 + 顶栏占比 > 55%，局部卡片区滚动）

    static func testPartialScrollWithFixedSidebar() throws {
        print("[TestStitch] 用例9: 局部滚动页（左侧 55% 固定侧边栏 + 顶部 60px 固定顶栏，静止区 > 60%）")
        let width = 1000
        let viewportH = 700
        let sidebarW = 550
        let headerH = 60
        let scrollW = width - sidebarW // 450
        let shifts = [67, 143, 195]
        let bodyScrollH = (viewportH - headerH) + shifts.reduce(0, +)

        let sidebar = try renderSidebar(width: sidebarW, height: viewportH)
        let header = try renderStickyBar(width: width, height: headerH, isHeader: true)
        let scrollFeed = try renderWebUIPage(width: scrollW, height: bodyScrollH, seed: 777)

        var frames: [CGImage] = []
        var scrollY = 0
        frames.append(try composeSidebarViewport(
            width: width, viewportH: viewportH,
            header: header, sidebar: sidebar,
            feed: scrollFeed, feedOffset: scrollY, sidebarW: sidebarW))
        for s in shifts {
            scrollY += s
            frames.append(try composeSidebarViewport(
                width: width, viewportH: viewportH,
                header: header, sidebar: sidebar,
                feed: scrollFeed, feedOffset: scrollY, sidebarW: sidebarW))
        }

        let result = try Stitcher.stitch(frames: frames)
        let expectedTotalH = viewportH + shifts.reduce(0, +)
        try assertClose(result.image.height, expectedTotalH, tolerance: 2, label: "用例9 局部滚动总高")
        for (i, truthShift) in shifts.enumerated() {
            try assertClose(result.seams[i + 1].contributedRows, truthShift, tolerance: 1, label: "用例9 第\(i + 1)步局部滚动位移")
        }
        print("[TestStitch] 用例9 PASS: >60% 静止区下仍精准识别局部滚动")
    }

    // MARK: - 用例 10：增量流式会话（静止帧 + 下滚 + 轻微回弹 + 继续下滚 + 到底）

    static func testIncrementalSessionWithBounceBack() throws {
        print("[TestStitch] 用例10: 增量流式会话（静止 → 下滚 → 回弹上滚 17px → 继续下滚 → 到底）")
        let width = 920
        let viewportH = 640
        // 视口轨迹：0 -> 0 -> 120 -> 215 -> 198 (回弹上滚17px) -> 198 -> 338 -> 421 -> 421 -> 421
        let trajectory = [0, 0, 120, 215, 198, 198, 338, 421, 421, 421]
        let maxPos = trajectory.max() ?? 0
        let truthTotalH = viewportH + maxPos
        let page = try renderWebUIPage(width: width, height: truthTotalH, seed: 555)

        let session = Stitcher.Session()
        var statuses: [Stitcher.PushStatus] = []
        for (idx, pos) in trajectory.enumerated() {
            let frame = try cropped(page, y: pos, height: viewportH, name: "inc-\(idx)")
            statuses.append(session.push(frame))
        }

        // 断言各阶段状态语义
        guard case .firstFrame = statuses[0] else {
            throw TestError("用例10 帧0应为 firstFrame，实际 \(statuses[0])")
        }
        guard case .staticFrame = statuses[1] else {
            throw TestError("用例10 帧1应为 staticFrame，实际 \(statuses[1])")
        }
        guard case .appended(let g2, _) = statuses[2], abs(g2 - 120) <= 1 else {
            throw TestError("用例10 帧2应为 appended(~120)，实际 \(statuses[2])")
        }
        guard case .appended(let g3, _) = statuses[3], abs(g3 - 95) <= 1 else {
            throw TestError("用例10 帧3应为 appended(~95)，实际 \(statuses[3])")
        }
        guard case .contained(let p4, _) = statuses[4], abs(p4 - 198) <= 1 else {
            throw TestError("用例10 帧4(回弹)应为 contained(~198)，实际 \(statuses[4])")
        }
        guard case .staticFrame = statuses[5] else {
            throw TestError("用例10 帧5应为 staticFrame，实际 \(statuses[5])")
        }
        // 帧6从 198 滚到 338（相对前帧移 140，但 maxPosition=215，净新增 = 338-215 = 123！）
        guard case .appended(let g6, _) = statuses[6], abs(g6 - 123) <= 2 else {
            throw TestError("用例10 帧6(回弹后续滚)净新增应≈123，实际 \(statuses[6])")
        }
        guard case .appended(let g7, _) = statuses[7], abs(g7 - 83) <= 2 else {
            throw TestError("用例10 帧7应为 appended(~83)，实际 \(statuses[7])")
        }
        guard case .staticFrame = statuses[8], case .staticFrame = statuses[9] else {
            throw TestError("用例10 末尾静止帧应为 staticFrame")
        }

        let finishStart = DispatchTime.now()
        let result = try session.finish()
        let finishMs = Int(Double(DispatchTime.now().uptimeNanoseconds - finishStart.uptimeNanoseconds) / 1_000_000)
        try assertClose(result.image.height, truthTotalH, tolerance: 3, label: "用例10 流式长图总高")
        try verifyRows(result.image, against: page, rows: [10, 150, 300, 500, 700, 900, truthTotalH - 20])
        print("[TestStitch] 用例10 PASS: finish() 耗时 \(finishMs)ms，回弹无破坏且总高与像素全匹配")
    }

    // MARK: - 用例 11：宽屏浅色文档/聊天页（左右各 ~28% 纯白留白 + 中间窄列正文 + 固定顶栏 + 固定底栏输入框）

    static func testWidescreenLightChatDocLayout() throws {
        print("[TestStitch] 用例11: 宽屏浅色文档/聊天页（左右 28% 纯白留白 + 中间窄列正文 + sticky 顶栏/底栏）")
        let width = 1440
        let viewportH = 760
        let headerH = 64
        let footerH = 88
        let bodyViewportH = viewportH - headerH - footerH // 608
        let shifts = [31, 79, 145, 223]
        let totalBodyH = bodyViewportH + shifts.reduce(0, +)
        let expectedTotalH = headerH + totalBodyH + footerH

        let bodyPage = try renderWidescreenLightDocBody(width: width, height: totalBodyH, seed: 2026)
        let headerImg = try renderLightStickyHeader(width: width, height: headerH)
        let footerImg = try renderLightStickyInputFooter(width: width, height: footerH)
        let truthPage = try composeTruthStickyPage(
            width: width, header: headerImg, body: bodyPage, footer: footerImg)

        var frames: [CGImage] = []
        var scrollY = 0
        frames.append(try composeStickyViewport(
            width: width, viewportH: viewportH,
            header: headerImg, body: bodyPage, bodyOffset: scrollY, footer: footerImg))
        for shift in shifts {
            scrollY += shift
            frames.append(try composeStickyViewport(
                width: width, viewportH: viewportH,
                header: headerImg, body: bodyPage, bodyOffset: scrollY, footer: footerImg))
        }

        let session = Stitcher.Session()
        for (idx, frame) in frames.enumerated() {
            let status = session.push(frame)
            if idx == 0 {
                guard case .firstFrame = status else {
                    throw TestError("用例11 帧0应为 firstFrame，实际 \(status)")
                }
            } else {
                guard case .appended(let growth, _) = status else {
                    throw TestError("用例11 帧\(idx) 应检出向下滚动（实际 \(status)，未误判静止）")
                }
                try assertClose(growth, shifts[idx - 1], tolerance: 1, label: "用例11 第\(idx)步位移")
            }
        }
        let result = try session.finish()
        try assertClose(result.image.height, expectedTotalH, tolerance: 2, label: "用例11 宽屏浅色长图总高")
        try verifyRegionExact(result.image, against: truthPage, startRow: 0, endRow: headerH, label: "用例11 浅色顶栏仅在顶部")
        try verifyRegionExact(result.image, against: truthPage, startRow: expectedTotalH - footerH, endRow: expectedTotalH, label: "用例11 底栏输入框仅在底部")
        try verifyRegionExact(result.image, against: truthPage, startRow: headerH + 20, endRow: expectedTotalH - footerH - 20, label: "用例11 中间正文洁净无重影")
        print("[TestStitch] 用例11 PASS: 宽屏浅色文档/聊天页精准拼接且无重复顶/底栏")
    }

    // MARK: - 用例 12：多次往回滚 + CanvasWindow 零漂移续拼（含 sticky header/footer）

    static func testMultiStepRollbackCanvasWindowZeroDrift() throws {
        print("[TestStitch] 用例12: 多步来回滚动 + CanvasWindow 零漂移续拼（含 sticky 顶/底栏）")
        let width = 1200
        let viewportH = 720
        let headerH = 60
        let footerH = 80
        let bodyViewportH = viewportH - headerH - footerH // 580
        let maxScroll = 640
        let totalBodyH = bodyViewportH + maxScroll
        let expectedTotalH = headerH + totalBodyH + footerH

        let bodyPage = try renderWidescreenLightDocBody(width: width, height: totalBodyH, seed: 777)
        let headerImg = try renderLightStickyHeader(width: width, height: headerH)
        let footerImg = try renderLightStickyInputFooter(width: width, height: footerH)
        let truthPage = try composeTruthStickyPage(
            width: width, header: headerImg, body: bodyPage, footer: footerImg)

        // 先下滚到 380 → 连续 4 步往回退到 110 → 再多步下滚穿过 380 直达 640
        let path = [0, 140, 270, 380, 310, 235, 165, 110, 210, 340, 490, 640]
        let session = Stitcher.Session()
        var containedCount = 0
        for (i, scrollY) in path.enumerated() {
            let frame = try composeStickyViewport(
                width: width, viewportH: viewportH,
                header: headerImg, body: bodyPage, bodyOffset: scrollY, footer: footerImg)
            let status = session.push(frame)
            if i == 0 {
                guard case .firstFrame = status else { throw TestError("用例12 帧0应为 firstFrame") }
            } else if i >= 4 && i <= 9 {
                guard case .contained = status else {
                    throw TestError("用例12 帧\(i)(y=\(scrollY)) 在已采集区内应为 contained，实际 \(status)")
                }
                containedCount += 1
            } else {
                guard case .appended = status else {
                    throw TestError("用例12 帧\(i)(y=\(scrollY)) 应为 appended，实际 \(status)")
                }
            }
        }
        guard containedCount == 6 else {
            throw TestError("用例12 期望 6 次 contained，实际 \(containedCount)")
        }
        let result = try session.finish()
        try assertClose(result.image.height, expectedTotalH, tolerance: 2, label: "用例12 零漂移总高")
        try verifyRegionExact(result.image, against: truthPage, startRow: 0, endRow: headerH, label: "用例12 顶栏")
        try verifyRegionExact(result.image, against: truthPage, startRow: expectedTotalH - footerH, endRow: expectedTotalH, label: "用例12 底栏")
        try verifyRegionExact(result.image, against: truthPage, startRow: headerH + 20, endRow: expectedTotalH - footerH - 20, label: "用例12 往返续拼正文零错位")
        print("[TestStitch] 用例12 PASS: 6 次往返 contained + 续拼零漂移 (总高 \(result.image.height))")
    }

    // MARK: - 测试画面生成器

    static func renderPage(width: Int, height: Int, seed: Int, invert: Bool = false) throws -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            throw TestError("整页 CGContext 创建失败")
        }
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        for row in 0..<height {
            let r0 = Double((UInt64(row + seed) &* 6_364_136_223_846_793_005) >> 33 % 1000) / 1000
            let g0 = Double((UInt64(row + seed) &* 28_629_335_559_573_927) >> 33 % 1000) / 1000
            let b0 = Double((UInt64(row + seed) &* 9_767_878_279_757_191) >> 33 % 1000) / 1000
            var r = r0, g = g0, b = b0
            if invert { r = 1.0 - r; g = 1.0 - g; b = 1.0 - b }
            ctx.setFillColor(CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(height - row - 1), width: CGFloat(width), height: 1))
        }
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
        guard let image = ctx.makeImage() else { throw TestError("整页 makeImage 失败") }
        return image
    }

    /// 模拟真实网页/UI 长页：浅灰/白底 + 卡片边框 + 伪随机多宽度文字行块 + 头像方块 + 大面积留白边距
    static func renderWebUIPage(width: Int, height: Int, seed: Int) throws -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            throw TestError("WebUI CGContext 创建失败")
        }
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let cardH = 148
        let cardGap = 16
        let marginX = max(24, width / 12)
        let cardW = width - marginX * 2
        var yTop = 16
        var cardIdx = 0
        while yTop + 40 < height {
            let cy = CGFloat(height - yTop - cardH)
            // 白色卡片底 + 描边
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(marginX), y: cy, width: CGFloat(cardW), height: CGFloat(cardH)))
            ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.87, blue: 0.90, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.stroke(CGRect(x: CGFloat(marginX), y: cy, width: CGFloat(cardW), height: CGFloat(cardH)))

            // 左侧色块头像
            let hVal = UInt64(bitPattern: Int64(cardIdx)) &* 2_654_435_761 &+ UInt64(bitPattern: Int64(seed)) &* 40_503
            let cr = CGFloat(30 + (hVal % 180)) / 255.0
            let cg = CGFloat(40 + ((hVal >> 8) % 180)) / 255.0
            let cb = CGFloat(60 + ((hVal >> 16) % 170)) / 255.0
            ctx.setFillColor(CGColor(srgbRed: cr, green: cg, blue: cb, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(marginX + 16), y: cy + CGFloat(cardH - 56), width: 40, height: 40))

            // 标题行 + 多行模拟英文/中文词块（不对称位置与宽度，无周期重复）
            for line in 0..<5 {
                let lineTop = yTop + 18 + line * 22
                guard lineTop + 10 < height else { break }
                let ly = CGFloat(height - lineTop - 10)
                let startX = marginX + (line < 2 ? 72 : 16)
                var curX = startX
                let maxLineX = marginX + cardW - 24
                var wordIdx = 0
                while curX + 20 < maxLineX {
                    let wh = UInt64(bitPattern: Int64(cardIdx * 31 + line * 17 + wordIdx * 13 + seed)) &* 6_364_136_223_846_793_005
                    let wordW = Int(14 + ((wh >> 24) % 44))
                    if curX + wordW > maxLineX { break }
                    let shade: CGFloat = line == 0 ? 0.14 : (0.28 + CGFloat((wh >> 16) % 30) / 100.0)
                    ctx.setFillColor(CGColor(gray: shade, alpha: 1))
                    ctx.fill(CGRect(x: CGFloat(curX), y: ly, width: CGFloat(wordW), height: line == 0 ? 11 : 8))
                    curX += wordW + Int(5 + ((wh >> 32) % 8))
                    wordIdx += 1
                }
            }
            yTop += cardH + cardGap
            cardIdx += 1
        }
        guard let image = ctx.makeImage() else { throw TestError("WebUI makeImage 失败") }
        return image
    }

    static func renderStickyBar(width: Int, height: Int, isHeader: Bool) throws -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            throw TestError("StickyBar CGContext 创建失败")
        }
        ctx.setFillColor(CGColor(srgbRed: isHeader ? 0.13 : 0.94, green: isHeader ? 0.16 : 0.95,
                                 blue: isHeader ? 0.22 : 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        // 装饰图标与导航按钮块
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.56, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 24, y: CGFloat(height / 2 - 12), width: 24, height: 24))
        for i in 0..<4 {
            ctx.setFillColor(CGColor(gray: isHeader ? 0.85 : 0.35, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(72 + i * 96), y: CGFloat(height / 2 - 6), width: 68, height: 12))
        }
        // 分隔线
        ctx.setFillColor(CGColor(gray: isHeader ? 0.35 : 0.78, alpha: 1))
        ctx.fill(CGRect(x: 0, y: isHeader ? 0 : CGFloat(height - 2), width: CGFloat(width), height: 2))
        guard let image = ctx.makeImage() else { throw TestError("StickyBar makeImage 失败") }
        return image
    }

    static func renderSidebar(width: Int, height: Int) throws -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            throw TestError("Sidebar CGContext 创建失败")
        }
        ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        for i in 0..<12 {
            let yTop = 84 + i * 48
            if yTop + 32 >= height { break }
            let cy = CGFloat(height - yTop - 32)
            ctx.setFillColor(CGColor(srgbRed: 0.22, green: 0.48, blue: 0.86, alpha: 1))
            ctx.fill(CGRect(x: 24, y: cy + 6, width: 20, height: 20))
            ctx.setFillColor(CGColor(gray: 0.20, alpha: 1))
            ctx.fill(CGRect(x: 56, y: cy + 10, width: CGFloat(140 + (i % 4) * 55), height: 12))
        }
        guard let image = ctx.makeImage() else { throw TestError("Sidebar makeImage 失败") }
        return image
    }

    /// 宽屏浅色 Notion/聊天页正文：左右各 ~28% 纯白留白，中间 44% 窄列轻细正文块
    static func renderWidescreenLightDocBody(width: Int, height: Int, seed: Int) throws -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            throw TestError("WidescreenDoc CGContext 创建失败")
        }
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let marginX = Int(Double(width) * 0.28)
        let colW = width - marginX * 2
        var yTop = 24
        var blockIdx = 0
        while yTop + 30 < height {
            // 浅色气泡/段落标题
            let hVal = UInt64(bitPattern: Int64(blockIdx)) &* 2_654_435_761 &+ UInt64(bitPattern: Int64(seed)) &* 40_503
            let isBubble = (blockIdx % 3 == 1)
            let blockH = isBubble ? 76 : 94
            if isBubble {
                let by = CGFloat(height - yTop - blockH)
                ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1))
                ctx.fill(CGRect(x: CGFloat(marginX + 28), y: by, width: CGFloat(colW - 56), height: CGFloat(blockH)))
            }
            let lines = isBubble ? 3 : 4
            for line in 0..<lines {
                let lineTop = yTop + 12 + line * 20
                guard lineTop + 8 < height else { break }
                let ly = CGFloat(height - lineTop - 8)
                var curX = marginX + (isBubble ? 42 : 8)
                let maxLineX = marginX + colW - (isBubble ? 42 : 8)
                var wordIdx = 0
                while curX + 16 < maxLineX {
                    let wh = UInt64(bitPattern: Int64(blockIdx * 43 + line * 19 + wordIdx * 11 + seed)) &* 6_364_136_223_846_793_005
                    let wordW = Int(12 + ((wh >> 24) % 38))
                    if curX + wordW > maxLineX { break }
                    let shade: CGFloat = line == 0 ? 0.18 : 0.38
                    ctx.setFillColor(CGColor(gray: shade, alpha: 1))
                    ctx.fill(CGRect(x: CGFloat(curX), y: ly, width: CGFloat(wordW), height: line == 0 ? 9 : 7))
                    curX += wordW + Int(5 + ((wh >> 32) % 7))
                    wordIdx += 1
                }
            }
            if (hVal % 5) == 0 && yTop + 50 < height {
                // 偶尔加一条细分割线
                ctx.setFillColor(CGColor(gray: 0.90, alpha: 1))
                ctx.fill(CGRect(x: CGFloat(marginX), y: CGFloat(height - yTop - blockH - 6), width: CGFloat(colW), height: 1))
            }
            yTop += blockH + 18
            blockIdx += 1
        }
        guard let img = ctx.makeImage() else { throw TestError("WidescreenDoc makeImage 失败") }
        return img
    }

    static func renderLightStickyHeader(width: Int, height: Int) throws -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            throw TestError("LightHeader CGContext 创建失败")
        }
        ctx.setFillColor(CGColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.setFillColor(CGColor(gray: 0.20, alpha: 1))
        ctx.fill(CGRect(x: 32, y: CGFloat(height / 2 - 7), width: 140, height: 14))
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.56, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(width - 112), y: CGFloat(height / 2 - 12), width: 80, height: 24))
        ctx.setFillColor(CGColor(gray: 0.88, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 1.5))
        guard let img = ctx.makeImage() else { throw TestError("LightHeader makeImage 失败") }
        return img
    }

    static func renderLightStickyInputFooter(width: Int, height: Int) throws -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            throw TestError("LightFooter CGContext 创建失败")
        }
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.setFillColor(CGColor(gray: 0.88, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(height - 1), width: CGFloat(width), height: 1))
        let boxX = Int(Double(width) * 0.28)
        let boxW = width - boxX * 2
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(boxX), y: 18, width: CGFloat(boxW), height: CGFloat(height - 36)))
        ctx.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: CGFloat(boxX), y: 18, width: CGFloat(boxW), height: CGFloat(height - 36)))
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.56, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(boxX + boxW - 44), y: 26, width: 32, height: CGFloat(height - 52)))
        guard let img = ctx.makeImage() else { throw TestError("LightFooter makeImage 失败") }
        return img
    }

    static func composeTruthStickyPage(
        width: Int, header: CGImage, body: CGImage, footer: CGImage
    ) throws -> CGImage {
        let totalH = header.height + body.height + footer.height
        guard let ctx = makeContext(width: width, height: totalH) else {
            throw TestError("TruthStickyPage CGContext 创建失败")
        }
        ctx.draw(header, in: CGRect(x: 0, y: totalH - header.height, width: width, height: header.height))
        ctx.draw(body, in: CGRect(x: 0, y: footer.height, width: width, height: body.height))
        ctx.draw(footer, in: CGRect(x: 0, y: 0, width: width, height: footer.height))
        guard let img = ctx.makeImage() else { throw TestError("TruthStickyPage makeImage 失败") }
        return img
    }

    static func composeStickyViewport(
        width: Int, viewportH: Int, header: CGImage, body: CGImage, bodyOffset: Int, footer: CGImage
    ) throws -> CGImage {
        let bodyH = viewportH - header.height - footer.height
        let bodySlice = try cropped(body, y: bodyOffset, height: bodyH, name: "bodySlice")
        guard let ctx = makeContext(width: width, height: viewportH) else {
            throw TestError("StickyViewport CGContext 创建失败")
        }
        ctx.draw(header, in: CGRect(x: 0, y: viewportH - header.height, width: width, height: header.height))
        ctx.draw(bodySlice, in: CGRect(x: 0, y: footer.height, width: width, height: bodyH))
        ctx.draw(footer, in: CGRect(x: 0, y: 0, width: width, height: footer.height))
        guard let img = ctx.makeImage() else { throw TestError("StickyViewport makeImage 失败") }
        return img
    }

    static func composeSidebarViewport(
        width: Int, viewportH: Int, header: CGImage, sidebar: CGImage,
        feed: CGImage, feedOffset: Int, sidebarW: Int
    ) throws -> CGImage {
        let bodyH = viewportH - header.height
        let feedSlice = try cropped(feed, y: feedOffset, height: bodyH, name: "feedSlice")
        guard let ctx = makeContext(width: width, height: viewportH) else {
            throw TestError("SidebarViewport CGContext 创建失败")
        }
        ctx.draw(sidebar, in: CGRect(x: 0, y: 0, width: sidebarW, height: viewportH))
        ctx.draw(feedSlice, in: CGRect(x: sidebarW, y: 0, width: width - sidebarW, height: bodyH))
        ctx.draw(header, in: CGRect(x: 0, y: viewportH - header.height, width: width, height: header.height))
        guard let img = ctx.makeImage() else { throw TestError("SidebarViewport makeImage 失败") }
        return img
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func cropped(_ image: CGImage, y: Int, height: Int, name: String) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)),
              cropped.width > 0, cropped.height > 0 else {
            throw TestError("裁剪 \(name) 失败 (y=\(y), h=\(height))")
        }
        return cropped
    }

    // MARK: - 校验

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

    static func verifyRegionExact(
        _ stitched: CGImage, against truth: CGImage, startRow: Int, endRow: Int, label: String
    ) throws {
        let a = PixelBuffer(cgImage: stitched)
        let b = PixelBuffer(cgImage: truth)
        let step = max(1, (endRow - startRow) / 25)
        var checked = 0
        var row = startRow
        while row < endRow {
            guard row < a.height, row < b.height else {
                throw TestError("\(label): 行 \(row) 越界 (stitched=\(a.height), truth=\(b.height))")
            }
            let maxDiff = zip(a.signature[row], b.signature[row]).map { max($0, $1) - min($0, $1) }.max() ?? 0
            guard maxDiff <= 2 else {
                throw TestError("\(label): 第 \(row) 行不匹配 (maxDiff=\(maxDiff))")
            }
            checked += 1
            row += step
        }
        print("[TestStitch] \(label) OK（校验 \(checked) 行 [\(startRow)..<\(endRow)]）")
    }

    static func assertEquals<T: Equatable & CustomStringConvertible>(
        _ actual: T, _ expected: T, _ label: String
    ) throws {
        guard actual == expected else {
            throw TestError("\(label): 实际 \(actual) ≠ 期望 \(expected)")
        }
        print("[TestStitch] \(label) = \(actual) ✓")
    }

    static func assertClose(_ actual: Int, _ expected: Int, tolerance: Int, label: String) throws {
        guard abs(actual - expected) <= tolerance else {
            throw TestError("\(label): 实际 \(actual) ≠ 期望 \(expected) ± \(tolerance)")
        }
        print("[TestStitch] \(label) = \(actual) (期望 \(expected) ± \(tolerance)) ✓")
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
