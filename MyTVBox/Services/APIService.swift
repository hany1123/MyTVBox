import Foundation

/// CMS / TVBox JSON 标准接口的视频 API 调用封装
///
/// 1.5.1：内置 mddcloud（type=3）站点走 MddCloudService 原生客户端分流，
/// 1.5.4：带 bundle 的 JS Spider（type=3）站点走 SpiderEngine，
/// 1.6.0：Node 中转服务站点走 NodeRelayService（POST /spider/...），
/// 其余站点继续走标准 CMS `ac=` 协议。
final class APIService {
    static let shared = APIService()

    private let network = NetworkManager.shared

    private init() {}

    // MARK: - 接口

    /// 拉取分类
    /// 1.5.2 单独用 8 秒短超时：分类接口慢不该把整个首屏拖到 20 秒。
    func fetchCategories(site: Site, timeout: TimeInterval? = 8) async throws -> [VideoCategory] {
        if NodeRelayService.isNodeSite(site) {
            let r = try? await NodeRelayService.shared.call(
                site: site, method: "home", body: [:], timeout: timeout ?? 8)
            let resp: APIResponse? = decodeSpider(r)
            return resp?.categories ?? []
        }
        if SpiderEngine.isSpiderSite(site) {
            let r = await SpiderEngine.shared.call(site: site, method: "home", args: [:])
            let resp: APIResponse? = decodeSpider(r)
            return resp?.categories ?? []
        }
        if MddCloudService.isMddSite(site) {
            return MddCloudService.shared.categories()
        }
        guard let api = site.api, !api.isEmpty else { return [] }
        let url = appendQuery(api, params: ["ac": "class"])
        let resp: APIResponse = try await network.decode(
            APIResponse.self, from: url, timeout: timeout
        )
        return resp.categories ?? []
    }

    /// 拉取视频列表（包含分类与第一页）
    /// 注意：标准 CMS 中 `ac=list` 返回简单列表，`ac=detail` 返回详情列表，多数 TVBox 接口用 detail
    func fetchVideoList(site: Site, categoryId: String, page: Int) async throws -> APIResponse {
        if NodeRelayService.isNodeSite(site) {
            let body: [String: Any] = ["id": categoryId, "page": page, "filters": [:]]
            let r = try? await NodeRelayService.shared.call(
                site: site, method: "category", body: body)
            if let resp: APIResponse = decodeSpider(r) { return resp }
            return APIResponse(list: [])
        }
        if SpiderEngine.isSpiderSite(site) {
            let r = await SpiderEngine.shared.call(
                site: site, method: "category",
                args: ["id": categoryId, "pg": page])
            if let resp: APIResponse = decodeSpider(r) { return resp }
            return APIResponse(list: [])
        }
        if MddCloudService.isMddSite(site) {
            return try await MddCloudService.shared.videoList(categoryId: categoryId, page: page)
        }
        guard let api = site.api, !api.isEmpty else {
            throw NetworkError.invalidURL
        }
        let url = appendQuery(api, params: [
            "ac": "detail",
            "t": categoryId,
            "pg": String(page)
        ])
        return try await network.decode(APIResponse.self, from: url)
    }

    /// 拉取单个视频详情
    /// - timeout: 跨站点并发搜索时传 6 秒，避免一个慢站拖住整轮聚合
    func fetchVideoDetail(site: Site, vodId: String,
                          timeout: TimeInterval? = nil) async throws -> VideoDetail? {
        if NodeRelayService.isNodeSite(site) {
            // 1.8.2：原来是 `try?` 把 Node 侧错误吞成 nil，诊断里只看到「空响应 0ms」，
            // 分不清是「站点没数据」还是「请求根本没发出去/被拒」。改为向上抛，
            // 详情页的 catch 会把错误原文记进链路诊断。
            var dict = try await NodeRelayService.shared.call(
                site: site, method: "detail", body: ["id": vodId],
                timeout: timeout ?? 20)
            NodeRelayService.rewritePlayURLs(&dict, site: site)
            let resp: VideoDetailResponse? = decodeSpider(dict)
            return resp?.list?.first
        }
        if SpiderEngine.isSpiderSite(site) {
            let r = await SpiderEngine.shared.call(
                site: site, method: "detail", args: ["id": vodId])
            let resp: VideoDetailResponse? = decodeSpider(r)
            return resp?.list?.first
        }
        if MddCloudService.isMddSite(site) {
            return try await MddCloudService.shared.detail(vodId: vodId)
        }
        guard let api = site.api, !api.isEmpty else { return nil }
        let url = appendQuery(api, params: [
            "ac": "detail",
            "ids": vodId
        ])
        let resp: VideoDetailResponse = try await network.decode(
            VideoDetailResponse.self, from: url, timeout: timeout
        )
        return resp.list?.first
    }

    /// 关键字搜索
    func searchVideos(site: Site, keyword: String,
                      timeout: TimeInterval? = nil) async throws -> [VideoItem] {
        if NodeRelayService.isNodeSite(site) {
            let body: [String: Any] = ["wd": keyword, "page": 1]
            // 1.8.4：不再用 `try?` 吞错。以前「站点超时」和「站点没这部片」
            // 都返回空数组，CrossSiteResolver 分不清，于是坏站永远不会被拉黑，
            // 每次搜索都重新白等一次超时（这就是慢的根因）。
            let r = try await NodeRelayService.shared.call(
                site: site, method: "search", body: body,
                timeout: timeout ?? 20)
            let resp: APIResponse? = decodeSpider(r)
            return resp?.list ?? []
        }
        if SpiderEngine.isSpiderSite(site) {
            let r = await SpiderEngine.shared.call(
                site: site, method: "search", args: ["wd": keyword])
            let resp: APIResponse? = decodeSpider(r)
            return resp?.list ?? []
        }
        if MddCloudService.isMddSite(site) {
            return try await MddCloudService.shared.search(keyword: keyword)
        }
        guard let api = site.api, !api.isEmpty else { return [] }
        let url = appendQuery(api, params: [
            "ac": "detail",
            "wd": keyword
        ])
        let resp: APIResponse = try await network.decode(
            APIResponse.self, from: url, timeout: timeout
        )
        return resp.list ?? []
    }

    // MARK: - 工具

    /// 1.5.4：Spider 返回的 [String: Any] 复用现有 CMS 模型解码，
    /// 避免为 JS 站点再造一套平行数据结构。
    private func decodeSpider<T: Decodable>(_ result: [String: Any]?) -> T? {
        guard let result,
              JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result),
              let value = try? network.decodeJSON(T.self, data: data) else { return nil }
        return value
    }

    /// 在 URL 上拼接 query 参数（已转义）
    private func appendQuery(_ urlString: String, params: [String: String]) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString }
        var items = comps.queryItems ?? []
        for (k, v) in params {
            items.append(URLQueryItem(name: k, value: v))
        }
        comps.queryItems = items
        return comps.url?.absoluteString ?? urlString
    }
}
