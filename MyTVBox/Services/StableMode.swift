import Foundation

// MARK: - 稳定模式（1.8.15）
//
// 全盘复盘的结论：反复闪退不是某一个 URL / 站点 / 内存尖峰的 bug，而是
// 「端上 Node + 自动跨站聚合 + AVPlayer」挤在同一个 iOS 进程里抢资源。
// 1.8.5~1.8.14 补了十轮探针，看得越来越清，但没动这个架构前提。
//
// 稳定模式是「止血」不是「根治」：不再让任何静默重活与播放并发。
// 根治方向是把 Node 移出 App 进程（外部中转），见交付说明。
//
// 默认开启；关掉即回到 1.8.14 的完整聚合行为。
// 设置页用 @AppStorage 读写同一个 key，Swift 逻辑层读 enabled。

final class StableMode {

    static let shared = StableMode()

    /// 与设置页 @AppStorage 共用的偏好设置键
    static let defaultsKey = "MyTVBox.stableMode"

    var enabled: Bool {
        (UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool) ?? true
    }

    /// 聚合搜索同时最多打几个站（完整模式 12）
    var searchConcurrency: Int { enabled ? 2 : 12 }

    /// 聚合搜索最多覆盖几个站（完整模式 60）
    var maxSites: Int { enabled ? 8 : 60 }

    /// 聚合搜索总时间预算（秒）
    var searchBudget: TimeInterval { enabled ? 10 : 14 }

    /// 单站 / 总结果上限：海报位图是内存大头
    var limitPerSite: Int { enabled ? 8 : 12 }
    var limitTotal: Int { enabled ? 40 : 120 }

    /// 详情拿不到线路时，是否静默去其它站「接管」（两轮 16/60 站）
    var allowDetailAdoption: Bool { !enabled }

    /// 详情展示后，是否后台再拉一轮跨站线路
    var allowCrossSiteLines: Bool { !enabled }

    /// 播放线路耗尽时，是否去其它站搜同名片续播
    var allowCrossSiteFallback: Bool { !enabled }

    /// 失败 / 卡顿时是否自动换线路（含同片多线路）
    var allowAutoSwitch: Bool { !enabled }

    /// 起播前等待在飞请求收口的超时（秒）。到点照常起播，不能把用户卡死。
    var drainTimeout: TimeInterval { 2.5 }

    /// 诊断页展示用
    var summary: String {
        enabled
            ? "开 · 并发 \(searchConcurrency) / 站 \(maxSites) / 起播前收口 / 禁自动换源"
            : "关 · 完整聚合（1.8.14 行为）"
    }
}
