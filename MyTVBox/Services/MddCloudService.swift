import Foundation
import CryptoKit

/// mddcloud 原生客户端（1.5.1）
///
/// 来源：iBox 2.5.1 真机 A+ 探针解出的完整原版 JS Spider（7,830 B / 21 函数），
/// 签名算法与请求体在 PC 侧已用 Python 等价实现全链路实测 200。
///
/// 为什么不用 JavaScriptCore 直接跑那份 JS：原版 Spider 全部是 `async function`，
/// 依赖 Spider 环境特有的 `fetch(url,{json,responseType})` 与 Promise，裸 JSContext
/// 对这套约定的支持不可靠。这里把已验证的签名与接口翻成 Swift 原生实现，
/// 数据直接映射成 MyTVBox 现有的 VideoItem / VideoDetail / APIResponse。
///
/// 原版 JS 保留在交付目录 `ibox_v2_return/mdd_spider_official.js`，供以后引擎升级对照。
final class MddCloudService {

    static let shared = MddCloudService()

    /// 内置站点的伪协议；ConfigService 只放行带此前缀的 type=3 站点
    static let siteScheme = "mytvbox://mddcloud"
    /// 剧集占位地址格式：mddcloud://play/<vodUuid>/<num>
    static let playScheme = "mddcloud://play/"

    static func isMddSite(_ site: Site) -> Bool {
        (site.api ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix(siteScheme)
    }

    private enum CFG {
        static let api = "https://mob.mddcloud.com.cn"
        static let webApi = "https://activity.mddcloud.com.cn"
        static let site = "https://m.mddcloud.com.cn"
        static let appKey = "e1be6b4cf4021b3d181170d1879a530a9e4130b69032144d5568abfd6cd6c1c2"
        static let webKey = "8a4af424bd714be5b2baacbe3cf5bbbe0131effeb92e99356ef1662884558f28"
        static let channel = "2250"
        static let appVersion = "5.6.01"
        static let pageRows = 18
        static let appUA = "Mdd/5.6.01 (Android+32+)"
        static let webUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    private let catalog: [(String, String)] = [
        ("0", "剧集"), ("1", "电影"), ("2", "综艺")
    ]

    private init() {}

    // MARK: - 对外接口（与 APIService 对齐）

    func categories() -> [VideoCategory] {
        catalog.map { VideoCategory(typeId: $0.0, typeName: $0.1) }
    }

    func videoList(categoryId: String, page: Int) async throws -> APIResponse {
        let vodType = Int(categoryId) ?? 0
        let pg = max(1, page)
        let data: [String: Any] = [
            "isVip": -1, "orderType": -1, "rows": CFG.pageRows,
            "startRow": (pg - 1) * CFG.pageRows,
            "uuidList": [], "vodType": vodType
        ]
        guard let resp = await appRequest("api/vod/classify/word/search.action", data),
              let arr = resp["data"] as? [Any] else {
            return APIResponse(code: 1, page: pg, list: [])
        }
        let items = arr.compactMap { mapItem($0) }
        return APIResponse(code: 1, page: pg, limit: CFG.pageRows,
                           list: items)
    }

    func search(keyword: String) async throws -> [VideoItem] {
        guard !keyword.isEmpty,
              let resp = await appRequest("searchApi/search/getAllSearchResult4820.action",
                                          ["keyWord": keyword]),
              let groups = resp["data"] as? [Any] else { return [] }
        var out: [VideoItem] = []
        for g in groups {
            guard let gd = g as? [String: Any],
                  let list = gd["vodList"] as? [Any] else { continue }
            out += list.compactMap { mapItem($0) }
        }
        return out
    }

    func detail(vodId: String) async throws -> VideoDetail? {
        guard let resp = await webRequest("/api/vod/getVodInfo.action/",
                                          ["vodUuid": vodId, "num": 1]),
              let d = resp["data"] as? [String: Any],
              let eps = d["vodSactionList"] as? [Any] else { return nil }

        var parts: [String] = []
        for (i, e) in eps.enumerated() {
            guard let ed = e as? [String: Any] else { continue }
            let num = intValue(ed["num"]) ?? (i + 1)
            let name = (ed["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let label = name.isEmpty ? "第\(num)集" : name
            parts.append("\(label)$\(Self.playScheme)\(vodId)/\(num)")
        }
        guard !parts.isEmpty else { return nil }

        let pic = httpsPic((d["coverImage"] as? String)
                           ?? (d["sideImage"] as? String) ?? "")
        return VideoDetail(
            vodId: vodId,
            vodName: (d["name"] as? String) ?? "",
            vodPic: pic,
            vodContent: d["introduction"] as? String,
            vodPlayFrom: "mddcloud",
            vodPlayUrl: parts.joined(separator: "#"),
            vodYear: d["yearName"] as? String,
            typeName: d["materialName"] as? String
        )
    }

    /// 把剧集占位地址换成真实 m3u8 / mp4
    func resolvePlayURL(_ urlString: String) async -> URL? {
        guard urlString.hasPrefix(Self.playScheme) else { return nil }
        let rest = String(urlString.dropFirst(Self.playScheme.count))
        let comps = rest.split(separator: "/").map(String.init)
        guard comps.count >= 2, let num = Int(comps[1]) else { return nil }
        guard let resp = await webRequest("/api/vod/getTrySaction.action/",
                                          ["vodUuid": comps[0], "num": num]),
              let d = resp["data"] as? [String: Any] else { return nil }
        for key in ["tryM3u8Url", "tryUrl", "tryMp4Url"] {
            guard let s = d[key] as? String, !s.isEmpty else { continue }
            if let u = URL(string: httpsPic(s)) { return u }
        }
        return nil
    }

    // MARK: - 签名（严格照原版 JS 的 jsonFragment / signValue / signDataString）

    private func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// JSON.stringify 一个字符串（含引号与转义），复用系统序列化器避免手写转义
    private func jsQuote(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s],
                                                  options: [.withoutEscapingSlashes]),
              let t = String(data: d, encoding: .utf8), t.count >= 2 else {
            return "\"" + s + "\""
        }
        return String(t.dropFirst().dropLast())
    }

    private func isBoolNumber(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// jsonFragment：对象按键排序、字符串加引号、数组递归
    private func jsonFragment(_ v: Any?) -> String {
        guard let v else { return "null" }
        if v is NSNull { return "null" }
        if let arr = v as? [Any] {
            return "[" + arr.map { jsonFragment($0) }.joined(separator: ",") + "]"
        }
        if let dict = v as? [String: Any] {
            let body = dict.keys.sorted().map {
                jsQuote($0) + ":" + jsonFragment(dict[$0])
            }.joined(separator: ",")
            return "{" + body + "}"
        }
        if let s = v as? String { return jsQuote(s) }
        if let n = v as? NSNumber {
            if isBoolNumber(n) { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return "null"
    }

    /// signValue：null→"null"、bool→true/false、object→jsonFragment、其它→String(e)
    private func signValue(_ v: Any?) -> String {
        guard let v else { return "null" }
        if v is NSNull { return "null" }
        if let d = v as? [String: Any] { return jsonFragment(d) }
        if let a = v as? [Any] { return jsonFragment(a) }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if isBoolNumber(n) { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return String(describing: v)
    }

    /// 按键排序，每段 `k=v&`，末尾保留一个 `&`（原版 JS 行为）
    private func signDataString(_ d: [String: Any]) -> String {
        d.keys.sorted().map { $0 + "=" + signValue(d[$0]) + "&" }.joined()
    }

    private func appSign(_ action: String, _ t: Int64, _ data: [String: Any]) -> String {
        md5("os:Android|version:\(CFG.appVersion)|action:/\(action)|time:\(t)" +
            "|appToken:|privateKey:\(CFG.appKey)|data:\(signDataString(data))")
    }

    private func webSign(_ t: Int64, _ data: [String: Any]) -> String {
        md5("time:\(t)|privateKey:\(CFG.webKey)|data:\(signDataString(data))")
    }

    // MARK: - HTTP

    private func appRequest(_ action: String, _ data: [String: Any]) async -> [String: Any]? {
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let a = action.hasPrefix("/") ? String(action.dropFirst()) : action
        let payload: [String: Any] = [
            "channel": CFG.channel, "data": data, "deviceNum": "",
            "deviceType": 0, "jsonSign": 0, "os": "Android",
            "sign": appSign(a, t, data), "sourceVersion": 0,
            "terminalType": "APP", "thirdStatus": 0, "time": t,
            "version": CFG.appVersion, "visitorStatus": 0
        ]
        return await post(CFG.api + "/" + a, payload: payload, headers: [
            "User-Agent": CFG.appUA,
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json; charset=UTF-8",
            "Referer": "mdd"
        ])
    }

    private func webRequest(_ path: String, _ data: [String: Any]) async -> [String: Any]? {
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let payload: [String: Any] = [
            "time": t, "sign": webSign(t, data), "data": data
        ]
        return await post(CFG.webApi + path, payload: payload, headers: [
            "User-Agent": CFG.webUA,
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json;charset=UTF-8",
            "Referer": CFG.site + "/",
            "Origin": CFG.site,
            "X-Requested-With": "XMLHttpRequest"
        ])
    }

    private func post(_ urlString: String,
                      payload: [String: Any],
                      headers: [String: String]) async -> [String: Any]? {
        guard let url = URL(string: urlString),
              let body = try? JSONSerialization.data(withJSONObject: payload,
                                                      options: [.withoutEscapingSlashes]) else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch {
            return nil
        }
    }

    // MARK: - 映射

    private func mapItem(_ any: Any) -> VideoItem? {
        guard let e = any as? [String: Any] else { return nil }
        let uid = (e["uuid"] as? String) ?? (e["vodUuid"] as? String) ?? ""
        guard !uid.isEmpty else { return nil }
        let pic = httpsPic((e["coverImage"] as? String)
                           ?? (e["sideImage"] as? String)
                           ?? (e["downImage"] as? String) ?? "")
        let note = e["updateNum"].map { "\($0)" }
        return VideoItem(
            vodId: uid,
            vodName: (e["name"] as? String) ?? "",
            vodPic: pic,
            vodRemarks: note,
            vodYear: e["yearName"] as? String,
            typeName: e["materialName"] as? String
        )
    }

    private func httpsPic(_ s: String) -> String {
        s.hasPrefix("http://") ? "https://" + String(s.dropFirst(7)) : s
    }

    private func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
