import AppKit
import CoreGraphics

/// 工具栏图标渲染器（设计稿 1:1：snapcut-design-redesign/index.html 的 15 个
/// 自绘 SVG 线性图标——SF Symbol 字形比例与设计稿不符，用户实报「竖着拉长/
/// 没跟设计稿对齐」）。
///
/// 视觉规格（2026-11-17 工具栏图标重设计落地）：viewBox 16、stroke 1.8pt、圆头/圆角连接、
/// 线色 currentColor（本层 = 调用方 tint）。真源：html-pages/snapcut-toolbar-icons/index.html
/// 页尾 path 坐标清单（15 个 icon 按清单逐一替换；马赛克单独深设计中，保持现状跳过）。
/// 实现：NSBitmapImageRep 2x 栅格化，
/// isTemplate = true → NSButton image + contentTintColor 上色（选中/强调态自动
/// 白字）。非模板色元素（马赛克块的 opacity 阶）在模板下不可表达——马赛克块
/// 改用描边 + 半数填充块表达网格语义（模板安全）。
enum TBIcon {
    /// 图标全集（tag 顺序 = 设计稿工具栏序）
    enum Kind {
        case arrow, rect, text, mosaic, sequence, highlight, ellipse
        case undo, redo, ocr, pin, eye
        case save, cancel, copy, scroll
    }

    static func image(_ kind: Kind, pointSize: CGFloat = 20) -> NSImage {
        let scale: Int = 2
        let px = Int(pointSize) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: pointSize, height: pointSize)) }
        rep.size = NSSize(width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        // viewBox 16 → pointSize 缩放（stroke 1.8 同步缩放）
        let unit = pointSize / 16
        ctx.scaleBy(x: unit, y: unit)
        // 翻转到 Y-down（SVG 坐标系）
        ctx.translateBy(x: 0, y: 16)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setStrokeColor(NSColor.black.cgColor)   // 模板：黑 = tint 通道
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        draw(kind, in: ctx)
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage()
        img.addRepresentation(rep)
        img.isTemplate = true
        img.size = NSSize(width: pointSize, height: pointSize)
        return img
    }

    /// SVG viewBox(0..16) 坐标的描边路径绘制（与设计稿 path 一一对应）
    private static func draw(_ kind: Kind, in ctx: CGContext) {
        func stroke(_ path: CGPath, alpha: CGFloat = 1) {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
        func strokeLine(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, alpha: CGFloat = 1) {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x2, y: y2))
            stroke(p, alpha: alpha)
        }
        func fillRoundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat) {
            let p = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.addPath(p)
            ctx.fillPath()
        }

        func strokeRoundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat, alpha: CGFloat = 1) {
            let p = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
            stroke(p, alpha: alpha)
        }
        func strokeEllipseAt(_ cx: CGFloat, _ cy: CGFloat, rx: CGFloat, ry: CGFloat) {
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            stroke(p)
        }

        func strokeCircle(_ cx: CGFloat, _ cy: CGFloat, r: CGFloat) {
            let p = CGMutablePath()
            p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            stroke(p)
        }

        switch kind {
        case .arrow:
            // 箭头 1：斜线 + 端箭头（重设计 2笔）
            strokeLine(3.2, 12.8, 12.6, 3.4)
            let arrowHead = CGMutablePath()
            arrowHead.move(to: CGPoint(x: 12.8, y: 8.6))
            arrowHead.addLine(to: CGPoint(x: 12.8, y: 3.2))
            arrowHead.addLine(to: CGPoint(x: 7.4, y: 3.2))
            stroke(arrowHead)
        case .rect:
            // 矩形 2：圆角矩形（重设计：外扩至视窗 ~70%、rx 1.8）
            strokeRoundedRect(2.4, 4, 11.2, 8, r: 1.8)
        case .text:
            // 文字 3：T 带衬线（重设计 3笔：衬线折笔合并）
            let serif = CGMutablePath()
            serif.move(to: CGPoint(x: 4.6, y: 4.8)); serif.addLine(to: CGPoint(x: 3.2, y: 3.4))
            serif.addLine(to: CGPoint(x: 12.8, y: 3.4)); serif.addLine(to: CGPoint(x: 11.4, y: 4.8))
            stroke(serif)
            strokeLine(8, 3.4, 8, 12.6)
            strokeLine(5.8, 12.6, 10.2, 12.6)
        case .mosaic:
            // 马赛克（用户三稿裁定 A「散块拼贴」2026-11-16：语义=「模糊、没有
            // 规律」——4 块大小/长宽/位置全不同（横长/竖长/近方/小方），1 实心
            // 3 描边，零对齐零等分；网格/表格/点阵方案全被否）
            // 块1 横长（描边）
            strokeRoundedRect(2.6, 3.0, 5.2, 3.0, r: 0.9)
            // 块2 竖长（描边）
            strokeRoundedRect(9.0, 2.6, 3.0, 5.4, r: 0.9)
            // 块3 近方（实心——墨量锚点）
            fillRoundedRect(3.0, 8.0, 4.0, 4.0, r: 0.9)
            // 块4 小方（描边，错位右下）
            strokeRoundedRect(8.6, 9.4, 3.4, 3.0, r: 0.8)
        case .sequence:
            // 序号 5：圆 + 数字「2」（重设计：曲线整体重绘放大、下移居中）
            strokeCircle(8, 8, r: 5.6)
            let two = CGMutablePath()
            two.move(to: CGPoint(x: 6.0, y: 6.3))
            two.addCurve(to: CGPoint(x: 8.6, y: 5.8), control1: CGPoint(x: 6.5, y: 5.2), control2: CGPoint(x: 7.9, y: 5.1))
            two.addCurve(to: CGPoint(x: 8.0, y: 8.2), control1: CGPoint(x: 9.2, y: 6.5), control2: CGPoint(x: 8.9, y: 7.4))
            two.addCurve(to: CGPoint(x: 6.0, y: 10.1), control1: CGPoint(x: 7.2, y: 8.9), control2: CGPoint(x: 6.4, y: 9.4))
            two.addLine(to: CGPoint(x: 10.2, y: 10.1))
            stroke(two)
        case .highlight:
            // 高亮 6：荧光笔斜置 + 底线（重设计：笔身放大、底线加宽 alpha 0.5）
            let pen = CGMutablePath()
            pen.move(to: CGPoint(x: 9.6, y: 3))
            pen.addLine(to: CGPoint(x: 13, y: 6.4))
            pen.addLine(to: CGPoint(x: 7.2, y: 12.2))
            pen.addLine(to: CGPoint(x: 4.0, y: 12.2))
            pen.addLine(to: CGPoint(x: 4.0, y: 9))
            pen.closeSubpath()
            stroke(pen)
            strokeLine(3.2, 14.2, 12.8, 14.2, alpha: 0.5)
        case .undo:
            // 撤销 ⌘Z（重设计：弧度加大、钩尾内收）
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 5.8, y: 3)); p.addLine(to: CGPoint(x: 2.9, y: 5.9)); p.addLine(to: CGPoint(x: 5.8, y: 8.8))
            stroke(p)
            let p2 = CGMutablePath()
            p2.move(to: CGPoint(x: 2.9, y: 5.9))
            p2.addLine(to: CGPoint(x: 9.2, y: 5.9))
            p2.addCurve(to: CGPoint(x: 13.1, y: 9.5), control1: CGPoint(x: 12.0, y: 5.9), control2: CGPoint(x: 13.1, y: 7.5))
            p2.addCurve(to: CGPoint(x: 9.2, y: 13), control1: CGPoint(x: 13.1, y: 11.5), control2: CGPoint(x: 12.0, y: 13))
            p2.addLine(to: CGPoint(x: 7.6, y: 13))
            stroke(p2)
        case .redo:
            // 重做 ⇧⌘Z（undo 的严格镜像 x → 16 − x）
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 10.2, y: 3)); p.addLine(to: CGPoint(x: 13.1, y: 5.9)); p.addLine(to: CGPoint(x: 10.2, y: 8.8))
            stroke(p)
            let p2 = CGMutablePath()
            p2.move(to: CGPoint(x: 13.1, y: 5.9))
            p2.addLine(to: CGPoint(x: 6.8, y: 5.9))
            p2.addCurve(to: CGPoint(x: 2.9, y: 9.5), control1: CGPoint(x: 4.0, y: 5.9), control2: CGPoint(x: 2.9, y: 7.5))
            p2.addCurve(to: CGPoint(x: 6.8, y: 13), control1: CGPoint(x: 2.9, y: 11.5), control2: CGPoint(x: 4.0, y: 13))
            p2.addLine(to: CGPoint(x: 8.4, y: 13))
            stroke(p2)
        case .ocr:
            // 取字 O：四角框 + 「文」（重设计 2笔：四角合并、「文」合并）
            let corners = CGMutablePath()
            corners.move(to: CGPoint(x: 3.0, y: 5.4)); corners.addLine(to: CGPoint(x: 3.0, y: 3.0)); corners.addLine(to: CGPoint(x: 5.4, y: 3.0))
            corners.move(to: CGPoint(x: 10.6, y: 3.0)); corners.addLine(to: CGPoint(x: 13.0, y: 3.0)); corners.addLine(to: CGPoint(x: 13.0, y: 5.4))
            corners.move(to: CGPoint(x: 13.0, y: 10.6)); corners.addLine(to: CGPoint(x: 13.0, y: 13.0)); corners.addLine(to: CGPoint(x: 10.6, y: 13.0))
            corners.move(to: CGPoint(x: 5.4, y: 13.0)); corners.addLine(to: CGPoint(x: 3.0, y: 13.0)); corners.addLine(to: CGPoint(x: 3.0, y: 10.6))
            stroke(corners)
            let wen = CGMutablePath()
            wen.move(to: CGPoint(x: 6.6, y: 7.0)); wen.addLine(to: CGPoint(x: 5.6, y: 6.2)); wen.addLine(to: CGPoint(x: 10.4, y: 6.2)); wen.addLine(to: CGPoint(x: 9.4, y: 7.0))
            wen.move(to: CGPoint(x: 8, y: 6.2)); wen.addLine(to: CGPoint(x: 8, y: 10.8))
            wen.move(to: CGPoint(x: 6.5, y: 10.8)); wen.addLine(to: CGPoint(x: 9.5, y: 10.8))
            stroke(wen)
        case .pin:
            // 贴图 P：图钉（重设计：针杆加长出头，钉头/底座放大）
            strokeLine(8, 2.8, 8, 6.0)
            let head = CGMutablePath()
            head.move(to: CGPoint(x: 5.8, y: 6.0)); head.addLine(to: CGPoint(x: 10.2, y: 6.0))
            head.addLine(to: CGPoint(x: 11.2, y: 9.2)); head.addLine(to: CGPoint(x: 4.8, y: 9.2))
            head.closeSubpath()
            stroke(head)
            let leg = CGMutablePath()
            leg.move(to: CGPoint(x: 6.8, y: 9.2)); leg.addLine(to: CGPoint(x: 6.4, y: 13.2))
            leg.addLine(to: CGPoint(x: 9.6, y: 13.2)); leg.addLine(to: CGPoint(x: 9.2, y: 9.2))
            stroke(leg)
        case .eye:
            // 眼睛 H（重设计：轮廓放大至 70% 视窗、瞳孔随比例放大；与椭圆纯轮廓区分：眼形更扁 + 有瞳）
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 2.4, y: 8))
            p.addCurve(to: CGPoint(x: 8, y: 3.9), control1: CGPoint(x: 4.0, y: 5.0), control2: CGPoint(x: 5.9, y: 3.9))
            p.addCurve(to: CGPoint(x: 13.6, y: 8), control1: CGPoint(x: 10.1, y: 3.9), control2: CGPoint(x: 12.0, y: 5.0))
            p.addCurve(to: CGPoint(x: 8, y: 12.1), control1: CGPoint(x: 12.0, y: 11.0), control2: CGPoint(x: 10.1, y: 12.1))
            p.addCurve(to: CGPoint(x: 2.4, y: 8), control1: CGPoint(x: 5.9, y: 12.1), control2: CGPoint(x: 4.0, y: 11.0))
            p.closeSubpath()
            stroke(p)
            strokeCircle(8, 8, r: 2.0)
        case .save:
            // 保存 ⌘S：下箭头 + 托盘（重设计 2笔：箭头杆加长、托盘圆角收紧）
            let shaft = CGMutablePath()
            shaft.move(to: CGPoint(x: 8, y: 2.8)); shaft.addLine(to: CGPoint(x: 8, y: 10.2))
            shaft.move(to: CGPoint(x: 5.0, y: 7.2)); shaft.addLine(to: CGPoint(x: 8, y: 10.2)); shaft.addLine(to: CGPoint(x: 11.0, y: 7.2))
            stroke(shaft)
            let tray = CGMutablePath()
            tray.move(to: CGPoint(x: 3.0, y: 11.2)); tray.addLine(to: CGPoint(x: 3.0, y: 12.2))
            tray.addCurve(to: CGPoint(x: 4.4, y: 13.5), control1: CGPoint(x: 3.0, y: 13.0), control2: CGPoint(x: 3.6, y: 13.5))
            tray.addLine(to: CGPoint(x: 11.6, y: 13.5))
            tray.addCurve(to: CGPoint(x: 13.0, y: 12.2), control1: CGPoint(x: 12.4, y: 13.5), control2: CGPoint(x: 13.0, y: 13.0))
            tray.addLine(to: CGPoint(x: 13.0, y: 11.2))
            stroke(tray)
        case .cancel:
            // 取消 Esc：×（重设计：两端外扩至 4.0–12.0）
            strokeLine(4, 4, 12, 12)
            strokeLine(12, 4, 4, 12)
        case .copy:
            // 复制（重设计：前纸外扩至 70% 视窗、后纸弧线重绘）
            strokeRoundedRect(5.8, 5.8, 7.4, 7.4, r: 1.6)
            let back = CGMutablePath()
            back.move(to: CGPoint(x: 10.4, y: 5.8)); back.addLine(to: CGPoint(x: 10.4, y: 4.2))
            back.addCurve(to: CGPoint(x: 9.0, y: 2.8), control1: CGPoint(x: 10.4, y: 3.3), control2: CGPoint(x: 9.9, y: 2.8))
            back.addLine(to: CGPoint(x: 4.4, y: 2.8))
            back.addCurve(to: CGPoint(x: 3.0, y: 4.2), control1: CGPoint(x: 3.5, y: 2.8), control2: CGPoint(x: 3.0, y: 3.3))
            back.addLine(to: CGPoint(x: 3.0, y: 8.8))
            back.addCurve(to: CGPoint(x: 4.4, y: 10.2), control1: CGPoint(x: 3.0, y: 9.7), control2: CGPoint(x: 3.5, y: 10.2))
            back.addLine(to: CGPoint(x: 5.8, y: 10.2))
            stroke(back)
        case .ellipse:
            // 椭圆工具（3）：纯轮廓 rx 5.6 / ry 4.2（去掉中心十字/点——与 Eye 彻底区分，
            // 与矩形等高、圆角气质一致；紧贴矩形成「形状两兄弟」组）
            strokeEllipseAt(8, 8, rx: 5.6, ry: 4.2)
        case .scroll:
            // 滚动截图（重设计 2笔：选区加高至 72% 视窗、箭头上移留笔尖呼吸空间）
            strokeRoundedRect(3.2, 2.4, 9.6, 11.2, r: 1.8)
            let stem = CGMutablePath()
            stem.move(to: CGPoint(x: 8, y: 4.6)); stem.addLine(to: CGPoint(x: 8, y: 10.4))
            stem.move(to: CGPoint(x: 6.0, y: 8.4)); stem.addLine(to: CGPoint(x: 8, y: 10.4)); stem.addLine(to: CGPoint(x: 10.0, y: 8.4))
            stroke(stem)
        }
    }
}
