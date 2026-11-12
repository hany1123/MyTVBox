//
//  SiteHealth.swift
//  MyTVBox
//
//  1.8.4：站点健康度记忆。
//
//  老大的问题「搜索慢是不是某些站点没加载导致的」—— 是的。
//  猫爪源 110 个站里有一批是坏站/慢站（上游挂了、要解析、参数对不上），
//  每个都要等到超时才返回。旧实现按固定 12 个一批，一批里只要混进一个坏站，
//  整批就得等满超时；5 批下来 25 秒，和真机实测 23.3 秒完全吻合。
//  更糟的是每搜一次都要重新撞一遍这些坏站，完全没有记忆。
//
//  这里只记「抛错/超时」，不记「正常返回空结果」（那只是没这部片，站是好的）。
//  连续失败 3 次的站冷却 10 分钟，期间搜索直接跳过；成功一次立刻清零。
//
//  1.8.7：只列「哪些站被冷却」不够判断原因 —— 1.8.6 诊断里冷却站从 6 个涨到
//  20 个，但看不出是站点自己挂了、超时，还是端上 fetch 兼容层没覆盖到。
//  现在把最后一次错误文本一起存下来，诊断里直接列出「站 + 失败次数 + 原因」。
//

import Foundation

final class SiteHealth {

    static let shared = SiteHealth()

    private struct Rec: Codable {
        var fails: Int = 0
        var successes: Int = 0
        var lastFail: TimeInterval = 0
        /// 1.8.7：最后一次失败的错误文本。用 Optional，旧版 UserDefaults
        /// 里没有这个 key 的记录也能正常解码，不会让整张表失效。
        var lastReason: String? = nil
    }

    /// 给诊断看的一条冷却记录
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
    /// - Parameter reason: 失败时的错误文本（只留前 120 字），成功时忽略
    func note(_ key: String, ok: Bool, reason: String? = nil) {
        lock.lock()
        var r = table[key] ?? Rec()
        if ok {
            r.fails = 0
            r.successes += 1
            r.lastReason = nil
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

    /// 给诊断看：当前冷却中的站点
    func coolingKeys() -> [String] {
        coolingDetails().map { $0.key }
    }

    /// 1.8.7：带失败原因，能区分「站点超时」「上游 404」「端上 fetch 报错」
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
