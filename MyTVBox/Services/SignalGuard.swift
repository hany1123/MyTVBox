import Foundation

// 1.8.18 收尾：POSIX signal handler 已移除。
// 不再注册 SIGABRT / SIGSEGV / SIGBUS / SIGILL / SIGFPE / SIGTRAP，
// 系统崩溃日志（.ips）由 iOS 自己生成，线程栈比信号名更可靠。

enum SignalGuard {
    static func install() {}
    static func lastSignal() -> String? { nil }
    static func status() -> String { "已移除（以系统 .ips 为准）" }
    static func clear() {}
}
