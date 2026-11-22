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

@MainActor
private final class OCRPanelController {
    private static let screenMargin: CGFloat = 12
    private static let headerHeight: CGFloat = 38
    private static let qrBarHeight: CGFloat = 40
    private static let footerHeight: CGFloat = 46
    private static let bodyFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
    private static let bodyLineSpacing: CGFloat = 4.5

    private let panel: OCRResultPanelWindow
    private let textView: NSTextView
    private let result: StructuredOCRResult
    private let primaryQR: DetectedQRCode?
    private let isTextEmpty: Bool
    private let hasOnlyQR: Bool
    private var keyMonitor: Any?

    init(result: StructuredOCRResult, nearGlobalRect rect: CGRect, on screen: NSScreen, avoidRect: CGRect?) {
        self.result = result
        self.primaryQR = result.qrCodes.first(where: { $0.isOpenableURL }) ?? result.qrCodes.first
        self.isTextEmpty = result.plainText.isEmpty
        self.hasOnlyQR = result.plainText.isEmpty && !result.qrCodes.isEmpty

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
        textView.isRichText = false
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

        // 3) 底部操作栏：左侧克制快捷键提示 + 可选 Markdown 表格按钮 + 右侧 Apple 强调主按钮
        let shortcutHint = NSTextField(labelWithString: isTextEmpty ? "Esc 关闭" : "↩ 复制并关闭  ·  Esc 关闭")
        shortcutHint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        shortcutHint.textColor = DesignTokens.label3
        shortcutHint.lineBreakMode = .byTruncatingTail
        shortcutHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutHint.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = OCRPrimaryButton(
            title: isTextEmpty ? "关闭" : "复制文字",
            symbol: isTextEmpty ? nil : "doc.on.doc"
        )
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        self.panel = panel
        self.textView = textView

        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        copyButton.target = self
        copyButton.action = #selector(copyAndClose)

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

        if result.markdownTable != nil {
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
            "table": result.markdownTable != nil ? "\(result.tableRowCount)x\(result.tableColumnCount)" : "none",
        ])
    }

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
        if isTextEmpty {
            close()
        } else {
            copyText(textView.string, closeAfter: true)
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
                copyText(qrPayload, closeAfter: closeAfter)
            } else if closeAfter {
                close()
            }
            return
        }
        let selectedRange = textView.selectedRange()
        let full = textView.string as NSString
        let payload: String
        if selectedRange.length > 0, selectedRange.location + selectedRange.length <= full.length {
            payload = full.substring(with: selectedRange)
        } else {
            payload = textView.string
        }
        copyText(payload, closeAfter: closeAfter)
    }

    private func copyText(_ payload: String, closeAfter: Bool) {
        guard !payload.isEmpty else {
            if closeAfter { close() }
            return
        }
        writeToClipboard(payload)
        Log.event(.ocr, "ocr.panel.copied", ["chars": "\(payload.count)"])
        if closeAfter { close() }
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
        let hasTable = result.markdownTable != nil
        let hasOnlyQR = result.plainText.isEmpty && hasQR

        let minDesiredW: CGFloat = hasTable ? 436 : (hasQR ? 400 : 360)
        let capW: CGFloat = (hasTable || hasQR) ? 540 : 500
        let maxW = min(capW, max(320, visible.width - m * 2))
        let width = max(320, min(max(rect.width * 0.92, minDesiredW), maxW)).rounded()

        let qrTotalH: CGFloat = hasQR ? (qrBarHeight + (hasOnlyQR ? 0 : 1)) : 0

        let minH: CGFloat
        let desiredH: CGFloat
        if hasOnlyQR {
            // 仅二维码无文字：贴合标题栏 + 二维码栏 + 底部操作栏，不留大片空文本区
            minH = headerHeight + qrTotalH + footerHeight + 2
            desiredH = minH
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
        let maxShortH: CGFloat = hasQR ? 420 : 380
        let maxTallH: CGFloat = hasQR ? 440 : 400

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
    private let labelText: String
    private let hasIcon: Bool
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
    private let labelText: String
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
