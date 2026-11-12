//
//  MemoryProbe.swift
//  MyTVBox
//
//  1.8.5：播放中稳定闪退两次（都在「首帧就绪」后约 10 秒），无 crash.log、
//  无内存警告。老大要求「不要靠猜，把可能原因都列进去，全面排查」。
//
//  进程消失至少有 6 类原因。这里做**双心跳**：
//    · 主线程每 1 秒只更新一个时间戳（不写日志）
//    · 后台写一行面包屑，同时读出「主线程多久没动过」+ 两个内存指标
//      1.8.12 起：起播前 10 秒每 1 秒一条，之后每 2 秒一条
//  于是：
//    · 后台心跳继续、主线程时间戳停摆 → 主线程卡死 → watchdog(0x8badf00d)
//    · 两条线同时停 → 进程被杀，再看内存曲线区分 Jetsam / V8 abort
//
//  1.8.9 关键补充：**只看 RSS 会漏判 Jetsam**。
//  iOS 的 Jetsam 依据 phys_footprint 杀进程，而 AVPlayer 的硬件解码缓冲 /
//  IOSurface / IOKit 映射不计入 mach_task_basic_info.resident_size。
//  1.8.8 诊断里 RSS 179→202MB「平稳」，进程却在首帧后 6 秒消失 ——
//  完全可能是视频侧内存只在 phys_footprint 上体现。两个指标必须一起记。
//

import Foundation
import Darwin

enum MemoryProbe {

    private static let peakKey = "MyTVBox.memPeakMB"
    private static let footPeakKey = "MyTVBox.memFootPeakMB"

    /// App 进程常驻内存（MB），含端上 Node 的 V8 堆、AVPlayer 的用户态缓冲、图片位图。
    /// **不含** IOSurface / IOKit 视频解码映射 —— 这正是 Jetsam 判据与 RSS 的差异。
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

    /// 1.8.9：Jetsam 真正看的指标（task_vm_info.phys_footprint，MB）。
    /// 包含压缩内存、IOSurface、IOKit 映射等 RSS 统计不到的部分。
    /// 0 = 读取失败
    static func footprintMB() -> Int {
        var info = task_vm_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { out in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), out, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// 记一次并更新两个历史峰值；返回当前 RSS
    @discardableResult
    static func record() -> Int {
        let mb = residentMB()
        let foot = footprintMB()
        if mb > UserDefaults.standard.integer(forKey: peakKey) {
            UserDefaults.standard.set(mb, forKey: peakKey)
        }
        if foot > UserDefaults.standard.integer(forKey: footPeakKey) {
            UserDefaults.standard.set(foot, forKey: footPeakKey)
        }
        return mb
    }

    static func peakMB() -> Int {
        max(residentMB(), UserDefaults.standard.integer(forKey: peakKey))
    }

    static func footprintPeakMB() -> Int {
        max(footprintMB(), UserDefaults.standard.integer(forKey: footPeakKey))
    }

    static func summary() -> String {
        let rss = residentMB()
        let foot = footprintMB()
        // task_vm_info 读取失败会返回 0，不能显示成「phys_footprint 0 MB」误导判读
        let footText = foot > 0 ? "\(foot) MB" : "读取失败"
        return "\(rss) MB · phys_footprint \(footText)"
            + "（峰值 \(peakMB()) / \(footprintPeakMB()) MB）"
    }

    static func resetPeak() {
        UserDefaults.standard.set(0, forKey: peakKey)
        UserDefaults.standard.set(0, forKey: footPeakKey)
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
        let firstFoot = MemoryProbe.footprintMB()
        lock.lock()
        lastMainTick = Date()
        lock.unlock()
        SessionTrace.mark("跳 播放 \(title) t=0 rss=\(first)MB foot=\(firstFoot)MB 主=OK")

        // 主线程探针：只更新时间戳，不写文件（避免日志被刷爆）
        mainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.touchMain()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // 后台探针：即使主线程卡死也继续写，这是区分 watchdog 的关键。
        // 1.8.9：3s → 2s。1.8.12：**起播前 10 秒再加密到 1s**。
        // AVAsset 装载窗口就是崩溃高发段，1.8.11 只拿到 t=0/t=2s 两个点，
        // 曲线一被截断，判别器既看不到峰值也无法算增速。
        // 240 行日志窗口复核：前 10s 10 条 + 之后每 2s 一条 ≈ 覆盖 7 分钟播放，仍够。
        bgTask = Task.detached { [weak self] in
            var interval: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                let sec = Int(Date().timeIntervalSince(t0))
                let rss = MemoryProbe.record()
                let foot = MemoryProbe.footprintMB()
                let gap = self.mainLag()
                let state = gap > 2.5
                    ? String(format: "主=卡%.1fs", gap)
                    : "主=OK"
                SessionTrace.mark("跳 播放 t=\(sec)s rss=\(rss)MB foot=\(foot)MB \(state)")
                interval = sec < 10 ? 1_000_000_000 : 2_000_000_000
            }
        }
    }

    func stop() {
        lock.lock()
        // 1.8.10：区分「心跳主动停」与「进程直接没了」。
        // 诊断里若没有这条「完 心跳」，就说明末条心跳之后进程被杀，
        // 而不是播放器视图被拆导致心跳正常收尾。
        let wasRunning = mainTask != nil || bgTask != nil
        mainTask?.cancel(); mainTask = nil
        bgTask?.cancel(); bgTask = nil
        lastMainTick = nil
        lock.unlock()
        if wasRunning {
            SessionTrace.mark("完 心跳 主动停止（播放页消失 / 视图重建）")
        }
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
