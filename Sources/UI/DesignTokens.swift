import AppKit

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

        /// 统一玻璃容器配方：三档材质 + blendingMode(.behindWindow) + active +
        /// 圆角 + 0.5pt stroke 描边。钉暗由窗口 appearance 负责（本函数不碰 appearance）。
        static func glass(
            material: NSVisualEffectView.Material,
            cornerRadius: CGFloat,
            strokeWidth: CGFloat = 0.5,
            strokeColor: NSColor? = nil
        ) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = material
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = strokeWidth
            v.layer?.borderColor = (strokeColor ?? DesignTokens.stroke).cgColor
            return v
        }
    }

    // MARK: - 内高光（inset.hi / inset.hi.strong）

    @MainActor
    enum Inset {
        /// inset.hi：顶缘 1pt 白 .10（亮色 .65）渐隐高光
        static let hiAlpha: (CGFloat, CGFloat) = (0.10, 0.65)
        /// inset.hi.strong：accent 实心控件顶缘白 .16
        static let strongAlpha: CGFloat = 0.16

        /// 给圆角容器加顶缘内高光：1pt 高渐变层（两端用 CAGradientLayer 渐隐），
        /// 需在 wantsLayer + masksToBounds 的容器内添加（贴描边下沿）。
        static func installHighlight(on container: NSView, alpha: CGFloat, topInset: CGFloat = 0.5) {
            let g = CAGradientLayer()
            g.frame = CGRect(x: 0, y: topInset, width: container.bounds.width, height: 1)
            g.autoresizingMask = [.layerWidthSizable]
            g.colors = [
                NSColor.white.withAlphaComponent(alpha).cgColor,
                NSColor.white.withAlphaComponent(alpha * 0.35).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ]
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            g.locations = [0, 0.18, 1]
            container.layer?.addSublayer(g)
        }
    }

    // MARK: - 3. 投影（克制，贴近 NSWindow 系统阴影；AppKit y 向下 ⇒ CSS offset 取负）

    @MainActor
    enum Shadow {
        /// shadow.float：单层 0 18 44 −20 .30（「高而淡」，贴合系统浮窗单层影）
        /// 轻盈感审查：双层 r15/α.50 + r32/α.55 叠加合成峰值 ≈.7+，比系统浮窗还沉 → 砍单层
        static let float = [
            LayerShadow(radius: 44, offset: CGSize(width: 0, height: -18), alpha: 0.30, spread: 20),
        ]
        /// shadow.card：0 6 16 −8 .28（单层，层级低于 float；卡片类浮层复用）
        static let card = LayerShadow(radius: 16, offset: CGSize(width: 0, height: -6), alpha: 0.28, spread: 8)
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

    // MARK: - 8. 动效

    enum Motion {
        /// motion.spring：0.22s cubic-bezier(.34,1.3,.5,1)（CaptureToast 手感，全产品统一）
        static let springDuration: TimeInterval = 0.22
        static let springControlPoints: (Float, Float, Float, Float) = (0.34, 1.3, 0.5, 1)
        /// motion.fade：0.20s 退场淡出
        static let fadeDuration: TimeInterval = 0.20
        /// motion.pulse：1.6s ease-in-out 往复（光晕 α .35↔.70），滚动采集边缘光晕
        static let pulseDuration: CFTimeInterval = 1.6
        static let pulseAlphaMin: Float = 0.35
        static let pulseAlphaMax: Float = 0.70
        /// hover 反馈 0.15s（不再上移）
        static let hoverDuration: CFTimeInterval = 0.15

        /// motion.enter：0.26s spring + rise 10pt + scale .97→1 + fade（贴边浮层入场：
        /// 工具栏/HUD/toast/文字件；入场 = fade + rise + scale 三件套）
        static let enterDuration: TimeInterval = 0.26
        static let enterRise: CGFloat = 10
        static let enterScale: CGFloat = 0.97
        /// motion.enter.center：0.28s spring + rise 10pt + scale .96→1（居中卡入场：引导卡）
        static let enterCenterDuration: TimeInterval = 0.28
        static let enterCenterScale: CGFloat = 0.96
        /// motion.exit：0.16s ease-in + sink 4pt + scale→.97 + fade（一切退场；
        /// 杜绝 orderOut 直切。toast 下滑 6pt / 引导卡下沉 6pt 用同 token 另调 sink）
        static let exitDuration: TimeInterval = 0.16
        static let exitSink: CGFloat = 4
        static let exitScale: CGFloat = 0.97
        /// motion.crossfade：0.15s ease-out（内容态/页面切换：设置 tab、HUD 三态）
        static let crossfadeDuration: TimeInterval = 0.15

        /// 统一 spring timing（NSAnimationContext / CATransaction 共用）
        nonisolated(unsafe) static let springTimingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.5, 1)
    }

    // MARK: - 工具栏规格（§9 场景速查）

    enum Toolbar {
        static let height: CGFloat = 56
        static let padding: CGFloat = 10
        static let groupGap: CGFloat = 8
        /// 组间 hairline 两侧各 4（叠加 stack 8 ⇒ 线到内容 12）
        static let separatorMargin: CGFloat = 4
        static let separatorHeight: CGFloat = 20
        static let iconIdleAlpha: CGFloat = 0.85
        static let iconDisabledAlpha: CGFloat = 0.28
        static let dotSide: CGFloat = 14
        static let dotGap: CGFloat = 6
        static let copyButtonSide: CGFloat = 32   // 2026-11-17 重设计：与工具按钮同步 32（全条一致）
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

// MARK: - NSAppearance 暗色判定（动态色 provider 用）

extension NSAppearance {
    /// 当前外观是否暗色（darkAqua / darkVibrant 族）
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua }
            ?? true
    }
}
