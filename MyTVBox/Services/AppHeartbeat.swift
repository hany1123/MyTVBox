import Foundation

// 1.8.18 收尾：App 级常驻心跳 / 运行时状态已移除。
// 保留签名作为兼容层，全部空操作，不再有 200ms/1s 定时器与 appbeat.log。

final class AppRuntimeState {
    static let shared = AppRuntimeState()
    func set(foreground v: Bool) {}
    func set(playing v: Bool) {}
    func set(stage v: String) {}
    func beginWork() {}
    func endWork() {}
    func snapshot() -> (fg: Bool, play: Bool, work: Int, stage: String) {
        (true, false, 0, "home")
    }
}

final class AppHeartbeat {
    static let shared = AppHeartbeat()
    func boot() {}
    func start() {}
    func setFast(_ on: Bool) {}
    func mark(_ text: String) {}
    func windows() -> [[String]] { [] }
    func previousWindow() -> [String] { [] }
    func currentWindow() -> [String] { [] }
    static func footValues(_ lines: [String]) -> [Int] { [] }
}
