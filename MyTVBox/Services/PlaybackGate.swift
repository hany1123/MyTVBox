import Foundation

// MARK: - 起播闸门（1.8.15）
//
// 1.8.14 诊断的最后一帧：播放开始前 `work=1`，`完重活` 落在播放开始之后，
// Node 的 /detail 回包一直持续到播放期，App 心跳末段 foot/rss 各 +15MB，
// 3 秒后进程被无声回收。也就是说「发个取消请求就起播」根本没等请求退场：
//
//   Task { await HeavyWorkGate.shared.requestCancelCurrent() }
//   model.start()      <- 取消还在半路，/play 与 AVAsset 已经压上来了
//
// 这里做两件以前没做的事：
//   ① 记所有在飞 HTTP 请求（Node /spider 与标准 CMS 都算）；
//   ② 起播前先请重活收手，再**等待**在飞计数归零（有上限，不卡死用户）。
// 播放期间 HeavyWorkGate 会拒绝新的整站级重活。
//
// 刻意用 NSLock + 同步方法而不是 actor：底层网络函数要在 defer 里还计数，
// 同步调用最稳，不会出现「defer 里起 Task 滞后归还」导致的计数漂移。

final class PlaybackGate {

    static let shared = PlaybackGate()

    private let lock = NSLock()
    private var inflight = 0
    private var playbackActive = false

    // MARK: - 在飞请求

    /// 每个 HTTP 请求开始时 +1，defer 里 -1
    func beginRequest() {
        lock.lock(); inflight += 1; lock.unlock()
    }

    func endRequest() {
        lock.lock(); inflight = max(0, inflight - 1); lock.unlock()
    }

    func inflightCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return inflight
    }

    // MARK: - 播放期

    func enterPlayback() {
        lock.lock(); playbackActive = true; lock.unlock()
    }

    func leavePlayback() {
        lock.lock(); playbackActive = false; lock.unlock()
    }

    /// 同步读取，供 HeavyWorkGate.acquire() 在 actor 内直接判断
    var isPlaybackActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return playbackActive
    }

    // MARK: - 起播前收口

    /// 请整站级重活收手 → 轮询等在飞请求归零。
    /// 返回 (是否已归零, 剩余在飞数)。超时也照常起播，只留痕。
    func drainForPlayback(timeout: TimeInterval) async -> (drained: Bool, remaining: Int) {
        let start = Date()
        let before = inflightCount()
        await HeavyWorkGate.shared.requestCancelCurrent()
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while inflightCount() > 0, Date() < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        let remaining = inflightCount()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        SessionTrace.mark("记 播放 起播前收口 \(ms)ms · 在飞 \(before)→\(remaining)"
                          + (remaining == 0 ? " · 已归零" : " · 超时放行"))
        return (remaining == 0, remaining)
    }

    /// 诊断页展示用
    func statusText() -> String {
        "播放期=\(isPlaybackActive ? "是" : "否") · 在飞请求 \(inflightCount()) 条"
    }
}
