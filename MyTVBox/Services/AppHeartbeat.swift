//
//  AppHeartbeat.swift
//  MyTVBox
//
//  1.8.14：App 级常驻心跳，补「非播放状态」的取证空窗。
//
//  1.8.11 就标记过这个盲区（BJ2），1.8.13 诊断里第二次复现：
//    21:04:20.912 完 播放 可能的爱情 正常退出     ← 播放完整 29 秒、心跳正常收尾
//    21:04:22.746 命 进入后台 → 21:04:29.116 命 回前台
//    21:04:34.481 开 详情 不可能的爱              ← 本站 detail 挂满 20 秒（Node 无 RES）
//    21:04:54.504 开 重活 跨站搜索 不可能的爱 站=16
//    21:04:56.898 启 启动                          ← 2.4 秒后进程消失
//
//  现有三套探针全部绑在特定窗口：PlaybackHeartbeat 绑播放页、SpikeProbe 绑 /play、
//  SessionTrace 只记离散事件。播放正常收尾后的 36 秒是**完全没有内存与存活证据**的，
//  判别器却拿播放期的平稳曲线去判整轮 Jetsam —— 拿错时段的证据比没有证据更危险。
//
//  设计：
//    · App 启动即开始，直到进程终止，不绑任何页面；
//    · 常态 1s 一条、重活期间自动加密到 200ms，每条**立即落盘**独立 appbeat.log；
//    · 每行带 foot/rss + 运行时状态（前台 / 播放中 / 在飞重活数 / 当前阶段）；
//    · 事件行 E 直接写进同一文件，崩溃前 10 秒的轨迹不用跨文件对齐；
//    · 按 === boot === 切窗口，诊断读「倒数第二个窗口」= 崩溃轮。
//

import Foundation

/// 轻量运行时状态。只存在内存里，由 App 级心跳每周期读取，不写偏好设置（避免高频落盘）。
final class AppRuntimeState {
    static let shared = AppRuntimeState()

    private let lock = NSLock()
    private var foreground = true
    private var playing = false
    private var work = 0
    private var stage = "home"

    func set(foreground v: Bool) { lock.lock(); foreground = v; lock.unlock() }
    func set(playing v: Bool) { lock.lock(); playing = v; lock.unlock() }
    func set(stage v: String) { lock.lock(); stage = v; lock.unlock() }
    func beginWork() { lock.lock(); work += 1; lock.unlock() }
    func endWork() { lock.lock(); work = max(0, work - 1); lock.unlock() }

    func snapshot() -> (fg: Bool, play: Bool, work: Int, stage: String) {
        lock.lock(); defer { lock.unlock() }
        return (foreground, playing, work, stage)
    }
}

final class AppHeartbeat {

    static let shared = AppHeartbeat()

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    /// 重活期间加密到 200ms；常态 1s。用普通变量 + lock，避免再引一个 actor。
    private var fast = false

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var logURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyTVBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("appbeat.log")
    }

    private func stamp() -> String { fmt.string(from: Date()) }

    /// 启动分界线。boot 之后的内容属于本轮，之前那一轮即崩溃轮。
    func boot() {
        lock.lock(); defer { lock.unlock() }
        let url = logURL
        var lines = readLocked(url)
        // 1s 一条、重活期 200ms，20 分钟约 2000 行；滞后裁剪避免文件无限增长
        if lines.count > 2400 { lines = Array(lines.suffix(2400)) }
        lines.append("=== boot === " + stamp())
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func start() {
        lock.lock()
        if task != nil { lock.unlock(); return }
        lock.unlock()
        append("START appbeat " + sampleText())
        let t0 = Date()
        task = Task.detached { [weak self] in
            var n = 0
            while !Task.isCancelled {
                let interval: UInt64 = (self?.isFast() ?? false)
                    ? 200_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                n += 1
                let sec = Int(Date().timeIntervalSince(t0))
                if n % 10 == 0 { _ = MemoryProbe.record() }  // 顺带维护历史峰值
                self.append("B t=\(sec)s " + self.lineText())
            }
        }
    }

    /// 整站级重活开始/结束时切换采样密度。
    func setFast(_ on: Bool) {
        lock.lock(); fast = on; lock.unlock()
    }

    private func isFast() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fast
    }

    /// 事件行。事件发生时同步写一条内存读数，判读时不用来回对齐两个日志的时间戳。
    func mark(_ text: String) {
        append("E " + text + " · " + lineText())
    }

    private func sampleText() -> String {
        "foot=\(MemoryProbe.footprintMB())MB rss=\(MemoryProbe.residentMB())MB"
    }

    private func lineText() -> String {
        let s = AppRuntimeState.shared.snapshot()
        return sampleText()
            + " fg=\(s.fg ? 1 : 0) play=\(s.play ? 1 : 0)"
            + " work=\(s.work) stage=\(s.stage)"
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

    private func readLocked(_ url: URL) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// 每个 === boot === 对应一个窗口；最后一个是本次启动后，倒数第二个是崩溃轮。
    func windows() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        var result: [[String]] = [[]]
        for line in readLocked(logURL) {
            if line.hasPrefix("=== boot ===") {
                result.append([])
            } else {
                result[result.count - 1].append(line)
            }
        }
        return result
    }

    func previousWindow() -> [String] {
        let w = windows()
        return w.count >= 2 ? w[w.count - 2] : []
    }

    func currentWindow() -> [String] { windows().last ?? [] }

    /// 从 B/E/START 行里抽 foot 数值（MB）
    static func footValues(_ lines: [String]) -> [Int] {
        lines.compactMap { line in
            guard let r = line.range(of: "foot=") else { return nil }
            let digits = line[r.upperBound...].prefix(while: { $0.isNumber })
            guard let v = Int(digits), v > 0 else { return nil }
            return v
        }
    }
}
