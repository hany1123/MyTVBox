import Foundation

// 1.8.18 收尾：取证探针已移除。
// 保留类型与调用签名作为兼容层，所有方法都是空操作：
// 不写 breadcrumb.log、不启定时器、不读文件、不占内存。
// 崩溃定位改用系统 .ips（设置 → 隐私与安全性 → 分析与改进 → 分析数据）。

enum SessionTrace {
    static let bootToken = "启 启动"
    static func mark(_ text: String) {}
    static func recent(_ n: Int = 6) -> [String] { [] }
    static func previousTail(_ n: Int = 1) -> [String] { [] }
    static func interruptedStep() -> String? { nil }
    static func previousLastLine() -> String? { nil }
    static func clear() {}
}
