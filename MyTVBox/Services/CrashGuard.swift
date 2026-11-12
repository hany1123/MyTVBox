import Foundation

// 1.8.18 收尾：NSException 抓取已移除。
// 保留签名作为兼容层，不再注册 handler、不再写 crash.log。

enum CrashGuard {
    static func install() {}
    static func lastReport() -> String? { nil }
    static func clear() {}
}
