//
//  LocalSourceCache.swift
//  MyTVBox
//
//  1.7.8：本机源（127.0.0.1 的 /config）的配置缓存 + 加载自述。
//
//  为什么需要它：
//  设备上跑 Node 时，源第一次生成 /config 需要现解站点配置（解释执行，比本地慢
//  一到两个数量级）。实测现象是「打开 App 转很久圈，最后报『加载失败』」——
//  客户端 20 秒超时 + 后面还会再打一轮 relay/备选路径，等于把一次慢请求放大成
//  好几分钟。
//
//  两个动作：
//  1. 每次成功拿到 /config 就存一份原始 JSON；加载失败时退回这份缓存，
//     界面至少不是空的（并在诊断里标出来）。
//  2. 记下最近一次加载的耗时/字节/错误（`lastProbe`），诊断里能直接看到
//     「到底是超时还是 500」，不用再猜。
//

import Foundation

enum LocalSourceCache {

    private static let lock = NSLock()

    private static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("MyTVBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var cacheFile: URL { dir.appendingPathComponent("local-config.json") }
    private static var metaFile: URL { dir.appendingPathComponent("local-config.meta") }

    /// 最近一次加载的自述（成功/失败 + 耗时 + 字节）
    private static var _lastProbe: String = "（本次运行还没有请求过）"

    static var lastProbe: String {
        lock.lock(); defer { lock.unlock() }
        return _lastProbe
    }

    static func note(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _lastProbe = text
    }

    // MARK: - 缓存读写

    static func save(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: cacheFile, options: .atomic)
        let stamp = "\(Date().timeIntervalSince1970)"
        try? stamp.data(using: .utf8)?.write(to: metaFile, options: .atomic)
    }

    /// 缓存年龄（秒）；没有缓存返回 nil
    static func age() -> TimeInterval? {
        guard let s = try? String(contentsOf: metaFile, encoding: .utf8),
              let t = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              t > 0 else { return nil }
        return Date().timeIntervalSince1970 - t
    }

    /// 取缓存内容；`maxAge` 为 nil 表示不限新鲜度
    static func data(maxAge: TimeInterval? = nil) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: cacheFile), !d.isEmpty else { return nil }
        if let maxAge {
            guard let a = ageRaw(), a <= maxAge else { return nil }
        }
        return d
    }

    private static func ageRaw() -> TimeInterval? {
        guard let s = try? String(contentsOf: metaFile, encoding: .utf8),
              let t = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              t > 0 else { return nil }
        return Date().timeIntervalSince1970 - t
    }

    /// 人读的缓存状态，给诊断用
    static func describe() -> String {
        guard let d = data(), let a = age() else { return "无缓存" }
        let mins = Int(a / 60)
        let ageText = mins < 1 ? "刚刚" : (mins < 60 ? "\(mins) 分钟前" : "\(mins / 60) 小时前")
        return "\(d.count) 字节 · \(ageText)"
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: cacheFile)
        try? FileManager.default.removeItem(at: metaFile)
    }
}
