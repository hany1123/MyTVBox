//
//  CrashDiagnostic.swift
//  MyTVBox
//
//  1.8.5：老大要求「不要靠猜，把可能导致的原因列进去，全面排查」。
//  iOS 上 App 进程消失至少 6 类原因，各有不同的可观测指纹。这里把每一类的
//  **证据现状**逐条列进诊断，而不是先验地押一个结论：
//
//   1 Jetsam(内存)      RSS 曲线 / 内存警告次数 / 心跳中断点
//   2 Watchdog(主线程)  后台心跳仍在但主线程时间戳停摆（0x8badf00d）
//   3 Node V8 abort     node.log 里 FATAL / Reached heap limit / EXIT code
//   4 AVFoundation      「败 播放」/ item 失败通知
//   5 NSException       CrashGuard 的 crash.log
//   6 生命周期/主动退出  「命 进入后台 / 即将终止 / 回前台」
//
//  证据不足时明确写「未观测到」，不替用户下结论。
//

import Foundation

enum CrashDiagnostic {

    static func lines() -> [String] {
        let prev = SessionTrace.previousTail(40)
        let nodeLog = NodeRuntime.shared.tailLog(lines: 40)
        let crashLog = CrashGuard.lastReport()

        let beats = prev.filter { $0.contains("跳 播放") }
        let rssList = beats.compactMap { rssMB(from: $0) }
        let warns = prev.filter { $0.contains("警 ") }
        let mainStall = beats.filter { $0.contains("主=卡") }
        let playerFails = prev.filter { $0.contains("败 播放") }
        let life = prev.filter { $0.contains("命 ") }

        let fatal = nodeLog.contains("FATAL ERROR")
            || nodeLog.contains("Reached heap limit")
            || nodeLog.contains("FATAL uncaught")
            || nodeLog.contains("FATAL unhandled")
        let nodeExit = nodeLog.contains("EXIT code=")
        let nodeMemLines = nodeLog.split(separator: "\n")
            .filter { $0.contains("mem10 ") || $0.contains("mem HIGH") }

        var out: [String] = []
        out.append("--- 崩溃原因判别（全量排查，逐项看证据）---")

        // 1. Jetsam
        if rssList.isEmpty {
            out.append("[1] Jetsam/内存    : 证据不足（上一轮没有播放心跳，看不到 RSS 曲线）")
        } else {
            let first = rssList.first ?? 0
            let last = rssList.last ?? 0
            let peak = rssList.max() ?? 0
            let trend = last - first
            out.append("[1] Jetsam/内存    : RSS \(first)→\(last)MB（上轮峰值 \(peak)MB，变化 \(trend >= 0 ? "+" : "")\(trend)MB）"
                       + " · 内存警告 \(warns.count) 次 · 历史峰值 \(MemoryProbe.peakMB())MB")
            out.append("     判据          : RSS 持续爬升且逼近设备上限 → 高度可疑；RSS 平稳 → 基本排除")
        }

        // 2. Watchdog
        if mainStall.isEmpty {
            out.append("[2] Watchdog/主线程: 未观测到主线程停摆（心跳里没有「主=卡」）")
        } else {
            out.append("[2] Watchdog/主线程: 观测到 \(mainStall.count) 次主线程停摆 → 高度可疑")
            out.append("     " + (mainStall.last ?? ""))
        }
        out.append("     判据          : 后台心跳继续、主线程时间戳不动 = 主线程被卡住 ≥10s 被 watchdog 杀")

        // 3. Node 侧：必须先区分「根本没启动」和「运行中崩」，否则会误判
        // 1.8.6：rc=9 是 Node 的 kInvalidCommandLineArgument。node_start 直接返回时
        // main.js 一行都没跑，此时不是 V8 abort，而是本机源整体不可用。
        let rt = NodeRuntime.shared
        let startFailed = (rt.nodeDidExit && (rt.lastExitCode ?? 0) != 0)
            || nodeLog.contains("node_start exited rc=9")
        if startFailed {
            out.append("[3] Node V8 abort  : 不适用 —— Node 根本没启动（node_start 退出码 "
                       + "\(rt.lastExitCode.map(String.init) ?? "9")，启动参数/运行时失败）")
            out.append("     本机源        : 端口无监听 → /config 与 /spider 必然连不上；站点列表只是配置缓存，不是可用站点")
            out.append("     处理          : 设置 → 诊断 → 重启本机内核；若仍失败请完全退出 App 冷启动")
        } else if fatal {
            out.append("[3] Node V8 abort  : node.log 出现 FATAL → 高度可疑（Node 与 App 同进程，abort 会带走整个 App）")
        } else if nodeExit {
            out.append("[3] Node V8 abort  : 看到 Node EXIT，但未见 FATAL")
        } else {
            out.append("[3] Node V8 abort  : node.log 未见 FATAL / EXIT，暂不支持")
        }
        out.append("     Node 内存样本 : \(nodeMemLines.count) 行（每 10s 一条）")

        // 4. AVFoundation
        if playerFails.isEmpty {
            out.append("[4] AVFoundation   : 未观测到「败 播放」（item failed / 播放到末尾失败）")
        } else {
            out.append("[4] AVFoundation   : 观测到 \(playerFails.count) 条失败事件")
            for l in playerFails.suffix(2) { out.append("     " + l) }
        }

        // 5. NSException
        if let c = crashLog, !c.isEmpty {
            out.append("[5] NSException    : CrashGuard 有记录 → 见「上次崩溃记录」")
        } else {
            out.append("[5] NSException    : CrashGuard 无记录 → 基本排除（ObjC/Swift 异常型崩溃）")
        }

        // 6. 生命周期
        if life.isEmpty {
            out.append("[6] 生命周期/主动  : 上一轮没有「进入后台 / 即将终止」记录")
        } else {
            out.append("[6] 生命周期/主动  : \(life.count) 条")
            for l in life.suffix(3) { out.append("     " + l) }
        }

        // 心跳覆盖度
        if beats.isEmpty {
            out.append("心跳覆盖度        : 上一轮没有播放心跳（可能没进播放页，或本版首次启动）")
        } else {
            out.append("心跳覆盖度        : \(beats.count) 条 · 首条 \(beats.first ?? "") · 末条 \(beats.last ?? "")")
            out.append("     说明          : 末条心跳的 t= 就是进程消失前的最后时刻，之后 3 秒内被杀")
        }

        out.append("证据不足时不下结论：请连同 node.log 尾部与本段一起复制给我。")
        out.append("")
        return out
    }

    private static func rssMB(from line: String) -> Int? {
        guard let r = line.range(of: "rss=") else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber })
        return Int(digits)
    }
}
