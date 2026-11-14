import AppKit
import CoreGraphics

/// 导出协调器（docs/03 §4 Export 模块，v0.1 子集：复制 + 保存）
@MainActor
final class ExportCoordinator {
    /// 复制到剪贴板
    func copyToClipboard(_ image: CGImage) {
        ClipboardWriter.writeImage(image)
    }

    /// 原生保存面板（R4：⌘S = NSSavePanel）
    func savePanel(_ image: CGImage) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName()
        panel.message = "保存截图"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                Log.event(.export, "export.save.cancelled")
                self?.releaseFocus()
                return
            }
            self?.writePNG(image, to: url)
            self?.releaseFocus()
        }
    }

    // MARK: - 私有

    /// 保存面板关闭后把激活权还给原 App（同 overlay.end 的焦点归还逻辑）
    private func releaseFocus() {
        guard NSApp.isActive else { return }
        NSApp.deactivate()
        Log.event(.app, "focus.deactivated")
    }

    private func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Snapcut \(formatter.string(from: Date())).png"
    }

    private func writePNG(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.error(.export, "export.save.fail", ["err": "PNG 编码失败"])
            return
        }
        do {
            try data.write(to: url)
            Log.event(.export, "export.save.ok", [
                "bytes": "\(data.count)",
                "path": "<private>", // privacy: .private（docs/03 §7.2）
            ])
        } catch {
            Log.error(.export, "export.save.fail", ["err": "\(error.localizedDescription)"])
        }
    }
}
