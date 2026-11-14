import AppKit
import CoreGraphics

/// Snapcut 图标绘制（代码绘制 = 唯一真源；design/status-icon.svg 只是设计参考）
///
/// 图形语义：四角选区括号 + 中心圆点 = "框选截图"
enum IconFactory {
    /// 菜单栏模板图标（从品牌 mark 剪影资源加载；黑色 + isTemplate，
    /// 系统自动适配浅色/深色/强调色菜单栏）
    ///
    /// 资源来源：GPT 生成的品牌 logo（蓝底白 mark）→ 阈值提取白色 mark
    /// 剪影 → 64px PNG（Resources/StatusMark.png）。
    /// 旧版代码绘制四角括号已废弃——品牌统一走 logo mark。
    static func statusIcon(pointSize: CGFloat = 18) -> NSImage {
        if let url = Bundle.main.url(forResource: "StatusMark", withExtension: "png"),
           let loaded = NSImage(contentsOf: url) {
            loaded.isTemplate = true
            // 实验 A：注释 resize，定位启动即退（若存活 ⇒ size 重设导致 MenuBarExtra 场景失效）
            // let ratio = pointSize / max(loaded.size.width, 1)
            // loaded.size = NSSize(width: loaded.size.width * ratio, height: loaded.size.height * ratio)
            return loaded
        }
        // 兜底：资源缺失时回退代码绘制（等比缩放保证任意 pointSize 可用）
        let scale: Int = 2
        let px = Int(pointSize) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage() }
        rep.size = NSSize(width: pointSize, height: pointSize)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        drawCropMarks(
            in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
            strokeColor: .black,
            dotColor: .black,
            strokeScale: 1.0
        )
        ctx?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// 拖拽影像 / 浮窗展示用 App 图标（蓝底白图形，非模板）
    static func appIcon(pointSize: CGFloat = 64) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.lockFocus()
        let full = NSRect(x: 0, y: 0, width: pointSize, height: pointSize)
        // macOS 会自动套 squircle 圆角，这里画满幅背景
        let bg = NSColor(calibratedRed: 0.145, green: 0.388, blue: 0.922, alpha: 1) // #2563EB
        bg.setFill()
        full.fill()
        drawCropMarks(
            in: full.insetBy(dx: pointSize * 0.14, dy: pointSize * 0.14),
            strokeColor: .white,
            dotColor: .white,
            strokeScale: 1.6 // 图标要更粗壮
        )
        image.unlockFocus()
        return image
    }

    // MARK: - 绘制核心

    /// 四角圆头括号 + 中心圆点
    private static func drawCropMarks(
        in rect: NSRect,
        strokeColor: NSColor,
        dotColor: NSColor,
        strokeScale: CGFloat
    ) {
        let side = min(rect.width, rect.height)
        let inset = side * 0.10
        let length = side * 0.28
        let lineWidth = side * 0.10 * strokeScale
        let dotRadius = side * 0.085

        strokeColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let tl = CGPoint(x: rect.minX + inset, y: rect.maxY - inset)
        let tr = CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)
        let br = CGPoint(x: rect.maxX - inset, y: rect.minY + inset)
        let bl = CGPoint(x: rect.minX + inset, y: rect.minY + inset)

        // 每个括号 = 起点 → 角点 → 终点（L 形，round join 自然圆角）
        let brackets: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: tl.x, y: tl.y - length), tl, CGPoint(x: tl.x + length, y: tl.y)),
            (CGPoint(x: tr.x - length, y: tr.y), tr, CGPoint(x: tr.x, y: tr.y - length)),
            (CGPoint(x: br.x, y: br.y + length), br, CGPoint(x: br.x - length, y: br.y)),
            (CGPoint(x: bl.x + length, y: bl.y), bl, CGPoint(x: bl.x, y: bl.y + length)),
        ]
        for (start, corner, end) in brackets {
            path.move(to: start)
            path.line(to: corner)
            path.line(to: end)
        }
        path.stroke()

        dotColor.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: rect.midX - dotRadius,
                y: rect.midY - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
        ).fill()
    }
}
