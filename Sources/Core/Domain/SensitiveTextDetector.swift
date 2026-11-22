import CoreGraphics
import Foundation

/// 敏感信息类别（纯 Core 领域模型，零 AppKit / Vision 依赖）
public enum SensitiveKind: String, Sendable, Equatable, CaseIterable {
    case email
    case phone
    case apiKey
    case jwt
    case urlSecret
    case ipAddress
    case idCard
}

/// 单行文本中的敏感片段匹配结果（字符区间 + 类别）
public struct SensitiveRangeMatch: Sendable, Equatable {
    public let kind: SensitiveKind
    public let range: Range<String.Index>

    public init(kind: SensitiveKind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}

/// 图像中检测到的敏感区域（归一化坐标 [0, 1]，原点左上 Y-down）
public struct DetectedSensitiveRegion: Sendable, Equatable {
    public let kind: SensitiveKind
    public let normalizedRect: CGRect

    public init(kind: SensitiveKind, normalizedRect: CGRect) {
        self.kind = kind
        self.normalizedRect = normalizedRect
    }
}

/// 本地敏感信息正则识别与坐标换算引擎（纯 Core，100% 离线，可独立单测）。
///
/// 设计原则：
/// - 宁缺毋滥：对高风险敏感凭证（邮箱、手机号、API Key/Token、JWT、URL/配置密钥值、内网/公网 IP、身份证号）
///   精准定位到「值本身」（例如 `api_key=abc12345` 只打码 `abc12345`，保留左侧字段名语义）；
/// - 重叠区间自动合并去重，避免同一处文本叠加多层马赛克；
/// - 跳过常见无害示例（如 `127.0.0.1`、`0.0.0.0`、`@MainActor`）。
public enum SensitiveTextDetector {
    private struct Rule {
        let kind: SensitiveKind
        let regex: NSRegularExpression
        /// 捕获组索引（0 = 全匹配；>0 = 仅脱敏值部分，保留键名上下文）
        let targetGroup: Int
    }

    private static let rules: [Rule] = {
        let defs: [(SensitiveKind, String, Int)] = [
            // 1. JWT 三段式 Token
            (.jwt, #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, 0),
            // 2. 常见平台 API Key / Access Key / Bot Token（OpenAI / Anthropic / Google / GitHub / AWS / Slack / 阿里云 / 腾讯云）
            (.apiKey, #"(?:sk-ant-[A-Za-z0-9_-]{14,}|sk-proj-[A-Za-z0-9_-]{14,}|sk-[A-Za-z0-9_-]{18,}|AIza[0-9A-Za-z_-]{28,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[0-9A-Za-z-]{16,}|LTAI[0-9A-Za-z]{12,}|AKID[0-9A-Za-z]{20,})"#, 0),
            // 3. Authorization Bearer Token（仅打码 Token 本体，保留 "Bearer "）
            (.apiKey, #"(?i)\bBearer\s+([A-Za-z0-9._~+/=-]{16,})"#, 1),
            // 4. URL 参数或配置文件中的密钥值（仅打码等号/冒号后的值，保留字段名）
            (.urlSecret, #"(?i)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|app[_-]?secret|auth[_-]?token|secret[_-]?key|password|passwd|pwd|private[_-]?key)\s*[:=]\s*["']?([^\s"'&,;<>]{6,})"#, 1),
            // 5. 电子邮箱
            (.email, #"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#, 0),
            // 6. 中国大陆 18 位身份证号
            (.idCard, #"(?<!\d)[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx](?!\d)"#, 0),
            // 7. 手机号（中国大陆 11 位，允许 3-4-4 空格/连字符分隔；以及 +国际区号手机号）
            (.phone, #"(?<!\d)1[3-9]\d[\s-]?\d{4}[\s-]?\d{4}(?!\d)"#, 0),
            (.phone, #"(?<!\d)\+\d{1,3}[\s-]?\d{2,4}[\s-]?\d{3,4}[\s-]?\d{3,4}(?!\d)"#, 0),
            // 8. IPv4 地址（后置过滤排除 127.0.0.1 / 0.0.0.0）
            (.ipAddress, #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#, 0),
        ]
        return defs.compactMap { kind, pattern, group in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return Rule(kind: kind, regex: regex, targetGroup: group)
        }
    }()

    /// 在单行识别文本中找出所有不重叠的敏感字符区间（按出现顺序排列）
    public static func detectRanges(in text: String) -> [SensitiveRangeMatch] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var rawMatches: [(kind: SensitiveKind, nsRange: NSRange)] = []

        for rule in rules {
            let hits = rule.regex.matches(in: text, options: [], range: fullRange)
            for hit in hits {
                let target = rule.targetGroup < hit.numberOfRanges ? hit.range(at: rule.targetGroup) : hit.range
                guard target.location != NSNotFound, target.length > 0 else { continue }
                let snippet = nsText.substring(with: target)
                if shouldIgnore(kind: rule.kind, snippet: snippet) { continue }
                rawMatches.append((rule.kind, target))
            }
        }

        guard !rawMatches.isEmpty else { return [] }

        // 按起点升序、长度降序排序并合并重叠区间（例如 token=eyJ... 同时命中 urlSecret 和 jwt）
        rawMatches.sort { a, b in
            if a.nsRange.location != b.nsRange.location {
                return a.nsRange.location < b.nsRange.location
            }
            return a.nsRange.length > b.nsRange.length
        }

        var merged: [(kind: SensitiveKind, nsRange: NSRange)] = []
        for item in rawMatches {
            if var last = merged.last {
                let lastEnd = last.nsRange.location + last.nsRange.length
                let itemEnd = item.nsRange.location + item.nsRange.length
                if item.nsRange.location < lastEnd {
                    let unionEnd = max(lastEnd, itemEnd)
                    last.nsRange = NSRange(location: last.nsRange.location, length: unionEnd - last.nsRange.location)
                    merged[merged.count - 1] = last
                    continue
                }
            }
            merged.append(item)
        }

        return merged.compactMap { item in
            guard let swiftRange = Range(item.nsRange, in: text) else { return nil }
            return SensitiveRangeMatch(kind: item.kind, range: swiftRange)
        }
    }

    /// 归一化坐标（[0,1]，Y-down）→ 选区本地点坐标，带轻微安全留白并夹取在画布内
    public static func localRect(
        fromNormalizedTopLeft normalized: CGRect,
        canvasSize: CGSize,
        padX: CGFloat = 3,
        padY: CGFloat = 2
    ) -> CGRect {
        let raw = CGRect(
            x: normalized.minX * canvasSize.width - padX,
            y: normalized.minY * canvasSize.height - padY,
            width: normalized.width * canvasSize.width + padX * 2,
            height: normalized.height * canvasSize.height + padY * 2
        )
        let canvas = CGRect(origin: .zero, size: canvasSize)
        return raw.intersection(canvas)
    }

    /// 计算两个矩形相对较小一方的重叠比例（用于防重复叠打同一处马赛克）
    public static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let minArea = min(a.width * a.height, b.width * b.height)
        guard minArea > 0 else { return 0 }
        return (inter.width * inter.height) / minArea
    }

    private static func shouldIgnore(kind: SensitiveKind, snippet: String) -> Bool {
        switch kind {
        case .ipAddress:
            return snippet == "127.0.0.1" || snippet == "0.0.0.0"
        case .urlSecret:
            let lower = snippet.lowercased()
            // 忽略明显占位示例值，避免误伤文档示例代码
            return lower == "your_api_key" || lower == "your-api-key" || lower == "placeholder" || lower == "<token>" || lower == "xxxxxxxx"
        default:
            return false
        }
    }
}
