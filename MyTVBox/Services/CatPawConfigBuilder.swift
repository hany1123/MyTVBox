import Foundation
import JavaScriptCore

/// CatPaw Spider 配置生成器
///
/// 从 CatPaw `.js.md5` URL 获取打包好的 JS 源码，
/// 通过正则提取各 spider 的 meta 信息，配合已知 CMS API 地址生成多站点配置。
///
/// 1.5.3：修复中文站名显示成 `\u63A8\u9001` 的问题 ——
/// JS 求值路径的偏移计算有误导致它永远失败并退回正则，
/// 而正则抠出来的是未解码的 JS 字符串字面量。现在两条路径都统一走
/// `decodeJSLiteral()`，还原 \uXXXX / \xNN / 代理对等转义。
///
/// 生成流程：
/// 1. `.js.md5` → 取 MD5 → 下载打包 JS 源码
/// 2. 正则提取 `meta: { key: '...', name: '...', type: N }`
/// 3. 通过 knownCMSAPIs 映射生成 TVBoxConfig（type=1 CMS 站点）
/// 4. 未知 spider 标记为 type=3（需 JS 引擎，当前显示为不可用）
final class CatPawConfigBuilder {

    static let shared = CatPawConfigBuilder()
    private let network = NetworkManager.shared
    private init() {}

    // MARK: - 公共接口

    func buildConfig(baseURL: String) async throws -> TVBoxConfig {
        // 1. 如果是 CatPaw URL，从打包 JS 中提取 spider 站点
        var catpawSites: [Site] = []
        if Self.isCatPawURL(baseURL) {
            if let result = (await tryExtractFromBundle(baseURL: baseURL)),
               let sites = result.sites {
                catpawSites = sites
            } else if let sites = (await tryServerConfig(baseURL: baseURL))?.sites {
                catpawSites = sites
            }
        } else if let sites = (await tryServerConfig(baseURL: baseURL))?.sites {
            catpawSites = sites
        }

        // 2. 始终追加内置已知 CMS 源（确保数量充足）
        let builtinSites = buildBuiltinCMSSources()

        // 3. 合并去重（按 key 去重）
        var seen = Set(catpawSites.map { $0.key })
        var allSites = catpawSites
        for site in builtinSites where !seen.contains(site.key) {
            allSites.append(site)
            seen.insert(site.key)
        }

        guard !allSites.isEmpty else { return buildFromSourceCode() }
        return TVBoxConfig(sites: allSites)
    }

    static func isCatPawURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasSuffix(".js.md5") || lower.hasSuffix("/index.js")
    }

    // MARK: - 从打包 JS 中提取 spider meta

    /// 下载打包 JS 源码，正则提取所有 spider 的 meta，生成多站点配置
    private func tryExtractFromBundle(baseURL: String) async -> TVBoxConfig? {
        // 下载打包 JS（处理 .md5 → MD5 → JS 路径）
        guard let jsCode = await fetchBundleCode(jsURL: baseURL) else {
            print("[CatPawConfigBuilder] 下载 JS 源码失败: \(baseURL)")
            return nil
        }

        // 提取所有 meta 对象
        let metas = extractSpiderMetas(from: jsCode)
        guard !metas.isEmpty else {
            print("[CatPawConfigBuilder] 未提取到 spider meta")
            return nil
        }

        print("[CatPawConfigBuilder] 提取到 \(metas.count) 个 spider: \(metas.map { $0.key }.joined(separator: ", "))")

        // 每个 spider 生成一个 Site
        var sites: [Site] = []
        for meta in metas {
            guard let api = knownCMSAPIs[meta.key] else {
                // 未知 CMS 的 spider：标记为 type=3，存储 bundle code 供 JS 引擎执行
                let siteKey = "catpaw_\(meta.key)"
                SpiderContextManager.shared.registerModuleCode(key: siteKey, code: jsCode)
                sites.append(Site(
                    key: siteKey,
                    name: meta.name,
                    type: 3,
                    api: nil,
                    searchable: meta.key == "kkys" ? 1 : 0,
                    quickSearch: 0,
                    spiderKey: meta.key
                ))
                continue
            }

            sites.append(Site(
                key: "catpaw_\(meta.key)",
                name: meta.name,
                type: 1,
                api: api,
                searchable: 1,
                quickSearch: 1,
                filterable: 1,
                categories: knownCategories[meta.key]
            ))
        }

        guard !sites.isEmpty else { return nil }
        return TVBoxConfig(sites: sites)
    }

    // MARK: - JS Bundle 下载

    private func fetchBundleCode(jsURL: String) async -> String? {
        // 方式1：对 .js.md5 → 取 MD5 → 拼 URL {base}/{md5}
        if jsURL.lowercased().hasSuffix(".js.md5"),
           let baseURL = jsURL.components(separatedBy: ".md5").first,
           let md5Data = try? await network.data(from: jsURL),
           let md5 = String(data: md5Data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !md5.isEmpty {
            let constructed = "\(baseURL)/\(md5)"
            print("[CatPawConfigBuilder] 尝试 constructed URL: \(constructed)")
            if let data = try? await network.data(from: constructed),
               let code = String(data: data, encoding: .utf8),
               !code.contains("<html>") {
                print("[CatPawConfigBuilder] constructed 成功 (\(code.count) bytes)")
                return code
            }
        }

        // 方式2：GET index.js，手动提取 Location header 获取 CDN URL
        let jsPath = jsURL.lowercased().hasSuffix(".md5")
            ? (jsURL.components(separatedBy: ".md5").first ?? jsURL)
            : jsURL
        print("[CatPawConfigBuilder] 尝试 GET 重定向跟踪: \(jsPath)")
        if let cdnURL = await self.extractRedirectLocation(from: jsPath),
           let data = try? await network.data(from: cdnURL),
           let code = String(data: data, encoding: .utf8),
           !code.contains("<html>") {
            print("[CatPawConfigBuilder] CDN 获取成功 (\(code.count) bytes)")
            return code
        }

        print("[CatPawConfigBuilder] fetchBundleCode: 所有方式均失败")
        return nil
    }

    /// GET 请求，禁止自动重定向，提取 302 Location header
    private func extractRedirectLocation(from urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let delegate = NoRedirectDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "MyTVBox/1.0 (iOS)"]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            print("[CatPawConfigBuilder] extractRedirect: \(http.statusCode)")
            if let loc = http.value(forHTTPHeaderField: "Location")
                ?? http.value(forHTTPHeaderField: "location") {
                print("[CatPawConfigBuilder] Location: \(loc.prefix(120))")
                return loc
            }
            if let text = String(data: data, encoding: .utf8),
               !text.contains("<html>"), text.count > 500 {
                print("[CatPawConfigBuilder] 无重定向，内容像 JS (\(text.count) bytes)")
                return urlString
            }
            print("[CatPawConfigBuilder] 无 Location，内容非 JS (\(data.count) bytes)")
        } catch {
            print("[CatPawConfigBuilder] extractRedirect error: \(error.localizedDescription)")
        }
        return nil
    }

    /// 禁止自动重定向的 URLSession delegate
    private class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

// MARK: - Spider Meta 提取

    private struct SpiderMeta {
        let key: String
        let name: String
        let type: Int
    }

    /// 主入口：JS 求值提取 → 正则兜底
    private func extractSpiderMetas(from jsCode: String) -> [SpiderMeta] {
        if let jsResults = extractSpiderMetasViaJS(jsCode), !jsResults.isEmpty {
            return jsResults
        }
        return extractSpiderMetasRegex(from: jsCode)
    }

    /// 用正则提取 meta（未混淆格式）
    private func extractSpiderMetasRegex(from jsCode: String) -> [SpiderMeta] {
        let pattern = #"meta\s*:\s*\{[^}]*key\s*:\s*['"]([^'"]+)['"][^}]*name\s*:\s*['"]([^'"]+)['"][^}]*(?:type\s*:\s*(\d+))?[^}]*\}"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(jsCode.startIndex..., in: jsCode)
        let matches = regex.matches(in: jsCode, options: [], range: range)

        var seen = Set<String>()
        var results: [SpiderMeta] = []

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: jsCode),
                  let nameRange = Range(match.range(at: 2), in: jsCode) else { continue }

            // 1.5.3：bundle 里中文站名常写成 '\u63A8\u9001'，
            // 正则抠出来是字面量，必须按 ECMA 规则解成真中文。
            let key = Self.decodeJSLiteral(String(jsCode[keyRange]))
            let name = Self.decodeJSLiteral(String(jsCode[nameRange]))
            let type: Int
            if let typeRange = Range(match.range(at: 3), in: jsCode) {
                type = Int(String(jsCode[typeRange])) ?? 3
            } else {
                type = 3
            }

            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(SpiderMeta(key: key, name: name, type: type))
        }

        return results
    }

    // MARK: - 已知 CMS API 地址映射

    /// CatPawOpen 各 spider 对应的 CMS 标准接口地址
    /// 这些地址来自源码分析和 TVBox 社区，是各 spider 实际请求的后端 API
    private let knownCMSAPIs: [String: String] = [
        "ffm3u8": "https://cj.ffzyapi.com/api.php/provide/vod/from/ffm3u8",
        "ffzy":   "https://cj.ffzyapi.com/api.php/provide/vod",
        "bfzy":   "https://bfzyapi.com/api.php/provide/vod",
        "ikun":   "https://ikunzyapi.com/api.php/provide/vod/from/ikm3u8",
        "360zy":  "https://360zy.com/api.php/provide/vod",
        "hw8":    "https://hw8.live/api.php/provide/vod",
        "jinying":"https://jinyingzy.com/api.php/provide/vod",
        "leshi":  "https://leshiapi.com/api.php/provide/vod",
        "mdzy":   "https://www.mdzyapi.com/api.php/provide/vod",
        "niuniu": "https://api.niuniuzy.me/api.php/provide/vod",
        "okzy":   "https://okzyw9.com/api.php/provide/vod",
        "hongniuzy": "https://www.hongniuzy2.com/api.php/provide/vod",
        "lyd":    "https://api.lydapi.com/api.php/provide/vod",
        "wolongzy": "https://collect.wolongzyw.com/api.php/provide/vod",
        "heimuer": "https://json.heimuer.xyz/api.php/provide/vod",
        "tpzy":   "https://cj.tianpi.top/api.php/provide/vod",
        "dbzy":   "https://www.dbzyapi.com/api.php/provide/vod",
        "jszy":   "https://www.jszyapi.com/api.php/provide/vod",
        "sdzy":   "https://sdzyapi.com/api.php/provide/vod",
        "mozidian": "https://mozidian.com/api.php/provide/vod",
        "hnzy":   "https://hnzyapi.com/api.php/provide/vod",
        "tianying": "https://api.tiany.top/api.php/provide/vod",
        "kbzy":   "https://www.kbzyapi.com/api.php/provide/vod",
        "ckzy":   "https://www.ckzyw.com/api.php/provide/vod",
        "feisu":  "https://www.feisuzyapi.com/api.php/provide/vod",
        "baiwanzy": "https://www.baiwanzy.com/api.php/provide/vod",
        "liangzi": "https://cj.lziapi.com/api.php/provide/vod",
        "tianyi": "https://api.tiany.top/api.php/provide/vod",
        "luobozy": "https://luobozyapi.com/api.php/provide/vod",
        "maozhuatv": "https://www.mzryapi.com/api.php/provide/vod",
        "guangsu": "https://api.guangsuapi.com/api.php/provide/vod",
        "taopian": "https://www.taopianapi.com/api.php/provide/vod",
        "wujin":  "https://api.wujinapi.me/api.php/provide/vod",
        "kuaiche": "https://caiji.kczyapi.com/api.php/provide/vod",
        "mahua":  "https://www.mahuazy.com/api.php/provide/vod",
    ]

    /// 已知分类列表（来自 index.config.js）
    private let knownCategories: [String: [String]] = [
        "ffm3u8": [
            "国产剧", "香港剧", "韩国剧", "欧美剧", "台湾剧", "日本剧",
            "海外剧", "泰国剧", "短剧", "动作片", "喜剧片", "爱情片",
            "科幻片", "恐怖片", "剧情片", "战争片", "动漫片", "大陆综艺",
            "港台综艺", "日韩综艺", "欧美综艺", "国产动漫", "日韩动漫",
            "欧美动漫", "港台动漫", "海外动漫", "记录片",
        ],
    ]

    /// 将所有 knownCMSAPIs 转换为内置 CMS Site 列表
    private func buildBuiltinCMSSources() -> [Site] {
        let allAPIs: [(key: String, name: String, api: String)] = [
            // === 采集站（已验证可用）===
            ("ffm3u8",     "非凡采集",   "https://cj.ffzyapi.com/api.php/provide/vod/from/ffm3u8"),
            ("ffzy",       "非凡资源",   "https://cj.ffzyapi.com/api.php/provide/vod"),
            ("bfzy",       "暴风资源",   "https://bfzyapi.com/api.php/provide/vod"),
            ("ikun",       "IKUN资源",   "https://ikunzyapi.com/api.php/provide/vod/from/ikm3u8"),
            ("360zy",      "360资源",    "https://360zy.com/api.php/provide/vod"),
            ("hw8",        "华为吧资源", "https://hw8.live/api.php/provide/vod"),
            ("jinying",    "金鹰资源",   "https://jinyingzy.com/api.php/provide/vod"),
            ("leshi",      "乐视资源",   "https://leshiapi.com/api.php/provide/vod"),
            ("mdzy",       "墨斗资源",   "https://www.mdzyapi.com/api.php/provide/vod"),
            ("niuniu",     "牛牛资源",   "https://api.niuniuzy.me/api.php/provide/vod"),
            ("okzy",       "OK资源",     "https://okzyw9.com/api.php/provide/vod"),
            ("hongniuzy",  "红牛资源",   "https://www.hongniuzy2.com/api.php/provide/vod"),
            ("lyd",        "闪电资源",   "https://api.lydapi.com/api.php/provide/vod"),
            ("wolongzy",   "卧龙资源",   "https://collect.wolongzyw.com/api.php/provide/vod"),
            ("heimuer",    "黑木耳",     "https://json.heimuer.xyz/api.php/provide/vod"),
            ("tpzy",       "天盘资源",   "https://cj.tianpi.top/api.php/provide/vod"),
            ("dbzy",       "豆瓣资源",   "https://www.dbzyapi.com/api.php/provide/vod"),
            ("jszy",       "极速资源",   "https://www.jszyapi.com/api.php/provide/vod"),
            ("sdzy",       "闪电资源",   "https://sdzyapi.com/api.php/provide/vod"),
            ("hnzy",       "华人资源",   "https://hnzyapi.com/api.php/provide/vod"),
            ("tianying",   "天鹰资源",   "https://api.tiany.top/api.php/provide/vod"),
            ("kbzy",       "快播资源",   "https://www.kbzyapi.com/api.php/provide/vod"),
            ("ckzy",       "超碰资源",   "https://www.ckzyw.com/api.php/provide/vod"),
            ("feisu",      "飞速资源",   "https://www.feisuzyapi.com/api.php/provide/vod"),
            ("baiwanzy",   "百万资源",   "https://www.baiwanzy.com/api.php/provide/vod"),
            ("liangzi",    "量子资源",   "https://cj.lziapi.com/api.php/provide/vod"),
            ("luobozy",    "萝卜资源",   "https://luobozyapi.com/api.php/provide/vod"),
            ("maozhuatv",  "猫抓TV",     "https://www.mzryapi.com/api.php/provide/vod"),
            ("mozidian",   "魔都资源",   "https://mozidian.com/api.php/provide/vod"),
            ("guangsu",    "光速资源",   "https://api.guangsuapi.com/api.php/provide/vod"),
            ("taopian",    "淘片资源",   "https://www.taopianapi.com/api.php/provide/vod"),
            ("wujin",      "无尽资源",   "https://api.wujinapi.me/api.php/provide/vod"),
            ("kuaiche",    "快车资源",   "https://caiji.kczyapi.com/api.php/provide/vod"),
            ("mahua",      "麻花资源",   "https://www.mahuazy.com/api.php/provide/vod"),
        ]

        return allAPIs.map { src in
            Site(
                key: "builtin_\(src.key)",
                name: src.name,
                type: 1,
                api: src.api,
                searchable: 1,
                quickSearch: 1
            )
        }
    }

    // MARK: - 服务端配置获取（CatPaw 服务器运行时）

    private func tryServerConfig(baseURL: String) async -> TVBoxConfig? {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme,
              let host = url.host else { return nil }

        var authPrefix = ""
        if let user = url.user, let password = url.password {
            authPrefix = "\(user):\(password)@"
        }
        let portStr = url.port.map { ":\($0)" } ?? ""
        let configURL = "\(scheme)://\(authPrefix)\(host)\(portStr)/config"

        guard let data = try? await self.network.data(from: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseServerConfig(json)
    }

    private func parseServerConfig(_ json: [String: Any]) -> TVBoxConfig? {
        var allSites: [Site] = []

        if let video = json["video"] as? [String: Any],
           let sites = video["sites"] as? [[String: Any]] {
            for siteJSON in sites {
                if let site = parseCatPawSite(siteJSON) {
                    allSites.append(site)
                }
            }
        }

        guard !allSites.isEmpty else { return nil }
        return TVBoxConfig(sites: allSites)
    }

    private func parseCatPawSite(_ json: [String: Any]) -> Site? {
        guard let key = json["key"] as? String,
              let name = json["name"] as? String else { return nil }

        let type = json["type"] as? Int ?? 3
        let directAPI = knownCMSAPIs[key]

        return Site(
            key: "catpaw_\(key)",
            name: name,
            type: directAPI != nil ? 1 : type,
            api: directAPI,
            searchable: 1,
            quickSearch: 1,
            filterable: 0,
            categories: knownCategories[key]
        )
    }

    /// 用 JavaScriptContext 执行 bundle，提取混淆后的 spider meta
    private func extractSpiderMetasViaJS(_ jsCode: String) -> [SpiderMeta]? {
        let ctx = JSContext()!
        // 1.5.3：猫爪 bundle 多是 webpack / CommonJS 打包，缺这些全局会直接抛异常
        let shim = [
            "var console={log:function(){},warn:function(){},error:function(){},info:function(){},debug:function(){}};",
            "var module={exports:{}}; var exports=module.exports;",
            "var require=function(){return {};};",
            "var window=this; var self=this; var global=this;",
            "var process={env:{},platform:'ios',version:'1.0'};",
            "var Buffer=function(){};",
            "var setTimeout=function(){return 0;}; var clearTimeout=function(){};",
            "var setInterval=function(){return 0;}; var clearInterval=function(){};",
            "var localStorage={getItem:function(){return null;},setItem:function(){},removeItem:function(){}};"
        ].joined(separator: "\n")
        ctx.evaluateScript(shim)
        ctx.evaluateScript(jsCode)

        let pattern = #"meta\s*:\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let fullRange = NSRange(jsCode.startIndex..., in: jsCode)
        let matches = regex.matches(in: jsCode, options: [], range: fullRange)
        guard !matches.isEmpty else { return nil }

        var seen = Set<String>()
        var results: [SpiderMeta] = []

        for match in matches {
            // 1.5.3 修正：旧代码把 `upperBound - lowerBound`（匹配长度）当绝对偏移，
            // 且 NSRange 是 UTF-16 偏移、String.Index 是 Character 偏移，中文 bundle
            // 下必然错位 → JS 求值路径全废 → 永远退回正则 → 名字成了 \uXXXX 字面量。
            guard let mRange = Range(match.range(at: 0), in: jsCode),
                  let snippet = Self.balancedObject(from: jsCode, braceAt: mRange.upperBound),
                  let obj = ctx.evaluateScript("(\(snippet))"),
                  let dict = obj.toObject() as? [String: Any],
                  let key = dict["key"] as? String,
                  let rawName = dict["name"] as? String else { continue }
            let name = Self.decodeJSLiteral(rawName)
            let type = dict["type"] as? Int ?? 3
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(SpiderMeta(key: key, name: name, type: type))
        }

        return results.isEmpty ? nil : results
    }

    /// 从 `meta:{` 之后的 `{` 位置起，按引号 / 转义状态扫描到配对的 `}`，
    /// 返回完整对象字面量（含两侧花括号）。字符串里的花括号不会被误计数。
    private static func balancedObject(from code: String, braceAt upper: String.Index) -> String? {
        guard upper > code.startIndex else { return nil }
        let start = code.index(before: upper)
        guard code[start] == "{" else { return nil }
        var depth = 0
        var quote: Character? = nil
        var escaped = false
        var i = start
        while i < code.endIndex {
            let ch = code[i]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if let q = quote {
                if ch == q { quote = nil }
            } else {
                switch ch {
                case "'", "\"", "`": quote = ch
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(code[start...i]) }
                default: break
                }
            }
            i = code.index(after: i)
        }
        return nil
    }

    /// 解码 JS 字符串字面量：\uXXXX / \u{XXXXX} / \xNN / 代理对 / 常见转义。
    /// 猫爪 bundle 里中文站名大量写成 `'\u63A8\u9001'`，正则抠出来是字面量，
    /// 不解就会在站点列表里显示成一串 \u 码点 —— 1.5.3 修的正是这个。
    static func decodeJSLiteral(_ raw: String) -> String {
        let chars = Array(raw)
        var out = ""
        var pendingHigh: UInt32? = nil

        func flushPending() {
            if let hi = pendingHigh, let sc = Unicode.Scalar(hi) {
                out.unicodeScalars.append(sc)
            }
            pendingHigh = nil
        }

        func push(_ v: UInt32) {
            if let hi = pendingHigh, v >= 0xDC00, v <= 0xDFFF {
                let joined = 0x10000 + ((hi - 0xD800) << 10) + (v - 0xDC00)
                if let sc = Unicode.Scalar(joined) { out.unicodeScalars.append(sc) }
                pendingHigh = nil
                return
            }
            flushPending()
            if v >= 0xD800, v <= 0xDBFF {
                pendingHigh = v
            } else if let sc = Unicode.Scalar(v) {
                out.unicodeScalars.append(sc)
            }
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else {
                flushPending()
                out.append(c)
                i += 1
                continue
            }
            let n = chars[i + 1]
            switch n {
            case "u":
                if i + 2 < chars.count, chars[i + 2] == "{" {
                    var j = i + 3, hex = ""
                    while j < chars.count, chars[j] != "}" {
                        hex.append(chars[j])
                        j += 1
                    }
                    if j < chars.count, let v = UInt32(hex, radix: 16) {
                        push(v); i = j + 1; continue
                    }
                } else if i + 5 < chars.count {
                    let hex = chars[(i + 2)...(i + 5)].reduce("") { $0 + String($1) }
                    if let v = UInt32(hex, radix: 16) {
                        push(v); i += 6; continue
                    }
                }
            case "x":
                if i + 3 < chars.count {
                    let hex = chars[(i + 2)...(i + 3)].reduce("") { $0 + String($1) }
                    if let v = UInt32(hex, radix: 16) {
                        push(v); i += 4; continue
                    }
                }
            case "n": flushPending(); out.append("\n"); i += 2; continue
            case "r": flushPending(); out.append("\r"); i += 2; continue
            case "t": flushPending(); out.append("\t"); i += 2; continue
            case "b": flushPending(); out.append("\u{08}"); i += 2; continue
            case "f": flushPending(); out.append("\u{0C}"); i += 2; continue
            case "v": flushPending(); out.append("\u{0B}"); i += 2; continue
            case "0": flushPending(); out.append("\u{00}"); i += 2; continue
            case "\n": i += 2; continue
            case "\r":
                i += (i + 2 < chars.count && chars[i + 2] == "\n") ? 3 : 2
                continue
            default:
                // \' \" \\ \/ 以及未知 \X：保留字符本身
                flushPending()
                out.append(n)
                i += 2
                continue
            }
            // 上面没识别成功的转义，保守保留反斜杠与字符
            flushPending()
            out.append(c)
            i += 1
        }
        flushPending()
        return out
    }

    // MARK: - 内置已知 CMS 源（fallback）

    private func buildFromSourceCode() -> TVBoxConfig {
        var sites: [Site] = []

        sites.append(Site(
            key: "catpaw_ffm3u8",
            name: "非凡采集",
            type: 1,
            api: "https://cj.ffzyapi.com/api.php/provide/vod/from/ffm3u8",
            searchable: 1,
            quickSearch: 1,
            filterable: 1,
            categories: knownCategories["ffm3u8"]
        ))

        let extraSources: [(key: String, name: String, api: String)] = [
            ("bfzy", "暴风资源", "https://bfzyapi.com/api.php/provide/vod"),
            ("ikun", "IKUN资源", "https://ikunzyapi.com/api.php/provide/vod/from/ikm3u8"),
            ("360zy", "360资源", "https://360zy.com/api.php/provide/vod"),
            ("hw8", "华为吧资源", "https://hw8.live/api.php/provide/vod"),
            ("jinying", "金鹰资源", "https://jinyingzy.com/api.php/provide/vod"),
            ("leshi", "乐视资源", "https://leshiapi.com/api.php/provide/vod"),
            ("mdzy", "墨斗资源", "https://www.mdzyapi.com/api.php/provide/vod"),
            ("niuniu", "牛牛资源", "https://api.niuniuzy.me/api.php/provide/vod"),
            ("okzy", "OK资源", "https://okzyw9.com/api.php/provide/vod"),
        ]

        for src in extraSources {
            sites.append(Site(
                key: "catpaw_\(src.key)",
                name: src.name,
                type: 1,
                api: src.api,
                searchable: 1,
                quickSearch: 1
            ))
        }

        return TVBoxConfig(sites: sites)
    }
}
