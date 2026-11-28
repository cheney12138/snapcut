import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 剪贴板写入（docs/03 §9：PNG + TIFF 双表示）
enum ClipboardWriter {
    // MARK: - 自写标记（剪贴板图片智能感知的防自触发闸门）

    /// 附加在 Snapcut 自写剪贴板内容上的私有 pasteboard type。
    ///
    /// 只多一个 type 名，不给外部 App 添任何负担：任何 App 粘贴图片/文件时只会按
    /// `public.png` / `public.tiff` / `public.file-url` 取数据，根本不会看这个自定义 type。
    /// 它让 `ClipboardImageWatcher` 100% 能认出「这一轮剪贴板是 Snapcut 自己写的」，
    /// 比只比对 `changeCount` 整数可靠得多（第三方剪贴板管理器 / Universal Clipboard
    /// 重写一次 changeCount 就飘了）。
    static let ownWriteMarkerType = NSPasteboard.PasteboardType("app.snapcut.own-clipboard-write")

    /// Snapcut 自己最后一次写系统剪贴板时的 `changeCount`（-1 = 尚未写过）。
    /// 外部剪贴板 watcher 据此跳过自己写进去的内容——否则「截图自动复制 → 弹提示 → 提示里再复制」
    /// 会自己触发自己，形成提示套娃。
    @MainActor private(set) static var lastOwnWriteChangeCount: Int = -1

    /// 最后一次自写剪贴板的时间（配合 `matchesRecentOwnImage` 做极短窗口兜底）
    @MainActor private(set) static var lastOwnWriteAt: Date = .distantPast

    /// 最后一次 `writeImage` 写出的图片像素宽高（第三方工具剥掉私有 type 后仍能指纹比对）
    @MainActor private(set) static var lastOwnImagePixelSize: CGSize?

    /// 写入完成后调用：记下当前 changeCount / 时间作为「这是自己写的」凭证，
    /// 并立刻把观察游标推给 watcher（同步取消在途探测任务，消灭「探测任务抢在
    /// markOwnWrite 之前跑完 Vision」的竞态）。
    @MainActor
    static func markOwnWrite() {
        let count = NSPasteboard.general.changeCount
        lastOwnWriteChangeCount = count
        lastOwnWriteAt = Date()
        ClipboardImageWatcher.shared.noteOwnWrite(changeCount: count)
    }

    /// 检查当前剪贴板是否明确带有 Snapcut 自写标记
    @MainActor
    static func hasOwnWriteMarker(in pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: [ownWriteMarkerType]) != nil
    }

    /// 兜底：若第三方剪贴板管理器在极短时间（<= 3.0s）内重新规范化剪贴板剥掉了私有标记，
    /// 比对像素宽高是否与 Snapcut 刚刚写出的截图完全一致。
    @MainActor
    static func matchesRecentOwnImage(_ image: CGImage, within seconds: TimeInterval = 3.0) -> Bool {
        guard Date().timeIntervalSince(lastOwnWriteAt) <= seconds,
              let lastSize = lastOwnImagePixelSize else { return false }
        return Int(lastSize.width) == image.width && Int(lastSize.height) == image.height
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
        if ok {
            // 同一轮内容里附加私有自写标记（不额外 clearContents，只是多挂一个 type）
            _ = pasteboard.setData(Data([1]), forType: Self.ownWriteMarkerType)
            lastOwnImagePixelSize = CGSize(width: image.width, height: image.height)
        }
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
        if wrote {
            // 写文件 URL 时同样打自写标记；顺带清掉上一张图的指纹，避免「刚写完文件 URL
            // 又冒出同尺寸外部图」被旧尺寸误判成自写
            _ = pasteboard.setData(Data([1]), forType: Self.ownWriteMarkerType)
            lastOwnImagePixelSize = nil
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
