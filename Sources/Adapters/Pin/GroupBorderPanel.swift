import AppKit
import CoreGraphics

/// 组框覆盖窗（设计定稿 §1.3）：每组建一个附属透明 NSPanel。
///
/// - `.borderless + .nonactivatingPanelMask`，level = floating+1（盖住成员 pin）
/// - 绘制：虚线组框 + 「拼贴空间 · N 张」徽标 + 「⟐ 合成整体」按钮（框顶右）
/// - 命中区（§风险兜底）：只有边框带 10pt + 徽标 + 按钮吃事件，
///   成员卡区域 hitTest 返回 nil 穿透给下面的 pin 窗
/// - 拖空白处（边框带/徽标区）= 整组刚体移动（转发给 PinMagnetRegistry，含磁吸）
@MainActor
final class GroupBorderPanel: NSPanel {
    let groupID: Int

    /// 「⟐ 合成整体」按钮回调（PinMagnetRegistry.assemble）
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

    /// 「⟐ 合成整体」按钮 target/action 入口
    @objc func handleAssemble() {
        onAssemble?()
    }

    /// 布局刷新（registry 每次 union rect 重算后调用）
    func refresh(count: Int) {
        borderView.memberCount = count
        borderView.needsDisplay = true
        borderView.layoutAssembleButton()
    }
}

/// 组框内容视图：虚线框 + 徽标 + 合成按钮；命中区 = 边框带 + 徽标 + 按钮
///
/// token（重设计 scene 04）：虚线 1.5pt dash 5/4 accent α.75、组内蓝 α.03、
/// 徽标 22 高 radius 11 accent 实心 10.5/600、合成键 24 高 radius 12 accent 实心
/// 11.5/600 **无光晕**；accent 统一 system blue（原 #4C8DFF 删除）。
/// ⚠️ 尺寸偏差说明：设计稿徽标/按钮骑在框顶（y −10/−11），但面板窗体只外扩
/// 10pt 且虚线画在窗缘 —— 骑顶会裁出窗外，故贴框内侧摆放（视觉差异微小）。
@MainActor
final class GroupBorderView: NSView {
    /// 唯一强调色（token accent，随外观解析暗 #0A84FF / 亮 #007AFF）
    static let accent = DesignTokens.accent
    /// 命中边框带宽度（pt）；窗体 = union rect 外扩 10 ⇒ 内区不含成员卡
    static let bandWidth: CGFloat = 10

    weak var panel: GroupBorderPanel?
    var memberCount: Int = 0
    private let assembleButton = NSButton(title: "合成整体", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        assembleButton.isBordered = false
        assembleButton.wantsLayer = true
        assembleButton.layer?.cornerRadius = DesignTokens.Radius.assemble
        assembleButton.layer?.backgroundColor = Self.accent.cgColor
        // 无光晕：删旧蓝色 shadow（迁移差异 §10-4）
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        assembleButton.attributedTitle = NSAttributedString(
            string: "合成整体",
            attributes: [
                .font: DesignTokens.GroupFrame.assembleFont,
                .foregroundColor: DesignTokens.labelOnAccent,
                .paragraphStyle: para,
            ]
        )
        assembleButton.setButtonType(.momentaryPushIn)
        addSubview(assembleButton)
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
        layoutAssembleButton()
    }

    /// 按钮贴框顶右：24 高 radius 12，右缘 12
    func layoutAssembleButton() {
        let size = assembleButton.intrinsicContentSize
        let width = max(size.width + 24, 92)
        assembleButton.frame = NSRect(
            x: bounds.width - width - 12,
            y: 2,
            width: width,
            height: DesignTokens.GroupFrame.assembleHeight
        )
    }

    // MARK: - 命中：边框带 / 徽标 / 按钮吃事件，成员区穿透

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        // 按钮等子控件优先
        if let hit = super.hitTest(point), hit !== self { return hit }
        // 边框带（外圈 bandWidth）+ 徽标区吃事件；成员卡区域穿透
        // reviewer 补丁：徽标是纯绘制（非子视图），必须给显式命中矩形——
        // 否则徽标下半部（band 之外）穿透，与注释「徽标区吃事件」不符
        let inner = bounds.insetBy(dx: Self.bandWidth, dy: Self.bandWidth)
        if !inner.contains(local) { return self }
        return badgeRect().contains(local) ? self : nil
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

    /// 徽标矩形（框顶左）
    private func badgeRect() -> NSRect {
        let text = "拼贴空间 · \(memberCount) 张"
        let size = (text as NSString).size(withAttributes: Self.badgeAttributes)
        return NSRect(x: 14, y: 2, width: ceil(size.width) + 24, height: DesignTokens.GroupFrame.badgeHeight)
    }

    private static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: DesignTokens.GroupFrame.badgeFont,
        .foregroundColor: DesignTokens.labelOnAccent,
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 虚线组框（骑窗体边缘内缩 1pt）：1.5pt dash 5/4 accent α.75
        let frameRect = bounds.insetBy(dx: 1, dy: 1)
        let path = CGPath(
            roundedRect: frameRect,
            cornerWidth: 14, cornerHeight: 14,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(Self.accent.withAlphaComponent(DesignTokens.GroupFrame.dashAlpha).cgColor)
        ctx.setLineWidth(DesignTokens.GroupFrame.dashWidth)
        ctx.setLineDash(phase: 0, lengths: DesignTokens.GroupFrame.dashPattern)
        ctx.strokePath()
        ctx.restoreGState()

        // 组框内部淡蓝底（α .03，成员区穿透点击，纯视觉）
        ctx.saveGState()
        ctx.addPath(CGPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 2),
            cornerWidth: 13, cornerHeight: 13, transform: nil
        ))
        ctx.clip()
        ctx.setFillColor(Self.accent.withAlphaComponent(DesignTokens.GroupFrame.innerTintAlpha).cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        // 「拼贴空间 · N 张」徽标：22 高 radius 11 accent 实心
        let badge = badgeRect()
        let badgePath = CGPath(
            roundedRect: badge, cornerWidth: DesignTokens.Radius.badge,
            cornerHeight: DesignTokens.Radius.badge, transform: nil
        )
        ctx.setFillColor(Self.accent.withAlphaComponent(0.92).cgColor)
        ctx.addPath(badgePath)
        ctx.fillPath()
        let text = "拼贴空间 · \(memberCount) 张"
        let textSize = (text as NSString).size(withAttributes: Self.badgeAttributes)
        (text as NSString).draw(
            at: CGPoint(x: badge.minX + 12, y: badge.minY + (badge.height - textSize.height) / 2),
            withAttributes: Self.badgeAttributes
        )
    }
}
