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

    /// 快速保存：不弹面板，按设置的目录 + 文件名规则直接落盘（⌘⌥S / 托盘）
    /// 目录不存在时自动创建；失败只记日志（绝不打断截图主流程）
    @discardableResult
    func quickSave(_ image: CGImage, settings: AppSettings) -> URL? {
        let dir = URL(fileURLWithPath: (settings.saveDirectoryPath as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name: String
        switch settings.filenameStyle {
        case .timestamp:
            name = Self.timestampName()
        case .appAndTime:
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Snapcut"
            name = "\(app)_\(Self.timestampName())"
        case .askEveryTime:
            savePanel(image)
            return nil
        }
        let url = dir.appendingPathComponent("\(name).png")
        writePNG(image, to: url)
        Log.event(.export, "export.quickSave", ["path": url.path])
        return url
    }

    /// 文件名时间戳：yyyy-MM-dd_HH-mm-ss（与设置面板「时间戳」一致）
    static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
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
