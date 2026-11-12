import Foundation

// 1.8.18 收尾：进程内存采样与播放双心跳已移除。
// 保留签名作为兼容层，全部空操作，不再有定时采样、mach 调用与峰值落盘。

enum MemoryProbe {
    static func residentMB() -> Int { 0 }
    static func footprintMB() -> Int { 0 }
    static func record() -> Int { 0 }
    static func peakMB() -> Int { 0 }
    static func footprintPeakMB() -> Int { 0 }
    static func summary() -> String { "—" }
    static func resetPeak() {}
}

final class PlaybackHeartbeat {
    static let shared = PlaybackHeartbeat()
    func start(_ title: String) {}
    func stop() {}
}
