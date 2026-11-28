import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 剪贴板写入（docs/03 §9：PNG + TIFF 双表示）
enum ClipboardWriter {
    // MARK: - 自写标记（剪贴板图片智能感知的防自触发闸门）

    /// Snapcut 自己最后一次写系统剪贴板时的 `changeCount`（-1 = 尚未写过）。
    /// 外部剪贴板 watcher 据此跳过自己写进去的内容——否则「截图自动复制 → 弹提示 → 提示里再复制」
    /// 会自己触发自己，形成提示套娃。
    @MainActor private(set) static var lastOwnWriteChangeCount: Int = -1

    /// 写入完成后调用：记下当前 changeCount 作为「这是自己写的」凭证。
    @MainActor
    static func markOwnWrite() {
        lastOwnWriteChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - 写入
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
        if ok { markOwnWrite() }
        return ok
    }

    /// 把本地文件写入系统剪贴板（支持粘贴进访达/微信/飞书/Slack；若是 GIF 同步附加动图数据）
    @MainActor
    @discardableResult
    static func writeFileURL(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var wrote = pasteboard.writeObjects([url as NSURL])
        var fmts = ["fileURL"]
        var bytes = 0
        if url.pathExtension.lowercased() == "gif", let gifData = try? Data(contentsOf: url) {
            bytes = gifData.count
            let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
            if pasteboard.setData(gifData, forType: gifType) {
                fmts.append("gif")
                wrote = true
            }
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber {
            bytes = size.intValue
        }
        Log.event(.clipboard, "clipboard.write", [
            "fmts": fmts.joined(separator: "+"),
            "bytes": "\(bytes)",
            "ok": "\(wrote)",
        ])
        if wrote { markOwnWrite() }
        return wrote
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
