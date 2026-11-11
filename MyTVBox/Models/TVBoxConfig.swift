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

    enum CodingKeys: String, CodingKey {
        case name, type, url, ext
    }

    static func == (lhs: ParseRule, rhs: ParseRule) -> Bool {
        lhs.name == rhs.name && lhs.url == rhs.url && lhs.type == rhs.type
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(url)
    }
}
