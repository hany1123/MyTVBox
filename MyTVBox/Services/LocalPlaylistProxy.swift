import Foundation
import Darwin

// MARK: - 本地 m3u8 代理（1.4.7）
//
// AVPlayer 无法在播放过程中跳过某个分片，唯一可行的去广告时机是「拿到 playlist 之前」。
// 这里在 App 进程内起一个只监听 127.0.0.1 的极简 HTTP/1.1 服务：
//   AVPlayer → /playlist?u=<base64url(原始 m3u8)> → 本代理拉原始 playlist
//            → M3U8AdFilter 剔除广告段、把分片改成绝对地址 → 回吐给 AVPlayer
// 分片仍由 AVPlayer 直连 CDN，不经过本进程转发，因此没有额外带宽/解码开销。
//
// 端口由系统分配（bind port=0），不占用固定端口，也不会和宝盒那类 9978 本地服务冲突。

final class LocalPlaylistProxy {

    static let shared = LocalPlaylistProxy()

    static let enabledKey = "MyTVBox.adFilterEnabled"

    /// 默认开启；用户在「接口管理 → 播放设置」里可一键关掉，关掉后完全退回 1.4.6 直连路径
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static let safariUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1"

    private var listenFD: Int32 = -1
    private var port: Int = 0
    private var running = false
    private let stateLock = NSLock()
    private let summaryLock = NSLock()
    private var pendingSummary: String?
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = ["User-Agent": Self.safariUA]
        session = URLSession(configuration: cfg)
    }

    // MARK: - 对外

    /// 生成本地代理地址；启动失败时返回 nil（调用方自动退回直连）
    func proxyURL(for original: URL) -> URL? {
        guard ensureStarted(), port > 0 else { return nil }
        return URL(string: encodedProxyURL(for: original.absoluteString))
    }

    /// 取一次最近一次过滤结果（读完即清空），供播放器短暂提示
    func consumeSummary() -> String? {
        summaryLock.lock()
        defer { summaryLock.unlock() }
        let value = pendingSummary
        pendingSummary = nil
        return value
    }

    private func storeSummary(_ value: String) {
        summaryLock.lock()
        pendingSummary = value
        summaryLock.unlock()
    }

    private func encodedProxyURL(for absolute: String) -> String {
        guard port > 0, let data = absolute.data(using: .utf8) else { return absolute }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "http://127.0.0.1:\(port)/playlist?u=\(encoded)"
    }

    private func decodeOriginal(_ encoded: String) -> URL? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return URLNormalizer.url(text) ?? URL(string: text)
    }

    // MARK: - Socket 启动

    private func ensureStarted() -> Bool {
        stateLock.lock()
        let already = running
        stateLock.unlock()
        if already { return true }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                       &reuse, socklen_t(MemoryLayout<Int32>.size))
        // SO_NOSIGPIPE：客户端提前断开时不让 send() 触发 SIGPIPE 杀进程
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, 0x1022,
                       &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // 由系统分配空闲端口
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                bind(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return false
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                getsockname(fd, sockPointer, &boundLength)
            }
        }
        guard nameResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }
        let actualPort = Int(UInt16(bigEndian: bound.sin_port))

        stateLock.lock()
        if running {
            stateLock.unlock()
            close(fd)
            return true
        }
        listenFD = fd
        port = actualPort
        running = true
        stateLock.unlock()

        let socketFD = fd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(fd: socketFD)
        }
        return true
    }

    private func acceptLoop(fd: Int32) {
        while true {
            stateLock.lock()
            let alive = running
            stateLock.unlock()
            if !alive { break }

            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, 0x1022,
                           &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let clientFD = client
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client: clientFD)
            }
        }
        close(fd)
    }

    // MARK: - 请求处理

    private func handle(client: Int32) {
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 16_384)
        let capacity = buffer.count
        var total = 0
        while total < capacity {
            let read: Int = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(client, base.advanced(by: total), capacity - total, 0)
            }
            if read <= 0 { break }
            total += read
            if total >= 4,
               let text = String(bytes: buffer[0..<total], encoding: .utf8),
               text.contains("\r\n\r\n") { break }
        }
        guard total > 0,
              let request = String(bytes: buffer[0..<total], encoding: .utf8),
              let firstLine = request.split(separator: "\n").first else { return }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let target = String(parts[1])
        let prefix = "/playlist?u="
        guard target.hasPrefix(prefix) else {
            writeResponse(client, status: "404 Not Found", type: "text/plain",
                          body: Data("not found".utf8))
            return
        }
        let encoded = String(target.dropFirst(prefix.count))
            .split(separator: "&").first.map(String.init) ?? ""
        guard let original = decodeOriginal(encoded) else {
            writeResponse(client, status: "400 Bad Request", type: "text/plain",
                          body: Data("bad url".utf8))
            return
        }
        guard let fetched = fetchPlaylist(original) else {
            writeResponse(client, status: "502 Bad Gateway", type: "text/plain",
                          body: Data("upstream failed".utf8))
            return
        }

        let text = decodeText(fetched.data)
        let cleaned = M3U8AdFilter.clean(text, baseURL: fetched.finalURL) { [weak self] absolute in
            self?.encodedProxyURL(for: absolute) ?? absolute
        }
        if let summary = cleaned.stats.summary {
            storeSummary(summary)
        }
        writeResponse(client,
                      status: "200 OK",
                      type: "application/vnd.apple.mpegurl",
                      body: Data(cleaned.text.utf8))
    }

    // MARK: - 上游拉取 / 响应写回

    private func fetchPlaylist(_ url: URL) -> (data: Data, finalURL: URL)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let scheme = url.scheme, let host = url.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var finalURL: URL?
        let task = session.dataTask(with: request) { data, response, error in
            if error == nil, let data = data {
                payload = data
                finalURL = response?.url
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 13)
        guard let data = payload else { return nil }
        return (data, finalURL ?? url)
    }

    private func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeResponse(_ fd: Int32, status: String, type: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store, no-cache, must-revalidate\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n\r\n"
        var bytes = Data(header.utf8)
        bytes.append(body)
        let count = bytes.count
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < count {
                let written = send(fd, base.advanced(by: sent), count - sent, 0)
                if written <= 0 { break }
                sent += written
            }
        }
    }
}
