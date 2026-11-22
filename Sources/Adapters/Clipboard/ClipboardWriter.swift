import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 剪贴板写入（docs/03 §9：PNG + TIFF 双表示）
enum ClipboardWriter {
    /// 把 CGImage 写入系统剪贴板（PNG + TIFF 双格式，写入 Retina 逻辑尺寸保证粘贴不误按 72dpi 缩放糊图）
    @MainActor
    @discardableResult
    static func writeImage(_ image: CGImage, scale: CGFloat? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let rep = NSBitmapImageRep(cgImage: image)
        let safeScale = max(1, scale ?? defaultRetinaScale())
        rep.size = NSSize(
            width: CGFloat(image.width) / safeScale,
            height: CGFloat(image.height) / safeScale
        )
        let pngData = rep.representation(using: .png, properties: [:])
        let tiffData = rep.tiffRepresentation

        var writtenTypes: [String] = []
        if let pngData {
            if pasteboard.setData(pngData, forType: .png) {
                writtenTypes.append("png")
            }
        }
        if let tiffData {
            if pasteboard.setData(tiffData, forType: .tiff) {
                writtenTypes.append("tiff")
            }
        }
        let ok = !writtenTypes.isEmpty
        Log.event(.clipboard, "clipboard.write", [
            "fmts": writtenTypes.joined(separator: "+"),
            "bytes": "\(pngData?.count ?? tiffData?.count ?? 0)",
            "ok": "\(ok)",
        ])
        return ok
    }

    @MainActor
    private static func defaultRetinaScale() -> CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return max(1, screen?.backingScaleFactor ?? 2)
    }
}
