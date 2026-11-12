import Foundation

// MARK: - 跨站点搜索 / 站点级自动换源
//
// 1.4.7：1.4.6 只做到「同一部片内多线路切换」。这里补上两层：
//   · 搜索：并发查询当前配置里所有可用 CMS 站点，结果携带站点归属
//   · 播放：所有线路耗尽时，拿片名去其它站点找同名片的直链线路续播
//
// 设计约束：
//   · 只处理 type != 3 的 CMS 站点（JAR / Spider 在 iOS 不可执行）
//   · 每个请求都带 6 秒超时，避免一个慢站拖住整轮聚合
//   · 站点间同名片不去重 —— 它们正是自动换源的候选池

enum CrossSiteResolver {

    /// 带站点归属的搜索结果。id 必须含 site.key，否则跨站点会撞 ID。
    struct SiteSearchResult: Identifiable, Hashable, @unchecked Sendable {
        var id: String { "\(site.key)#\(item.vodId)" }
        let item: VideoItem
        let site: Site
        /// 2 = 标题完全一致，1 = 包含匹配，0 = 其它
        let relevance: Int
        let order: Int
        var siteName: String { site.name }
    }

    /// 站点级换源成功后，播放器要整体替换的上下文
    struct CrossSitePlayable: @unchecked Sendable {
        let detail: VideoDetail
        let sources: [PlaySource]
        let sourceIndex: Int
        let episodeIndex: Int
        let seekTo: Double
        let siteKey: String
        let siteName: String
    }

    private struct Candidate: @unchecked Sendable {
        let index: Int
        let playable: CrossSitePlayable?
    }

    private struct Batch: @unchecked Sendable {
        let index: Int
        let site: Site
        let items: [VideoItem]
    }

    // MARK: - 站点筛选

    /// 可用于 CMS 搜索的站点：排除 JAR 型、无 http api、显式标注不可搜索的站点
    static func usableSites(_ sites: [Site]) -> [Site] {
        var seen = Set<String>()
        return sites.filter { site in
            guard site.type != 3,
                  let api = site.api,
                  api.lowercased().hasPrefix("http"),
                  site.searchable != 0 else { return false }
            return seen.insert(site.key).inserted
        }
    }

    // MARK: - 标题归一化 / 匹配

    /// 去掉括号内容、季数、清晰度标记与所有标点空白，只留字母/数字/汉字
    static func normalizedTitle(_ raw: String) -> String {
        var s = raw.lowercased()
        s = s.replacingOccurrences(
            of: "\\([^)]*\\)|（[^）]*）|\\[[^\\]]*\\]|【[^】]*】",
            with: "", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "第[0-9一二三四五六七八九十]+季",
            with: "", options: .regularExpression
        )
        // 1.7.4：站点标题普遍带进度尾巴，不剥掉就永远判不成「完全一致」
        // 例：谷雨(更新至06集) / 谷雨 全24集 / 谷雨-完结 / 谷雨 超前点映
        s = s.replacingOccurrences(
            of: "(更新至|更新到|已更新|更至|连载至|全)\\s*[0-9]+\\s*[集话話期]?",
            with: "", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "[0-9]+\\s*[集话話期]\\s*(全|完|完结)?",
            with: "", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "(完结|已完结|大结局|超前点映|超前点播|点映|抢先版|预告)",
            with: "", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "(4k|8k|1080p|720p|hd|bd|蓝光|国语|粤语|中字|完整版|未删减|dvd|vip)",
            with: "", options: .regularExpression
        )
        return String(s.filter { $0.isLetter || $0.isNumber })
    }

    static func matchRelevance(title: String, query: String) -> Int {
        let a = normalizedTitle(title)
        let b = normalizedTitle(query)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 2 }
        if a.count >= 2, b.count >= 2 {
            if a.contains(b), b.count * 2 >= a.count { return 1 }
            if b.contains(a), a.count * 2 >= b.count { return 1 }
        }
        return 0
    }

    // MARK: - 多站点聚合搜索

    /// 并发搜索所有可用站点；任一站失败/超时不影响其它站点。
    /// 结果排序：完全匹配 > 包含匹配 > 其它；同级别下当前站点优先、站点原顺序优先。
    static func search(keyword: String,
                       in sites: [Site],
                       limitPerSite: Int = 12,
                       limitTotal: Int = 120,
                       preferredSiteKey: String? = nil,
                       maxSites: Int = 24) async -> [SiteSearchResult] {
        let targets = Array(usableSites(sites).prefix(max(1, maxSites)))
        guard !targets.isEmpty else { return [] }

        let kw = keyword
        let per = max(1, limitPerSite)
        let batches: [Batch] = await withTaskGroup(
            of: Batch?.self,
            returning: [Batch].self
        ) { group in
            for (idx, site) in targets.enumerated() {
                group.addTask {
                    do {
                        let items = try await APIService.shared.searchVideos(
                            site: site, keyword: kw, timeout: 6
                        )
                        return Batch(index: idx, site: site, items: Array(items.prefix(per)))
                    } catch {
                        return nil
                    }
                }
            }
            var collected: [Batch] = []
            for await batch in group {
                if let batch = batch { collected.append(batch) }
            }
            return collected
        }

        let ordered = batches.sorted { $0.index < $1.index }
        var out: [SiteSearchResult] = []
        var seen = Set<String>()
        for batch in ordered {
            let bias = (batch.site.key == preferredSiteKey) ? -1_000_000 : 0
            for (itemIdx, item) in batch.items.enumerated() {
                let key = "\(batch.site.key)#\(item.vodId)"
                guard seen.insert(key).inserted else { continue }
                out.append(SiteSearchResult(
                    item: item,
                    site: batch.site,
                    relevance: matchRelevance(title: item.vodName, query: keyword),
                    order: bias + batch.index * 1000 + itemIdx
                ))
            }
        }
        out.sort { a, b in
            if a.relevance != b.relevance { return a.relevance > b.relevance }
            return a.order < b.order
        }
        if out.count > limitTotal { out = Array(out.prefix(limitTotal)) }
        return out
    }

    // MARK: - 站点级自动换源

    /// 线路全部失败时调用：在其它站点搜同名片 → 拉详情 → 找一条含 m3u8 直链的线路。
    /// - excludingKeys: 本次播放已经试过（以及当前）的站点，避免来回切同一个坏站
    /// - episodeIndex / progress: 尽量保留集数与播放进度
    static func findAlternative(title: String,
                                in sites: [Site],
                                excludingKeys: Set<String>,
                                episodeIndex: Int,
                                progress: Double,
                                preferredSiteKey: String? = nil) async -> CrossSitePlayable? {
        let candidates = usableSites(sites).filter { !excludingKeys.contains($0.key) }
        guard !candidates.isEmpty else { return nil }

        let found = await search(keyword: title,
                                 in: candidates,
                                 limitPerSite: 8,
                                 limitTotal: 60,
                                 preferredSiteKey: preferredSiteKey)
        // 只接受标题高度匹配的结果，避免自动换成另一部片子
        let exact = found.filter { $0.relevance == 2 }
        let pool = Array((exact.isEmpty ? found.filter { $0.relevance == 1 } : exact).prefix(6))
        guard !pool.isEmpty else { return nil }

        let ep = max(0, episodeIndex)
        let seek = max(0, progress)
        return await withTaskGroup(
            of: Candidate?.self,
            returning: CrossSitePlayable?.self
        ) { group in
            for (idx, result) in pool.enumerated() {
                group.addTask {
                    guard let detail = try? await APIService.shared.fetchVideoDetail(
                        site: result.site, vodId: result.item.vodId, timeout: 6
                    ) else { return nil }
                    let sources = detail.parsePlaySources()
                    guard !sources.isEmpty else { return nil }
                    // 给线路打上来源站点标记，播放器里能显示「来自哪个站」
                    let tagged = sources.map { src in
                        PlaySource(name: src.name,
                                   episodes: src.episodes,
                                   siteName: result.site.name,
                                   siteKey: result.site.key)
                    }
                    for (srcIdx, source) in tagged.enumerated() {
                        let epIdx = source.episodes.indices.contains(ep) ? ep : 0
                        guard source.episodes.indices.contains(epIdx),
                              PlayURL.isDirectPlayable(url: source.episodes[epIdx].url)
                        else { continue }
                        let playable = CrossSitePlayable(
                            detail: detail,
                            sources: tagged,
                            sourceIndex: srcIdx,
                            episodeIndex: epIdx,
                            seekTo: seek,
                            siteKey: result.site.key,
                            siteName: result.site.name
                        )
                        return Candidate(index: idx, playable: playable)
                    }
                    return nil
                }
            }
            // 收集全部候选后按 pool 顺序取最相关的一个；不中途 cancel，
            // 避免在 `for await ... in group` 内访问 group 触发 exclusivity 冲突
            var best: Candidate?
            for await candidate in group {
                guard let candidate = candidate, candidate.playable != nil else { continue }
                if let current = best {
                    if candidate.index < current.index { best = candidate }
                } else {
                    best = candidate
                }
            }
            return best?.playable
        }
    }

    // MARK: - 详情页跨站线路聚合（1.4.9）

    /// 详情页「片源可在所有源里切换」的数据源：
    /// 一个站点上找到的同名片，连同它的全部播放线路。
    struct CrossSiteLine: @unchecked Sendable {
        let siteKey: String
        let siteName: String
        let vodId: String
        let vodName: String
        /// 该站点上的线路（已带来源标记）
        let sources: [PlaySource]
    }

    /// 在其它站点搜同名片，并把每个站点的播放线路一起带回来。
    /// - maxSites: 最多取几个站（避免一次开几十个请求）
    /// - onlyDirect: 只保留含 m3u8 / mp4 直链的线路
    static func fetchCrossSiteLines(title: String,
                                    in sites: [Site],
                                    excludingKeys: Set<String>,
                                    maxSites: Int = 8,
                                    onlyDirect: Bool = true) async -> [CrossSiteLine] {
        let candidates = usableSites(sites).filter { !excludingKeys.contains($0.key) }
        guard !candidates.isEmpty else { return [] }

        let found = await search(keyword: title,
                                 in: candidates,
                                 limitPerSite: 6,
                                 limitTotal: 60)
        // 优先完全匹配，其次包含匹配
        let exact = found.filter { $0.relevance == 2 }
        let partial = found.filter { $0.relevance == 1 }
        let ordered = exact.isEmpty ? partial : (exact + partial)

        // 同一个站点只取最相关的一条
        var seenSite = Set<String>()
        let pool = ordered.filter { seenSite.insert($0.site.key).inserted }.prefix(maxSites)
        guard !pool.isEmpty else { return [] }

        let lines: [CrossSiteLine] = await withTaskGroup(
            of: CrossSiteLine?.self,
            returning: [CrossSiteLine].self
        ) { group in
            for result in pool {
                group.addTask {
                    guard let detail = try? await APIService.shared.fetchVideoDetail(
                        site: result.site, vodId: result.item.vodId, timeout: 8
                    ) else { return nil }
                    let parsed = detail.parsePlaySources()
                    guard !parsed.isEmpty else { return nil }
                    let tagged = parsed.map { src -> PlaySource in
                        PlaySource(name: src.name,
                                   episodes: src.episodes,
                                   siteName: result.site.name,
                                   siteKey: result.site.key)
                    }
                    if onlyDirect {
                        let usable = tagged.filter { src in
                            src.episodes.contains(where: { PlayURL.isDirectPlayable(url: $0.url) })
                        }
                        guard !usable.isEmpty else { return nil }
                    }
                    return CrossSiteLine(siteKey: result.site.key,
                                        siteName: result.site.name,
                                        vodId: result.item.vodId,
                                        vodName: detail.vodName,
                                        sources: tagged)
                }
            }
            var collected: [CrossSiteLine] = []
            for await line in group {
                if let line = line { collected.append(line) }
            }
            return collected
        }
        return lines
    }
}
