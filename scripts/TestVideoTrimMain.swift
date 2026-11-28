import CoreGraphics
import Foundation

/// 录屏头尾裁剪的纯 Core 验证入口（不依赖 App / AppKit / AVFoundation）。
/// 由 scripts/test-video-trim.sh 编译运行：
/// RecordingModel.swift + 本文件。
///
/// 覆盖：`full(duration:)` 整段语义 / 起止越界钳制 / 总长小于 minSpan 的退化 /
/// 起止重合时 minSpan 保底 / `isTrimmed` 的 0.05s 噪声阈值 / 归一化分数退化（总长 0）/
/// `updatingStartFraction` 与 `updatingEndFraction` 互不越界 / `clampingTime` /
/// `trimmedDuration` / `RecordingGeometry.formatPreciseTime`。
@main
struct TestVideoTrimMain {

    // MARK: - 入口

    static func main() {
        do {
            try test1FullCoversWholeClip()
            try test2OutOfBoundsInitIsClamped()
            try test3CollapsedRangeKeepsMinSpan()
            try test4TotalShorterThanMinSpanDegradesToFull()
            try test5IsTrimmedNoiseThreshold()
            try test6FractionMathAndZeroDurationFallback()
            try test7UpdatingStartFractionRespectsEnd()
            try test8UpdatingEndFractionRespectsStart()
            try test9ClampingTime()
            try test10TrimmedDuration()
            try test11InvalidNumbersAreSanitized()
            try test12FormatPreciseTime()
            try test13GIFConversionGuardAndAdaptiveSlimming()
            print("[TestVideoTrim] ALL PASS ✅")
        } catch {
            print("[TestVideoTrim] FAILED ❌: \(error)")
            exit(1)
        }
    }

    // MARK: - 场景 1：`full(duration:)` 整段语义

    static func test1FullCoversWholeClip() throws {
        print("[TestVideoTrim] 场景1: full(duration:) 整段保留")

        let range = VideoTrimRange.full(duration: 10)
        try expectApprox(range.start, 0, "整段起点为 0")
        try expectApprox(range.end, 10, "整段终点等于总长")
        try expectApprox(range.totalDuration, 10, "总长透传")
        try expectApprox(range.trimmedDuration, 10, "保留时长等于总长")
        try expectApprox(range.startFraction, 0, "起点分数为 0")
        try expectApprox(range.endFraction, 1, "终点分数为 1")
        try expectTrue(!range.isTrimmed, "整段不算已裁剪")

        // 0 时长的退化：也不能崩，分数退回 0 / 1
        let zero = VideoTrimRange.full(duration: 0)
        try expectApprox(zero.start, 0, "0 时长起点")
        try expectApprox(zero.end, 0, "0 时长终点")
        try expectApprox(zero.startFraction, 0, "0 时长起点分数")
        try expectApprox(zero.endFraction, 1, "0 时长终点分数")
        try expectTrue(!zero.isTrimmed, "0 时长不算已裁剪")
    }

    // MARK: - 场景 2：起止越界钳制

    static func test2OutOfBoundsInitIsClamped() throws {
        print("[TestVideoTrim] 场景2: 越界起止被钳制")

        // 负数起点 + 超出片尾的终点
        let wide = VideoTrimRange(start: -5, end: 99, totalDuration: 10)
        try expectApprox(wide.start, 0, "负起点钳到 0")
        try expectApprox(wide.end, 10, "超片尾终点钳到总长")

        // 起点越界到片尾附近：最多只能留 minSpan
        let late = VideoTrimRange(start: 99, end: 99, totalDuration: 10)
        try expectApprox(late.start, 10 - VideoTrimRange.minSpan, "起点钳到 total - minSpan")
        try expectApprox(late.end, 10, "终点钳到片尾")
        try expectApprox(late.trimmedDuration, VideoTrimRange.minSpan, "保留时长恰为 minSpan")

        // 终点跑到起点前面：被抬到起点 + minSpan
        let inverted = VideoTrimRange(start: 4, end: 1, totalDuration: 10)
        try expectApprox(inverted.start, 4, "起点保持")
        try expectApprox(inverted.end, 4 + VideoTrimRange.minSpan, "终点抬到 start + minSpan")
    }

    // MARK: - 场景 3：起止重合时的 minSpan 保底（总长大于 minSpan）

    static func test3CollapsedRangeKeepsMinSpan() throws {
        print("[TestVideoTrim] 场景3: 起止重合不产出 0 帧区间")

        let collapsed = VideoTrimRange(start: 5, end: 5, totalDuration: 10)
        try expectApprox(collapsed.start, 5, "起点保持")
        try expectApprox(collapsed.end, 5 + VideoTrimRange.minSpan, "终点补足 minSpan")
        try expectTrue(collapsed.trimmedDuration >= VideoTrimRange.minSpan, "保留时长不低于 minSpan")

        // 拖柄越过对方后仍然合法
        let crossed = VideoTrimRange(start: 6, end: 5.1, totalDuration: 10)
        try expectTrue(crossed.end - crossed.start >= VideoTrimRange.minSpan, "跨越后仍保有 minSpan")
        try expectApprox(crossed.end, 6.25, "终点被抬到 start + minSpan")
    }

    // MARK: - 场景 4：总长本身小于 minSpan

    static func test4TotalShorterThanMinSpanDegradesToFull() throws {
        print("[TestVideoTrim] 场景4: 极短片不给裁（整段保留）")

        let tiny = VideoTrimRange(start: 0.05, end: 0.2, totalDuration: 0.2)
        try expectApprox(tiny.start, 0, "极短片起点归 0")
        try expectApprox(tiny.end, 0.2, "极短片终点为总长")
        try expectApprox(tiny.trimmedDuration, 0.2, "极短片保留完整时长")
        try expectTrue(!tiny.isTrimmed, "极短片不标记已裁剪")

        // 恰好等于 minSpan 也算「不够裁」（<= 分支）
        let edge = VideoTrimRange(start: 0, end: VideoTrimRange.minSpan, totalDuration: VideoTrimRange.minSpan)
        try expectApprox(edge.start, 0, "等于 minSpan 时起点 0")
        try expectApprox(edge.end, VideoTrimRange.minSpan, "等于 minSpan 时终点为总长")
        try expectTrue(!edge.isTrimmed, "等于 minSpan 时不算已裁剪")

        // 拖柄动作不该把极短片搞坏
        let stretched = tiny.updatingStartFraction(0.9)
        try expectApprox(stretched.start, 0, "极短片拖左柄仍是整段")
        try expectApprox(stretched.end, 0.2, "极短片拖左柄终点不变")
    }

    // MARK: - 场景 5：isTrimmed 的 0.05s 噪声阈值

    static func test5IsTrimmedNoiseThreshold() throws {
        print("[TestVideoTrim] 场景5: isTrimmed 阈值")

        let noiseStart = VideoTrimRange(start: 0.04, end: 10, totalDuration: 10)
        try expectTrue(!noiseStart.isTrimmed, "起点 0.04s 视为噪声，不算裁剪")

        let realStart = VideoTrimRange(start: 0.06, end: 10, totalDuration: 10)
        try expectTrue(realStart.isTrimmed, "起点 0.06s 视为已裁剪")

        let noiseEnd = VideoTrimRange(start: 0, end: 9.96, totalDuration: 10)
        try expectTrue(!noiseEnd.isTrimmed, "尾部 0.04s 视为噪声")

        let realEnd = VideoTrimRange(start: 0, end: 9.94, totalDuration: 10)
        try expectTrue(realEnd.isTrimmed, "尾部 0.06s 视为已裁剪")

        // 总长不超 minSpan 时永远不算裁剪（没有可裁空间）
        let tiny = VideoTrimRange(start: 0, end: 0.2, totalDuration: 0.2)
        try expectTrue(!tiny.isTrimmed, "极短片永不标记裁剪")
    }

    // MARK: - 场景 6：归一化分数与总长 0 退化

    static func test6FractionMathAndZeroDurationFallback() throws {
        print("[TestVideoTrim] 场景6: startFraction / endFraction")

        let range = VideoTrimRange(start: 2.5, end: 7.5, totalDuration: 10)
        try expectApprox(range.startFraction, 0.25, "起点分数")
        try expectApprox(range.endFraction, 0.75, "终点分数")

        // 总长 0：分数退回 0 / 1，不出现 NaN
        let zero = VideoTrimRange(start: 1, end: 2, totalDuration: 0)
        try expectApprox(zero.startFraction, 0, "总长 0 时起点分数 0")
        try expectApprox(zero.endFraction, 1, "总长 0 时终点分数 1")
        try expectTrue(!zero.startFraction.isNaN, "起点分数不是 NaN")
        try expectTrue(!zero.endFraction.isNaN, "终点分数不是 NaN")
    }

    // MARK: - 场景 7：拖左柄不越过右柄

    static func test7UpdatingStartFractionRespectsEnd() throws {
        print("[TestVideoTrim] 场景7: updatingStartFraction")

        let range = VideoTrimRange.full(duration: 10)

        let half = range.updatingStartFraction(0.5)
        try expectApprox(half.start, 5, "拖到 50% 起点为 5")
        try expectApprox(half.end, 10, "右柄保持不动")

        let pinned = range.updatingStartFraction(0.99)
        try expectApprox(pinned.start, 10 - VideoTrimRange.minSpan, "左柄最多到 end - minSpan")
        try expectApprox(pinned.end, 10, "右柄仍不动")
        try expectTrue(pinned.trimmedDuration >= VideoTrimRange.minSpan, "保留时长不低于 minSpan")

        let negative = range.updatingStartFraction(-3)
        try expectApprox(negative.start, 0, "负分数钳到 0")

        let overflow = range.updatingStartFraction(7)
        try expectApprox(overflow.start, 10 - VideoTrimRange.minSpan, "超 1 的分数钳到上限")

        // 已有裁剪的区间再拖左柄：右柄仍是原右柄
        let trimmed = VideoTrimRange(start: 1, end: 4, totalDuration: 10)
        let moved = trimmed.updatingStartFraction(0.3)
        try expectApprox(moved.start, 3, "新起点 3")
        try expectApprox(moved.end, 4, "右柄保持 4")
    }

    // MARK: - 场景 8：拖右柄不越过左柄

    static func test8UpdatingEndFractionRespectsStart() throws {
        print("[TestVideoTrim] 场景8: updatingEndFraction")

        let range = VideoTrimRange.full(duration: 10)

        let half = range.updatingEndFraction(0.4)
        try expectApprox(half.end, 4, "拖到 40% 终点为 4")
        try expectApprox(half.start, 0, "左柄保持不动")

        let pinned = range.updatingEndFraction(0)
        try expectApprox(pinned.end, VideoTrimRange.minSpan, "右柄最少停在 start + minSpan")
        try expectApprox(pinned.start, 0, "左柄仍不动")
        try expectTrue(pinned.trimmedDuration >= VideoTrimRange.minSpan, "保留时长不低于 minSpan")

        let overflow = range.updatingEndFraction(9)
        try expectApprox(overflow.end, 10, "超 1 的分数钳到片尾")

        // 已有裁剪的区间再拖右柄：左柄保留
        let trimmed = VideoTrimRange(start: 8, end: 10, totalDuration: 10)
        let pulledBack = trimmed.updatingEndFraction(0.5)
        try expectApprox(pulledBack.start, 8, "左柄保持 8")
        try expectApprox(pulledBack.end, 8 + VideoTrimRange.minSpan, "右柄被顶到 start + minSpan")
    }

    // MARK: - 场景 9：clampingTime

    static func test9ClampingTime() throws {
        print("[TestVideoTrim] 场景9: clampingTime")

        let range = VideoTrimRange(start: 2, end: 5, totalDuration: 10)
        try expectApprox(range.clampingTime(0), 2, "早于起点钳到起点")
        try expectApprox(range.clampingTime(3.5), 3.5, "区间内原样返回")
        try expectApprox(range.clampingTime(9), 5, "晚于终点钳到终点")
        try expectApprox(range.clampingTime(2), 2, "等于起点保持")
        try expectApprox(range.clampingTime(5), 5, "等于终点保持")
        try expectApprox(range.clampingTime(-0.0), 2, "0 钳到起点")
    }

    // MARK: - 场景 10：trimmedDuration

    static func test10TrimmedDuration() throws {
        print("[TestVideoTrim] 场景10: trimmedDuration")

        try expectApprox(VideoTrimRange(start: 1, end: 4.5, totalDuration: 10).trimmedDuration, 3.5, "常规保留时长")
        try expectApprox(VideoTrimRange.full(duration: 3).trimmedDuration, 3, "整段保留时长")
        try expectApprox(VideoTrimRange.full(duration: 0).trimmedDuration, 0, "0 时长保留 0")
    }

    // MARK: - 场景 11：NaN / 无穷 输入不污染模型

    static func test11InvalidNumbersAreSanitized() throws {
        print("[TestVideoTrim] 场景11: 非法数值兜底")

        let nan = VideoTrimRange(start: .nan, end: .nan, totalDuration: .nan)
        try expectApprox(nan.totalDuration, 0, "NaN 总长归 0")
        try expectApprox(nan.start, 0, "NaN 起点归 0")
        try expectApprox(nan.end, 0, "NaN 终点归 0")

        // 无穷时长统一归 0（sanitized 只留有限正值），构造出的是安全退化区间
        let infinite = VideoTrimRange(start: .infinity, end: -(.infinity), totalDuration: .infinity)
        try expectApprox(infinite.totalDuration, 0, "无穷总长归 0")
        try expectApprox(infinite.start, 0, "无穷入参起点归 0")
        try expectApprox(infinite.end, 0, "无穷入参终点归 0")

        let nanFraction = VideoTrimRange.full(duration: 10).updatingStartFraction(.nan)
        try expectApprox(nanFraction.start, 0, "NaN 分数按下限处理")
        try expectApprox(nanFraction.end, 10, "NaN 分数不影响右柄")

        let nanTime = VideoTrimRange(start: 2, end: 5, totalDuration: 10).clampingTime(.nan)
        try expectTrue(nanTime.isFinite, "NaN 时间钳成有限值")
        try expectApprox(nanTime, 2, "NaN 时间按下限处理")
    }

    // MARK: - 场景 12：formatPreciseTime

    static func test12FormatPreciseTime() throws {
        print("[TestVideoTrim] 场景12: RecordingGeometry.formatPreciseTime")

        try expectEqual(RecordingGeometry.formatPreciseTime(0), "00:00.0", "零点")
        try expectEqual(RecordingGeometry.formatPreciseTime(4.3), "00:04.3", "4.3 秒")
        try expectEqual(RecordingGeometry.formatPreciseTime(4.34), "00:04.3", "4.34 秒取整到 0.1 秒")
        try expectEqual(RecordingGeometry.formatPreciseTime(59.9), "00:59.9", "59.9 秒不进位")
        try expectEqual(RecordingGeometry.formatPreciseTime(60), "01:00.0", "整分钟")
        try expectEqual(RecordingGeometry.formatPreciseTime(65.5), "01:05.5", "1 分 5.5 秒")
        try expectEqual(RecordingGeometry.formatPreciseTime(125.0), "02:05.0", "2 分 5 秒")
        try expectEqual(RecordingGeometry.formatPreciseTime(-3), "00:00.0", "负值归零")
        try expectEqual(RecordingGeometry.formatPreciseTime(.nan), "00:00.0", "NaN 归零")

        // 与整秒读数互补：formatDuration 只看整秒
        try expectEqual(RecordingGeometry.formatDuration(59.9), "00:59", "整秒读数不进位")
    }

    // MARK: - 场景 13：GIF 60s 硬上限与 20–60s 自动瘦身策略

    static func test13GIFConversionGuardAndAdaptiveSlimming() throws {
        print("[TestVideoTrim] 场景13: GIF 60s 硬上限与 20–60s 自适应瘦身")

        let base = GIFConversionOptions(fps: 15, maxDimension: 960)

        let short = base.resolved(forDuration: 15)
        try expectEqual(short, GIFConversionOptions(fps: 15, maxDimension: 960), "≤20s 保持用户画质与帧率")

        let medium = base.resolved(forDuration: 30)
        try expectEqual(medium, GIFConversionOptions(fps: 10, maxDimension: 720), "20–40s 自动降到 10fps / 720px")

        let long = base.resolved(forDuration: 55)
        try expectEqual(long, GIFConversionOptions(fps: 8, maxDimension: 720), "40–60s 自动降到 8fps / 720px")

        let atCap = base.resolved(forDuration: 60.0)
        try expectEqual(atCap, GIFConversionOptions(fps: 8, maxDimension: 720), "恰好 60s 允许转换")

        let overCap = base.resolved(forDuration: 61.0)
        try expectTrue(overCap == nil, "超过 60s 返回 nil 拦截")

        let invalid = base.resolved(forDuration: 0)
        try expectTrue(invalid == nil, "0 秒返回 nil")
    }

    // MARK: - 断言工具

    enum Failure: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static func expectTrue(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.message("\(label)：期望 true，实际 false") }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else { throw Failure.message("\(label)：期望 \(expected)，实际 \(actual)") }
    }

    static func expectApprox(
        _ actual: Double,
        _ expected: Double,
        _ label: String,
        accuracy: Double = 0.0001
    ) throws {
        guard abs(actual - expected) <= accuracy else {
            throw Failure.message("\(label)：期望 \(expected)（±\(accuracy)），实际 \(actual)")
        }
    }
}
