//
//  CrashDiagnostic.swift
//  MyTVBox
//
//  1.8.5：老大要求「不要靠猜，把可能导致的原因列进去，全面排查」。
//  iOS 上 App 进程消失的原因逐项列「证据现状」，而不是先验押一个结论：
//
//   1 Jetsam(内存)      RSS + phys_footprint 曲线 / 内存警告 / 心跳中断点
//   2 Watchdog(主线程)  后台心跳仍在但主线程时间戳停摆（0x8badf00d）
//   3 Node V8 abort     node.log 里 FATAL / Reached heap limit / EXIT code
//   4 AVFoundation      「败 播放」/ item 失败通知
//   5 NSException       CrashGuard 的 crash.log
//   6 生命周期/主动退出  「命 进入后台 / 播放页消失 / 回前台」
//   7 原生信号          1.8.10 新增：SignalGuard 的 signal.log
//                       （SIGABRT / SIGSEGV / SIGBUS / SIGTRAP，CrashGuard 抓不到）
//   8 起播阶段/重活并发  1.8.10 新增：本次播放停在哪一步、整站搜索是否还在飞
//
//  1.8.10：1.8.9 把日志窗口放大到 240 行后，`previous` 会跨好几个会话，
//  [4] 把 18:18 / 18:31 的旧 item.failed 当成「本次」、[6] 把 18:32 的
//  「进入后台」也算进来。证据范围必须收窄到**最后一个完整会话**。
//
//  证据不足时明确写「未观测到」，不替用户下结论。
//

import Foundation

enum CrashDiagnostic {

    static func lines() -> [String] {
        // 1.8.7：本轮/上一轮双范围；1.8.9：窗口 80→240 行（2s 心跳）。
        let all = SessionTrace.recent(240)
        let boot = all.lastIndex(where: { $0.contains(SessionTrace.bootToken) })
        let current = boot.map { Array(all[($0 + 1)...]) } ?? all
        let previous = boot.map { Array(all[..<$0]) } ?? []

        // 1.8.10：240 行能装下好几次启动，previous 不再是「上一轮」，
        // 而是「本次启动之前的全部历史」。取其中最后一次启动之后的部分，
        // 才是真正崩溃的那一轮现场。
        let lastSession = Self.lastSession(from: previous)
        let curBeats = playbackBeats(current)
        let prevBeats = playbackBeats(lastSession)
        // 本轮有心跳就用本轮；本轮没进播放页才退回上一轮的崩溃现场
        let useCurrent = !curBeats.isEmpty || prevBeats.isEmpty
        let scope = useCurrent ? current : lastSession
        let scopeName = useCurrent ? "本轮" : "上一轮"
        let beats = useCurrent ? curBeats : prevBeats

        // 本次播放范围：最后一次「开 播放」之后的所有行
        let pStart = scope.lastIndex(where: { $0.contains("开 播放") }) ?? scope.startIndex
        let playScope = Array(scope[pStart...])

        // 1.8.7：node.log 每 10s 一条 mem10，tail 40 行几乎全是内存样本。
        // 改用「本次启动之后」的全文关键行，FATAL 首行 / shim 状态 / rc=9 都不会被挤掉。
        let keyLines = NodeRuntime.shared.keyLogLines()
        let nodeLog = keyLines.joined(separator: "\n")
        let crashLog = CrashGuard.lastReport()

        let rssList = beats.compactMap { rssMB(from: $0) }
        let warns = scope.filter { $0.contains("警 ") }
        let mainStall = beats.filter { $0.contains("主=卡") }
        // 1.8.10：只看收窄后的会话，不再用 both（会把好几轮的旧失败混进来）
        let playerFails = playScope.filter { $0.contains("败 播放") }
        let life = scope.filter { $0.contains("命 ") }

        let fatal = nodeLog.contains("FATAL ERROR")
            || nodeLog.contains("Reached heap limit")
            || nodeLog.contains("FATAL uncaught")
            || nodeLog.contains("FATAL unhandled")
        let nodeExit = nodeLog.contains("EXIT code=")
        let nodeMemLines = NodeRuntime.shared.tailLog(lines: 400).split(separator: "\n")
            .filter { $0.contains("mem10 ") || $0.contains("mem HIGH") }

        var out: [String] = []
        out.append("--- 崩溃原因判别（全量排查，逐项看证据）---")
        out.append("证据范围      : 本轮 \(current.count) 行 / 启动前历史 \(previous.count) 行 → 收窄到最后一个完整会话 \(lastSession.count) 行 → 取「\(scopeName)」（心跳 \(beats.count) 条）")
        out.append("node.log 关键行: \(keyLines.count) 行（本次启动后全文提取，见报告下一段）")

        // 1. Jetsam —— 1.8.9 同时看 RSS 与 phys_footprint；1.8.10 给明确结论
        let footList = beats.compactMap { footMB(from: $0) }
        if rssList.isEmpty {
            out.append("[1] Jetsam/内存    : 证据不足（\(scopeName)没有播放心跳，看不到内存曲线）")
        } else {
            let first = rssList.first ?? 0
            let last = rssList.last ?? 0
            let peak = rssList.max() ?? 0
            let trend = last - first
            let footText: String
            if footList.isEmpty {
                footText = "phys_footprint 未记录（旧版心跳 / task_vm_info 读取失败）"
            } else {
                let f0 = footList.first ?? 0
                let f1 = footList.last ?? 0
                let fp = footList.max() ?? 0
                footText = "foot \(f0)→\(f1)MB（峰值 \(fp)MB，变化 \(f1 - f0 >= 0 ? "+" : "")\(f1 - f0)MB）"
            }
            out.append("[1] Jetsam/内存    : RSS \(first)→\(last)MB（\(scopeName)峰值 \(peak)MB，变化 \(trend >= 0 ? "+" : "")\(trend)MB）"
                       + " · \(footText) · 内存警告 \(warns.count) 次")
            out.append("     判据          : Jetsam 依据 phys_footprint 杀进程，AVPlayer 的 IOSurface / IOKit / 硬件解码缓冲不计入 resident_size；阈值 40MB 跃升 / 400MB 绝对值是**参考量级**，不是硬判定")
            if !footList.isEmpty {
                let fmin = footList.min() ?? 0
                let fp = footList.max() ?? 0
                let jump = fp - fmin
                out.append("     foot 判读      : 最低 \(fmin)MB / 峰值 \(fp)MB / 末条 \(footList.last ?? 0)MB，跃升 \(jump)MB")
                out.append("     结论          : "
                           + (jump < 40 && fp < 400
                              ? "**按现有证据基本排除 Jetsam**（foot 全程平稳且绝对值不高，视频侧映射没有暴涨）"
                              : "**高度可疑**（foot 出现明显跃升，优先查视频侧缓冲）"))
            } else {
                out.append("     foot 判读      : 本版心跳应带 foot=；若为空请回报（task_vm_info 在该设备读取失败）")
            }
        }

        // 2. Watchdog
        if mainStall.isEmpty {
            out.append("[2] Watchdog/主线程: 未观测到主线程停摆（心跳里没有「主=卡」）→ 基本排除")
        } else {
            out.append("[2] Watchdog/主线程: 观测到 \(mainStall.count) 次主线程停摆 → 高度可疑")
            out.append("     " + (mainStall.last ?? ""))
        }
        out.append("     判据          : 后台心跳继续、主线程时间戳不动 = 主线程被卡住 ≥10s 被 watchdog 杀")

        // 3. Node 侧：必须先区分「根本没启动」和「运行中崩」，否则会误判
        let rt = NodeRuntime.shared
        let startFailed = (rt.nodeDidExit && (rt.lastExitCode ?? 0) != 0)
            || nodeLog.contains("node_start exited rc=9")
        if startFailed {
            out.append("[3] Node V8 abort  : 不适用 —— Node 根本没启动（node_start 退出码 "
                       + "\(rt.lastExitCode.map(String.init) ?? "9")，启动参数/运行时失败）")
            out.append("     本机源        : 端口无监听 → /config 与 /spider 必然连不上；站点列表只是配置缓存，不是可用站点")
            out.append("     处理          : 设置 → 诊断 → 重启本机内核；若仍失败请完全退出 App 冷启动")
        } else if fatal {
            out.append("[3] Node V8 abort  : 本轮 node.log 关键行出现 FATAL → 高度可疑（Node 与 App 同进程，abort 会带走整个 App）")
        } else if nodeExit {
            out.append("[3] Node V8 abort  : 看到 Node EXIT，但未见 FATAL")
        } else {
            out.append("[3] Node V8 abort  : 本轮 node.log 关键行未见 FATAL / EXIT → 基本排除")
        }
        out.append("     Node 内存样本 : \(nodeMemLines.count) 行（每 10s 一条）")

        // 4. AVFoundation —— 只看本次播放范围
        if playerFails.isEmpty {
            out.append("[4] AVFoundation   : 本次播放未观测到「败 播放」（旧轮的失败已不再计入）")
        } else {
            out.append("[4] AVFoundation   : 本次播放观测到 \(playerFails.count) 条失败事件")
            for l in playerFails.suffix(2) { out.append("     " + l) }
        }

        // 5. NSException
        if let c = crashLog, !c.isEmpty {
            out.append("[5] NSException    : CrashGuard 有记录 → 见「上次崩溃记录」")
        } else {
            out.append("[5] NSException    : CrashGuard 无记录 → 基本排除（ObjC/Swift 异常型崩溃）")
        }

        // 6. 生命周期 —— 只看收窄后的会话
        if life.isEmpty {
            out.append("[6] 生命周期/主动  : 本轮未观测到「进入后台 / 播放页消失 / 回前台」")
        } else {
            out.append("[6] 生命周期/主动  : \(life.count) 条")
            for l in life.suffix(3) { out.append("     " + l) }
        }

        // 7. 原生信号 —— 1.8.10：六类全排除后最大的盲区
        if let sig = SignalGuard.lastSignal() {
            out.append("[7] 原生信号      : 上一轮捕获到 `\(sig)` → **高度可疑**（AVFoundation / NodeMobile C++ / Swift runtime 断言）")
        } else {
            out.append("[7] 原生信号      : 未捕获到 SIGABRT / SIGSEGV / SIGBUS / SIGTRAP 记录")
        }
        out.append("     判据          : 这类崩溃不产生 NSException、不写 node.log FATAL，只有 signal handler 能留痕；SIGKILL 抓不到，但已由 foot 曲线排除 Jetsam")

        // 8. 起播阶段 + 重活并发 —— 1.8.10：1.8.9 崩在「记 播放 URL」之前
        let stageHits = playScope.filter { $0.contains("记 播放") || $0.contains("item.status=") }
        let reachedReady = playScope.contains(where: { $0.contains("首帧就绪") })
        let reachedItem = playScope.contains(where: { $0.contains("创建 AVPlayerItem") })
        let reachedURL = playScope.contains(where: { $0.contains("记 播放 URL") })
        let playStarted = playScope.contains(where: { $0.contains("发起 /play 取流") })
        let playEnded = playScope.contains(where: { $0.contains("/play 结束") })
        let stageText = reachedReady ? "首帧就绪之后"
            : (reachedItem ? "已创建 AVPlayerItem、等 status"
               : (reachedURL ? "已拿到播放 URL"
                  : (playStarted ? (playEnded ? "/play 已返回、未拿到可播 URL"
                                   : "**/play 取流请求在飞（未见返回）**")
                     : "起播入口之前 / 非本机源解析")))
        out.append("[8] 起播阶段      : 本次播放停在「\(stageText)」 · 阶段轨迹 \(stageHits.count) 条")
        for l in stageHits.suffix(4) { out.append("     " + l) }
        let openWork = scope.filter { $0.contains("开 重活") }.count
        let closeWork = scope.filter { $0.contains("完 重活") }.count
        out.append("     重活并发      : 整站级搜索 开 \(openWork) / 完 \(closeWork) → "
                   + (openWork > closeWork
                      ? "**起播时仍有未结束的跨站搜索**（与本机 Node 同进程）"
                      : "无在飞重活"))
        out.append("     心跳结局      : "
                   + (scope.contains(where: { $0.contains("完 心跳") })
                      ? "有「完 心跳」→ 播放页主动消失，心跳是正常收尾"
                      : "**无「完 心跳」→ 进程被直接终止**，末条心跳即最后存活证据"))
        out.append("     死亡时刻      : `启 启动` 是老大重开 App 的时间，不是进程消失时刻；以末条心跳为准")

        // 心跳覆盖度
        if beats.isEmpty {
            out.append("心跳覆盖度        : 0 条（\(scopeName)没有播放心跳；可能没进播放页）")
        } else {
            out.append("心跳覆盖度        : \(beats.count) 条（\(scopeName)最近一次播放） · 首条 \(beats.first ?? "") · 末条 \(beats.last ?? "")")
            out.append("     说明          : 按 2 秒采样，末条之后本应还有下一条；缺了就是进程在那一瞬间没了")
        }
        out.append("播放结局          : "
                   + (playScope.last(where: { $0.contains("完 播放") })
                      ?? "本次播放没有「完 播放」（未正常收尾）"))

        out.append("证据不足时不下结论：请连同 node.log 关键行与本段一起复制给我。")
        out.append("")
        return out
    }

    /// 1.8.10：从「本次启动之前的全部历史」里切出最后一次启动之后的那一轮。
    /// 240 行窗口能装下好几次启动，不加这一步就会把 18:18 / 18:31 的旧
    /// `败 播放`、18:32 的「进入后台」当成崩溃轮的证据。
    private static func lastSession(from lines: [String]) -> [String] {
        guard let i = lines.lastIndex(where: { $0.contains(SessionTrace.bootToken) }) else {
            return lines
        }
        return Array(lines[(i + 1)...])
    }

    /// 只取「最后一次开 播放」之后的心跳，避免把多轮播放的 RSS 混成一条曲线
    private static func playbackBeats(_ lines: [String]) -> [String] {
        let from = lines.lastIndex(where: { $0.contains("开 播放") }) ?? lines.startIndex
        return Array(lines[from...]).filter { $0.contains("跳 播放") }
    }

    private static func rssMB(from line: String) -> Int? {
        guard let r = line.range(of: "rss=") else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// 1.8.9：读心跳里的 phys_footprint。0 = task_vm_info 读取失败，不能当成
    /// 「内存只有 0MB」画进曲线，否则会把证据变成误导。
    private static func footMB(from line: String) -> Int? {
        guard let r = line.range(of: "foot=") else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber })
        guard let v = Int(digits), v > 0 else { return nil }
        return v
    }
}
