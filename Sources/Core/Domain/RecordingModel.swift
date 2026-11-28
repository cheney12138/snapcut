import CoreGraphics
import Foundation

/// 录屏输出格式
public enum RecordingFormat: String, Codable, Sendable, CaseIterable {
    case mp4
    case gif

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .gif: return "GIF"
        }
    }
}

/// 录制会话偏好与运行参数（纯领域模型，支持持久化记忆）
public struct RecordingOptions: Equatable, Codable, Sendable {
    public var format: RecordingFormat
    public var mp4FPS: Int
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var showCursor: Bool
    public var gifFPS: Int
    public var gifScale1x: Bool

    public var effectiveFPS: Int {
        switch format {
        case .mp4: return [30, 60].contains(mp4FPS) ? mp4FPS : 60
        case .gif: return min(24, max(10, gifFPS))
        }
    }

    public init(
        format: RecordingFormat = .mp4,
        mp4FPS: Int = 60,
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = false,
        showCursor: Bool = true,
        gifFPS: Int = 15,
        gifScale1x: Bool = true
    ) {
        self.format = format
        self.mp4FPS = mp4FPS
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.showCursor = showCursor
        self.gifFPS = gifFPS
        self.gifScale1x = gifScale1x
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decodeIfPresent(RecordingFormat.self, forKey: .format)) ?? .mp4
        mp4FPS = (try? c.decodeIfPresent(Int.self, forKey: .mp4FPS)) ?? 60
        captureSystemAudio = (try? c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio)) ?? true
        captureMicrophone = (try? c.decodeIfPresent(Bool.self, forKey: .captureMicrophone)) ?? false
        showCursor = (try? c.decodeIfPresent(Bool.self, forKey: .showCursor)) ?? true
        gifFPS = (try? c.decodeIfPresent(Int.self, forKey: .gifFPS)) ?? 15
        gifScale1x = (try? c.decodeIfPresent(Bool.self, forKey: .gifScale1x)) ?? true
    }
}

/// 录制阶段状态机
public enum RecordingPhase: Equatable, Sendable {
    case preparing
    case recording(elapsed: TimeInterval)
    case paused(elapsed: TimeInterval)
    case finalizing
}

/// 单次录制完成的输出产物描述
public struct RecordingResult: Sendable {
    public let format: RecordingFormat
    public let fileURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    public let fileSizeBytes: Int64
    public let frameCount: Int
    public let thumbnail: CGImage?
    public let isTemporaryFile: Bool

    public init(
        format: RecordingFormat,
        fileURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval,
        fileSizeBytes: Int64,
        frameCount: Int = 0,
        thumbnail: CGImage?,
        isTemporaryFile: Bool = false
    ) {
        self.format = format
        self.fileURL = fileURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.frameCount = frameCount
        self.thumbnail = thumbnail
        self.isTemporaryFile = isTemporaryFile
    }

    public var formattedDuration: String {
        RecordingGeometry.formatDuration(duration)
    }

    public var formattedSize: String {
        RecordingGeometry.formatBytes(fileSizeBytes)
    }
}

/// 视频头尾裁剪区间（纯领域值类型：自动合法化边界与最小时长保护）
///
/// 领域只表达「保留哪一段」，不感知 AVFoundation 的 CMTimeRange——
/// 换算成 `CMTimeRange` 由适配器负责（外圈才知道导出会话）。
/// 构造即合法化是刻意的：拖柄、键盘微调、程序化重置都走同一个入口，
/// 让「起点越界 / 两端重合产出 0 帧坏文件」这类状态在类型层面不可表示。
public struct VideoTrimRange: Equatable, Sendable {
    /// 裁剪区间最小保留时长（秒），防止左右柄重合产出 0 帧坏文件
    public static let minSpan: TimeInterval = 0.25

    public let start: TimeInterval
    public let end: TimeInterval
    public let totalDuration: TimeInterval

    public init(start: TimeInterval, end: TimeInterval, totalDuration: TimeInterval) {
        let safeTotal = Self.sanitized(totalDuration)
        self.totalDuration = safeTotal
        if safeTotal <= Self.minSpan {
            // 太短的片子不给裁：整段保留（此时没有可用的合法窗口）
            self.start = 0
            self.end = safeTotal
        } else {
            let safeStart = min(max(0, Self.sanitized(start)), safeTotal - Self.minSpan)
            let safeEnd = min(max(safeStart + Self.minSpan, Self.sanitized(end)), safeTotal)
            self.start = safeStart
            self.end = safeEnd
        }
    }

    /// 整段保留
    public static func full(duration: TimeInterval) -> VideoTrimRange {
        VideoTrimRange(start: 0, end: duration, totalDuration: duration)
    }

    public var trimmedDuration: TimeInterval { max(0, end - start) }

    /// 起点在整段中的归一化位置（0...1）
    public var startFraction: Double {
        guard totalDuration > 0 else { return 0 }
        return min(1, max(0, start / totalDuration))
    }

    /// 终点在整段中的归一化位置（0...1）
    public var endFraction: Double {
        guard totalDuration > 0 else { return 1 }
        return min(1, max(0, end / totalDuration))
    }

    /// 只要起点 > 0.05s 或终点距片尾 > 0.05s 且总长 > minSpan 即视为已裁剪
    /// （0.05s 是「拖了一点点」的噪声阈值，避免手指抖动就打出裁剪标记）
    public var isTrimmed: Bool {
        guard totalDuration > Self.minSpan else { return false }
        return start > 0.05 || (totalDuration - end) > 0.05
    }

    /// 拖动左柄：保持右柄不动，新起点不得吃掉 minSpan
    public func updatingStartFraction(_ fraction: Double) -> VideoTrimRange {
        let target = Self.clampFraction(fraction) * totalDuration
        let newStart = max(0, min(target, end - Self.minSpan))
        return VideoTrimRange(start: newStart, end: end, totalDuration: totalDuration)
    }

    /// 拖动右柄：保持左柄不动，新终点不得吃掉 minSpan
    public func updatingEndFraction(_ fraction: Double) -> VideoTrimRange {
        let target = Self.clampFraction(fraction) * totalDuration
        let newEnd = min(totalDuration, max(target, start + Self.minSpan))
        return VideoTrimRange(start: start, end: newEnd, totalDuration: totalDuration)
    }

    /// 把任意时间点收进裁剪区间（播放头 / 时间戳回显用）
    public func clampingTime(_ time: TimeInterval) -> TimeInterval {
        let safe = Self.sanitized(time)
        return min(max(safe, start), end)
    }

    private static func clampFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }

    /// NaN / 无穷 / 负数统一压成 0（时间值来自 AVFoundation，可能给出 NaN）
    private static func sanitized(_ value: TimeInterval) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}

/// MP4 → GIF 的转换参数（纯领域值：不泄漏 AVFoundation / ImageIO 类型）
public struct GIFConversionOptions: Equatable, Sendable {
    /// 目标帧率（适配器会再收到 8...24 区间内）
    public var fps: Int
    /// 最长边像素上限（等比缩放，防 4K 视频产出几十 MB 的 GIF）
    public var maxDimension: Int

    /// 单次转 GIF 的最长允许时长（硬上限 60 秒；超出提示用户先裁剪片段）
    public static let maxDurationSeconds: TimeInterval = 60

    /// 时长宽容度（避免恰好录到 60.02s 被边界抖动拒之门外）
    public static let durationToleranceSeconds: TimeInterval = 0.05

    /// 超过该时长（秒）后自动启动温和瘦身，保证 1 分钟 GIF 也能控在聊天工具可发送体积内
    public static let adaptiveSlimThresholdSeconds: TimeInterval = 20

    public init(fps: Int = 15, maxDimension: Int = 960) {
        self.fps = fps
        self.maxDimension = maxDimension
    }

    /// 按待转换片段时长解析生效参数：
    /// - 超过 60s 硬上限 → 返回 `nil`（调用方拦截并引导先裁剪）；
    /// - `≤ 20s` → 保持用户设定（fps 钳制在 8...24）；
    /// - `20s < d ≤ 40s` → 温和收紧至 `fps ≤ 10`、`maxDimension ≤ 720`；
    /// - `40s < d ≤ 60s` → 进一步收紧至 `fps ≤ 8`、`maxDimension ≤ 720`。
    public func resolved(forDuration duration: TimeInterval) -> GIFConversionOptions? {
        guard duration.isFinite, duration > 0 else { return nil }
        guard duration <= Self.maxDurationSeconds + Self.durationToleranceSeconds else { return nil }
        let baseFPS = min(24, max(8, fps))
        let baseMaxDim = max(64, maxDimension)
        if duration <= Self.adaptiveSlimThresholdSeconds {
            return GIFConversionOptions(fps: baseFPS, maxDimension: baseMaxDim)
        }
        let slimFPS = duration > 40 ? min(baseFPS, 8) : min(baseFPS, 10)
        let slimMaxDim = min(baseMaxDim, 720)
        return GIFConversionOptions(fps: slimFPS, maxDimension: slimMaxDim)
    }
}

/// 录制几何与格式化纯函数
public enum RecordingGeometry {
    /// 视频编码（H.264/HEVC）要求像素宽高为偶数且不低于最小值，避免出现绿边或初始化失败
    public static func targetPixelSize(
        regionPoints: CGSize,
        backingScale: CGFloat,
        options: RecordingOptions
    ) -> (width: Int, height: Int) {
        let scale = max(1, backingScale)
        let rawW = max(16, Int((regionPoints.width * scale).rounded()))
        let rawH = max(16, Int((regionPoints.height * scale).rounded()))
        switch options.format {
        case .mp4:
            return (evenDown(rawW, min: 16), evenDown(rawH, min: 16))
        case .gif:
            if options.gifScale1x {
                let w = max(16, Int(regionPoints.width.rounded()))
                let h = max(16, Int(regionPoints.height.rounded()))
                return (evenDown(w, min: 16), evenDown(h, min: 16))
            }
            return (evenDown(rawW, min: 16), evenDown(rawH, min: 16))
        }
    }

    private static func evenDown(_ value: Int, min minValue: Int) -> Int {
        let clamped = max(minValue, value)
        return clamped - (clamped % 2)
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    /// 精确到 0.1 秒的时间读数（裁剪区用，`"mm:ss.d"`，如 `"00:04.3"`）
    ///
    /// 为什么不复用 `formatDuration`：裁剪要看见「拖动了 0.3 秒」，
    /// 整秒读数会让左右柄看起来没反应。
    /// 取整到最近的 0.1 秒（而非向下截断）：时间值多是二进制浮点近似，
    /// 向下截断会把 12.3 显示成 12.2 这种「少一格」的错觉。
    public static func formatPreciseTime(_ seconds: TimeInterval) -> String {
        let safe = (seconds.isFinite && seconds > 0) ? seconds : 0
        let totalTenths = Int((safe * 10).rounded())
        let mins = totalTenths / 600
        let secs = (totalTenths % 600) / 10
        let tenths = totalTenths % 10
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let b = max(0, bytes)
        if b < 1024 {
            return "\(b) B"
        } else if b < 1024 * 1024 {
            return String(format: "%.0f KB", Double(b) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(b) / (1024.0 * 1024.0))
        }
    }
}
