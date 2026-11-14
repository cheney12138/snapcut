import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 剪贴板写入（docs/03 §9：PNG + TIFF 双表示）
enum ClipboardWriter {
    /// 把 CGImage 写入系统剪贴板（PNG + TIFF 双格式，保证 Preview/Pages/微信等粘贴一致）
    @MainActor
    static func writeImage(_ image: CGImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let rep = NSBitmapImageRep(cgImage: image)
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
}
