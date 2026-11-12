import SwiftUI
import UIKit

/// 1.7.5：海报加载器。
///
/// 为什么不用 `AsyncImage`：
/// 1. 它只能用 `URLSession.shared`，而端上化之后**所有海报都走同一个 host**
///    （`127.0.0.1:端上 Node/imageProxy`），共享会话每 host 只开 6 条连接，
///    一屏 20 张图要排 4 轮，滚起来一顿一顿的。
/// 2. 它没有内存缓存，滚回去就重新下。
///
/// 这里给独立的会话（24 条连接）+ NSCache 内存缓存，同屏并发直接把图拉满。
final class RemoteImageLoader {

    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 10
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        // 海报地址里带 cache=86400，让它走系统缓存；重复进来不用再下
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)

        cache.countLimit = 160          // 1.8.0：300 → 160，配合内存收紧
        cache.totalCostLimit = 48 << 20 // 1.8.0：80 → 48 MB
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL, cost: data.count)
        return img
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
