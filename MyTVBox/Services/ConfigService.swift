import Foundation

/// 配置下载与解析服务
final class ConfigService {
    static let shared = ConfigService()

    private let network = NetworkManager.shared

    private init() {}

    /// 从给定 URL 下载并解析 TVBox / 猫爪 JSON 配置
    /// - 支持 .md5 后缀（先尝试直接获取，若返回内容是 32 位 md5 则去掉 .md5 重新请求）
    /// - 支持 URL 内嵌 Basic Auth: http://user:pass@host/path
    /// - 支持 CatPaw Spider 模块 URL（自动尝试常见配置路径）
    /// - 支持 base64 编码的 JSON 配置
    func loadConfig(from urlString: String) async throws -> TVBoxConfig {
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
    /// 解析配置并滤掉 iOS 无法执行的站点（type 3 = JAR 爬虫，需要 JVM）
    private func decodeWithExtras(_ data: Data) throws -> TVBoxConfig {
        let cfg = try _decodeWithExtras(data)
        let usable = (cfg.sites ?? []).filter { [0, 1, 4].contains($0.type) }
        return TVBoxConfig(spider: cfg.spider, sites: usable, lives: cfg.lives,
                           parses: cfg.parses, flags: cfg.flags, ijk: cfg.ijk)
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
        guard let url = URL(string: baseURL),
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
