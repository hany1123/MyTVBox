import Foundation
import SwiftUI

/// 订阅源（用户添加的接口地址）
///
/// 1.4.9 起支持「同时启用多个订阅源」：
/// - `isEnabled`：是否参与合并站点池（多选）。旧数据只有 `isActive`，解码时自动兼容。
/// - `activeSubscriptionId`：当前聚焦的订阅（界面高亮、单独刷新用），不再决定加载哪些源。
struct Subscription: Codable, Identifiable, Hashable {

    enum CodingKeys: String, CodingKey {
        case id, name, url
        case isEnabled
        case isActive       // 1.4.8 旧字段，仅为兼容老数据
        case lastUpdated
    }

    let id: UUID
    var name: String
    var url: String
    /// 是否参与合并站点池
    var isEnabled: Bool
    var lastUpdated: Date?

    init(id: UUID = UUID(),
         name: String,
         url: String,
         isEnabled: Bool = true,
         lastUpdated: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.lastUpdated = lastUpdated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(String.self, forKey: .url)
        // 优先读新字段；老数据回落 isActive；都没有则默认启用
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .isEnabled) {
            self.isEnabled = v
        } else if let v = try? c.decodeIfPresent(Bool.self, forKey: .isActive) {
            self.isEnabled = v
        } else {
            self.isEnabled = true
        }
        self.lastUpdated = try? c.decodeIfPresent(Date.self, forKey: .lastUpdated)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(isEnabled, forKey: .isActive)
        try c.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
    }
}

// MARK: - 订阅配置加载（文件级，非 MainActor 隔离）
//
// 1.4.9：多订阅要并发拉取。若把加载函数放进 `@MainActor` 的 AppState 里，
// 静态方法同样被主线程隔离，TaskGroup 的每个子任务都要 hop 回主线程，
// 并发就退化成串行。这里放在文件顶层，保证真正跑在并发执行器上。

/// 单个订阅的加载结果（TVBoxConfig 不是 Sendable，故整体标注）
struct LoadedSource: @unchecked Sendable {
    let id: UUID
    let config: TVBoxConfig
    let stats: ConfigService.ConfigStats
    let repos: [RepoLink]
}

/// 加载单个订阅的原始配置
func loadSubscriptionConfig(_ sub: Subscription) async -> LoadedSource? {
    // 内置源：本地构造，不走网络
    if BuiltinSources.isBuiltin(sub.url) {
        let cfg = BuiltinSources.config()
        let stats = ConfigService.ConfigStats(
            totalSites: cfg.sites?.count ?? 0,
            usableSites: cfg.sites?.count ?? 0,
            droppedJarSites: 0,
            lives: cfg.lives?.count ?? 0
        )
        return LoadedSource(id: sub.id, config: cfg, stats: stats, repos: [])
    }

    // 每个订阅用独立实例，避免并发时 lastStats / lastRepos 互相覆盖
    let service = ConfigService()
    do {
        let cfg = try await service.loadConfig(from: sub.url)
        return LoadedSource(id: sub.id,
                            config: cfg,
                            stats: service.lastStats ?? ConfigService.ConfigStats(),
                            repos: service.lastRepos)
    } catch {
        // 猫爪 / Spider 模块：退回到源码生成的 CMS 源
        if CatPawConfigBuilder.isCatPawURL(sub.url),
           let cfg = try? await CatPawConfigBuilder.shared.buildConfig(baseURL: sub.url) {
            let stats = ConfigService.ConfigStats(
                totalSites: cfg.sites?.count ?? 0,
                usableSites: cfg.sites?.count ?? 0,
                droppedJarSites: 0,
                lives: cfg.lives?.count ?? 0
            )
            return LoadedSource(id: sub.id, config: cfg, stats: stats, repos: [])
        }
        return nil
    }
}

/// 全局应用状态
@MainActor
final class AppState: ObservableObject {
    // MARK: - 配置

    /// 合并后的站点池：所有「已启用」订阅的站点合并在一起
    @Published var currentConfig: TVBoxConfig?
    @Published var currentSite: Site?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    /// 非错误类信息（如「加载成功但部分站点 iOS 不支持」），与 errorMessage 分开以免误报「出错了」
    @Published var configNotice: String?

    @Published var subscriptions: [Subscription] = []
    /// 当前聚焦的订阅（只是界面高亮，不再决定加载范围）
    @Published var activeSubscriptionId: UUID?

    /// 1.7.4：跨页跳转用的两个小通道
    /// 主 Tab 当前页（0 首页 / 1 分类 / 2 搜索 / 3 收藏 / 4 设置）
    @Published var selectedTab: Int = 0
    /// 详情页「去搜索」时带给搜索页的关键字，搜索页取走后置 nil
    @Published var pendingSearchKeyword: String?

    /// 1.8.0：跳搜索页的唯一出口。
    ///
    /// 之前是「关详情 + 切 Tab + 塞关键词」在同一帧里做。SwiftUI 会在视图更新期间
    /// 拆掉正在 dismiss 的 NavigationStack，iOS 16 上表现为**点豆瓣电影直接闪退**。
    /// 现在统一成：调用方先 dismiss，隔一拍（放过转场）再切 Tab 并带关键词。
    func jumpToSearch(keyword kw: String, after delay: TimeInterval = 0.35) {
        let t = kw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        SessionTrace.mark("开 跳搜索 \(t)")
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self else { return }
            self.pendingSearchKeyword = t
            self.selectedTab = 2
            SessionTrace.mark("完 跳搜索 \(t)")
        }
    }
    /// 当前订阅若是多仓，这里是可切换的子仓库列表
    @Published var availableRepos: [RepoLink] = []
    @Published var activeRepoURL: String?
    /// 站点 key -> 所属订阅名（合并池里同名站点需要区分来源）
    @Published var siteSourceNames: [String: String] = [:]

    // MARK: - 私有

    private let subscriptionsKey = "MyTVBox.subscriptions"
    private let activeSubKey = "MyTVBox.activeSubscription"
    private let activeSiteKey = "MyTVBox.activeSite"
    private let didSeedDefaultKey = "MyTVBox.didSeedDefaultSubscription"

    /// 每个订阅加载到的内容（合并站点池的原料）
    private struct SourceGroup {
        let subscriptionId: UUID
        var name: String
        var sites: [Site]
        var lives: [LiveSource]
        var parses: [ParseRule]
        var flags: [String]
        var repos: [RepoLink]
        var stats: ConfigService.ConfigStats
        /// 猫爪 / Spider 入口（合并时取第一个非空）
        var spider: String?
        /// ijk 播放内核配置（合并时取第一个非空）
        var ijk: [AnyCodable]?
    }

    private var groups: [UUID: SourceGroup] = [:]
    /// 子仓库 URL -> 所属订阅 id（切仓库时只替换该订阅的站点）
    private var repoOwners: [String: UUID] = [:]

    // MARK: - 默认订阅源

    static let defaultSubscriptionName = "内置源"
    static let defaultSubscriptionURL = BuiltinSources.defaultURL
    /// 1.7.0：App 内置 Node 运行时提供的猫爪源（127.0.0.1，不需要电脑）
    static let localNodeSourceName = "本机猫爪源"

    init() {
        loadSubscriptions()
        seedDefaultSubscriptionIfNeeded()
    }

    // MARK: - 订阅持久化

    func loadSubscriptions() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: subscriptionsKey),
           let arr = try? JSONDecoder().decode([Subscription].self, from: data) {
            self.subscriptions = arr
        }
        if let s = defaults.string(forKey: activeSubKey),
           let uuid = UUID(uuidString: s) {
            self.activeSubscriptionId = uuid
        }
    }

    /// 确保内置源存在（老版本升级后也会自动补上）
    private func seedDefaultSubscriptionIfNeeded() {
        let defaults = UserDefaults.standard
        if subscriptions.contains(where: { BuiltinSources.isBuiltin($0.url) }) { return }
        let sub = Subscription(
            name: Self.defaultSubscriptionName,
            url: Self.defaultSubscriptionURL,
            isEnabled: true
        )
        subscriptions.insert(sub, at: 0)
        activeSubscriptionId = sub.id
        saveSubscriptions()
        defaults.set(true, forKey: didSeedDefaultKey)
    }

    func saveSubscriptions() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: subscriptionsKey)
        }
        if let id = activeSubscriptionId {
            defaults.set(id.uuidString, forKey: activeSubKey)
        } else {
            defaults.removeObject(forKey: activeSubKey)
        }
    }

    func addSubscription(_ sub: Subscription) {
        subscriptions.append(sub)
        if activeSubscriptionId == nil {
            activeSubscriptionId = sub.id
        }
        saveSubscriptions()
    }

    // MARK: - 1.7.0 端上 Node 源

    /// 端上 Node 就绪后，把本机源挂成一个订阅（幂等）。
    ///
    /// 用 `127.0.0.1` 前缀识别「本机源」：如果之前挂过但端口变了（源在端口
    /// 被占用时会自动 +1），这里会就地更新 URL 而不是再加一条重复订阅。
    func installLocalNodeSource(base: String) {
        var norm = base
        while norm.hasSuffix("/") { norm.removeLast() }
        guard !norm.isEmpty else { return }
        let configURL = norm + "/config"

        if let idx = subscriptions.firstIndex(where: { $0.url.hasPrefix("http://127.0.0.1:") }) {
            guard subscriptions[idx].url != configURL else { return }
            subscriptions[idx].url = configURL
            subscriptions[idx].isEnabled = true
            saveSubscriptions()
            return
        }

        let sub = Subscription(name: Self.localNodeSourceName,
                               url: configURL,
                               isEnabled: true)
        subscriptions.insert(sub, at: 0)
        activeSubscriptionId = sub.id
        saveSubscriptions()
    }

    /// 本机源是否已经挂上（用于启动流程判断要不要重新拉配置）。
    var hasLocalNodeSource: Bool {
        subscriptions.contains { $0.url.hasPrefix("http://127.0.0.1:") }
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        groups.removeValue(forKey: id)
        if activeSubscriptionId == id {
            activeSubscriptionId = subscriptions.first?.id
        }
        saveSubscriptions()
        rebuildMergedConfig()
    }

    func updateSubscription(_ sub: Subscription) {
        if let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) {
            subscriptions[idx] = sub
            saveSubscriptions()
        }
    }

    func setActive(_ id: UUID) {
        activeSubscriptionId = id
        saveSubscriptions()
    }

    var activeSubscription: Subscription? {
        guard let id = activeSubscriptionId else { return nil }
        return subscriptions.first { $0.id == id }
    }

    /// 是否存在已激活的订阅源
    var hasActiveSubscription: Bool {
        activeSubscription != nil
    }

    /// 已启用（参与合并）的订阅
    var enabledSubscriptions: [Subscription] {
        // 1.7.3：端上 Node 就绪后，「JS bundle 型」订阅（解析出来是 catpaw_* 站点）
        // 必然跑不起来 —— 猫爪源是 Node 服务端包，JavaScriptCore 里没有 socket，
        // 1.5.4~1.5.9 已经反复验证过这条路是死的。
        // 订阅记录和开关状态都保留（用户随时能看见），只是不再参与加载：
        // 既省掉一次 6.6 MB 下载 + JSC 预处理，也不会把这些永远报空的站点混进合并池。
        subscriptions.filter { $0.isEnabled && !isSupersededByLocalNode($0) }
    }

    /// 该订阅是否已被「端上内核」接管（只有 Node 真正就绪时才成立，
    /// Node 起不来时照旧加载，不能让用户彻底没站点）
    func isSupersededByLocalNode(_ sub: Subscription) -> Bool {
        guard NodeRuntime.shared.isReady else { return false }
        if sub.url.hasPrefix("http://127.0.0.1:") { return false }
        return CatPawConfigBuilder.isCatPawURL(sub.url)
    }

    /// 是否有可用于加载的订阅
    var hasEnabledSubscription: Bool {
        !enabledSubscriptions.isEmpty
    }

    /// 1.7.7：已启用订阅里是否有「指向端上 Node」的那种。
    /// 这种在 Node 就绪前加载必定失败，所以要等启动流程统一处理，不能抢先拉。
    var hasEnabledLocalNodeSubscription: Bool {
        enabledSubscriptions.contains { $0.url.hasPrefix("http://127.0.0.1:") }
    }

    // MARK: - 配置加载

    /// 加载全部「已启用」订阅并合并成一个站点池
    func loadConfig() async {
        let enabled = enabledSubscriptions
        guard !enabled.isEmpty else {
            self.errorMessage = "没有启用任何接口，请到「接口管理」里至少开启一个"
            self.currentConfig = nil
            return
        }

        isLoading = true
        errorMessage = nil
        configNotice = nil
        defer { isLoading = false }

        // 并发拉取各订阅（每个订阅用独立 ConfigService 实例，避免共享诊断状态被覆盖）
        let results: [LoadedSource] = await withTaskGroup(
            of: LoadedSource?.self,
            returning: [LoadedSource].self
        ) { group in
            for sub in enabled {
                group.addTask {
                    await loadSubscriptionConfig(sub)
                }
            }
            var collected: [LoadedSource] = []
            for await item in group {
                if let item { collected.append(item) }
            }
            return collected
        }

        var okCount = 0
        var siteTotal = 0
        var dropped = 0
        var livesTotal = 0
        for item in results {
            let id = item.id
            groups[id] = SourceGroup(
                subscriptionId: id,
                name: subscriptions.first { $0.id == id }?.name ?? "接口",
                sites: item.config.sites ?? [],
                lives: item.config.lives ?? [],
                parses: item.config.parses ?? [],
                flags: item.config.flags ?? [],
                repos: item.repos,
                stats: item.stats,
                spider: item.config.spider,
                ijk: item.config.ijk
            )
            for repo in item.repos { repoOwners[repo.url] = id }
            okCount += 1
            siteTotal += item.stats.totalSites
            dropped += item.stats.droppedJarSites
            livesTotal += item.stats.lives
        }

        rebuildMergedConfig()
        touchUpdated(enabled.map { $0.id })

        if okCount == 0 {
            errorMessage = "所有接口都没能加载成功，请检查地址是否可访问"
        } else if siteTotal > 0 && usableSiteCount == 0 {
            var msg = "接口读取成功，但 \(siteTotal) 个站点全部为 JAR 型（需 Android 运行时），iOS 无法加载。"
            if livesTotal > 0 { msg += "另有 \(livesTotal) 路直播源可用。" }
            msg += "\n建议换一个含 CMS / JS 站点的接口。"
            configNotice = msg
        } else if dropped > 0 {
            configNotice = "已合并 \(okCount) 个接口 · \(usableSiteCount) 个可用站点（另有 \(dropped) 个 JAR 型站点无法在 iOS 运行）。"
        } else {
            configNotice = "已合并 \(okCount) 个接口 · \(usableSiteCount) 个可用站点。"
        }
    }

    /// 1.7.7：带重试的加载。
    ///
    /// 端上 Node 刚 listen 时，源内部的 `/config` 可能还在拉远端站点配置，
    /// 第一次请求经常超时 —— 以前的表现就是「打开 App 显示 0 个站点，
    /// 得手动点一下订阅才加载出来」。这里失败就退避重试，用户不用管。
    @discardableResult
    func loadConfigWithRetry(attempts: Int = 4, delay: TimeInterval = 2.0) async -> Bool {
        var attempt = 0
        while true {
            attempt += 1
            await loadConfig()
            if usableSiteCount > 0 { return true }
            if attempt >= attempts { return false }
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, delay) * 1_000_000_000))
        }
    }

    /// 单独加载一个订阅并并入合并池（切换聚焦源时用）
    func reloadSubscription(_ sub: Subscription) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        if let item = await loadSubscriptionConfig(sub) {
            let id = item.id
            groups[id] = SourceGroup(
                subscriptionId: id,
                name: sub.name,
                sites: item.config.sites ?? [],
                lives: item.config.lives ?? [],
                parses: item.config.parses ?? [],
                flags: item.config.flags ?? [],
                repos: item.repos,
                stats: item.stats,
                spider: item.config.spider,
                ijk: item.config.ijk
            )
            for repo in item.repos { repoOwners[repo.url] = id }
            rebuildMergedConfig()
            touchUpdated([sub.id])
        } else {
            errorMessage = "「\(sub.name)」加载失败"
        }
    }

    /// 开启 / 关闭某个订阅（关闭则从合并池里移除）
    /// - 开启：调用方需随后调用 `loadConfig()` 重新拉取并合并
    /// - 关闭：立即移出合并池并重建
    func setEnabled(_ sub: Subscription, _ enabled: Bool) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) else { return }
        guard subscriptions[idx].isEnabled != enabled else { return }
        subscriptions[idx].isEnabled = enabled
        saveSubscriptions()

        if !enabled {
            groups.removeValue(forKey: sub.id)
            rebuildMergedConfig()
        }
    }

    /// 加载单个订阅的原始配置（静态方法，便于在 TaskGroup 内并发调用）
    ///
    /// 必须是 `nonisolated`：本类是 `@MainActor`，静态方法默认也是主线程隔离，
    /// 那样 TaskGroup 的每个子任务都要 hop 回主线程，多订阅并发加载会退化成串行。
    private static func loadOne(
        _ sub: Subscription
    ) async -> LoadedSource? {
        await loadSubscriptionConfig(sub)
    }

    private func touchUpdated(_ ids: [UUID]) {
        for id in ids {
            if let idx = subscriptions.firstIndex(where: { $0.id == id }) {
                subscriptions[idx].lastUpdated = Date()
            }
        }
        saveSubscriptions()
    }

    // MARK: - 合并站点池

    /// 合并所有已启用订阅的站点 / 直播 / 解析器 / 标识
    private func rebuildMergedConfig() {
        var usedKeys = Set<String>()
        var sites: [Site] = []
        var sourceNames: [String: String] = [:]
        var lives: [LiveSource] = []
        var seenLive = Set<String>()
        var parses: [ParseRule] = []
        var seenParse = Set<String>()
        var flags: [String] = []
        var seenFlag = Set<String>()
        var repos: [RepoLink] = []
        var seenRepo = Set<String>()
        var spider: String?
        var ijk: [AnyCodable]?

        for sub in subscriptions where sub.isEnabled {
            guard let group = groups[sub.id] else { continue }
            if spider == nil { spider = group.spider }
            if ijk == nil { ijk = group.ijk }
            for site in group.sites {
                // 1.7.3：端上 Node 已就绪时，旧的 catpaw_* 站点（JSC 路线）一律不进合并池。
                // 它们和 noderelay_* 指的是同一批站，留着只会让人点到空列表。
                if NodeRuntime.shared.isReady, site.key.hasPrefix("catpaw_") { continue }
                let unique = dedupeKey(site.key, used: &usedKeys)
                let final = unique == site.key ? site : site.replacingKey(unique)
                sites.append(final)
                sourceNames[final.key] = sub.name
            }
            for live in group.lives {
                let sig = "\(live.name)|\(live.url ?? "")"
                if seenLive.insert(sig).inserted { lives.append(live) }
            }
            for parse in group.parses {
                let sig = "\(parse.name)|\(parse.url ?? "")"
                if seenParse.insert(sig).inserted { parses.append(parse) }
            }
            for flag in group.flags where !flag.isEmpty {
                if seenFlag.insert(flag).inserted { flags.append(flag) }
            }
            for repo in group.repos where seenRepo.insert(repo.url).inserted {
                repos.append(repo)
            }
        }

        self.siteSourceNames = sourceNames
        self.availableRepos = repos
        self.currentConfig = TVBoxConfig(
            spider: spider,
            sites: sites,
            lives: lives,
            parses: parses,
            flags: flags.isEmpty ? nil : flags,
            ijk: ijk,
            repos: repos
        )

        // 当前站点仍存在就保留，否则重新挑一个
        if currentSite == nil || !sites.contains(where: { $0.key == currentSite?.key }) {
            let preferred = sites.first { $0.type != 3 && ($0.api ?? "").hasPrefix("http") }
            self.currentSite = preferred ?? sites.first
        }
    }

    /// 生成池内唯一的站点 key
    private func dedupeKey(_ key: String, used: inout Set<String>) -> String {
        var candidate = key
        var n = 2
        while !used.insert(candidate).inserted {
            candidate = "\(key)#\(n)"
            n += 1
        }
        // Spider 站点按 key 索引模块代码，改名后要同步一份
        if candidate != key,
           let code = SpiderContextManager.shared.moduleCode(for: key) {
            SpiderContextManager.shared.registerModuleCode(key: candidate, code: code)
        }
        return candidate
    }

    /// 合并池里可用于 CMS 搜索的站点数量
    var usableSiteCount: Int {
        CrossSiteResolver.usableSites(currentConfig?.sites ?? []).count
    }

    /// 合并池里的站点总数（含 JAR 型）
    var totalSiteCount: Int {
        currentConfig?.sites?.count ?? 0
    }

    /// 某个订阅贡献的站点数
    func siteCount(for subscriptionId: UUID) -> Int {
        groups[subscriptionId]?.sites.count ?? 0
    }

    /// 某个订阅贡献的可用站点数（排除 JAR 型）
    func usableSiteCount(for subscriptionId: UUID) -> Int {
        guard let sites = groups[subscriptionId]?.sites else { return 0 }
        return CrossSiteResolver.usableSites(sites).count
    }

    // MARK: - 多仓

    /// 多仓：手动切换到某个子仓库（只替换该仓库所属订阅的站点，其余订阅保持不变）
    func selectRepo(_ repo: RepoLink) async {
        isLoading = true
        errorMessage = nil
        configNotice = nil
        defer { isLoading = false }
        do {
            let service = ConfigService()
            let cfg = try await service.loadRepoConfig(from: repo.url)
            let owner = repoOwners[repo.url]
            if let owner, var group = groups[owner] {
                group.sites = cfg.sites ?? []
                group.lives = cfg.lives ?? []
                group.parses = cfg.parses ?? []
                group.flags = cfg.flags ?? []
                groups[owner] = group
            } else {
                // 找不到归属就当作一个独立来源并入
                let id = UUID()
                groups[id] = SourceGroup(
                    subscriptionId: id,
                    name: repo.name,
                    sites: cfg.sites ?? [],
                    lives: cfg.lives ?? [],
                    parses: cfg.parses ?? [],
                    flags: cfg.flags ?? [],
                    repos: [],
                    stats: service.lastStats ?? ConfigService.ConfigStats(),
                    spider: cfg.spider,
                    ijk: cfg.ijk
                )
            }
            activeRepoURL = repo.url
            rebuildMergedConfig()
            let usable = usableSiteCount
            if usable == 0 {
                configNotice = "仓库「\(repo.name)」没有可用站点。"
            } else {
                configNotice = "已切换到仓库「\(repo.name)」· 合并池现有 \(usable) 个可用站点。"
            }
        } catch {
            self.errorMessage = "仓库加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 切换当前站点

    /// 切换当前站点
    func selectSite(_ site: Site) {
        self.currentSite = site
    }
}
