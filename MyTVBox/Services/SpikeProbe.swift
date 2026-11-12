//
//  SpikeProbe.swift
//  MyTVBox
//
//  1.8.13：/play 取流窗口内的 100ms 高频进程内存采样。
//
//  为什么不能用现有的 PlaybackHeartbeat：
//    1.8.12 诊断显示 foot 111→110MB「平稳」、signal 0 次、无 FATAL、无内存警告，
//    但进程仍死在「/play 请求在飞」时。这不代表 Jetsam 被排除 ——
//    Node 的 fetch shim 用 Buffer.concat + zlib.*Sync 一次性展开响应体，
//    可以在**亚秒级**把 phys_footprint 推高几百 MB，随即被 Jetsam 以 SIGKILL 干掉。
//    1 秒一条的心跳只会看到「崩前最后一个采样点」，尖峰整个落在采样间隙里。
//
//  设计要点：
//    · 独立 spike.log，不写 breadcrumb.log（避免挤爆 240 行窗口）；
//    · 每条采样**立即落盘**，进程被 SIGKILL 也不会丢；
//    · 只在 /play 取流窗口内采样，不产生常驻开销；
//    · 没有 END 行的窗口 = 进程在窗口内消失，就是崩溃现场。
//

import Foundation

final class SpikeProbe {

    struct Window {
        let label: String
        let startLine: String
        let foots: [Int]
        let rss: [Int]
        let ended: Bool

        var peak: Int { foots.max() ?? 0 }
        var first: Int { foots.first ?? 0 }
        var last: Int { foots.last ?? 0 }
        var samples: Int { foots.count }

        /// 相邻两次采样之间的最大单次跃升（MB）。100ms 内涨 80MB 就是尖峰铁证。
        var maxJump: Int {
            guard foots.count > 1 else { return 0 }
            var m = 0
            for i in 1..<foots.count { m = max(m, foots[i] - foots[i - 1]) }
            return m
        }

        var describe: String {
            guard samples > 0 else { return "无采样" }
            return "foot \(first)→\(last)MB（峰值 \(peak)MB · 单次最大跃升 +\(maxJump)MB/100ms）"
                + " · rss \(rss.first ?? 0)→\(rss.last ?? 0)MB"
                + " · \(samples) 个样本 · " + (ended ? "**正常结束**" : "**无 END（进程在窗口内消失）**")
        }
    }

    static let shared = SpikeProbe()

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var active = false

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var logURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyTVBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spike.log")
    }

    private func stamp() -> String { fmt.string(from: Date()) }

    /// App 启动分界线。boot 会打断上一轮未收尾的窗口，这正是「崩溃轮」的标记。
    func boot() {
        lock.lock(); defer { lock.unlock() }
        let url = logURL
        var lines = readLinesLocked(url)
        if lines.count > 3000 { lines = Array(lines.suffix(3000)) }
        lines.append("=== boot === " + stamp())
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 进入 /play 取流窗口。重复调用不会叠加采样任务。
    func start(_ label: String) {
        lock.lock()
        if active { lock.unlock(); return }
        active = true
        task?.cancel()
        lock.unlock()

        append("START " + label + " " + sampleText())
        let t0 = Date()
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                self.append("S t=\(ms) " + self.sampleText())
            }
        }
    }

    /// 离开 /play 取流窗口。写 END 是「活着走出来」的唯一凭据。
    func stop(_ label: String) {
        lock.lock()
        let wasActive = active
        active = false
        task?.cancel()
        task = nil
        lock.unlock()
        if wasActive { append("END " + label + " " + sampleText()) }
    }

    private func sampleText() -> String {
        // 不调 MemoryProbe.record()：100ms 一次写 UserDefaults 开销太大，这里纯读即可
        "foot=\(MemoryProbe.footprintMB())MB rss=\(MemoryProbe.residentMB())MB"
    }

    private func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let line = stamp() + " " + text + "\n"
        let url = logURL
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }

    // MARK: - 读取（供诊断）

    private func readLinesLocked(_ url: URL) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// 按 START / END / boot 切出所有窗口。boot 或新 START 打断的窗口记为 ended=false。
    func windows() -> [Window] {
        lock.lock(); defer { lock.unlock() }
        let lines = readLinesLocked(logURL)
        var result: [Window] = []
        var label = ""
        var startLine = ""
        var foots: [Int] = []
        var rss: [Int] = []
        var inWindow = false

        func flush(_ ended: Bool) {
            if inWindow {
                result.append(Window(label: label, startLine: startLine,
                                     foots: foots, rss: rss, ended: ended))
            }
            inWindow = false
            foots = []
            rss = []
        }

        for line in lines {
            if line.hasPrefix("=== boot ===") {
                flush(false)
                continue
            }
            if line.contains(" START ") {
                flush(false)
                let rest = line.components(separatedBy: " START ").dropFirst().joined(separator: " START ")
                label = String(rest.prefix(while: { $0 != " " }))
                startLine = line
                inWindow = true
                if let f = SpikeProbe.mb(line, key: "foot=") { foots.append(f) }
                if let r = SpikeProbe.mb(line, key: "rss=") { rss.append(r) }
                continue
            }
            guard inWindow else { continue }
            if let f = SpikeProbe.mb(line, key: "foot=") { foots.append(f) }
            if let r = SpikeProbe.mb(line, key: "rss=") { rss.append(r) }
            if line.contains(" END ") {
                flush(true)
            }
        }
        flush(false)
        return result
    }

    /// 最近若干个窗口，供诊断并列展示（避免被本轮一次正常播放盖掉首轮崩溃现场）。
    func recentWindows(_ n: Int = 2) -> [Window] {
        Array(windows().suffix(n))
    }

    private static func mb(_ line: String, key: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        let digits = line[r.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits)
    }
}
