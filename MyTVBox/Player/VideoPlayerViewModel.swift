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
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?

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
    private var endObserver: NSObjectProtocol?
    private var bgObserver: NSObjectProtocol?
    private var fgObserver: NSObjectProtocol?
    private var didRestoreProgress = false

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
        if let obs = bgObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = fgObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        statusObservation?.invalidate()
        rateObservation?.invalidate()
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

    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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

    private func loadAndPlay(url: URL, restoreProgress: Bool, seekTo: Double? = nil) {
        isLoading = true
        currentTime = 0
        duration = 0
        errorMessage = nil

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        // 重新挂载状态观察
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    let dur = item.duration.seconds
                    if dur.isFinite { self.duration = dur }
                    // 续播
                    if restoreProgress, !self.didRestoreProgress, let p = self.loadProgress() {
                        self.didRestoreProgress = true
                        self.seek(to: p)
                    } else if let s = seekTo, s > 0 {
                        self.seek(to: s)
                    }
                    self.player.play()
                    self.player.rate = self.playbackRate
                case .failed:
                    self.isLoading = false
                    self.errorMessage = item.error?.localizedDescription ?? "播放失败"
                default:
                    break
                }
            }
        }

        // 重新挂载结束监听
        if let obs = endObserver {
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
            }
        }
        // Rate / playing
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isPlaying = (player.timeControlStatus == .playing)
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
