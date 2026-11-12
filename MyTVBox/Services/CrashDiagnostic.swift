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
        let bootLine = boot.map { all[$0] }
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

        // 本次播放范围：最后一次「开 播放」之后、到「播放页消失」为止。
        // 1.8.14：原来一直取到会话结束，把播放结束 36 秒后的详情页 / 跨站搜索
        // 全算进「本次播放窗口」，于是 1.8.13 误报「起播与整站搜索时间重叠」，
        // 那些重活其实都在 `完 播放 正常退出` 之后。
        let pStart = scope.lastIndex(where: { $0.contains("开 播放") }) ?? scope.startIndex
        let playTail = Array(scope[pStart...])
        let playEnd = playTail.firstIndex(where: {
            $0.contains("命 播放页消失") || $0.contains("完 心跳")
                || ($0.contains("完 播放") && $0.contains("正常退出"))
        })
        let playScope = playEnd.map { Array(playTail[...$0]) } ?? playTail
        let playEndedNormally = playTail.contains(where: {
            $0.contains("完 播放") && $0.contains("正常退出")
        })
        let beatGap = beats.last.flatMap { gapToBoot(from: $0, bootLine: bootLine) }

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
        let nodeMemLines = NodeRuntime.shared.tailLog(lines: 1200).split(separator: "\n")
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
                // 1.8.12：1.8.11 只有 2 条心跳（t=0 / t=2s），foot 2 秒涨 39MB，
                // 进程在跃升刚开始处就没了 —— 判别器却按「39 < 40」判成
                //「全程平稳、排除 Jetsam」。**曲线被截断时没有后半段，不能叫平稳**。
                let interrupted = !scope.contains(where: { $0.contains("完 心跳") })
                let rate = Double(jump) / 2.0
                out.append("     foot 判读      : 最低 \(fmin)MB / 峰值 \(fp)MB / 末条 \(footList.last ?? 0)MB，跃升 \(jump)MB · 约 \(Int(rate))MB/s · 样本 \(footList.count) 条，曲线"
                           + (interrupted ? "**被截断（进程消失）**" : "完整收尾"))
                let verdict: String
                if interrupted && footList.count < 3 {
                    // 1.8.13：rate=0 时不能再写「跃升刚开始处被砍断」——
                    // 没有上升苗头就说没有，同时点明 1s 心跳抓不到亚秒级尖峰。
                    let shapeText = rate > 0
                        ? "曲线在跃升刚开始处被砍断（只有 \(footList.count) 条心跳、无「完 心跳」），按 \(Int(rate))MB/s 外推 3 秒还会再涨约 \(Int(rate * 3))MB"
                        : "曲线被砍断且未见上升苗头（只有 \(footList.count) 条心跳、无「完 心跳」）；但 1s 心跳采不到亚秒级尖峰，不能据此排除"
                    verdict = "**证据不足，不能排除 Jetsam**：" + shapeText
                        + "。1.8.9 那次是播到 t=6s 且正常退出，那才叫真平稳；本轮请看 [9] 的 100ms 采样"
                } else if jump < 40 && fp < 400 {
                    // 1.8.14：1.8.13 拿播放期（21:03:50~21:04:20）的平稳曲线
                    // 去判 21:04:56 的崩溃，中间 36 秒完全没有内存证据。
                    if let g = beatGap, g > 8 {
                        verdict = "**仅播放期可排除 Jetsam**：曲线完整、foot 平稳，但末条播放心跳距本次启动 \(g) 秒 —— 崩溃时刻**没有内存证据**，结论不能外推到非播放期；请看 [10] App 级心跳"
                    } else {
                        verdict = "**按现有证据基本排除 Jetsam**（1s 心跳曲线完整、foot 平稳且绝对值不高；若 [9] 抓到尖峰则以 [9] 为准）"
                    }
                } else {
                    verdict = "**高度可疑**（foot 明显跃升，优先查视频侧缓冲与 Node V8 堆）"
                }
                out.append("     结论          : " + verdict)
            } else {
                out.append("     foot 判读      : 本版心跳应带 foot=；若为空请回报（task_vm_info 在该设备读取失败）")
            }
            // 1.8.13：原来从 tail 400 行直接取 mem10，跨了好几次 === boot ===，
            // 于是 1.8.12 里「177→154MB」这种下降曲线也被硬写成「同步上涨、
            // 内存在 Node 侧」。现在只取本次启动之后的样本，
            // 并按真实趋势措辞，不再预设结论。
            let bootScoped = NodeRuntime.shared.tailLog(lines: 1200)
                .split(separator: "\n").map(String.init)
            let bootIdx = bootScoped.lastIndex(where: { $0.contains("=== boot ===") })
                ?? bootScoped.startIndex
            let nodeRssList: [Int] = bootScoped[bootIdx...]
                .filter { $0.contains("mem10 ") }
                .suffix(8)
                .compactMap { line in
                    guard let r = line.range(of: "rss=") else { return nil }
                    let digits = String(line[r.upperBound...].prefix(while: { $0.isNumber }))
                    return Int(digits)
                }
            if !nodeRssList.isEmpty {
                let nf = nodeRssList.first ?? 0
                let nl = nodeRssList.last ?? 0
                let nt = nl - nf
                let trendText = nt > 12 ? "上升" : (nt < -12 ? "下降" : "平稳")
                out.append("     Node RSS       : 本次启动 \(nodeRssList.count) 条 mem10 样本 \(nf)→\(nl)MB"
                           + "（峰值 \(nodeRssList.max() ?? 0)MB）· 趋势 \(trendText)（\(nt >= 0 ? "+" : "")\(nt)MB）")
                out.append("     判读          : " + (trendText == "上升"
                    ? "Node 侧在涨，倾向跨站搜索 / fetch 缓冲区持续占用；再看 [9] 的 mem1 buf="
                    : "Node 侧无明显持续增长，压力更可能来自一次性大分配或视频侧映射（看 [9] 的 100ms 尖峰）"))
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
        out.append("     判据          : 这类崩溃不产生 NSException、不写 node.log FATAL，只有 signal handler 能留痕；SIGKILL 抓不到，Jetsam 是否成立请看 [1] 的曲线完整性与增速判读")

        // 8. 起播阶段 + 重活并发 —— 1.8.10：1.8.9 崩在「记 播放 URL」之前
        let stageHits = playScope.filter { $0.contains("记 播放") || $0.contains("item.status=") }
        let reachedReady = playScope.contains(where: { $0.contains("首帧就绪") })
        let reachedItem = playScope.contains(where: { $0.contains("创建 AVPlayerItem") })
        let reachedURL = playScope.contains(where: { $0.contains("记 播放 URL") })
        let playStarted = playScope.contains(where: { $0.contains("发起 /play 取流") })
        let playEnded = playScope.contains(where: { $0.contains("/play 结束") })
        // 1.8.14：播放已经正常收尾时，别再按「缺 item.status 回调」判成崩在装载期。
        // 1.8.13 就是这样把一次完整 29 秒的正常播放读成「已创建 AVPlayerItem、等 status」。
        let stageText = playEndedNormally
            ? "**播放已正常收尾 → 崩溃发生在非播放状态**（看 [10] App 级心跳）"
            : (reachedReady ? "首帧就绪之后"
               : (reachedItem ? "已创建 AVPlayerItem、等 status"
                  : (reachedURL ? "已拿到播放 URL"
                     : (playStarted ? (playEnded ? "/play 已返回、未拿到可播 URL"
                                      : "**/play 取流请求在飞（未见返回）**")
                        : "起播入口之前 / 非本机源解析"))))
        out.append("[8] 起播阶段      : 本次播放停在「\(stageText)」 · 阶段轨迹 \(stageHits.count) 条")
        for l in stageHits.suffix(4) { out.append("     " + l) }
        let openWork = scope.filter { $0.contains("开 重活") }.count
        let closeWork = scope.filter { $0.contains("完 重活") }.count
        // 1.8.12：全局「开/完 数量配对」≠ 时间上不重叠。1.8.11 的 `完 重活`
        // 就落在播放窗口内（起播后 2 秒），判别器却报「无在飞重活」。
        let playWork = playScope.filter { $0.contains("开 重活") || $0.contains("完 重活") }
        out.append("     重活并发      : 本次播放窗口内 \(playWork.count) 条重活事件（全局配对 开 \(openWork) / 完 \(closeWork)）→ "
                   + (playWork.isEmpty ? "播放期间无重活"
                      : "**起播与整站搜索时间重叠**（数量配对不代表不重叠）"))
        for l in playWork.suffix(2) { out.append("     " + l) }
        out.append("     心跳结局      : "
                   + (scope.contains(where: { $0.contains("完 心跳") })
                      ? "有「完 心跳」→ 播放页主动消失，心跳是正常收尾"
                      : "**无「完 心跳」→ 进程被直接终止**，末条心跳即最后存活证据"))
        out.append("     死亡时刻      : `启 启动` 是老大重开 App 的时间，不是进程消失时刻；以末条心跳为准")

        // 9. /play 在飞取证 —— 1.8.13
        // 1.8.12 死在「/play 取流请求在飞」，[1] 的 1s 心跳只给出
        //「foot 111→110MB 平稳」。这里补两个此前完全空白的证据源：
        //   spike.log 的 100ms 采样（亚秒尖峰）、node.log 的 REQ/RES/FETCH 轨迹。
        var trace = NodeRuntime.shared.playTraceLines()
        var traceLabel = "本次"
        let prevTrace = NodeRuntime.shared.previousPlayTraceLines()
        if !trace.contains(where: { $0.contains("REQ ") && $0.contains("/play") }),
           !prevTrace.isEmpty {
            // 崩溃轮是上一轮；本次刚重开还没发起取流，只看本次会得出「无请求」的错误结论
            trace = prevTrace
            traceLabel = "上一轮"
        }
        let reqPlay = trace.filter { $0.contains("REQ ") && $0.contains("/play") }
        let resPlay = trace.filter { $0.contains("RES ") && $0.contains("/play") }
        let aborted = trace.filter { $0.contains("RES-ABORT") }
        let bigBody = trace.filter { $0.contains("BIGBODY") }
        let fetchErr = trace.filter { $0.contains("FETCHERR") }
        let mem1 = trace.filter { $0.contains("mem1 ") }
        let wins = SpikeProbe.shared.recentWindows(2)
        out.append("[9] /play 在飞取证 : spike 窗口 \(wins.count) 个 · \(traceLabel) Node 轨迹 \(trace.count) 行"
                   + "（REQ /play \(reqPlay.count) / RES /play \(resPlay.count) / ABORT \(aborted.count)"
                   + " / BIGBODY \(bigBody.count) / FETCHERR \(fetchErr.count) / mem1 \(mem1.count)）")
        if wins.isEmpty {
            out.append("     spike.log     : 无窗口（本版首次运行，或没走过 mytvboxnode://play 解析）")
        } else {
            for (i, w) in wins.enumerated() {
                out.append("     窗口\(i + 1) \(w.ended ? "正常" : "**无 END=崩溃轮**") : " + w.describe)
            }
            if let crash = wins.reversed().first(where: { !$0.ended }) {
                let v9: String
                if crash.peak >= 400 || crash.maxJump >= 80 {
                    v9 = "**Jetsam 高度可疑**：100ms 采样抓到了 1s 心跳看不到的尖峰"
                        + "（峰值 \(crash.peak)MB / 单次 +\(crash.maxJump)MB）→ 内存主要来自 Node fetch 响应体或视频侧映射"
                } else if crash.samples > 0 {
                    v9 = "**尖峰证据阴性**：100ms 采样全程 \(crash.first)→\(crash.peak)MB 平稳，"
                        + "但窗口无 END → 进程仍是被直接终止；优先查 Node 请求悬空 / 事件循环阻塞 / 系统回收，别再只盯内存"
                } else {
                    v9 = "窗口无采样，证据不足"
                }
                out.append("     结论          : " + v9)
            }
        }
        if resPlay.isEmpty && !reqPlay.isEmpty {
            out.append("     Node 请求     : **REQ 已进 Node、但没有 RES** → /play 在 Node 侧没回包"
                       + "（外网 fetch 挂住 / 同步 CPU 阻塞 / 回包前进程被杀）")
        } else if !resPlay.isEmpty {
            out.append("     Node 请求     : REQ→RES 成对，Node 回包了；若 Swift 侧仍无「/play 结束」，问题在 Swift 侧")
        } else if !reqPlay.isEmpty {
            out.append("     Node 请求     : 已有 /play 请求轨迹，但 createServer 包装未覆盖到该路由")
        }
        if let b = bigBody.last { out.append("     大响应体      : " + b) }
        for l in fetchErr.suffix(2) { out.append("     fetch 失败    : " + l) }
        if let m = mem1.last {
            out.append("     Node mem1     : " + m + " · buf= 是响应 Buffer 的直接指标")
        }
        out.append("     判据          : 1s 心跳与 100ms 采样冲突时以 100ms 为准；SIGKILL 抓不到，"
                   + "「无 END」+「尖峰」= Jetsam，「无 END」+「全程平稳」= 请求悬空或其他终止")

        // 10. 非播放期 / App 级心跳 —— 1.8.14
        // 1.8.11 标记、1.8.13 第二次复现的盲区：播放心跳绑播放页、spike 绑 /play，
        // 「播放页消失 → 后台 → 回前台 → 详情 → 跨站搜索」这段完全没有内存与存活证据。
        let appW = AppHeartbeat.shared.previousWindow()
        let appFoots = AppHeartbeat.footValues(appW)
        let appEvents = appW.filter { $0.contains(" E ") }
        out.append("[10] 非播放期取证 : App 级心跳 \(appW.count) 行（foot \(appFoots.count) 样本 / 事件 \(appEvents.count) 条）· 崩溃轮")
        if appW.isEmpty {
            out.append("     appbeat.log   : 无崩溃轮记录（本版首次启动 / 日志被裁剪）")
        } else {
            let f0 = appFoots.first ?? 0
            let f1 = appFoots.last ?? 0
            let fp = appFoots.max() ?? 0
            var jump2 = 0
            if appFoots.count > 1 {
                for i in 1..<appFoots.count { jump2 = max(jump2, appFoots[i] - appFoots[i - 1]) }
            }
            out.append("     foot 曲线     : \(f0)→\(f1)MB（峰值 \(fp)MB · 单次最大 +\(jump2)MB）· 常态 1s / 重活期 200ms")
            for l in appEvents.suffix(5) { out.append("     事件          : " + l) }
            if let last = appW.last {
                out.append("     末条          : " + last)
                if let gap = gapToBoot(from: last, bootLine: bootLine) {
                    out.append("     距本次启动    : \(gap) 秒（末条 App 心跳 → 重开）")
                }
            }
            let v10: String
            if fp >= 400 || jump2 >= 80 {
                v10 = "**Jetsam 高度可疑**：非播放期抓到了内存尖峰（峰值 \(fp)MB / 单次 +\(jump2)MB）"
            } else if appFoots.count < 3 {
                v10 = "证据不足（App 心跳样本太少）"
            } else {
                v10 = "**非播放期内存平稳**：排除持续性内存压力；进程仍无 END 地消失 → 优先查请求悬空 / Node 在飞请求（INFLIGHT）/ 系统回收"
            }
            out.append("     结论          : " + v10)
        }
        out.append("     判据          : 播放心跳与 spike 都绑窗口，只有 App 级心跳覆盖「播放页消失 → 后台 → 详情 → 搜索」这段；重活期间自动加密到 200ms")

        // 心跳覆盖度
        if beats.isEmpty {
            out.append("心跳覆盖度        : 0 条（\(scopeName)没有播放心跳；可能没进播放页）")
        } else {
            out.append("心跳覆盖度        : \(beats.count) 条（\(scopeName)最近一次播放） · 首条 \(beats.first ?? "") · 末条 \(beats.last ?? "")")
            out.append("     说明          : "
                       + (scope.contains(where: { $0.contains("完 心跳") })
                          ? "有「完 心跳」，本轮心跳是正常收尾，不是被杀断的"
                          : "按 1~2 秒采样（起播前 10 秒为 1 秒），末条之后本应还有下一条；缺了就是进程在那一瞬间没了"))
        }
        out.append("     覆盖边界      : 播放心跳在「完 心跳」处主动停止，**不覆盖非播放期**；崩在播放页消失之后请看 [10] App 级心跳")
        out.append("播放结局          : "
                   + (playScope.last(where: { $0.contains("完 播放") })
                      ?? "本次播放没有「完 播放」（未正常收尾）"))

        // 1.8.11：老大「首次进入闪退了一次」，但崩完又正常播了一次 ——
        // 本轮 4 条心跳让 useCurrent 取了本轮，首次闪退那一轮被整个盖掉。
        // 这里**并列**再给一份上一轮判读，两份都保留，不再二选一。
        out.append("")
        out.append("--- 上一轮独立判读（首次闪退轮，避免被本轮正常播放覆盖）---")
        if lastSession.isEmpty {
            out.append("上一轮          : 无记录（本版首次启动 / 日志已被裁剪）")
        } else {
            let prevLast = lastSession.last ?? ""
            let pBeats = playbackBeats(lastSession)
            let pRss = pBeats.compactMap { rssMB(from: $0) }
            let pFoot = pBeats.compactMap { footMB(from: $0) }
            out.append("上一轮范围      : \(lastSession.count) 行 · 末行 \(prevLast)")
            let memText = pRss.isEmpty
                ? "无播放心跳（崩溃可能发生在非播放状态）"
                : "RSS \(pRss.first ?? 0)→\(pRss.last ?? 0)MB · foot "
                  + (pFoot.isEmpty ? "未记录"
                     : "\(pFoot.first ?? 0)→\(pFoot.last ?? 0)MB（峰值 \(pFoot.max() ?? 0)MB）")
            out.append("上一轮内存      : " + memText + " · 心跳 \(pBeats.count) 条")
            out.append("上一轮心跳结局  : "
                       + (lastSession.contains(where: { $0.contains("完 心跳") })
                          ? "有「完 心跳」→ 播放页主动收尾，心跳不是被杀断的"
                          : "**无「完 心跳」→ 进程在播放中被直接终止**"))
            out.append("上一轮播放结局  : "
                       + (lastSession.last(where: { $0.contains("完 播放") })
                          ?? "没有「完 播放」（未正常收尾）"))
            let pFails = lastSession.filter { $0.contains("败 播放") || $0.contains("败 取流") }
            out.append("上一轮失败事件  : \(pFails.count) 条"
                       + (pFails.isEmpty ? "" : " · 末条 " + (pFails.last ?? "")))
            let pOpen = lastSession.filter { $0.contains("开 重活") }.count
            let pClose = lastSession.filter { $0.contains("完 重活") }.count
            out.append("上一轮重活配对  : 开 \(pOpen) / 完 \(pClose)")
            let bootLine = boot.map { all[$0] }
            if let gap = gapToBoot(from: prevLast, bootLine: bootLine) {
                out.append("距本次启动      : \(gap) 秒（本次启动行 \(bootLine ?? "")）")
                if lastSession.contains(where: { $0.contains("完 心跳") }), gap <= 60 {
                    out.append("     判读          : **播放页与心跳都已正常收尾，却仍在 \(gap) 秒后重启** → 崩溃发生在**非播放状态**，现有播放心跳覆盖不到这段取证空窗")
                    out.append("     下一步        : 补 App 级轻量心跳（不绑播放页），或先看本轮新加的 `/play 失败原因` 与 signal 安装自检")
                }
            }
        }

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

    /// 1.8.11：从面包屑行首的 `HH:mm:ss.SSS` 读出当天秒数，
    /// 用来算「上一轮末行 → 本次启动」的间隔。跨午夜时结果为负，返回 nil。
    private static func clockSeconds(_ line: String) -> Int? {
        guard let t = line.split(separator: " ").first else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let h = Int(String(parts[0])),
              let m = Int(String(parts[1])) else { return nil }
        guard let secPart = parts[2].split(separator: ".").first,
              let s = Int(String(secPart)) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private static func gapToBoot(from line: String, bootLine: String?) -> Int? {
        guard let b = bootLine,
              let t0 = clockSeconds(line),
              let t1 = clockSeconds(b) else { return nil }
        let gap = t1 - t0
        return gap >= 0 ? gap : nil
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
