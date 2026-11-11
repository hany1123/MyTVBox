import Foundation

/// 内置源：不依赖任何外部订阅地址，开箱即可播放
///
/// iOS 版没有 JVM，无法执行 type 3 的 JAR 爬虫（`csp_` 系列）。
/// 下面 16 个站点全部是实测可用的标准 JSON CMS 接口：
///   - 首页 / 分类 / 搜索逐站验证过
///   - 详情首选线路全部是 m3u8 直链（非网盘、非网页分享页）
/// 多站点并存是为了：某条线路挂掉时可以在 SWITCH 里换站点，
/// 播放页也会在同一部片的多个 vod_play_from 线路之间自动切换。
enum BuiltinSources {

    /// 内置源使用的伪协议，网络层不会真的去请求它
    static let scheme = "builtin://"
    static let defaultURL = "builtin://ios"

    static func isBuiltin(_ url: String) -> Bool {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix(scheme)
    }

    /// 构造内置配置
    static func config() -> TVBoxConfig {
        let sites: [Site] = [
            Site(key: "bfzy", name: "暴风资源",
                 type: 1, api: "https://bfzyapi.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "lzzy", name: "量子资源",
                 type: 1, api: "https://cj.lziapi.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "snzy", name: "索尼采集",
                 type: 1, api: "https://suoniapi.com/api.php/provide/vod",
                 searchable: 0, quickSearch: 0, filterable: 1),
            Site(key: "sdzy", name: "闪电资源",
                 type: 1, api: "http://sdzyapi.com/api.php/provide/vod",
                 searchable: 0, quickSearch: 0, filterable: 1),
            Site(key: "xlzy", name: "新浪资源",
                 type: 1, api: "http://api.xinlangapi.com/xinlangapi.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "gszy", name: "光速资源",
                 type: 1, api: "https://api.guangsuapi.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "hhzy", name: "火狐采集",
                 type: 1, api: "https://hhzyapi.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "hyzy", name: "虎牙采集",
                 type: 1, api: "https://www.huyaapi.com/api.php/provide/vod/from/hym3u8",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "jszy", name: "极速资源",
                 type: 1, api: "https://jszyapi.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "ffzy", name: "非凡影视",
                 type: 1, api: "http://cj.ffzyapi.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "ffzy2", name: "非凡直连",
                 type: 1, api: "http://ffzy.tv/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "dytt", name: "电影天堂",
                 type: 1, api: "http://caiji.dyttzyapi.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "tyys", name: "天涯影视",
                 type: 1, api: "http://tyyszy.com/api.php/provide/vod",
                 searchable: 0, quickSearch: 0, filterable: 1),
            Site(key: "lzzy2", name: "量子备用",
                 type: 1, api: "https://lzizy1.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "bdzy", name: "百度采集",
                 type: 1, api: "https://api.apibdzy.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),
            Site(key: "tpzy", name: "淘片采集",
                 type: 1, api: "https://taopianapi.com/cjapi/mc/vod/json.html",
                 searchable: 1, quickSearch: 1, filterable: 1),
            // 1.5.1：真机明文里挖到的 mddcloud 源，走 Swift 原生签名客户端。
            // type=3 只放行这一个已实现的站点（见 ConfigService）。
            Site(key: "mddcloud", name: "mdd云·剧集",
                 type: 3, api: MddCloudService.siteScheme,
                 searchable: 1, quickSearch: 1, filterable: 0,
                 categories: ["剧集", "电影", "综艺"]),
        ]

        let lives: [LiveSource] = [
            LiveSource(name: "IPTV 综合",
                       type: 0,
                       url: "https://gh-proxy.com/https://raw.githubusercontent.com/Kimentanm/aptv/master/m3u/iptv.m3u"),
        ]

        // 1.5.1：真机实测可用的解析规则（内置兜底，用户没配订阅也能用）。
        // type=1 = 直接 GET 接口并解析 JSON 里的 url；play_keys = 线路名路由。
        let parses: [ParseRule] = [
            ParseRule(name: "非凡去广告", type: 1,
                      url: "https://api.hxmp4.com/api/parsing.Fjx/index?url=",
                      playKeys: ["ffm3u8"]),
            ParseRule(name: "优质去广告解析", type: 1,
                      url: "https://api.hxmp4.com/api/parsing.Yzjx/index?url=",
                      playKeys: ["1080zyk"]),
            ParseRule(name: "人人视频解析", type: 1,
                      url: "https://parsing.hxmp4.com/api/parsing.Rrmj/index?url=",
                      playKeys: ["selfrrmj"]),
            ParseRule(name: "毒舌电影", type: 1,
                      url: "https://parsing.hxmp4.com/api/parsing.Dushe/index?url=",
                      playKeys: ["selfdushe"]),
        ]

        // 需要走解析的线路标识（标准 TVBox 语义；MyTVBox 用 play_keys 精确路由）
        let flags: [String] = ["ffm3u8", "1080zyk", "selfrrmj", "selfdushe"]

        return TVBoxConfig(spider: nil, sites: sites, lives: lives,
                           parses: parses, flags: flags, ijk: nil)
    }
}
