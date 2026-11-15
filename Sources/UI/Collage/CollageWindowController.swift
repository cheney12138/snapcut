import AppKit
import CoreGraphics

/// 拼贴画布窗口（C2 交付物 1，docs/06 §4 Adapters/UI: CollageWindow）
///
/// 单例风格（AppCoordinatorShared / SettingsWindowController.shared 同款）：
/// 全局唯一画布窗，常驻不释放（关窗只 orderOut，文档保留在 history 里，
/// 托盘「新建拼贴」/编辑器「贴图」/⌘⇧A 连续截图随时再入）。
///
/// 对接 C1 接口：
/// - 文档唯一真相源 = `CollageHistory`（值快照 undo/redo）；
/// - 新贴片落位 = `SnapGeometry.nextGridSlot` → `doc.adding`（画布自动扩展，
///   CollageDocument.recomputeCanvas 负责内容 bounding box + padding）；
/// - imageRef 键图像存 `CollageImageCache`。
@MainActor
final class CollageWindowController: NSWindowController, NSWindowDelegate, CollageMergeTarget {


    static let shared = CollageWindowController()

    /// 拼贴窗是否正打开（AppCoordinator 复制路径 / OverlayController 贴图按钮的
    /// 「画布激活重定向」判据）
    var isActive: Bool { window?.isVisible ?? false }

    private var history = CollageHistory()
    private var canvasView: CollageCanvasView?

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CollageWindowController 只走单例代码创建") }

    // MARK: - 打开（托盘「新建拼贴」入口）

    /// 打开画布窗并载入文档（已开着则前置 + 换文档内容）
    func openDocument(_ doc: CollageDocument) {
        guard let window = makeWindowIfNeeded() else { return }
        history = CollageHistory(document: doc)
        canvasView?.clearSelection()
        syncCanvas()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.event(.app, "collage.open", [
            "pieces": "\(doc.pieces.count)",
            "annotations": "\(doc.annotations.count)",
        ])
    }

    // MARK: - 加贴片（⌘⇧A 连续截图 / 编辑器「贴图」重定向入口）

    /// 图像飞入画布：nextGridSlot 找格位 → doc.adding（画布如需扩展自动）。
    /// 拼贴未打开时先开窗（用户从托盘/热键直接来的场景同样成立）。
    /// CollageMergeTarget 协议实现（Pin 侧合并入口）：
    /// at 为屏幕全局点（AppKit Y-up），nil = nextGridSlot 自动格位
    func acceptPiece(image: CGImage, at: CGPoint?) {
        // TODO(C2 迭代): at 全局点 → 画布坐标换算后落位；当前统一走自动格位
        addPiece(image: image)
    }

    func addPiece(image: CGImage) {
        let ref = "collage-" + UUID().uuidString
        CollageImageCache.shared.store(image, for: ref)

        let size = Self.fittedPointSize(for: image)
        let doc = history.document
        let origin = SnapGeometry.nextGridSlot(
            occupied: doc.pieces.map(\.frame),
            pieceSize: size,
            gutter: SnapGeometry.defaultGutter
        )
        let piece = CollagePiece(
            imageRef: ref,
            frame: CGRect(origin: origin, size: size),
            showsPanelBorder: true   // 分镜框默认开（C1 约定）
        )
        if !isActive, let window = makeWindowIfNeeded() {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        apply(doc.adding(piece))
        Log.event(.app, "collage.piece.added", [
            "ref": ref, "w": "\(size.width)", "h": "\(size.height)",
        ])
    }

    // MARK: - 私有

    /// 截图像素 → 画布点尺寸：按 2x retina 折算，长边超 560pt 等比缩
    /// （分镜格排版下贴片过大不可读，560 ≈ 900 宽画布的三分之二）
    private static func fittedPointSize(for image: CGImage) -> CGSize {
        var size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let maxSide: CGFloat = 560
        let longest = max(size.width, size.height)
        if longest > maxSide {
            let k = maxSide / longest
            size = CGSize(width: size.width * k, height: size.height * k)
        }
        return size
    }

    /// 不可变更新入历史并同步画布（值快照 undo/redo 的唯一写入口）
    private func apply(_ next: CollageDocument) {
        history.apply(next)
        syncCanvas()
    }

    private func syncCanvas() {
        canvasView?.document = history.document
        canvasView?.needsDisplay = true
    }

    /// 常驻窗口：只建一次；关窗（windowWillClose）不释放，isActive 随 isVisible 翻转
    private func makeWindowIfNeeded() -> NSWindow? {
        if let window {
            // C3⇄C2 挂点接线：窗口活着即接受 Pin 侧合并（右键/⌥拖/drop）
            AppCoordinatorShared.collageTarget = self
            return window
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Snapcut 拼贴"
        // 坑（同 SettingsWindowController/ToolbarPanel）：材质跟随系统主题 ——
        // 浅色系统下不钉 appearance，标题栏/控件解析成浅色，画布深底上不可读
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenAuxiliary]

        let view = CollageCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        view.onDocumentChanged = { [weak self] next in self?.apply(next) }
        view.onAddImage = { [weak self] image in self?.addPiece(image: image) }
        // TODO(C4 导出): C4 交付后在此接 ExportCoordinator/CollageExporter 入口
        view.onExportRequested = {
            Log.event(.app, "collage.export.unwired")
        }
        window.contentView = view
        self.window = window
        canvasView = view
        Log.event(.app, "collage.window.created")
        return window
    }

    // MARK: - NSWindowDelegate（关窗只收起，文档与窗口都常驻）

    func windowWillClose(_ notification: Notification) {
        AppCoordinatorShared.collageTarget = nil

        Log.event(.app, "collage.window.close", ["pieces": "\(history.document.pieces.count)"])
    }
}
