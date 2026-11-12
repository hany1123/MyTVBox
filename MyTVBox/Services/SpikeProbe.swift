import Foundation

// 1.8.18 收尾：/play 100ms 高频内存尖峰采样已移除。
// 保留签名作为兼容层，全部空操作，不再写 spike.log。

final class SpikeProbe {
    struct Window {
        var describe: String { "" }
    }
    static let shared = SpikeProbe()
    func boot() {}
    func start(_ label: String) {}
    func stop(_ label: String) {}
    func windows() -> [Window] { [] }
    func recentWindows(_ n: Int = 2) -> [Window] { [] }
}
