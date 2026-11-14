import AppKit
import CoreGraphics

/// 编辑会话：选区冻结后的标注编辑状态（v0.3 功能 + 工具栏）
///
/// 关键设计（需求「截图时隐藏工具栏/工具栏不入截图」的实现基础）：
/// 底图在 mouseUp 瞬间、工具栏出现**之前**就截好（frozen base），
/// 之后所有编辑 UI（工具栏/手柄/预览）都只画在屏幕上，导出 = 底图 + 标注合成，
/// 工具栏天然不可能进图。
@MainActor
final class EditorSession {
    enum Tool: Int, CaseIterable {
        case arrow = 1
        case rect = 2
        case text = 3
        case mosaic = 4
        case sequence = 5
        case highlight = 6

        var label: String {
            switch self {
            case .arrow: return "箭头"
            case .rect: return "矩形"
            case .text: return "文字"
            case .mosaic: return "马赛克"
            case .sequence: return "序号"
            case .highlight: return "高亮"
            }
        }
    }

    /// 冻结底图（选区像素，scale 已含）
    let baseImage: CGImage
    let scale: CGFloat
    let selectionGlobal: CGRect
    let screen: NSScreen

    let store = AnnotationStore()

    var currentTool: Tool = .arrow
    var colorIndex = 0
    var strokeWidth = 2
    var toolbarVisible = true

    init(baseImage: CGImage, scale: CGFloat, selectionGlobal: CGRect, screen: NSScreen) {
        self.baseImage = baseImage
        self.scale = scale
        self.selectionGlobal = selectionGlobal
        self.screen = screen
    }

    // MARK: - 导出

    /// 合成最终图：底图 + 标注（含马赛克像素化），编辑器所见 = 导出所得
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
        return CGRenderer.composite(base: image, annotations: store.annotations, scale: scale)
    }
}
