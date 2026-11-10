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

    @StateObject private var viewModel: VideoPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var episodesVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isFullscreen = false

    init(playSource: PlaySource,
         allSources: [PlaySource],
         videoDetail: VideoDetail,
         initialEpisodeIndex: Int = 0) {
        self.playSource = playSource
        self.allSources = allSources
        self.videoDetail = videoDetail
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
            viewModel.start()
            scheduleAutoHide()
            TabBarVisibility.setHidden(true)
        }
        .onDisappear {
            viewModel.saveProgress()
            hideTask?.cancel()
            TabBarVisibility.setHidden(false)
        }
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
