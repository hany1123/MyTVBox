import Foundation
import SwiftUI

/// 内容浏览 ViewModel —— 负责分类、视频列表、分页与刷新
///
/// 关键设计（1.4.4）：
/// 1. 请求不再挂在视图的 `.task` 生命周期上，改由 ViewModel 自己持有 Task，
///    切站点时旧请求主动取消、新请求立刻发起，不会再出现「上一个请求还没回来 → 新请求被丢弃」。
/// 2. 用自增序号 `requestSeq` 做「只认最新」保护，迟到的旧响应直接丢弃。
/// 3. 首页数据进内存缓存，切回已看过的站点瞬间出图，同时在后台静默刷新。
/// 4. `URLError.cancelled` 视为正常中断，不弹错误。
@MainActor
final class ContentViewModel: ObservableObject {

    // MARK: - Published

    @Published var categories: [VideoCategory] = []
    @Published var currentCategory: VideoCategory?
    @Published var videoList: [VideoItem] = []
    @Published var isLoading: Bool = false
    @Published var isLoadingMore: Bool = false
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var errorMessage: String?
    /// 正在用缓存兜底显示（用于界面提示「刷新中」而不是空白）
    @Published var isShowingCached: Bool = false

    // MARK: - 私有

    private let apiService = APIService.shared
    private var loadedSiteKey: String?
    private var loadTask: Task<Void, Never>?
    private var requestSeq = 0
    /// 1.5.2 分类请求序号：切站点时作废旧响应，避免旧站分类覆盖新站
    private var categoriesSeq = 0

    /// 站点首页缓存：site.key|typeId -> 列表
    private static var firstPageCache: [String: [VideoItem]] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 32

    /// 1.5.2 分类缓存（站点 key → 分类 + 写入时间），10 分钟内复用，
    /// 切回看过的站点分类条瞬间出现，不再重跑一次 ac=class。
    private struct CategoryCacheEntry {
        let list: [VideoCategory]
        let date: Date
    }
    private static var categoryCache: [String: CategoryCacheEntry] = [:]
    private static let categoryTTL: TimeInterval = 600

    static func cachedCategories(for site: Site) -> [VideoCategory]? {
        guard let e = categoryCache[site.key],
              Date().timeIntervalSince(e.date) < categoryTTL,
              !e.list.isEmpty else { return nil }
        return e.list
    }

    private static func cacheCategories(_ key: String, _ list: [VideoCategory]) {
        guard !list.isEmpty else { return }
        categoryCache[key] = CategoryCacheEntry(list: list, date: Date())
    }

    // MARK: - 缓存

    private static func cacheKey(_ site: Site, _ category: VideoCategory?) -> String {
        "\(site.key)|\(category?.typeId ?? "")"
    }

    private static func cacheGet(_ key: String) -> [VideoItem]? {
        firstPageCache[key]
    }

    private static func cachePut(_ key: String, _ list: [VideoItem]) {
        guard !list.isEmpty else { return }
        firstPageCache[key] = list
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > cacheLimit {
            let old = cacheOrder.removeFirst()
            firstPageCache.removeValue(forKey: old)
        }
    }

    /// 后台预热相邻站点首页。
    /// 1.5.2 从「逐个串行」改成最多 3 路并发 —— 原来往往还没轮到目标站点，
    /// 用户就已经切过去了，预热等于白做。
    static func prefetch(sites: [Site]) {
        let pending = Array(sites.filter {
            cacheGet(cacheKey($0, nil)) == nil && $0.api != nil
        }.prefix(3))
        guard !pending.isEmpty else { return }
        for site in pending {
            Task { @MainActor in
                let key = cacheKey(site, nil)
                guard cacheGet(key) == nil else { return }
                if let resp = try? await APIService.shared.fetchVideoList(
                    site: site, categoryId: "", page: 1),
                   let list = resp.list, !list.isEmpty {
                    cachePut(key, list)
                }
            }
        }
    }

    /// 首页标题栏用：已缓存几个站点了（调试/展示用）
    static var cachedSiteCount: Int { firstPageCache.count }

    // MARK: - 接口

    /// 1.5.2 带缓存 + 短超时的分类加载。
    /// 失败时**保留**已显示的分类条（旧实现直接清空，慢站一超时整条栏就闪没）。
    @discardableResult
    func loadCategories(site: Site, allowCache: Bool = true) async -> Bool {
        let siteKey = site.key
        categoriesSeq += 1
        let seq = categoriesSeq
        if allowCache, let cached = Self.cachedCategories(for: site) {
            self.categories = cached
        }
        do {
            var result: [VideoCategory] = []
            if site.type == 3, let code = SpiderContextManager.shared.moduleCode(for: site.key) {
                let r = await SpiderEngine.shared.execute(
                    jsCode: code, method: "home", args: [:], spiderKey: site.spiderKey)
                if let classList = r?["class"] as? [[String: Any]] {
                    result = classList.compactMap { dict in
                        guard let typeId = dict["type_id"] as? String ?? (dict["type_id"] as? Int).map(String.init),
                              let typeName = dict["type_name"] as? String else { return nil }
                        return VideoCategory(typeId: typeId, typeName: typeName)
                    }
                }
            } else {
                result = try await apiService.fetchCategories(site: site, timeout: 8)
            }
            guard seq == categoriesSeq else { return false }
            guard !result.isEmpty else { return false }
            self.categories = result
            Self.cacheCategories(siteKey, result)
            return true
        } catch {
            guard seq == categoriesSeq, !Self.isCancellation(error) else { return false }
            if self.categories.isEmpty {
                self.errorMessage = error.localizedDescription
            }
            return false
        }
    }

    /// 1.5.2 分类页首屏：分类与内容**并发**发起。
    /// 旧实现是 `await 分类` 再 `await 列表`，两次网络往返相加，慢站能到 20~40 秒；
    /// 现在首屏时间 = 两者中较慢的一次，且两者都有缓存可先出图。
    /// 默认展示「最新」(category=nil)，分类回来后由用户点选，不会出现
    /// 「条上高亮电影、内容却是最新」的错配。
    func loadInitial(site: Site) async {
        loadTask?.cancel()
        categoriesSeq += 1
        requestSeq += 1
        errorMessage = nil

        if let cached = Self.cachedCategories(for: site), !cached.isEmpty {
            self.categories = cached
        }
        self.currentCategory = nil

        let catTask = Task { @MainActor [weak self] in
            _ = await self?.loadCategories(site: site, allowCache: true)
        }
        let listTask = Task { @MainActor [weak self] in
            _ = await self?.loadVideoList(site: site, category: nil,
                                          allowCache: true, preserveList: false)
        }
        await catTask.value
        await listTask.value
    }

    /// 发起一次「首页/分类首页」加载。
    /// 不 await、不阻塞 UI：内部自持 Task，切换站点时旧请求自动作废。
    /// - Parameters:
    ///   - allowCache: 有缓存就先渲染缓存，再后台刷新
    ///   - preserveList: 下拉刷新场景，保留现有内容不清空
    func reload(site: Site,
                category: VideoCategory? = nil,
                allowCache: Bool = true,
                preserveList: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadVideoList(site: site,
                                      category: category,
                                      allowCache: allowCache,
                                      preserveList: preserveList)
        }
    }

    func loadVideoList(site: Site,
                       category: VideoCategory?,
                       allowCache: Bool = true,
                       preserveList: Bool = false) async {
        requestSeq += 1
        let seq = requestSeq

        errorMessage = nil
        currentCategory = category
        currentPage = 1
        totalPages = 1
        loadedSiteKey = site.key

        let key = Self.cacheKey(site, category)
        if allowCache, let cached = Self.cacheGet(key), !cached.isEmpty {
            // 有缓存：立刻出图，随后静默刷新
            videoList = cached
            isShowingCached = true
        } else if preserveList, !videoList.isEmpty {
            // 下拉刷新：保留旧内容，避免闪白
            isShowingCached = true
        } else {
            videoList = []
            isShowingCached = false
        }
        isLoading = true
        defer {
            if seq == requestSeq { isLoading = false }
        }

        let typeId = category?.typeId ?? ""
        do {
            if site.type == 3, let code = SpiderContextManager.shared.moduleCode(for: site.key) {
                let args: [String: Any] = ["id": typeId, "pg": 1]
                let result = await SpiderEngine.shared.execute(jsCode: code, method: "category", args: args, spiderKey: site.spiderKey)
                guard seq == requestSeq else { return }
                let parsed = parseSpiderList(result)
                self.videoList = parsed.list
                self.totalPages = max(1, parsed.pageCount)
                self.currentPage = parsed.page
                Self.cachePut(key, parsed.list)
            } else {
                let resp = try await apiService.fetchVideoList(site: site, categoryId: typeId, page: 1)
                guard seq == requestSeq else { return }
                let list = resp.list ?? []
                // 缓存过但这次返回空了，说明源站异常：保留旧内容，不闪空
                if list.isEmpty, !self.videoList.isEmpty, allowCache {
                    self.totalPages = 1
                } else {
                    self.videoList = list
                }
                self.totalPages = max(1, resp.pagecount ?? 1)
                self.currentPage = resp.page ?? 1
                Self.cachePut(key, list)
            }
            isShowingCached = false
        } catch {
            guard seq == requestSeq else { return }
            if Self.isCancellation(error) {
                // 被更新的一次请求取代，或视图已离开 —— 不提示
                return
            }
            if videoList.isEmpty {
                self.errorMessage = Self.friendlyMessage(error)
            }
            isShowingCached = false
        }
    }

    func loadMore(site: Site) async {
        guard !isLoading, !isLoadingMore else { return }
        guard currentPage < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let seq = requestSeq
        let nextPage = currentPage + 1
        let typeId = currentCategory?.typeId ?? ""
        do {
            if site.type == 3, let code = SpiderContextManager.shared.moduleCode(for: site.key) {
                let args: [String: Any] = ["id": typeId, "pg": nextPage]
                let result = await SpiderEngine.shared.execute(jsCode: code, method: "category", args: args, spiderKey: site.spiderKey)
                guard loadedSiteKey == site.key, seq == requestSeq else { return }
                let parsed = parseSpiderList(result)
                let known = Set(self.videoList.map { $0.vodId })
                let appended = parsed.list.filter { !known.contains($0.vodId) }
                self.videoList.append(contentsOf: appended)
                self.totalPages = max(self.totalPages, parsed.pageCount)
                self.currentPage = nextPage
            } else {
                let resp = try await apiService.fetchVideoList(site: site, categoryId: typeId, page: nextPage)
                guard loadedSiteKey == site.key, seq == requestSeq else { return }
                if let items = resp.list {
                    let known = Set(self.videoList.map { $0.vodId })
                    let appended = items.filter { !known.contains($0.vodId) }
                    self.videoList.append(contentsOf: appended)
                }
                self.totalPages = max(self.totalPages, resp.pagecount ?? self.totalPages)
                self.currentPage = resp.page ?? nextPage
            }
        } catch {
            if !Self.isCancellation(error) {
                print("[ContentViewModel] loadMore error: \(error.localizedDescription)")
            }
        }
    }

    /// 下拉刷新：保留当前内容 + 强制走网络
    func refresh(site: Site) async {
        loadTask?.cancel()
        await loadVideoList(site: site,
                            category: currentCategory,
                            allowCache: false,
                            preserveList: true)
    }

    // MARK: - 错误判定

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        // 部分系统版本会把 cancelled 包一层
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
        let text = ns.localizedDescription.lowercased()
        return text == "cancelled" || text == "canceled" || text.contains("已取消")
    }

    private static func friendlyMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "请求超时，换条线路试试"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "网络已断开"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "该源站无法连接，换一个站点试试"
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Spider 结果解析

    private struct SpiderListResult {
        var list: [VideoItem]
        var page: Int
        var pageCount: Int
    }

    private func parseSpiderList(_ result: [String: Any]?) -> SpiderListResult {
        guard let result = result else { return SpiderListResult(list: [], page: 1, pageCount: 1) }
        let vodList = (result["list"] as? [[String: Any]] ?? []).map { dict -> VideoItem in
            VideoItem(
                vodId: dict["vod_id"] as? String ?? "\(dict["vod_id"] ?? "")",
                vodName: dict["vod_name"] as? String ?? "",
                vodPic: dict["vod_pic"] as? String,
                vodRemarks: dict["vod_remarks"] as? String,
                vodYear: dict["vod_year"] as? String,
                vodArea: dict["vod_area"] as? String
            )
        }
        return SpiderListResult(
            list: vodList,
            page: (result["page"] as? Int) ?? 1,
            pageCount: (result["pagecount"] as? Int) ?? 1
        )
    }
}
