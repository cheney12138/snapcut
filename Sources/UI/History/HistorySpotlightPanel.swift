import AppKit

/// Apple Liquid Glass Spotlight 风格视觉记忆速搜浮窗（T2.3）
///
/// 设计要点：
/// - 零外部直连：不 import Vision / ScreenCaptureKit，也不直连 HistoryStore，所有数据与动作经 Callbacks 注入；
/// - 明暗自适应：面板不钉暗色外观，采用 `DesignTokens.Mat.liquidGlass(..., style: .clear)`（macOS 26 原生液态玻璃 / macOS 15 自动回落 `AdaptiveGlassView`）；
/// - 焦点严谨：呼出前记录 `previousApp`（含 PID），激活面板并聚焦搜索框即刻盲打；关闭/执行动作后稳妥归还焦点（`onReopenEdit` 例外，将焦点留给即将打开的编辑器）；
/// - 零闪烁刷新：`reloadIfVisible()` 保留滚动偏移与尽量保留当前选中项，后台 OCR 索引就绪时无闪烁增量更新。
@MainActor
final class HistorySpotlightPanel: NSObject {
    static let shared = HistorySpotlightPanel()

    struct Callbacks {
        var loadRecords: @MainActor () -> [HistoryRecord]
        /// 纯内存查询（0 磁盘 I/O）：同步布局阶段只允许调它，命中不了就先用占位
        var cachedThumbnail: @MainActor (HistoryRecord, CGFloat) -> NSImage?
        /// 异步加载：未命中缓存的缩略图在后台解码，回主线程交给面板
        var loadThumbnailAsync: @MainActor (HistoryRecord, CGFloat) async -> NSImage?
        var onCopyImage: @MainActor (HistoryRecord) -> Void
        var onReopenEdit: @MainActor (HistoryRecord) -> Void
        var onPin: @MainActor (HistoryRecord) -> Void
        var onCopyOCRText: @MainActor (HistoryRecord) -> Void
        var onDismiss: (@MainActor () -> Void)?

        init(
            loadRecords: @escaping @MainActor () -> [HistoryRecord],
            cachedThumbnail: @escaping @MainActor (HistoryRecord, CGFloat) -> NSImage?,
            loadThumbnailAsync: @escaping @MainActor (HistoryRecord, CGFloat) async -> NSImage?,
            onCopyImage: @escaping @MainActor (HistoryRecord) -> Void,
            onReopenEdit: @escaping @MainActor (HistoryRecord) -> Void,
            onPin: @escaping @MainActor (HistoryRecord) -> Void,
            onCopyOCRText: @escaping @MainActor (HistoryRecord) -> Void,
            onDismiss: (@MainActor () -> Void)? = nil
        ) {
            self.loadRecords = loadRecords
            self.cachedThumbnail = cachedThumbnail
            self.loadThumbnailAsync = loadThumbnailAsync
            self.onCopyImage = onCopyImage
            self.onReopenEdit = onReopenEdit
            self.onPin = onPin
            self.onCopyOCRText = onCopyOCRText
            self.onDismiss = onDismiss
        }
    }

    // MARK: - 布局规格

    private enum Spec {
        static let panelWidth: CGFloat = 760
        static let panelHeight: CGFloat = 500
        static let shadowMargin: CGFloat = 20
        static let cornerRadius: CGFloat = 18
        static let searchBarHeight: CGFloat = 54
        static let footerHeight: CGFloat = 42
        static let columns: Int = 3
        static let gridPaddingH: CGFloat = 16
        static let gridPaddingV: CGFloat = 12
        static let gridGapH: CGFloat = 12
        static let gridGapV: CGFloat = 12
        static let cardHeight: CGFloat = 188
        static let thumbMaxSide: CGFloat = 440
    }

    // MARK: - 状态

    private var callbacks: Callbacks?
    private var panel: SpotlightPanelWindow?
    private var outerShadowView: OuterShadowView?
    private var panelRoot: NSView?
    private var contentHost: NSView?

    private var searchField: NSTextField!
    private var countBadgeView: SpotlightBadgeView!
    private var countLabel: NSTextField!
    private var clearButton: SpotlightIconButton!
    private var scrollView: NSScrollView!
    private var gridDocumentView: SpotlightFlippedView!
    private var emptyStateView: SpotlightEmptyStateView!

    private var footerReopenButton: SpotlightActionButton!
    private var footerPinButton: SpotlightActionButton!
    private var footerCopyTextButton: SpotlightActionButton!
    private var footerView: NSView!
    private var hintsStack: NSStackView?
    private var actionsStack: NSStackView!

    private var allRecords: [HistoryRecord] = []
    private var matches: [HistorySearchMatch] = []
    private var selectedIndex: Int?
    private var cardPool: [HistoryCardView] = []
    private var thumbnailCache: [String: NSImage] = [:]

    /// 本轮异步补图任务（每次重新 applySearch / dismiss 都要取消上一轮）
    private var thumbnailLoadTask: Task<Void, Never>?

    private var isPresented = false
    private var isContextMenuOpen = false
    private var presentationEpoch = 0
    private var previousApp: NSRunningApplication?
    private var previousAppPID: Int?
    private var keyMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private override init() {
        super.init()
    }

    // MARK: - 公开 API

    var isVisible: Bool {
        isPresented && (panel?.isVisible ?? false)
    }

    func toggle(callbacks: Callbacks) {
        if isVisible {
            dismiss()
        } else {
            show(callbacks: callbacks)
        }
    }

    func show(callbacks: Callbacks) {
        self.callbacks = callbacks
        ensurePanelBuilt()
        guard let panel else { return }

        if !isPresented {
            capturePreviousApplication()
        }

        presentationEpoch += 1
        isPresented = true
        isContextMenuOpen = false

        // 定位到鼠标所在屏幕可见区域居中偏上（先确定面板宽度，再刷新网格布局）
        let targetFrame = computePanelFrame()
        let reduce = DesignTokens.Motion.reduceMotion
        if !reduce {
            panel.setFrame(
                NSRect(
                    x: targetFrame.minX,
                    y: targetFrame.minY - DesignTokens.Motion.enterRise,
                    width: targetFrame.width,
                    height: targetFrame.height
                ),
                display: false
            )
        } else {
            panel.setFrame(targetFrame, display: false)
        }
        panel.alphaValue = 0

        // 清空上次搜索词，刷新最新快捷键提示，重新加载全量记录并默认高亮第一项
        rebuildHintsStack()
        searchField.stringValue = ""
        allRecords = callbacks.loadRecords()
        // 只剔除已不存在记录的失效缩略图，其余保留（上一轮的图直接复用，免二次解码）
        let validIDs = Set(allRecords.map(\.id))
        thumbnailCache = thumbnailCache.filter { validIDs.contains($0.key) }
        applySearch(query: "", preferredRecordID: nil, preserveScroll: false)

        installEventMonitors()

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        focusSearchField()
        let activeEpoch = presentationEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.presentationEpoch == activeEpoch else { return }
            self.focusSearchField()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 1
            if !reduce {
                panel.animator().setFrame(targetFrame, display: true)
            }
        }

        Log.event(.history, "spotlight.show", ["records": "\(allRecords.count)"])
    }

    func dismiss() {
        dismissInternal(restoreFocus: true, notifyDismiss: true)
    }

    /// 外部历史/OCR 索引更新时，如果面板正打开则无闪烁刷新列表并尽量保留当前选中项
    func reloadIfVisible() {
        guard isVisible, let callbacks else { return }
        let previousSelectedID = selectedMatch?.record.id
        allRecords = callbacks.loadRecords()

        // 仅清理已不存在记录的缩略图缓存，保留现有图片避免重绘闪烁
        let validIDs = Set(allRecords.map(\.id))
        thumbnailCache = thumbnailCache.filter { validIDs.contains($0.key) }

        applySearch(
            query: searchField.stringValue,
            preferredRecordID: previousSelectedID,
            preserveScroll: true
        )
    }

    // MARK: - 面板构建

    private func ensurePanelBuilt() {
        guard panel == nil else { return }

        let m = Spec.shadowMargin
        let initialSize = NSSize(width: Spec.panelWidth + m * 2, height: Spec.panelHeight + m * 2)

        let window = SpotlightPanelWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.delegate = self
        window.keyEquivalentHandler = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }

        let outer = SpotlightOuterView(frame: NSRect(origin: .zero, size: initialSize))
        outer.wantsLayer = true

        let shadowHost = OuterShadowView(spec: .spotlight, margin: m, cornerRadius: Spec.cornerRadius)
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(shadowHost)
        outerShadowView = shadowHost
        NSLayoutConstraint.activate([
            shadowHost.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            shadowHost.topAnchor.constraint(equalTo: outer.topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
        ])

        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(root)
        outer.panelRootView = root

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: m),
            root.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -m),
            root.topAnchor.constraint(equalTo: outer.topAnchor, constant: m),
            root.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -m),
        ])

        let glassSurface = DesignTokens.Mat.liquidGlass(
            cornerRadius: Spec.cornerRadius,
            style: .clear,
            tintColor: DesignTokens.Mat.crystalGlassTint,
            fallbackMaterial: .hudWindow
        )

        let glassHost = glassSurface.hostView
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glassHost)

        // 前景内容放到与 glassHost 同级的独立宿主上，隔离 macOS 26 NSGlassEffectView.contentView
        // 随背景亮度自动反转图标/模板图颜色的自适应活力渲染，确保全浅色外观在任何背景下稳如磐石。
        let foregroundHost = NSView()
        foregroundHost.wantsLayer = true
        foregroundHost.appearance = NSAppearance(named: .aqua)
        foregroundHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(foregroundHost)

        NSLayoutConstraint.activate([
            glassHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glassHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glassHost.topAnchor.constraint(equalTo: root.topAnchor),
            glassHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            foregroundHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            foregroundHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            foregroundHost.topAnchor.constraint(equalTo: root.topAnchor),
            foregroundHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        buildContentHierarchy(in: foregroundHost)

        window.contentView = outer
        panel = window
        panelRoot = root
        contentHost = foregroundHost

        outer.layoutSubtreeIfNeeded()
        shadowHost.refreshGeometry()
    }

    private func buildContentHierarchy(in container: NSView) {
        // 1) 顶部搜索栏（整行可点击聚焦到搜索框）
        let searchBar = SpotlightSearchBarView()
        searchBar.onClickEmptyArea = { [weak self] in
            self?.focusSearchField()
        }
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchBar)

        let searchIcon = NSImageView()
        searchIcon.image = TBIcon.symbolImage(named: "magnifyingglass", pointSize: 16, weight: .medium, hierarchical: false)
        searchIcon.contentTintColor = DesignTokens.label2
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchIcon)

        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.allowsEditingTextAttributes = false
        field.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        field.textColor = DesignTokens.label1
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.alignment = .natural
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.placeholderAttributedString = NSAttributedString(
            string: "搜索历史截图文字、应用名或时间…",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: DesignTokens.label3,
            ]
        )
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(field)
        searchField = field

        let badge = SpotlightBadgeView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let badgeText = NSTextField(labelWithString: "0 条")
        badgeText.font = DesignTokens.Font.monoDigit(11.5)
        badgeText.textColor = DesignTokens.label2
        badgeText.setContentHuggingPriority(.required, for: .horizontal)
        badgeText.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeText.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeText)
        countBadgeView = badge
        countLabel = badgeText

        let clear = SpotlightIconButton(
            symbol: "xmark.circle.fill",
            pointSize: 14,
            tooltip: "清空搜索"
        ) { [weak self] in
            self?.clearSearchTapped()
        }
        clear.isHidden = true
        clear.translatesAutoresizingMaskIntoConstraints = false
        clearButton = clear

        let trailingStack = NSStackView(views: [badge, clear])
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 8
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchBar.addSubview(trailingStack)

        let topDivider = SpotlightHairlineView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topDivider)

        // 2) 中央 3 列滚动网格区
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        scrollView = scroll

        let doc = SpotlightFlippedView(frame: NSRect(x: 0, y: 0, width: Spec.panelWidth, height: 300))
        scroll.documentView = doc
        gridDocumentView = doc

        let empty = SpotlightEmptyStateView()
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(empty)
        emptyStateView = empty

        // 3) 底部快捷键提示条 + 鼠标快捷操作按钮
        let bottomDivider = SpotlightHairlineView()
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bottomDivider)

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)
        footerView = footer

        let reopenBtn = SpotlightActionButton(title: "重编", symbol: "pencil.and.outline") { [weak self] in
            self?.executeReopenEdit()
        }
        let pinBtn = SpotlightActionButton(title: "贴图", symbol: "pin") { [weak self] in
            self?.executePin()
        }
        let copyTextBtn = SpotlightActionButton(title: "复制文字", symbol: "text.viewfinder") { [weak self] in
            self?.executeCopyOCRText()
        }
        footerReopenButton = reopenBtn
        footerPinButton = pinBtn
        footerCopyTextButton = copyTextBtn

        let actionsStack = NSStackView(views: [reopenBtn, pinBtn, copyTextBtn])
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 6
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(actionsStack)
        self.actionsStack = actionsStack

        rebuildHintsStack()

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: container.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: Spec.searchBarHeight),

            searchIcon.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 18),
            searchIcon.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),

            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 26),
            field.trailingAnchor.constraint(equalTo: trailingStack.leadingAnchor, constant: -10),

            badgeText.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 8),
            badgeText.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -8),
            badgeText.topAnchor.constraint(equalTo: badge.topAnchor, constant: 3),
            badgeText.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -3),

            clear.widthAnchor.constraint(equalToConstant: 24),
            clear.heightAnchor.constraint(equalToConstant: 24),

            trailingStack.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -16),
            trailingStack.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            topDivider.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            topDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            topDivider.heightAnchor.constraint(equalToConstant: 0.5),

            scroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -48),

            bottomDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            bottomDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            bottomDivider.heightAnchor.constraint(equalToConstant: 0.5),
            bottomDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Spec.footerHeight),

            actionsStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            actionsStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    private func rebuildHintsStack() {
        guard let footerView, let actionsStack else { return }
        hintsStack?.removeFromSuperview()
        let stack = buildHintsStack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -10),
        ])
        hintsStack = stack
    }

    private func buildHintsStack() -> NSStackView {
        let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
        let items: [(String, String)] = [
            (HotkeySpec.compactDisplay(settings.spotlightHotkey(for: "copyImage")), "复制原图"),
            (HotkeySpec.compactDisplay(settings.spotlightHotkey(for: "reopenEdit")), "重新编辑"),
            (HotkeySpec.compactDisplay(settings.spotlightHotkey(for: "pin")), "贴图"),
            (HotkeySpec.compactDisplay(settings.spotlightHotkey(for: "copyOCR")), "复制文字"),
            ("Esc", "关闭"),
        ]
        var views: [NSView] = []
        for (idx, item) in items.enumerated() {
            let cap = SpotlightKbdCapsule(text: item.0)
            let text = NSTextField(labelWithString: item.1)
            text.font = DesignTokens.Font.note
            text.textColor = NSColor(white: 0.12, alpha: 0.85)
            let pair = NSStackView(views: [cap, text])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 4
            views.append(pair)

            if idx < items.count - 1 {
                let dot = NSTextField(labelWithString: "·")
                dot.font = DesignTokens.Font.note
                dot.textColor = NSColor(white: 0.12, alpha: 0.45)
                views.append(dot)
            }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func updateShadowPaths(for cardSize: NSSize) {
        panel?.contentView?.layoutSubtreeIfNeeded()
        outerShadowView?.refreshGeometry()
    }

    // MARK: - 屏幕定位与尺寸

    private func computePanelFrame() -> NSRect {
        let screen = DisplayRegistry.screenAtMouse()
        guard let visible = screen?.visibleFrame else {
            let m = Spec.shadowMargin
            return NSRect(x: 200, y: 200, width: Spec.panelWidth + m * 2, height: Spec.panelHeight + m * 2)
        }

        let cardW = min(Spec.panelWidth, max(540, visible.width - 32))
        let cardH = min(Spec.panelHeight, max(360, visible.height - 32))
        updateShadowPaths(for: NSSize(width: cardW, height: cardH))

        let m = Spec.shadowMargin
        let totalW = cardW + m * 2
        let totalH = cardH + m * 2

        let cardOrigin = DisplayRegistry.centerOrigin(for: NSSize(width: cardW, height: cardH), on: screen)

        return NSRect(
            x: cardOrigin.x - m,
            y: cardOrigin.y - m,
            width: totalW,
            height: totalH
        )
    }

    // MARK: - 搜索与无闪烁网格刷新

    private var selectedMatch: HistorySearchMatch? {
        guard let idx = selectedIndex, matches.indices.contains(idx) else { return nil }
        return matches[idx]
    }

    private func applySearch(query: String, preferredRecordID: String?, preserveScroll: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = HistorySearch.filter(allRecords, query: query)

        clearButton.isHidden = query.isEmpty

        if trimmed.isEmpty {
            countLabel.stringValue = "\(allRecords.count) 条"
        } else {
            countLabel.stringValue = "\(matches.count) / \(allRecords.count)"
        }

        if matches.isEmpty {
            selectedIndex = nil
        } else if let preferredRecordID,
                  let found = matches.firstIndex(where: { $0.record.id == preferredRecordID }) {
            selectedIndex = found
        } else {
            selectedIndex = 0
        }

        layoutGrid(preserveScroll: preserveScroll)
        updateFooterActionButtons()
        // 同步布局完成后才异步补图：面板已瞬间弹出，图片逐张补位
        startThumbnailLoad(for: matches.map(\.record), epoch: presentationEpoch)
    }

    private func layoutGrid(preserveScroll: Bool) {
        let savedScrollOrigin = scrollView.contentView.bounds.origin

        let visibleWidth = max(500, (panel?.frame.width ?? (Spec.panelWidth + Spec.shadowMargin * 2)) - Spec.shadowMargin * 2)
        let cols = Spec.columns
        let availableW = visibleWidth - Spec.gridPaddingH * 2 - Spec.gridGapH * CGFloat(cols - 1)
        let cardW = floor(availableW / CGFloat(cols))
        let cardH = Spec.cardHeight

        let count = matches.count
        let rows = (count + cols - 1) / cols
        let contentHeight = count == 0
            ? max(100, scrollView.contentView.bounds.height)
            : Spec.gridPaddingV * 2 + CGFloat(rows) * cardH + CGFloat(max(0, rows - 1)) * Spec.gridGapV

        gridDocumentView.frame = NSRect(x: 0, y: 0, width: visibleWidth, height: max(contentHeight, scrollView.bounds.height))

        while cardPool.count < count {
            let card = HistoryCardView()
            card.onSelect = { [weak self] idx in
                self?.selectCard(at: idx, ensureVisible: false)
                self?.focusSearchFieldKeepingCursor()
            }
            card.onDoubleClick = { [weak self] idx in
                self?.selectCard(at: idx, ensureVisible: false)
                self?.executeCopyImage()
            }
            card.onRightClick = { [weak self] idx, event, sourceView in
                self?.selectCard(at: idx, ensureVisible: false)
                self?.presentContextMenu(for: idx, event: event, in: sourceView)
            }
            gridDocumentView.addSubview(card)
            cardPool.append(card)
        }

        for index in 0..<cardPool.count {
            let card = cardPool[index]
            if index < count {
                let row = index / cols
                let col = index % cols
                let x = Spec.gridPaddingH + CGFloat(col) * (cardW + Spec.gridGapH)
                let y = Spec.gridPaddingV + CGFloat(row) * (cardH + Spec.gridGapV)
                card.frame = NSRect(x: x, y: y, width: cardW, height: cardH)
                card.isHidden = false

                let match = matches[index]
                let thumb = cachedThumbnailImage(for: match.record)
                let metaText = Self.formatMetaLine(for: match.record)
                card.configure(
                    index: index,
                    match: match,
                    metaText: metaText,
                    thumbnail: thumb,
                    isSelected: index == selectedIndex
                )
            } else {
                card.isHidden = true
            }
        }

        if count == 0 {
            emptyStateView.isHidden = false
            emptyStateView.configure(
                hasAnyRecords: !allRecords.isEmpty,
                query: searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else {
            emptyStateView.isHidden = true
        }

        if preserveScroll {
            let maxY = max(0, gridDocumentView.frame.height - scrollView.contentView.bounds.height)
            let clampedOrigin = NSPoint(x: 0, y: min(savedScrollOrigin.y, maxY))
            scrollView.contentView.scroll(to: clampedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// 同步阶段取缩略图：本地缓存 → 注入的纯内存查询；绝不在主线程解码磁盘 PNG
    private func cachedThumbnailImage(for record: HistoryRecord) -> NSImage? {
        if let cached = thumbnailCache[record.id] {
            return cached
        }
        guard let loaded = callbacks?.cachedThumbnail(record, Spec.thumbMaxSide) else {
            return nil
        }
        thumbnailCache[record.id] = loaded
        return loaded
    }

    /// 异步补图：首屏前 9 条优先，其余后排；最多 4 个并发解码，拿一张刷一张
    private func startThumbnailLoad(for records: [HistoryRecord], epoch: Int) {
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        guard callbacks != nil else { return }

        var ordered: [HistoryRecord] = []
        ordered.reserveCapacity(records.count)
        var seen = Set<String>()
        for record in records where !seen.contains(record.id) {
            seen.insert(record.id)
            guard thumbnailCache[record.id] == nil else { continue }
            ordered.append(record)
        }
        guard !ordered.isEmpty else { return }

        let headCount = min(9, ordered.count)
        let planned = Array(ordered[0..<headCount]) + Array(ordered[headCount...])

        thumbnailLoadTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                let maxConcurrent = 4
                var nextIndex = 0
                while nextIndex < planned.count, nextIndex < maxConcurrent {
                    let record = planned[nextIndex]
                    nextIndex += 1
                    group.addTask { [weak self] in
                        await self?.loadAndApplyThumbnail(record, epoch: epoch)
                    }
                }
                while nextIndex < planned.count {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    _ = await group.next()
                    let record = planned[nextIndex]
                    nextIndex += 1
                    group.addTask { [weak self] in
                        await self?.loadAndApplyThumbnail(record, epoch: epoch)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    /// 单个缩略图加载单元：取图与落图都在 MainActor，NSImage 不跨 actor
    private func loadAndApplyThumbnail(_ record: HistoryRecord, epoch: Int) async {
        guard let callbacks, !Task.isCancelled else { return }
        guard let image = await callbacks.loadThumbnailAsync(record, Spec.thumbMaxSide) else { return }
        guard !Task.isCancelled else { return }
        applyLoadedThumbnail(image, recordID: record.id, epoch: epoch)
    }

    /// 补图落地：epoch / 可见性双重校验后写本地缓存并只刷仍展示同一记录的卡片
    private func applyLoadedThumbnail(_ image: NSImage, recordID: String, epoch: Int) {
        guard isVisible, presentationEpoch == epoch else { return }
        thumbnailCache[recordID] = image
        guard let index = matches.firstIndex(where: { $0.record.id == recordID }),
              cardPool.indices.contains(index),
              !cardPool[index].isHidden else { return }
        cardPool[index].updateThumbnail(image, forRecordID: recordID)
    }

    private func selectCard(at newIndex: Int, ensureVisible: Bool) {
        guard matches.indices.contains(newIndex) else { return }
        let oldIndex = selectedIndex
        selectedIndex = newIndex

        if let oldIndex, cardPool.indices.contains(oldIndex), !cardPool[oldIndex].isHidden {
            cardPool[oldIndex].setSelected(false)
        }
        if cardPool.indices.contains(newIndex), !cardPool[newIndex].isHidden {
            cardPool[newIndex].setSelected(true)
            if ensureVisible {
                scrollCardToVisible(at: newIndex)
            }
        }
        updateFooterActionButtons()
    }

    private func scrollCardToVisible(at index: Int) {
        guard cardPool.indices.contains(index), !cardPool[index].isHidden else { return }
        let cardFrame = cardPool[index].frame.insetBy(dx: 0, dy: -8)
        let clipBounds = scrollView.contentView.bounds
        var targetOrigin = clipBounds.origin

        if cardFrame.minY < clipBounds.minY {
            targetOrigin.y = max(0, cardFrame.minY)
        } else if cardFrame.maxY > clipBounds.maxY {
            let maxOriginY = max(0, gridDocumentView.frame.height - clipBounds.height)
            targetOrigin.y = min(maxOriginY, cardFrame.maxY - clipBounds.height)
        } else {
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func updateFooterActionButtons() {
        let hasSelection = selectedMatch != nil
        footerReopenButton.isEnabled = hasSelection
        footerPinButton.isEnabled = hasSelection
        footerCopyTextButton.isEnabled = hasSelection
    }

    // MARK: - 动作执行

    private func clearSearchTapped() {
        searchField.stringValue = ""
        applySearch(query: "", preferredRecordID: nil, preserveScroll: false)
        focusSearchField()
    }

    private func executeCopyImage() {
        guard let record = selectedMatch?.record, let callbacks else { return }
        dismissInternal(restoreFocus: true, notifyDismiss: true)
        callbacks.onCopyImage(record)
        Log.event(.history, "spotlight.action.copyImage", ["id": record.id])
    }

    private func executeReopenEdit() {
        guard let record = selectedMatch?.record, let callbacks else { return }
        // 重开编辑会立即激活编辑器窗口，不把焦点归还给旧 App
        dismissInternal(restoreFocus: false, notifyDismiss: true)
        callbacks.onReopenEdit(record)
        Log.event(.history, "spotlight.action.reopenEdit", ["id": record.id])
    }

    private func executePin() {
        guard let record = selectedMatch?.record, let callbacks else { return }
        dismissInternal(restoreFocus: true, notifyDismiss: true)
        callbacks.onPin(record)
        Log.event(.history, "spotlight.action.pin", ["id": record.id])
    }

    private func executeCopyOCRText() {
        guard let record = selectedMatch?.record, let callbacks else { return }
        dismissInternal(restoreFocus: true, notifyDismiss: true)
        callbacks.onCopyOCRText(record)
        Log.event(.history, "spotlight.action.copyOCR", ["id": record.id])
    }

    // MARK: - 右键菜单

    private func presentContextMenu(for index: Int, event: NSEvent, in view: NSView) {
        guard matches.indices.contains(index) else { return }
        let menu = NSMenu(title: "历史截图操作")
        menu.delegate = self
        let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings

        func makeMenuItem(title: String, action: Selector, symbol: String, actionKey: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            let combo = settings.spotlightHotkey(for: actionKey)
            if let spec = HotkeySpec.parse(combo, allowBare: false, allowNamedBare: true) {
                item.keyEquivalentModifierMask = EditorKeyRouter.nsEventFlags(spec.modifiers)
                if spec.keyCode == 36 {
                    item.keyEquivalent = "\r"
                } else {
                    let parts = combo.lowercased().split(separator: "+").map(String.init)
                    if let last = parts.last, last.count == 1 {
                        item.keyEquivalent = last
                    }
                }
            }
            item.image = TBIcon.symbolImage(named: symbol, pointSize: 13, weight: .medium, hierarchical: false)
            item.target = self
            return item
        }

        menu.addItem(makeMenuItem(title: "复制原图", action: #selector(menuCopyImage(_:)), symbol: "doc.on.doc", actionKey: "copyImage"))
        menu.addItem(makeMenuItem(title: "重新打开编辑", action: #selector(menuReopenEdit(_:)), symbol: "pencil.and.outline", actionKey: "reopenEdit"))
        menu.addItem(makeMenuItem(title: "贴到桌面", action: #selector(menuPin(_:)), symbol: "pin", actionKey: "pin"))
        menu.addItem(makeMenuItem(title: "复制识别文字", action: #selector(menuCopyOCR(_:)), symbol: "text.viewfinder", actionKey: "copyOCR"))

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func menuCopyImage(_ sender: Any?) { executeCopyImage() }
    @objc private func menuReopenEdit(_ sender: Any?) { executeReopenEdit() }
    @objc private func menuPin(_ sender: Any?) { executePin() }
    @objc private func menuCopyOCR(_ sender: Any?) { executeCopyOCRText() }

    // MARK: - 键盘事件与网格导航

    private enum NavigationDirection {
        case up, down, left, right
    }

    private func moveSelection(_ direction: NavigationDirection) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        guard let current = selectedIndex else {
            selectCard(at: 0, ensureVisible: true)
            return
        }

        let cols = Spec.columns
        let target: Int
        switch direction {
        case .left:
            target = max(0, current - 1)
        case .right:
            target = min(count - 1, current + 1)
        case .up:
            target = current >= cols ? current - cols : current
        case .down:
            if current + cols < count {
                target = current + cols
            } else if current / cols < (count - 1) / cols {
                target = count - 1
            } else {
                target = current
            }
        }
        if target != current {
            selectCard(at: target, ensureVisible: true)
        }
    }

    private var hasMarkedTextInFieldEditor: Bool {
        (panel?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    private func matchSpotlightAction(for event: NSEvent) -> String? {
        let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
        let keyCode = UInt32(event.keyCode)
        let normalizedKeyCode: UInt32 = (keyCode == 76) ? 36 : keyCode   // 小键盘回车视为 return
        let mods = event.modifierFlags.hotkeyModifiers
        let keys = ["copyImage", "reopenEdit", "pin", "copyOCR"]
        for actionKey in keys {
            let combo = settings.spotlightHotkey(for: actionKey)
            guard let spec = HotkeySpec.parse(combo, allowBare: false, allowNamedBare: true) else { continue }
            if spec.keyCode == normalizedKeyCode && spec.modifiers == mods {
                return actionKey
            }
        }
        return nil
    }

    private func performSpotlightAction(_ actionKey: String) {
        switch actionKey {
        case "copyImage": executeCopyImage()
        case "reopenEdit": executeReopenEdit()
        case "pin": executePin()
        case "copyOCR": executeCopyOCRText()
        default: break
        }
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isVisible, event.window === panel else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if !hasMarkedTextInFieldEditor, let actionKey = matchSpotlightAction(for: event) {
            if actionKey == "copyOCR",
               flags == .command,
               (event.charactersIgnoringModifiers?.lowercased() ?? "") == "c",
               let editor = panel?.firstResponder as? NSTextView,
               editor.selectedRange().length > 0 {
                return false
            }
            performSpotlightAction(actionKey)
            return true
        }
        // ⌃/⌥ + 方向键：在搜索框有内容时也能完整进行网格导航
        if !hasMarkedTextInFieldEditor,
           (flags.contains(.control) || flags.contains(.option)) {
            switch event.keyCode {
            case 123: moveSelection(.left); return true
            case 124: moveSelection(.right); return true
            case 125: moveSelection(.down); return true
            case 126: moveSelection(.up); return true
            default: break
            }
        }
        return false
    }

    private func installEventMonitors() {
        removeEventMonitors()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control])
            let hasMarked = self.hasMarkedTextInFieldEditor

            // ⌃/⌥ + ←/→/↑/↓ 强制网格导航
            if !hasMarked, (flags.contains(.control) || flags.contains(.option)) {
                switch event.keyCode {
                case 123: self.moveSelection(.left); return nil
                case 124: self.moveSelection(.right); return nil
                case 125: self.moveSelection(.down); return nil
                case 126: self.moveSelection(.up); return nil
                default: break
                }
            }

            // 支持无修饰键的自定义动作键（如 Return / F1-F12）
            if !hasMarked, flags.isEmpty, let actionKey = self.matchSpotlightAction(for: event) {
                self.performSpotlightAction(actionKey)
                return nil
            }

            // 当焦点不在搜索框 field editor 上时兜底处理 Esc / Return / 方向键
            if !(self.panel?.firstResponder is NSTextView) {
                switch event.keyCode {
                case 53:
                    self.dismiss()
                    return nil
                case 36, 76:
                    self.executeCopyImage()
                    return nil
                case 123:
                    self.moveSelection(.left)
                    return nil
                case 124:
                    self.moveSelection(.right)
                    return nil
                case 125:
                    self.moveSelection(.down)
                    return nil
                case 126:
                    self.moveSelection(.up)
                    return nil
                default:
                    break
                }
            }
            return event
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isVisible, !self.isContextMenuOpen else { return }
                self.dismissInternal(restoreFocus: false, notifyDismiss: true)
            }
        }
    }

    private func removeEventMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }

    // MARK: - 焦点与退场

    private func focusSearchField() {
        guard let panel else { return }
        if panel.firstResponder !== searchField.currentEditor() {
            panel.makeFirstResponder(searchField)
        }
        if let editor = searchField.currentEditor() as? NSTextView {
            editor.insertionPointColor = DesignTokens.accent
            if !editor.hasMarkedText() {
                let len = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: len, length: 0))
            }
        }
    }

    private func focusSearchFieldKeepingCursor() {
        guard let panel else { return }
        if !(panel.firstResponder is NSTextView) {
            focusSearchField()
        }
    }

    private func capturePreviousApplication() {
        let ownPID = NSRunningApplication.current.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ownPID {
            previousApp = front
            previousAppPID = Int(front.processIdentifier)
        } else {
            previousApp = nil
            previousAppPID = nil
        }
    }

    private func restoreFocusToPreviousApp() {
        guard NSApp.isActive else { return }
        let ownPID = Int(NSRunningApplication.current.processIdentifier)

        let target: NSRunningApplication? = {
            if let pid = previousAppPID, pid != ownPID,
               let live = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
               !live.isTerminated {
                return live
            }
            if let prev = previousApp, !prev.isTerminated,
               Int(prev.processIdentifier) != ownPID {
                return prev
            }
            return nil
        }()

        if let target {
            _ = target.activate()
        } else {
            NSApp.deactivate()
        }
    }

    private func dismissInternal(restoreFocus: Bool, notifyDismiss: Bool) {
        guard isPresented || (panel?.isVisible ?? false) else { return }
        isPresented = false
        isContextMenuOpen = false
        presentationEpoch += 1
        let epoch = presentationEpoch

        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil

        removeEventMonitors()

        if restoreFocus {
            restoreFocusToPreviousApp()
        }
        previousApp = nil
        previousAppPID = nil

        guard let panel else {
            if notifyDismiss { callbacks?.onDismiss?() }
            return
        }

        let reduce = DesignTokens.Motion.reduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.exitDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 0
            if !reduce {
                var sink = panel.frame
                sink.origin.y -= DesignTokens.Motion.exitSink
                panel.animator().setFrameOrigin(sink.origin)
            }
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.presentationEpoch == epoch else { return }
                panel.orderOut(nil)
                self.thumbnailCache.removeAll(keepingCapacity: false)
            }
        })

        if notifyDismiss {
            callbacks?.onDismiss?()
        }
        Log.event(.history, "spotlight.dismiss", ["restoreFocus": "\(restoreFocus)"])
    }

    // MARK: - 文案格式化

    private static func formatMetaLine(for record: HistoryRecord) -> String {
        let rel = relativeTime(from: record.createdAt)
        return "\(rel) · \(record.width)×\(record.height)"
    }

    private static func relativeTime(from date: Date, now: Date = Date()) -> String {
        let diff = max(0, now.timeIntervalSince(date))
        if diff < 60 {
            return "刚刚"
        }
        if diff < 3600 {
            return "\(Int(diff / 60)) 分钟前"
        }
        if diff < 86400 {
            return "\(Int(diff / 3600)) 小时前"
        }
        return dateFormatter.string(from: date)
    }
}

// MARK: - NSWindowDelegate / NSTextFieldDelegate / NSMenuDelegate

extension HistorySpotlightPanel: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, !isContextMenuOpen else { return }
        dismissInternal(restoreFocus: true, notifyDismiss: true)
    }
}

extension HistorySpotlightPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard isVisible else { return }
        applySearch(query: searchField.stringValue, preferredRecordID: nil, preserveScroll: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(.up)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(.down)
            return true
        case #selector(NSResponder.moveLeft(_:)):
            if searchField.stringValue.isEmpty {
                moveSelection(.left)
                return true
            }
            return false
        case #selector(NSResponder.moveRight(_:)):
            if searchField.stringValue.isEmpty {
                moveSelection(.right)
                return true
            }
            return false
        case #selector(NSResponder.insertNewline(_:)):
            let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
            let returnAction = ["copyImage", "reopenEdit", "pin", "copyOCR"].first {
                HotkeySpec.parse(settings.spotlightHotkey(for: $0), allowBare: false, allowNamedBare: true)?.keyCode == 36
                    && HotkeySpec.parse(settings.spotlightHotkey(for: $0), allowBare: false, allowNamedBare: true)?.modifiers.isEmpty == true
            } ?? "copyImage"
            performSpotlightAction(returnAction)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }
}

extension HistorySpotlightPanel: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isContextMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isContextMenuOpen = false
    }
}

// MARK: - 私有窗口与视图组件

@MainActor
private final class SpotlightPanelWindow: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class SpotlightOuterView: NSView {
    weak var panelRootView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let panelRootView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return panelRootView.frame.contains(local) ? super.hitTest(point) : nil
    }
}

@MainActor
private final class SpotlightSearchBarView: NSView {
    var onClickEmptyArea: (() -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        onClickEmptyArea?()
    }
}

@MainActor
private final class SpotlightFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SpotlightHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SpotlightHairlineView 只走代码创建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignTokens.hair.cgColor
        }
    }
}

@MainActor
private final class SpotlightBadgeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.sm
        layer?.borderWidth = 0.5
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SpotlightBadgeView 只走代码创建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(white: 0.985, alpha: 0.96).cgColor
            layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        }
    }
}

@MainActor
private final class SpotlightIconButton: NSButton {
    private let onTap: () -> Void
    private var isHot = false
    private var trackingArea: NSTrackingArea?

    init(symbol: String, pointSize: CGFloat, tooltip: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        image = TBIcon.symbolImage(named: symbol, pointSize: pointSize, weight: .medium, hierarchical: false)
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 12
        target = self
        action = #selector(tapped)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SpotlightIconButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true, scale: 0.92)
        super.mouseDown(with: event)
        TactilePress.animate(view: self, pressed: false)
    }

    @objc private func tapped() {
        onTap()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHot ? DesignTokens.fillHover.cgColor : NSColor.clear.cgColor
            contentTintColor = isHot ? DesignTokens.label1 : DesignTokens.label3
        }
    }
}

@MainActor
private final class SpotlightActionButton: NSButton {
    private let labelText: String
    private let onTap: () -> Void
    private var isHot = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    override var isEnabled: Bool {
        didSet { applyStyle() }
    }

    init(title: String, symbol: String, onTap: @escaping () -> Void) {
        self.labelText = title
        self.onTap = onTap
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = TBIcon.symbolImage(named: symbol, pointSize: 11, weight: .medium, hierarchical: false)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.sm
        layer?.borderWidth = 0.5
        target = self
        action = #selector(tapped)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SpotlightActionButton 只走代码创建") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let textW = (labelText as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
        ]).width
        return NSSize(width: ceil(textW) + 28, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        applyStyle()
        TactilePress.animate(view: self, pressed: true, scale: 0.96)
        super.mouseDown(with: event)
        isPressed = false
        TactilePress.animate(view: self, pressed: false)
        applyStyle()
    }

    @objc private func tapped() {
        guard isEnabled else { return }
        onTap()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if !isEnabled {
                layer?.backgroundColor = NSColor(white: 0.97, alpha: 0.76).cgColor
                layer?.borderColor = NSColor.black.withAlphaComponent(0.07).cgColor
                contentTintColor = DesignTokens.label3
                alphaValue = 0.65
            } else {
                alphaValue = 1
                let bg: NSColor = isPressed
                    ? NSColor(white: 0.91, alpha: 0.98)
                    : (isHot
                        ? NSColor(white: 0.955, alpha: 0.98)
                        : NSColor(white: 0.99, alpha: 0.96))
                layer?.backgroundColor = bg.cgColor
                layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
                contentTintColor = DesignTokens.label1
            }

            attributedTitle = NSAttributedString(
                string: " \(labelText)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: isEnabled ? DesignTokens.label1 : DesignTokens.label3,
                ]
            )
        }
    }
}

@MainActor
private final class SpotlightKbdCapsule: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.kbd
        layer?.borderWidth = 0.5

        label.font = DesignTokens.Font.kbd
        label.textColor = NSColor(white: 0.14, alpha: 0.94)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let textW = ceil(label.intrinsicContentSize.width)
        let width = max(20, textW + 10)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 19),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SpotlightKbdCapsule 只走代码创建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(white: 0.99, alpha: 0.98).cgColor
            layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
        }
    }
}

@MainActor
private final class SpotlightEmptyStateView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.contentTintColor = DesignTokens.label3
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = DesignTokens.label2
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = DesignTokens.Font.body
        subtitleLabel.textColor = DesignTokens.label3
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SpotlightEmptyStateView 只走代码创建") }

    func configure(hasAnyRecords: Bool, query: String) {
        if !hasAnyRecords {
            iconView.image = TBIcon.symbolImage(named: "photo.on.rectangle.angled", pointSize: 28, weight: .regular, hierarchical: true)
            titleLabel.stringValue = "暂无历史截图"
            subtitleLabel.stringValue = "截图复制、保存或贴图后将自动收录到这里"
        } else {
            iconView.image = TBIcon.symbolImage(named: "magnifyingglass", pointSize: 26, weight: .regular, hierarchical: false)
            titleLabel.stringValue = "没有匹配「\(query)」的截图"
            subtitleLabel.stringValue = "可尝试搜索识别文字、应用名（如 Xcode）或日期（如 11-21）"
        }
    }
}

// MARK: - 历史截图网格卡片

@MainActor
private final class HistoryCardView: NSView {
    var onSelect: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent, NSView) -> Void)?

    private var index: Int = 0
    private var currentRecordID: String?
    private var isSelectedCard = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    private let thumbContainer = NSView()
    private let thumbImageView = NSImageView()
    private let editableBadge = NSView()
    private let editableLabel = NSTextField(labelWithString: "✎ 可重编")
    private let appLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.lg

        buildSubviews()
        applyVisualState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("HistoryCardView 只走代码创建") }

    private func buildSubviews() {
        thumbContainer.wantsLayer = true
        thumbContainer.layer?.cornerRadius = DesignTokens.Radius.sm
        thumbContainer.layer?.masksToBounds = true
        thumbContainer.layer?.borderWidth = 0.5
        thumbContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbContainer)

        thumbImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbImageView.imageAlignment = .alignCenter
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbContainer.addSubview(thumbImageView)

        editableBadge.wantsLayer = true
        editableBadge.layer?.cornerRadius = 9
        editableBadge.layer?.borderWidth = 0.5
        editableBadge.layer?.backgroundColor = DesignTokens.capsuleDark.cgColor
        editableBadge.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        editableBadge.translatesAutoresizingMaskIntoConstraints = false
        thumbContainer.addSubview(editableBadge)

        editableLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        editableLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        editableLabel.translatesAutoresizingMaskIntoConstraints = false
        editableBadge.addSubview(editableLabel)

        appLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        appLabel.textColor = DesignTokens.label1
        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(appLabel)

        metaLabel.font = DesignTokens.Font.monoDigit(10.5)
        metaLabel.textColor = DesignTokens.label3
        metaLabel.alignment = .right
        metaLabel.lineBreakMode = .byTruncatingHead
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaLabel)

        snippetLabel.maximumNumberOfLines = 2
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.cell?.truncatesLastVisibleLine = true
        snippetLabel.isSelectable = false
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(snippetLabel)

        NSLayoutConstraint.activate([
            thumbContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumbContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            thumbContainer.heightAnchor.constraint(equalToConstant: 114),

            thumbImageView.topAnchor.constraint(equalTo: thumbContainer.topAnchor, constant: 2),
            thumbImageView.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor, constant: -2),
            thumbImageView.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor, constant: 2),
            thumbImageView.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor, constant: -2),

            editableBadge.topAnchor.constraint(equalTo: thumbContainer.topAnchor, constant: 6),
            editableBadge.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor, constant: -6),
            editableBadge.heightAnchor.constraint(equalToConstant: 18),

            editableLabel.leadingAnchor.constraint(equalTo: editableBadge.leadingAnchor, constant: 6),
            editableLabel.trailingAnchor.constraint(equalTo: editableBadge.trailingAnchor, constant: -6),
            editableLabel.centerYAnchor.constraint(equalTo: editableBadge.centerYAnchor),

            appLabel.topAnchor.constraint(equalTo: thumbContainer.bottomAnchor, constant: 7),
            appLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            appLabel.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -6),

            metaLabel.centerYAnchor.constraint(equalTo: appLabel.centerYAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),

            snippetLabel.topAnchor.constraint(equalTo: appLabel.bottomAnchor, constant: 3),
            snippetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            snippetLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        ])
    }

    func configure(
        index: Int,
        match: HistorySearchMatch,
        metaText: String,
        thumbnail: NSImage?,
        isSelected: Bool
    ) {
        self.index = index
        self.isSelectedCard = isSelected
        let record = match.record

        if currentRecordID != record.id {
            // 卡片复用：换了记录必须先清掉上一张图，否则异步补图会串图
            currentRecordID = record.id
            thumbImageView.image = thumbnail
        } else if thumbImageView.image == nil, let thumbnail {
            // 同一条记录：已有异步补上的图就保留，避免回退成占位
            thumbImageView.image = thumbnail
        }

        editableBadge.isHidden = !record.hasEditableAnnotations

        let sourceTitle = record.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        appLabel.stringValue = (sourceTitle?.isEmpty == false) ? sourceTitle! : "截图"
        metaLabel.stringValue = metaText

        if let snippet = match.matchedSnippet, !snippet.isEmpty {
            snippetLabel.attributedStringValue = Self.highlightedSnippet(
                snippet,
                terms: match.matchedTerms
            )
        } else if let title = record.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty {
            snippetLabel.attributedStringValue = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5),
                    .foregroundColor: DesignTokens.label3,
                ]
            )
        } else {
            snippetLabel.attributedStringValue = NSAttributedString(
                string: "无识别文字",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: DesignTokens.label3,
                ]
            )
        }

        applyVisualState()
    }

    func setSelected(_ selected: Bool) {
        guard isSelectedCard != selected else { return }
        isSelectedCard = selected
        applyVisualState()
    }

    /// 异步补图落到卡片：只有仍展示同一条记录时才换图（防止复用卡片串图）
    func updateThumbnail(_ image: NSImage, forRecordID id: String) {
        guard currentRecordID == id else { return }
        guard thumbImageView.image !== image else { return }
        thumbImageView.image = image
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyVisualState()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if !isSelectedCard { applyVisualState() }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isSelectedCard { applyVisualState() }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?(index)
        } else {
            onSelect?(index)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(index, event, self)
    }

    private func applyVisualState() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelectedCard {
                layer?.backgroundColor = NSColor(srgbRed: 0.92, green: 0.965, blue: 1.0, alpha: 0.86).cgColor
                layer?.borderWidth = 1.5
                layer?.borderColor = DesignTokens.accent.cgColor
            } else if isHovered {
                layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.84).cgColor
                layer?.borderWidth = 0.5
                layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
            } else {
                layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.68).cgColor
                layer?.borderWidth = 0.5
                layer?.borderColor = NSColor.black.withAlphaComponent(0.07).cgColor
            }

            thumbContainer.layer?.backgroundColor = NSColor(white: 0.965, alpha: 0.88).cgColor
            thumbContainer.layer?.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        }
    }

    private static func highlightedSnippet(_ snippet: String, terms: [String]) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        let highlightFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5
        paragraph.lineBreakMode = .byTruncatingTail

        let attributed = NSMutableAttributedString(
            string: snippet,
            attributes: [
                .font: baseFont,
                .foregroundColor: DesignTokens.label2,
                .paragraphStyle: paragraph,
            ]
        )

        let nsText = snippet as NSString
        let fullLength = nsText.length
        for term in terms where !term.isEmpty {
            var searchRange = NSRange(location: 0, length: fullLength)
            while searchRange.location < fullLength {
                let found = nsText.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard found.location != NSNotFound, found.length > 0 else { break }
                attributed.addAttributes([
                    .font: highlightFont,
                    .foregroundColor: DesignTokens.accent,
                    .backgroundColor: DesignTokens.accentSoft,
                ], range: found)
                let nextLoc = found.location + found.length
                searchRange = NSRange(location: nextLoc, length: fullLength - nextLoc)
            }
        }
        return attributed
    }
}
