import Foundation
import AVKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class VideoPlayerViewModel: ObservableObject {

    // MARK: - Published State

    @Published var currentEpisodeIndex: Int = 0
    @Published var currentSourceIndex: Int = 0
    @Published var playbackRate: Float = 1.0
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// 首帧未就绪（AVPlayerItem 还没 readyToPlay）
    @Published var isLoading: Bool = true
    /// 已经开始播但当前在等数据（真正意义的「卡缓冲」）
    @Published var isBuffering: Bool = false
    /// 已缓冲进度 0...1，给进度条画浅色预读段
    @Published var bufferedRatio: Double = 0
    /// 当前播放点前面还有多少秒已缓存
    @Published var bufferedAhead: Double = 0
    @Published var errorMessage: String?
    /// 线路过慢提示
    @Published var slowLineHint: String?
    /// 自动切换线路时的提示（如「正在切到 XX」）
    @Published var autoSwitchHint: String?

    /// 中心按钮该转圈吗
    var isStalling: Bool { isLoading || isBuffering }

    // MARK: - Player

    let player = AVPlayer()

    // MARK: - Context

    let videoDetail: VideoDetail
    private(set) var sources: [PlaySource]

    var currentSource: PlaySource? {
        guard sources.indices.contains(currentSourceIndex) else { return nil }
        return sources[currentSourceIndex]
    }

    var currentEpisode: PlayURL? {
        guard let src = currentSource,
              src.episodes.indices.contains(currentEpisodeIndex) else { return nil }
        return src.episodes[currentEpisodeIndex]
    }

    // MARK: - Internals

    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var bgObserver: NSObjectProtocol?
    private var fgObserver: NSObjectProtocol?
    private var didRestoreProgress = false
    private var currentURLString: String?
    private var slowTimer: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?

    /// 自动换源状态：本次播放已试过的线路下标
    private var autoTriedSources: Set<Int> = []
    /// 连续处在缓冲状态的时间起点
    private var bufferingSince: Date?

    /// 已解析过的 asset（复用可跳过 m3u8 多级 playlist 的重新拉取）
    private var assetCache: [String: AVURLAsset] = [:]
    private var assetOrder: [String] = []
    private static let assetCacheLimit = 3

    // MARK: - 播放参数

    /// 预读缓冲时长（秒）。系统默认 0 = 自适应，通常只留 2~3 秒，稍微抖一下就卡
    private let forwardBufferSeconds: Double = 6
    /// 超过这个时间还没 readyToPlay 就提示线路慢
    private let slowLineThreshold: Double = 12
    /// 连续缓冲超过这个时间就自动换一条线路
    private let bufferingSwitchThreshold: TimeInterval = 20
    /// 单次播放最多自动尝试几条线路
    private let maxAutoSwitch = 8

    // MARK: - Init

    init(videoDetail: VideoDetail,
         sources: [PlaySource],
         initialSourceIndex: Int = 0,
         initialEpisodeIndex: Int = 0) {
        self.videoDetail = videoDetail
        self.sources = sources
        self.currentSourceIndex = max(0, min(initialSourceIndex, max(sources.count - 1, 0)))
        let epCount = sources.indices.contains(self.currentSourceIndex)
            ? sources[self.currentSourceIndex].episodes.count : 0
        self.currentEpisodeIndex = max(0, min(initialEpisodeIndex, max(epCount - 1, 0)))

        // 缓冲不足时让系统自动等待并在恢复后继续播放。
        // 设成 false 会「缓冲即暂停且不再自动恢复」——1.4.5 的回归就出在这里。
        player.automaticallyWaitsToMinimizeStalling = true

        configureAudioSession()
        attachObservers()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = failObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = bgObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = fgObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        statusObservation?.invalidate()
        rateObservation?.invalidate()
        keepUpObservation?.invalidate()
        bufferEmptyObservation?.invalidate()
        slowTimer?.cancel()
        prewarmTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Lifecycle

    /// 视图出现时调用：开始首次播放（处理续播）
    /// 若当前线路是网页地址（需解析器），自动切到第一条可直连的线路
    func start() {
        if let ep = currentEpisode, PlayURL.isDirectPlayable(url: ep.url),
           let url = URL(string: ep.url) {
            loadAndPlay(url: url, restoreProgress: true)
            return
        }
        // 自动降级：找第一条能直连的线路
        if let fallback = firstPlayableSourceIndex() {
            currentSourceIndex = fallback
            let eps = sources[fallback].episodes
            let keep = eps.indices.contains(currentEpisodeIndex) ? currentEpisodeIndex : 0
            currentEpisodeIndex = keep
            if let url = URL(string: eps[keep].url) {
                loadAndPlay(url: url, restoreProgress: true)
                return
            }
        }
        errorMessage = "所有线路都需要解析器\n当前版本只能播放 M3U8 直链"
    }

    /// 返回第一条含可直连地址的线路下标
    private func firstPlayableSourceIndex() -> Int? {
        for (i, src) in sources.enumerated() {
            if src.episodes.contains(where: { PlayURL.isDirectPlayable(url: $0.url) }) {
                return i
            }
        }
        return nil
    }

    /// 针对不同「不可直连」地址给出可操作的提示
    private func playbackHint(url: String) -> String {
        let lower = url.lowercased()
        let netdiskHosts = ["pan.quark.cn", "pan.baidu.com", "aliyundrive.com",
                            "alipan.com", "cloud.189.cn", "caiyun.139.com",
                            "115.com", "123pan.com", "xunlei.com"]
        if netdiskHosts.contains(where: { lower.contains($0) }) {
            return "这是网盘资源，需在网盘 App 内打开"
        }
        if lower.contains("/share/") || lower.contains("/play/") {
            return "该线路是网页分享页，需要解析器\n请切换到 M3U8 线路"
        }
        return "无法识别的播放地址\n请切换到其他线路"
    }

    // MARK: - Episode / Source

    func playEpisode(at index: Int) {
        guard let src = currentSource, src.episodes.indices.contains(index) else { return }
        saveProgress()
        autoTriedSources.removeAll()
        autoSwitchHint = nil
        currentEpisodeIndex = index
        let ep = src.episodes[index]
        guard let url = URL(string: ep.url) else {
            errorMessage = "无效的播放地址"
            return
        }
        guard PlayURL.isDirectPlayable(url: ep.url) else {
            errorMessage = playbackHint(url: ep.url)
            return
        }
        loadAndPlay(url: url, restoreProgress: false)
    }

    func switchSource(to index: Int) {
        guard sources.indices.contains(index) else { return }
        saveProgress()
        // 用户手动选线路 → 重置自动切换记录
        autoTriedSources.removeAll()
        autoSwitchHint = nil
        let preservedTime = currentTime
        currentSourceIndex = index
        // 集数索引超界则回 0
        let epCount = sources[index].episodes.count
        if currentEpisodeIndex >= epCount { currentEpisodeIndex = 0 }
        guard sources[index].episodes.indices.contains(currentEpisodeIndex) else { return }
        let ep = sources[index].episodes[currentEpisodeIndex]
        guard let url = URL(string: ep.url) else {
            errorMessage = "无效的播放地址"
            return
        }
        guard PlayURL.isDirectPlayable(url: ep.url) else {
            errorMessage = playbackHint(url: ep.url)
            return
        }
        // 切线路尝试保留进度
        loadAndPlay(url: url, restoreProgress: false, seekTo: preservedTime)
    }

    func playNextEpisode() {
        guard let src = currentSource else { return }
        let next = currentEpisodeIndex + 1
        if next < src.episodes.count {
            playEpisode(at: next)
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
            player.rate = playbackRate
        }
    }

    /// 拖动定位。
    /// 宽容差 = 直接落到最近的关键帧，HLS 上比逐帧精确定位快得多。
    func seek(to seconds: Double, precise: Bool = false) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        if precise {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
        currentTime = seconds
    }

    func skip(by delta: Double) {
        let target = max(0, min(currentTime + delta, duration))
        seek(to: target)
    }

    // MARK: - Rate

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if player.timeControlStatus == .playing {
            player.rate = rate
        }
    }

    // MARK: - Progress Persistence

    func saveProgress() {
        guard duration > 0, currentTime > 3 else { return }
        let epName = currentEpisode?.name ?? "第\(currentEpisodeIndex + 1)集"
        let record = PlayHistoryManager.PlayRecord(
            vodId: videoDetail.vodId,
            vodName: videoDetail.vodName,
            vodPic: videoDetail.vodPic,
            episodeName: epName,
            sourceIndex: currentSourceIndex,
            episodeIndex: currentEpisodeIndex,
            progress: currentTime,
            duration: duration,
            timestamp: Date()
        )
        PlayHistoryManager.shared.saveRecord(record)
    }

    func loadProgress() -> Double? {
        guard let rec = PlayHistoryManager.shared.getRecord(vodId: videoDetail.vodId),
              rec.sourceIndex == currentSourceIndex,
              rec.episodeIndex == currentEpisodeIndex,
              rec.progress > 5,
              rec.progress < rec.duration - 10
        else { return nil }
        return rec.progress
    }

    // MARK: - Picture in Picture

    /// AVPlayerViewController 的 allowsPictureInPicturePlayback 需在 VC 上设置；
    /// 这里仅做音频会话配置，PiP 真实启动由系统按钮控制。
    func enablePiP() {
        configureAudioSession()
    }

    // MARK: - Background Audio

    /// 转后台音频播放 — 交给 AudioPlayerManager 接手，锁屏可听
    func switchToBackgroundAudio() {
        saveProgress()
        guard let src = currentSource,
              src.episodes.indices.contains(currentEpisodeIndex) else { return }
        let ep = src.episodes[currentEpisodeIndex]
        AudioPlayerManager.shared.play(episode: ep, in: src.episodes)
        AudioPlayerManager.shared.updateNowPlayingInfo(
            title: videoDetail.vodName,
            artist: nil,
            artwork: nil
        )
    }

    // MARK: - Internal helpers

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    /// 启用/禁用视频轨道（后台时禁用视频，音频继续播放）
    private func setVideoTracksEnabled(_ enabled: Bool) {
        guard let item = player.currentItem else { return }
        for track in item.tracks {
            if let assetTrack = track.assetTrack, assetTrack.mediaType == .video {
                track.isEnabled = enabled
            }
        }
    }

    // MARK: - Asset / Item 构造

    /// 采集站 CDN 普遍做 UA / Referer 校验：默认的 AppleCoreMedia UA 常被降速甚至限流。
    /// 换成 Safari UA + 站点根域 Referer，能明显改善拉流速度。
    private func makeAsset(for url: URL) -> AVURLAsset {
        let key = url.absoluteString
        if let cached = assetCache[key] {
            return cached
        }

        var headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1",
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        if let scheme = url.scheme, let host = url.host {
            headers["Referer"] = "\(scheme)://\(host)/"
            headers["Origin"] = "\(scheme)://\(host)"
        }

        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetAllowsCellularAccess": true
        ]
        let asset = AVURLAsset(url: url, options: options)

        assetCache[key] = asset
        assetOrder.removeAll { $0 == key }
        assetOrder.append(key)
        while assetOrder.count > Self.assetCacheLimit {
            let old = assetOrder.removeFirst()
            assetCache.removeValue(forKey: old)
        }
        return asset
    }

    private func makeItem(for url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(asset: makeAsset(for: url))
        // 多留点预读，减少抖动导致的卡顿（只影响后台预读，不影响起播）
        item.preferredForwardBufferDuration = forwardBufferSeconds
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    /// 提前解析下一集的 asset（m3u8 主列表 + 子列表可能要 2~3 次往返），
    /// 切集时直接命中缓存，省掉整轮 DNS / TLS 握手与 playlist 解析。
    private func prewarmNextEpisode() {
        guard let src = currentSource else { return }
        let next = currentEpisodeIndex + 1
        guard src.episodes.indices.contains(next),
              PlayURL.isDirectPlayable(url: src.episodes[next].url),
              let url = URL(string: src.episodes[next].url) else { return }

        // 放进 asset 缓存，切集时直接复用
        _ = makeAsset(for: url)

        let urlString = url.absoluteString
        prewarmTask?.cancel()
        prewarmTask = Task {
            // 只解析不播放，失败静默；系统会因此对同 host 建立并保留连接
            guard let target = URL(string: urlString) else { return }
            let asset = AVURLAsset(url: target)
            _ = try? await asset.load(.isPlayable)
        }
    }

    private func cancelPrewarm() {
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    // MARK: - 加载与播放

    private func loadAndPlay(url: URL, restoreProgress: Bool, seekTo: Double? = nil) {
        let urlString = url.absoluteString
        bufferingSince = nil

        // 同一地址重入（比如误触重播）：只 seek，不重建 item，避免整轮重新缓冲
        if urlString == currentURLString,
           let item = player.currentItem, item.status == .readyToPlay {
            if let s = seekTo, s > 0 {
                seek(to: s)
            } else if restoreProgress, !didRestoreProgress, let p = loadProgress() {
                didRestoreProgress = true
                seek(to: p)
            }
            player.play()
            player.rate = playbackRate
            return
        }

        // 换片前先停掉旧 item 的拉流，别让两条流抢带宽
        player.pause()
        cancelPrewarm()

        currentURLString = urlString
        isLoading = true
        isBuffering = false
        bufferedRatio = 0
        bufferedAhead = 0
        slowLineHint = nil
        currentTime = 0
        duration = 0
        errorMessage = nil

        let item = makeItem(for: url)
        player.replaceCurrentItem(with: item)

        observe(item: item, restoreProgress: restoreProgress, seekTo: seekTo)
        observeEnd(of: item)
        startSlowLineWatchdog()
    }

    private func observe(item: AVPlayerItem, restoreProgress: Bool, seekTo: Double?) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.slowLineHint = nil
                    self.slowTimer?.cancel()
                    let dur = item.duration.seconds
                    if dur.isFinite { self.duration = dur }
                    // 续播：宽容差定位，避免精确 seek 触发重新拉整段分片
                    if restoreProgress, !self.didRestoreProgress, let p = self.loadProgress() {
                        self.didRestoreProgress = true
                        self.seek(to: p)
                    } else if let s = seekTo, s > 0 {
                        self.seek(to: s)
                    }
                    self.player.play()
                    self.player.rate = self.playbackRate
                    // 稳定播放几秒后撤掉「正在切换」提示
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run { [weak self] in
                            self?.autoSwitchHint = nil
                        }
                    }
                    // 起播稳定后再预热下一集，避免和当前流抢带宽
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.prewarmNextEpisode()
                    }
                case .failed:
                    self.isLoading = false
                    self.isBuffering = false
                    self.slowTimer?.cancel()
                    // 不直接报错，先自动换下一条线路
                    self.autoSwitchSource(reason: "当前线路播放失败")
                default:
                    break
                }
            }
        }

        keepUpObservation?.invalidate()
        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshBufferingState() }
        }

        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshBufferingState() }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = failObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.playNextEpisode()
            }
        }
        // 播放中途失败（分片 404 / 会话失效）也触发自动换线路
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.autoSwitchSource(reason: "播放中断")
            }
        }
    }

    /// 12 秒还没出画面 → 先提示；再等 8 秒仍没出画面 → 自动换线路
    private func startSlowLineWatchdog() {
        slowTimer?.cancel()
        let hintAt = slowLineThreshold
        let switchDelay = 8.0
        slowTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hintAt * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self = self, self.isLoading else { return }
                self.slowLineHint = "当前线路较慢，正在准备切换…"
            }
            try? await Task.sleep(nanoseconds: UInt64(switchDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self = self, self.isLoading else { return }
                self.autoSwitchSource(reason: "线路连接超时")
            }
        }
    }

    private func refreshBufferingState() {
        guard let item = player.currentItem else {
            isBuffering = false
            bufferingSince = nil
            return
        }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let empty = item.isPlaybackBufferEmpty
        let keepUp = item.isPlaybackLikelyToKeepUp
        // 只有「已经在放/该放却拿不到数据」才算卡缓冲；首帧阶段算 isLoading
        let now = !isLoading && (waiting || (empty && !keepUp))
        isBuffering = now
        if now {
            if bufferingSince == nil { bufferingSince = Date() }
        } else {
            bufferingSince = nil
        }
    }

    /// 每 0.5s 由 timeObserver 调用：连续缓冲超过阈值就自动切线路。
    /// 正常的几秒等待由系统自动恢复，不会走到这里。
    private func checkBufferingTimeout() {
        guard let since = bufferingSince,
              Date().timeIntervalSince(since) >= bufferingSwitchThreshold else { return }
        bufferingSince = nil
        autoSwitchSource(reason: "线路缓冲超时")
    }

    /// 多源自动切换：当前线路失败 / 超时 / 卡住时，自动切到下一条可直连的线路。
    /// 保留当前集数与播放进度；已试过的线路不会重复尝试。
    private func autoSwitchSource(reason: String) {
        guard sources.count > 1 else {
            errorMessage = "\(reason)\n该片只有一条线路，建议换一个站点搜索"
            slowLineHint = nil
            return
        }
        guard autoTriedSources.count < maxAutoSwitch else {
            errorMessage = "\(reason)\n已自动尝试多条线路均失败，建议切换站点"
            slowLineHint = nil
            return
        }
        autoTriedSources.insert(currentSourceIndex)

        let count = sources.count
        for step in 1...count {
            let idx = (currentSourceIndex + step) % count
            if autoTriedSources.contains(idx) { continue }
            let eps = sources[idx].episodes
            let epIdx = eps.indices.contains(currentEpisodeIndex) ? currentEpisodeIndex : 0
            guard eps.indices.contains(epIdx),
                  PlayURL.isDirectPlayable(url: eps[epIdx].url),
                  let url = URL(string: eps[epIdx].url) else { continue }

            let resumeAt = currentTime
            autoTriedSources.insert(idx)
            currentSourceIndex = idx
            currentEpisodeIndex = epIdx
            autoSwitchHint = "自动切换线路 → \(sources[idx].name)"
            errorMessage = nil
            slowLineHint = nil
            loadAndPlay(url: url, restoreProgress: false, seekTo: resumeAt)
            return
        }
        errorMessage = "\(reason)\n所有线路都不可用，建议切换站点"
        slowLineHint = nil
    }

    private func updateBufferedProgress() {
        guard let item = player.currentItem, duration > 0 else {
            bufferedRatio = 0
            bufferedAhead = 0
            return
        }
        var maxEnd: Double = 0
        var ahead: Double = 0
        let t = currentTime
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            guard start.isFinite, end.isFinite else { continue }
            maxEnd = max(maxEnd, end)
            if t >= start - 1, t <= end {
                ahead = max(ahead, end - t)
            }
        }
        bufferedRatio = min(1, max(0, maxEnd / duration))
        bufferedAhead = max(0, ahead)
    }

    private func attachObservers() {
        // Time
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if self.duration <= 0,
                   let dur = self.player.currentItem?.duration.seconds,
                   dur.isFinite {
                    self.duration = dur
                }
                self.updateBufferedProgress()
                self.checkBufferingTimeout()
            }
        }
        // Rate / playing / waiting
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isPlaying = (player.timeControlStatus == .playing)
                self.refreshBufferingState()
            }
        }

        // 后台/前台切换 — 禁用视频轨道以保活音频
        bgObserver = NotificationCenter.default.addObserver(
            forName: .appDidEnterBackground, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setVideoTracksEnabled(false)
            }
        }
        fgObserver = NotificationCenter.default.addObserver(
            forName: .appWillEnterForeground, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setVideoTracksEnabled(true)
            }
        }
    }
}
