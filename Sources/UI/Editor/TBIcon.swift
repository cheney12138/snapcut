import AppKit

/// 工具栏图标工厂：全面采用 Apple 原生 SF Symbols 矢量渲染 + 光学字号微调 + Hierarchical 分层质感。
///
/// 相比早期手绘 16×16 2x 位图：
/// - 原生矢量随任意 DPI 屏幕锐利呈现，具备 SF Pro 同源光学字重补偿与连续圆角曲率；
/// - 复合图标启用 `.preferringHierarchical()` 保持 `isTemplate = true`，
///   随 `NSButton.contentTintColor` 自动在浅/暗玻璃、悬停、选中态之间呈现主次层次；
/// - 针对不同字形的视觉体量做 ±1pt 光学平衡（如 `xmark` 收紧至 14pt、形状类统一 15.5pt），
///   让整排 16 个图标视觉中轴与墨量完全对齐。
@MainActor
enum TBIcon {
    /// 图标全集（与工具栏按钮一一对应）
    enum Kind {
        case arrow, rect, text, mosaic, sequence, highlight, ellipse
        case undo, redo, ocr, pin, backdrop, eye, more
        case save, cancel, copy, scroll
    }

    private struct Spec {
        let symbol: String
        let pointSizeDelta: CGFloat
        let weight: NSFont.Weight
        let hierarchical: Bool
    }

    private static func spec(for kind: Kind) -> Spec {
        switch kind {
        case .arrow:
            return Spec(symbol: "arrow.up.right", pointSizeDelta: 0, weight: .medium, hierarchical: false)
        case .rect:
            return Spec(symbol: "rectangle", pointSizeDelta: 0.5, weight: .medium, hierarchical: false)
        case .ellipse:
            return Spec(symbol: "oval", pointSizeDelta: 0.5, weight: .medium, hierarchical: false)
        case .text:
            return Spec(symbol: "character.textbox", pointSizeDelta: 0, weight: .medium, hierarchical: true)
        case .mosaic:
            return Spec(symbol: "checkerboard.rectangle", pointSizeDelta: 0.5, weight: .medium, hierarchical: true)
        case .sequence:
            return Spec(symbol: "1.circle", pointSizeDelta: 0, weight: .medium, hierarchical: true)
        case .highlight:
            return Spec(symbol: "highlighter", pointSizeDelta: 0, weight: .medium, hierarchical: true)
        case .scroll:
            return Spec(symbol: "rectangle.expand.vertical", pointSizeDelta: 0, weight: .medium, hierarchical: true)
        case .undo:
            return Spec(symbol: "arrow.uturn.backward", pointSizeDelta: -0.5, weight: .medium, hierarchical: false)
        case .redo:
            return Spec(symbol: "arrow.uturn.forward", pointSizeDelta: -0.5, weight: .medium, hierarchical: false)
        case .ocr:
            return Spec(symbol: "text.viewfinder", pointSizeDelta: 0, weight: .medium, hierarchical: true)
        case .pin:
            return Spec(symbol: "pin", pointSizeDelta: -0.5, weight: .medium, hierarchical: false)
        case .backdrop:
            return Spec(symbol: "sparkles.rectangle.stack", pointSizeDelta: 0, weight: .medium, hierarchical: true)
        case .eye:
            return Spec(symbol: "eye", pointSizeDelta: -0.5, weight: .medium, hierarchical: true)
        case .more:
            return Spec(symbol: "ellipsis", pointSizeDelta: -0.5, weight: .semibold, hierarchical: false)
        case .copy:
            return Spec(symbol: "doc.on.doc", pointSizeDelta: -1.0, weight: .medium, hierarchical: false)
        case .save:
            return Spec(symbol: "square.and.arrow.down", pointSizeDelta: -0.5, weight: .medium, hierarchical: true)
        case .cancel:
            return Spec(symbol: "xmark", pointSizeDelta: -1.5, weight: .semibold, hierarchical: false)
        }
    }

    static func image(_ kind: Kind, pointSize: CGFloat = 15.5) -> NSImage {
        let s = spec(for: kind)
        return symbolImage(
            named: s.symbol,
            pointSize: max(11, pointSize + s.pointSizeDelta),
            weight: s.weight,
            hierarchical: s.hierarchical
        )
    }

    static func symbolImage(
        named name: String,
        pointSize: CGFloat = 15.0,
        weight: NSFont.Weight = .medium,
        hierarchical: Bool = true
    ) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
        if hierarchical {
            config = config.applying(.preferringHierarchical())
        }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let configured = base.withSymbolConfiguration(config) else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        configured.isTemplate = true
        return configured
    }
}
