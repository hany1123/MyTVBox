import Foundation

/// 内置源：不依赖任何外部订阅地址，开箱即可播放
///
/// iOS 版没有 JVM，无法执行 type 3 的 JAR 爬虫（`csp_` 系列）。
/// 这里内置的是从常用接口里筛出来的、能被本端直接执行的部分：
/// CMS 标准接口（type 1）与 JS 接口（type 4），外加两组直播源。
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
            // 苹果 CMS 标准接口，分类 / 详情 / 搜索都走 ?ac= 协议
            Site(key: "ffzy", name: "非凡影视",
                 type: 1,
                 api: "http://cj.ffzyapi.com/api.php/provide/vod",
                 searchable: 1, quickSearch: 1, filterable: 1),

            // JS 接口：网盘资源搜索
            Site(key: "pansou", name: "网盘搜索",
                 type: 4,
                 api: "http://so.yinpai.xyz/wanpan.php?type=quark|uc|baidu|tianyi|xunlei|123",
                 searchable: 1, quickSearch: 1, filterable: 0),

            // JS 接口：短剧
            Site(key: "duanju", name: "全网短剧",
                 type: 4,
                 api: "http://38.76.197.172:15151/duanju.php?type=dquark",
                 searchable: 1, quickSearch: 1, filterable: 0),
        ]

        let lives: [LiveSource] = [
            LiveSource(name: "IPTV 综合",
                       type: 0,
                       url: "https://down.nigx.cn/raw.githubusercontent.com/Kimentanm/aptv/master/m3u/iptv.m3u"),
            LiveSource(name: "直播备用",
                       type: 0,
                       url: "http://193.123.86.190:14888/TV/iptv.php"),
        ]

        return TVBoxConfig(spider: nil, sites: sites, lives: lives,
                           parses: nil, flags: nil, ijk: nil)
    }
}
