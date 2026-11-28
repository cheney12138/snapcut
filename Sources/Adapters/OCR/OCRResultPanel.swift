import AppKit

/// OCR 结果浮层（Apple Live Text / Spotlight 卡片风格）：
///
/// - 窗口层级 `screenSaver + 3`，严格高于工具栏与 Tooltip，绝不被工具栏腰斩遮挡；
/// - 智能避让 `avoidRect`（工具栏真实可视矩形）：矮选区顺排在工具栏下方 10pt（空间不足翻选区上方），
///   高选区保证底缘高于工具栏顶缘 12pt 以上，顶部标题栏支持拖拽挪开对照原文；
/// - 顶部「图标 + 识别结果 + 字数角标 + 右上角 ×」，中间舒适行距可编辑滚动正文，底部「左侧快捷提示 + 右侧复制文字主按钮」；
/// - `⌘C` 复制当前选中段（未选中则复制全文），`↩` / 点击「复制文字」复制全文并关闭，`Esc` / `×` 关闭。
@MainActor
enum OCRResultPanel {
    fileprivate static var controller: OCRPanelController?

    static var isPresented: Bool { controller != nil }

    static func dismissIfPresented() {
        controller?.close()
    }

    static func present(
        text: String,
        nearGlobalRect rect: CGRect,
        on screen: NSScreen,
        avoidRect: CGRect? = nil
    ) {
        present(
            result: StructuredOCRResult(
                plainText: text,
                qrCodes: [],
                markdownTable: nil,
                tableRowCount: 0,
                tableColumnCount: 0
            ),
            nearGlobalRect: rect,
            on: screen,
            avoidRect: avoidRect
        )
    }

    static func present(
        result: StructuredOCRResult,
        nearGlobalRect rect: CGRect,
        on screen: NSScreen,
        avoidRect: CGRect? = nil
    ) {
        controller?.close()
        let newController = OCRPanelController(
            result: result,
            nearGlobalRect: rect,
            on: screen,
            avoidRect: avoidRect
        )
        controller = newController
        newController.present()
    }
}

private final class OCRResultPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 语义结构成立时才存在的两种视图（无结构走纯文本老路，不出现切换胶囊）
private enum OCRViewMode: String {
    case formatted
    case markdown
}

@MainActor
private final class OCRPanelController: NSObject, NSTextViewDelegate {
    private static let screenMargin: CGFloat = 12
    private static let headerHeight: CGFloat = 38
    private static let qrBarHeight: CGFloat = 40
    private static let footerHeight: CGFloat = 46
    private static let bodyFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
    private static let bodyLineSpacing: CGFloat = 4.5
    /// 富文本（尤其带表格）需要更宽版面：上限 640pt
    private static let richMaxWidth: CGFloat = 640
    /// 带表格时的最小宽度，保证一列数字不至于挤成两行
    private static let richTableMinWidth: CGFloat = 480

    private let panel: OCRResultPanelWindow
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let result: StructuredOCRResult
    private let primaryQR: DetectedQRCode?
    private let isTextEmpty: Bool
    private let hasOnlyQR: Bool
    private let shortcutHint: NSTextField
    private let copyButton: OCRPrimaryButton
    private let modeButton: OCRSecondaryButton?
    private let segment: OCRViewModeSegment?
    /// 语义文档（OCR-A 解析产物）：非 nil 且块非空才提供「排版 / Markdown」双视图
    private let document: OCRDocument?
    private let hasRichDocument: Bool
    private var mode: OCRViewMode
    /// 用户改过的内容（未改过时始终按 document 重新渲染，保证导出最纯净）
    private var formattedCache: NSAttributedString?
    private var markdownCache: NSAttributedString?
    private var hasEditedFormatted = false
    private var hasEditedMarkdown = false
    /// 程序写入正文时抑制脏状态误判
    private var isApplyingContent = false
    private var keyMonitor: Any?

    init(result: StructuredOCRResult, nearGlobalRect rect: CGRect, on screen: NSScreen, avoidRect: CGRect?) {
        self.result = result
        self.primaryQR = result.qrCodes.first(where: { $0.isOpenableURL }) ?? result.qrCodes.first
        self.isTextEmpty = result.plainText.isEmpty
        self.hasOnlyQR = result.plainText.isEmpty && !result.qrCodes.isEmpty

        let document = result.document
        // 契约闸门：hasRichStructure 为真且确有可渲染的块才启用双视图；
        // 旧链路（仅 markdownTable、document 为 nil）保持原纯文本面板零回归
        let hasRichDocument = result.hasRichStructure && !(document?.blocks.isEmpty ?? true)
        self.document = document
        self.hasRichDocument = hasRichDocument
        self.mode = .formatted

        let placement = Self.computeFrame(for: result, selection: rect, on: screen, avoidRect: avoidRect)
        let frame = placement
        let size = frame.size

        let panel = OCRResultPanelWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 严格高于 OverlayWindow (.screenSaver)、ToolbarPanel (+1) 与 Tooltip (+2)，绝不被工具栏压切
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = DesignTokens.Mat.glass(
            material: DesignTokens.Mat.hud,
            cornerRadius: DesignTokens.Radius.xl
        )
        effect.frame = NSRect(origin: .zero, size: size)
        effect.autoresizingMask = [.width, .height]

        // 1) 顶部拖拽标题栏：[图标 + 识别结果 + 字数/二维码角标] ··· [×]
        let headerBar = OCRHeaderDragView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = TBIcon.symbolImage(
            named: hasOnlyQR ? "qrcode.viewfinder" : "text.viewfinder",
            pointSize: 13,
            weight: .medium,
            hierarchical: true
        )
        iconView.contentTintColor = DesignTokens.accent
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "识别结果")
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = DesignTokens.label1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let countText: String
        if hasOnlyQR {
            countText = result.qrCodes.count > 1 ? "\(result.qrCodes.count) 个二维码" : "二维码"
        } else if isTextEmpty {
            countText = "无文字"
        } else {
            countText = "\(result.plainText.count) 字"
        }
        let countLabel = NSTextField(labelWithString: countText)
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = DesignTokens.label3
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = OCRCloseButton()
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        // 视图切换胶囊：紧贴关闭按钮左侧 10pt（标题栏右侧），仅在语义结构成立时出现
        let segment: OCRViewModeSegment? = hasRichDocument ? OCRViewModeSegment() : nil
        if let segment {
            segment.translatesAutoresizingMaskIntoConstraints = false
            headerBar.addSubview(segment)
        }

        headerBar.addSubview(iconView)
        headerBar.addSubview(titleLabel)
        headerBar.addSubview(countLabel)
        headerBar.addSubview(closeBtn)

        let topDivider = OCRHairlineView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false

        // 2) 正文滚动区（舒适行距、可局部选词、可编辑修订；仅二维码无文字时不占位）
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.bodyLineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: max(100, size.width - 28), height: 60))
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        // 富文本模式才能承接 NSTextList / NSTextTable 的段落样式（纯文本会直接被抹平）
        textView.isRichText = hasRichDocument
        textView.font = Self.bodyFont
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: Self.bodyFont,
            .foregroundColor: DesignTokens.label1,
            .paragraphStyle: paragraph,
        ]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 34)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.textContainer?.widthTracksTextView = true
        if isTextEmpty {
            textView.string = "未识别到可提取的文字内容"
            textView.textColor = DesignTokens.label3
            textView.isEditable = false
        } else if hasRichDocument, let document {
            textView.textStorage?.setAttributedString(OCRDocumentRenderer.render(document))
            textView.isEditable = true
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: result.plainText, attributes: [
                .font: Self.bodyFont,
                .foregroundColor: DesignTokens.label1,
                .paragraphStyle: paragraph,
            ]))
            textView.isEditable = true
        }
        textView.isSelectable = true
        scrollView.documentView = textView

        let bottomDivider = OCRHairlineView()
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false

        // 3) 底部操作栏：左侧克制快捷键提示 + 富文本双按钮（次要格式 + 当前格式主按钮）
        let hintText: String
        if hasRichDocument {
            hintText = "↩ 复制并关闭  ·  ⌘M 切视图  ·  Esc 关闭"
        } else {
            hintText = isTextEmpty ? "Esc 关闭" : "↩ 复制并关闭  ·  Esc 关闭"
        }
        let shortcutHint = NSTextField(labelWithString: hintText)
        shortcutHint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        shortcutHint.textColor = DesignTokens.label3
        shortcutHint.lineBreakMode = .byTruncatingTail
        shortcutHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutHint.translatesAutoresizingMaskIntoConstraints = false

        let copyButton: OCRPrimaryButton
        let modeButton: OCRSecondaryButton?
        if hasRichDocument {
            // 默认「排版」态：主按钮复制排版，次按钮复制 Markdown（切到 Markdown 后互换）
            copyButton = OCRPrimaryButton(title: "复制排版", symbol: "doc.on.doc")
            modeButton = OCRSecondaryButton(title: "复制 Markdown", symbol: "doc.plaintext", height: 28)
        } else {
            copyButton = OCRPrimaryButton(
                title: isTextEmpty ? "关闭" : "复制文字",
                symbol: isTextEmpty ? nil : "doc.on.doc"
            )
            modeButton = nil
        }
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton?.translatesAutoresizingMaskIntoConstraints = false

        self.panel = panel
        self.textView = textView
        self.scrollView = scrollView
        self.shortcutHint = shortcutHint
        self.copyButton = copyButton
        self.modeButton = modeButton
        self.segment = segment
        super.init()

        textView.delegate = self
        segment?.onSelect = { [weak self] newMode in
            self?.setMode(newMode, animated: true)
        }

        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        copyButton.target = self
        copyButton.action = #selector(copyAndClose)
        if let modeButton {
            modeButton.target = self
            modeButton.action = #selector(copyOtherModeAndClose)
        }

        effect.addSubview(headerBar)
        effect.addSubview(topDivider)
        if !hasOnlyQR {
            effect.addSubview(scrollView)
        }
        effect.addSubview(bottomDivider)
        effect.addSubview(shortcutHint)
        effect.addSubview(copyButton)

        var constraints: [NSLayoutConstraint] = [
            headerBar.topAnchor.constraint(equalTo: effect.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            iconView.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 7),
            countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -10),
            closeBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 22),
            closeBtn.heightAnchor.constraint(equalToConstant: 22),

            topDivider.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            topDivider.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            topDivider.heightAnchor.constraint(equalToConstant: 0.5),

            bottomDivider.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            bottomDivider.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            bottomDivider.heightAnchor.constraint(equalToConstant: 0.5),
            bottomDivider.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Self.footerHeight),

            shortcutHint.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            shortcutHint.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            copyButton.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor, constant: 9),
            copyButton.heightAnchor.constraint(equalToConstant: 28),
        ]

        // 分段胶囊贴住 closeBtn 左侧，字数角标不得越过它
        if let segment {
            constraints.append(contentsOf: [
                segment.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -10),
                segment.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
                countLabel.trailingAnchor.constraint(lessThanOrEqualTo: segment.leadingAnchor, constant: -8),
            ])
        } else {
            constraints.append(
                countLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -8)
            )
        }

        // 二维码直达动作条（在标题栏下方）
        var bodyTopAnchor = topDivider.bottomAnchor
        if let primaryQR {
            let qrBar = NSView()
            qrBar.translatesAutoresizingMaskIntoConstraints = false

            let qrIcon = NSImageView()
            qrIcon.image = TBIcon.symbolImage(named: "qrcode", pointSize: 13, weight: .medium, hierarchical: true)
            qrIcon.contentTintColor = DesignTokens.accent
            qrIcon.translatesAutoresizingMaskIntoConstraints = false

            let qrLabel = NSTextField(labelWithString: primaryQR.payload)
            qrLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            qrLabel.textColor = DesignTokens.label1
            qrLabel.lineBreakMode = .byTruncatingMiddle
            qrLabel.toolTip = primaryQR.payload
            qrLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            qrLabel.translatesAutoresizingMaskIntoConstraints = false

            let copyQRButton = OCRSecondaryButton(title: "复制二维码", symbol: "doc.on.doc", height: 24)
            copyQRButton.toolTip = "复制二维码内容"
            copyQRButton.target = self
            copyQRButton.action = #selector(copyQRPayload)
            copyQRButton.translatesAutoresizingMaskIntoConstraints = false

            qrBar.addSubview(qrIcon)
            qrBar.addSubview(qrLabel)
            qrBar.addSubview(copyQRButton)
            effect.addSubview(qrBar)

            constraints.append(contentsOf: [
                qrBar.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
                qrBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                qrBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                qrBar.heightAnchor.constraint(equalToConstant: Self.qrBarHeight),

                qrIcon.leadingAnchor.constraint(equalTo: qrBar.leadingAnchor, constant: 14),
                qrIcon.centerYAnchor.constraint(equalTo: qrBar.centerYAnchor),
                qrIcon.widthAnchor.constraint(equalToConstant: 14),
                qrIcon.heightAnchor.constraint(equalToConstant: 14),

                qrLabel.leadingAnchor.constraint(equalTo: qrIcon.trailingAnchor, constant: 7),
                qrLabel.centerYAnchor.constraint(equalTo: qrBar.centerYAnchor),

                copyQRButton.trailingAnchor.constraint(equalTo: qrBar.trailingAnchor, constant: -12),
                copyQRButton.centerYAnchor.constraint(equalTo: qrBar.centerYAnchor),
            ])

            var leadingButtonAnchor = copyQRButton.leadingAnchor
            if let openURL = primaryQR.openableURL {
                let openButton = OCRPrimaryButton(title: "打开链接", symbol: "arrow.up.right.square", height: 24, fontSize: 11.5)
                openButton.toolTip = openURL.absoluteString
                openButton.target = self
                openButton.action = #selector(openPrimaryQRLink)
                openButton.translatesAutoresizingMaskIntoConstraints = false
                qrBar.addSubview(openButton)

                constraints.append(contentsOf: [
                    openButton.trailingAnchor.constraint(equalTo: copyQRButton.leadingAnchor, constant: -6),
                    openButton.centerYAnchor.constraint(equalTo: qrBar.centerYAnchor),
                ])
                leadingButtonAnchor = openButton.leadingAnchor
            }

            if result.qrCodes.count > 1 {
                let multiLabel = NSTextField(labelWithString: "共 \(result.qrCodes.count) 个")
                multiLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
                multiLabel.textColor = DesignTokens.label3
                multiLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                multiLabel.setContentHuggingPriority(.required, for: .horizontal)
                multiLabel.translatesAutoresizingMaskIntoConstraints = false
                qrBar.addSubview(multiLabel)

                constraints.append(contentsOf: [
                    multiLabel.leadingAnchor.constraint(greaterThanOrEqualTo: qrLabel.trailingAnchor, constant: 6),
                    multiLabel.trailingAnchor.constraint(equalTo: leadingButtonAnchor, constant: -8),
                    multiLabel.centerYAnchor.constraint(equalTo: qrBar.centerYAnchor),
                ])
            } else {
                constraints.append(
                    qrLabel.trailingAnchor.constraint(lessThanOrEqualTo: leadingButtonAnchor, constant: -8)
                )
            }

            if hasOnlyQR {
                constraints.append(qrBar.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor))
            } else {
                let qrDivider = OCRHairlineView()
                qrDivider.translatesAutoresizingMaskIntoConstraints = false
                effect.addSubview(qrDivider)
                constraints.append(contentsOf: [
                    qrDivider.topAnchor.constraint(equalTo: qrBar.bottomAnchor),
                    qrDivider.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
                    qrDivider.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
                    qrDivider.heightAnchor.constraint(equalToConstant: 0.5),
                ])
                bodyTopAnchor = qrDivider.bottomAnchor
            }
        }

        if !hasOnlyQR {
            constraints.append(contentsOf: [
                scrollView.topAnchor.constraint(equalTo: bodyTopAnchor, constant: 4),
                scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
                scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
                scrollView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -4),
            ])
        }

        if let modeButton {
            // 富文本双按钮：次按钮（另一格式）+ 主按钮（当前格式），文案随模式即时刷新
            effect.addSubview(modeButton)
            constraints.append(contentsOf: [
                modeButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
                modeButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
                shortcutHint.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor, constant: -10),
            ])
        } else if result.markdownTable != nil {
            let markdownButton = OCRSecondaryButton(title: "复制 Markdown 表格", symbol: "tablecells", height: 28)
            markdownButton.toolTip = "\(result.tableRowCount) 行 × \(result.tableColumnCount) 列 Markdown 表格"
            markdownButton.target = self
            markdownButton.action = #selector(copyMarkdownTable)
            markdownButton.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(markdownButton)

            constraints.append(contentsOf: [
                markdownButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
                markdownButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
                shortcutHint.trailingAnchor.constraint(lessThanOrEqualTo: markdownButton.leadingAnchor, constant: -10),
            ])
        } else {
            constraints.append(
                shortcutHint.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -10)
            )
        }

        NSLayoutConstraint.activate(constraints)
        panel.contentView = effect
    }

    func present() {
        installKeyMonitor()
        let finalFrame = panel.frame
        let reduce = DesignTokens.Motion.reduceMotion
        if !reduce {
            panel.setFrameOrigin(CGPoint(x: finalFrame.minX, y: finalFrame.minY - 6))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.enterDuration
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            panel.animator().alphaValue = 1
            if !reduce { panel.animator().setFrame(finalFrame, display: true) }
        }
        if !isTextEmpty {
            panel.makeFirstResponder(textView)
            // 不做刺眼的全屏蓝底反白；光标停在末尾，用户可直接拖选任意词，或按 ⌘C / ↩ 直接复制全文
            let len = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: len, length: 0))
        }
        Log.event(.ocr, "ocr.panel.present", [
            "w": "\(Int(panel.frame.width))",
            "h": "\(Int(panel.frame.height))",
            "chars": "\(result.plainText.count)",
            "qrs": "\(result.qrCodes.count)",
            "table": result.markdownTable != nil ? "\(result.tableRowCount)x\(result.tableColumnCount)" : (document?.hasTable == true ? "native" : "none"),
            "mode": modeLabel,
            "rich": hasRichDocument ? "1" : "0",
            "blocks": "\(document?.blocks.count ?? 0)",
        ])
    }

    private var modeLabel: String { hasRichDocument ? mode.rawValue : "plain" }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { // Esc
                self.close()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                self.copyCurrentSelectionOrAll(closeAfter: false)
                return nil
            }
            // ⌘M：仅在存在语义结构时于「排版 ↔ Markdown」间切换
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "m",
               self.hasRichDocument {
                self.toggleMode()
                return nil
            }
            // Return（无 Shift 时复制全文并关闭；Shift+Return 允许编辑换行）
            if (event.keyCode == 36 || event.keyCode == 76),
               !event.modifierFlags.contains(.shift) {
                self.copyAndClose()
                return nil
            }
            return event
        }
    }

    @objc private func closeTapped() {
        close()
    }

    @objc private func copyAndClose() {
        guard !isTextEmpty else {
            close()
            return
        }
        if hasRichDocument {
            copyCurrentFormat(closeAfter: true)
            return
        }
        copyText(textView.string, closeAfter: true, scope: "full")
    }

    /// 底部次按钮：复制「另一种」表示（排版 ↔ Markdown），复制完同样关闭
    @objc private func copyOtherModeAndClose() {
        guard hasRichDocument else {
            copyAndClose()
            return
        }
        if mode == .markdown {
            copyFormatted(closeAfter: true)
        } else {
            copyMarkdown(closeAfter: true)
        }
    }

    @objc private func openPrimaryQRLink() {
        guard let url = primaryQR?.openableURL else { return }
        NSWorkspace.shared.open(url)
        Log.event(.ocr, "ocr.qr.open", ["scheme": url.scheme ?? ""])
        close()
    }

    @objc private func copyQRPayload() {
        guard let payload = primaryQR?.payload, !payload.isEmpty else {
            close()
            return
        }
        writeToClipboard(payload)
        Log.event(.ocr, "ocr.qr.copy", ["chars": "\(payload.count)", "count": "\(result.qrCodes.count)"])
        close()
    }

    @objc private func copyMarkdownTable() {
        guard let markdown = result.markdownTable, !markdown.isEmpty else {
            close()
            return
        }
        writeToClipboard(markdown)
        Log.event(.ocr, "ocr.copy.markdownTable", [
            "rows": "\(result.tableRowCount)",
            "cols": "\(result.tableColumnCount)",
            "chars": "\(markdown.count)",
        ])
        close()
    }

    private func copyCurrentSelectionOrAll(closeAfter: Bool) {
        guard !isTextEmpty else {
            if let qrPayload = primaryQR?.payload, !qrPayload.isEmpty {
                copyText(qrPayload, closeAfter: closeAfter, scope: "qr")
            } else if closeAfter {
                close()
            }
            return
        }
        let selectedRange = textView.selectedRange()
        let fullLength = (textView.string as NSString).length
        let hasSelection = selectedRange.length > 0
            && selectedRange.location + selectedRange.length <= fullLength

        // 「排版」模式下拖选：选多少复制多少，且带完整列表 / 表格结构（粘进飞书 / 文档不丢表格）
        if hasRichDocument, mode == .formatted {
            if hasSelection,
               let sub = textView.attributedSubstring(forProposedRange: selectedRange, actualRange: nil) {
                OCRDocumentRenderer.writeRichToPasteboard(attributed: sub, semanticHTML: nil, plainText: sub.string)
                logCopied(format: OCRViewMode.formatted.rawValue, scope: "selection", rich: true, chars: sub.string.count)
                if closeAfter { close() }
                return
            }
            if !hasSelection {
                copyFormatted(closeAfter: closeAfter)
                return
            }
        }

        let payload = hasSelection
            ? (textView.string as NSString).substring(with: selectedRange)
            : textView.string
        let scope = hasSelection ? "selection" : "full"
        if hasRichDocument, mode == .markdown {
            writeToClipboard(payload)
            logCopied(format: OCRViewMode.markdown.rawValue, scope: scope, rich: false, chars: payload.count)
            if closeAfter { close() }
            return
        }
        copyText(payload, closeAfter: closeAfter, scope: scope)
    }

    private func copyCurrentFormat(closeAfter: Bool) {
        if mode == .markdown {
            copyMarkdown(closeAfter: closeAfter)
        } else {
            copyFormatted(closeAfter: closeAfter)
        }
    }

    /// 复制「排版」：未编辑 → 语义 HTML + 原生 RTF + 干净纯文本（最纯净）；
    /// 已编辑 → 从当前 textView 导出，绝不丢用户修订
    private func copyFormatted(closeAfter: Bool) {
        guard let document else {
            copyText(textView.string, closeAfter: closeAfter, scope: "full")
            return
        }
        let edited = formattedSnapshot
        let attributed = edited ?? OCRDocumentRenderer.render(document)
        let html = edited == nil ? document.renderHTML() : nil
        let plain = edited?.string ?? document.renderCleanPlainText()
        OCRDocumentRenderer.writeRichToPasteboard(
            attributed: attributed,
            semanticHTML: html,
            plainText: plain.isEmpty ? attributed.string : plain
        )
        logCopied(format: OCRViewMode.formatted.rawValue, scope: "full", rich: true, chars: plain.count)
        if closeAfter { close() }
    }

    /// 复制「Markdown」：源码就该是纯文本（粘到编辑器 / 终端 / 飞书都是源码）
    private func copyMarkdown(closeAfter: Bool) {
        let payload = markdownSnapshot
        guard !payload.isEmpty else {
            if closeAfter { close() }
            return
        }
        writeToClipboard(payload)
        logCopied(format: OCRViewMode.markdown.rawValue, scope: "full", rich: false, chars: payload.count)
        if closeAfter { close() }
    }

    private func copyText(_ payload: String, closeAfter: Bool, scope: String) {
        guard !payload.isEmpty else {
            if closeAfter { close() }
            return
        }
        writeToClipboard(payload)
        logCopied(format: modeLabel, scope: scope, rich: false, chars: payload.count)
        if closeAfter { close() }
    }

    private func logCopied(format: String, scope: String, rich: Bool, chars: Int) {
        Log.event(.ocr, "ocr.panel.copied", [
            "mode": format,
            "scope": scope,
            "rich": rich ? "1" : "0",
            "chars": "\(chars)",
        ])
    }

    private func writeToClipboard(_ payload: String) {
        if let clipboard = AppCoordinatorShared.deps?.clipboard {
            _ = clipboard.writeText(payload)
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)
        }
    }

    // MARK: - 视图模式（排版 / Markdown）与脏状态

    private func toggleMode() {
        setMode(mode == .formatted ? .markdown : .formatted, animated: true)
    }

    private func setMode(_ newMode: OCRViewMode, animated: Bool) {
        guard hasRichDocument, newMode != mode else { return }
        cacheCurrentEdits()
        mode = newMode
        applyContent()
        segment?.setMode(newMode, animated: animated)
        refreshFooter()
        if animated, !DesignTokens.Motion.reduceMotion {
            // 不闪：先压到 0.72 再回升，不做空帧白闪
            textView.alphaValue = 0.72
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = DesignTokens.Motion.crossfadeDuration
                ctx.timingFunction = DesignTokens.Motion.easeOutStrong
                textView.animator().alphaValue = 1
            }
        }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        Log.event(.ocr, "ocr.panel.mode", ["mode": newMode.rawValue])
    }

    /// 写回正文（只在切模式时调用，程序写入不算「用户编辑」）
    private func applyContent() {
        guard !isTextEmpty else { return }
        isApplyingContent = true
        defer { isApplyingContent = false }

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = Self.bodyLineSpacing
        bodyParagraph.lineBreakMode = .byWordWrapping

        switch mode {
        case .markdown where hasRichDocument:
            let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let monoParagraph = NSMutableParagraphStyle()
            monoParagraph.lineSpacing = Self.bodyLineSpacing
            monoParagraph.lineBreakMode = .byWordWrapping
            textView.isRichText = true
            textView.textStorage?.setAttributedString(markdownAttributed)
            textView.font = mono
            textView.typingAttributes = [
                .font: mono,
                .foregroundColor: DesignTokens.label1,
                .paragraphStyle: monoParagraph,
            ]
        case .formatted where hasRichDocument:
            textView.isRichText = true
            textView.textStorage?.setAttributedString(formattedAttributed)
            textView.font = Self.bodyFont
            textView.typingAttributes = [
                .font: Self.bodyFont,
                .foregroundColor: DesignTokens.label1,
                .paragraphStyle: bodyParagraph,
            ]
        default:
            break
        }
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
    }

    /// 切走前把当前模式的修订存起来（未改则什么都不存，下次仍按 document 重新渲染）
    private func cacheCurrentEdits() {
        guard hasRichDocument else { return }
        switch mode {
        case .formatted:
            if hasEditedFormatted { formattedCache = textView.attributedString() }
        case .markdown:
            if hasEditedMarkdown { markdownCache = textView.attributedString() }
        }
    }

    /// 底部双按钮文案随模式即时互换，并重算固有宽度避免截断
    private func refreshFooter() {
        guard hasRichDocument else { return }
        switch mode {
        case .formatted:
            modeButton?.update(title: "复制 Markdown", symbol: "doc.plaintext")
            copyButton.update(title: "复制排版", symbol: "doc.on.doc")
        case .markdown:
            modeButton?.update(title: "复制排版", symbol: "text.alignleft")
            copyButton.update(title: "复制 Markdown", symbol: "doc.on.doc")
        }
    }

    // MARK: - 内容快照（未编辑走 document 语义导出，已编辑走 textView）

    private var formattedAttributed: NSAttributedString {
        if let formattedCache { return formattedCache }
        guard let document else { return NSAttributedString(string: result.plainText) }
        return OCRDocumentRenderer.render(document)
    }

    private var formattedSnapshot: NSAttributedString? {
        guard hasEditedFormatted else { return nil }
        return mode == .formatted ? textView.attributedString() : formattedCache
    }

    private var markdownSourceText: String {
        guard let document else { return result.plainText }
        let markdown = document.renderMarkdown()
        return markdown.isEmpty ? document.renderCleanPlainText() : markdown
    }

    private var markdownAttributed: NSAttributedString {
        if let markdownCache { return markdownCache }
        return OCRDocumentRenderer.renderMarkdownSource(markdownSourceText)
    }

    private var markdownSnapshot: String {
        if mode == .markdown, hasEditedMarkdown { return textView.string }
        if let markdownCache { return markdownCache.string }
        return markdownSourceText
    }

    // NSTextViewDelegate：记录用户是否真的动过手（决定整篇复制走语义 HTML 还是 textView 导出）
    func textDidChange(_ notification: Notification) {
        guard !isApplyingContent,
              let changed = notification.object as? NSTextView,
              changed === textView,
              hasRichDocument else { return }
        switch mode {
        case .formatted:
            hasEditedFormatted = true
            formattedCache = textView.attributedString()
        case .markdown:
            hasEditedMarkdown = true
            markdownCache = textView.attributedString()
        }
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel.orderOut(nil)
        OCRResultPanel.controller = nil
        Log.event(.ocr, "ocr.panel.close", [:])
    }

    // MARK: - 智能尺寸与避让工具栏定位

    private static func computeFrame(
        for result: StructuredOCRResult,
        selection rect: CGRect,
        on screen: NSScreen,
        avoidRect: CGRect?
    ) -> CGRect {
        let visible = screen.visibleFrame
        let m = screenMargin
        let gap: CGFloat = 10

        let hasQR = !result.qrCodes.isEmpty
        let hasLegacyTable = result.markdownTable != nil
        let document = result.document
        let hasRich = result.hasRichStructure && !(document?.blocks.isEmpty ?? true)
        let hasRichTable = document?.hasTable == true
        let hasTable = hasLegacyTable || hasRichTable
        let hasOnlyQR = result.plainText.isEmpty && hasQR

        // 富文本（尤其带表格）需要更宽的版面：上限 640pt，表格场景最小 480pt
        let minDesiredW: CGFloat
        let capW: CGFloat
        if hasRich {
            // 底栏「↩ 复制并关闭 · ⌘M 切视图 · Esc 关闭」+ 双按钮实测需 456pt，留出余量
            minDesiredW = hasTable ? richTableMinWidth : 480
            capW = richMaxWidth
        } else {
            minDesiredW = hasTable ? 436 : (hasQR ? 400 : 360)
            capW = (hasTable || hasQR) ? 540 : 500
        }
        let maxW = min(capW, max(320, visible.width - m * 2))
        let width = max(320, min(max(rect.width * 0.92, minDesiredW), maxW)).rounded()

        let qrTotalH: CGFloat = hasQR ? (qrBarHeight + (hasOnlyQR ? 0 : 1)) : 0

        let minH: CGFloat
        let desiredH: CGFloat
        if hasOnlyQR {
            // 仅二维码无文字：贴合标题栏 + 二维码栏 + 底部操作栏，不留大片空文本区
            minH = headerHeight + qrTotalH + footerHeight + 2
            desiredH = minH
        } else if hasRich, let document {
            // 富文本：按真实排版实测高度（表格 / 列表都不用估算公式）
            let rendered = OCRDocumentRenderer.render(document)
            // 内容宽 = 面板宽 - 左右 12*2 - 文本容器内衬 2*2 - 行片段 padding 5*2
            let measured = OCRDocumentRenderer.measuredHeight(of: rendered, width: max(120, width - 38))
            let chromeH = headerHeight + qrTotalH + footerHeight + 28
            minH = 168 + qrTotalH
            desiredH = max(minH, ceil(measured) + chromeH)
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = bodyLineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            let sample = result.plainText.isEmpty ? "未识别到可提取的文字内容" : result.plainText
            let contentWidth = max(120, width - 32)
            let measured = (sample as NSString).boundingRect(
                with: NSSize(width: contentWidth, height: 2000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: bodyFont, .paragraphStyle: paragraph]
            )
            // 顶部 38 + (可选二维码条) + 底部 46 + 分隔/滚动内边距 28
            let chromeH = headerHeight + qrTotalH + footerHeight + 28
            minH = 138 + qrTotalH
            desiredH = max(minH, ceil(measured.height) + chromeH)
        }

        // 判断工具栏位置（默认在选区下方；选区贴屏底时工具栏会翻到选区上方）
        let toolbarIsBelow = avoidRect.map { $0.midY < rect.midY } ?? true
        let effectiveBelowY: CGFloat = {
            if let avoid = avoidRect, toolbarIsBelow {
                return min(rect.minY, avoid.minY)
            }
            return rect.minY
        }()
        let effectiveAboveY: CGFloat = {
            if let avoid = avoidRect, !toolbarIsBelow {
                return max(rect.maxY, avoid.maxY)
            }
            return rect.maxY
        }()

        let isShortSelection = rect.height < 140
        var originX = rect.midX - width / 2
        originX = max(visible.minX + m, min(originX, visible.maxX - width - m))

        let height: CGFloat
        var originY: CGFloat
        // 富文本严守「不超过屏幕可用高 52%」，普通文本保持原档位零回归
        let richCapH = min(visible.height * 0.52, 900)
        let maxShortH: CGFloat = hasRich ? richCapH : (hasQR ? 420 : 380)
        let maxTallH: CGFloat = hasRich ? richCapH : (hasQR ? 440 : 400)

        if isShortSelection {
            // 矮选区（如单行/两行文字）：优先放在「选区 + 工具栏」整块下方 10pt，不盖原文也不撞工具栏；
            // 下方空间不足则翻到上方 10pt，再不足才居中覆盖
            let spaceBelow = (effectiveBelowY - gap) - (visible.minY + m)
            let spaceAbove = (visible.maxY - m) - (effectiveAboveY + gap)
            if spaceBelow >= minH {
                height = min(desiredH, min(maxShortH, spaceBelow))
                originY = effectiveBelowY - gap - height
            } else if spaceAbove >= minH {
                height = min(desiredH, min(maxShortH, spaceAbove))
                originY = effectiveAboveY + gap
            } else {
                height = min(desiredH, min(maxShortH, visible.height - m * 2))
                originY = visible.midY - height / 2
            }
        } else {
            // 中/高选区：居中展示在选区内，同时严格避开工具栏所在垂直区间，确保底部「复制文字」永不被遮挡
            let safeBottom: CGFloat
            let safeTop: CGFloat
            if let avoid = avoidRect {
                if toolbarIsBelow {
                    safeBottom = max(visible.minY + m, avoid.maxY + gap)
                    safeTop = visible.maxY - m
                } else {
                    safeBottom = visible.minY + m
                    safeTop = min(visible.maxY - m, avoid.minY - gap)
                }
            } else {
                safeBottom = visible.minY + m
                safeTop = visible.maxY - m
            }

            let availableH = max(minH, safeTop - safeBottom)
            height = min(desiredH, min(maxTallH, availableH))
            let centeredY = rect.midY - height / 2
            originY = max(safeBottom, min(centeredY, safeTop - height))
        }

        originY = max(visible.minY + m, min(originY, visible.maxY - height - m))
        return CGRect(
            x: originX.rounded(),
            y: originY.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }
}

// MARK: - 内部子控件（Apple 质感细节）

/// 顶部可拖拽标题条：按住即可把 OCR 面板挪到一旁对照原文
@MainActor
private final class OCRHeaderDragView: NSView {
    private var dragOffset: CGPoint?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = CGPoint(x: mouse.x - win.frame.minX, y: mouse.y - win.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let offset = dragOffset else { return }
        let mouse = NSEvent.mouseLocation
        win.setFrameOrigin(CGPoint(x: (mouse.x - offset.x).rounded(), y: (mouse.y - offset.y).rounded()))
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }
}

/// 明暗自适应 0.5pt 发丝分隔线
@MainActor
private final class OCRHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refresh()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignTokens.hair.cgColor
        }
    }
}

/// 右上角 22×22 圆形关闭按钮
@MainActor
private final class OCRCloseButton: NSButton {
    private var isHot = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        image = TBIcon.symbolImage(named: "xmark", pointSize: 10, weight: .semibold, hierarchical: false)
        toolTip = "关闭 (Esc)"
        wantsLayer = true
        layer?.cornerRadius = 11
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHot ? DesignTokens.fillHover.cgColor : NSColor.clear.cgColor
            contentTintColor = isHot ? DesignTokens.label1 : DesignTokens.label2
        }
    }
}

/// Apple 强调主动作按钮（图标 + 文案 + 悬停高光 + 触觉按压缩放）
@MainActor
private final class OCRPrimaryButton: NSButton {
    private var isHot = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    private var labelText: String
    private var hasIcon: Bool
    private let buttonHeight: CGFloat
    private let fontSize: CGFloat

    init(title: String, symbol: String?, height: CGFloat = 28, fontSize: CGFloat = 12.5) {
        self.labelText = title
        self.hasIcon = (symbol != nil)
        self.buttonHeight = height
        self.fontSize = fontSize
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        if let symbol {
            imagePosition = .imageLeading
            imageHugsTitle = true
            image = TBIcon.symbolImage(named: symbol, pointSize: max(10.5, fontSize - 1), weight: .medium, hierarchical: false)
            contentTintColor = DesignTokens.labelOnAccent
        } else {
            imagePosition = .noImage
        }
        wantsLayer = true
        layer?.cornerRadius = height <= 24 ? 6 : 7
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        applyStyle()
    }

    /// 视图模式切换时动态换文案 / 图标（重算固有宽度，避免「复制 Markdown」被截断）
    func update(title: String, symbol: String?) {
        labelText = title
        hasIcon = (symbol != nil)
        if let symbol {
            imagePosition = .imageLeading
            imageHugsTitle = true
            image = TBIcon.symbolImage(named: symbol, pointSize: max(10.5, fontSize - 1), weight: .medium, hierarchical: false)
            contentTintColor = DesignTokens.labelOnAccent
        } else {
            imagePosition = .noImage
            image = nil
        }
        invalidateIntrinsicContentSize()
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let textW = (labelText as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ]).width
        let pad: CGFloat = buttonHeight <= 24 ? (hasIcon ? 30 : 20) : (hasIcon ? 36 : 26)
        return NSSize(width: ceil(textW) + pad, height: buttonHeight)
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
        isPressed = true
        applyStyle()
        TactilePress.animate(view: self, pressed: true, scale: 0.96)
        super.mouseDown(with: event)
        isPressed = false
        TactilePress.animate(view: self, pressed: false)
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isPressed ? DesignTokens.accentPress : (isHot ? DesignTokens.accentHover : DesignTokens.accent)).cgColor
        }
        attributedTitle = NSAttributedString(string: hasIcon ? " \(labelText)" : labelText, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: DesignTokens.labelOnAccent,
        ])
    }
}

/// 轻量次级动作按钮（复制二维码 / 复制 Markdown 表格）
@MainActor
private final class OCRSecondaryButton: NSButton {
    private var isHot = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    private var labelText: String
    private let buttonHeight: CGFloat
    private let fontSize: CGFloat

    init(title: String, symbol: String, height: CGFloat = 28) {
        self.labelText = title
        self.buttonHeight = height
        self.fontSize = height <= 24 ? 11.5 : 12
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = TBIcon.symbolImage(named: symbol, pointSize: max(10.5, fontSize - 0.5), weight: .medium, hierarchical: false)
        wantsLayer = true
        layer?.cornerRadius = height <= 24 ? 6 : 7
        layer?.borderWidth = 0.5
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        applyStyle()
    }

    /// 视图模式切换时动态换文案 / 图标（重算固有宽度，避免长文案被截断）
    func update(title: String, symbol: String) {
        labelText = title
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = TBIcon.symbolImage(named: symbol, pointSize: max(10.5, fontSize - 0.5), weight: .medium, hierarchical: false)
        invalidateIntrinsicContentSize()
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let textW = (labelText as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ]).width
        let pad: CGFloat = buttonHeight <= 24 ? 28 : 34
        return NSSize(width: ceil(textW) + pad, height: buttonHeight)
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
        isPressed = true
        applyStyle()
        TactilePress.animate(view: self, pressed: true, scale: 0.96)
        super.mouseDown(with: event)
        isPressed = false
        TactilePress.animate(view: self, pressed: false)
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg: NSColor = isPressed ? DesignTokens.fillPress : (isHot ? DesignTokens.fillHover : DesignTokens.fill)
            layer?.backgroundColor = bg.cgColor
            layer?.borderColor = DesignTokens.stroke.cgColor
            contentTintColor = DesignTokens.label1
            attributedTitle = NSAttributedString(string: " \(labelText)", attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: DesignTokens.label1,
            ])
        }
    }
}

/// 紧凑 Apple 风格分段切换胶囊（「排版」/「Markdown」）：
/// - 24pt 高、外圆角 7pt、有 0.5pt 细描边，浮在玻璃上只是一层薄膜；
/// - 内滑块 5pt 圆角 + 极轻阴影，跟随选中项 0.16s 强缓出滑动（与 RecordingControlBar 的格式切换同语言）；
/// - hover 只抬一档填充 + 文字回归 label1，不做花哨放大。
@MainActor
private final class OCRViewModeSegment: NSView {
    var onSelect: ((OCRViewMode) -> Void)?

    private static let inset: CGFloat = 2
    private static let segmentHeight: CGFloat = 24
    private static let outerRadius: CGFloat = 7
    private static let knobRadius: CGFloat = 5
    private static let fontSize: CGFloat = 11.5

    private let modes: [OCRViewMode] = [.formatted, .markdown]
    private let names = ["排版", "Markdown"]
    private let titleLabels: [NSTextField]
    private let itemWidths: [CGFloat]
    private let knobLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var isHot = false
    private var selectedMode: OCRViewMode = .formatted
    private var hasLaidOutOnce = false

    init() {
        var widths: [CGFloat] = []
        var labels: [NSTextField] = []
        for name in names {
            // 按 semibold 量宽——选中态会加粗，宽度这里一次留够，切换时不会左右抖动
            let textWidth = (name as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: Self.fontSize, weight: .semibold),
            ]).width
            widths.append(max(40, ceil(textWidth) + 20))
            let label = NSTextField(labelWithString: name)
            label.font = NSFont.systemFont(ofSize: Self.fontSize, weight: .medium)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            labels.append(label)
        }
        self.itemWidths = widths
        self.titleLabels = labels
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Self.outerRadius
        layer?.cornerCurve = .continuous

        knobLayer.cornerRadius = Self.knobRadius
        knobLayer.cornerCurve = .continuous
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.18
        knobLayer.shadowRadius = 2
        knobLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(knobLayer)

        var cursorX = Self.inset
        for (index, label) in labels.enumerated() {
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: leadingAnchor, constant: cursorX + widths[index] / 2),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            cursorX += widths[index]
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: cursorX + Self.inset),
            heightAnchor.constraint(equalToConstant: Self.segmentHeight),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setMode(_ mode: OCRViewMode, animated: Bool) {
        selectedMode = mode
        refreshAppearance()
        updateKnobFrame(animated: animated && hasLaidOutOnce && !DesignTokens.Motion.reduceMotion)
    }

    private func updateKnobFrame(animated: Bool) {
        guard bounds.height > Self.inset * 2,
              let index = modes.firstIndex(of: selectedMode) else { return }
        var x = Self.inset
        for i in 0..<index { x += itemWidths[i] }
        let target = CGRect(
            x: x,
            y: Self.inset,
            width: itemWidths[index],
            height: max(0, bounds.height - Self.inset * 2)
        )
        CATransaction.begin()
        if animated {
            CATransaction.setDisableActions(false)
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(DesignTokens.Motion.easeOutStrong)
        } else {
            CATransaction.setDisableActions(true)
        }
        knobLayer.frame = target
        CATransaction.commit()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = (isHot ? DesignTokens.fillHover : DesignTokens.fill).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = DesignTokens.stroke.cgColor
            // 深色玻璃用半透明白滑块（0.20 / hover 0.24），浅色玻璃用原生白卡滑块（0.88 / hover 0.96）
            let knobColor: NSColor = isDark
                ? NSColor.white.withAlphaComponent(isHot ? 0.24 : 0.20)
                : NSColor.white.withAlphaComponent(isHot ? 0.96 : 0.88)
            knobLayer.backgroundColor = knobColor.cgColor
            knobLayer.shadowOpacity = isDark ? 0.18 : 0.12
        }
        for (index, label) in titleLabels.enumerated() {
            let isSelected = modes[index] == selectedMode
            label.textColor = isSelected ? DesignTokens.label1 : DesignTokens.label2
            label.font = NSFont.systemFont(ofSize: Self.fontSize, weight: isSelected ? .semibold : .medium)
        }
    }

    override func layout() {
        super.layout()
        updateKnobFrame(animated: false)
        hasLaidOutOnce = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: true, scale: 0.97)
    }

    override func mouseUp(with event: NSEvent) {
        TactilePress.animate(view: self, pressed: false)
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let next: OCRViewMode = point.x < Self.inset + itemWidths[0] ? modes[0] : modes[1]
        guard next != selectedMode else { return }
        setMode(next, animated: true)
        onSelect?(next)
    }
}
