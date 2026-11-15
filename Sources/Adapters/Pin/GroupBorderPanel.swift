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
@MainActor
final class GroupBorderView: NSView {
    static let accent = NSColor(srgbRed: 0.298, green: 0.553, blue: 1.0, alpha: 1) // #4C8DFF
    /// 命中边框带宽度（pt）；窗体 = union rect 外扩 10 ⇒ 内区不含成员卡
    static let bandWidth: CGFloat = 10

    weak var panel: GroupBorderPanel?
    var memberCount: Int = 0
    private let assembleButton = NSButton(title: "⟐ 合成整体", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        assembleButton.isBordered = false
        assembleButton.wantsLayer = true
        assembleButton.layer?.cornerRadius = 11
        assembleButton.layer?.backgroundColor = Self.accent.cgColor
        assembleButton.layer?.shadowColor = Self.accent.cgColor
        assembleButton.layer?.shadowOpacity = 0.45
        assembleButton.layer?.shadowRadius = 5
        assembleButton.layer?.shadowOffset = CGSize(width: 0, height: -3)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        assembleButton.attributedTitle = NSAttributedString(
            string: "⟐ 合成整体",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
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

    /// 按钮贴框顶右（徽标旁）：翻转坐标下 y=2 顶对齐
    func layoutAssembleButton() {
        let size = assembleButton.intrinsicContentSize
        let width = max(size.width + 16, 78)
        assembleButton.frame = NSRect(
            x: bounds.width - width - 14,
            y: 2,
            width: width,
            height: 22
        )
    }

    // MARK: - 命中：边框带 / 徽标 / 按钮吃事件，成员区穿透

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        // 按钮等子控件优先
        if let hit = super.hitTest(point), hit !== self { return hit }
        // 边框带（外圈 bandWidth）+ 徽标区吃事件；成员卡区域穿透
        let inner = bounds.insetBy(dx: Self.bandWidth, dy: Self.bandWidth)
        return inner.contains(local) ? nil : self
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

    /// 徽标矩形（框顶左，骑在边框上）
    private func badgeRect() -> NSRect {
        let text = "拼贴空间 · \(memberCount) 张"
        let size = (text as NSString).size(withAttributes: Self.badgeAttributes)
        return NSRect(x: 14, y: 1, width: ceil(size.width) + 16, height: 16)
    }

    private static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 虚线组框（骑窗体边缘内缩 1pt）
        let frameRect = bounds.insetBy(dx: 1, dy: 1)
        let path = CGPath(
            roundedRect: frameRect,
            cornerWidth: 14, cornerHeight: 14,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(Self.accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.strokePath()
        ctx.restoreGState()

        // 组框内部淡蓝底（成员区穿透点击，纯视觉）
        ctx.saveGState()
        ctx.addPath(CGPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 2),
            cornerWidth: 13, cornerHeight: 13, transform: nil
        ))
        ctx.clip()
        ctx.setFillColor(Self.accent.withAlphaComponent(0.04).cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        // 「拼贴空间 · N 张」徽标
        let badge = badgeRect()
        let badgePath = CGPath(
            roundedRect: badge, cornerWidth: 8, cornerHeight: 8, transform: nil
        )
        ctx.setFillColor(Self.accent.withAlphaComponent(0.92).cgColor)
        ctx.addPath(badgePath)
        ctx.fillPath()
        let text = "拼贴空间 · \(memberCount) 张"
        let textSize = (text as NSString).size(withAttributes: Self.badgeAttributes)
        (text as NSString).draw(
            at: CGPoint(x: badge.minX + 8, y: badge.minY + (badge.height - textSize.height) / 2),
            withAttributes: Self.badgeAttributes
        )
    }
}
