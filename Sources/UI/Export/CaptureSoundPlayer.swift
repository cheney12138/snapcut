import AppKit

/// 截图快门音效播放器（受 `AppSettings.playCaptureSound` 控制，关闭时零开销静默）。
///
/// 优先使用 macOS 原生截图快门音 `Screen Capture.aif`（回落 `Grab.aif` / 系统 `Tink`），
/// 在主线程缓存并复用已解码的 `NSSound` 实例，兼顾首次响应速度与连续截屏时的顺滑播控。
@MainActor
enum CaptureSoundPlayer {
    private static let candidatePaths: [String] = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
    ]

    private static var cachedSound: NSSound?

    /// 若设置已开启「截图音效」（或 `force == true` 用于设置开启瞬间的试听反馈），播放快门音。
    static func play(force: Bool = false) {
        let enabled = force || (AppCoordinatorShared.coordinator?.settings.playCaptureSound ?? false)
        guard enabled else { return }

        guard let sound = resolveSound() else {
            Log.error(.export, "capture.sound.missing")
            return
        }
        if sound.isPlaying {
            sound.stop()
        }
        sound.currentTime = 0
        _ = sound.play()
        Log.event(.export, "capture.sound.play", ["force": "\(force)"])
    }

    private static func resolveSound() -> NSSound? {
        if let cachedSound {
            return cachedSound
        }
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.9
                cachedSound = sound
                return sound
            }
        }
        if let fallback = NSSound(named: NSSound.Name("Tink")) {
            fallback.volume = 0.7
            cachedSound = fallback
            return fallback
        }
        return nil
    }
}
