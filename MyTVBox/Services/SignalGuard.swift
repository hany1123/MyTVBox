//
//  SignalGuard.swift
//  MyTVBox
//
//  1.8.10：六类原因（Jetsam / Watchdog / V8 abort / AVFoundation / NSException /
//  生命周期）在 1.8.9 诊断里全部无证据，foot 104→105MB 平稳、CrashGuard 无记录，
//  进程却仍在起播阶段消失。剩下的最大盲区是**原生层信号崩溃**：
//  AVFoundation / mediaserverd / NodeMobile 的 C++ 层 SIGABRT、SIGSEGV、SIGBUS、
//  SIGTRAP（Swift runtime 断言）不会产生 NSException，NSSetUncaughtExceptionHandler
//  抓不到，也不写 node.log FATAL。
//
//  这里装 POSIX signal handler，把信号名落到 Documents/MyTVBox/signal.log。
//  注意：
//   · handler 里**只能用 async-signal-safe 的 C 调用**（open/write/close/signal/raise）。
//     不碰 Foundation、不 malloc、不调 backtrace_symbols，否则在已损坏的堆上会二次崩溃。
//   · 所有字符串在 install() 里预先 strdup 好，handler 只读全局指针。
//   · SIGKILL（Jetsam / watchdog 的最终一击）**抓不到**，这类仍靠心跳与 foot 曲线判读。
//   · 写完恢复 SIG_DFL 并重新 raise，让系统照常生成 .ips 崩溃日志，不吞掉现场。
//
//  每次启动写一条 `=== boot ===` 分隔线；lastSignal() 只认**最后一次 boot 之前**
//  的 SIGNAL 行，也就是「上一轮是不是被原生信号带走的」。
//

import Foundation
import Darwin

// signal handler 是 C 函数指针，不能捕获 Swift 上下文，只能用全局变量。
// 这些全局量都在 install() 里完成惰性初始化，handler 触发时不会再初始化。
private var sgPath: UnsafeMutablePointer<CChar>?
private var sgAbort: UnsafeMutablePointer<CChar>?
private var sgSegv: UnsafeMutablePointer<CChar>?
private var sgBus: UnsafeMutablePointer<CChar>?
private var sgIll: UnsafeMutablePointer<CChar>?
private var sgFpe: UnsafeMutablePointer<CChar>?
private var sgTrap: UnsafeMutablePointer<CChar>?
private var sgOther: UnsafeMutablePointer<CChar>?

private let sgHandler: @convention(c) (Int32) -> Void = { sig in
    let line: UnsafeMutablePointer<CChar>?
    switch sig {
    case SIGABRT: line = sgAbort
    case SIGSEGV: line = sgSegv
    case SIGBUS:  line = sgBus
    case SIGILL:  line = sgIll
    case SIGFPE:  line = sgFpe
    case SIGTRAP: line = sgTrap
    default:      line = sgOther
    }
    if let p = sgPath {
        let fd = open(p, O_WRONLY | O_CREAT | O_APPEND, mode_t(S_IRUSR | S_IWUSR))
        if fd >= 0 {
            if let l = line { _ = write(fd, l, strlen(l)) }
            close(fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum SignalGuard {

    private static var installed = false

    private static var logFile: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyTVBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signal.log")
    }

    /// 在 didFinishLaunching 里、CrashGuard.install() 之后调用一次
    static func install() {
        guard !installed else { return }
        installed = true

        sgPath = logFile.path.withCString { strdup($0) }
        sgAbort = strdup("SIGNAL SIGABRT (6) abort() / C++ assertion / NSAssertion\n")
        sgSegv  = strdup("SIGNAL SIGSEGV (11) invalid memory access\n")
        sgBus   = strdup("SIGNAL SIGBUS (10) bus error / misaligned mapping\n")
        sgIll   = strdup("SIGNAL SIGILL (4) illegal instruction\n")
        sgFpe   = strdup("SIGNAL SIGFPE (8) floating point exception\n")
        sgTrap  = strdup("SIGNAL SIGTRAP (5) Swift / ObjC runtime trap\n")
        sgOther = strdup("SIGNAL other (native signal)\n")

        // 先写分界线，再装 handler。分界线之后如有 SIGNAL 行，就是「本轮」；
        // 诊断只看最后一次 boot **之前** 的那一段，即上一轮的结局。
        appendBoot()
        for s in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(s, sgHandler)
        }
    }

    private static func appendBoot() {
        let url = logFile
        let line = Data("=== boot ===\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// 上一轮（最后一次启动之前）捕获到的原生信号；没有则 nil
    static func lastSignal() -> String? {
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return nil }
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        if let boot = lines.lastIndex(of: "=== boot ===") {
            return Array(lines[..<boot]).last(where: { $0.hasPrefix("SIGNAL ") })
        }
        return lines.last(where: { $0.hasPrefix("SIGNAL ") })
    }

    static func clear() {
        try? FileManager.default.removeItem(at: logFile)
    }
}
