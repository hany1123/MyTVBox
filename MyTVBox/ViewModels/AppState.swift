import Foundation
import SwiftUI

/// 订阅源（用户添加的接口地址）
struct Subscription: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var url: String
    var isActive: Bool
    var lastUpdated: Date?

    init(id: UUID = UUID(),
         name: String,
         url: String,
         isActive: Bool = true,
         lastUpdated: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.isActive = isActive
        self.lastUpdated = lastUpdated
    }
}

/// 全局应用状态
@MainActor
final class AppState: ObservableObject {

    // MARK: - 配置

    @Published var currentConfig: TVBoxConfig?
    @Published var currentSite: Site?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    @Published var subscriptions: [Subscription] = []
    @Published var activeSubscriptionId: UUID?

    // MARK: - 私有

    private let subscriptionsKey = "MyTVBox.subscriptions"
    private let activeSubKey = "MyTVBox.activeSubscription"
    private let activeSiteKey = "MyTVBox.activeSite"
    private let didSeedDefaultKey = "MyTVBox.didSeedDefaultSubscription"

    // MARK: - 默认订阅源
    static let defaultSubscriptionName = "内置源"
    static let defaultSubscriptionURL = BuiltinSources.defaultURL

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
            isActive: true
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

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        if activeSubscriptionId == id {
            activeSubscriptionId = subscriptions.first?.id
        }
        saveSubscriptions()
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

    // MARK: - 配置加载

    /// 加载当前激活订阅的配置
    func loadConfig() async {
        guard let sub = activeSubscription else {
            self.errorMessage = "未选择订阅源"
            return
        }
        await loadConfig(from: sub.url, subscriptionId: sub.id)
    }

    /// 从指定 URL 加载配置（并更新订阅时间戳）
    func loadConfig(from url: String, subscriptionId: UUID? = nil) async {
        // 内置源：本地构造，不走网络
        if BuiltinSources.isBuiltin(url) {
            let cfg = BuiltinSources.config()
            self.currentConfig = cfg
            let sites = cfg.sites ?? []
            if currentSite == nil || !sites.contains(where: { $0.key == currentSite?.key }) {
                self.currentSite = sites.first
            }
            self.errorMessage = nil
            if let sid = subscriptionId,
               let idx = subscriptions.firstIndex(where: { $0.id == sid }) {
                subscriptions[idx].lastUpdated = Date()
                saveSubscriptions()
            }
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let cfg = try await ConfigService.shared.loadConfig(from: url)
            self.currentConfig = cfg

            // 智能选择默认站点：优先 CMS 标准接口（type != 3），其次 type 3 中有真实 URL 的
            let allSites = cfg.sites ?? []
            let cmsSites = allSites.filter { $0.type != 3 || $0.spiderKey != nil }
            let spiderWithURL = allSites.filter { $0.type == 3 && $0.spiderKey == nil && ($0.api ?? "").hasPrefix("http") }

            if currentSite == nil || !allSites.contains(where: { $0.key == currentSite?.key }) {
                self.currentSite = cmsSites.first ?? spiderWithURL.first ?? allSites.first
            }

            // 更新订阅时间戳
            if let sid = subscriptionId,
               let idx = subscriptions.firstIndex(where: { $0.id == sid }) {
                subscriptions[idx].lastUpdated = Date()
                saveSubscriptions()
            }

            // 提示可用站点情况
            let usableCount = cmsSites.count + spiderWithURL.count
            let spiderOnlyCount = allSites.count - usableCount
            if spiderOnlyCount > 0 && cmsSites.count > 0 {
                self.errorMessage = "已加载 \(allSites.count) 个站点，其中 \(cmsSites.count) 个可用，\(spiderOnlyCount) 个 Spider 源缺少 JS 引擎支持。"
            }
        } catch {
            // 如果是默认 CatPaw 订阅源加载失败，使用 CatPawConfigBuilder 生成配置
            if url == Self.defaultSubscriptionURL || CatPawConfigBuilder.isCatPawURL(url) {
                do {
                    let fallbackCfg = try await CatPawConfigBuilder.shared.buildConfig(baseURL: url)
                    self.currentConfig = fallbackCfg
                    if currentSite == nil, let first = fallbackCfg.sites?.first {
                        self.currentSite = first
                    }
                    self.errorMessage = "原始接口为 Spider 模块，已自动使用基于 CatPawOpen 源码生成的内置源（\(fallbackCfg.sites?.count ?? 0) 个 CMS 源）。"
                    return
                } catch {}
            }
            self.errorMessage = error.localizedDescription
            self.currentConfig = nil
        }
    }

    /// 切换当前站点
    func selectSite(_ site: Site) {
        self.currentSite = site
    }
}
