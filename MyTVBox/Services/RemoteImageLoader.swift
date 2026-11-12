import SwiftUI
import UIKit
import ImageIO

/// 1.7.5：海报加载器。
///
/// 为什么不用 `AsyncImage`：
/// 1. 它只能用 `URLSession.shared`，而端上化之后**所有海报都走同一个 host**
///    （`127.0.0.1:端上 Node/imageProxy`），共享会话每 host 只开 6 条连接，
///   一屏 20 张图要排 4 轮，滚起来一顿一顿的。
/// 2. 它没有内存缓存，滚回去就重新下。
///
/// 1.8.3：这才是「搜索出结果后闪退」的真凶。
/// 旧版 `cache.setObject(img, cost: data.count)` 记的是**压缩后的 JPEG 字节数**，
/// 但 UIImage 真正占的是解码后的位图：一张 1000×1500 海报 ≈ 6 MB，是 100 KB
/// JPEG 的 60 倍。`totalCostLimit = 48MB` 因此形同虚设，174 条结果滑几屏就能
/// 堆到几百 MB → iOS Jetsam 直接杀进程（没有 crash.log，完全对得上）。
/// 现在两步根治：① ImageIO 直接生成 420px 缩略图（显示尺寸足够，且立即解码）
/// ② cost 用 `cgImage.width * height * 4` 的真实位图字节数。
final class RemoteImageLoader {

    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    /// 海报卡片宽约 126pt，@3x ≈ 378px；420 足够且不浪费
    private static let maxPixel = 420

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 8   // 1.8.3：10 → 8
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        // 海报地址里带 cache=86400，让它走系统缓存；重复进来不用再下
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)

        // cost 现在是「解码后位图字节」，不是压缩数据，单位终于对上了
        cache.countLimit = 96
        cache.totalCostLimit = 28 << 20   // 28 MB 真实位图 ≈ 26 张缩略海报

        // 系统发内存警告就整块清空：宁可重新下一张图，也别被 Jetsam 连进程端掉
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak cache] _ in
            cache?.removeAllObjects()
            // 1.8.3：内存警告是 Jetsam 的前一步，写进面包屑。
            // 下次诊断里出现「警 内存警告」，就能坐实是图片内存而不是 Node 抓取。
        }
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 供设置/诊断手动释放（内存吃紧时）
    func clearCache() {
        cache.removeAllObjects()
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              let img = Self.decode(data) else { return nil }
        cache.setObject(img, forKey: url as NSURL, cost: Self.bitmapBytes(img))
        return img
    }

    /// 用 ImageIO 直接出缩略图：不会先把 6 MB 全尺寸位图解码出来再缩，
    /// 而是在解码阶段就按 420px 生成，峰值内存也一起降下来。
    private static func decode(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    /// 真实占用：4 字节/像素（RGBA）。NSCache 的 cost 必须用这个，否则限流失效。
    private static func bitmapBytes(_ img: UIImage) -> Int {
        guard let cg = img.cgImage else { return 0 }
        return cg.width * cg.height * 4
    }
}

/// 卡片/背景通用的远程图：有内存缓存、有连接池、失败只显示占位不重试轰炸。
/// 占位图由调用方传入，避免「图片到了但占位还盖在上面」这种响应式坑。
struct RemoteImage<Placeholder: View>: View {

    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .task(id: url) {
            guard let url else { return }
            if let hit = RemoteImageLoader.shared.cached(url) {
                image = hit
                return
            }
            guard !didFail else { return }
            if let loaded = await RemoteImageLoader.shared.load(url) {
                image = loaded
            } else {
                didFail = true
            }
        }
    }
}
