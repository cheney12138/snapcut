import CoreGraphics
import Foundation

/// 已画标注二次编辑的真实验证入口（纯 Core，不依赖 App / AppKit / Vision）。
/// 由 scripts/test-annotation-editing.sh 编译运行：
/// AnnotationModel.swift + AnnotationEditing.swift + RGBAColor.swift + Shared/Log.swift + 本文件。
///
/// 覆盖：7 种 Shape 的包围盒 / 本体命中原语（箭头·高亮线段距离、矩形描边环与内部穿透、
/// 椭圆环与极小椭圆退化、马赛克实体、序号徽章、文字框）/ 顶层优先 /
/// 操控柄布局与命中优先级 / `.body` 平移 / 箭头端点与四角缩放（含跨对角翻转、minSize 保底、
/// 椭圆回算）/ 形状与手柄不匹配 / AnnotationStore 预览+单步撤销、无变化不污染撤销栈、
/// 删除与改样式（含调色板同色等价）。
@main
struct TestAnnotationEditingMain {

    // MARK: - 入口

    @MainActor
    static func main() {
        do {
            try test1BoundingRectAllShapes()
            try test2ArrowAndHighlightHit()
            try test3RectRingAndInteriorPassThrough()
            try test4EllipseRingAndTinyFallback()
            try test5MosaicSequenceTextHit()
            try test6TopmostPriority()
            try test7HandleLayout()
            try test8HitTestHandlePriority()
            try test9BodyTranslation()
            try test10ArrowEndpointTransform()
            try test11RectCornerResize()
            try test12EllipseCornerResize()
            try test13HandleShapeMismatch()
            try test14PreviewAndSingleStepUndo()
            try test15NoChangeKeepsUndoStackClean()
            try test16RemoveAndUpdateStyle()
            print("[TestAnnotationEditing] ALL PASS ✅")
        } catch {
            print("[TestAnnotationEditing] FAILED ❌: \(error)")
            exit(1)
        }
    }

    // MARK: - 场景 1：7 种 Shape 的包围盒

    static func test1BoundingRectAllShapes() throws {
        print("[TestAnnotationEditing] 场景1: 7 种 Shape 的 boundingRect")

        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 70))),
                textSize: nil
            ),
            CGRect(x: 10, y: 20, width: 100, height: 50),
            "箭头两点外接矩形"
        )
        // 反向拖拽的高亮笔：宽高为负也要归一
        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.highlight(from: CGPoint(x: 110, y: 70), to: CGPoint(x: 10, y: 20))),
                textSize: nil
            ),
            CGRect(x: 10, y: 20, width: 100, height: 50),
            "高亮反向拖拽归一"
        )
        // 负尺寸矩形（拖出负宽高）同样归一
        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.rect(CGRect(x: 300, y: 300, width: -200, height: -150))),
                textSize: nil
            ),
            CGRect(x: 100, y: 150, width: 200, height: 150),
            "矩形负尺寸归一"
        )
        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.mosaic(CGRect(x: 300, y: 300, width: -200, height: -150))),
                textSize: nil
            ),
            CGRect(x: 100, y: 150, width: 200, height: 150),
            "马赛克负尺寸归一"
        )
        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.ellipse(center: CGPoint(x: 200, y: 200), radiusX: 100, radiusY: 60)),
                textSize: nil
            ),
            CGRect(x: 100, y: 140, width: 200, height: 120),
            "椭圆外接矩形"
        )
        // 负半径（构造期不该出现，但几何不能崩）
        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.ellipse(center: CGPoint(x: 200, y: 200), radiusX: -100, radiusY: -60)),
                textSize: nil
            ),
            CGRect(x: 100, y: 140, width: 200, height: 120),
            "椭圆负半径取绝对值"
        )

        // 序号：radius = diameter / 2 + 2，diameter = clamp(20 + strokeWidth * 2, 24, 34)
        try expectApprox(AnnotationEditorGeometry.sequenceRadius(strokeWidth: 2), 14, "序号半径 2pt → 14")
        try expectApprox(AnnotationEditorGeometry.sequenceRadius(strokeWidth: 1), 14, "序号半径 1pt 触底 24 直径")
        try expectApprox(AnnotationEditorGeometry.sequenceRadius(strokeWidth: 8), 19, "序号半径 8pt 顶到 34 直径")
        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.sequence(anchor: CGPoint(x: 300, y: 300)), strokeWidth: 2),
                textSize: nil
            ),
            CGRect(x: 286, y: 286, width: 28, height: 28),
            "序号徽章包围盒"
        )

        // 文字：anchor 是 **基线（baseline）**，与 CGRenderer.drawText 的 CTLine 绘制口径一致——
        // 视觉矩形 = 基线之上 ascent、基线之下 descent。（病例：旧实现把 anchor 当左上角 ⇒
        // 蓝框/悬停框/命中框整体比文字低一整个字高，字比框高）
        // 无实测尺寸时启发式：width = max(48, count × fontSize × 0.65)、ascent = fontSize × 0.95、descent = fontSize × 0.28
        let shortTextAnchor = CGPoint(x: 50, y: 60)
        let shortTextBox = AnnotationEditorGeometry.boundingRect(
            for: make(.text(anchor: shortTextAnchor), text: "hello", fontSize: 14),
            textSize: nil
        )
        try expectRect(
            shortTextBox,
            CGRect(x: 50, y: 60 - 14 * 0.95, width: 48, height: 14 * 0.95 + 14 * 0.28),
            "文字短文本估宽触底 48（基线口径）"
        )
        try expectTrue(shortTextBox.minY < shortTextAnchor.y, "文字框上沿在基线上方")
        try expectTrue(shortTextBox.maxY > shortTextAnchor.y, "文字框下沿在基线下方")
        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.text(anchor: CGPoint(x: 50, y: 60)), text: "0123456789", fontSize: 14),
                textSize: nil
            ),
            CGRect(x: 50, y: 60 - 14 * 0.95, width: 10 * 14 * 0.65, height: 14 * 0.95 + 14 * 0.28),
            "文字长文本按字数估宽（基线口径）"
        )
        // 只有宽高的旧口径：把高度按 0.79 / 0.21 拆成 ascent / descent，同样以基线对齐
        let sizedTextBox = AnnotationEditorGeometry.boundingRect(
            for: make(.text(anchor: shortTextAnchor), text: "hello", fontSize: 14),
            textSize: CGSize(width: 120, height: 20)
        )
        try expectRect(
            sizedTextBox,
            CGRect(x: 50, y: 60 - 20 * 0.79, width: 120, height: 20),
            "文字优先用实测尺寸（基线口径）"
        )
        try expectTrue(sizedTextBox.minY < shortTextAnchor.y && sizedTextBox.maxY > shortTextAnchor.y, "实测尺寸框跨过基线")
        // 精确排版度量（UI 用 CTLine 量出的真实 ascent/descent）：完全 1:1 贴合字形
        try expectRect(
            AnnotationEditorGeometry.boundingRect(
                for: make(.text(anchor: CGPoint(x: 50, y: 60)), text: "hello", fontSize: 14),
                textMetrics: AnnotationTextMetrics(width: 61.5, ascent: 13.2, descent: 3.6)
            ),
            CGRect(x: 50, y: 60 - 13.2, width: 61.5, height: 16.8),
            "文字精确度量按基线出框"
        )
    }

    // MARK: - 场景 2：箭头 / 高亮的线段命中

    static func test2ArrowAndHighlightHit() throws {
        print("[TestAnnotationEditing] 场景2: 箭头与高亮的线段命中")

        let arrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 50, y: 0), for: arrow), "箭头线上命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 50, y: 6), for: arrow), "箭头 6pt 容差内命中")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 50, y: 20), for: arrow), "箭头 20pt 外不命中")
        // 线段端点外按端点距离（端帽外 5pt 仍可点，20pt 不可点）
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: -5, y: 0), for: arrow), "箭头端点外 5pt 可点")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: -20, y: 0), for: arrow), "箭头端点外 20pt 不可点")
        // 退化线段（起终点重合）按点距
        let dot = make(.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10)), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 10, y: 14), for: dot), "退化线段按点距命中")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 10, y: 30), for: dot), "退化线段远处不命中")

        // 粗高亮笔比同线宽箭头容差更宽（strokeWidth * 1.5）
        let thickArrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)), strokeWidth: 12)
        let thickHighlight = make(.highlight(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)), strokeWidth: 12)
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 50, y: 15), for: thickArrow), "粗箭头 15pt 外不命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 50, y: 15), for: thickHighlight), "粗高亮 15pt 内命中")

        // 倒序遍历：同一条只是形状不同时按线宽判定优先，互不干扰
        let annotations = [thickArrow, thickHighlight]
        try expectEqual(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 50, y: 15), in: annotations), 1, "高亮更宽容差命中上层")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 50, y: 15), in: []) == nil, "空列表不命中")
    }

    // MARK: - 场景 3：矩形描边环 + 内部空白穿透

    static func test3RectRingAndInteriorPassThrough() throws {
        print("[TestAnnotationEditing] 场景3: 矩形描边环与内部穿透")

        let rect = make(.rect(CGRect(x: 100, y: 100, width: 200, height: 150)), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 100, y: 175), for: rect), "左边描边命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 300, y: 175), for: rect), "右边描边命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 200, y: 100), for: rect), "上边描边命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 200, y: 250), for: rect), "下边描边命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 95, y: 175), for: rect), "描边外 5pt 容差内命中")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 80, y: 175), for: rect), "描边外 20pt 不命中")
        // 内部空白不拦截
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 200, y: 175), for: rect), "矩形内部空白穿透")

        // 框内嵌套的文字：点中文字应命中文字（上层），而不是被矩形内部挡住
        // （文字 anchor 是基线 ⇒ 视觉框 y ∈ [160 - 15.8, 160 + 4.2]）
        let text = make(.text(anchor: CGPoint(x: 150, y: 160)), text: "内嵌", fontSize: 14)
        let stack: [AnnotationModel] = [rect, text]
        try expectEqual(
            AnnotationEditorGeometry.hitTestBody(
                at: CGPoint(x: 170, y: 160),
                in: stack,
                textSizeProvider: { $0.shape == text.shape ? CGSize(width: 40, height: 20) : nil }
            ),
            1,
            "框内文字可点（矩形内部穿透）"
        )
        try expectEqual(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 100, y: 175), in: stack), 0, "框边仍命中矩形")

        // 小框内缩塌陷 ⇒ 整块可点（否则 10pt 的框等于不可选）
        let tinyRect = make(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 5, y: 5), for: tinyRect), "小矩形塌陷后整块可点")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 40, y: 5), for: tinyRect), "小矩形远处不命中")

        // 负尺寸矩形（拖出负宽高）命中口径与归一后一致
        let reversed = make(.rect(CGRect(x: 300, y: 250, width: -200, height: -150)), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 100, y: 175), for: reversed), "负尺寸矩形归一后命中描边")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 200, y: 175), for: reversed), "负尺寸矩形内部穿透")
    }

    // MARK: - 场景 4：椭圆描边环 + 极小椭圆退化

    static func test4EllipseRingAndTinyFallback() throws {
        print("[TestAnnotationEditing] 场景4: 椭圆环命中与极小椭圆退化")

        let ellipse = make(.ellipse(center: CGPoint(x: 200, y: 200), radiusX: 100, radiusY: 60), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 300, y: 200), for: ellipse), "右边缘命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 100, y: 200), for: ellipse), "左边缘命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 200, y: 140), for: ellipse), "上边缘命中")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 200, y: 260), for: ellipse), "下边缘命中")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 200, y: 200), for: ellipse), "圆心空白穿透")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 400, y: 200), for: ellipse), "半径外 100pt 不命中")
        // 外接矩形四角不命中（椭圆不是矩形）
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 300, y: 260), for: ellipse), "外接矩形角不命中")

        // 极小椭圆：无法按「环」点中，退化为整块命中
        let tiny = make(.ellipse(center: CGPoint(x: 50, y: 50), radiusX: 8, radiusY: 8), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 50, y: 50), for: tiny), "极小椭圆圆心整块可点")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 58, y: 50), for: tiny), "极小椭圆边缘可点")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 95, y: 50), for: tiny), "极小椭圆远处不命中")

        // 半径为 0 的退化椭圆不能崩、按点距处理
        let zero = make(.ellipse(center: CGPoint(x: 10, y: 10), radiusX: 0, radiusY: 0), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 10, y: 10), for: zero), "零半径椭圆按点距命中")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 60, y: 10), for: zero), "零半径椭圆远处不命中")
    }

    // MARK: - 场景 5：马赛克实体 / 序号徽章 / 文字框

    static func test5MosaicSequenceTextHit() throws {
        print("[TestAnnotationEditing] 场景5: 马赛克实体、序号徽章、文字框")

        let mosaic = make(.mosaic(CGRect(x: 100, y: 100, width: 100, height: 100)), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 150, y: 150), for: mosaic), "马赛克内部命中（实体面积）")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 98, y: 150), for: mosaic), "马赛克外扩 4pt 内命中")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 90, y: 150), for: mosaic), "马赛克外扩 4pt 外不命中")

        let sequence = make(.sequence(anchor: CGPoint(x: 300, y: 300)), strokeWidth: 2)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 315, y: 300), for: sequence), "序号徽章半径+4 内命中")
        try expectTrue(!AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 320, y: 300), for: sequence), "序号徽章半径+4 外不命中")

        // 文字：anchor 是基线 ⇒ 命中区 = 字形框（基线之上/之下）外扩 dx 6 / dy 4
        let textAnchor = CGPoint(x: 50, y: 60)
        let text = make(.text(anchor: textAnchor), text: "abc", fontSize: 14)
        let metrics = AnnotationTextMetrics(width: 60, ascent: 16, descent: 4)   // 视觉 y ∈ [44, 64]
        try expectTrue(
            AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 80, y: 60), for: text, textMetrics: metrics),
            "文字框内（基线处）命中"
        )
        try expectTrue(
            AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 80, y: 46), for: text, textMetrics: metrics),
            "基线上方字形范围内命中"
        )
        try expectTrue(
            AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 114, y: 60), for: text, textMetrics: metrics),
            "文字框右外扩 6pt 内命中"
        )
        try expectTrue(
            !AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 120, y: 60), for: text, textMetrics: metrics),
            "文字框右外扩 6pt 外不命中"
        )
        try expectTrue(
            !AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 80, y: 36), for: text, textMetrics: metrics),
            "文字框上外扩 4pt 外不命中"
        )
        // 基线下方一整字高的旧实现落点不再算命中（只留 4pt 手指容差）
        try expectTrue(
            !AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 80, y: 76), for: text, textMetrics: metrics),
            "基线下方旧实现偏低区不再命中"
        )
        // 只有宽高的旧口径同样按基线对齐：ascent = 20 × 0.79 = 15.8 ⇒ y ∈ [44.2, 64.2]
        let legacyBox = CGSize(width: 60, height: 20)
        try expectTrue(
            AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 80, y: 60), for: text, textSize: legacyBox),
            "旧 textSize 口径命中"
        )
        try expectTrue(
            !AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 80, y: 38), for: text, textSize: legacyBox),
            "旧 textSize 口径基线上方外不命中"
        )
        // 没给任何排版信息时用启发式度量命中（UI 尚未排版完成的瞬间）
        try expectTrue(
            AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 70, y: 60), for: text),
            "无实测尺寸时按估宽命中"
        )
    }

    // MARK: - 场景 6：顶层优先

    static func test6TopmostPriority() throws {
        print("[TestAnnotationEditing] 场景6: 重叠标注顶层优先")

        let bottom = make(.mosaic(CGRect(x: 0, y: 0, width: 200, height: 200)), strokeWidth: 2)
        let top = make(.mosaic(CGRect(x: 50, y: 50, width: 100, height: 100)), strokeWidth: 2)
        let stack = [bottom, top]
        try expectEqual(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 100, y: 100), in: stack), 1, "重叠区命中上层")
        try expectEqual(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 10, y: 10), in: stack), 0, "只有下层覆盖处命中下层")
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 500, y: 500), in: stack) == nil, "都不覆盖时无命中")

        // 三层叠加：最上层（下标最大）优先，即便下层是更"实"的马赛克
        let rect = make(.rect(CGRect(x: 90, y: 90, width: 120, height: 120)), strokeWidth: 2)
        let threeLayers = [bottom, top, rect]
        try expectEqual(
            AnnotationEditorGeometry.hitTestBody(at: CGPoint(x: 90, y: 90), in: threeLayers),
            2,
            "矩形描边压在马赛克之上时命中矩形"
        )
    }

    // MARK: - 场景 7：操控柄布局

    static func test7HandleLayout() throws {
        print("[TestAnnotationEditing] 场景7: 各形状操控柄布局")

        let arrowHandles = AnnotationEditorGeometry.handles(
            for: make(.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 70)))
        )
        try expectEqual(arrowHandles.count, 2, "箭头两个手柄")
        try expectEqual(arrowHandles[0].handle, .start, "箭头手柄0 是起点")
        try expectEqual(arrowHandles[0].point, CGPoint(x: 10, y: 20), "箭头起点坐标")
        try expectEqual(arrowHandles[1].handle, .end, "箭头手柄1 是终点")
        try expectEqual(arrowHandles[1].point, CGPoint(x: 110, y: 70), "箭头终点坐标")

        let highlightHandles = AnnotationEditorGeometry.handles(
            for: make(.highlight(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4)))
        )
        try expectEqual(highlightHandles.map(\.handle), [.start, .end], "高亮两端手柄")
        try expectEqual(highlightHandles.map(\.point), [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], "高亮端点坐标")

        // 负尺寸矩形：手柄落在归一后的四角
        let rectHandles = AnnotationEditorGeometry.handles(
            for: make(.rect(CGRect(x: 100, y: 100, width: -100, height: -100)))
        )
        try expectEqual(rectHandles.map(\.handle), [.topLeft, .topRight, .bottomLeft, .bottomRight], "矩形四角手柄顺序")
        try expectEqual(
            rectHandles.map(\.point),
            [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 100, y: 0),
                CGPoint(x: 0, y: 100),
                CGPoint(x: 100, y: 100)
            ],
            "负尺寸矩形归一后四角坐标"
        )

        let mosaicHandles = AnnotationEditorGeometry.handles(
            for: make(.mosaic(CGRect(x: 10, y: 20, width: 30, height: 40)))
        )
        try expectEqual(mosaicHandles.map(\.handle), [.topLeft, .topRight, .bottomLeft, .bottomRight], "马赛克四角手柄")
        try expectEqual(
            mosaicHandles.map(\.point),
            [
                CGPoint(x: 10, y: 20),
                CGPoint(x: 40, y: 20),
                CGPoint(x: 10, y: 60),
                CGPoint(x: 40, y: 60)
            ],
            "马赛克四角坐标"
        )

        let ellipseHandles = AnnotationEditorGeometry.handles(
            for: make(.ellipse(center: CGPoint(x: 50, y: 50), radiusX: 20, radiusY: 10))
        )
        try expectEqual(ellipseHandles.map(\.handle), [.topLeft, .topRight, .bottomLeft, .bottomRight], "椭圆四角手柄")
        try expectEqual(
            ellipseHandles.map(\.point),
            [
                CGPoint(x: 30, y: 40),
                CGPoint(x: 70, y: 40),
                CGPoint(x: 30, y: 60),
                CGPoint(x: 70, y: 60)
            ],
            "椭圆手柄在外接矩形四角"
        )

        try expectTrue(AnnotationEditorGeometry.handles(for: make(.sequence(anchor: CGPoint(x: 5, y: 5)))).isEmpty, "序号无手柄")
        try expectTrue(
            AnnotationEditorGeometry.handles(for: make(.text(anchor: CGPoint(x: 5, y: 5)), text: "x")).isEmpty,
            "文字无手柄"
        )
    }

    // MARK: - 场景 8：操控柄命中与优先级

    static func test8HitTestHandlePriority() throws {
        print("[TestAnnotationEditing] 场景8: 操控柄命中与优先级")

        let rect = make(.rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        try expectEqual(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 3, y: 3), for: rect), .topLeft, "左上角手柄命中")
        try expectEqual(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 98, y: 2), for: rect), .topRight, "右上角手柄命中")
        try expectEqual(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 2, y: 98), for: rect), .bottomLeft, "左下角手柄命中")
        try expectEqual(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 99, y: 99), for: rect), .bottomRight, "右下角手柄命中")
        try expectTrue(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 50, y: 50), for: rect) == nil, "矩形内部无手柄")
        // 容差可配：默认 9pt，收紧到 1pt 就点不中 3pt 外的角
        try expectTrue(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 3, y: 3), for: rect, tolerance: 1) == nil, "容差 1pt 不命中")

        let arrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)))
        try expectEqual(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 0, y: 4), for: arrow), .start, "箭头顶端手柄命中")
        try expectEqual(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 104, y: 0), for: arrow), .end, "箭头尾端手柄命中")
        try expectTrue(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 50, y: 0), for: arrow) == nil, "箭头中段无手柄")

        // 端点与角重叠时按 handles 顺序取第一个（箭头 start 优先于 end）
        let shortArrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 2, y: 0)))
        try expectEqual(AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 1, y: 0), for: shortArrow), .start, "短箭头重叠区取起点")

        // 手柄优先于本体：矩形角点同时满足描边命中，UI 应先判手柄
        let atCorner = CGPoint(x: 0, y: 0)
        try expectTrue(AnnotationEditorGeometry.hitTestBody(at: atCorner, for: rect), "角点本身也是描边命中")
        try expectEqual(AnnotationEditorGeometry.hitTestHandle(at: atCorner, for: rect), .topLeft, "角点优先判为手柄")

        try expectTrue(
            AnnotationEditorGeometry.hitTestHandle(at: CGPoint(x: 5, y: 5), for: make(.sequence(anchor: CGPoint(x: 5, y: 5)))) == nil,
            "序号永不出手柄"
        )
    }

    // MARK: - 场景 9：`.body` 平移

    static func test9BodyTranslation() throws {
        print("[TestAnnotationEditing] 场景9: .body 平移（7 种形状）")

        let delta = CGSize(width: 7, height: -13)
        let shapes: [AnnotationModel.Shape] = [
            .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 70)),
            .highlight(from: CGPoint(x: 110, y: 70), to: CGPoint(x: 10, y: 20)),
            .rect(CGRect(x: 100, y: 100, width: 200, height: 150)),
            .mosaic(CGRect(x: 100, y: 100, width: 200, height: 150)),
            .ellipse(center: CGPoint(x: 200, y: 200), radiusX: 100, radiusY: 60),
            .sequence(anchor: CGPoint(x: 300, y: 300)),
            .text(anchor: CGPoint(x: 50, y: 60))
        ]
        for shape in shapes {
            let annotation = make(shape, strokeWidth: 3)
            let moved = AnnotationEditorGeometry.transformed(annotation, handle: .body, delta: delta)
            try expectEqual(moved, annotation.offsetBy(dx: 7, dy: -13), "\(shape) .body 平移等于 offsetBy")
            try expectEqual(moved.strokeWidth, annotation.strokeWidth, "\(shape) 平移不改线宽")
            try expectEqual(moved.colorIndex, annotation.colorIndex, "\(shape) 平移不改颜色")
        }
        // 零位移幂等
        let rect = make(.rect(CGRect(x: 1, y: 2, width: 3, height: 4)))
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .body, delta: CGSize(width: 0, height: 0)),
            rect,
            "零位移幂等"
        )
    }

    // MARK: - 场景 10：箭头 / 高亮端点变换

    static func test10ArrowEndpointTransform() throws {
        print("[TestAnnotationEditing] 场景10: 箭头与高亮端点拖拽")

        let arrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)), strokeWidth: 2)
        try expectEqual(
            AnnotationEditorGeometry.transformed(arrow, handle: .start, delta: CGSize(width: 5, height: 5)).shape,
            .arrow(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 100, y: 0)),
            "拖起点只动 from"
        )
        try expectEqual(
            AnnotationEditorGeometry.transformed(arrow, handle: .end, delta: CGSize(width: -30, height: 40)).shape,
            .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 70, y: 40)),
            "拖终点只动 to"
        )

        let highlight = make(.highlight(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 90)), strokeWidth: 8)
        let movedHighlight = AnnotationEditorGeometry.transformed(
            highlight,
            handle: .end,
            delta: CGSize(width: 10, height: -20)
        )
        try expectEqual(movedHighlight.shape, .highlight(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 70)), "高亮拖终点")
        try expectEqual(movedHighlight.strokeWidth, 8, "高亮拖端点不改线宽")

        // 单步幂等：同一 delta 应用在「原始标注」上，而不是累积在已变形结果上
        let twice = AnnotationEditorGeometry.transformed(
            AnnotationEditorGeometry.transformed(arrow, handle: .end, delta: CGSize(width: 10, height: 0)),
            handle: .end,
            delta: CGSize(width: 10, height: 0)
        )
        try expectEqual(twice.shape, .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 120, y: 0)), "两次 10pt = 一次 20pt")
    }

    // MARK: - 场景 11：矩形 / 马赛克四角缩放

    static func test11RectCornerResize() throws {
        print("[TestAnnotationEditing] 场景11: 矩形与马赛克四角缩放")

        let rect = make(.rect(CGRect(x: 100, y: 100, width: 100, height: 100)), strokeWidth: 3, colorIndex: 2)
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .topLeft, delta: CGSize(width: -20, height: -30)).shape,
            .rect(CGRect(x: 80, y: 70, width: 120, height: 130)),
            "拖左上角：右下角锚定"
        )
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .topRight, delta: CGSize(width: 40, height: -10)).shape,
            .rect(CGRect(x: 100, y: 90, width: 140, height: 110)),
            "拖右上角：左下角锚定"
        )
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .bottomLeft, delta: CGSize(width: -40, height: 20)).shape,
            .rect(CGRect(x: 60, y: 100, width: 140, height: 120)),
            "拖左下角：右上角锚定"
        )
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .bottomRight, delta: CGSize(width: 20, height: 30)).shape,
            .rect(CGRect(x: 100, y: 100, width: 120, height: 130)),
            "拖右下角：左上角锚定"
        )
        // 样式与颜色随拖拽保留
        let resized = AnnotationEditorGeometry.transformed(rect, handle: .bottomRight, delta: CGSize(width: 5, height: 5))
        try expectEqual(resized.strokeWidth, 3, "缩放不改线宽")
        try expectEqual(resized.colorIndex, 2, "缩放不改颜色")

        // 跨对角翻转：仍产出合法（归一化）矩形，而不是负宽高
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .topLeft, delta: CGSize(width: 150, height: 150)).shape,
            .rect(CGRect(x: 200, y: 200, width: 50, height: 50)),
            "拖过对角自动翻转"
        )

        // minSize 保底：拖到几乎重合时按拖动方向钳到 8pt
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .topLeft, delta: CGSize(width: 95, height: 95)).shape,
            .rect(CGRect(x: 192, y: 192, width: 8, height: 8)),
            "minSize 保底 8pt"
        )
        // 自定义 minSize
        try expectEqual(
            AnnotationEditorGeometry.transformed(
                rect, handle: .bottomRight, delta: CGSize(width: -98, height: -98), minSize: 20
            ).shape,
            .rect(CGRect(x: 100, y: 100, width: 20, height: 20)),
            "自定义 minSize 20pt"
        )

        // 负尺寸矩形：先归一，再按同一口径缩放
        let reversed = make(.rect(CGRect(x: 300, y: 300, width: -100, height: -100)), strokeWidth: 2)
        try expectEqual(
            AnnotationEditorGeometry.transformed(reversed, handle: .topLeft, delta: CGSize(width: -10, height: -10)).shape,
            .rect(CGRect(x: 190, y: 190, width: 110, height: 110)),
            "负尺寸矩形归一后缩放"
        )

        // 马赛克同口径
        let mosaic = make(.mosaic(CGRect(x: 100, y: 100, width: 100, height: 100)), strokeWidth: 2)
        try expectEqual(
            AnnotationEditorGeometry.transformed(mosaic, handle: .bottomRight, delta: CGSize(width: 50, height: -60)).shape,
            .mosaic(CGRect(x: 100, y: 100, width: 150, height: 40)),
            "马赛克右下角缩放"
        )
        try expectEqual(
            AnnotationEditorGeometry.transformed(mosaic, handle: .topRight, delta: CGSize(width: -95, height: 0)).shape,
            .mosaic(CGRect(x: 100, y: 100, width: 8, height: 100)),
            "马赛克 minSize 保底（右边缘内拖到塌陷，按左侧锚定钳到 8pt）"
        )
    }

    // MARK: - 场景 12：椭圆四角缩放与回算

    static func test12EllipseCornerResize() throws {
        print("[TestAnnotationEditing] 场景12: 椭圆四角缩放回算 center/radius")

        let ellipse = make(.ellipse(center: CGPoint(x: 100, y: 100), radiusX: 50, radiusY: 30), strokeWidth: 4)
        // 外接矩形 (50,70,100,60)
        let expanded = AnnotationEditorGeometry.transformed(ellipse, handle: .bottomRight, delta: CGSize(width: 10, height: 20))
        guard case .ellipse(let center, let rx, let ry) = expanded.shape else {
            throw Failure.message("椭圆拖角后应仍是 ellipse，实际 \(expanded.shape)")
        }
        try expectPoint(center, CGPoint(x: 105, y: 110), "椭圆右下角外扩后中心")
        try expectApprox(rx, 55, "椭圆右下角外扩后 radiusX")
        try expectApprox(ry, 40, "椭圆右下角外扩后 radiusY")
        try expectEqual(expanded.strokeWidth, 4, "椭圆缩放不改线宽")

        let shrunk = AnnotationEditorGeometry.transformed(ellipse, handle: .topLeft, delta: CGSize(width: -10, height: -10))
        guard case .ellipse(let center2, let rx2, let ry2) = shrunk.shape else {
            throw Failure.message("椭圆拖左上角后应仍是 ellipse")
        }
        try expectPoint(center2, CGPoint(x: 95, y: 95), "椭圆左上角外扩后中心")
        try expectApprox(rx2, 55, "椭圆左上角外扩后 radiusX")
        try expectApprox(ry2, 35, "椭圆左上角外扩后 radiusY")

        // 半径保底：拖到塌陷时 rx/ry 不小于 minSize / 2
        let collapsed = AnnotationEditorGeometry.transformed(ellipse, handle: .bottomRight, delta: CGSize(width: -99, height: -59))
        guard case .ellipse(let center3, let rx3, let ry3) = collapsed.shape else {
            throw Failure.message("椭圆拖塌后应仍是 ellipse")
        }
        try expectApprox(rx3, 4, "椭圆 radiusX 保底 minSize/2")
        try expectApprox(ry3, 4, "椭圆 radiusY 保底 minSize/2")
        try expectPoint(center3, CGPoint(x: 54, y: 74), "椭圆塌陷后中心")

        // 跨对角翻转后仍是合法椭圆（半径为正，外接矩形 20x20）
        let flipped = AnnotationEditorGeometry.transformed(ellipse, handle: .topLeft, delta: CGSize(width: 120, height: 80))
        guard case .ellipse(let center4, let rx4, let ry4) = flipped.shape else {
            throw Failure.message("椭圆翻转后应仍是 ellipse")
        }
        try expectPoint(center4, CGPoint(x: 160, y: 140), "椭圆翻转后中心")
        try expectApprox(rx4, 10, "椭圆翻转后 radiusX")
        try expectApprox(ry4, 10, "椭圆翻转后 radiusY")
        try expectTrue(rx4 > 0 && ry4 > 0, "椭圆翻转后半径为正（\(rx4), \(ry4)）")
    }

    // MARK: - 场景 13：形状与手柄不匹配

    static func test13HandleShapeMismatch() throws {
        print("[TestAnnotationEditing] 场景13: 手柄与形状不匹配时原样返回")

        let arrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)))
        try expectEqual(
            AnnotationEditorGeometry.transformed(arrow, handle: .topLeft, delta: CGSize(width: 10, height: 10)),
            arrow,
            "箭头不吃角手柄"
        )
        let rect = make(.rect(CGRect(x: 0, y: 0, width: 50, height: 50)))
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .start, delta: CGSize(width: 10, height: 10)),
            rect,
            "矩形不吃端点手柄"
        )
        try expectEqual(
            AnnotationEditorGeometry.transformed(rect, handle: .end, delta: CGSize(width: 10, height: 10)),
            rect,
            "矩形不吃终点手柄"
        )
        let ellipse = make(.ellipse(center: CGPoint(x: 10, y: 10), radiusX: 10, radiusY: 10))
        try expectEqual(
            AnnotationEditorGeometry.transformed(ellipse, handle: .start, delta: CGSize(width: 10, height: 10)),
            ellipse,
            "椭圆不吃端点手柄"
        )
        let sequence = make(.sequence(anchor: CGPoint(x: 20, y: 20)))
        try expectEqual(
            AnnotationEditorGeometry.transformed(sequence, handle: .topLeft, delta: CGSize(width: 10, height: 10)),
            sequence,
            "序号不吃角手柄"
        )
        let text = make(.text(anchor: CGPoint(x: 20, y: 20)), text: "abc")
        try expectEqual(
            AnnotationEditorGeometry.transformed(text, handle: .bottomRight, delta: CGSize(width: 10, height: 10)),
            text,
            "文字不吃角手柄"
        )
    }

    // MARK: - 场景 14：拖拽预览 + 单步撤销

    @MainActor
    static func test14PreviewAndSingleStepUndo() throws {
        print("[TestAnnotationEditing] 场景14: previewReplace + commitMutation 单步撤销")

        let store = AnnotationStore()
        let original = make(.rect(CGRect(x: 10, y: 10, width: 100, height: 100)), strokeWidth: 2)
        store.add(original)
        try expectEqual(store.annotations, [original], "add 后一条标注")
        try expectTrue(store.canUndo, "add 后可撤销")

        let snapshot = store.annotations
        // 30 帧拖拽预览：只改值不压栈
        for step in 1...30 {
            store.previewReplace(
                at: 0,
                with: AnnotationEditorGeometry.transformed(
                    original, handle: .body, delta: CGSize(width: CGFloat(step), height: CGFloat(step))
                )
            )
        }
        try expectEqual(
            store.annotations[0].shape,
            .rect(CGRect(x: 40, y: 40, width: 100, height: 100)),
            "预览逐帧生效"
        )

        store.commitMutation(previousAnnotations: snapshot)
        // 一次 ⌘Z 就回到拖拽前（整段拖拽只算一步）
        store.undo()
        try expectEqual(store.annotations, snapshot, "一次撤销回到拖拽前快照")
        try expectTrue(store.canRedo, "撤销后可重做")
        store.redo()
        try expectEqual(
            store.annotations[0].shape,
            .rect(CGRect(x: 40, y: 40, width: 100, height: 100)),
            "重做回到拖拽结果"
        )

        // 再撤销一次才是 add 之前的空状态（证明预览帧没有额外压栈）
        store.undo()
        try expectEqual(store.annotations, snapshot, "第二次撤销仍是拖拽前")
        store.undo()
        try expectTrue(store.annotations.isEmpty, "第三次撤销清空（只有 add 与拖拽两步）")

        // commitMutation 清 redo 栈
        let store2 = AnnotationStore()
        store2.add(original)
        let snap2 = store2.annotations
        store2.previewReplace(at: 0, with: original.offsetBy(dx: 5, dy: 5))
        store2.commitMutation(previousAnnotations: snap2)
        store2.undo()
        try expectTrue(store2.canRedo, "撤销后有 redo")
        let snap3 = store2.annotations
        store2.previewReplace(at: 0, with: original.offsetBy(dx: -5, dy: -5))
        store2.commitMutation(previousAnnotations: snap3)
        try expectTrue(!store2.canRedo, "新的提交清空 redo 栈")

        // 越界预览不崩、不新增
        store2.previewReplace(at: 99, with: original)
        try expectEqual(store2.annotations.count, 1, "越界预览不改变数量")
    }

    // MARK: - 场景 15：无变化不污染撤销栈

    @MainActor
    static func test15NoChangeKeepsUndoStackClean() throws {
        print("[TestAnnotationEditing] 场景15: 无变化不压撤销栈")

        let store = AnnotationStore()
        let rect = make(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)), strokeWidth: 2)
        store.add(rect)
        let snapshot = store.annotations

        // 空拖拽（点一下没动）
        store.commitMutation(previousAnnotations: snapshot)
        // 单步替换成完全相同的值
        store.replace(at: 0, with: rect)
        // 样式改成同值
        try expectTrue(!store.updateStyle(at: 0, colorIndex: 0), "同色返回 false")
        try expectTrue(!store.updateStyle(at: 0, strokeWidth: 2), "同线宽返回 false")
        try expectTrue(!store.updateStyle(at: 0, fontSize: 14), "同字号返回 false")
        try expectTrue(!store.updateStyle(at: 0, colorIndex: 995), "调色板取模同色（995 % 5 == 0 红）返回 false")

        // 只有 add 压过一次栈：一次撤销就清空
        store.undo()
        try expectTrue(store.annotations.isEmpty, "无变化操作没有额外压栈（一次撤销即清空）")

        // 越界替换 / 越界改样式：不崩、返回 false、不压栈
        let store2 = AnnotationStore()
        store2.add(rect)
        store2.replace(at: 9, with: rect.offsetBy(dx: 100, dy: 100))
        try expectTrue(!store2.updateStyle(at: 9, colorIndex: 1), "越界改样式返回 false")
        try expectEqual(store2.annotations, [rect], "越界操作不改内容")
        store2.undo()
        try expectTrue(store2.annotations.isEmpty, "越界操作没压栈")
    }

    // MARK: - 场景 16：删除与改样式

    @MainActor
    static func test16RemoveAndUpdateStyle() throws {
        print("[TestAnnotationEditing] 场景16: remove(at:) 与 updateStyle(at:)")

        let store = AnnotationStore()
        let rect = make(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)), strokeWidth: 2, colorIndex: 0)
        let arrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)), strokeWidth: 2, colorIndex: 0)
        store.add(rect)
        store.add(arrow)
        try expectEqual(store.annotations.count, 2, "两条标注")

        try expectTrue(!store.remove(at: 5), "越界删除返回 false")
        try expectTrue(!store.remove(at: -1), "负下标返回 false")
        try expectEqual(store.annotations.count, 2, "越界删除不改内容")
        try expectTrue(store.remove(at: 0), "删除第 0 条成功")
        try expectEqual(store.annotations, [arrow], "剩下箭头")
        store.undo()
        try expectEqual(store.annotations, [rect, arrow], "⌘Z 恢复删除")
        store.redo()
        try expectEqual(store.annotations, [arrow], "⌘⇧Z 重做删除")

        // 改颜色：有变化 → true，且可撤销回原色
        try expectTrue(store.updateStyle(at: 0, colorIndex: 2), "改颜色返回 true")
        try expectEqual(store.annotations[0].colorIndex, 2, "颜色已改为 2")
        try expectTrue(!store.updateStyle(at: 0, colorIndex: 2), "同色再改返回 false")
        store.undo()
        try expectEqual(store.annotations[0].colorIndex, 0, "撤销回到原色")

        // 改线宽 + 字号（一次调用压一次栈）
        try expectTrue(store.updateStyle(at: 0, strokeWidth: 5, fontSize: 17), "改线宽字号返回 true")
        try expectEqual(store.annotations[0].strokeWidth, 5, "线宽已改")
        try expectEqual(store.annotations[0].fontSize, 17, "字号已改")
        try expectTrue(!store.updateStyle(at: 0, strokeWidth: 5.004), "0.01pt 内浮点噪声不算变化")
        store.undo()
        try expectEqual(store.annotations[0].strokeWidth, 2, "撤销回到原线宽")
        try expectEqual(store.annotations[0].fontSize, 14, "撤销回到原字号")

        // 只改字号也要生效（文字标注改字号走同一条通道）
        try expectTrue(store.updateStyle(at: 0, fontSize: 21), "只改字号返回 true")
        try expectEqual(store.annotations[0].fontSize, 21, "字号已改 21")
        try expectEqual(store.annotations[0].strokeWidth, 2, "未传的参数保持原值")

        // 预览 + 提交 + 改样式混用：撤销顺序严格后进先出
        let snapshot = store.annotations
        store.previewReplace(at: 0, with: store.annotations[0].offsetBy(dx: 20, dy: 20))
        store.commitMutation(previousAnnotations: snapshot)
        try expectEqual(store.annotations[0].shape, .arrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 30, y: 30)), "拖拽结果")
        store.undo()
        try expectEqual(store.annotations[0].shape, .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)), "撤销拖拽后几何回退")
        try expectEqual(store.annotations[0].fontSize, 21, "撤销拖拽不影响此前的字号修改")
    }

    // MARK: - 工具

    enum Failure: Error {
        case message(String)
    }

    static func make(
        _ shape: AnnotationModel.Shape,
        strokeWidth: CGFloat = 2,
        text: String? = nil,
        index: Int? = nil,
        fontSize: CGFloat = 14,
        colorIndex: Int = 0
    ) -> AnnotationModel {
        AnnotationModel(
            shape: shape,
            colorIndex: colorIndex,
            strokeWidth: strokeWidth,
            text: text,
            index: index,
            fontSize: fontSize
        )
    }

    static func expectTrue(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.message("\(label)：期望 true，实际 false") }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else { throw Failure.message("\(label)：期望 \(expected)，实际 \(actual)") }
    }

    static func expectApprox(_ actual: CGFloat, _ expected: CGFloat, _ label: String, accuracy: CGFloat = 0.001) throws {
        guard abs(actual - expected) <= accuracy else {
            throw Failure.message("\(label)：期望 \(expected)（±\(accuracy)），实际 \(actual)")
        }
    }

    static func expectPoint(_ actual: CGPoint, _ expected: CGPoint, _ label: String, accuracy: CGFloat = 0.001) throws {
        guard abs(actual.x - expected.x) <= accuracy, abs(actual.y - expected.y) <= accuracy else {
            throw Failure.message("\(label)：期望 \(expected)，实际 \(actual)")
        }
    }

    static func expectRect(_ actual: CGRect, _ expected: CGRect, _ label: String, accuracy: CGFloat = 0.001) throws {
        guard abs(actual.minX - expected.minX) <= accuracy,
              abs(actual.minY - expected.minY) <= accuracy,
              abs(actual.width - expected.width) <= accuracy,
              abs(actual.height - expected.height) <= accuracy else {
            throw Failure.message("\(label)：期望 \(expected)，实际 \(actual)")
        }
    }
}
