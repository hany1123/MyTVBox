//
//  SiteHealth.swift
//  MyTVBox
//
//  站点健康度记忆：连续失败 3 次的站冷却 10 分钟，搜索直接跳过；成功一次清零。
//  1.8.18：额外记每个站成功响应的耗时（指数移动平均），聚合搜索据此做
//  「快站优先」调度 —— 先出结果的站点先上屏，不必等齐所有站。
//

import Foundation

final class SiteHealth {

    static let shared = SiteHealth()

    private struct Rec: Codable {
        var fails: Int = 0
        var successes: Int = 0
        var lastFail: TimeInterval = 0
        var lastReason: String? = nil
        /// 成功响应耗时的指数移动平均（毫秒）；0 = 还没有样本
        var emaMs: Double = 0
    }

    struct CoolingDetail {
        let key: String
        let fails: Int
        let reason: String
    }

    private let lock = NSLock()
    private var table: [String: Rec] = [:]
    private var dirty = false
    private let storeKey = "MyTVBox.siteHealth.v1"
    private let failThreshold = 3
    private let cooldown: TimeInterval = 10 * 60

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([String: Rec].self, from: data) {
            table = saved
        }
    }

    /// 这个站现在是不是该跳过（连续失败且还在冷却窗口内）
    func isCooling(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let r = table[key], r.fails >= failThreshold else { return false }
        return Date().timeIntervalSince1970 - r.lastFail < cooldown
    }

    /// ok = 拿到了响应（哪怕 0 条）；false = 抛错/超时
    /// - Parameter latency: 本次请求耗时（秒），成功的样本才计入速度排序
    func note(_ key: String, ok: Bool, reason: String? = nil,
              latency: TimeInterval? = nil) {
        lock.lock()
        var r = table[key] ?? Rec()
        if ok {
            r.fails = 0
            r.successes += 1
            r.lastReason = nil
            if let sec = latency, sec > 0 {
                let ms = sec * 1000
                r.emaMs = r.emaMs <= 0 ? ms : r.emaMs * 0.7 + ms * 0.3
            }
        } else {
            r.fails += 1
            r.lastFail = Date().timeIntervalSince1970
            if let reason, !reason.isEmpty {
                r.lastReason = String(reason.prefix(120))
            }
        }
        table[key] = r
        dirty = true
        lock.unlock()
    }

    /// 历史响应耗时（毫秒）；0 表示还没有样本，调度时按中等速度处理
    func latencyMs(_ key: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        return table[key]?.emaMs ?? 0
    }

    /// 一次搜索结束后统一落盘，避免 60 个站各写一次 UserDefaults
    func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = table
        dirty = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    func coolingKeys() -> [String] {
        coolingDetails().map { $0.key }
    }

    func coolingDetails() -> [CoolingDetail] {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        return table.filter { $0.value.fails >= failThreshold && now - $0.value.lastFail < cooldown }
            .map { CoolingDetail(key: $0.key,
                                 fails: $0.value.fails,
                                 reason: $0.value.lastReason ?? "(旧记录无错误文本)") }
            .sorted { $0.key < $1.key }
    }

    func reset() {
        lock.lock()
        table.removeAll()
        dirty = true
        lock.unlock()
        flush()
    }
}
