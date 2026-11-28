import AppKit
import CoreGraphics

/// 冻结帧的像素级采样器（放大镜 / 取色用）
///
/// 为什么单独抽出：放大镜要在每个鼠标事件里读 121 个像素，
/// 必须 O(1)，不能走 `NSBitmapImageRep.colorAt`（每次都要过 CG 桥）。
/// 安装冻结帧时一次性把像素解到连续缓冲，之后纯数组索引。
struct FrozenSampler {
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let pixels: [UInt8]

    init?(image: CGImage) {
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 4
        let w = width
        let h = height
        var buffer = [UInt8](repeating: 0, count: rowBytes * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        bytesPerRow = rowBytes
        pixels = buffer
    }

    /// 取像素（RGBA 0-255，alpha 已按 premultiplied 解算成直通值）
    func rgba(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let idx = y * bytesPerRow + x * 4
        guard idx + 3 < pixels.count else { return nil }
        let a = Int(pixels[idx + 3])
        guard a > 0 else { return (0, 0, 0, 0) }
        // premultiplied → 直通
        let r = min(255, Int(pixels[idx]) * 255 / a)
        let g = min(255, Int(pixels[idx + 1]) * 255 / a)
        let b = min(255, Int(pixels[idx + 2]) * 255 / a)
        return (r, g, b, a)
    }

    func hex(x: Int, y: Int) -> String {
        guard let c = rgba(x: x, y: y) else { return "#------" }
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    /// `rgb(r, g, b)`（越界给占位符，绝不画出假色值）
    func rgbString(x: Int, y: Int) -> String {
        guard let c = rgba(x: x, y: y) else { return "rgb(-, -, -)" }
        return "rgb(\(c.r), \(c.g), \(c.b))"
    }

    /// `hsl(h, s%, l%)`：标准 RGB→HSL 换算，h ∈ 0...360、s/l ∈ 0...100（整数口径，与浏览器取色器一致）
    func hslString(x: Int, y: Int) -> String {
        guard let c = rgba(x: x, y: y) else { return "hsl(-, -, -)" }
        return Self.hslString(r: c.r, g: c.g, b: c.b)
    }

    private static func hslString(r: Int, g: Int, b: Int) -> String {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxV = max(rf, gf, bf)
        let minV = min(rf, gf, bf)
        let delta = maxV - minV
        let lightness = (maxV + minV) / 2

        var hue = 0.0
        var saturation = 0.0
        if delta > 0 {
            saturation = lightness > 0.5
                ? delta / (2 - maxV - minV)
                : delta / (maxV + minV)
            if maxV == rf {
                hue = (gf - bf) / delta + (gf < bf ? 6 : 0)
            } else if maxV == gf {
                hue = (bf - rf) / delta + 2
            } else {
                hue = (rf - gf) / delta + 4
            }
            hue /= 6
        }

        let h = min(360, max(0, Int((hue * 360).rounded())))
        let s = min(100, max(0, Int((saturation * 100).rounded())))
        let l = min(100, max(0, Int((lightness * 100).rounded())))
        return "hsl(\(h), \(s)%, \(l)%)"
    }

    /// 按用户当前格式口径输出色值（放大镜底栏 / 色卡 Toast / 剪贴板统一走这一个入口）
    func formatted(x: Int, y: Int, format: ColorCopyFormat) -> String {
        switch format {
        case .hex: return hex(x: x, y: y)
        case .rgb: return rgbString(x: x, y: y)
        case .hsl: return hslString(x: x, y: y)
        }
    }

    /// 副行信息：HEX 口径给 RGB 三元组，RGB/HSL 口径给 HEX（永远是“另一种”表示，不重复主行）
    func secondaryInfo(x: Int, y: Int, format: ColorCopyFormat) -> String {
        if format == .hex {
            guard let c = rgba(x: x, y: y) else { return "RGB(-, -, -)" }
            return "RGB(\(c.r), \(c.g), \(c.b))"
        }
        return hex(x: x, y: y)
    }
}

/// 取色复制格式（HEX → RGB → HSL 轮换）
///
/// 为什么放这里的 UI 层：格式只影响“怎么念出这个像素”，与取色链路无关；
/// 放大镜底栏、色卡 Toast、剪贴板写入共用同一份口径与落盘状态。
enum ColorCopyFormat: String, CaseIterable, Sendable {
    case hex
    case rgb
    case hsl

    private static let defaultsKey = "snapcut.colorCopyFormat"

    var shortLabel: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        }
    }

    func next() -> ColorCopyFormat {
        switch self {
        case .hex: return .rgb
        case .rgb: return .hsl
        case .hsl: return .hex
        }
    }

    /// 用户上次选定的格式（`⇧C` 轮换后落盘，下次取色直接沿用）
    static var persisted: ColorCopyFormat {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let parsed = ColorCopyFormat(rawValue: raw) else { return .hex }
            return parsed
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// 放大镜绘制（选区阶段的精确对位 / 取色）
///
/// 规格参照 Snow Shot 取色器：11×11 源像素 @12× = 132pt 放大区，
/// 中心像素描边标记，两行读数（色值 + 坐标/快捷键），光标右下 16pt 跟随、
/// 贴边自动翻到另一侧。
///
/// RGB / HSL 口径的色值比 HEX 长得多（`hsl(360, 100%, 100%)` 约 126pt），
/// 底栏放不下就按 24pt 步进加宽卡片（每侧多出整数列 12pt 源像素，方格仍是正方形、
/// 左右严格对称），实际像素也照真实采样补画，绝不拉伸出非方形像素或留黑边。
enum MagnifierPainter {
    static let sampleCount = 11
    static let zoom: CGFloat = 12
    private static let gridSize = CGFloat(sampleCount) * zoom           // 132
    private static let gap: CGFloat = 16
    /// 底线：132（仅 HEX 且坐标短）；上限 228（超宽屏 5 位坐标 + 长快捷键提示）
    private static let minCardWidth = gridSize
    private static let maxCardWidth: CGFloat = 228
    /// 加宽步进 = 每侧 1 列源像素（左右对称，方格保持正方形）
    private static let widenStep: CGFloat = 2 * zoom                    // 24
    private static let footerHeight: CGFloat = 46
    private static let hPad: CGFloat = 8
    private static let swatchSide: CGFloat = 9
    private static let swatchGap: CGFloat = 6
    private static let fullHint = "C 复制 · ⇧C 切"
    private static let compactHint = "C · ⇧C"

    /// - Parameters:
    ///   - sampler: 冻结帧采样器
    ///   - cursorLocal: 光标在本视图的本地坐标（Y 向下）
    ///   - bounds: 视图范围（用于避让边缘）
    ///   - imageSize: 冻结帧像素尺寸（用于本地点 → 像素换算）
    ///   - screenPoints: 屏幕逻辑尺寸（用于坐标读数）
    ///   - globalOrigin: 本窗在全局坐标的原点（用于换算屏幕坐标读数）
    static func draw(
        sampler: FrozenSampler,
        cursorLocal: CGPoint,
        bounds: CGRect,
        imageSize: CGSize,
        screenPoints: CGSize,
        globalOrigin: CGPoint,
        ctx: CGContext,
        format: ColorCopyFormat = .hex
    ) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        // 本地点 → 图像像素
        let px = Int(cursorLocal.x / bounds.width * imageSize.width)
        let py = Int(cursorLocal.y / bounds.height * imageSize.height)
        guard px >= 0, px < sampler.width, py >= 0, py < sampler.height else { return }

        let metrics = layoutMetrics(format: format, screenPoints: screenPoints)
        let cardWidth = metrics.cardWidth
        let cardHeight = gridSize + footerHeight
        let cornerR: CGFloat = 10

        // 面板位置：光标右下 18pt，右侧/下方放不下则翻到另一侧
        var origin = CGPoint(x: cursorLocal.x + gap + 2, y: cursorLocal.y + gap + 2)
        if origin.x + cardWidth + 10 > bounds.maxX { origin.x = cursorLocal.x - gap - 2 - cardWidth }
        if origin.y + cardHeight + 10 > bounds.maxY { origin.y = cursorLocal.y - gap - 2 - cardHeight }
        origin.x = max(8, min(origin.x, bounds.maxX - cardWidth - 8))
        origin.y = max(8, min(origin.y, bounds.maxY - cardHeight - 8))

        // 背景卡片（Apple Digital Color Meter 风格：柔和圆角投影 + 深半透底 + 0.5pt 发丝边）
        let cardRect = CGRect(x: origin.x, y: origin.y, width: cardWidth, height: cardHeight)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 22/255.0, green: 22/255.0, blue: 26/255.0, alpha: 0.90).cgColor)
        ctx.addPath(cardPath)
        ctx.fillPath()
        ctx.restoreGState()

        // 放大区裁进卡片圆角内
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        ctx.clip(to: CGRect(x: origin.x, y: origin.y, width: cardWidth, height: gridSize))

        // 11×11 采样区在卡片内水平居中；加宽出来的两侧照真实像素补画（方格恒为正方）
        let half = sampleCount / 2
        let extraCols = Int(((cardWidth - gridSize) / 2 / zoom).rounded())
        let gridOriginX = origin.x + (cardWidth - gridSize) / 2

        // 逐源像素绘制 12×12 方块（最近邻，不插值）
        for dy in 0..<sampleCount {
            for dx in (-extraCols)..<(sampleCount + extraCols) {
                let sx = px - half + dx
                let sy = py - half + dy
                guard sx >= 0, sx < sampler.width, sy >= 0, sy < sampler.height else { continue }
                let color = sampler.rgba(x: sx, y: sy) ?? (0, 0, 0, 0)
                ctx.setFillColor(
                    NSColor(
                        srgbRed: CGFloat(color.r) / 255,
                        green: CGFloat(color.g) / 255,
                        blue: CGFloat(color.b) / 255,
                        alpha: color.a == 0 ? 0.35 : 1
                    ).cgColor
                )
                ctx.fill(CGRect(
                    x: gridOriginX + CGFloat(dx) * zoom,
                    y: origin.y + CGFloat(dy) * zoom,
                    width: zoom, height: zoom
                ))
            }
        }

        // 精细像素网格线（克制白 α.07）
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
        ctx.setLineWidth(0.5)
        let columnCount = Int((cardWidth / zoom).rounded())
        for i in 1..<columnCount {
            let x = origin.x + CGFloat(i) * zoom
            ctx.move(to: CGPoint(x: x, y: origin.y))
            ctx.addLine(to: CGPoint(x: x, y: origin.y + gridSize))
        }
        for i in 1..<sampleCount {
            let y = origin.y + CGFloat(i) * zoom
            ctx.move(to: CGPoint(x: origin.x, y: y))
            ctx.addLine(to: CGPoint(x: origin.x + cardWidth, y: y))
        }
        ctx.strokePath()

        // 柔和十字准线（白 α.45，避免喧宾夺主）
        let centerRect = CGRect(
            x: gridOriginX + CGFloat(half) * zoom,
            y: origin.y + CGFloat(half) * zoom,
            width: zoom, height: zoom
        )
        let cx = centerRect.midX
        let cy = centerRect.midY
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.75)
        ctx.move(to: CGPoint(x: origin.x, y: cy))
        ctx.addLine(to: CGPoint(x: centerRect.minX - 1, y: cy))
        ctx.move(to: CGPoint(x: centerRect.maxX + 1, y: cy))
        ctx.addLine(to: CGPoint(x: origin.x + cardWidth, y: cy))
        ctx.move(to: CGPoint(x: cx, y: origin.y))
        ctx.addLine(to: CGPoint(x: cx, y: centerRect.minY - 1))
        ctx.move(to: CGPoint(x: cx, y: centerRect.maxY + 1))
        ctx.addLine(to: CGPoint(x: cx, y: origin.y + gridSize))
        ctx.strokePath()

        // 中心像素取色框（内白外暗双边，深浅底色皆清晰）
        let reticle = centerRect.insetBy(dx: -0.75, dy: -0.75)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(2.2)
        ctx.stroke(reticle)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.2)
        ctx.stroke(reticle)
        ctx.restoreGState()

        // 放大区与读数区分隔发丝线 + 外框 0.5pt 发丝边
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: origin.x, y: origin.y + gridSize))
        ctx.addLine(to: CGPoint(x: origin.x + cardWidth, y: origin.y + gridSize))
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(cardPath)
        ctx.strokePath()

        // 读数区首行 = 实时色点圆芯片 + 当前格式色值（HEX / RGB / HSL）
        let centerRGBA = sampler.rgba(x: px, y: py) ?? (0, 0, 0, 255)
        let colorText = sampler.formatted(x: px, y: py, format: format)
        let swatchRect = CGRect(
            x: origin.x + hPad,
            y: origin.y + gridSize + 8.5,
            width: swatchSide, height: swatchSide
        )
        ctx.setFillColor(NSColor(
            srgbRed: CGFloat(centerRGBA.r) / 255,
            green: CGFloat(centerRGBA.g) / 255,
            blue: CGFloat(centerRGBA.b) / 255,
            alpha: 1
        ).cgColor)
        ctx.fillEllipse(in: swatchRect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: swatchRect)

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.46),
        ]
        let valueX = origin.x + hPad + swatchSide + swatchGap
        (colorText as NSString).draw(
            at: CGPoint(x: valueX, y: origin.y + gridSize + 6),
            withAttributes: valueAttrs
        )

        // 次行：左侧精确坐标（等宽数字），右侧紧凑快捷键提示（右对齐，永不相撞）
        let hintText = metrics.hintText
        let hintWidth = (hintText as NSString).size(withAttributes: hintAttrs).width
        (hintText as NSString).draw(
            at: CGPoint(x: origin.x + cardWidth - hPad - hintWidth, y: origin.y + gridSize + 27),
            withAttributes: hintAttrs
        )

        let screenX = Int(cursorLocal.x.rounded())
        let screenY = Int(cursorLocal.y.rounded())
        let coordText = "X \(screenX)  Y \(screenY)"
        let coordAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.58),
        ]
        (coordText as NSString).draw(
            at: CGPoint(x: origin.x + hPad, y: origin.y + gridSize + 26),
            withAttributes: coordAttrs
        )
    }

    // MARK: - 底栏排版（宽度按真实字宽算，宁可加宽卡片也绝不压字/裁切）

    private struct LayoutMetrics {
        var cardWidth: CGFloat
        var hintText: String
    }

    /// 最坏情况色值样本：宽度只按「该格式最长可能输出」算，避免光标移动时卡片宽度抖动
    private static func valueProbe(format: ColorCopyFormat) -> String {
        switch format {
        case .hex: return "#FFFFFF"
        case .rgb: return "rgb(255, 255, 255)"
        case .hsl: return "hsl(360, 100%, 100%)"
        }
    }

    /// 坐标样本：位数按当前屏幕逻辑尺寸取（同一个 tabular 字体下等宽，宽度即最坏值）
    private static func coordinateProbe(screenPoints: CGSize) -> String {
        let longest = Int(max(screenPoints.width, screenPoints.height).rounded())
        let digits = max(3, String(max(1, longest)).count)
        let blank = String(repeating: "0", count: digits)
        return "X \(blank)  Y \(blank)"
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func layoutMetrics(
        format: ColorCopyFormat,
        screenPoints: CGSize
    ) -> LayoutMetrics {
        let valueWidth = textWidth(
            valueProbe(format: format),
            font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        )
        let coordWidth = textWidth(
            coordinateProbe(screenPoints: screenPoints),
            font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        )
        let hintFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        let fullHintWidth = textWidth(fullHint, font: hintFont)
        let compactHintWidth = textWidth(compactHint, font: hintFont)

        func neededWidth(hintWidth: CGFloat) -> CGFloat {
            let valueLine = hPad + swatchSide + swatchGap + valueWidth + hPad
            let coordLine = hPad + coordWidth + 12 + hintWidth + hPad
            return max(valueLine, coordLine)
        }

        /// 宽度按 24pt（每侧 1 列源像素）向上取整，保证左右对称且方格恒为正方形
        func fitted(_ need: CGFloat) -> CGFloat {
            guard need > minCardWidth else { return minCardWidth }
            let steps = ((need - minCardWidth) / widenStep).rounded(.up)
            return min(maxCardWidth, minCardWidth + steps * widenStep)
        }

        let full = neededWidth(hintWidth: fullHintWidth)
        if full <= maxCardWidth {
            return LayoutMetrics(cardWidth: fitted(full), hintText: fullHint)
        }
        // 超宽屏 + 5 位坐标仍放不下完整提示时才退到紧凑口径
        return LayoutMetrics(
            cardWidth: fitted(neededWidth(hintWidth: compactHintWidth)),
            hintText: compactHint
        )
    }
}
