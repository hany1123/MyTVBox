import Foundation
import AVKit
import AVFoundation
import Combine
import SwiftUI
import UIKit

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
    /// 站点级换源成功后的站点名
    @Published var activeSiteName: String?
    /// m3u8 广告过滤结果（短暂显示）
    @Published var adFilterHint: String?

    /// 中心按钮该转圈吗
    var isStalling: Bool { isLoading || isBuffering }

    // MARK: - Player

    let player = AVPlayer()

    // MARK: - Context

    /// 站点级换源后会整体替换，故为 var
    var videoDetail: VideoDetail
    var sources: [PlaySource]

    /// 当前配置里的解析规则（由 View 注入）；非直链线路靠它兑换 m3u8
    var parseRules: [ParseRule] = []
    /// 1.5.4：本片所属站点；JS Spider 站点的集地址要先调 play() 换真实地址
    var spiderSite: Site?

    /// 进度记录用的原始影片 ID：跨站点换源后仍归到同一条记录，避免进度散落
    private let progressKey: String

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
    /// 1.5.2 本次播放会话「最后确认过的真实播放位置」。
    /// loadAndPlay 重建 item 会把 currentTime 归零；自动换源若发生在首帧之前
    /// 就会拿到 0。这个锚点不会被清零，连续多次换源也不会丢进度。
    private var sessionResumeAnchor: Double = 0
    /// 正在执行续播 seek：期间 timeObserver 不得用播放器旧时间覆盖进度
    private var isApplyingSeek = false
    /// 提示自动消失的计时任务（1.5.2 统一控制停留时长）
    private var hintClearTask: Task<Void, Never>?
    private var slowTimer: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    /// 每次「主动发起播放」自增；异步解析回来后用它判断是否已经切集/换源，
    /// 避免旧线路的解析结果把新线路顶掉。
    private var playEpoch: UInt64 = 0

    /// 自动换源状态：本次播放已试过的线路下标
    private var autoTriedSources: Set<Int> = []
    /// 1.8.8：短时窗口限流。AVPlayerItem 的 failed 回调可能连发，
    /// 旧版每次都立刻换线路、耗尽后直接启动整站级跨站搜索。
    private var lastAutoSwitchAt: Date = .distantPast
    private var autoSwitchBurst: Int = 0
    /// 本次运行内一旦自定义 scheme 加载失败，就永久退回直连，不再尝试过滤
    private var adProxyBypassed = false
    /// 跨站点换源已经试过的站点（含当前站点），避免来回切同一个坏站
    private var triedSiteKeys: Set<String> = []
    /// 本片所属站点，换源时作为第一排除项
    var originSiteKey: String?
    /// 是否正在跨站点搜索（防止多个失败回调并发触发多次换源）
    private var isCrossSiteSwitching = false
    /// 线路全部耗尽时的兜底：片名 / 集序号 / 进度 / 排除站点 → 可播放候选
    var onCrossSiteFallback: (@MainActor (String, Int, Double, Set<String>) async -> CrossSiteResolver.CrossSitePlayable?)?
    /// 连续处在缓冲状态的时间起点
    private var bufferingSince: Date?

    /// 已解析过的 asset（复用可跳过 m3u8 多级 playlist 的重新拉取）
    private var assetCache: [String: AVURLAsset] = [:]
    private var assetOrder: [String] = []
    private static let assetCacheLimit = 3

    // MARK: - 播放参数

    /// 预读缓冲时长（秒）。1.8.4：6 → 2。
    /// 端上 Node 与 AVPlayer 在**同一个进程**里，6 秒预读会让视频缓冲区
    /// 长期占着几十 MB；播放页实测 9 秒就被系统回收，先把它压到够用的 2 秒。
    private let forwardBufferSeconds: Double = 2
    /// 超过这个时间还没 readyToPlay 就提示线路慢
    private let slowLineThreshold: Double = 12
    /// 连续缓冲超过这个时间就自动换一条线路（1.4.9 从 20s 收紧到 12s，
    /// 「播放卡顿时自动切换源」要够快才有用）
    private let bufferingSwitchThreshold: TimeInterval = 12
    /// 单次播放最多自动尝试几条线路
    private let maxAutoSwitch = 12

    /// 1.5.2 自动换源总开关（默认开）。用 object(forKey:) 判空，
    /// 避免 UserDefaults 尚未写入时 bool(forKey:) 返回 false 把默认行为改成关闭。
    private var autoSwitchEnabled: Bool {
        (UserDefaults.standard.object(forKey: "MyTVBox.autoSwitchEnabled") as? Bool) ?? true
    }
    /// 云端清洗失败过一次后，本次会话不再重复等待，避免每条线路都卡 3.5 秒
    private var cloudCleanFailed = false
    /// Spider play() 返回的自定义请求头（Referer / UA 等）
    private var spiderHeaders: [String: String] = [:]

    // MARK: - Init

    init(videoDetail: VideoDetail,
         sources: [PlaySource],
         initialSourceIndex: Int = 0,
         initialEpisodeIndex: Int = 0) {
        self.videoDetail = videoDetail
        self.sources = sources
        self.progressKey = videoDetail.vodId
        self.currentSourceIndex = max(0, min(initialSourceIndex, max(sources.count - 1, 0)))
        let epCount = sources.indices.contains(self.currentSourceIndex)
            ? sources[self.currentSourceIndex].episodes.count : 0
        self.currentEpisodeIndex = max(0, min(initialEpisodeIndex, max(epCount - 1, 0)))

        // 缓冲不足时让系统自动等待并在恢复后继续播放。
        // 设成 false 会「缓冲即暂停且不再自动恢复」——1.4.5 的回归就出在这里。
        player.automaticallyWaitsToMinimizeStalling = true

        configureAudioSession()
        attachObservers()

        // 1.8.4：播放页收到内存警告时主动释放 asset 缓存 / 取消预热。
        // 视频缓冲是可重建的，进程被 Jetsam 杀掉才是不可逆的。
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelPrewarm()
                self.assetCache.removeAll()
                self.assetOrder.removeAll()
                SessionTrace.mark("警 播放页内存警告 → 清 asset 缓存")
            }
        }
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
    /// 直链直接播；网页型地址（官源 / 分享页）交给解析层换 m3u8，
    /// 解析不出来时由 autoSwitchSource 自动切到其它线路。
    func start() {
        if let ep = currentEpisode, let url = URL(string: ep.url) {
            loadAndPlay(url: url, restoreProgress: true)
            return
        }
        attemptCrossSite(reason: "没有可用的播放地址")
    }

    /// 返回第一条含可直连地址的线路下标
    private func firstPlayableSourceIndex() -> Int? {
        for (i, src) in sources.enumerated() {
            if src.episodes.contains(where: { PlayURL.isPlayableCandidate(url: $0.url) }) {
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
        // 换集必须清掉上一集的锚点，否则自动换源会续到上一集的位置
        resetResumeAnchor()
        autoTriedSources.removeAll()
        showHint(nil)
        currentEpisodeIndex = index
        let ep = src.episodes[index]
        guard let url = URL(string: ep.url) else {
            errorMessage = "无效的播放地址"
            return
        }
        // 网页型地址不再直接拒绝，交给解析层兑换
        loadAndPlay(url: url, restoreProgress: false)
    }

    func switchSource(to index: Int) {
        guard sources.indices.contains(index) else { return }
        saveProgress()
        // 用户手动选线路 → 重置自动切换记录
        autoTriedSources.removeAll()
        showHint(nil)
        let preservedTime = max(currentTime, sessionResumeAnchor)
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
        // 切线路尝试保留进度；网页型地址由解析层接管
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
        // 1.5.2 手动拖动也算新的续播锚点
        sessionResumeAnchor = seconds
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
        let at = max(currentTime, sessionResumeAnchor)
        guard duration > 0, at > 3 else { return }
        let epName = currentEpisode?.name ?? "第\(currentEpisodeIndex + 1)集"
        let record = PlayHistoryManager.PlayRecord(
            vodId: progressKey,
            vodName: videoDetail.vodName,
            vodPic: videoDetail.vodPic,
            episodeName: epName,
            sourceIndex: currentSourceIndex,
            episodeIndex: currentEpisodeIndex,
            progress: at,
            duration: duration,
            timestamp: Date()
        )
        PlayHistoryManager.shared.saveRecord(record)
    }

    func loadProgress() -> Double? {
        guard let rec = PlayHistoryManager.shared.getRecord(vodId: progressKey),
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

    /// 只对 HLS 走自定义 scheme 由 AVAssetResourceLoader 清洗广告；mp4 等保持直连。
    /// 开关关闭、或本次运行已判定过滤不可用时，完全退回 1.4.6 的直连地址。
    private func applyAdProxy(to url: URL) -> URL {
        let lower = url.absoluteString.lowercased()
        guard !adProxyBypassed,
              LocalPlaylistProxy.isEnabled,
              lower.contains(".m3u8") || lower.contains("/hls/"),
              let proxied = LocalPlaylistProxy.proxiedURL(for: url) else {
            return url
        }
        return proxied
    }

    /// 采集站 CDN 普遍做 UA / Referer 校验：默认的 AppleCoreMedia UA 常被降速甚至限流。
    /// 换成 Safari UA + 站点根域 Referer，能明显改善拉流速度。
    private func makeAsset(for originalURL: URL) -> AVURLAsset {
        let url = applyAdProxy(to: originalURL)
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
        // 走自定义 scheme 时防盗链头必须仍按原始资源站计算
        if let scheme = originalURL.scheme, let host = originalURL.host {
            headers["Referer"] = "\(scheme)://\(host)/"
            headers["Origin"] = "\(scheme)://\(host)"
        }
        // 1.5.4：Spider play() 指定的头优先（它比我们猜的防盗链更准）
        if !spiderHeaders.isEmpty {
            headers.merge(spiderHeaders) { _, new in new }
        }

        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetAllowsCellularAccess": true
        ]
        let asset = AVURLAsset(url: url, options: options)
        if LocalPlaylistProxy.isProxied(url) {
            HLSPlaylistLoader.shared.attach(to: asset)
        }

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
        item.preferredForwardBufferDuration = forwardBufferSeconds
        // 1.8.4：限制 HLS 变体峰值码率。猫爪源不少线路是 4K/高码率 master playlist，
        // AVPlayer 默认会挑它能扛的最高档 —— 解码缓冲区 + Node 的 V8 堆同时顶上来，
        // 就是播放页被 Jetsam 的典型姿势。3 Mbps 足够手机/投影清晰播放。
        item.preferredPeakBitRate = 3_000_000
        // 暂停时不再继续吃带宽/内存预读（旧值 true 会在后台一直缓冲）
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
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

        // 1.8.4：删掉「再建一个 AVURLAsset 并 load(.isPlayable)」这一步。
        // 旧版在起播后 3 秒就会额外拉一条 HLS playlist，等于和正在缓冲的主流
        // 抢带宽、抢内存；1.8.3 真机崩在「开 播放」后约 9 秒，正好落在这个窗口。
        // 现在只保留上面那一步轻量缓存，切集仍然能省掉 asset 构造。
    }

    private func cancelPrewarm() {
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    // MARK: - 1.5.4 Spider play() 结果解析

    /// 1.8.8：只记「URL 形态」的最小信息，不落完整地址 —— 播放直链常带
    /// token/签名，写进 breadcrumb.log 不合适。scheme / host / path 前缀 /
    /// 参数个数已经足够判断「AVFoundation 为什么会报 unsupported URL」。
    static func urlDigest(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "(无scheme)"
        let host = url.host ?? "(无host)"
        let path = url.path.isEmpty ? "/" : String(url.path.prefix(48))
        let qCount = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.count ?? 0
        return "\(scheme)://\(host)\(path) · 参数\(qCount)项"
    }

    /// Spider 的 play() 可能返回 {url}、{data:{url}}，也可能返回 JSON 字符串
    private static func extractPlayURL(from dict: [String: Any]) -> String? {
        for k in ["url", "playUrl", "play_url", "m3u8", "data"] {
            if let s = dict[k] as? String, s.lowercased().hasPrefix("http") { return s }
            if let d = dict[k] as? [String: Any],
               let s = d["url"] as? String, s.lowercased().hasPrefix("http") { return s }
        }
        for (_, v) in dict {
            guard let s = v as? String, s.contains("http"),
                  let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let j = obj as? [String: Any],
                  let u = j["url"] as? String else { continue }
            return u
        }
        return nil
    }

    private static func extractHeaders(from dict: [String: Any]) -> [String: String] {
        for k in ["header", "headers"] {
            if let h = dict[k] as? [String: String] { return h }
            if let h = dict[k] as? [String: Any] {
                var out: [String: String] = [:]
                for (key, value) in h { out[key] = "\(value)" }
                return out
            }
        }
        return [:]
    }

    // MARK: - 1.5.2 提示时长 / 稳健续播

    /// 统一控制「正在切线路 / 解析 / 去广告」这类提示的停留时长。
    /// hold=nil 表示粘性提示（等后续状态覆盖），否则到点自动消失。
    /// 旧实现只在 readyToPlay 后固定等 4 秒才清，云端清洗又要等 8 秒，
    /// 叠加起来转圈浮层能挡十几秒，观感上像卡死。
    private func showHint(_ text: String?, hold: TimeInterval? = 2.0) {
        hintClearTask?.cancel()
        hintClearTask = nil
        autoSwitchHint = text
        guard let text, let hold, hold > 0 else { return }
        hintClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.autoSwitchHint == text else { return }
            self.autoSwitchHint = nil
        }
    }

    /// 换集时清空上一集的续播状态
    private func resetResumeAnchor() {
        sessionResumeAnchor = 0
        isApplyingSeek = false
        didRestoreProgress = false
        hintClearTask?.cancel()
        hintClearTask = nil
    }

    /// 1.5.2 稳健续播。
    ///
    /// 旧实现只在 readyToPlay 里一次性 seek(to:)，有三个坑：
    /// 1. HLS 刚 ready 时 seekableTimeRanges 常常还是空的，seek 被静默丢弃 → 从头播；
    /// 2. 没有 completion 校验，失败也不知道；
    /// 3. timeObserver 每 0.5s 用播放器旧时间覆盖 currentTime，把续播锚点冲掉。
    /// 现在改成：等待可 seek 区间 → 带 completion 的宽容差 seek → 失败重试，
    /// 期间用 isApplyingSeek 挡住 timeObserver，并用 sessionResumeAnchor 兜住连续换源。
    private func applyResume(restore: Bool,
                             seekTo: Double?,
                             epoch: UInt64,
                             attempt: Int = 0) {
        guard playEpoch == epoch, player.currentItem != nil else { return }

        var target: Double?
        if let s = seekTo, s > 1 {
            target = s
        } else if restore, !didRestoreProgress, let p = loadProgress() {
            target = p
        } else if sessionResumeAnchor > 3 {
            target = sessionResumeAnchor
        }
        guard let raw = target, raw > 1 else { return }

        // 时长已知时别 seek 到片尾，避免直接触发下一集
        var seconds = raw
        if duration > 5, duration.isFinite {
            seconds = min(seconds, max(0, duration - 3))
        }
        guard seconds > 1 else { return }

        let item = player.currentItem!
        if item.seekableTimeRanges.isEmpty {
            guard attempt < 6 else {
                // 直播型 / 不可 seek 的流：明确告知，别让人以为又坏了
                isApplyingSeek = false
                showHint("该源不支持续播，已从头播放", hold: 2.0)
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.applyResume(restore: restore, seekTo: seekTo,
                                  epoch: epoch, attempt: attempt + 1)
            }
            return
        }

        isApplyingSeek = true
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
        player.seek(to: cmTime,
                    toleranceBefore: tolerance,
                    toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.playEpoch == epoch else { return }
                if finished {
                    self.currentTime = seconds
                    self.sessionResumeAnchor = seconds
                    self.didRestoreProgress = true
                    self.isApplyingSeek = false
                } else if attempt < 6 {
                    self.isApplyingSeek = false
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    self.applyResume(restore: restore, seekTo: seekTo,
                                     epoch: epoch, attempt: attempt + 1)
                } else {
                    self.isApplyingSeek = false
                    self.showHint("该源不支持续播，已从头播放", hold: 2.0)
                }
            }
        }
    }

    // MARK: - 加载与播放

    private func loadAndPlay(url: URL,
                             restoreProgress: Bool,
                             seekTo: Double? = nil,
                             allowResolve: Bool = true,
                             bump: Bool = true) {
        // 主动发起的播放会让 epoch 前进；解析成功后的递归调用 bump=false，
        // 属于同一次请求，不会把自己的结果判成过期。
        if bump { playEpoch += 1 }
        let epoch = playEpoch
        let urlString = url.absoluteString
        // 1.8.10：1.8.9 诊断里播放页起来后连 `记 播放 URL` 都没有 —— 崩在
        // **起播/取流阶段**，旧埋点在这一段是全黑的。这里补入口，后面每条
        // 取流分支补开始/结束，下一份诊断能直接定位卡在哪一步。
        if bump {
            SessionTrace.mark("记 播放 起播入口 · " + Self.urlDigest(url))
        }

        // 1.5.1：mddcloud 内置源的剧集用自定义 scheme 占位，播放前先换真实 m3u8。
        if allowResolve, urlString.hasPrefix(MddCloudService.playScheme) {
            isLoading = true
            isBuffering = false
            errorMessage = nil
            showHint("正在获取播放地址…", hold: nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let real = await MddCloudService.shared.resolvePlayURL(urlString)
                guard self.playEpoch == epoch else { return }
                guard let real else {
                    self.showHint(nil)
                    self.errorMessage = "该线路暂时无法获取播放地址"
                    self.autoSwitchSource(reason: "取流失败")
                    return
                }
                self.showHint("取流成功 · 开始播放", hold: 2.0)
                self.loadAndPlay(url: real,
                                 restoreProgress: restoreProgress,
                                 seekTo: seekTo,
                                 allowResolve: false,
                                 bump: false)
            }
            return
        }

        // 1.6.0：Node 中转服务的集地址是加密参数串，用自定义 scheme 占位，
        // 播放前调 /play 换真实 m3u8，并把服务返回的 header 注入 AVURLAsset。
        // 必须排在网页解析之前，否则 ParseResolver 会把 scheme 当 URL 去嗅探。
        if allowResolve, urlString.hasPrefix(NodeRelayService.playScheme) {
            isLoading = true
            isBuffering = false
            errorMessage = nil
            showHint("正在获取播放地址…", hold: nil)
            // 1.8.10：本机源主路径。/play 卡住或把 Node 侧带崩时，
            // 旧轨迹只到「开 播放」，看不出请求有没有发出去、有没有回来。
            SessionTrace.mark("记 播放 发起 /play 取流")
            let playT0 = Date()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resolved = await NodeRelayService.shared.resolvePlay(urlString)
                let playMs = Int(Date().timeIntervalSince(playT0) * 1000)
                SessionTrace.mark("记 播放 /play 结束 \(playMs)ms "
                                  + (resolved == nil ? "失败" : "成功"))
                guard self.playEpoch == epoch else { return }
                guard let resolved else {
                    self.showHint(nil)
                    self.errorMessage = "该线路暂时无法获取播放地址"
                    // 1.8.8：/play 没给出有效 URL 也要留痕，才能区分
                    // 「取流失败」和「取到了但 URL 形态不对」
                    SessionTrace.mark("败 播放 取流失败（/play 无有效 URL）")
                    self.autoSwitchSource(reason: "取流失败")
                    return
                }
                self.spiderHeaders = resolved.1
                self.showHint("取流成功 · 开始播放", hold: 2.0)
                self.loadAndPlay(url: resolved.0,
                                 restoreProgress: restoreProgress,
                                 seekTo: seekTo,
                                 allowResolve: false,
                                 bump: false)
            }
            return
        }

        // 1.5.4：JS Spider 站点的集地址往往是内部 id，要先调 play() 换真实地址。
        // 必须排在网页解析之前，否则 ParseResolver 会把 id 当 URL 去解析。
        if allowResolve,
           let site = spiderSite,
           SpiderEngine.isSpiderSite(site),
           !PlayURL.isDirectPlayable(url: urlString) {
            isLoading = true
            isBuffering = false
            errorMessage = nil
            showHint("正在获取播放地址…", hold: nil)
            let flag = currentSource?.name ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                let r = await SpiderEngine.shared.call(
                    site: site, method: "play",
                    args: ["flag": flag, "id": urlString])
                guard self.playEpoch == epoch else { return }
                guard let r,
                      let real = Self.extractPlayURL(from: r),
                      let url = URL(string: real) else {
                    self.showHint(nil)
                    self.errorMessage = "该线路暂时无法获取播放地址"
                    self.autoSwitchSource(reason: "取流失败")
                    return
                }
                self.spiderHeaders = Self.extractHeaders(from: r)
                self.showHint("取流成功 · 开始播放", hold: 2.0)
                self.loadAndPlay(url: url,
                                 restoreProgress: restoreProgress,
                                 seekTo: seekTo,
                                 allowResolve: false,
                                 bump: false)
            }
            return
        }

        // 1.5.1：云端去广告（默认关）。只对 m3u8 直链生效，失败静默退回原地址，
        // 绝不因为清洗失败导致播不了。
        if allowResolve,
           !cloudCleanFailed,
           urlString.lowercased().contains(".m3u8"),
           UserDefaults.standard.bool(forKey: "MyTVBox.cloudAdFilterEnabled") {
            isLoading = true
            showHint("正在云端去广告…", hold: nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 1.5.2 最多等 3.5 秒，服务慢就直接播原地址，别让转圈一直挡着画面
                let cleaned = await ParseResolver.shared.cleanM3U8(original: urlString, timeout: 3.5)
                guard self.playEpoch == epoch else { return }
                if let cleaned {
                    // 成功提示只停 1 秒（原来统一 4 秒，观感上像卡住）
                    self.showHint("云端去广告已生效", hold: 1.0)
                    self.loadAndPlay(url: cleaned,
                                     restoreProgress: restoreProgress,
                                     seekTo: seekTo,
                                     allowResolve: false,
                                     bump: false)
                } else {
                    // 本次会话后续线路不再重复等待同一个失效服务
                    self.cloudCleanFailed = true
                    self.showHint(nil)
                    self.loadAndPlay(url: url,
                                     restoreProgress: restoreProgress,
                                     seekTo: seekTo,
                                     allowResolve: false,
                                     bump: false)
                }
            }
            return
        }

        // 官源 / 分享页这类非直链：先交给解析层换出 m3u8，再走正常播放。
        // allowResolve=false 防止解析结果又被当普通网页递归解析。
        if allowResolve, !PlayURL.isDirectPlayable(url: urlString) {
            isLoading = true
            isBuffering = false
            errorMessage = nil
            showHint("正在解析播放地址…", hold: nil)
            let rules = parseRules
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resolved = await ParseResolver.shared.resolve(
                    original: urlString, rules: rules,
                    flag: self.currentSource?.name, timeout: 12)
                // 解析期间用户已切集 / 换源 / 自动切线路 → 丢弃这次结果
                guard self.playEpoch == epoch else { return }
                guard let resolved else {
                    self.showHint(nil)
                    self.errorMessage = "该线路需要解析，但解析服务不可用"
                    self.autoSwitchSource(reason: "解析失败")
                    return
                }
                self.showHint("解析成功 · 开始播放", hold: 2.0)
                self.loadAndPlay(url: resolved,
                                 restoreProgress: restoreProgress,
                                 seekTo: seekTo,
                                 allowResolve: false,
                                 bump: false)
            }
            return
        }

        bufferingSince = nil

        // 1.8.8：AVURLAsset 只认 http/https（以及已接好 resourceLoader delegate
        // 的本地代理 scheme）。把 relative URL / 嵌套占位 / 未知 scheme 交给
        // AVPlayerItem 只会得到 `unsupported URL`，failed 回调再触发整条
        // 自动换源链（最多 12 条线路 + 整站级跨站搜索）。
        // 1.8.7 真机两次都是这个错，随后约 8 秒进程消失；心跳 3 秒一条，
        // 内存暴涨来不及留下证据。先在这里挡住，并把 URL 形态写进轨迹。
        let scheme = url.scheme?.lowercased() ?? ""
        let proxyOK = scheme == LocalPlaylistProxy.scheme.lowercased()
            && LocalPlaylistProxy.isProxied(url)
        guard scheme == "http" || scheme == "https" || proxyOK else {
            SessionTrace.mark("败 播放 URL 不支持 scheme=\(scheme.isEmpty ? "(空)" : scheme) · "
                              + Self.urlDigest(url))
            errorMessage = "该线路地址不被支持（\(scheme.isEmpty ? "无 scheme" : scheme)）"
            isLoading = false
            isBuffering = false
            autoSwitchSource(reason: "播放地址不支持")
            return
        }
        SessionTrace.mark("记 播放 URL " + Self.urlDigest(url))

        // 同一地址重入（比如误触重播）：只 seek，不重建 item，避免整轮重新缓冲
        if urlString == currentURLString,
           let item = player.currentItem, item.status == .readyToPlay {
            applyResume(restore: restoreProgress, seekTo: seekTo, epoch: epoch)
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

        // 1.8.10：创建 AVPlayerItem 是原生层（AVFoundation / 解码器）真正介入的点
        SessionTrace.mark("记 播放 创建 AVPlayerItem")
        let item = makeItem(for: url)
        player.replaceCurrentItem(with: item)

        observe(item: item, restoreProgress: restoreProgress, seekTo: seekTo)
        observeEnd(of: item)
        startSlowLineWatchdog()
        scheduleAdFilterSummary()
    }

    /// 代理拉到 playlist 并清洗后，短暂提示「过滤了几段广告」
    private func scheduleAdFilterSummary() {
        guard LocalPlaylistProxy.isEnabled else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self = self,
                  let summary = LocalPlaylistProxy.consumeSummary() else { return }
            self.adFilterHint = summary
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if self.adFilterHint == summary { self.adFilterHint = nil }
        }
    }

    private func observe(item: AVPlayerItem, restoreProgress: Bool, seekTo: Double?) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // 1.8.10：status 回调有没有触发，能区分「崩在 asset 装载」与
                // 「崩在首帧之后」。1.8.9 那一轮两种结局都看不到。
                SessionTrace.mark("记 播放 item.status="
                                  + (item.status == .readyToPlay ? "readyToPlay"
                                     : (item.status == .failed ? "failed" : "unknown")))
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.slowLineHint = nil
                    self.slowTimer?.cancel()
                    // 1.8.4：补上「完 播放」。旧版只有「开 播放」没有配对，
                    // 于是只要用户最后进过播放器，诊断就永远误报「崩在播放」。
                    SessionTrace.mark("完 播放 \(self.videoDetail.vodName) 首帧就绪")
                    let dur = item.duration.seconds
                    if dur.isFinite { self.duration = dur }
                    // 1.5.2 稳健续播：等可 seek 区间就绪、带 completion 校验、失败重试
                    self.applyResume(restore: restoreProgress, seekTo: seekTo, epoch: self.playEpoch)
                    self.player.play()
                    self.player.rate = self.playbackRate
                    // 兜底：若仍停在「正在…」类粘性提示，起播后给它一个短计时
                    if let h = self.autoSwitchHint, h.hasPrefix("正在"), self.hintClearTask == nil {
                        self.showHint(h, hold: 1.2)
                    }
                    // 起播稳定后再预热下一集，避免和当前流抢带宽。
                    // 1.8.4：3 秒 → 20 秒，别在刚起播的内存高峰上再叠一件事。
                    prewarmTask?.cancel()
                    prewarmTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run { self?.prewarmNextEpisode() }
                    }
                case .failed:
                    self.isLoading = false
                    self.isBuffering = false
                    self.slowTimer?.cancel()
                    // 1.8.5：AVFoundation 侧的失败要留痕，用于排除「播放器错误导致退出」
                    // 1.8.8：附上 URL 形态摘要，下一份诊断能直接看出是哪个 scheme/host
                    let digest = self.currentURLString
                        .flatMap { URL(string: $0) }
                        .map { Self.urlDigest($0) } ?? "(无 URL 记录)"
                    SessionTrace.mark("败 播放 item.failed: "
                                      + (item.error?.localizedDescription ?? "未知错误")
                                      + " · " + digest)
                    // 自定义 scheme 加载失败：整轮关掉过滤并用原始地址重建，
                    // 绝不让「去广告」把正常播放拖垮（1.4.7 回归的最终兜底）
                    if !self.adProxyBypassed,
                       LocalPlaylistProxy.isEnabled,
                       let rawString = self.currentURLString,
                       let raw = URL(string: rawString),
                       rawString.lowercased().contains(".m3u8") {
                        self.adProxyBypassed = true
                        self.assetCache.removeAll()
                        self.assetOrder.removeAll()
                        self.autoTriedSources = []
                        self.errorMessage = nil
                        self.adFilterHint = "过滤加载失败，已自动改为直连"
                        self.loadAndPlay(url: raw, restoreProgress: false,
                                         seekTo: max(self.currentTime, self.sessionResumeAnchor))
                        return
                    }
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
                SessionTrace.mark("完 播放 \(self.videoDetail.vodName) 自然播完")
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
                SessionTrace.mark("败 播放 播放中断（分片/会话失效）")
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
                self.slowLineHint = self.autoSwitchEnabled
                    ? "当前线路较慢，正在准备切换…"
                    : "当前线路较慢，可手动切换线路"
            }
            try? await Task.sleep(nanoseconds: UInt64(switchDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self = self, self.isLoading, self.autoSwitchEnabled else { return }
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
    ///
    /// 1.4.9：优先切到「不同站点」的线路 —— 同一站点的多条线路通常共用同一套后端，
    /// 站点本身故障时换同站线路大概率还是黑屏；跨站线路才是真正的备用源。
    private func autoSwitchSource(reason: String) {
        // 1.5.2 总开关关闭时只给提示，不擅自换线路
        guard autoSwitchEnabled else {
            slowLineHint = nil
            isBuffering = false
            bufferingSince = nil
            showHint("\(reason) · 自动换源已关闭，请手动切换线路", hold: 3.0)
            return
        }

        // 1.8.8：AVPlayerItem 的 failed 回调会在几秒内连发（1.8.7 真机两次
        // `unsupported URL`）。旧版每次都立刻换线路，最多 12 条，
        // 耗尽后还会启动整站级跨站搜索 —— 端上 Node 与播放器同进程，
        // 十几条 AVURLAsset 加整站抓取一起堆上来，3 秒一条的心跳
        // 根本来不及记录内存变化，进程就没了。这里给失败风暴踩刹车。
        let now = Date()
        if now.timeIntervalSince(lastAutoSwitchAt) < 2.0 {
            autoSwitchBurst += 1
        } else {
            lastAutoSwitchAt = now
            autoSwitchBurst = 1
        }
        if autoSwitchBurst >= 3 {
            SessionTrace.mark("阻 播放 换源风暴（2 秒内 \(autoSwitchBurst) 次）")
            showHint(nil)
            errorMessage = "多条线路连续失败，已暂停自动换源，请手动选择线路"
            slowLineHint = nil
            isBuffering = false
            isLoading = false
            return
        }

        guard sources.count > 1 else {
            slowLineHint = nil
            attemptCrossSite(reason: reason)
            return
        }
        guard autoTriedSources.count < maxAutoSwitch else {
            slowLineHint = nil
            attemptCrossSite(reason: reason)
            return
        }
        autoTriedSources.insert(currentSourceIndex)

        let count = sources.count
        let currentSiteKey = currentSource?.siteKey

        // 先找跨站线路，再退回同站线路
        var order: [Int] = []
        for step in 1...count {
            let idx = (currentSourceIndex + step) % count
            let key = sources[idx].siteKey
            if key != nil && key != currentSiteKey {
                order.append(idx)
            }
        }
        for step in 1...count {
            let idx = (currentSourceIndex + step) % count
            if !order.contains(idx) { order.append(idx) }
        }

        for idx in order {
            if autoTriedSources.contains(idx) { continue }
            let eps = sources[idx].episodes
            let epIdx = eps.indices.contains(currentEpisodeIndex) ? currentEpisodeIndex : 0
            guard eps.indices.contains(epIdx),
                  PlayURL.isPlayableCandidate(url: eps[epIdx].url),
                  let url = URL(string: eps[epIdx].url) else { continue }

            // 优先用真实播放时间，首帧前换源则退回会话锚点
            let resumeAt = max(currentTime, sessionResumeAnchor)
            autoTriedSources.insert(idx)
            currentSourceIndex = idx
            currentEpisodeIndex = epIdx
            let label = sources[idx].siteName.map { "\(sources[idx].name) · \($0)" } ?? sources[idx].name
            showHint("自动切换线路 → \(label)", hold: 2.5)
            if let s = sources[idx].siteName {
                activeSiteName = s
            }
            errorMessage = nil
            slowLineHint = nil
            loadAndPlay(url: url, restoreProgress: false, seekTo: resumeAt)
            return
        }
        slowLineHint = nil
        attemptCrossSite(reason: reason)
    }

    // MARK: - 站点级自动换源

    /// 一部片的所有线路都不可用时，去其它站点搜同名片并续播
    private func attemptCrossSite(reason: String) {
        // 线路不足时会直接走到这里，所以两个入口都要拦
        guard autoSwitchEnabled else {
            slowLineHint = nil
            isBuffering = false
            bufferingSince = nil
            showHint("\(reason) · 自动换源已关闭，请手动切换线路", hold: 3.0)
            return
        }
        guard !isCrossSiteSwitching else { return }
        guard let provider = onCrossSiteFallback else {
            errorMessage = "\(reason)\n所有线路均不可用，建议手动切换站点"
            slowLineHint = nil
            return
        }

        var excluded = triedSiteKeys
        if let origin = originSiteKey { excluded.insert(origin) }
        guard excluded.count < 24 else {
            errorMessage = "\(reason)\n已尝试多个站点均不可用，建议换一部片或切换订阅"
            slowLineHint = nil
            return
        }

        let title = videoDetail.vodName
        let epIdx = currentEpisodeIndex
        let seek = max(currentTime, sessionResumeAnchor)
        isCrossSiteSwitching = true
        showHint("正在其它站点搜索「\(title)」…", hold: nil)
        errorMessage = nil
        slowLineHint = nil

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let candidate = await provider(title, epIdx, seek, excluded)
            guard let candidate = candidate else {
                self.isCrossSiteSwitching = false
                self.showHint(nil)
                self.errorMessage = "\(reason)\n所有线路及跨站点搜索均不可用，建议切换站点"
                return
            }
            self.triedSiteKeys.insert(candidate.siteKey)
            self.applyCrossSite(candidate)
            self.isCrossSiteSwitching = false
        }
    }

    /// 用其它站点的详情整体替换播放上下文，保留集数与进度
    ///
    /// 1.4.9：不再「整池替换」，而是把新站点的线路**追加**到现有线路之后 ——
    /// 这样用户可以在原站线路与跨站线路之间随时来回切，而不是被强制换掉。
    private func applyCrossSite(_ candidate: CrossSiteResolver.CrossSitePlayable) {
        videoDetail = candidate.detail
        activeSiteName = candidate.siteName

        // 合并：以 candidate 的线路为基准，把原有线路中不重复的补在后面
        var merged = candidate.sources
        var seen = Set<String>()
        for src in candidate.sources {
            seen.insert(sourceSignature(src))
        }
        for src in sources {
            if seen.insert(sourceSignature(src)).inserted {
                merged.append(src)
            }
        }
        sources = merged

        autoTriedSources = []
        bufferingSince = nil
        didRestoreProgress = false
        currentSourceIndex = max(0, min(candidate.sourceIndex, max(sources.count - 1, 0)))
        let epCount = currentSource?.episodes.count ?? 0
        currentEpisodeIndex = max(0, min(candidate.episodeIndex, max(epCount - 1, 0)))

        guard let ep = currentEpisode,
              let url = URL(string: ep.url) else {
            errorMessage = "跨站点未找到可播放的直链"
            showHint(nil)
            return
        }
        showHint("已切到「\(candidate.siteName)」· 续播", hold: 2.5)
        loadAndPlay(url: url, restoreProgress: false, seekTo: candidate.seekTo)
    }

    /// 线路去重签名：线路名 + 首集地址
    private func sourceSignature(_ src: PlaySource) -> String {
        let first = src.episodes.first?.url ?? ""
        return "\(src.siteKey ?? "")|\(src.name)|\(first)"
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
                if !self.isApplyingSeek {
                    let t = time.seconds.isFinite ? max(0, time.seconds) : 0
                    self.currentTime = t
                    // 1.5.2 会话锚点只记真实播放位置，重建 item 不会丢
                    if t > 1 { self.sessionResumeAnchor = t }
                }
                if self.duration <= 0,
                   let dur = self.player.currentItem?.duration.seconds,
                   dur.isFinite {
                    self.duration = dur
                }
                self.updateBufferedProgress()
                // 续播 seek 期间不判缓冲超时，避免刚 seek 完又被换源
                if !self.isApplyingSeek { self.checkBufferingTimeout() }
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
