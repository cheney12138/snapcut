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
