import AppKit

/// OCR 结果浮层（docs/05 §OCR：结果贴在选区原位附近的可编辑浮层）。
///
/// - 无边框 NSPanel（canBecomeKey = true），浮在选区原位附近，超出屏幕自动内缩
/// - 顶部提示行「识别结果 · ⌘C 复制 · Esc 关闭」，中间 NSTextView 可编辑可选中、自动全选，
///   底部「复制文字」按钮；背景 NSVisualEffectView(.hudWindow)，圆角 10
/// - Esc 关闭；⌘C 复制；「复制文字」复制后关窗；失去 key 不自动关闭
/// - text 为空时显示「未识别到文字」占位，仍可 Esc 关闭
@MainActor
enum OCRResultPanel {
    /// 常驻期间的控制器引用（面板存活由这里持有）
    fileprivate static var controller: OCRPanelController?

    static func present(text: String, nearGlobalRect rect: CGRect, on screen: NSScreen) {
        // 重复 present：先关旧面板，同一时刻只存在一张结果浮层
        controller?.close()
        let newController = OCRPanelController(text: text, nearGlobalRect: rect, on: screen)
        controller = newController
        newController.present()
    }
}

/// 面板窗口（无边框面板默认 canBecomeKey=false，必须显式放开才能收键盘）
private final class OCRResultPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 面板生命周期 + 键盘监听 + 复制动作的实际持有者
@MainActor
private final class OCRPanelController {
    private static let margin: CGFloat = 8

    private let panel: OCRResultPanelWindow
    private let textView: NSTextView
    /// 真正要复制进剪贴板的识别文本（占位文案不参与复制）
    private let recognizedText: String
    private let isEmptyResult: Bool
    private var keyMonitor: Any?

    init(text: String, nearGlobalRect rect: CGRect, on screen: NSScreen) {
        isEmptyResult = text.isEmpty
        recognizedText = text

        // 尺寸：宽 min(520, 选区宽)、高 min(360, 选区高)，且不超过屏幕内缩边界
        let size = Self.clampSize(
            CGSize(width: min(520, rect.width), height: min(360, rect.height)),
            screen: screen
        )
        let frame = Self.place(size: size, near: rect, on: screen)

        let panel = OCRResultPanelWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 背景：hudWindow 磨砂 + 10pt 连续曲率圆角
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        // 顶部提示行
        let hintHeight: CGFloat = 24
        let hint = NSTextField(labelWithString: "识别结果 · ⌘C 复制 · Esc 关闭")
        hint.isEditable = false
        hint.isBordered = false
        hint.drawsBackground = false
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: 12, y: size.height - hintHeight - 6, width: size.width - 24, height: hintHeight)
        hint.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]

        // 中间文本区：可编辑可选中；空结果显示占位文案且不可编辑
        let bottomInset: CGFloat = 44
        let textView = NSTextView(
            frame: NSRect(x: 12, y: bottomInset, width: size.width - 24, height: size.height - hintHeight - bottomInset - 14)
        )
        textView.autoresizingMask = [.width, .height]
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        if isEmptyResult {
            textView.string = "未识别到文字"
            textView.textColor = .tertiaryLabelColor
            textView.isEditable = false
        } else {
            textView.string = text
            textView.isEditable = true
        }
        textView.isSelectable = true

        self.panel = panel
        self.textView = textView

        // 底部「复制文字」按钮（target=self，需在所有存储属性赋完后再建）
        let button = NSButton(title: "复制文字", target: self, action: #selector(copyAndClose))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        let buttonSize = button.intrinsicContentSize
        let buttonWidth = max(96, buttonSize.width)
        button.frame = NSRect(
            x: (size.width - buttonWidth) / 2,
            y: 10,
            width: buttonWidth,
            height: 26
        )
        button.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]

        effect.addSubview(textView)
        effect.addSubview(hint)
        effect.addSubview(button)
        panel.contentView = effect
    }

    func present() {
        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
        if !isEmptyResult {
            panel.makeFirstResponder(textView)
            // 自动全选，方便直接 ⌘C
            textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        }
        Log.event(.ocr, "ocr.panel.present", [
            "w": "\(Int(panel.frame.width))",
            "h": "\(Int(panel.frame.height))",
            "chars": "\(recognizedText.count)",
        ])
    }

    /// Esc 关闭；⌘C 复制（本地监听只作用于本面板为 keyWindow 的事件，返回 nil 拦截）
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { // kVK_Escape
                self.close()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "c" {
                self.copyText(closeAfter: false)
                return nil
            }
            return event
        }
    }

    @objc private func copyAndClose() {
        if isEmptyResult {
            close()
        } else {
            copyText(closeAfter: true)
        }
    }

    private func copyText(closeAfter: Bool) {
        guard !recognizedText.isEmpty else {
            if closeAfter { close() }
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recognizedText, forType: .string)
        Log.event(.ocr, "ocr.panel.copied", ["chars": "\(recognizedText.count)"])
        if closeAfter { close() }
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

    /// 尺寸再内缩：不超过屏幕 frame 减边距（选区大于屏幕时兜底）
    private static func clampSize(_ size: CGSize, screen: NSScreen) -> CGSize {
        let limit = CGSize(
            width: screen.frame.width - margin * 2,
            height: screen.frame.height - margin * 2
        )
        return CGSize(
            width: max(80, min(size.width, limit.width)),
            height: max(48, min(size.height, limit.height))
        )
    }

    /// 居中贴到选区附近，越界则内缩回屏幕 frame 内
    private static func place(size: CGSize, near rect: CGRect, on screen: NSScreen) -> CGRect {
        var origin = CGPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        origin.x = max(screen.frame.minX + margin, min(origin.x, screen.frame.maxX - size.width - margin))
        origin.y = max(screen.frame.minY + margin, min(origin.y, screen.frame.maxY - size.height - margin))
        return CGRect(origin: origin, size: size)
    }
}
