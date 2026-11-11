import Foundation
import AVFoundation

// MARK: - m3u8 广告过滤路由（1.4.7.1）
//
// 1.4.7 初版用「App 内 127.0.0.1 socket 服务」代理 playlist，真机上全军覆没：
// HLS 请求由系统媒体进程发起，跨进程 loopback 在 iOS 上不可靠。
// 这里改用 Apple 官方的 AVAssetResourceLoader + 自定义 scheme：
//   · 不需要监听端口，不存在 socket / ATS / loopback 问题
//   · 只有 playlist 请求进 delegate，分片仍是绝对 http(s) 地址，由 AVPlayer 直连 CDN
//   · 上游拉取失败时通过 loadingRequest.redirect 直接退回原始 m3u8
//
// 开关默认关闭：保证升级后播放行为与 1.4.6 完全一致，验证过再手动开启。

enum LocalPlaylistProxy {

    static let enabledKey = "MyTVBox.adFilterEnabled"
    static let scheme = "mytvboxhls"

    /// 默认关闭；1.4.8 首次启动强制关一次，避免 1.4.7 残留设置继续拖垮播放。
    /// 之后完全尊重用户在「接口管理 → 播放设置」里的选择。
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        let migratedKey = "MyTVBox.adFilterMigrated148"
        if !defaults.bool(forKey: migratedKey) {
            defaults.set(false, forKey: enabledKey)
            defaults.set(true, forKey: migratedKey)
            return false
        }
        guard let value = defaults.object(forKey: enabledKey) else {
            return false
        }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    static func isProxied(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// 把原始 m3u8 包装成自定义 scheme，交给 AVAssetResourceLoader
    static func proxiedURL(for original: URL) -> URL? {
        URL(string: encodedURLString(for: original.absoluteString))
    }

    static func encodedURLString(for absolute: String) -> String {
        guard let data = absolute.data(using: .utf8) else { return absolute }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(scheme)://playlist?u=\(encoded)"
    }

    static func originalURL(from proxied: URL) -> URL? {
        var raw: String?
        if let comps = URLComponents(url: proxied, resolvingAgainstBaseURL: false) {
            raw = comps.queryItems?.first(where: { $0.name == "u" })?.value
        }
        if raw == nil {
            let text = proxied.absoluteString
            if let range = text.range(of: "?u=") {
                raw = String(text[range.upperBound...])
            }
        }
        guard let encoded = raw?.split(separator: "&").first.map(String.init) else {
            return nil
        }
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return URLNormalizer.url(text) ?? URL(string: text)
    }

    // MARK: - 过滤结果提示

    private static let summaryLock = NSLock()
    private static var pendingSummary: String?

    static func storeSummary(_ value: String) {
        summaryLock.lock()
        pendingSummary = value
        summaryLock.unlock()
    }

    /// 取一次最近一次过滤结果（读完即清空）
    static func consumeSummary() -> String? {
        summaryLock.lock()
        defer { summaryLock.unlock() }
        let value = pendingSummary
        pendingSummary = nil
        return value
    }
}

// MARK: - AVAssetResourceLoader 实现

final class HLSPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let shared = HLSPlaylistLoader()

    private static let safariUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1"

    private let session: URLSession
    private let loaderQueue = DispatchQueue(label: "mytvbox.hls.playlist")

    private override init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = ["User-Agent": Self.safariUA]
        session = URLSession(configuration: cfg)
        super.init()
    }

    /// 把自定义 scheme 的 asset 绑定到本 delegate。delegate 不被 asset 强持有，故用单例。
    func attach(to asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              LocalPlaylistProxy.isProxied(url),
              let original = LocalPlaylistProxy.originalURL(from: url) else {
            return false
        }

        var request = URLRequest(url: original)
        request.timeoutInterval = 12
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let scheme = original.scheme, let host = original.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }

        let task = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil else {
                    // 上游失败：直接让 AVFoundation 重定向回原始 m3u8，播放不受影响
                    loadingRequest.redirect = URLRequest(url: original)
                    loadingRequest.finishLoading()
                    return
                }
                let text = Self.decodeText(data)
                let finalURL = response?.url ?? original
                // master playlist 只做 URI 绝对化：variant 保持 http(s) 直连，
                // 不改写为自定义 scheme，避免 AVFoundation 在解析阶段拒绝
                let cleaned = M3U8AdFilter.clean(text, baseURL: finalURL)
                if let summary = cleaned.stats.summary {
                    LocalPlaylistProxy.storeSummary(summary)
                }
                let payload = Data(cleaned.text.utf8)
                loadingRequest.contentInformationRequest?.contentType =
                    "application/vnd.apple.mpegurl"
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
                loadingRequest.contentInformationRequest?.contentLength = Int64(payload.count)
                loadingRequest.dataRequest?.respond(with: payload)
                loadingRequest.finishLoading()
            }
        }
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        false
    }

    private static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
