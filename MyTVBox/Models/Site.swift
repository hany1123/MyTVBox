import Foundation

/// 资源站点配置
struct Site: Codable, Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    /// 0 = XPath, 1 = JSON API (CMS标准接口), 3 = Spider (jar/js)
    let type: Int
    let api: String?
    /// 1 = 可搜索
    let searchable: Int?
    /// 1 = 支持快速搜索
    let quickSearch: Int?
    /// 1 = 可筛选
    let filterable: Int?
    /// 播放器类型：0 系统, 1 IJK, 2 Exo
    let playerType: Int?
    /// 扩展配置（JSON / URL / 字符串）
    let ext: String?
    /// 站点支持的分类 ID 列表（用于过滤）
    let categories: [String]?
    /// jar 包地址（spider 站点用）
    let jar: String?
    /// CatPaw bundle 中的原始 spider key（type=3 站点路由用）
    let spiderKey: String?

    enum CodingKeys: String, CodingKey {
        case key, name, type, api
        case searchable, quickSearch, filterable, playerType
        case ext, categories, jar, spiderKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // key / name：优先 String，兜底 Int→String
        self.key = c.decodeStringFlexible(.key) ?? "unknown"
        self.name = c.decodeStringFlexible(.name) ?? "未命名"
        // 所有数字字段使用宽松解码（兼容 Int / String / Double）
        self.type = c.decodeIntFlexible(.type) ?? 1
        self.api = try? c.decodeIfPresent(String.self, forKey: .api)
        self.searchable = c.decodeIntFlexible(.searchable)
        self.quickSearch = c.decodeIntFlexible(.quickSearch)
        self.filterable = c.decodeIntFlexible(.filterable)
        self.playerType = c.decodeIntFlexible(.playerType)
        self.categories = try? c.decodeIfPresent([String].self, forKey: .categories)
        self.jar = try? c.decodeIfPresent(String.self, forKey: .jar)
        self.spiderKey = try? c.decodeIfPresent(String.self, forKey: .spiderKey)

        // ext 可能是字符串、对象或数组，统一转字符串方便存储
        if let s = try? c.decodeIfPresent(String.self, forKey: .ext) {
            self.ext = s
        } else if let any = try? c.decodeIfPresent(AnyCodable.self, forKey: .ext) {
            if let data = try? JSONSerialization.data(withJSONObject: any.value, options: []),
               let s = String(data: data, encoding: .utf8) {
                self.ext = s
            } else {
                self.ext = nil
            }
        } else {
            self.ext = nil
        }
    }

    /// 便捷成员初始化器（用于代码构建 Site 实例）
    init(key: String, name: String, type: Int = 1, api: String? = nil,
         searchable: Int? = nil, quickSearch: Int? = nil, filterable: Int? = nil,
         playerType: Int? = nil, ext: String? = nil,
         categories: [String]? = nil, jar: String? = nil,
         spiderKey: String? = nil) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.searchable = searchable
        self.quickSearch = quickSearch
        self.filterable = filterable
        self.playerType = playerType
        self.ext = ext
        self.categories = categories
        self.jar = jar
        self.spiderKey = spiderKey
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(api, forKey: .api)
        try c.encodeIfPresent(searchable, forKey: .searchable)
        try c.encodeIfPresent(quickSearch, forKey: .quickSearch)
        try c.encodeIfPresent(filterable, forKey: .filterable)
        try c.encodeIfPresent(playerType, forKey: .playerType)
        try c.encodeIfPresent(ext, forKey: .ext)
        try c.encodeIfPresent(categories, forKey: .categories)
        try c.encodeIfPresent(jar, forKey: .jar)
        try c.encodeIfPresent(spiderKey, forKey: .spiderKey)
    }

    var isSearchable: Bool { (searchable ?? 0) == 1 }
    var isFilterable: Bool { (filterable ?? 0) == 1 }

    /// 复制一份并替换 key。
    ///
    /// 1.4.9 起支持「同时启用多个订阅源」：各源的站点会合并成一个池子，
    /// 不同源可能有同名 key（csp_xxx / 数字 key 都很常见），
    /// 合并时用订阅名做前缀重写，保证 key 在池内唯一。
    func replacingKey(_ newKey: String) -> Site {
        Site(key: newKey, name: name, type: type, api: api,
             searchable: searchable, quickSearch: quickSearch, filterable: filterable,
             playerType: playerType, ext: ext, categories: categories,
             jar: jar, spiderKey: spiderKey)
    }
}
