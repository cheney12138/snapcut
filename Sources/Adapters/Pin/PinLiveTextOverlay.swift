import AppKit
import CoreGraphics
import VisionKit

/// 实况文本（Live Text）分析器：进程内复用同一个 `ImageAnalyzer`（Apple 明确建议：
/// 每次分析新建 analyzer 会在首次调用时反复做模型加载，贴图批量拖出来会明显卡顿）。
///
/// 纪律：系统不支持（`ImageAnalyzer.isSupported` = false，如 Intel Mac / 关闭实况文本）
/// 时一律返回 nil，调用方按「无文字」降级，绝不崩、绝不弹系统错误。
enum PinLiveTextAnalyzer {
    /// 当前机器是否支持实况文本（贴图悬停按钮与右键项据此显隐）
    static var isSupported: Bool { ImageAnalyzer.isSupported }

    /// 共享分析器：ImageAnalyzer 本身线程安全（VisionKit 内部串行化），进程内一个足够
    private static let sharedAnalyzer = ImageAnalyzer()

    /// 静默分析一张图（文字 + 机器可读码）。失败只记日志，返回 nil。
    static func analyze(_ cgImage: CGImage) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }
        let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
        do {
            return try await sharedAnalyzer.analyze(
                cgImage,
                orientation: .up,
                configuration: configuration
            )
        } catch {
            Log.error(.pin, "pin.livetext.fail", ["err": "\(error.localizedDescription)"])
            return nil
        }
    }
}

/// 实况文本宿主容器视图。
///
/// 【为什么必须是非翻转容器】`PinContentView` 是 `isFlipped == true`，而
/// `ImageAnalysisOverlayView` 依赖所属视图坐标系做 contentsRect → 图像坐标的映射；
/// 直接塞进翻转视图会让选区整体上下颠倒（文字框出现在相反方向）。本容器
/// `isFlipped == false` 且铺满贴图 bounds，VisionKit 的归一化坐标（左下原点）与
/// AppKit 非翻转坐标系天然一致 ⇒ 选区 100% 像素级贴合图像。
///
/// 会话生命周期：静默分析由 `PinWindowController` 负责（后台跑），本视图只负责
/// 「装上分析结果 / 卸下 / 选中态读写」。初始 `preferredInteractionTypes = []`
/// 确保未激活时绝不抢贴图的拖动与滚轮。
@MainActor
final class PinLiveTextHostView: NSView, ImageAnalysisOverlayViewDelegate {
    private let overlayView = ImageAnalysisOverlayView()

    /// 是否处于划词态（分析结果已装上且系统交互已开启）
    private(set) var isActive = false

    /// 划词态下的滚轮/捏合透传：缩放与 ⌥ 透明度调节必须照常可用
    var onScrollWheel: ((NSEvent) -> Void)?
    var onMagnify: ((NSEvent) -> Void)?

    /// overlay 几何尺寸变更检测：只在窗口尺寸真的变化时重排内部 overlay，避免 layout 自激
    private var lastOverlaySize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 与贴图本体同圆角：overlay 的选中高亮在圆角内被裁切，不会溢出卡片之外
        layer?.cornerRadius = PinContentView.cornerRadius
        layer?.masksToBounds = true
        isHidden = true

        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        overlayView.delegate = self
        // 系统自带的右下角「实况文本」灰按钮：隐藏，统一用贴图右上角 Snapcut 同源圆钮
        overlayView.isSupplementaryInterfaceHidden = true
        // 初始关闭交互：未激活态由 hitTest 直接透传，双保险
        overlayView.preferredInteractionTypes = []
        addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PinLiveTextHostView 只走代码创建") }

    // MARK: - 坐标（关键：非翻转）

    override var isFlipped: Bool { false }

    /// 内容区域 = 整块 bounds（图像 1:1 铺满，无 letterbox）
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != lastOverlaySize else { return }
        lastOverlaySize = size
        overlayView.frame = bounds
        // 贴图被滚轮/捏合缩放时几何要跟着刷新，否则文字框停在旧位置。
        // macOS 的 NSView 没有 setNeedsLayout()（那是 UIKit），VisionKit 专用的是
        // setContentsRectNeedsUpdate() + needsLayout 置位。
        overlayView.needsLayout = true
        overlayView.setContentsRectNeedsUpdate()
    }

    // MARK: - 状态

    /// 当前是否有选中的文字片段
    var hasSelection: Bool { isActive && overlayView.hasActiveTextSelection }

    /// 当前选中的文字（未激活态恒为空）
    var selectedText: String { isActive ? overlayView.selectedText : "" }

    // MARK: - 会话开关

    func activate(with analysis: ImageAnalysis) {
        overlayView.analysis = analysis
        overlayView.preferredInteractionTypes = [.textSelection, .dataDetectors]
        isActive = true
        isHidden = false
        overlayView.frame = bounds
        overlayView.needsLayout = true
        overlayView.setContentsRectNeedsUpdate()
    }

    func deactivate() {
        overlayView.resetSelection()
        overlayView.preferredInteractionTypes = []
        isActive = false
        isHidden = true
    }

    func clearSelection() {
        overlayView.resetSelection()
    }

    /// 全选：优先走 overlay 自身的 selectAll，失败则沿响应链投递标准 selectAll:
    func selectAllText() {
        guard isActive else { return }
        overlayView.selectAll(nil)
        if !overlayView.hasActiveTextSelection {
            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: overlayView, from: nil)
        }
    }

    /// 复制选中文字。返回 false 表示「当前没有选区」（调用方据此降级为复制图像）。
    @discardableResult
    func copySelectedText() -> Bool {
        guard isActive, overlayView.hasActiveTextSelection else { return false }
        let text = overlayView.selectedText
        if text.isEmpty {
            // 选区存在但系统没给出可读文本（极少见）：退回标准 copy: 让 overlay 自己处理
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        } else {
            Self.writeTextToPasteboard(text)
        }
        return true
    }

    /// 文本写剪贴板：优先走合成根注入的端口（带统一日志），未初始化时直写 NSPasteboard
    private static func writeTextToPasteboard(_ text: String) {
        if let clipboard = AppCoordinatorShared.deps?.clipboard {
            _ = clipboard.writeText(text)
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let ok = pasteboard.setString(text, forType: .string)
            Log.event(.clipboard, "clipboard.write", [
                "fmts": "text", "bytes": "\(text.utf8.count)", "ok": "\(ok)",
            ])
        }
    }

    // MARK: - 交互透传保护

    /// 未激活 → 完全透传（贴图拖动/双击/右键照旧）；激活态按住 ⌘ → 同样透传，
    /// 让「⌘拖整组移动」在划词态下依然可用。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive else { return nil }
        guard !NSEvent.modifierFlags.contains(.command) else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        // 划词态依然要能滚轮缩放 / ⌥+滚轮调透明度
        onScrollWheel?(event)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event)
    }
}
