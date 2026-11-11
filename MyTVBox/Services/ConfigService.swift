import Foundation

/// 配置下载与解析服务
final class ConfigService {
    static let shared = ConfigService()

    /// 最近一次解析的站点统计（用于向用户解释「为什么站点很少」）
    struct ConfigStats: Sendable {
        var totalSites: Int = 0
        var usableSites: Int = 0
        var droppedJarSites: Int = 0
        var lives: Int = 0
    }

    /// 最近一次 `loadConfig` 的诊断结果；调用方在 await 之后读取
    private(set) var lastStats: ConfigStats?
    /// 最近一次解析到的多仓列表（供界面切换仓库）
    private(set) var lastRepos: [RepoLink] = []

    private let network = NetworkManager.shared

    /// 1.4.9：允许多实例。
    /// 合并多个订阅源时会并发加载各源，`lastStats` / `lastRepos` 是实例级状态，
    /// 共用单例会导致诊断数据互相覆盖，故并发场景各用各的实例。
    init() {}

    /// 从给定 URL 下载并解析 TVBox / 猫爪 JSON 配置
    /// - 支持 .md5 后缀（先尝试直接获取，若返回内容是 32 位 md5 则去掉 .md5 重新请求）
    /// - 支持 URL 内嵌 Basic Auth: http://user:pass@host/path
    /// - 支持 CatPaw Spider 模块 URL（自动尝试常见配置路径）
    /// - 支持 base64 编码的 JSON 配置
    func loadConfig(from urlString: String) async throws -> TVBoxConfig {
        lastStats = nil
        lastRepos = []
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NetworkError.invalidURL }

        // CatPaw .js.md5 URL → 直接交给 CatPawConfigBuilder（避免重复下载）
        if CatPawConfigBuilder.isCatPawURL(trimmed) {
            do {
                return try await CatPawConfigBuilder.shared.buildConfig(baseURL: trimmed)
            } catch {
                // 构建失败则继续下面的标准流程
            }
        }

        // 第一步：尝试直接请求
        let primaryData: Data
        do {
            primaryData = try await network.data(from: trimmed)
        } catch {
            // 如果是 .md5 URL 请求失败，尝试去掉 .md5
            if trimmed.lowercased().hasSuffix(".md5") {
                let noMD5 = String(trimmed.dropLast(4))
                do {
                    let data = try await network.data(from: noMD5)
                    if let cfg = try? decodeWithExtras(data) {
                        return cfg
                    }
                } catch {}
                // CatPaw .md5 URL → 使用源码配置生成器
                if CatPawConfigBuilder.isCatPawURL(trimmed) {
                    return try await CatPawConfigBuilder.shared.buildConfig(baseURL: trimmed)
                }
            }
            throw error
        }

        // 尝试直接解析
        if let cfg = try? decodeWithExtras(primaryData) {
            let repos = cfg.repos ?? []
            // 多仓配置：本身没站点，自动展开第一个可用子仓（支持多仓套多仓）。
            // 展开后仍把「顶层仓库列表」挂回去，界面才能切换其它仓库。
            if (cfg.sites ?? []).isEmpty, !repos.isEmpty,
               let resolved = await resolveFirstUsableRepo(repos, depth: 0) {
                lastRepos = repos
                return TVBoxConfig(spider: resolved.spider, sites: resolved.sites,
                                   lives: resolved.lives, parses: resolved.parses,
                                   flags: resolved.flags, ijk: resolved.ijk,
                                   repos: repos)
            }
            return cfg
        }

        // 第二步：检查是否是纯 md5 字符串
        if let text = String(data: primaryData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isMD5Hash(text), trimmed.lowercased().hasSuffix(".md5") {
            // 去掉 .md5 重新请求
            let realURL = String(trimmed.dropLast(4))
            do {
                let realData = try await network.data(from: realURL)
                if let cfg = try? decodeWithExtras(realData) {
                    return cfg
                }
                // 尝试同域名的常见配置路径
                if let cfg = await tryAlternativePaths(baseURL: trimmed) {
                    return cfg
                }
                // 检测 Spider 模块 → 尝试 CatPaw 配置生成器
                if looksLikeSpiderModule(realData) {
                    if CatPawConfigBuilder.isCatPawURL(trimmed) {
                        return try await CatPawConfigBuilder.shared.buildConfig(baseURL: trimmed)
                    }
                    throw NetworkError.spiderModuleNotSupported
                }
            } catch let error as NetworkError where error == .spiderModuleNotSupported {
                throw error
            } catch {
                // 去掉 .md5 的请求也失败了
            }
        }

        // 第三步：若 url 以 .md5 结尾但内容不是 md5，也尝试去掉后缀
        if trimmed.lowercased().hasSuffix(".md5") {
            let realURL = String(trimmed.dropLast(4))
            do {
                let realData = try await network.data(from: realURL)
                if let cfg = try? decodeWithExtras(realData) {
                    return cfg
                }
                if looksLikeSpiderModule(realData) {
                    if CatPawConfigBuilder.isCatPawURL(trimmed) {
                        return try await CatPawConfigBuilder.shared.buildConfig(baseURL: trimmed)
                    }
                    throw NetworkError.spiderModuleNotSupported
                }
            } catch let error as NetworkError where error == .spiderModuleNotSupported {
                throw error
            } catch {}
        }

        // 第四步：尝试同域名的常见配置路径（适用于 Spider 模块 URL）
        if let cfg = await tryAlternativePaths(baseURL: trimmed) {
            return cfg
        }

        // 第五步：检测 Spider 模块 → 尝试 CatPaw 配置生成器
        if looksLikeSpiderModule(primaryData) {
            if CatPawConfigBuilder.isCatPawURL(trimmed) {
                return try await CatPawConfigBuilder.shared.buildConfig(baseURL: trimmed)
            }
            throw NetworkError.spiderModuleNotSupported
        }

        // 兜底：再次解析（抛出真实错误）
        return try decodeWithExtras(primaryData)
    }

    // MARK: - 解码增强

    /// 解码 JSON，支持 base64 编码兜底 + 数组格式 [{api,name}] 兼容
    /// 1.5.1：JAR 型 type=3 仍不可用，但已实现原生客户端的内置 mddcloud
    /// 站点（api 前缀 mytvbox://mddcloud）会放行。
    /// 1.5.4：带 bundle / spiderKey 的 **JS Spider** 站点也放行；
    /// 带 jar 字段的 Java 站点继续挡，避免 123 个跑不了的站涌进列表。
    private func decodeWithExtras(_ data: Data) throws -> TVBoxConfig {
        let cfg = try _decodeWithExtras(data)
        let repos = Self.extractRepos(from: data)
        lastRepos = repos
        let all = cfg.sites ?? []
        let usable = all.filter { site in
            if [0, 1, 4].contains(site.type) { return true }
            guard site.type == 3 else { return false }
            if MddCloudService.isMddSite(site) { return true }
            if site.jar == nil,
               site.spiderKey != nil || SpiderEngine.isSpiderSite(site) {
                return true
            }
            return false
        }
        lastStats = ConfigStats(
            totalSites: all.count,
            usableSites: usable.count,
            droppedJarSites: all.count - usable.count,
            lives: cfg.lives?.count ?? 0
        )
        return TVBoxConfig(spider: cfg.spider, sites: usable, lives: cfg.lives,
                           parses: cfg.parses, flags: cfg.flags, ijk: cfg.ijk,
                           repos: repos)
    }

    // MARK: - 多仓

    /// 解析多仓字段。TVBox 生态里字段名不统一：
    /// `urls` / `storeHouse` / `repos` / `subs`，条目可能是字符串、
    /// `{name,url}`、`{sourceName,sourceUrl}`，url 还可能是数组。
    static func extractRepos(from data: Data) -> [RepoLink] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var out: [RepoLink] = []
        for key in ["urls", "storeHouse", "storehouse", "repos", "subs", "list"] {
            guard let arr = obj[key] as? [Any] else { continue }
            for item in arr {
                if let s = item as? String, s.hasPrefix("http") {
                    out.append(RepoLink(name: (s as NSString).lastPathComponent, url: s))
                    continue
                }
                guard let d = item as? [String: Any] else { continue }
                let name = (d["name"] as? String)
                    ?? (d["sourceName"] as? String)
                    ?? (d["sourcename"] as? String) ?? "仓库"
                var candidates: [String] = []
                for k in ["url", "sourceUrl", "sourceurl"] {
                    if let s = d[k] as? String { candidates.append(s) }
                    if let list = d[k] as? [String] { candidates += list }
                }
                for u in candidates where u.hasPrefix("http") {
                    out.append(RepoLink(name: name, url: u))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.url).inserted }
    }

    /// 多仓自动展开：按顺序找第一个真正含站点的子仓，最多递归 3 层
    private func resolveFirstUsableRepo(_ repos: [RepoLink], depth: Int) async -> TVBoxConfig? {
        guard depth < 3 else { return nil }
        for repo in repos.prefix(12) {
            guard let data = try? await network.data(from: repo.url) else { continue }
            guard let cfg = try? decodeWithExtras(data) else { continue }
            let rawTotal = lastStats?.totalSites ?? 0
            // 有可用站点就采用；全是 JAR 也返回，让上层给出明确提示而不是空白
            if !(cfg.sites ?? []).isEmpty || rawTotal > 0 {
                return cfg
            }
            let sub = lastRepos   // decodeWithExtras 刚写入的子仓
            if !sub.isEmpty, let found = await resolveFirstUsableRepo(sub, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// 用户手动切换仓库：直接加载该仓库地址（若又是多仓则继续展开）
    func loadRepoConfig(from url: String) async throws -> TVBoxConfig {
        lastStats = nil
        lastRepos = []
        let data = try await network.data(from: url)
        let cfg = try decodeWithExtras(data)
        let repos = cfg.repos ?? []
        if (cfg.sites ?? []).isEmpty, !repos.isEmpty,
           let resolved = await resolveFirstUsableRepo(repos, depth: 0) {
            lastRepos = repos
            return TVBoxConfig(spider: resolved.spider, sites: resolved.sites,
                               lives: resolved.lives, parses: resolved.parses,
                               flags: resolved.flags, ijk: resolved.ijk,
                               repos: repos)
        }
        return cfg
    }

    private func _decodeWithExtras(_ data: Data) throws -> TVBoxConfig {
        // 1. 直接 JSON 解码（标准 TVBox 对象格式）
        if let cfg = try? network.decodeJSON(TVBoxConfig.self, data: data) {
            return cfg
        }

        // 2. 尝试数组格式：[{api, name}, ...] → 转换为 CMS 站点列表
        if let cfg = try? decodeArrayFormat(data) {
            return cfg
        }

        // 2.5 `$#` 加密配置（十六进制 + AES-128-CBC，部分接口在用）
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           ConfigDecryptor.isEncrypted(text),
           let plain = ConfigDecryptor.decrypt(text),
           let cfg = try? network.decodeJSON(TVBoxConfig.self, data: plain) {
            return cfg
        }

        // 3. 尝试 base64 解码后再解析
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: text) {
            if let cfg = try? network.decodeJSON(TVBoxConfig.self, data: decoded) {
                return cfg
            }
            // base64 解码后也尝试数组格式
            if let cfg = try? decodeArrayFormat(decoded) {
                return cfg
            }
        }

        // 4. 尝试提取内嵌 JSON（有时 JSON 被包裹在 JS 变量赋值中）
        if let text = String(data: data, encoding: .utf8),
           let json = extractJSONFromText(text) {
            if let cfg = try? network.decodeJSON(TVBoxConfig.self, data: json) {
                return cfg
            }
            if let cfg = try? decodeArrayFormat(json) {
                return cfg
            }
        }

        throw NetworkError.decodingFailed("未能读取数据，因为它的格式不正确")
    }

    /// 解码数组格式的视频源列表：[{api: "...", name: "..."}, ...]
    /// 常见于 uzVideo 等第三方源，将每个条目转为 type=1 的 CMS 站点
    private func decodeArrayFormat(_ data: Data) throws -> TVBoxConfig {
        struct SimpleSource: Decodable {
            let api: String
            let name: String
        }
        let sources = try JSONDecoder().decode([SimpleSource].self, from: data)
        guard !sources.isEmpty else {
            throw NetworkError.decodingFailed("空的源列表")
        }
        let sites = sources.map { src -> Site in
            Site(key: src.name, name: src.name, type: 1, api: src.api,
                 searchable: 1, quickSearch: 1)
        }
        return TVBoxConfig(sites: sites)
    }

    /// 从文本中提取 JSON 对象（处理 `var config = {...}` 或 `{...}` 被包裹的情况）
    private func extractJSONFromText(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 尝试找最外层的 { ... } 对
        guard let start = trimmed.firstIndex(of: "{") else { return nil }

        // 从最后一个 } 往前找
        guard let lastBrace = trimmed.lastIndex(of: "}") else { return nil }
        guard lastBrace > start else { return nil }

        let candidate = String(trimmed[start...lastBrace])
        return candidate.data(using: .utf8)
    }

    // MARK: - Spider 模块检测

    /// 检查 Data 是否看起来像 Spider 模块（JS 代码而非 JSON 配置）
    private func looksLikeSpiderModule(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // JS 模块通常包含这些特征
        let jsPatterns = [
            "require(",
            "module.exports",
            "export default",
            "export async function",
            "const { parentPort }",
            "fastify",
            "function start(",
            "function stop(",
        ]

        // 如果文本很大（>10KB）且包含 JS 特征，基本可以确认是 Spider 模块
        if trimmed.count > 10_000 {
            for pattern in jsPatterns {
                if trimmed.contains(pattern) { return true }
            }
        }

        // 小文件也检查，但需要更多证据
        let matchCount = jsPatterns.filter { trimmed.contains($0) }.count
        return matchCount >= 3
    }

    // MARK: - 替代路径尝试

    /// 从同一域名的常见配置路径尝试获取 JSON 配置
    private func tryAlternativePaths(baseURL: String) async -> TVBoxConfig? {
        guard let url = URLNormalizer.url(baseURL),
              let scheme = url.scheme,
              let host = url.host else { return nil }

        // 构建基础 URL（含认证信息）
        var authPrefix = ""
        if let user = url.user, let password = url.password {
            authPrefix = "\(user):\(password)@"
        }
        let portStr = url.port.map { ":\($0)" } ?? ""
        let base = "\(scheme)://\(authPrefix)\(host)\(portStr)"

        // 常见的 TVBox 配置文件路径
        let paths = [
            "/config.json",
            "/tvbox.json",
            "/config",
            "/api/config",
            "/index.json",
            "/tv.json",
        ]

        for path in paths {
            let tryURL = base + path
            if let data = try? await network.data(from: tryURL),
               let cfg = try? decodeWithExtras(data) {
                return cfg
            }
        }

        return nil
    }

    // MARK: - 工具

    private func decode(_ data: Data) throws -> TVBoxConfig {
        return try network.decodeJSON(TVBoxConfig.self, data: data)
    }

    private func isMD5Hash(_ s: String) -> Bool {
        guard s.count == 32 else { return false }
        let hexSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return s.unicodeScalars.allSatisfy { hexSet.contains($0) }
    }
}
