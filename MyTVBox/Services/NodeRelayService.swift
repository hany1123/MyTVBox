import Foundation

/// 1.6.0：猫爪 / CatVodSpiderios **Node 中转服务**原生客户端。
///
/// 背景：这个猫爪源不是浏览器式 JS Spider，而是 `cat_vod_nodejs_fastify`
/// Node 服务端插件包（见 `MiraPlay_逆向分析.md`）。MiraPlay 靠内置
/// NodeMobile.framework 跑它；MyTVBox 选择在电脑上常驻 Node 服务，
/// App 侧直接说它的 HTTP 协议，不再需要 Python 桥接层。
///
/// Node 服务协议（实测）：
///   GET  /health                          -> {"ok":true,"name":"CatVodSpiderios"}
///   GET  /config                          -> {video:{sites:[...]}, ...}
///   POST /spider/{key}/{type}/home        -> {class, filters, list}
///   POST /spider/{key}/{type}/category    -> {page, pagecount, list}
///   POST /spider/{key}/{type}/detail      -> {list:[{vod_play_url, ...}]}
///   POST /spider/{key}/{type}/search      -> {page, pagecount, list}
///   POST /spider/{key}/{type}/play        -> {parse:0, url, header, format}
///
/// 返回体本身就是标准 TVBox JSON，所以 APIService 直接复用
/// `APIResponse` / `VideoDetailResponse` 解码，不需要平行数据模型。
final class NodeRelayService {
    static let shared = NodeRelayService()

    /// 播放地址占位 scheme：集地址是加密参数串而非 URL 时使用，
    /// `VideoPlayerViewModel.loadAndPlay` 会拦截并调 /play 换真实 m3u8。
    static let playScheme = "mytvboxnode://play"

    private static let baseKey = "MyTVBox.nodeRelay.baseURL"

    /// 1.7.5：专用会话 —— 这是端上化后最大的一处性能坑。
    ///
    /// 所有请求都打到同一个 host（127.0.0.1:端上 Node），而 URLSession 默认
    /// `httpMaximumConnectionsPerHost = 6`。聚合搜索要同时打 97 个站，等于 97 个
    /// 请求排队挤 6 条连接，一轮下来几十秒。把上限提到 48 之后，97 站基本两三轮就完了。
    /// 图片走同一个 Node 的 /imageProxy，也吃这个池子，所以一起受益。
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 48
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// 最近一次成功识别的 Node 服务基址（多个服务时播放地址里还会带 base）
    var baseURL: String? {
        get { UserDefaults.standard.string(forKey: Self.baseKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.baseKey) }
    }

    private init() {}

    // MARK: - 站点识别

    /// 只有从 Node 服务 /config 生成的站点带 `nodeRelayBase`
    static func isNodeSite(_ site: Site) -> Bool {
        guard let base = site.nodeRelayBase, !base.isEmpty else { return false }
        return true
    }

    /// 归一化用户填的地址：补 http、去掉 /config /health 等尾路径与 query
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        guard var comps = URLComponents(string: s),
              comps.scheme != nil,
              let host = comps.host, !host.isEmpty else { return nil }
        let path = comps.path
        if path.isEmpty || path == "/"
            || path.hasSuffix("/config") || path.hasSuffix("/health")
            || path.hasSuffix("/full-config") || path.hasSuffix("/check") {
            comps.path = ""
        }
        comps.query = nil
        comps.fragment = nil
        guard var out = comps.url?.absoluteString else { return nil }
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// 从 api 字段 `/spider/{key}/{type}` 里取 type（多数是 3，push 是 4）
    static func typeOf(_ site: Site) -> String {
        guard let api = site.api,
              let r = api.range(of: "/spider/") else { return "3" }
        let parts = String(api[r.upperBound...]).components(separatedBy: "/")
        if parts.count > 1, !parts[1].isEmpty { return parts[1] }
        return "3"
    }

    // MARK: - 配置加载

    /// 标准配置解析全部失败后的兜底：探测这是不是一台 CatVodSpiderios。
    /// 严格校验 /health 的 name，避免把任意 404 服务误判成 Node 中转。
    func tryLoadConfig(from raw: String) async -> TVBoxConfig? {
        guard let base = Self.normalize(raw) else { return nil }
        guard let health = try? await getJSON(base + "/health", timeout: 2.5),
              let ok = health["ok"] as? Bool, ok,
              let name = health["name"] as? String,
              name == "CatVodSpiderios" else { return nil }
        guard let cfg = try? await getJSON(base + "/config", timeout: 12),
              let video = cfg["video"] as? [String: Any],
              let arr = video["sites"] as? [[String: Any]], !arr.isEmpty else { return nil }

        baseURL = base
        let sites: [Site] = arr.compactMap { d in
            guard let key = d["key"] as? String, !key.isEmpty else { return nil }
            // 1.7.5：源自己勾了「不启用」的站点直接跳过 —— 源作者标了 enable:false
            // 就别硬塞进列表里；enable:true 的一律自动可用，不需要用户再点开关。
            if let en = Self.intValue(d["enable"]), en == 0 { return nil }
            let prefix = "nodejs_"
            let rawKey = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
            guard !rawKey.isEmpty else { return nil }
            let name = (d["name"] as? String) ?? rawKey
            let type = Self.intValue(d["type"]) ?? 3
            var apiPath = (d["api"] as? String) ?? "/spider/\(rawKey)/\(type)"
            if !apiPath.hasPrefix("/") { apiPath = "/" + apiPath }
            return Site(key: "noderelay_" + rawKey,
                        name: name,
                        type: 1,                 // 走 JSON 直解分支，避免被当 JSP
                        api: base + apiPath,
                        searchable: Self.intValue(d["searchable"]) ?? 1,
                        quickSearch: Self.intValue(d["quickSearch"]) ?? 0,
                        filterable: Self.intValue(d["filterable"]) ?? 1,
                        spiderKey: rawKey,
                        nodeRelayBase: base)
        }
        guard !sites.isEmpty else { return nil }
        return TVBoxConfig(sites: sites)
    }

    // MARK: - 内容接口

    /// POST 一个 spider 方法，返回原始 JSON 字典交给 APIService 复用 CMS 模型解码
    func call(site: Site, method: String, body: [String: Any],
              timeout: TimeInterval = 20) async throws -> [String: Any] {
        guard let base = site.nodeRelayBase, !base.isEmpty,
              let key = site.spiderKey, !key.isEmpty else {
            throw NetworkError.invalidURL
        }
        let type = Self.typeOf(site)
        let urlString = base + "/spider/" + key + "/" + type + "/" + method
        return try await postJSON(urlString, body: body, timeout: timeout)
    }

    /// 把详情里的 `vod_play_url` 参数串改写成自定义 scheme，播放时再换真实地址。
    /// 结构与 Python 桥接层一致：`$$$` 分线路、`#` 分集、`$` 分集名与参数。
    static func rewritePlayURLs(_ dict: inout [String: Any], site: Site) {
        guard var list = dict["list"] as? [[String: Any]] else { return }
        let key = site.spiderKey ?? ""
        let type = typeOf(site)
        let base = site.nodeRelayBase ?? ""
        for i in list.indices {
            guard let pu = list[i]["vod_play_url"] as? String, !pu.isEmpty else { continue }
            list[i]["vod_play_url"] = rewritePlayURL(pu, key: key, type: type, base: base)
        }
        dict["list"] = list
    }

    static func rewritePlayURL(_ pu: String, key: String, type: String, base: String) -> String {
        let groups = pu.components(separatedBy: "$$$")
        let out: [String] = groups.map { group in
            let eps = group.components(separatedBy: "#").map { ep -> String in
                guard let r = ep.range(of: "$") else { return ep }
                let name = String(ep[ep.startIndex..<r.lowerBound])
                let param = String(ep[r.upperBound...])
                let lower = param.lowercased()
                if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return ep }
                guard !param.isEmpty,
                      let pid = percentEncode(param),
                      let b = percentEncode(base) else { return ep }
                return name + "$" + playScheme
                    + "?site=" + key + "&type=" + type
                    + "&base=" + b + "&id=" + pid
            }
            return eps.joined(separator: "#")
        }
        return out.joined(separator: "$$$")
    }

    /// 严格 ASCII 百分号编码，避免 `&` `=` `#` `|` 破坏 scheme URL
    private static func percentEncode(_ s: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    // MARK: - 播放取流

    /// 解析 `mytvboxnode://play?...`，调 /play 换出真实 m3u8 + 请求头
    func resolvePlay(_ urlString: String) async -> (URL, [String: String])? {
        guard urlString.hasPrefix(Self.playScheme),
              let comps = URLComponents(string: urlString) else { return nil }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        guard let key = q["site"], !key.isEmpty,
              let id = q["id"], !id.isEmpty else { return nil }
        let type = q["type"] ?? "3"
        let base = (q["base"].flatMap { Self.normalize($0) }) ?? baseURL
        guard let base, !base.isEmpty else { return nil }
        guard let r = try? await postJSON(
            base + "/spider/" + key + "/" + type + "/play",
            body: ["id": id], timeout: 20),
              let u = r["url"] as? String, !u.isEmpty,
              let url = URL(string: u) else { return nil }
        var headers: [String: String] = [:]
        if let h = r["header"] as? [String: Any] {
            for (k, v) in h { headers[k] = "\(v)" }
        }
        return (url, headers)
    }

    // MARK: - HTTP

    private func getJSON(_ urlString: String, timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let (data, resp) = try await Self.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw NetworkError.decodingFailed("Node 服务返回 \(status)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.decodingFailed("Node 服务返回非 JSON")
        }
        return obj
    }

    private func postJSON(_ urlString: String, body: [String: Any],
                          timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await Self.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw NetworkError.decodingFailed("Node 服务返回 \(status)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.decodingFailed("Node 服务返回非 JSON")
        }
        return obj
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let d = v as? Double { return Int(d) }
        if let b = v as? Bool { return b ? 1 : 0 }
        return nil
    }
}
