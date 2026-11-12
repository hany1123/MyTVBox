import SwiftUI
import AVKit
import AVFoundation

// MARK: - AVPlayerViewController 封装

struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false                  // 使用自定义控制层
        vc.allowsPictureInPicturePlayback = true          // 画中画
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player {
            vc.player = player
        }
    }
}

// MARK: - 主播放器视图

struct VideoPlayerView: View {

    let playSource: PlaySource
    let allSources: [PlaySource]
    let videoDetail: VideoDetail
    /// 本片所属站点 key —— 跨站点换源时作为第一排除项
    let originSiteKey: String?
    /// 1.5.4：详情所属站点（JS Spider 取流用）
    let site: Site?

    @StateObject private var viewModel: VideoPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var controlsVisible = true
    @State private var episodesVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isFullscreen = false

    init(playSource: PlaySource,
         allSources: [PlaySource],
         videoDetail: VideoDetail,
         initialEpisodeIndex: Int = 0,
         originSiteKey: String? = nil,
         site: Site? = nil) {
        self.playSource = playSource
        self.allSources = allSources
        self.videoDetail = videoDetail
        self.originSiteKey = originSiteKey
        self.site = site
        let srcIdx = allSources.firstIndex(where: { $0.id == playSource.id }) ?? 0
        _viewModel = StateObject(wrappedValue: VideoPlayerViewModel(
            videoDetail: videoDetail,
            sources: allSources.isEmpty ? [playSource] : allSources,
            initialSourceIndex: srcIdx,
            initialEpisodeIndex: initialEpisodeIndex
        ))
    }

    var body: some View {
        ZStack {
            PlayerTheme.ink.ignoresSafeArea()

            // 视频画面（全屏时由 FullscreenPlayerView 接管）
            if !isFullscreen {
                AVPlayerControllerRepresentable(player: viewModel.player)
                    .ignoresSafeArea()
                    .onTapGesture {
                        toggleControls()
                    }
            }

            // HUD 覆盖
            if controlsVisible {
                PlayerControlsView(
                    viewModel: viewModel,
                    isVisible: $controlsVisible,
                    isFullscreen: $isFullscreen,
                    onClose: {
                        viewModel.saveProgress()
                        dismiss()
                    },
                    onToggleEpisodes: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            episodesVisible.toggle()
                        }
                        scheduleAutoHide()
                    },
                    onToggleFullscreen: {
                        isFullscreen = true
                        scheduleAutoHide()
                    },
                    onBackgroundAudio: {
                        viewModel.switchToBackgroundAudio()
                        dismiss()
                    }
                )
                .ignoresSafeArea(edges: .horizontal)
                .transition(.opacity)
                .allowsHitTesting(true)
                // 任何控制层动作均刷新自动隐藏计时
                .onChangeCompat(of: viewModel.isPlaying) { _ in scheduleAutoHide() }
                .onChangeCompat(of: viewModel.currentEpisodeIndex) { _ in scheduleAutoHide() }
                .onChangeCompat(of: viewModel.currentSourceIndex) { _ in scheduleAutoHide() }
                .onChangeCompat(of: viewModel.playbackRate) { _ in scheduleAutoHide() }
            }

            // 集数抽屉
            if controlsVisible && episodesVisible,
               let src = viewModel.currentSource, !src.episodes.isEmpty {
                VStack {
                    Spacer()
                    EpisodeListView(
                        episodes: src.episodes,
                        currentIndex: viewModel.currentEpisodeIndex
                    ) { idx in
                        viewModel.playEpisode(at: idx)
                        scheduleAutoHide()
                    }
                    .padding(.bottom, 88) // 让出底部进度条
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .ignoresSafeArea(edges: .horizontal)
                .allowsHitTesting(true)
            }

            // 顶部状态角标：站点级换源 / m3u8 广告过滤结果
            if controlsVisible && (viewModel.activeSiteName != nil || viewModel.adFilterHint != nil) {
                VStack(spacing: 6) {
                    if let site = viewModel.activeSiteName {
                        statusBadge("自动换源 · \(site)")
                    }
                    if let ad = viewModel.adFilterHint {
                        statusBadge(ad)
                    }
                    Spacer()
                }
                .padding(.top, 14)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // 缓冲浮层 —— 控制层自动隐藏后，卡缓冲仍然能看见状态
            PlayerBufferingOverlay(viewModel: viewModel)
                .opacity(controlsVisible ? 0 : 1)
                .allowsHitTesting(false)

            // 错误提示
            if let err = viewModel.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(PlayerTheme.amber)
                    Text(err)
                        .font(PlayerTheme.sans(13))
                        .foregroundColor(PlayerTheme.textHigh)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(PlayerTheme.charcoal)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PlayerTheme.hairline))
                )
                .padding(40)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(isFullscreen)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // 播放页隐藏底部 TabBar —— 横屏时它正好压在画面上
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: $isFullscreen) {
            FullscreenPlayerView(viewModel: viewModel) {
                isFullscreen = false
            }
        }
        .onAppear {
            // 1.8.0：面包屑 —— 播放页是闪退高发区（AVPlayer + 端上 Node 同进程）
            // 1.8.4：进播放页先把海报位图全释放（最多 28MB），
            // 给马上要来的视频解码缓冲腾地方。
            RemoteImageLoader.shared.clearCache()
            // 1.8.5：连同 URLSession 的响应缓存一起清（120 张海报的 HTTP 响应也占内存）
            URLCache.shared.removeAllCachedResponses()
            // 1.8.5：双心跳。进程被直接干掉后，这些行是唯一能区分
            // 「内存被杀 / 主线程卡死 / Node abort」的现场证据。
            // 注入站点级换源：线路全部耗尽时，去当前配置的其它 CMS 站点找同名片
            // @StateObject 的 wrappedValue 在 View 内会被解析成 Binding，
            // 先取出实例引用再改其属性，避免 dynamicMember 下标报错
            let state = appState
            let model = viewModel
            model.originSiteKey = originSiteKey
            // 网页型线路（官源 / 分享页）靠这些解析规则兑换 m3u8
            model.parseRules = state.currentConfig?.parses ?? []
            // JS Spider 站点的集地址要先过 play()
            model.spiderSite = site ?? state.currentSite
            model.onCrossSiteFallback = { title, epIdx, progress, excluded in
                let sites = state.currentConfig?.sites ?? []
                return await CrossSiteResolver.findAlternative(
                    title: title,
                    in: sites,
                    excludingKeys: excluded,
                    episodeIndex: epIdx,
                    progress: progress,
                    preferredSiteKey: state.currentSite?.key
                )
            }
            // 1.8.12：起播前先请跨站聚合搜索收手。1.8.11 里 `完 重活` 落在
            // 起播窗口内，Node RSS 与 App RSS 同步上涨，两条线一起把内存顶上去。
            // 不改 model.start() 的时序，只发取消请求；搜索在下一次 group.next()
            // 就会 break，通常几十毫秒内生效。
            Task { await HeavyWorkGate.shared.requestCancelCurrent() }
            model.start()
            scheduleAutoHide()
            TabBarVisibility.setHidden(true)
        }
        .onDisappear {
            // 1.8.10：播放页消失本身是一等证据。崩溃时这条不会出现，
            // 于是能把「进程被杀」与「SwiftUI 把视图拆了」区分开。
            viewModel.saveProgress()
            hideTask?.cancel()
            TabBarVisibility.setHidden(false)
            // 1.8.4：正常退出也要写「完」，否则下次诊断永远误报「崩在播放」
        }
    }

    // MARK: - 顶部状态角标

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(PlayerTheme.mono(10, weight: .heavy))
            .foregroundColor(PlayerTheme.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(PlayerTheme.amber.opacity(0.9)))
    }

    // MARK: - 控制层显隐

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.22)) {
            controlsVisible.toggle()
        }
        if controlsVisible { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    controlsVisible = false
                }
            }
        }
    }
}

// MARK: - iOS 16/17 onChange 兼容

extension View {
    func onChangeCompat<V: Equatable>(of value: V, perform: @escaping (V) -> Void) -> some View {
        // iOS 16 onChange(of:perform:) 在 iOS 17 仍可用（仅 deprecated），统一使用
        self.onChange(of: value, perform: perform)
    }
}
