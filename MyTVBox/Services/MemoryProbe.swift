//
//  MemoryProbe.swift
//  MyTVBox
//
//  1.8.5：播放中稳定闪退两次（都在「首帧就绪」后约 10 秒），无 crash.log、
//  无内存警告。老大要求「不要靠猜，把可能原因都列进去，全面排查」。
//
//  进程消失至少有 6 类原因，光看 RSS 只能覆盖其中一类。这里做**双心跳**：
//    · 主线程每 1 秒只更新一个时间戳（不写日志）
//    · 后台每 3 秒写一行面包屑，同时读出「主线程多久没动过」+ 进程 RSS
//  于是：
//    · 后台心跳继续、主线程时间戳停摆 → 主线程卡死 → watchdog(0x8badf00d)
//    · 两条线同时停 → 进程被杀，再看 RSS 曲线区分 Jetsam / V8 abort
//    · RSS 平稳但进程没了 → 转查 AVFoundation / 生命周期 / Node abort
//

import Foundation
import Darwin

enum MemoryProbe {

    private static let peakKey = "MyTVBox.memPeakMB"

    /// App 进程常驻内存（MB），含端上 Node 的 V8 堆、AVPlayer 缓冲、图片位图。
    /// 0 = 读取失败
    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { out in
                // mach_task_self() 是 C 宏，Swift 里要用同名的全局变量 mach_task_self_
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), out, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }

    /// 记一次并更新历史峰值；返回当前值
    @discardableResult
    static func record() -> Int {
        let mb = residentMB()
        if mb > UserDefaults.standard.integer(forKey: peakKey) {
            UserDefaults.standard.set(mb, forKey: peakKey)
        }
        return mb
    }

    static func peakMB() -> Int {
        max(residentMB(), UserDefaults.standard.integer(forKey: peakKey))
    }

    static func summary() -> String {
        "\(residentMB()) MB（历史峰值 \(peakMB()) MB）"
    }

    static func resetPeak() {
        UserDefaults.standard.set(0, forKey: peakKey)
    }
}

/// 播放页双心跳。写进 breadcrumb.log，进程被直接干掉时这些行还留在磁盘上。
final class PlaybackHeartbeat {

    static let shared = PlaybackHeartbeat()

    private let lock = NSLock()
    private var mainTask: Task<Void, Never>?
    private var bgTask: Task<Void, Never>?
    /// 主线程最后一次「我还活着」的时间；由后台心跳读取
    private var lastMainTick: Date?
    private var label: String = ""

    func start(_ title: String) {
        stop()
        label = title
        let t0 = Date()
        let first = MemoryProbe.record()
        lock.lock()
        lastMainTick = Date()
        lock.unlock()
        SessionTrace.mark("跳 播放 \(title) t=0 rss=\(first)MB 主=OK")

        // 主线程探针：只更新时间戳，不写文件（避免日志被刷爆）
        mainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.touchMain()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // 后台探针：即使主线程卡死也继续写，这是区分 watchdog 的关键
        bgTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let sec = Int(Date().timeIntervalSince(t0))
                let rss = MemoryProbe.record()
                let gap = self.mainLag()
                let state = gap > 2.5
                    ? String(format: "主=卡%.1fs", gap)
                    : "主=OK"
                SessionTrace.mark("跳 播放 t=\(sec)s rss=\(rss)MB \(state)")
            }
        }
    }

    func stop() {
        lock.lock()
        mainTask?.cancel(); mainTask = nil
        bgTask?.cancel(); bgTask = nil
        lastMainTick = nil
        lock.unlock()
    }

    private func touchMain() {
        lock.lock(); lastMainTick = Date(); lock.unlock()
    }

    private func mainLag() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let t = lastMainTick else { return 0 }
        return Date().timeIntervalSince(t)
    }
}
