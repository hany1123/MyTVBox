import Foundation

/// 多仓配置里的一个子仓库（urls / storeHouse 条目）
struct RepoLink: Identifiable, Hashable, Sendable {
    var id: String { url }
    let name: String
    let url: String
}

/// TVBox / 猫爪 顶层配置模型
struct TVBoxConfig: Codable {
    let spider: String?
    let sites: [Site]?
    let lives: [LiveSource]?
    let parses: [ParseRule]?
    let flags: [String]?
    /// ijk 配置以原始结构保存
    let ijk: [AnyCodable]?
    /// 多仓：该配置指向的子仓库列表（urls / storeHouse）
    let repos: [RepoLink]?

    enum CodingKeys: String, CodingKey {
        case spider, sites, lives, parses, flags, ijk
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.spider = try c.decodeIfPresent(String.self, forKey: .spider)
        self.sites = try c.decodeIfPresent([Site].self, forKey: .sites)
        self.lives = try c.decodeIfPresent([LiveSource].self, forKey: .lives)
        self.parses = try c.decodeIfPresent([ParseRule].self, forKey: .parses)
        self.flags = try c.decodeIfPresent([String].self, forKey: .flags)
        self.ijk = try c.decodeIfPresent([AnyCodable].self, forKey: .ijk)
        self.repos = nil
    }

    /// 便捷成员初始化器（用于代码构建配置实例）
    init(spider: String? = nil, sites: [Site]? = nil, lives: [LiveSource]? = nil,
         parses: [ParseRule]? = nil, flags: [String]? = nil, ijk: [AnyCodable]? = nil,
         repos: [RepoLink]? = nil) {
        self.spider = spider
        self.sites = sites
        self.lives = lives
        self.parses = parses
        self.flags = flags
        self.ijk = ijk
        self.repos = repos
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(spider, forKey: .spider)
        try c.encodeIfPresent(sites, forKey: .sites)
        try c.encodeIfPresent(lives, forKey: .lives)
        try c.encodeIfPresent(parses, forKey: .parses)
        try c.encodeIfPresent(flags, forKey: .flags)
        try c.encodeIfPresent(ijk, forKey: .ijk)
    }
}

/// 解析规则（JSON 解析 / 嗅探 / 默认 等）
struct ParseRule: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    /// 0 = 默认嗅探, 1 = JSON 解析, 2 = JSON 扩展
    let type: Int?
    let url: String?
    let ext: AnyCodable?
    /// 1.5.1：线路标识（CMS 的 vod_play_from / TVBox 的 flag）→ 该解析器负责的线路。
    /// 支持 `play_keys` / `play_key` / `playKey`，数组或逗号分隔字符串；
    /// 兼容把配置放在 `ext.play_key` 里的写法。标准客户端不认识这些字段会直接忽略。
    let playKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case name, type, url, ext
        case playKeys = "play_keys"
        case playKeySingular = "play_key"
        case playKeyCamel = "playKey"
    }

    init(name: String, type: Int? = nil, url: String? = nil,
         ext: AnyCodable? = nil, playKeys: [String]? = nil) {
        self.name = name
        self.type = type
        self.url = url
        self.ext = ext
        self.playKeys = playKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decodeIfPresent(Int.self, forKey: .type)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.ext = try c.decodeIfPresent(AnyCodable.self, forKey: .ext)

        var keys: [String] = []
        func append(_ s: String) {
            keys += s.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for k in [CodingKeys.playKeys, .playKeySingular, .playKeyCamel] {
            if let arr = try? c.decode([String].self, forKey: k) {
                keys += arr
            } else if let s = try? c.decode(String.self, forKey: k) {
                append(s)
            }
        }
        if let e = ext?.value as? [String: Any] {
            if let s = e["play_key"] as? String { append(s) }
            else if let arr = e["play_key"] as? [String] { keys += arr }
            else if let arr = e["play_keys"] as? [String] { keys += arr }
        }
        var unique: [String] = []
        var seen = Set<String>()
        for k in keys where !k.isEmpty && seen.insert(k).inserted { unique.append(k) }
        self.playKeys = unique.isEmpty ? nil : unique
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(ext, forKey: .ext)
        try c.encodeIfPresent(playKeys, forKey: .playKeys)
    }

    static func == (lhs: ParseRule, rhs: ParseRule) -> Bool {
        lhs.name == rhs.name && lhs.url == rhs.url && lhs.type == rhs.type
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(url)
    }

    /// 该规则是否声明负责这条线路
    func matches(flag: String) -> Bool {
        guard let playKeys else { return false }
        let f = flag.lowercased()
        return playKeys.contains { $0.lowercased() == f }
    }
}
