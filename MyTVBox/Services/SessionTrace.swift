//
//  SessionTrace.swift
//  MyTVBox
//
//  1.8.0：闪退「面包屑」。
//
//  问题：设备上闪退（尤其是主线程卡死被系统 watchdog 杀掉、或内存被 Jetsam 回收、
//  或 V8 abort）时，进程是直接消失的 —— 任何 in-process 的异常处理器都抓不到，
//  界面上也留不下任何东西。
//
//  办法：在关键动作开始时写一行 `开 xxx`，成功结束时写一行 `完 xxx`。
//  下次启动读最后一行：如果停在 `开` 上，就说明「上次是在这一步没的」。
//  这样即使抓不到崩溃原因，也能定位到**哪一步**，不用再靠猜。
//

import Foundation

enum SessionTrace {

    private static let lock = NSLock()
    /// 只留最近 80 行，避免文件变长
    private static let keep = 80

    private static var logFile: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyTVBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("breadcrumb.log")
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 记一条面包屑（append + 截断）
    static func mark(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let line = fmt.string(from: Date()) + " " + text + "\n"
        let url = logFile
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
        trimIfNeeded(url)
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > keep else { return }
        let kept = lines.suffix(keep).joined(separator: "\n") + "\n"
        try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// 最近 n 条
    static func recent(_ n: Int = 6) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.suffix(n))
    }

    /// 1.8.2：启动分界线。
    ///
    /// 1.8.0/1.8.1 的 `interruptedStep()` 只看「文件最后一行是不是 `开 `」，
    /// 有两个致命误判：
    /// ① 最后一行是 `弃 xxx`（搜索被取代）时判成「无记录」—— 恰恰这时候进程死了；
    /// ② 本次会话里正有一个 `开` 在飞（用户边搜边开诊断）时，会被误报成上次闪退。
    /// 现在每次启动写一条 `启 启动`，只把**这条线之前的最后一行**当作上一轮的现场。
    static let bootToken = "启 启动"

    /// 上一轮结束时的最后一行（不含本次启动之后的内容）
    static func previousTail(_ n: Int = 1) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let boot = lines.lastIndex(where: { $0.contains(bootToken) }) else {
            // 没有启动线（升级后第一次跑）→ 没有可信现场
            return []
        }
        let prev = Array(lines[..<boot])
        return Array(prev.suffix(max(1, n)))
    }

    /// 上一轮是不是停在某个「开 …」上（=那一步没走完）
    static func interruptedStep() -> String? {
        guard let last = previousTail(1).first else { return nil }
        guard let r = last.range(of: "开 ") else { return nil }
        return String(last[r.upperBound...])
    }

    /// 上一轮的最后一行（无论开/完/弃），去掉时间前缀 —— 崩溃时这才是真现场
    static func previousLastLine() -> String? {
        guard let last = previousTail(1).first else { return nil }
        guard let sp = last.firstIndex(of: " ") else { return last }
        return String(last[last.index(after: sp)...])
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: logFile)
    }
}
