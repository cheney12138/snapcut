import AppKit
import CoreGraphics

/// 拖拽源持久代理（Pattern 铁律：beginDraggingSession 的 source 会话期间不能释放 → 单例）
@MainActor
final class DragSourceCoordinator: NSObject {
    static let shared = DragSourceCoordinator()

    /// 拖拽进行中标记（浮窗 tick 据此冻结一切重定位与消失）
    var isDragging = false
}

// NSDraggingSource 的一致性实现：回调都在主线程，用 assumeIsolated 桥接
extension DragSourceCoordinator: NSDraggingSource {
    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        MainActor.assumeIsolated { .copy }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint
    ) {
        MainActor.assumeIsolated {
            isDragging = true
            Log.event(.permission, "drag.begin")
        }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        MainActor.assumeIsolated {
            isDragging = false
            Log.event(.permission, "drag.end", ["op": "\(operation.rawValue)"])
        }
    }
}

/// 可拖拽的 App 图标视图（热区 = 图标本身，位移 ≥5pt 才起拖，区分点击）
@MainActor
final class DraggableAppIconView: NSImageView {
    private var pressOrigin: CGPoint?
    private var dragStarted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = IconFactory.appIcon(pointSize: min(frameRect.width, frameRect.height))
        imageScaling = .scaleProportionallyUpOrDown
        // ⚠️ 不用 isEnabled=false 隔离事件（NSImageView 会画淡化态），也不设 isEditable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = convert(event.locationInWindow, from: nil)
        dragStarted = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, !dragStarted else { return }
        let current = convert(event.locationInWindow, from: nil)
        let delta = hypot(current.x - origin.x, current.y - origin.y)
        if delta >= 5 {
            dragStarted = true
            beginDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
        dragStarted = false
        super.mouseUp(with: event)
    }

    /// AppKit 原生拖拽：负载与 Finder 逐字等价（NSURL file URL → public.file-url）
    /// ⚠️ SwiftUI onDrag 的 NSItemProvider 负载系统设置不认，勿改
    private func beginDrag(with event: NSEvent) {
        let appURL = Bundle.main.bundleURL as NSURL

        let item = NSDraggingItem(pasteboardWriter: appURL)
        let iconSize = frame.size
        // 拖拽影像 = 图标本身，热点居中
        item.setDraggingFrame(
            NSRect(origin: CGPoint(x: -iconSize.width / 2, y: -iconSize.height / 2), size: iconSize),
            contents: IconFactory.appIcon(pointSize: min(iconSize.width, iconSize.height))
        )
        beginDraggingSession(with: [item], event: event, source: DragSourceCoordinator.shared)
    }
}

/// 浮窗内容：HUD 材质背景 + 可拖图标 + 引导文案 + 关闭按钮
@MainActor
final class PanelContentView: NSView {
    private unowned let overlay: PermissionDragOverlay

    init(frame frameRect: NSRect, overlay: PermissionDragOverlay) {
        self.overlay = overlay
        super.init(frame: frameRect)
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func buildSubviews() {
        // HUD 磨砂背景
        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        addSubview(effect)

        // 可拖拽图标（48pt，左侧）
        let iconSize: CGFloat = 48
        let iconY = bounds.midY - iconSize / 2
        let icon = DraggableAppIconView(
            frame: NSRect(x: 16, y: iconY, width: iconSize, height: iconSize)
        )
        addSubview(icon)

        // 文案（右侧）
        let textX: CGFloat = 76
        let title = NSTextField(labelWithString: "拖我到「屏幕录制」列表")
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: textX, y: bounds.midY + 2, width: bounds.width - textX - 24, height: 16)
        title.lineBreakMode = .byWordWrapping
        addSubview(title)

        let subtitle = NSTextField(labelWithString: "松手即完成授权")
        subtitle.font = NSFont.systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: textX, y: bounds.midY - 14, width: bounds.width - textX - 24, height: 13)
        addSubview(subtitle)

        // 关闭按钮（右上角）
        let close = NSButton(
            title: "✕",
            target: self,
            action: #selector(closeTapped)
        )
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        close.frame = NSRect(x: bounds.width - 22, y: bounds.height - 20, width: 16, height: 16)
        addSubview(close)
    }

    @objc private func closeTapped() {
        overlay.dismiss()
    }
}
