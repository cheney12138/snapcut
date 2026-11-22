import CoreGraphics
import Foundation

/// 克制画框美化（Smart Backdrop）领域样式与几何模型
///
/// 六边形架构边界：纯领域值类型，仅依赖 Foundation / CoreGraphics。
/// 默认 `enabled = false`，确保日常极速裸截图流程零侵入。
public struct BackdropStyle: Equatable, Codable, Sendable {
    /// Apple 风格克制预设背景色板
    public enum Preset: String, CaseIterable, Codable, Sendable {
        case mistGray
        case softWhite
        case obsidian
        case macSonoma
        case macSequoia
        case macTahoe

        public var displayName: String {
            switch self {
            case .mistGray: return "浅雾灰"
            case .softWhite: return "柔白"
            case .obsidian: return "深曜石"
            case .macSonoma: return "暖霞"
            case .macSequoia: return "森海"
            case .macTahoe: return "冰蓝"
            }
        }

        public var colors: [RGBAColor] {
            switch self {
            case .mistGray:
                return [RGBAColor(hex: 0xF2F4F8), RGBAColor(hex: 0xE4E8F0)]
            case .softWhite:
                return [RGBAColor(hex: 0xFCFCFD), RGBAColor(hex: 0xF1F2F6)]
            case .obsidian:
                return [RGBAColor(hex: 0x23262F), RGBAColor(hex: 0x14161D)]
            case .macSonoma:
                return [RGBAColor(hex: 0xF6D7C7), RGBAColor(hex: 0xE5C5DF), RGBAColor(hex: 0xC6CCE8)]
            case .macSequoia:
                return [RGBAColor(hex: 0xC9E4DE), RGBAColor(hex: 0x90B8C9), RGBAColor(hex: 0x5E7C99)]
            case .macTahoe:
                return [RGBAColor(hex: 0xD6E8FF), RGBAColor(hex: 0xA8C9FA), RGBAColor(hex: 0x809CE8)]
            }
        }

        public var startPoint: CGPoint {
            CGPoint(x: 0, y: 0)
        }

        public var endPoint: CGPoint {
            CGPoint(x: 1, y: 1)
        }

        public var isDark: Bool {
            switch self {
            case .obsidian:
                return true
            case .mistGray, .softWhite, .macSonoma, .macSequoia, .macTahoe:
                return false
            }
        }
    }

    /// 边距档位（单位：逻辑 pt）
    public enum Padding: String, CaseIterable, Codable, Sendable {
        case compact
        case standard
        case showcase

        public var displayName: String {
            switch self {
            case .compact: return "紧凑"
            case .standard: return "标准"
            case .showcase: return "展示"
            }
        }

        public var points: CGFloat {
            switch self {
            case .compact: return 24
            case .standard: return 40
            case .showcase: return 64
            }
        }
    }

    /// 输出画布比例开关
    public enum AspectRatio: String, CaseIterable, Codable, Sendable {
        case auto
        case ratio16x9
        case ratio4x3

        public var displayName: String {
            switch self {
            case .auto: return "自动"
            case .ratio16x9: return "16:9"
            case .ratio4x3: return "4:3"
            }
        }

        public var ratio: CGFloat? {
            switch self {
            case .auto: return nil
            case .ratio16x9: return 16.0 / 9.0
            case .ratio4x3: return 4.0 / 3.0
            }
        }
    }

    public static let preferenceDefaultsKey = "snapcut.backdrop.preference"

    public var enabled: Bool
    public var preset: Preset
    public var padding: Padding
    public var cornerRadius: CGFloat
    public var aspectRatio: AspectRatio
    public var autoBalance: Bool

    public init(
        enabled: Bool = false,
        preset: Preset = .mistGray,
        padding: Padding = .standard,
        cornerRadius: CGFloat = 12,
        aspectRatio: AspectRatio = .auto,
        autoBalance: Bool = false
    ) {
        self.enabled = enabled
        self.preset = preset
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.aspectRatio = aspectRatio
        self.autoBalance = autoBalance
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case preset
        case padding
        case cornerRadius
        case aspectRatio
        case autoBalance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        preset = (try? container.decodeIfPresent(Preset.self, forKey: .preset)) ?? .mistGray
        padding = (try? container.decodeIfPresent(Padding.self, forKey: .padding)) ?? .standard
        cornerRadius = (try? container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)) ?? 12
        aspectRatio = (try? container.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)) ?? .auto
        autoBalance = (try? container.decodeIfPresent(Bool.self, forKey: .autoBalance)) ?? false
    }

    /// 计算画布、居中卡片与截图几何（原点左上 Y 向下，与 AnnotationModel 一致）
    public func layout(for imagePointSize: CGSize, balanceInset: CGFloat = 0) -> BackdropLayout {
        let imgW = max(1, imagePointSize.width)
        let imgH = max(1, imagePointSize.height)
        let inset = max(0, balanceInset)

        let cardW = imgW + inset * 2
        let cardH = imgH + inset * 2

        let minW = cardW + padding.points * 2
        let minH = cardH + padding.points * 2

        let canvasW: CGFloat
        let canvasH: CGFloat
        if let targetRatio = aspectRatio.ratio, targetRatio > 0 {
            let currentRatio = minW / minH
            if currentRatio < targetRatio {
                canvasW = (minH * targetRatio).rounded()
                canvasH = minH.rounded()
            } else if currentRatio > targetRatio {
                canvasW = minW.rounded()
                canvasH = (minW / targetRatio).rounded()
            } else {
                canvasW = minW.rounded()
                canvasH = minH.rounded()
            }
        } else {
            canvasW = minW.rounded()
            canvasH = minH.rounded()
        }

        let cardX = ((canvasW - cardW) * 0.5).rounded()
        let cardY = ((canvasH - cardH) * 0.5).rounded()
        let cardRect = CGRect(x: cardX, y: cardY, width: cardW, height: cardH)
        let imageRect = CGRect(x: cardX + inset, y: cardY + inset, width: imgW, height: imgH)

        let clampedCornerRadius = min(max(0, cornerRadius), min(cardW, cardH) * 0.25)

        return BackdropLayout(
            canvasSize: CGSize(width: canvasW, height: canvasH),
            cardRect: cardRect,
            imageRect: imageRect,
            cornerRadius: clampedCornerRadius,
            balanceInset: inset
        )
    }

    /// 加载用户上次选中的画框样式偏好；始终强制 `enabled = false` 以维持默认极速裸截图习惯
    public static func loadSavedPreference(from defaults: UserDefaults = .standard) -> BackdropStyle {
        guard let data = defaults.data(forKey: preferenceDefaultsKey),
              var decoded = try? JSONDecoder().decode(BackdropStyle.self, from: data) else {
            return BackdropStyle()
        }
        decoded.enabled = false
        return decoded
    }

    /// 持久化用户选中的画框样式偏好（不包含启用开关状态）
    public func savePreference(to defaults: UserDefaults = .standard) {
        var preference = self
        preference.enabled = false
        if let data = try? JSONEncoder().encode(preference) {
            defaults.set(data, forKey: Self.preferenceDefaultsKey)
        }
    }
}

/// 画框美化纯几何布局（原点左上 Y 向下，与 AnnotationModel 一致）
public struct BackdropLayout: Equatable, Sendable {
    public let canvasSize: CGSize
    public let cardRect: CGRect
    public let imageRect: CGRect
    public let cornerRadius: CGFloat
    public let balanceInset: CGFloat

    public init(
        canvasSize: CGSize,
        cardRect: CGRect,
        imageRect: CGRect,
        cornerRadius: CGFloat,
        balanceInset: CGFloat
    ) {
        self.canvasSize = canvasSize
        self.cardRect = cardRect
        self.imageRect = imageRect
        self.cornerRadius = cornerRadius
        self.balanceInset = balanceInset
    }
}

private extension RGBAColor {
    init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}
