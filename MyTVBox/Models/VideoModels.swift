import Foundation

// MARK: - 视频分类

struct VideoCategory: Codable, Identifiable, Hashable, Sendable {
    var id: String { typeId }
    let typeId: String
    let typeName: String
    let typePid: String?

    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
        case typePid = "type_pid"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // type_id 可能是 Int 或 String
        if let s = try? c.decode(String.self, forKey: .typeId) {
            self.typeId = s
        } else if let i = try? c.decode(Int.self, forKey: .typeId) {
            self.typeId = String(i)
        } else {
            self.typeId = ""
        }
        self.typeName = (try? c.decode(String.self, forKey: .typeName)) ?? ""
        if let s = try? c.decodeIfPresent(String.self, forKey: .typePid) {
            self.typePid = s
        } else if let i = try? c.decode(Int.self, forKey: .typePid) {
            self.typePid = String(i)
        } else {
            self.typePid = nil
        }
    }

    init(typeId: String, typeName: String, typePid: String? = nil) {
        self.typeId = typeId
        self.typeName = typeName
        self.typePid = typePid
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeId, forKey: .typeId)
        try c.encode(typeName, forKey: .typeName)
        try c.encodeIfPresent(typePid, forKey: .typePid)
    }
}

// MARK: - 视频列表项

struct VideoItem: Codable, Identifiable, Hashable, Sendable {
    var id: String { vodId }
    let vodId: String
    let vodName: String
    let vodPic: String?
    let vodRemarks: String?
    let vodYear: String?
    let vodArea: String?
    let typeName: String?

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case vodPic = "vod_pic"
        case vodRemarks = "vod_remarks"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case typeName = "type_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .vodId) {
            self.vodId = s
        } else if let i = try? c.decode(Int.self, forKey: .vodId) {
            self.vodId = String(i)
        } else {
            self.vodId = UUID().uuidString
        }
        self.vodName = (try? c.decode(String.self, forKey: .vodName)) ?? ""
        self.vodPic = try? c.decodeIfPresent(String.self, forKey: .vodPic)
        self.vodRemarks = try? c.decodeIfPresent(String.self, forKey: .vodRemarks)
        self.vodYear = try? c.decodeIfPresent(String.self, forKey: .vodYear)
        self.vodArea = try? c.decodeIfPresent(String.self, forKey: .vodArea)
        self.typeName = try? c.decodeIfPresent(String.self, forKey: .typeName)
    }

    init(vodId: String,
         vodName: String,
         vodPic: String? = nil,
         vodRemarks: String? = nil,
         vodYear: String? = nil,
         vodArea: String? = nil,
         typeName: String? = nil) {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodRemarks = vodRemarks
        self.vodYear = vodYear
        self.vodArea = vodArea
        self.typeName = typeName
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vodId, forKey: .vodId)
        try c.encode(vodName, forKey: .vodName)
        try c.encodeIfPresent(vodPic, forKey: .vodPic)
        try c.encodeIfPresent(vodRemarks, forKey: .vodRemarks)
        try c.encodeIfPresent(vodYear, forKey: .vodYear)
        try c.encodeIfPresent(vodArea, forKey: .vodArea)
        try c.encodeIfPresent(typeName, forKey: .typeName)
    }
}

// MARK: - 视频详情

struct VideoDetail: Codable, Identifiable, Hashable, Sendable {
    var id: String { vodId }
    let vodId: String
    let vodName: String
    let vodPic: String?
    let vodContent: String?
    let vodPlayFrom: String?
    let vodPlayUrl: String?
    let vodDirector: String?
    let vodActor: String?
    let vodYear: String?
    let vodArea: String?
    let typeName: String?

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case vodPic = "vod_pic"
        case vodContent = "vod_content"
        case vodPlayFrom = "vod_play_from"
        case vodPlayUrl = "vod_play_url"
        case vodDirector = "vod_director"
        case vodActor = "vod_actor"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case typeName = "type_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .vodId) {
            self.vodId = s
        } else if let i = try? c.decode(Int.self, forKey: .vodId) {
            self.vodId = String(i)
        } else {
            self.vodId = UUID().uuidString
        }
        self.vodName = (try? c.decode(String.self, forKey: .vodName)) ?? ""
        self.vodPic = try? c.decodeIfPresent(String.self, forKey: .vodPic)
        self.vodContent = try? c.decodeIfPresent(String.self, forKey: .vodContent)
        self.vodPlayFrom = try? c.decodeIfPresent(String.self, forKey: .vodPlayFrom)
        self.vodPlayUrl = try? c.decodeIfPresent(String.self, forKey: .vodPlayUrl)
        self.vodDirector = try? c.decodeIfPresent(String.self, forKey: .vodDirector)
        self.vodActor = try? c.decodeIfPresent(String.self, forKey: .vodActor)
        self.vodYear = try? c.decodeIfPresent(String.self, forKey: .vodYear)
        self.vodArea = try? c.decodeIfPresent(String.self, forKey: .vodArea)
        self.typeName = try? c.decodeIfPresent(String.self, forKey: .typeName)
    }

    init(vodId: String,
         vodName: String,
         vodPic: String? = nil,
         vodContent: String? = nil,
         vodPlayFrom: String? = nil,
         vodPlayUrl: String? = nil,
         vodDirector: String? = nil,
         vodActor: String? = nil,
         vodYear: String? = nil,
         vodArea: String? = nil,
         typeName: String? = nil) {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodContent = vodContent
        self.vodPlayFrom = vodPlayFrom
        self.vodPlayUrl = vodPlayUrl
        self.vodDirector = vodDirector
        self.vodActor = vodActor
        self.vodYear = vodYear
        self.vodArea = vodArea
        self.typeName = typeName
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vodId, forKey: .vodId)
        try c.encode(vodName, forKey: .vodName)
        try c.encodeIfPresent(vodPic, forKey: .vodPic)
        try c.encodeIfPresent(vodContent, forKey: .vodContent)
        try c.encodeIfPresent(vodPlayFrom, forKey: .vodPlayFrom)
        try c.encodeIfPresent(vodPlayUrl, forKey: .vodPlayUrl)
        try c.encodeIfPresent(vodDirector, forKey: .vodDirector)
        try c.encodeIfPresent(vodActor, forKey: .vodActor)
        try c.encodeIfPresent(vodYear, forKey: .vodYear)
        try c.encodeIfPresent(vodArea, forKey: .vodArea)
        try c.encodeIfPresent(typeName, forKey: .typeName)
    }

    /// 解析播放来源与剧集 (vod_play_from / vod_play_url 用 $$$ 分隔多源,
    /// 每源内部用 # 分隔多集, 集名与URL用 $ 分隔)
    ///
    /// 重要：同一部片子常有多组线路，其中一组是「网页分享页」（如 `feifan` 的
    /// `https://vip.ffzy-play9.com/share/xxx`），必须经解析器才能播；
    /// 另一组才是 m3u8 直链（`ffm3u8`）。原实现按顺序取第 0 组，导致把 HTML
    /// 交给 AVPlayer 而报 "Cannot Open"。这里按「能否直连播放」重新排序。
    func parsePlaySources() -> [PlaySource] {
        guard let from = vodPlayFrom, let urls = vodPlayUrl else { return [] }
        let fromList = from.components(separatedBy: "$$$")
        let urlList = urls.components(separatedBy: "$$$")
        var result: [PlaySource] = []
        for (idx, name) in fromList.enumerated() {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            guard idx < urlList.count else { break }
            let episodes = urlList[idx]
                .components(separatedBy: "#")
                .compactMap { seg -> PlayURL? in
                    let parts = seg.components(separatedBy: "$")
                    guard parts.count >= 2 else {
                        if parts.count == 1, !parts[0].isEmpty {
                            return PlayURL(name: "默认", url: parts[0])
                        }
                        return nil
                    }
                    let n = parts[0].trimmingCharacters(in: .whitespaces)
                    let u = parts[1...].joined(separator: "$")
                    return PlayURL(name: n.isEmpty ? "默认" : n, url: u)
                }
            if !episodes.isEmpty {
                result.append(PlaySource(name: trimmedName, episodes: episodes))
            }
        }
        // 稳定排序：可直连播放的线路优先，其余（网页/需解析）降级到后面
        return result.enumerated()
            .sorted { a, b in
                let sa = PlayURL.mediaScore(a.element, sourceName: a.element.name)
                let sb = PlayURL.mediaScore(b.element, sourceName: b.element.name)
                if sa != sb { return sa > sb }
                return a.offset < b.offset
            }
            .map { $0.element }
    }
}

// MARK: - 直链判定

extension PlayURL {
    /// 地址看起来能否被 AVPlayer 直接播放（m3u8 / mp4 / flv / ts / mpd）
    static func isDirectPlayable(url: String) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            return lower.hasPrefix("file://")
        }
        // 去掉 query 后看路径后缀
        let path = lower.components(separatedBy: "?").first ?? lower
        let mediaExts = [".m3u8", ".mp4", ".m4v", ".mov", ".flv", ".ts", ".mpd", ".mkv"]
        if mediaExts.contains(where: { path.hasSuffix($0) || path.contains($0 + "?") }) {
            return true
        }
        // 路径里带 m3u8 但不在结尾（如 /xxx.m3u8/token/...）也算
        if path.contains(".m3u8") || path.contains("/hls/") { return true }
        // 明确的网页分享页
        if path.contains("/share/") || path.contains("/play/") && !path.contains(".m3u8") {
            return false
        }
        return false
    }

    /// 1.6.0：可交给 `loadAndPlay` 的候选地址。
    /// 除直链外，`mddcloud://play` / `mytvboxnode://play` 这类占位 scheme
    /// 会在播放前换成真实 m3u8。若不把它们算作候选，`firstPlayableSourceIndex`
    /// 和自动换源会把整组线路全部跳过，导致取流失败后直接跨站。
    static func isPlayableCandidate(url: String) -> Bool {
        if isDirectPlayable(url: url) { return true }
        let lower = url.lowercased()
        return lower.hasPrefix("mddcloud://play") || lower.hasPrefix("mytvboxnode://play")
    }

    /// 线路打分：越高越该排在前面
    static func mediaScore(_ source: PlaySource, sourceName: String) -> Int {
        let nameLower = sourceName.lowercased()
        var score = 0
        // 线路名本身带 m3u8，通常就是直链线路
        if nameLower.contains("m3u8") { score += 4 }
        if nameLower.contains("mp4") { score += 3 }
        // 抽前几集判断实际地址形态
        let sample = source.episodes.prefix(3)
        let playable = sample.filter { isDirectPlayable(url: $0.url) }.count
        if playable == sample.count && playable > 0 {
            score += 6
        } else if playable > 0 {
            score += 2
        }
        return score
    }
}

// MARK: - API 响应包装

struct APIResponse: Codable {
    let code: Int?
    let msg: String?
    let page: Int?
    let pagecount: Int?
    let limit: Int?
    let total: Int?
    let list: [VideoItem]?
    /// 分类列表 (JSON 字段名为 "class")
    let categories: [VideoCategory]?

    enum CodingKeys: String, CodingKey {
        case code, msg, page, pagecount, limit, total, list
        case categories = "class"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = APIResponse.decodeIntOrString(c, key: .code)
        self.msg = try c.decodeIfPresent(String.self, forKey: .msg)
        self.page = APIResponse.decodeIntOrString(c, key: .page)
        self.pagecount = APIResponse.decodeIntOrString(c, key: .pagecount)
        self.limit = APIResponse.decodeIntOrString(c, key: .limit)
        self.total = APIResponse.decodeIntOrString(c, key: .total)
        self.list = try c.decodeIfPresent([VideoItem].self, forKey: .list)
        self.categories = try c.decodeIfPresent([VideoCategory].self, forKey: .categories)
    }

    init(code: Int? = nil, msg: String? = nil, page: Int? = nil,
         pagecount: Int? = nil, limit: Int? = nil, total: Int? = nil,
         list: [VideoItem]? = nil, categories: [VideoCategory]? = nil) {
        self.code = code
        self.msg = msg
        self.page = page
        self.pagecount = pagecount
        self.limit = limit
        self.total = total
        self.list = list
        self.categories = categories
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(msg, forKey: .msg)
        try c.encodeIfPresent(page, forKey: .page)
        try c.encodeIfPresent(pagecount, forKey: .pagecount)
        try c.encodeIfPresent(limit, forKey: .limit)
        try c.encodeIfPresent(total, forKey: .total)
        try c.encodeIfPresent(list, forKey: .list)
        try c.encodeIfPresent(categories, forKey: .categories)
    }

    private static func decodeIntOrString(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }
}

struct VideoDetailResponse: Codable {
    let code: Int?
    let msg: String?
    let list: [VideoDetail]?
}

// MARK: - 解析后的播放信息

struct PlayURL: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let url: String
}

struct PlaySource: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let episodes: [PlayURL]
    /// 跨站线路的来源站点名（本站线路为 nil）
    var siteName: String?
    /// 跨站线路的来源站点 key（本站线路为 nil）
    var siteKey: String?

    init(name: String, episodes: [PlayURL], siteName: String? = nil, siteKey: String? = nil) {
        self.name = name
        self.episodes = episodes
        self.siteName = siteName
        self.siteKey = siteKey
    }

    /// 是否来自其它站点（详情页会把它和本站线路分开显示）
    var isCrossSite: Bool { siteName != nil }
}
