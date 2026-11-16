import AppKit
import CoreGraphics

/// 组框覆盖窗（重设计真源：snapcut-collage-ui/index.html「现状 vs 重设计」右栏）：
/// 每组建一个附属透明 NSPanel。
///
/// - `.borderless + .nonactivatingPanelMask`，level = floating+1（盖住成员 pin）
/// - 视觉（Stage Manager 语气）：0.5pt 极细实线组框（暗 白.26 / 亮 黑.18，corner 12）
///   + 框顶 1pt 渐隐高光；删除 1.5pt 虚线与组内 α.03 蓝底
/// - 浮标骑框顶外 −11pt：玻璃徽标「拼贴 N」（mat.hud + label-1 + tabular-nums）
///   + accent 合成钮（22pt / r7 / SF Symbol arrow.triangle.merge / inset-hi-strong）——
///   全画面唯一 accent（徽标降级玻璃后蓝块 ×2 → ×1）
/// - 窗体外扩 22pt（原 10 骑顶裁切病例修复，GroupFrame.panelOutset）
/// - 命中区：框线 ±10pt 边框带 + 徽标 + 按钮吃事件，成员卡区域 hitTest 返回 nil
///   穿透给下面的 pin 窗
/// - 拖边框带/徽标区 = 整组刚体移动（转发给 PinMagnetRegistry，含磁吸）
@MainActor
final class GroupBorderPanel: NSPanel {
    let groupID: Int

    /// 「合成」按钮回调（PinMagnetRegistry.assemble）
    var onAssemble: (() -> Void)?
    /// 边框带按下/拖动/松手（整组移动）
    var onDragBegin: (() -> Void)?
    var onDragMoved: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var borderView: GroupBorderView {
        contentView as! GroupBorderView
    }

    init(groupID: Int) {
        self.groupID = groupID
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false

        let view = GroupBorderView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.panel = self
        view.connectAssembleAction(to: self)
        contentView = view
    }

    /// 「合成」按钮 target/action 入口
    @objc func handleAssemble() {
        onAssemble?()
    }

    /// 布局刷新（registry 每次 union rect 重算后调用）
    func refresh(count: Int) {
        borderView.memberCount = count
        borderView.refreshBadgeText()
        borderView.needsDisplay = true
        borderView.layoutChrome()
    }
}

/// 组框内容视图：0.5pt 极细框 + 玻璃徽标 + accent 合成按钮；
/// 命中区 = 框线 ±10pt 边框带 + 徽标 + 按钮，成员卡区域穿透。
///
/// token（snapcut-collage-ui §06 差异清单）：组框 0.5pt 实线 白.26/黑.18、corner 12；
/// 徽标 mat.hud 玻璃胶囊 22 高 radius 11 + 0.5pt 白.16 stroke + label-1「拼贴 N」
/// tabular-nums；合成钮 22 高 radius 7 + SF Symbol arrow.triangle.merge + 11/500
/// + inset-hi-strong + hover accent-hover。
@MainActor
final class GroupBorderView: NSView {
    /// 命中边框带宽度（pt）：骑在框线上，内外各 10pt
    static let bandWidth: CGFloat = 10

    weak var panel: GroupBorderPanel?
    var memberCount: Int = 0

    /// 组框矩形（= 成员 union rect）：窗体外扩 GroupFrame.panelOutset
    private var frameRect: NSRect {
        let outset = DesignTokens.GroupFrame.panelOutset
        return bounds.insetBy(dx: outset, dy: outset)
    }

    private let badgeView: NSVisualEffectView
    private let badgeField = NSTextField(labelWithString: "")
    private let assembleButton = NSButton(title: "合成", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        // 徽标容器：mat.hud 玻璃胶囊（钉暗策略由面板 appearance 负责）+ 0.5pt 白.16 stroke
        badgeView = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: DesignTokens.Radius.badge,
            strokeWidth: 0.5,
            strokeColor: DesignTokens.GroupFrame.badgeStroke
        )
        super.init(frame: frame)
        wantsLayer = true

        // 玻璃徽标：「拼贴 N」label-1 + 数字 tabular-nums（文案 6 字 → 3 字符级）
        badgeField.isEditable = false
        badgeField.isBordered = false
        badgeField.drawsBackground = false
        badgeField.alignment = .center
        refreshBadgeText()
        badgeView.addSubview(badgeField)
        addSubview(badgeView)
        DesignTokens.Inset.installHighlight(on: badgeView, alpha: DesignTokens.Inset.hiAlpha.0)

        // 合成按钮：SF Symbol arrow.triangle.merge + 「合成」（tooltip 语境给全称），
        // accent 实心玻璃——全画面唯一 accent；22 高 / r7 / inset-hi-strong / hover accent-hover
        assembleButton.isBordered = false
        assembleButton.imagePosition = .imageLeading
        assembleButton.wantsLayer = true
        assembleButton.layer?.cornerRadius = DesignTokens.Radius.md
        assembleButton.layer?.masksToBounds = true
        assembleButton.layer?.backgroundColor = DesignTokens.accent.cgColor
        if let symbol = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: "合成") {
            assembleButton.image = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            )
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        assembleButton.attributedTitle = NSAttributedString(
            string: "合成",
            attributes: [
                .font: DesignTokens.GroupFrame.assembleFont,
                .foregroundColor: DesignTokens.labelOnAccent,
                .paragraphStyle: para,
            ]
        )
        assembleButton.setButtonType(.momentaryPushIn)
        addSubview(assembleButton)
        DesignTokens.Inset.installHighlight(on: assembleButton, alpha: DesignTokens.Inset.strongAlpha)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GroupBorderView 只走代码创建") }

    /// panel 挂接按钮 target/action（view 创建于 panel.init 内，此时 self 已可用）
    func connectAssembleAction(to panel: GroupBorderPanel) {
        assembleButton.target = panel
        assembleButton.action = #selector(GroupBorderPanel.handleAssemble)
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    /// 徽标文字：「拼贴 N」（label-1 caption 500 + 等宽数字 600）
    func refreshBadgeText() {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "拼贴 ", attributes: [
            .font: DesignTokens.GroupFrame.badgeFont,
            .foregroundColor: DesignTokens.label1,
        ]))
        text.append(NSAttributedString(string: "\(memberCount)", attributes: [
            .font: DesignTokens.GroupFrame.badgeNumberFont,
            .foregroundColor: DesignTokens.label1,
        ]))
        badgeField.attributedStringValue = text
    }

    /// 浮标骑框顶外 −11pt：徽标框顶左 +12、合成钮框顶右 −12
    func layoutChrome() {
        let ride = DesignTokens.GroupFrame.rideOffset
        let textSize = badgeField.attributedStringValue.size()
        let badgeWidth = ceil(textSize.width) + 22   // 左右各 11pt 内距
        badgeView.frame = NSRect(
            x: frameRect.minX + 12,
            y: frameRect.minY - ride,
            width: badgeWidth,
            height: DesignTokens.GroupFrame.badgeHeight
        )
        // 文字在胶囊内手工居中（不依赖 NSTextField 垂直对齐默认值）
        badgeField.frame = NSRect(
            x: 11,
            y: (DesignTokens.GroupFrame.badgeHeight - ceil(textSize.height)) / 2,
            width: ceil(textSize.width),
            height: ceil(textSize.height)
        )

        let size = assembleButton.intrinsicContentSize
        let buttonWidth = max(ceil(size.width) + 20, 72)
        assembleButton.frame = NSRect(
            x: frameRect.maxX - buttonWidth - 12,
            y: frameRect.minY - ride,
            width: buttonWidth,
            height: DesignTokens.GroupFrame.assembleHeight
        )
        updateButtonTracking()
    }

    // MARK: - 合成钮 hover（accent → accent-hover，0.15s fill 变化）

    private func updateButtonTracking() {
        let rect = assembleButton.frame
        for area in trackingAreas where area.owner === self {
            if area.rect == rect { return }
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        assembleButton.layer?.backgroundColor = DesignTokens.accentHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        assembleButton.layer?.backgroundColor = DesignTokens.accent.cgColor
    }

    // MARK: - 命中：框线 ±10pt 边框带 / 徽标 / 按钮吃事件，成员区穿透

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        // 徽标/按钮子控件优先
        if let hit = super.hitTest(point), hit !== self { return hit }
        // 框线 ±bandWidth 边框带吃事件；成员卡区域穿透
        let outer = frameRect.insetBy(dx: -Self.bandWidth, dy: -Self.bandWidth)
        let inner = frameRect.insetBy(dx: Self.bandWidth, dy: Self.bandWidth)
        if outer.contains(local) && !inner.contains(local) { return self }
        return nil
    }

    // MARK: - 整组拖动（转发 registry）

    override func mouseDown(with event: NSEvent) {
        panel?.onDragBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        panel?.onDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        panel?.onDragEnd?()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = frameRect
        let r = DesignTokens.GroupFrame.cornerRadius
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

        // Stage Manager 式 0.5pt 极细实线（暗 白.26 / 亮 黑.18）
        // ——「这是一组」由一根线说清：1.5pt 虚线与组内 α.03 蓝底整体删除
        ctx.addPath(path)
        ctx.setStrokeColor(DesignTokens.GroupFrame.stroke.cgColor)
        ctx.setLineWidth(DesignTokens.GroupFrame.strokeWidth)
        ctx.strokePath()

        // 框顶 1pt 渐隐高光（gframe-new ::before：白 .10 沿 22% 高度渐隐到透明）
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(1)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let colors = [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.22),
                options: []
            )
        }
        ctx.restoreGState()
    }
}
