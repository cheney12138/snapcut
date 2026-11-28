import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VisionKit

/// 外部剪贴板里「被复制的一张图」的完整快照。
///
/// 只由 `ClipboardImageWatcher` 构造并回调，UI 层据此决定弹什么提示
/// （有文字 → 贴图/取字；只有二维码 → 取码）。`changeCount` 是这一张图的身份，
/// 回调方拿它和当前剪贴板比对，防止「提示还在显示、用户已经又复制了别的」时误操作。
@MainActor
struct ClipboardDetectedImage {
    let image: CGImage
    let analysis: ImageAnalysis
    let hasText: Bool
    let hasQR: Bool
    let charCount: Int
    let changeCount: Int
}

/// 剪贴板图片读取（纯读，不写、不持有状态）。
///
/// 设计纪律：
/// - `hasImageInPasteboard` 只查类型/扩展名，**不解码像素**——它每 0.6s 被调用一次，
///   必须便宜到无感；
/// - `readImage` 才真正解码，且只在「确认有图」之后调用；
/// - 单张静态图片文件 URL 优先于位图数据（保留原始分辨率与 EXIF 方向，截图工具/浏览器
///   「复制图片」多数落这条路径）；GIF 动图显式排除（那是动图，取字/贴图无意义，且
///   首帧静态图会误导用户）。
@MainActor
enum ClipboardImageReader {
    /// 认作「单张静态图片」的扩展名（显式排除 gif：动图不感知）
    static let staticImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "tiff", "tif", "bmp",
    ]

    /// 小于这个边长的一律视为图标/表情贴片（16/32/48 常用图标尺寸），不打扰
    static let minPixelSide = 48
    /// 超过这个字节数视为异常文件（> 30MB 的剪贴板图片解码会明显卡主线程）
    static let maxByteCount = 30 * 1024 * 1024

    /// 轻量检测当前剪贴板是否含图片（像素图或单张静态图片文件 URL，不含 GIF 动图），不做重解码
    static func hasImageInPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let urls = fileURLs(in: pasteboard)
        if !urls.isEmpty {
            // 有文件：只认单张静态图片；GIF / PDF / 视频等一律不算
            return urls.contains(where: isStaticImageFile)
        }
        // 位图数据：系统「复制图片」与 Snapcut 自己写剪贴板都落 png/tiff
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// 解码当前剪贴板原图
    ///
    /// 优先单张静态图片文件 URL，其次 PNG/TIFF/NSImage；过滤 < 48x48 小图标与 > 30MB 异常文件；
    /// `CGImageSource` 走 thumbnail-with-transform 路径以尊重 EXIF 方向（手机截图/相机图倒转
    /// 是最常见的取字失败原因）。
    static func readImage(from pasteboard: NSPasteboard = .general) -> CGImage? {
        let urls = fileURLs(in: pasteboard)
        if !urls.isEmpty {
            // 有文件就以文件为准：不静态的（gif/pdf/…）直接拒绝，绝不退化成「读首帧」
            let candidates = urls.filter(isStaticImageFile)
            guard let url = candidates.first else {
                Log.event(.clipboard, "clipboard.read.skip", ["reason": "fileType"])
                return nil
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let bytes = (attrs[.size] as? NSNumber)?.intValue,
               bytes > maxByteCount {
                Log.event(.clipboard, "clipboard.read.skip", [
                    "reason": "tooLarge", "bytes": "\(bytes)",
                ])
                return nil
            }
            if let image = decodeFile(at: url) { return image }
        }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type) else { continue }
            guard data.count <= maxByteCount else {
                Log.event(.clipboard, "clipboard.read.skip", [
                    "reason": "tooLarge", "bytes": "\(data.count)",
                ])
                continue
            }
            if let image = decode(data: data) { return image }
        }

        // 最后兜底：别的 App 只写了 NSImage 私有表示（少数老 App / 部分设计工具）
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = image.first,
           let cgImage = first.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            guard passesPixelFloor(cgImage) else { return nil }
            return cgImage
        }
        return nil
    }

    // MARK: - 内部

    /// 剪贴板里的文件 URL（只读 fileURL 类型，不触发数据加载）
    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) else {
            return []
        }
        return objects.compactMap { object in
            (object as? NSURL).map { $0 as URL }
        }
    }

    private static func isStaticImageFile(_ url: URL) -> Bool {
        staticImageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func decodeFile(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            Log.event(.clipboard, "clipboard.read.skip", ["reason": "decodeFail", "name": url.lastPathComponent])
            return nil
        }
        return decode(source: source, label: url.lastPathComponent)
    }

    private static func decode(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return decode(source: source)
    }

    private static func decode(source: CGImageSource, label: String = "data") -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        if pixelWidth > 0, pixelHeight > 0,
           pixelWidth < minPixelSide || pixelHeight < minPixelSide {
            Log.event(.clipboard, "clipboard.read.skip", [
                "reason": "tooSmall", "px": "\(pixelWidth)x\(pixelHeight)", "name": label,
            ])
            return nil
        }

        // 全尺寸 thumbnail + withTransform：一次解码拿到「尊重 EXIF 方向」的原图，
        // 不需要自己读 kCGImagePropertyOrientation 再翻矩阵。
        let maxPixelSize = max(pixelWidth, pixelHeight, minPixelSide)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            guard passesPixelFloor(image) else { return nil }
            return image
        }

        // 极少数格式 thumbnail 路径不可用：退回直接解码（方向信息可能丢失，但比没有强）
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard passesPixelFloor(image) else { return nil }
        return image
    }

    private static func passesPixelFloor(_ image: CGImage) -> Bool {
        guard image.width >= minPixelSide, image.height >= minPixelSide else {
            Log.event(.clipboard, "clipboard.read.skip", [
                "reason": "tooSmall", "px": "\(image.width)x\(image.height)",
            ])
            return false
        }
        return true
    }
}

/// 外部剪贴板图片感知 watcher：轮询 `NSPasteboard.changeCount`，只在「别人复制了一张
/// 带文字/带二维码的图」时回调一次。
///
/// 为什么轮询而不是事件：macOS 没有剪贴板变更通知，`changeCount` 是唯一可靠信号；
/// 0.6s + 0.2s tolerance 的 Timer 在 App Nap 下几乎零成本，且能保证「复制后 1s 内」响应。
///
/// 三道自扰闸门：
/// 1. 自写过滤：`ClipboardWriter.lastOwnWriteChangeCount` —— Snapcut 自己复制的图不弹提示；
/// 2. 忙态/前台过滤：正在截图、正在录屏、Snapcut 自己的窗口在前台时用户视线不在这里；
/// 3. 内容过滤：`hasText || hasQR` 才回调 —— 纯表情包/照片 0 打扰。
@MainActor
final class ClipboardImageWatcher {
    static let shared = ClipboardImageWatcher()

    /// 「剪贴板里当前有图」的 UserDefaults key —— SwiftUI 的 TrayMenuContent 直接读它
    /// 来实时显隐顶部「剪贴板图片」入口（AppKit 环境里没法直接观察 NSPasteboard）。
    static let hasImageDefaultsKey = "app.clipboard.hasImage"

    /// 轮询节奏：0.6s + 0.2s tolerance（用户复制后感知延迟 < 1s，功耗可忽略）
    static let tickInterval: TimeInterval = 0.6
    static let tickTolerance: TimeInterval = 0.2

    /// 总开关（设置页 smartClipboardImagePrompt 的运行时镜像）
    var isEnabled: Bool = true
    /// 忙态来源（截图/录屏/取色等独占交互期间不该弹提示）
    var isBusyProvider: (() -> Bool)?
    /// 检测到「值得打扰」的图片时回调（每次复制最多一次，纯 emoji/照片不回调）
    var onDetected: ((ClipboardDetectedImage) -> Void)?

    private var timer: Timer?
    /// 上次观察到的 changeCount：start() 时对齐当前值，避免把「启动前的旧剪贴板」当新复制
    private var lastObservedChangeCount: Int = -1
    /// 正在跑的 Vision 分析任务（新复制/无图时取消）
    private var probeTask: Task<Void, Never>?

    private init() {}

    /// 是否已在轮询（调试/自测用）
    var isRunning: Bool { timer != nil }

    // MARK: - 生命周期

    func start() {
        // 启动瞬间对齐 changeCount：此刻剪贴板里已有的东西是「旧的」，绝不弹提示
        lastObservedChangeCount = NSPasteboard.general.changeCount
        // 但「有没有图」要立刻发布一次：托盘首帧就能正确显隐入口
        Self.publishHasImage()

        guard timer == nil else {
            Log.event(.clipboard, "clipboard.watch.start", ["dedup": "true"])
            return
        }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            // Timer 回调在主 RunLoop ⇒ 这里确实在主线程，可安全断言 MainActor
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = Self.tickTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.event(.clipboard, "clipboard.watch.start", [
            "interval": "\(Self.tickInterval)",
            "tolerance": "\(Self.tickTolerance)",
            "hasImage": "\(ClipboardImageReader.hasImageInPasteboard())",
        ])
    }

    func stop() {
        if timer != nil {
            Log.event(.clipboard, "clipboard.watch.stop")
        }
        timer?.invalidate()
        timer = nil
        probeTask?.cancel()
        probeTask = nil
    }

    // MARK: - 轮询

    private func tick() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = currentCount

        // ① 先刷「剪贴板里有图吗」——与业务过滤无关，托盘入口必须实时跟着变
        Self.publishHasImage()

        // ② 自己写的不算什么「外部复制」
        guard currentCount != ClipboardWriter.lastOwnWriteChangeCount else { return }

        // ③ 开关 / 忙态 / Snapcut 自己在前台（用户视线不在这里，弹提示只会碍事）
        guard isEnabled, isBusyProvider?() != true, !NSApp.isActive else { return }

        // ④ 轻量判断：不是图就收工（取消可能还在跑的旧分析）
        guard ClipboardImageReader.hasImageInPasteboard() else {
            cancelProbe()
            return
        }
        guard let image = ClipboardImageReader.readImage() else {
            cancelProbe()
            return
        }

        // ⑤ 重解码 + Vision 分析放后台任务；期间用户又复制 → changeCount 变了，结果作废
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            let analysis = await PinLiveTextAnalyzer.analyze(image)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard NSPasteboard.general.changeCount == currentCount else { return }
            guard self.isEnabled, self.isBusyProvider?() != true else { return }
            guard let analysis else {
                Log.event(.clipboard, "clipboard.watch.skip", [
                    "reason": "analyzeFail", "px": "\(image.width)x\(image.height)",
                ])
                return
            }

            let hasText = analysis.hasResults(for: .text)
            let hasQR = analysis.hasResults(for: .machineReadableCode)
            let charCount = analysis.transcript.count

            guard hasText || hasQR else {
                // 纯表情包 / 照片：一句日志，零打扰
                Log.event(.clipboard, "clipboard.watch.skip", [
                    "reason": "noText",
                    "px": "\(image.width)x\(image.height)",
                ])
                return
            }

            Log.event(.clipboard, "clipboard.watch.detected", [
                "px": "\(image.width)x\(image.height)",
                "chars": "\(charCount)",
                "qr": "\(hasQR)",
            ])
            self.onDetected?(ClipboardDetectedImage(
                image: image,
                analysis: analysis,
                hasText: hasText,
                hasQR: hasQR,
                charCount: charCount,
                changeCount: currentCount
            ))
        }
    }

    private func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
    }

    private static func publishHasImage(_ pasteboard: NSPasteboard = .general) {
        UserDefaults.standard.set(
            ClipboardImageReader.hasImageInPasteboard(pasteboard),
            forKey: hasImageDefaultsKey
        )
    }
}
