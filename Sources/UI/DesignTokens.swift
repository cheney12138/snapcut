import AppKit
import SwiftUI

/// 设计 Token 单一真源（施工图：tokens.md / 视觉真源：snapcut-design-redesign/index.html）
///
/// 纪律：
/// - 所有界面（工具栏 / 引导卡 / 设置窗 / 组框 / toast / 滚动 HUD）的颜色、圆角、
///   间距、字阶、材质配方一律从这里取值，不允许文件内私设色值。
/// - 三条铁律：玻璃只分三档（mat.hud / mat.card / mat.window）；强调色只有一个
///   system blue；间距全部落在 8pt 栅格（半档 4pt）。
/// - 钉暗策略：HUD 档浮层（工具栏 / toast / 组框徽标 / 滚动 HUD）窗口 appearance
///   钉 darkAqua——动态色在该外观下自动解析为暗值；窗口类（引导卡 / 设置窗）跟随
///   系统 appearance，动态 provider 给出暗 / 亮双值。
/// - Core 零 AppKit：本文件只放 UI 层。
@MainActor
enum DesignTokens {

    // MARK: - 1.1 accent（唯一强调色，暗 #0A84FF / 亮 #007AFF）

    static let accent = NSColor(name: "dt.accent") { ap in
        ap.isDark ? NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)     // #0A84FF
                  : NSColor(srgbRed: 0, green: 0.478, blue: 1.0, alpha: 1)         // #007AFF
    }
    /// accent.hover：主按钮 hover 背景（+0.12 亮度），暗 #2A94FF / 亮 #1F82FF
    static let accentHover = NSColor(name: "dt.accentHover") { ap in
        ap.isDark ? NSColor(srgbRed: 0.165, green: 0.580, blue: 1.0, alpha: 1)     // #2A94FF
                  : NSColor(srgbRed: 0.122, green: 0.510, blue: 1.0, alpha: 1)     // #1F82FF
    }
    /// accent.press：按下态，暗 #0060DF / 亮 #0062CC
    static let accentPress = NSColor(name: "dt.accentPress") { ap in
        ap.isDark ? NSColor(srgbRed: 0, green: 0.376, blue: 0.875, alpha: 1)       // #0060DF
                  : NSColor(srgbRed: 0, green: 0.384, blue: 0.800, alpha: 1)       // #0062CC
    }
    /// accent.soft：选中 tab 底 / 焦点柔和底，暗 α.16 / 亮 α.12
    static let accentSoft = NSColor(name: "dt.accentSoft") { ap in
        ap.isDark ? NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.16)
                  : NSColor(srgbRed: 0, green: 0.478, blue: 1.0, alpha: 0.12)
    }
    /// accent.ring：热键录制态 1.5pt 外环（α .55）
    /// 轻盈感审查：2.5pt 在 22pt 控件上占高 11% 比例失真 → 1.5pt（与选区同阶）+ α.55 补偿可读性
    static let accentRing = accent.withAlphaComponent(0.55)

    /// 深胶囊家族底色 rgba(24,24,27,.62)：尺寸角标 / PinHUD 读数（α.72/.75 实心黑块 → 材质语气）
    static let capsuleDark = NSColor(srgbRed: 24 / 255.0, green: 24 / 255.0, blue: 27 / 255.0, alpha: 0.62)

    // MARK: - 1.2 status（语义状态色，只表达状态不做装饰）

    /// status.ok：暗 #30D158 / 亮 #28CD41（systemGreen 双态解析）
    static let statusOK = NSColor(name: "dt.statusOK") { ap in
        ap.isDark ? NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)   // #30D158
                  : NSColor(srgbRed: 0.157, green: 0.804, blue: 0.255, alpha: 1)   // #28CD41
    }
    /// status.warn：暗 #FF9F0A / 亮 #FF9500（systemOrange 双态解析）
    static let statusWarn = NSColor(name: "dt.statusWarn") { ap in
        ap.isDark ? NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)     // #FF9F0A
                  : NSColor(srgbRed: 1.0, green: 0.584, blue: 0.0, alpha: 1)       // #FF9500
    }
    /// status.error：热键冲突提示文字（11pt）
    static let statusError = NSColor(name: "dt.statusError") { ap in
        ap.isDark ? NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)     // #FF453A
                  : NSColor(srgbRed: 1.0, green: 0.231, blue: 0.188, alpha: 1)     // #FF3B30
    }

    // MARK: - 1.3 label（文字阶层，暗色浮层基准 / 亮色变体随动态色解析）

    static let label1 = NSColor(name: "dt.label1") { ap in
        ap.isDark ? NSColor.white.withAlphaComponent(0.94)
                  : NSColor.black.withAlphaComponent(0.88)
    }
    static let label2 = NSColor(name: "dt.label2") { ap in
        ap.isDark ? NSColor.white.withAlphaComponent(0.64)
                  : NSColor.black.withAlphaComponent(0.56)
    }
    static let label3 = NSColor(name: "dt.label3") { ap in
        ap.isDark ? NSColor.white.withAlphaComponent(0.40)
                  : NSColor.black.withAlphaComponent(0.36)
    }
    /// label.onAccent：accent 实心控件上的文字/图标（纯白）
    static let labelOnAccent = NSColor.white

    // MARK: - 1.4 线与填充

    /// hair：0.5pt 分隔线，暗 白.12 / 亮 黑.10
    static let hair = NSColor(name: "dt.hair") { ap in
        ap.isDark ? NSColor.white.withAlphaComponent(0.12)
                  : NSColor.black.withAlphaComponent(0.10)
    }
    /// stroke：0.5pt 容器描边，暗 白.14 / 亮 黑.12
    static let stroke = NSColor(name: "dt.stroke") { ap in
        ap.isDark ? NSColor.white.withAlphaComponent(0.14)
                  : NSColor.black.withAlphaComponent(0.12)
    }
    /// fill：自绘填充底（popup/输入框/小按钮），暗 α.24 / 亮 α.12
    static let fill = NSColor(name: "dt.fill") { ap in
        ap.isDark ? NSColor(srgbRed: 120/255.0, green: 120/255.0, blue: 128/255.0, alpha: 0.24)
                  : NSColor(srgbRed: 120/255.0, green: 120/255.0, blue: 128/255.0, alpha: 0.12)
    }
    /// fill.hover：图标按钮 hover 底，暗 α.36 / 亮 α.20
    static let fillHover = NSColor(name: "dt.fillHover") { ap in
        ap.isDark ? NSColor(srgbRed: 120/255.0, green: 120/255.0, blue: 128/255.0, alpha: 0.36)
                  : NSColor(srgbRed: 120/255.0, green: 120/255.0, blue: 128/255.0, alpha: 0.20)
    }
    /// fill.press：按下态，暗 α.46 / 亮 α.28
    static let fillPress = NSColor(name: "dt.fillPress") { ap in
        ap.isDark ? NSColor(srgbRed: 120/255.0, green: 120/255.0, blue: 128/255.0, alpha: 0.46)
                  : NSColor(srgbRed: 120/255.0, green: 120/255.0, blue: 128/255.0, alpha: 0.28)
    }
    /// fill.kbd：kbd 胶囊底（暗 白.07；亮变体 黑.06 保持胶囊可读）
    static let fillKbd = NSColor(name: "dt.fillKbd") { ap in
        ap.isDark ? NSColor.white.withAlphaComponent(0.07)
                  : NSColor.black.withAlphaComponent(0.06)
    }
    /// 分组卡底：暗 白.045 / 亮 黑.04（设置窗分组卡与窗底的层级差）
    static let fillCard = NSColor(name: "dt.fillCard") { ap in
        ap.isDark ? NSColor.white.withAlphaComponent(0.045)
                  : NSColor.black.withAlphaComponent(0.04)
    }

    // MARK: - 2. 玻璃材质三档（配方即最终值，不再手工叠色调灰）

    @MainActor
    enum Mat {
        /// 档 1 · HUD：.hudWindow（钉暗窗口内解析为暗玻璃）——工具栏/toast/组框徽标/滚动 HUD
        static let hud: NSVisualEffectView.Material = .hudWindow
        /// 档 2 · 卡片：.hudWindow 跟随窗口 appearance——引导卡
        static let card: NSVisualEffectView.Material = .hudWindow
        /// 档 3 · 窗体：.sidebar 全窗磨砂——设置窗底
        /// 病例：.underWindowBackground 在 isOpaque=false + clear 的透明窗体上
        /// 磨砂直接失效（底下窗口文字穿透可见，macOS 26）；.sidebar 是设置类
        /// 窗的常规材质，三件套（满铺 effectView + isOpaque=false + clear）下稳定。
        static let window: NSVisualEffectView.Material = .sidebar

        /// 缓存的 9-slice 圆角蒙版图（Apple 官方 NSVisualEffectView.maskImage 方案）：
        /// 严格把 WindowServer 磨砂层裁在连续圆角内，彻底消除 macOS 亮/暗色下的四角白块与晕边。
        private static var maskCache: [Int: NSImage] = [:]

        static func roundedMaskImage(cornerRadius r: CGFloat) -> NSImage {
            let key = Int((r * 10).rounded())
            if let cached = maskCache[key] { return cached }
            // `.continuous` 超椭圆拐角过渡略大于圆半径（约 1.52×r），9-slice cap 取 ceil(1.6×r) 保证边角零拉伸
            let cap = max(r, ceil(r * 1.6))
            let side = max(4, cap * 2 + 2)
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                if let cg = NSGraphicsContext.current?.cgContext {
                    cg.addPath(continuousRoundedPath(in: rect, cornerRadius: r))
                    cg.setFillColor(NSColor.black.cgColor)
                    cg.fillPath()
                }
                return true
            }
            image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
            image.resizingMode = .stretch
            maskCache[key] = image
            return image
        }

        /// 统一玻璃容器配方（macOS 15 回退材质）：三档材质 + blendingMode(.behindWindow) + active +
        /// maskImage 精确圆角裁剪 + 明暗自适应 0.5pt stroke 描边。
        static func glass(
            material: NSVisualEffectView.Material,
            cornerRadius: CGFloat,
            strokeWidth: CGFloat = 0.5,
            strokeColor: NSColor? = nil
        ) -> NSVisualEffectView {
            let v = AdaptiveGlassView(
                cornerRadius: cornerRadius,
                strokeWidth: strokeWidth,
                dynamicStrokeColor: strokeColor ?? DesignTokens.stroke
            )
            v.material = material
            v.blendingMode = .behindWindow
            v.state = .active
            return v
        }

        /// macOS 26 原生 Liquid Glass 风格档位
        enum LiquidGlassStyle {
            /// 标准液态玻璃（工具栏、悬浮胶囊、控件栏：光学折射 + 高可读对比）
            case regular
            /// 通透液态玻璃（拼贴托盘、画布衬底：极清透玻璃质感 + 真实边缘折射）
            case clear
        }

        /// 原生液态玻璃容器包装：
        /// - macOS 26+ 使用系统原生 `NSGlassEffectView`，并严格把所有子视图放进 `contentView`
        ///   （Apple 官方要求：直接 addSubview 到 NSGlassEffectView 无法保证 z-order）；
        /// - macOS 15 自动回落 `AdaptiveGlassView`（NSVisualEffectView），保持双版本兼容。
        struct LiquidGlassSurface {
            let hostView: NSView
            let contentContainer: NSView
            let isNativeLiquidGlass: Bool
        }

        /// 悬浮控件用通透液态玻璃微着色（搭配 `NSGlassEffectView.style = .clear`）：
        /// 不画边框黑线，靠适度提亮/加深玻璃体与「紧贴接触影 + 柔和抬升影」自然切分玻璃与背景。
        static let floatingGlassTint = NSColor(name: "dt.floatingGlassTint") { ap in
            ap.isDark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 0.42)
                      : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.48)
        }

        /// 高晶液态玻璃微着色（视觉记忆浮窗等大面积内容面板专用：纯白晶透微着 `0.42`，对齐工具栏通透度）
        static let crystalGlassTint = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.42)

        static func liquidGlass(
            cornerRadius: CGFloat,
            style: LiquidGlassStyle = .clear,
            tintColor: NSColor? = nil,
            fallbackMaterial: NSVisualEffectView.Material = .hudWindow
        ) -> LiquidGlassSurface {
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = cornerRadius
                glass.style = (style == .clear) ? .clear : .regular
                glass.tintColor = tintColor
                let inner = NSView()
                inner.wantsLayer = true
                glass.contentView = inner
                return LiquidGlassSurface(
                    hostView: glass,
                    contentContainer: inner,
                    isNativeLiquidGlass: true
                )
            }
            let fallback = glass(material: fallbackMaterial, cornerRadius: cornerRadius)
            return LiquidGlassSurface(
                hostView: fallback,
                contentContainer: fallback,
                isNativeLiquidGlass: false
            )
        }

        /// 恒定浅色高晶玻璃容器（`.aqua` `.menu` 澄澈模糊 + `.continuous` 9-slice 裁切 + 纯白晶透提亮，无任何边框黑线）：
        /// - 相比 `.hudWindow`，`.menu` 在 `.aqua` 下通透度更高、更接近高晶玻璃观感；
        /// - 相比 macOS 26 原生 `NSGlassEffectView`（内部硬编码 `CABackdropLayer.tracksLuma = 1` 会在切到深色 IDE 时首帧闪跳），
        ///   本实现完全不含 `tracksLuma`，深浅背景切屏时 100% 稳定零闪烁，同时由 `OuterShadowView` 双层阴影自然托起。
        static func fixedLightCrystalBlur(
            cornerRadius: CGFloat,
            tintAlpha: CGFloat = 0.08
        ) -> LiquidGlassSurface {
            let glassView = AdaptiveGlassView(
                cornerRadius: cornerRadius,
                strokeWidth: 0,
                dynamicStrokeColor: .clear
            )
            glassView.appearance = NSAppearance(named: .aqua)
            glassView.material = .menu
            glassView.blendingMode = .behindWindow
            glassView.state = .active

            if tintAlpha > 0 {
                let veil = NSView(frame: glassView.bounds)
                veil.autoresizingMask = [.width, .height]
                veil.wantsLayer = true
                veil.layer?.backgroundColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: tintAlpha).cgColor
                glassView.addSubview(veil)
            }

            return LiquidGlassSurface(
                hostView: glassView,
                contentContainer: glassView,
                isNativeLiquidGlass: false
            )
        }

        /// 生成与 `NSGlassEffectView` 内部 `CASDFElementLayer` 完全一致的 `.continuous` 连续曲率超椭圆路径
        static func continuousRoundedPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
            let r = min(cornerRadius, min(rect.width, rect.height) / 2)
            return RoundedRectangle(cornerRadius: max(0, r), style: .continuous)
                .path(in: rect)
                .cgPath
        }
    }

    // MARK: - 内高光（inset.hi / inset.hi.strong）

    @MainActor
    enum Inset {
        /// inset.hi：顶缘 1pt 镜面高光（暗 .14 / 亮 .55）
        static let hiAlpha: (CGFloat, CGFloat) = (0.14, 0.55)
        /// inset.hi.strong：accent 实心控件顶缘白 .18
        static let strongAlpha: CGFloat = 0.18

        /// 给圆角容器加对称顶缘镜面高光：1pt 高渐变层在左右圆角处柔缓淡出，模拟 Apple 玻璃顶缘受光。
        static func installHighlight(on container: NSView, alpha: CGFloat, topInset: CGFloat = 0.5) {
            let g = CAGradientLayer()
            let yPos = container.isFlipped ? topInset : max(0, container.bounds.height - topInset - 1)
            g.frame = CGRect(x: 0, y: yPos, width: container.bounds.width, height: 1)
            g.autoresizingMask = container.isFlipped
                ? [.layerWidthSizable]
                : [.layerWidthSizable, .layerMinYMargin]
            g.colors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(alpha).cgColor,
                NSColor.white.withAlphaComponent(alpha).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ]
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            g.locations = [0, 0.12, 0.88, 1]
            container.layer?.addSublayer(g)
        }
    }

    // MARK: - 3. 投影（Apple 双层光学投影：贴边接触影 + 柔散环境影）

    @MainActor
    enum Shadow {
        /// shadow.float：双层光学影（贴边接触影 r4/y-1/α.14 + 环境浮起影 r24/y-10/α.22）
        static let float = [
            LayerShadow(radius: 4, offset: CGSize(width: 0, height: -1), alpha: 0.14, spread: 0),
            LayerShadow(radius: 24, offset: CGSize(width: 0, height: -10), alpha: 0.22, spread: 4),
        ]
        /// shadow.card：卡片浮层投影（单层紧凑柔影）
        static let card = LayerShadow(radius: 16, offset: CGSize(width: 0, height: -6), alpha: 0.24, spread: 4)
        /// shadow.knob：滑杆旋钮 0 1 3 .45
        static let knob = LayerShadow(radius: 3, offset: CGSize(width: 0, height: -1), alpha: 0.45, spread: 0)

        struct LayerShadow {
            let radius: CGFloat
            let offset: CGSize
            let alpha: CGFloat
            let spread: CGFloat
        }

        /// 把 shadow.float 投影铺到一组铺满容器的透明视图上（ToolbarPanel 配方；
        /// v0.6 起单层，数组兼容多层调用方）
        static func applyFloat(to layers: [(NSView, LayerShadow)], cornerRadius: CGFloat) {
            for (view, spec) in layers {
                guard let layer = view.layer else { continue }
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = Float(spec.alpha)
                layer.shadowRadius = spec.radius
                layer.shadowOffset = spec.offset
                let rect = CGRect(origin: .zero, size: view.bounds.size).insetBy(dx: spec.spread / 2, dy: spec.spread / 2)
                layer.shadowPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            }
        }
    }

    // MARK: - 4. 圆角阶

    enum Radius {
        static let xs: CGFloat = 4    // 徽标内元素、状态点
        static let sm: CGFloat = 6    // 缩略图、输入框、kbd 胶囊(5)、popup
        static let md: CGFloat = 7    // 28pt 工具/图标按钮、主按钮(8)
        static let lg: CGFloat = 10   // 设置分组卡、纯文案 toast
        static let xl: CGFloat = 14   // 工具栏容器、toast 容器、组框
        static let xxl: CGFloat = 16  // 引导卡
        static let kbd: CGFloat = 5   // kbd 胶囊
        static let primaryButton: CGFloat = 8   // 引导卡主按钮
        static let hudSmall: CGFloat = 9         // 滚动 HUD
        static let badge: CGFloat = 11           // 组框徽标（22 高胶囊 = 高/2）
        static let assemble: CGFloat = 7         // 组框合成按钮（r.md，原 12 孤儿尺寸回收进 token 阶）
        static let collageFrame: CGFloat = 12    // 组框（Stage Manager 式极细框，原 14 → 12）
    }

    // MARK: - 5. 间距（8pt 栅格）

    enum Spacing {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
    }

    // MARK: - 6. 字阶（SF Pro / PingFang SC 自动回退）

    @MainActor
    enum Font {
        static let title = NSFont.systemFont(ofSize: 15, weight: .semibold)       // t.title
        static let head = NSFont.systemFont(ofSize: 13, weight: .semibold)        // t.head
        static let body = NSFont.systemFont(ofSize: 13)                           // t.body
        static let note = NSFont.systemFont(ofSize: 11)                           // t.note
        static let noteSemibold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let caption = NSFont.systemFont(ofSize: 10.5, weight: .medium)     // t.caption
        static let kbd = NSFont.systemFont(ofSize: 11, weight: .medium)           // t.kbd
        /// 数字一律 tabular-nums（等宽数字变体）
        static func monoDigit(_ size: CGFloat) -> NSFont {
            NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        }
    }

    // MARK: - 7. 控件尺寸

    /// 玻璃浮层前景（暗外观=白 α，亮外观=黑 α）——工具栏等 HUD 组件
    /// 跟随系统后的文字/描边动态色源
    static func hudForeground(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base: NSColor = isDark ? .white : .black
            return base.withAlphaComponent(alpha)
        }
    }

    enum Control {
        static let h: CGFloat = 28      // ctl.h：标准控件高 / 工具·图标按钮 28×28
        static let hSm: CGFloat = 22    // ctl.h.sm：popup、小按钮、热键录制器、NSSwitch
        static let hLg: CGFloat = 34    // ctl.h.lg：引导卡主按钮
        static let iconS: CGFloat = 16  // 图标视觉高（SF Symbol pointSize 14 / medium）
        static let kbdHeight: CGFloat = 22
        static let kbdMinWidth: CGFloat = 22
        static let recorderHeight: CGFloat = 22
        static let recorderMinWidth: CGFloat = 96
        static let sliderWidth: CGFloat = 76   // 粗细滑杆 76×20
        static let sliderHeight: CGFloat = 20
    }

    // MARK: - 8. 动效（Emil Design Engineering & Apple Craft 标准：绝不对 UI 用 ease-in）

    enum Motion {
        /// 强缓出曲线 cubic-bezier(0.23, 1, 0.32, 1) — 入场/退场/微反馈统一首选，起步即响应
        nonisolated(unsafe) static let easeOutStrong = CAMediaTimingFunction(controlPoints: 0.23, 1.0, 0.32, 1.0)
        /// 强缓入缓出曲线 cubic-bezier(0.77, 0, 0.175, 1) — 屏内位移/形变专用
        nonisolated(unsafe) static let easeInOutStrong = CAMediaTimingFunction(controlPoints: 0.77, 0.0, 0.175, 1.0)
        /// 克制的临界阻尼曲线 cubic-bezier(0.22, 1, 0.36, 1) — 工具栏/浮层落位干脆利落，无廉价橡胶回弹
        nonisolated(unsafe) static let springTimingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)

        /// 强制启用完整动效（针对 Snapcut 忽略系统「减少动态效果」设置，确保灵动岛与弹簧交互满血生效）
        @MainActor static var reduceMotion: Bool { false }

        /// motion.spring：0.22s 临界阻尼入场
        static let springDuration: TimeInterval = 0.22
        static let springControlPoints: (Float, Float, Float, Float) = (0.22, 1.0, 0.36, 1.0)
        /// 按钮按压触觉反馈：120ms ease-out + scale(0.97)
        static let pressDuration: TimeInterval = 0.12
        static let pressScale: CGFloat = 0.97
        /// motion.fade：0.16s 退场淡出
        static let fadeDuration: TimeInterval = 0.16
        /// motion.pulse：1.6s ease-in-out 往复（光晕 α .35↔.70），滚动采集边缘光晕
        static let pulseDuration: CFTimeInterval = 1.6
        static let pulseAlphaMin: Float = 0.35
        static let pulseAlphaMax: Float = 0.70
        /// hover 反馈 0.14s
        static let hoverDuration: CFTimeInterval = 0.14

        /// motion.enter：0.22s strong ease-out + rise 8pt + scale .97→1 + fade
        static let enterDuration: TimeInterval = 0.22
        static let enterRise: CGFloat = 8
        static let enterScale: CGFloat = 0.97
        /// motion.enter.center：0.24s strong ease-out + rise 8pt + scale .96→1（引导卡）
        static let enterCenterDuration: TimeInterval = 0.24
        static let enterCenterScale: CGFloat = 0.96
        /// motion.exit：0.14s ease-out + sink 4pt + scale→.97 + fade（绝不用 ease-in 拖慢收尾）
        static let exitDuration: TimeInterval = 0.14
        static let exitSink: CGFloat = 4
        static let exitScale: CGFloat = 0.97
        /// motion.crossfade：0.15s ease-out（内容态/页面切换）
        static let crossfadeDuration: TimeInterval = 0.15
    }

    // MARK: - 工具栏规格（§9 场景速查）

    enum Toolbar {
        /// 按用户选择的工具栏尺寸档位派生的完整几何度量（遵守 macOS 26 Liquid Glass 同心圆角规范）
        struct Metrics {
            let buttonSide: CGFloat
            let iconPointSize: CGFloat
            let paddingH: CGFloat
            let paddingV: CGFloat
            let groupGap: CGFloat
            let separatorHeight: CGFloat
            let separatorMargin: CGFloat
            let dotSide: CGFloat
            let dotGap: CGFloat
            let strokeButtonSide: CGFloat
            let strokeDotScale: CGFloat

            var height: CGFloat { buttonSide + paddingV * 2 }
            var cornerRadius: CGFloat {
                switch buttonSide {
                case ..<33: return 12
                case ..<39: return 14
                default: return 16
                }
            }
            var innerPillRadius: CGFloat {
                switch buttonSide {
                case ..<33: return 7
                case ..<39: return 8.5
                default: return 10
                }
            }

            static func forSize(_ size: AppSettings.ToolbarSize) -> Metrics {
                switch size {
                case .compact:
                    return Metrics(
                        buttonSide: 30, iconPointSize: 15.5,
                        paddingH: 10, paddingV: 7, groupGap: 4,
                        separatorHeight: 18, separatorMargin: 4,
                        dotSide: 13, dotGap: 4,
                        strokeButtonSide: 24, strokeDotScale: 1.0
                    )
                case .regular:
                    return Metrics(
                        buttonSide: 36, iconPointSize: 17.5,
                        paddingH: 12, paddingV: 7, groupGap: 5,
                        separatorHeight: 20, separatorMargin: 5,
                        dotSide: 15, dotGap: 5,
                        strokeButtonSide: 28, strokeDotScale: 1.15
                    )
                case .large:
                    return Metrics(
                        buttonSide: 42, iconPointSize: 20.0,
                        paddingH: 14, paddingV: 8, groupGap: 6,
                        separatorHeight: 24, separatorMargin: 6,
                        dotSide: 17, dotGap: 6,
                        strokeButtonSide: 32, strokeDotScale: 1.3
                    )
                }
            }
        }

        static let height: CGFloat = 50
        static let padding: CGFloat = 7
        static let groupGap: CGFloat = 5
        /// 组间 hairline 两侧各 5
        static let separatorMargin: CGFloat = 5
        static let separatorHeight: CGFloat = 20
        static let iconIdleAlpha: CGFloat = 0.88
        static let iconDisabledAlpha: CGFloat = 0.28
        static let dotSide: CGFloat = 15
        static let dotGap: CGFloat = 5
        static let copyButtonSide: CGFloat = 36
        static let tooltipFontSize: CGFloat = 10.5
    }

    // MARK: - 引导卡规格

    enum Onboarding {
        static let width: CGFloat = 400
        static let padding: CGFloat = 24
        static let rowHeight: CGFloat = 40
        static let headIconSize: CGFloat = 48
    }

    // MARK: - 设置窗规格

    enum Settings {
        static let windowSize = CGSize(width: 560, height: 640)
        static let rowHeight: CGFloat = 38
        static let cardPaddingH: CGFloat = 16
        static let cardPaddingTop: CGFloat = 4
        static let cardPaddingBottom: CGFloat = 6
        static let cardGap: CGFloat = 12
        /// 分组卡描边（settings 局部覆写，不动全局 stroke）：暗 白.10 / 亮 黑.08
        /// ——卡是区域不是盒子（System Settings 语气）
        static let cardStroke = NSColor(name: "dt.settingsCardStroke") { ap in
            ap.isDark ? NSColor.white.withAlphaComponent(0.10)
                      : NSColor.black.withAlphaComponent(0.08)
        }
    }

    // MARK: - 组框规格（重设计真源：snapcut-collage-ui/index.html §06 token 差异清单）

    @MainActor
    enum GroupFrame {
        /// 组框线：0.5pt 极细实线（替代 1.5pt dash[5,4] 虚线——Stage Manager 语气）
        static let strokeWidth: CGFloat = 0.5
        /// 组框线色：暗 白.26 / 亮 黑.18（GroupBorderPanel 钉 darkAqua 时解析暗值）
        static let stroke = NSColor(name: "dt.groupStroke") { ap in
            ap.isDark ? NSColor.white.withAlphaComponent(0.26)
                      : NSColor.black.withAlphaComponent(0.18)
        }
        /// 组框圆角（corner 14 → 12）
        static let cornerRadius: CGFloat = Radius.collageFrame
        /// 组框窗体外扩：10 → 22（修复浮标骑顶被窗缘裁切病例；浮标骑框顶外 −11pt 后
        /// 需 ≥ 11 + 浮标半高 11 + 呼吸 = 22）
        static let panelOutset: CGFloat = 22
        /// 浮标骑框顶外偏移（badge/button top = 框顶 −11）
        static let rideOffset: CGFloat = 11
        /// 徽标（mat.hud 玻璃胶囊）：22 高 / radius 11 / 0.5pt 白.16 stroke /
        /// label-1 文字「拼贴 N」+ tabular-nums（原 accent 实心 α.92「拼贴空间 · N 张」删除）
        static let badgeHeight: CGFloat = 22
        static let badgeStroke = NSColor(name: "dt.badgeStroke") { ap in
            ap.isDark ? NSColor.white.withAlphaComponent(0.16)
                      : NSColor.black.withAlphaComponent(0.14)
        }
        static let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)          // t.caption 10.5/500
        static let badgeNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold) // tabular-nums 600
        /// 合成按钮（全画面唯一 accent）：22 高（ctl.h.sm）/ radius 7（r.md）/
        /// SF Symbol arrow.triangle.merge + 「合成」/ 11pt·500 / inset-hi-strong / hover accent-hover
        /// （原 24 高 / radius 12 孤儿尺寸 + 纯文字「合成整体」删除）
        static let assembleHeight: CGFloat = 22
        static let assembleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        /// 吸附反馈（对齐 Scroll 选区语言，替代 blur12 α.9 蓝色光晕 + 硬编码 #4C8DFF）：
        /// 1.5pt accent outline + 3.5pt soft ring，ring α.10↔.22 做 1.2s autoreverse 透明度脉冲
        static let snapOutlineWidth: CGFloat = Scroll.outlineWidth        // 1.5
        static let snapRingWidth: CGFloat = Scroll.outlineSoftRing       // 3.5
        static let snapRingAlphaMin: CGFloat = 0.10
        static let snapRingAlphaMax: CGFloat = 0.22
        static let snapPulseDuration: CFTimeInterval = 1.2
    }

    // MARK: - Toast 规格

    enum Toast {
        static let imageSize = CGSize(width: 268, height: 76)
        static let textHeight: CGFloat = 40
        static let thumbSide: CGFloat = 56
        static let screenMargin: CGFloat = 20
        /// 缩略图描边：0.5pt 白 .16（对齐 stroke token 档位；装饰边界不是内容边界）
        static let thumbStrokeAlpha: CGFloat = 0.16
    }

    // MARK: - 滚动截图规格（§9 场景 06）

    enum Scroll {
        static let hudOffsetFromSelection: CGFloat = 8   // HUD 贴选区下缘 8pt
        static let hudPaddingH: CGFloat = 10
        static let hudPaddingV: CGFloat = 6
        static let progressSize = CGSize(width: 44, height: 3)   // 44×3pt 进度条
        static let breathingDotSide: CGFloat = 4                 // 呼吸点×3
        /// 呼吸点透明度下限：.35↔1（原 .22↔1 满幅闪烁 → 呼吸）
        static let breathingAlphaMin: Float = 0.35
        static let bottomBarHeight: CGFloat = 2                  // 底缘 2pt 绿条
        static let outlineWidth: CGFloat = 1.5                   // 选区 outline
        static let outlineSoftRing: CGFloat = 3.5                // 3.5pt soft 外圈
        static let outlineSoftAlpha: CGFloat = 0.14
        static let bottomAutoComposeDelay: TimeInterval = 0.6    // 到底 0.6s 自动合成
        // ⚠️ 2 样本 @0.4s = 静止 0.8s 就判到底（病例：用户进采集态后先读屏定位，
        // 还没开滚就自动合成单帧）——提到 4（静止 1.6s）才敢说「停止滚动」
        // 10（病例 2026-11-16「还是没拼接好」：0.12s 采样下 4 样本=0.48s 停顿
        // 就误判到底——用户滚动中松手换姿势即触发，长图只有 1-2 帧。
        // 0.12×10=1.2s 停顿才判到底（对齐 0.4s 时代 4 样本=1.6s 的设计意图）
        static let bottomConfirmSamples = 10
        static let sampleInterval: TimeInterval = 0.4            // 采样周期
        // 拼帧超时上限（病例：3840×2098 两帧 compose 卡 10s 后才 fail——超时
        // 直接回退单帧+恢复原选区，不让用户在无反馈的收尾期干等）
        static let composeTimeout: TimeInterval = 3
    }
}

// MARK: - 双层光学阴影宿主视图（紧贴接触影 + 柔和抬升影）

/// 为透明液态玻璃面板提供「紧贴接触影 + 柔和抬升影」：
///
/// - 使用独立子 `CALayer` 承载阴影（绕开 AppKit 对 `NSView.layer.shadowOpacity` 在 `addSubview` 时强制清零的坑）；
/// - 宿主覆盖含投影留白在内的整张外框，在宿主层挂载覆盖全边界的 `.evenOdd` 蒙版把玻璃圆角内部 100% 镂空，
///   使用 `RoundedRectangle(style: .continuous)` 精确对齐 `NSGlassEffectView` 的 `.continuous` 圆角曲率。
@MainActor
final class OuterShadowView: NSView {
    struct Spec {
        let contactRadius: CGFloat
        let contactOffset: CGSize
        let contactLightAlpha: CGFloat
        let contactDarkAlpha: CGFloat
        let ambientRadius: CGFloat
        let ambientOffset: CGSize
        let ambientInset: CGSize
        let ambientLightAlpha: CGFloat
        let ambientDarkAlpha: CGFloat

        static let toolbar = Spec(
            contactRadius: 1.2,
            contactOffset: CGSize(width: 0, height: -0.5),
            contactLightAlpha: 0.34,
            contactDarkAlpha: 0.54,
            ambientRadius: 8.5,
            ambientOffset: CGSize(width: 0, height: -3.0),
            ambientInset: CGSize(width: 1.5, height: 1.0),
            ambientLightAlpha: 0.18,
            ambientDarkAlpha: 0.34
        )

        static let pill = Spec(
            contactRadius: 1.1,
            contactOffset: CGSize(width: 0, height: -0.5),
            contactLightAlpha: 0.32,
            contactDarkAlpha: 0.52,
            ambientRadius: 6.5,
            ambientOffset: CGSize(width: 0, height: -2.5),
            ambientInset: CGSize(width: 1.0, height: 0.8),
            ambientLightAlpha: 0.17,
            ambientDarkAlpha: 0.32
        )

        static let spotlight = Spec(
            contactRadius: 1.3,
            contactOffset: CGSize(width: 0, height: -0.5),
            contactLightAlpha: 0.32,
            contactDarkAlpha: 0.54,
            ambientRadius: 12,
            ambientOffset: CGSize(width: 0, height: -5),
            ambientInset: CGSize(width: 2.0, height: 1.5),
            ambientLightAlpha: 0.20,
            ambientDarkAlpha: 0.38
        )
    }

    private let spec: Spec
    private let margin: CGFloat
    private let cornerRadius: CGFloat
    private let ambientLayer = CALayer()
    private let contactLayer = CALayer()
    private let cutoutMask = CAShapeLayer()

    init(spec: Spec, margin: CGFloat, cornerRadius: CGFloat) {
        self.spec = spec
        self.margin = margin
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        for l in [ambientLayer, contactLayer] {
            l.backgroundColor = NSColor.clear.cgColor
            l.shadowOpacity = 1
            layer?.addSublayer(l)
        }
        ambientLayer.shadowRadius = spec.ambientRadius
        ambientLayer.shadowOffset = spec.ambientOffset
        contactLayer.shadowRadius = spec.contactRadius
        contactLayer.shadowOffset = spec.contactOffset

        cutoutMask.fillRule = .evenOdd
        layer?.mask = cutoutMask
        refreshAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("OuterShadowView 只走代码创建") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        refreshGeometry()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    func refreshGeometry() {
        let panelRect = bounds.insetBy(dx: margin, dy: margin)
        guard panelRect.width > 2, panelRect.height > 2 else { return }

        let localPillRect = CGRect(origin: .zero, size: panelRect.size)
        let localPillPath = DesignTokens.Mat.continuousRoundedPath(in: localPillRect, cornerRadius: cornerRadius)
        let ambientRect = localPillRect.insetBy(dx: spec.ambientInset.width, dy: spec.ambientInset.height)
        let ambientCorner = max(1, cornerRadius - max(spec.ambientInset.width, spec.ambientInset.height))
        let ambientPath = DesignTokens.Mat.continuousRoundedPath(in: ambientRect, cornerRadius: ambientCorner)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        contactLayer.frame = panelRect
        contactLayer.shadowPath = localPillPath
        ambientLayer.frame = panelRect
        ambientLayer.shadowPath = ambientPath

        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        maskPath.addPath(DesignTokens.Mat.continuousRoundedPath(in: panelRect, cornerRadius: cornerRadius))
        cutoutMask.frame = bounds
        cutoutMask.path = maskPath

        CATransaction.commit()
    }

    private func refreshAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            let contactAlpha = isDark ? spec.contactDarkAlpha : spec.contactLightAlpha
            let ambientAlpha = isDark ? spec.ambientDarkAlpha : spec.ambientLightAlpha
            contactLayer.shadowColor = NSColor.black.withAlphaComponent(contactAlpha).cgColor
            ambientLayer.shadowColor = NSColor.black.withAlphaComponent(ambientAlpha).cgColor
        }
    }
}

// MARK: - 自适应圆角玻璃视图（自动应用 maskImage 消四角白边 + 跟随系统明暗刷新描边与顶缘镜面高光）

@MainActor
final class AdaptiveGlassView: NSVisualEffectView {
    private let cornerRadius: CGFloat
    private let strokeWidth: CGFloat
    private let dynamicStrokeColor: NSColor
    private let specularLayer = CAGradientLayer()

    init(cornerRadius: CGFloat, strokeWidth: CGFloat, dynamicStrokeColor: NSColor) {
        self.cornerRadius = cornerRadius
        self.strokeWidth = strokeWidth
        self.dynamicStrokeColor = dynamicStrokeColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = strokeWidth
        maskImage = DesignTokens.Mat.roundedMaskImage(cornerRadius: cornerRadius)

        if strokeWidth > 0 {
            specularLayer.startPoint = CGPoint(x: 0, y: 0.5)
            specularLayer.endPoint = CGPoint(x: 1, y: 0.5)
            specularLayer.locations = [0, 0.12, 0.88, 1]
            layer?.addSublayer(specularLayer)
        }
        refreshAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AdaptiveGlassView 只走代码创建") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let yPos = isFlipped ? 0.5 : max(0, bounds.height - 1.5)
        specularLayer.frame = CGRect(x: 0, y: yPos, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    func refreshAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            layer?.borderColor = dynamicStrokeColor.cgColor
            let hiAlpha = isDark ? DesignTokens.Inset.hiAlpha.0 : DesignTokens.Inset.hiAlpha.1
            specularLayer.colors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(hiAlpha).cgColor,
                NSColor.white.withAlphaComponent(hiAlpha).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ]
        }
    }
}

// MARK: - 按钮居中缩放按压反馈辅助（Emil Craft：scale(0.97) 120ms ease-out）

@MainActor
enum TactilePress {
    /// 以视图中心为锚点施加缩放动画（不破坏 AppKit 默认 (0,0) anchorPoint 的 frame 布局）
    static func animate(view: NSView, pressed: Bool, scale: CGFloat = DesignTokens.Motion.pressScale) {
        guard !DesignTokens.Motion.reduceMotion, let layer = view.layer else { return }
        let b = view.bounds
        guard b.width > 0, b.height > 0 else { return }
        let target: CATransform3D
        if pressed {
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, b.midX, b.midY, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
            target = t
        } else {
            target = CATransform3DIdentity
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(DesignTokens.Motion.pressDuration)
        CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        layer.transform = target
        CATransaction.commit()
    }
}

// MARK: - NSAppearance 暗色判定（动态色 provider 用）

extension NSAppearance {
    /// 当前外观是否暗色（darkAqua / darkVibrant 族）
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua }
            ?? true
    }
}
