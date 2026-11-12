import Foundation

enum NetworkError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noData
    case decodingFailed(String)
    case spiderModuleNotSupported

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL 无效"
        case .invalidResponse: return "响应无效"
        case .httpError(let code): return "HTTP 错误 (\(code))"
        case .noData: return "无返回数据"
        case .decodingFailed(let msg): return "解析失败: \(msg)"
        case .spiderModuleNotSupported:
            return "该接口地址为猫爪/TVBox Spider 模块（JS 脚本），需要在 JS 引擎中运行才能生成配置。请使用标准的 TVBox JSON 配置地址（如 config.json），或在猫爪客户端中使用该接口。"
        }
    }
}

/// 网络请求封装：URLSession + Basic Auth + 任意编码兜底
final class NetworkManager {
    static let shared = NetworkManager()

    private let session: URLSession
    /// 1.7.8：本机 Node 源专用会话（超时放宽，见下方注释）
    private let localSession: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = [
            "User-Agent": "MyTVBox/1.0 (iOS)"
        ]
        // 使用 delegate 来处理重定向时保留 Auth header
        let delegate = RedirectDelegate()
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)

        // 1.7.8：源在设备上是解释执行，第一次生成 /config 可能要几十秒。
        // 用默认 20 秒会把「慢但能成」变成「失败」，而上层失败后还会再打
        // relay + 6 条备选路径，一次慢请求被放大成好几分钟（用户看到的就是
        // 「加载很慢，最后报错」）。这里给足 60/120 秒，且不等连通性。
        let lcfg = URLSessionConfiguration.default
        lcfg.timeoutIntervalForRequest = 60
        lcfg.timeoutIntervalForResource = 120
        lcfg.waitsForConnectivity = false
        lcfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        lcfg.httpAdditionalHeaders = [
            "User-Agent": "MyTVBox/1.0 (iOS)"
        ]
        self.localSession = URLSession(configuration: lcfg)
    }

    // MARK: - 公共接口

    /// 是否是「本机/回环」地址（端上 Node）
    static func isLoopback(_ urlString: String) -> Bool {
        guard let h = URLNormalizer.url(urlString)?.host?.lowercased() else { return false }
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "0.0.0.0"
    }

    /// 本机源请求：放宽超时，不走重定向/Auth 那套
    func localData(from urlString: String) async throws -> Data {
        guard let url = URLNormalizer.url(urlString) else { throw NetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await localSession.data(for: request)
        try validate(response)
        return data
    }

    /// 发起请求并返回原始 Data
    func data(from urlString: String, timeout: TimeInterval? = nil) async throws -> Data {
        guard let url = URLNormalizer.url(urlString) else { throw NetworkError.invalidURL }
        let request = makeRequest(url: url, timeout: timeout)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    /// 发起请求并解析为字符串（多编码兜底）
    func string(from urlString: String, timeout: TimeInterval? = nil) async throws -> String {
        let data = try await data(from: urlString, timeout: timeout)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .gbk) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw NetworkError.decodingFailed("无法识别字符编码")
    }

    /// JSON Decode 到指定类型
    func decode<T: Decodable>(_ type: T.Type, from urlString: String, timeout: TimeInterval? = nil) async throws -> T {
        let data = try await data(from: urlString, timeout: timeout)
        return try decodeJSON(type, data: data)
    }

    /// 数据 → JSON 对象（容错处理 BOM、注释、尾随逗号）
    func decodeJSON<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let cleaned = sanitizeJSONData(data)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: cleaned)
        } catch {
            // 尝试 GBK -> UTF-8 二次解析
            if let gbk = String(data: cleaned, encoding: .gbk),
               let reEncoded = gbk.data(using: .utf8) {
                return try decoder.decode(T.self, from: reEncoded)
            }
            throw NetworkError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - 内部

    private func makeRequest(url: URL, timeout: TimeInterval?) -> URLRequest {
        var request: URLRequest
        // 处理 Basic Auth: user:pass@host
        if let user = url.user, let pass = url.password {
            // 重建去掉认证信息的 URL
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.user = nil
            comps?.password = nil
            let cleanURL = comps?.url ?? url
            request = URLRequest(url: cleanURL)
            let authStr = "\(user):\(pass)"
            if let token = authStr.data(using: .utf8)?.base64EncodedString() {
                request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
        } else {
            request = URLRequest(url: url)
        }
        if let timeout = timeout {
            request.timeoutInterval = timeout
        }
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.httpError(http.statusCode)
        }
    }

    /// 去除 BOM、JS 风格注释、尾随逗号等常见非标准 JSON 内容
    private func sanitizeJSONData(_ data: Data) -> Data {
        guard var s = String(data: data, encoding: .utf8) else {
            return data
        }
        // 去除 BOM
        if s.hasPrefix("\u{FEFF}") {
            s.removeFirst()
        }
        // 去除单行 // 注释（仅在 JSON 开头未出现时处理，避免破坏字符串内的 URL）
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            s = s.replacingOccurrences(
                of: "(?m)^\\s*//.*$",
                with: "",
                options: .regularExpression
            )
            // 去除 /* */ 块注释
            s = s.replacingOccurrences(
                of: "/\\*[\\s\\S]*?\\*/",
                with: "",
                options: .regularExpression
            )
        }
        // 去除尾随逗号: ,}  ,]
        s = s.replacingOccurrences(
            of: ",(\\s*[}\\]])",
            with: "$1",
            options: .regularExpression
        )
        return s.data(using: .utf8) ?? data
    }
}

// MARK: - String.Encoding GBK 扩展

extension String.Encoding {
    static let gbk: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()
}

// MARK: - 重定向代理：保留 Basic Auth Header

/// 在 HTTP 重定向时保留 Authorization header（URLSession 默认会移除跨域 Auth）
private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var newRequest = request
        // 如果原请求有 Basic Auth，保留它（仅同域或子域）
        if let originalAuth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            let originalHost = task.originalRequest?.url?.host ?? ""
            let redirectHost = request.url?.host ?? ""
            if redirectHost == originalHost || redirectHost.hasSuffix("." + originalHost) {
                newRequest.setValue(originalAuth, forHTTPHeaderField: "Authorization")
            }
        }
        completionHandler(newRequest)
    }
}
