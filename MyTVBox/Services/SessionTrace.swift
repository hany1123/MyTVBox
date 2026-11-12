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

    /// 上次是不是停在某个「开 …」上（=那一步没走完）
    static func interruptedStep() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return nil }
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        // 格式：`12:34:56.789 开 搜索 谷雨`
        guard let r = last.range(of: "开 ") else { return nil }
        return String(last[r.upperBound...])
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: logFile)
    }
}
