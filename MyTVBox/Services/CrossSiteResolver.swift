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

    /// 1.8.4：一次站点搜索的结果 + 「这个站是不是真的失败了」。
    /// 只有抛错/超时才算失败；正常返回空列表只是「没这部片」，不能拉黑。
    private struct FetchResult: @unchecked Sendable {
        let batch: Batch?
        let failed: Bool
        let key: String
        let reason: String
        /// 1.8.18：本次请求耗时，既喂给 SiteHealth 做快站优先，也用于自适应并发
        let ms: TimeInterval
    }

    private static func fetchOne(idx: Int, site: Site, kw: String,
                                 per: Int, timeout: TimeInterval) async -> FetchResult {
        let t0 = Date()
        do {
            let items = try await APIService.shared.searchVideos(
                site: site, keyword: kw, timeout: timeout)
            return FetchResult(batch: Batch(index: idx, site: site,
                                            items: Array(items.prefix(per))),
                               failed: false, key: site.key, reason: "",
                               ms: Date().timeIntervalSince(t0))
        } catch {
            let why = String(error.localizedDescription.prefix(120))
            return FetchResult(batch: nil, failed: true, key: site.key, reason: why,
                               ms: Date().timeIntervalSince(t0))
        }
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
    ///
    /// - Parameter concurrency: 同时最多打几个站。
    ///   1.7.7：以前是把 200 个站一次性全 `addTask` 出去 —— 端上 Node 那边等于同时
    ///   发起 200 个上游请求，每个都持有整页 HTML/JSON，V8 堆撞上限直接
    ///   `FATAL ERROR: Reached heap limit` → **整个 App 进程被 abort，表现就是闪退**。
    ///   分批后峰值内存与连接数都可控；16 路是 1.8.0 再压一档的取值（24 路仍偏多，
    ///   98 个站约 7 批，代价是总耗时多几秒，换来内存峰值明显下降）。
    /// 1.8.2：所有聚合搜索都必须过 `HeavyWorkGate` 的闸。
    /// 崩溃现场是「搜索页 60 站」与「详情页跨站接管 110 站」同时在跑，
    /// Node 侧同时执行两批 spider，V8 堆撞顶 → abort。
    /// 过闸后两件重活会排队，峰值只有一批。
    /// `onPartial` 非空即启用流式：每个站一返回就把该站结果推给调用方，
    /// 调用方可以边搜边上屏，不必等齐全部站点（1.8.18）。
    static func search(keyword: String,
                       in sites: [Site],
                       limitPerSite: Int = 12,
                       limitTotal: Int = 120,
                       preferredSiteKey: String? = nil,
                       maxSites: Int = 24,
                       concurrency: Int = 16,
                       budget: TimeInterval = 0,
                       onPartial: (@Sendable ([SiteSearchResult]) -> Void)? = nil
    ) async -> [SiteSearchResult] {
        let result = await HeavyWorkGate.shared.run {
            await searchUngated(
                keyword: keyword, in: sites, limitPerSite: limitPerSite,
                limitTotal: limitTotal, preferredSiteKey: preferredSiteKey,
                maxSites: maxSites, concurrency: concurrency, budget: budget,
                onPartial: onPartial)
        }
        return result ?? []
    }

    private static func searchUngated(keyword: String,
                                      in sites: [Site],
                                      limitPerSite: Int = 12,
                                      limitTotal: Int = 120,
                                      preferredSiteKey: String? = nil,
                                      maxSites: Int = 24,
                                      concurrency: Int = 16,
                                      budget: TimeInterval = 0,
                                      onPartial: (@Sendable ([SiteSearchResult]) -> Void)? = nil
    ) async -> [SiteSearchResult] {
        // 跳过连续失败的坏站；全被冷却了就照常全量，别把结果搜没了
        let all = usableSites(sites)
        let healthy = all.filter { !SiteHealth.shared.isCooling($0.key) }
        let pool = healthy.isEmpty ? all : healthy

        // 1.8.18 快站优先：覆盖的站点集合仍按配置顺序取（慢站不会被永久排除），
        // 只在这批里按历史响应耗时排「谁先发」。batch.index 保留配置原顺序，
        // 所以最终结果的站点次序不受调度影响。
        let window = Array(pool.prefix(max(1, maxSites)).enumerated())
        let ranked = window.sorted { a, b in
            if a.element.key == preferredSiteKey { return true }
            if b.element.key == preferredSiteKey { return false }
            let la = SiteHealth.shared.latencyMs(a.element.key)
            let lb = SiteHealth.shared.latencyMs(b.element.key)
            let va = la > 0 ? la : 1200   // 未知站按 1.2s 中等速度
            let vb = lb > 0 ? lb : 1200
            if va != vb { return va < vb }
            return a.offset < b.offset
        }
        guard !ranked.isEmpty else { return [] }

        let t0 = Date()
        let kw = keyword
        let per = max(1, limitPerSite)
        let siteTimeout: TimeInterval = 3

        // 1.8.18 自适应并发：起步 6 路，连续快站逐步升到上限；一有失败就收，
        // 不让十几个慢站同时压在端上 Node。滑动窗口谁先完成谁空槽补位。
        let ceiling = max(2, concurrency)
        var width = min(ceiling, 6)
        var active = 0
        var cursor = 0
        var batches: [Batch] = []

        await withTaskGroup(of: FetchResult.self) { group in
            func addNext() -> Bool {
                guard cursor < ranked.count else { return false }
                let slot = ranked[cursor]
                cursor += 1
                group.addTask {
                    await Self.fetchOne(idx: slot.offset, site: slot.element,
                                        kw: kw, per: per, timeout: siteTimeout)
                }
                return true
            }

            while active < width, addNext() { active += 1 }

            while let r = await group.next() {
                active -= 1
                SiteHealth.shared.note(r.key, ok: !r.failed,
                                       reason: r.reason, latency: r.ms)
                // 快站连续返回 → 加并发；出现失败 → 立刻收，别堆慢站
                if r.failed {
                    width = max(2, width - 2)
                } else if r.ms < 1.2 {
                    width = min(ceiling, width + 2)
                }
                if let b = r.batch {
                    batches.append(b)
                    // 1.8.18 流式：这一站的结果立刻交给上层上屏，不等其余站
                    if let onPartial = onPartial {
                        let chunk = Self.makeResults(batch: b, keyword: kw,
                                                     preferredSiteKey: preferredSiteKey)
                        if !chunk.isEmpty { onPartial(chunk) }
                    }
                }
                // 页面已退 / 搜索被新词取代 → 收手，别占着重活闸
                if Task.isCancelled { group.cancelAll(); break }
                // 播放页已起播 → 让出 Node 资源，不再补新站
                if await HeavyWorkGate.shared.isCancelRequested() {
                    group.cancelAll()
                    break
                }
                // 总时间预算到点 → 取消在飞的，用已拿到的结果收尾
                if budget > 0, Date().timeIntervalSince(t0) >= budget {
                    group.cancelAll()
                    break
                }
                while active < width, addNext() { active += 1 }
            }
        }
        SiteHealth.shared.flush()

        let ordered = batches.sorted { $0.index < $1.index }
        var out: [SiteSearchResult] = []
        var seen = Set<String>()
        for batch in ordered {
            let chunk = makeResults(batch: batch, keyword: keyword,
                                    preferredSiteKey: preferredSiteKey)
            for r in chunk {
                guard seen.insert(r.id).inserted else { continue }
                out.append(r)
            }
        }
        out.sort { a, b in
            if a.relevance != b.relevance { return a.relevance > b.relevance }
            return a.order < b.order
        }
        if out.count > limitTotal { out = Array(out.prefix(limitTotal)) }
        return out
    }

    /// 单站结果 → 站内去重并按相关度排序。流式增量与最终汇总共用同一套次序。
    private static func makeResults(batch: Batch, keyword: String,
                                    preferredSiteKey: String?) -> [SiteSearchResult] {
        let bias = (batch.site.key == preferredSiteKey) ? -1_000_000 : 0
        var seen = Set<String>()
        var out: [SiteSearchResult] = []
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
        out.sort { a, b in
            if a.relevance != b.relevance { return a.relevance > b.relevance }
            return a.order < b.order
        }
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
