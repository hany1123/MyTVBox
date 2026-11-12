//
//  CrashGuard.swift
//  MyTVBox
//
//  1.7.7：把「上一次是怎么没的」留下来。
//
//  背景：真机闪退时界面上什么都看不到，系统崩溃日志（设置 → 隐私与安全 →
//  分析与改进 → 分析数据）用户一般拿不到、也不好找。这里装一个未捕获异常
//  处理器，把异常名 / 原因 / 调用栈落到 Documents/MyTVBox/crash.log，
//  设置页的「诊断信息」里能直接读、直接复制。
//
//  注意：它抓的是 **ObjC / Swift 的 NSException 型崩溃**。
//  V8 堆溢出（`FATAL ERROR: Reached heap limit`）和系统 Jetsam 属于
//  进程被直接 abort / kill，任何 in-process 处理器都抓不到 —— 那类问题
//  靠 main.js 里定期写的内存水位日志来判断。
//

import Foundation

enum CrashGuard {

    private static var installed = false
    /// 只保留最近 8 次，避免文件无限长
    private static let keepLines = 240

    private static var logFile: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyTVBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("crash.log")
    }

    /// 在 didFinishLaunching 里调用一次
    static func install() {
        guard !installed else { return }
        installed = true

        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let symbols = exception.callStackSymbols.joined(separator: "\n    ")
            let text = """

            ===== \(ISO8601DateFormatter().string(from: Date())) =====
            type: NSException
            name: \(name)
            reason: \(reason)
            stack:
                \(symbols)

            """
            CrashGuard.append(text)
        }
    }

    private static func append(_ text: String) {
        let url = logFile
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        existing += text
        // 只留最后 keepLines 行
        let lines = existing.components(separatedBy: "\n")
        if lines.count > keepLines {
            existing = lines.suffix(keepLines).joined(separator: "\n")
        }
        if let data = existing.data(using: .utf8) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 最近一次崩溃记录（没有则 nil）
    static func lastReport() -> String? {
        guard let s = try? String(contentsOf: logFile, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: logFile)
    }
}
