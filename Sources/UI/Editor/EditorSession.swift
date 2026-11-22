import AppKit
import CoreGraphics

/// 可传递的编辑会话导出快照（供上层在会话结束后持久化可重编矢量层与原始底图）
struct EditableExportSnapshot: Sendable {
    let baseImage: CGImage
    let canvasSize: CGSize
    let annotations: [AnnotationModel]
    let strokeWidth: CGFloat
    let sourceApp: String?
    let windowTitle: String?
}

/// 编辑会话：选区冻结后的标注编辑状态（v0.3 功能 + 工具栏）
///
/// 关键设计（需求「截图时隐藏工具栏/工具栏不入截图」的实现基础）：
/// 底图在 mouseUp 瞬间、工具栏出现**之前**就截好（frozen base），
/// 之后所有编辑 UI（工具栏/手柄/预览）都只画在屏幕上，导出 = 底图 + 标注合成，
/// 工具栏天然不可能进图。
@MainActor
final class EditorSession {
    enum Tool: Int, CaseIterable {
        /// 无工具（用户裁定 2026-11-16：编辑器默认态——拖动=移动选区；
        /// 数字键选工具、再按同键取消回 none）
        ///
        /// case 声明序 = 工具栏按钮序（allCases 建按钮）：重设计版工具组顺序
        /// 「箭头 矩形 椭圆 文字 马赛克 序号 高亮 滚动」——椭圆紧贴矩形成形状组。
        /// rawValue 保持原值不动：数字热键（EditorKeyRouter 按名映射 1-7）、
        /// 按钮 tag / Tool(rawValue:) 全部不受影响。
        case none = 0
        case arrow = 1
        case rect = 2
        /// 椭圆/圆（圆心起拖：用户裁定 2026-11-16 新增「圆心圈选」）
        case ellipse = 7
        case text = 3
        case mosaic = 4
        case sequence = 5
        case highlight = 6

        var label: String {
            switch self {
            case .none: return "移动"
            case .arrow: return "箭头"
            case .ellipse: return "椭圆"
            case .rect: return "矩形"
            case .text: return "文字"
            case .mosaic: return "马赛克"
            case .sequence: return "序号"
            case .highlight: return "高亮"
            }
        }
    }

    /// 冻结底图（选区像素，scale 已含）。选区调整后会按新选区从冻结帧重裁
    private(set) var baseImage: CGImage
    private(set) var scale: CGFloat
    private(set) var selectionGlobal: CGRect
    let screen: NSScreen
    /// 边缘主色缓存（双层 Optional 区分「尚未计算」与「已算但返回 nil」）
    private var cachedEdgeColor: RGBAColor??

    /// 选区调整（拖手柄 / 方向键）：换底图 + 平移既有标注，保证标注钉在图像上
    func applySelectionChange(newSelection: CGRect, newBase: CGImage, annotationOffset: CGSize) {
        store.offsetAll(dx: annotationOffset.width, dy: annotationOffset.height)
        baseImage = newBase
        cachedEdgeColor = nil
        selectionGlobal = newSelection
        scale = CGFloat(newBase.width) / max(1, newSelection.width)
        Log.event(.editor, "editor.selection.change", [
            "pxW": "\(newBase.width)", "pxH": "\(newBase.height)",
            "ptW": "\(Int(newSelection.width))", "ptH": "\(Int(newSelection.height))",
        ])
    }

    /// 独立外源图视口缩放/平移（无冻结桌面）：底图像素不变，按新展示矩形更新 scale 并同步缩放既有标注
    func applyViewportTransform(newSelection: CGRect) {
        let oldWidth = max(1, selectionGlobal.width)
        let ratio = newSelection.width / oldWidth
        if abs(ratio - 1) > 0.0001 {
            store.scaleAll(by: ratio)
        }
        selectionGlobal = newSelection
        scale = CGFloat(baseImage.width) / max(1, newSelection.width)
    }

    let store = AnnotationStore()

    var currentTool: Tool = .none
    var colorIndex = 0
    var strokeWidth: CGFloat = 2   // 连续 2-6pt（工具栏滑杆实时调节；下一个新标注用当前值）
    var toolbarVisible = true

    /// 文字工具当前档位（4 档：12/14/17/21，默认 14）
    /// 真相源在 session：浮动字号面板（OverlayWindow）与未来的工具栏控件都读写它
    var textFontSize: Int = 14

    /// 克制画框美化样式（每次新会话默认 enabled == false，保留上次色板/边距/比例/均衡偏好）
    var backdropStyle: BackdropStyle = BackdropStyle.loadSavedPreference()

    init(baseImage: CGImage, scale: CGFloat, selectionGlobal: CGRect, screen: NSScreen) {
        self.baseImage = baseImage
        self.scale = scale
        self.selectionGlobal = selectionGlobal
        self.screen = screen
    }

    // MARK: - 画框美化

    func backdropEdgeColor() -> RGBAColor? {
        if let cached = cachedEdgeColor { return cached }
        let detected = CGRenderer.detectEdgeColor(of: baseImage)
        cachedEdgeColor = .some(detected)
        return detected
    }

    func currentBackdropLayout(for selectionSize: CGSize) -> BackdropLayout? {
        guard backdropStyle.enabled else { return nil }
        let edgeColor = backdropStyle.autoBalance ? backdropEdgeColor() : nil
        let inset = CGRenderer.effectiveBalanceInset(
            for: backdropStyle,
            imagePointSize: selectionSize,
            edgeColor: edgeColor
        )
        return backdropStyle.layout(for: selectionSize, balanceInset: inset)
    }

    // MARK: - 恢复与快照

    /// 从历史/Toast 恢复矢量标注，按当前画布与保存时画布宽度比例精确缩放并重建撤销栈
    func restoreAnnotations(_ annotations: [AnnotationModel], savedCanvasSize: CGSize?) {
        let scaled: [AnnotationModel]
        if let savedCanvasSize, savedCanvasSize.width > 1 {
            let ratio = selectionGlobal.width / savedCanvasSize.width
            if ratio > 0, abs(ratio - 1) > 0.0001 {
                scaled = annotations.map { $0.scaled(by: ratio) }
            } else {
                scaled = annotations
            }
        } else {
            scaled = annotations
        }
        store.restore(annotations: scaled)
    }

    /// 导出当前编辑会话快照（在 end() 销毁 editorSession 之前调用）
    func makeExportSnapshot(sourceApp: String?, windowTitle: String?) -> EditableExportSnapshot {
        EditableExportSnapshot(
            baseImage: baseImage,
            canvasSize: selectionGlobal.size,
            annotations: store.annotations,
            strokeWidth: strokeWidth,
            sourceApp: sourceApp,
            windowTitle: windowTitle
        )
    }

    // MARK: - 导出

    /// 合成最终图：底图 + 标注（含马赛克像素化 + 可选画框美化），编辑器所见 = 导出所得
    func renderFinalImage() -> CGImage {
        var image = baseImage
        // 先马赛克（直接改底图像素），再画矢量标注
        for annotation in store.annotations {
            if case .mosaic(let localRect) = annotation.shape {
                let pxRect = CGRect(
                    x: localRect.minX * scale,
                    y: localRect.minY * scale,
                    width: localRect.width * scale,
                    height: localRect.height * scale
                )
                image = CGRenderer.pixelate(image: image, rect: pxRect, blockSize: max(2, Int(strokeWidth + 4)))
            }
        }
        let composited = CGRenderer.composite(base: image, annotations: store.annotations, scale: scale)
        guard backdropStyle.enabled else { return composited }
        return CGRenderer.renderWithBackdrop(
            image: composited,
            style: backdropStyle,
            scale: scale,
            precomputedEdgeColor: backdropStyle.autoBalance ? backdropEdgeColor() : nil
        )
    }
}
