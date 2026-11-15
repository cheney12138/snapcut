import AppKit
import CoreGraphics

/// 拼贴图像缓存（docs/06 §4：imageRef 是图像库键，适配器负责解析为位图）
///
/// CollageDocument 是纯值类型，只存 imageRef 字符串；像素由本缓存按键解析。
/// NSCache 自带线程安全与内存压力自动逐出，无需自己实现 LRU。
/// addPiece 时由 CollageWindowController 写入；贴片删除时引用自然失效，
/// 不主动清理（NSCache 会随内存压力回收，会话级生命周期足够）。
@MainActor
final class CollageImageCache {
    static let shared = CollageImageCache()

    private let cache = NSCache<NSString, CGImage>()

    private init() {
        // 会话级拼贴：上限 200 张足够（同 AnnotationStore 200 条上限同一量级）
        cache.countLimit = 200
    }

    func image(for ref: String) -> CGImage? {
        cache.object(forKey: ref as NSString)
    }

    func store(_ image: CGImage, for ref: String) {
        cache.setObject(image, forKey: ref as NSString)
    }

    func remove(for ref: String) {
        cache.removeObject(forKey: ref as NSString)
    }

    /// 清空（清空画布时调用；防大图常驻内存）
    func removeAll() {
        cache.removeAllObjects()
    }
}
