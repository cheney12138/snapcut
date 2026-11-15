import AppKit
import CoreGraphics

/// 工具栏图标渲染器（设计稿 1:1：snapcut-design-redesign/index.html 的 15 个
/// 自绘 SVG 线性图标——SF Symbol 字形比例与设计稿不符，用户实报「竖着拉长/
/// 没跟设计稿对齐」）。
///
/// 视觉规格（与设计稿 .ic 一致）：viewBox 16、stroke 1.6pt、圆头/圆角连接、
/// 线色 currentColor（本层 = 调用方 tint）。实现：NSBitmapImageRep 2x 栅格化，
/// isTemplate = true → NSButton image + contentTintColor 上色（选中/强调态自动
/// 白字）。非模板色元素（马赛克块的 opacity 阶）在模板下不可表达——马赛克块
/// 改用描边 + 半数填充块表达网格语义（模板安全）。
enum TBIcon {
    /// 图标全集（tag 顺序 = 设计稿工具栏序）
    enum Kind {
        case arrow, rect, text, mosaic, sequence, highlight
        case undo, redo, ocr, pin, eye
        case save, cancel, copy, scroll
    }

    static func image(_ kind: Kind, pointSize: CGFloat = 16) -> NSImage {
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
        // viewBox 16 → pointSize 缩放（stroke 1.6 同步缩放）
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
        func strokeRoundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat, alpha: CGFloat = 1) {
            let p = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
            stroke(p, alpha: alpha)
        }
        func strokeCircle(_ cx: CGFloat, _ cy: CGFloat, r: CGFloat) {
            let p = CGMutablePath()
            p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            stroke(p)
        }

        switch kind {
        case .arrow:
            // 箭头 1：斜线 + 端箭头
            strokeLine(2.5, 13.5, 12, 4)
            strokeLine(12.5, 8.5, 12.5, 4)
            strokeLine(12.5, 4, 8, 4)
        case .rect:
            // 矩形 2：圆角矩形
            strokeRoundedRect(2.5, 4, 11, 8, r: 1.5)
        case .text:
            // 文字 3：T 带衬线
            strokeLine(3, 4.5, 3, 3); strokeLine(3, 3, 13, 3); strokeLine(3, 4.5, 13, 4.5)
            strokeLine(8, 3, 8, 13)
            strokeLine(6, 13, 10, 13)
        case .mosaic:
            // 马赛克 4：3×3 网格（设计稿填充块带 opacity——模板下改描边网格，
            // 对角块加粗表达马赛克语义）
            let p = CGMutablePath()
            for row in 0..<3 { for col in 0..<3 {
                let x = 2 + CGFloat(col) * 4.8, y = 2 + CGFloat(row) * 4.8
                p.addRect(CGRect(x: x, y: y, width: 4, height: 4))
            }}
            ctx.saveGState(); ctx.setLineWidth(1.1); ctx.addPath(p); ctx.strokePath(); ctx.restoreGState()
            // 对角重块（马赛克焦点）
            ctx.saveGState()
            ctx.setAlpha(0.9)
            for (c, r) in [(0,0),(2,1),(1,2)] {
                let x = 2 + CGFloat(c) * 4.8, y = 2 + CGFloat(r) * 4.8
                ctx.fill(CGRect(x: x + 0.8, y: y + 0.8, width: 2.4, height: 2.4))
            }
            ctx.restoreGState()
        case .sequence:
            // 序号 5：圆 + 数字「2」（曲线以折线近似）
            strokeCircle(8, 8, r: 5.6)
            let two = CGMutablePath()
            two.move(to: CGPoint(x: 6.4, y: 5.8))
            two.addCurve(to: CGPoint(x: 8.9, y: 5.8), control1: CGPoint(x: 6.9, y: 5.2), control2: CGPoint(x: 8.6, y: 5.2))
            two.addCurve(to: CGPoint(x: 9.4, y: 7.4), control1: CGPoint(x: 9.2, y: 6.6), control2: CGPoint(x: 8.6, y: 7.0))
            two.addCurve(to: CGPoint(x: 6.6, y: 9.4), control1: CGPoint(x: 8.2, y: 8.2), control2: CGPoint(x: 7.0, y: 8.6))
            two.addCurve(to: CGPoint(x: 9.2, y: 10.4), control1: CGPoint(x: 7.0, y: 10.6), control2: CGPoint(x: 8.6, y: 10.6))
            stroke(two)
        case .highlight:
            // 高亮 6：荧光笔斜置 + 底线
            let pen = CGMutablePath()
            pen.move(to: CGPoint(x: 9.5, y: 3))
            pen.addLine(to: CGPoint(x: 13, y: 6.5))
            pen.addLine(to: CGPoint(x: 7, y: 12.5))
            pen.addLine(to: CGPoint(x: 3.5, y: 12.5))
            pen.addLine(to: CGPoint(x: 3.5, y: 9))
            pen.closeSubpath()
            stroke(pen)
            strokeLine(3, 14.5, 13, 14.5, alpha: 0.5)
        case .undo:
            // 撤销 ⌘Z
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 6, y: 3.5)); p.addLine(to: CGPoint(x: 3, y: 6.5)); p.addLine(to: CGPoint(x: 6, y: 9.5))
            stroke(p)
            let p2 = CGMutablePath()
            p2.move(to: CGPoint(x: 3, y: 6.5))
            p2.addLine(to: CGPoint(x: 9.5, y: 6.5))
            p2.addCurve(to: CGPoint(x: 9.5, y: 13.5), control1: CGPoint(x: 13, y: 6.5), control2: CGPoint(x: 13, y: 13.5))
            p2.addLine(to: CGPoint(x: 7, y: 13.5))
            stroke(p2)
        case .redo:
            // 重做 ⇧⌘Z
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 10, y: 3.5)); p.addLine(to: CGPoint(x: 13, y: 6.5)); p.addLine(to: CGPoint(x: 10, y: 9.5))
            stroke(p)
            let p2 = CGMutablePath()
            p2.move(to: CGPoint(x: 13, y: 6.5))
            p2.addLine(to: CGPoint(x: 6.5, y: 6.5))
            p2.addCurve(to: CGPoint(x: 6.5, y: 13.5), control1: CGPoint(x: 3, y: 6.5), control2: CGPoint(x: 3, y: 13.5))
            p2.addLine(to: CGPoint(x: 9, y: 13.5))
            stroke(p2)
        case .ocr:
            // 取字 O：四角框 + 「文」
            strokeLine(2.5, 4.5, 2.5, 2.5); strokeLine(2.5, 2.5, 4.5, 2.5)
            strokeLine(13.5, 4.5, 13.5, 2.5); strokeLine(13.5, 2.5, 11.5, 2.5)
            strokeLine(2.5, 11.5, 2.5, 13.5); strokeLine(2.5, 13.5, 4.5, 13.5)
            strokeLine(13.5, 11.5, 13.5, 13.5); strokeLine(13.5, 13.5, 11.5, 13.5)
            strokeLine(5.5, 6, 5.5, 5.2); strokeLine(5.5, 5.2, 10.5, 5.2); strokeLine(10.5, 5.2, 10.5, 6)
            strokeLine(8, 5.2, 8, 10.8)
            strokeLine(6.8, 10.8, 9.2, 10.8)
        case .pin:
            // 贴图 P：图钉
            strokeLine(8, 2.5, 8, 8.5)
            let head = CGMutablePath()
            head.move(to: CGPoint(x: 5.5, y: 5)); head.addLine(to: CGPoint(x: 10.5, y: 5))
            head.addLine(to: CGPoint(x: 11.5, y: 8.5)); head.addLine(to: CGPoint(x: 4.5, y: 8.5))
            head.closeSubpath()
            stroke(head)
            let leg = CGMutablePath()
            leg.move(to: CGPoint(x: 6.5, y: 8.5)); leg.addLine(to: CGPoint(x: 6, y: 13.5))
            leg.addLine(to: CGPoint(x: 10, y: 13.5)); leg.addLine(to: CGPoint(x: 9.5, y: 8.5))
            stroke(leg)
        case .eye:
            // 眼睛 H
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 2, y: 8))
            p.addCurve(to: CGPoint(x: 8, y: 4), control1: CGPoint(x: 4.4, y: 4), control2: CGPoint(x: 5.6, y: 4))
            p.addCurve(to: CGPoint(x: 14, y: 8), control1: CGPoint(x: 10.4, y: 4), control2: CGPoint(x: 11.6, y: 4))
            p.addCurve(to: CGPoint(x: 8, y: 12), control1: CGPoint(x: 11.6, y: 12), control2: CGPoint(x: 10.4, y: 12))
            p.addCurve(to: CGPoint(x: 2, y: 8), control1: CGPoint(x: 5.6, y: 12), control2: CGPoint(x: 4.4, y: 12))
            stroke(p)
            strokeCircle(8, 8, r: 1.8)
        case .save:
            // 保存 ⌘S：下箭头 + 托盘
            strokeLine(8, 2.5, 8, 10)
            strokeLine(5, 7.5, 8, 10.5); strokeLine(11, 7.5, 8, 10.5)
            let tray = CGMutablePath()
            tray.move(to: CGPoint(x: 2.5, y: 11.5)); tray.addLine(to: CGPoint(x: 2.5, y: 12.5))
            tray.addCurve(to: CGPoint(x: 4, y: 14), control1: CGPoint(x: 2.5, y: 13.3), control2: CGPoint(x: 3.2, y: 14))
            tray.addLine(to: CGPoint(x: 12, y: 14))
            tray.addCurve(to: CGPoint(x: 13.5, y: 12.5), control1: CGPoint(x: 12.8, y: 14), control2: CGPoint(x: 13.5, y: 13.3))
            tray.addLine(to: CGPoint(x: 13.5, y: 11.5))
            stroke(tray)
        case .cancel:
            // 取消 Esc：×
            strokeLine(4, 4, 12, 12)
            strokeLine(12, 4, 4, 12)
        case .copy:
            // 复制（设计稿 tb-copy：双叠文档，字形方正不竖长）
            strokeRoundedRect(5.5, 5.5, 8, 8, r: 1.6)
            let back = CGMutablePath()
            back.move(to: CGPoint(x: 10.5, y: 5.5)); back.addLine(to: CGPoint(x: 10.5, y: 3.5))
            back.addCurve(to: CGPoint(x: 8.9, y: 1.9), control1: CGPoint(x: 10.5, y: 2.6), control2: CGPoint(x: 9.8, y: 1.9))
            back.addLine(to: CGPoint(x: 3.9, y: 1.9))
            back.addCurve(to: CGPoint(x: 2.3, y: 3.5), control1: CGPoint(x: 3.1, y: 1.9), control2: CGPoint(x: 2.3, y: 2.6))
            back.addLine(to: CGPoint(x: 2.3, y: 8.5))
            back.addCurve(to: CGPoint(x: 3.9, y: 10.1), control1: CGPoint(x: 2.3, y: 9.4), control2: CGPoint(x: 3.1, y: 10.1))
            back.addLine(to: CGPoint(x: 5.5, y: 10.1))
            stroke(back)
        case .scroll:
            // 滚动截图（设计稿无此按钮，新增同风格自绘：长条选区 + 下生长箭头）
            strokeRoundedRect(3, 2.5, 10, 11, r: 1.6)
            strokeLine(6, 8, 8, 10); strokeLine(10, 8, 8, 10)
            strokeLine(8, 10, 8, 4.5)
        }
    }
}
