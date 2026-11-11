import Foundation

/// CMS / TVBox JSON 标准接口的视频 API 调用封装
///
/// 1.5.1：内置 mddcloud（type=3）站点走 MddCloudService 原生客户端分流，
/// 其余站点继续走标准 CMS `ac=` 协议。
final class APIService {
    static let shared = APIService()

    private let network = NetworkManager.shared

    private init() {}

    // MARK: - 接口

    /// 拉取分类
    /// 1.5.2 单独用 8 秒短超时：分类接口慢不该把整个首屏拖到 20 秒。
    func fetchCategories(site: Site, timeout: TimeInterval? = 8) async throws -> [VideoCategory] {
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
