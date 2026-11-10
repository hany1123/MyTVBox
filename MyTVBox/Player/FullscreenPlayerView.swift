import SwiftUI
import AVKit

// MARK: - 全屏播放器（旋转方案，无需系统方向 API）
//
// 通过 GeometryReader + rotationEffect(.degrees(90)) 将竖屏容器
// 视觉上渲染为横屏，完全规避 iOS 16 requestGeometryUpdate 的可靠性问题。

struct FullscreenPlayerView: View {

    @ObservedObject var viewModel: VideoPlayerViewModel
    let onDismiss: () -> Void

    @State private var controlsVisible = true
    @State private var episodesVisible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // 把竖屏尺寸翻转成横屏尺寸，再整体旋转 90°
                ZStack {
                    AVPlayerControllerRepresentable(player: viewModel.player)
                        .ignoresSafeArea()
                        .onTapGesture { toggleControls() }

                    if controlsVisible {
                        PlayerControlsView(
                            viewModel: viewModel,
                            isVisible: $controlsVisible,
                            isFullscreen: .constant(true),
                            onClose: onDismiss,
                            onToggleEpisodes: {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    episodesVisible.toggle()
                                }
                                scheduleAutoHide()
                            },
                            onToggleFullscreen: onDismiss,
                            onBackgroundAudio: {
                                viewModel.switchToBackgroundAudio()
                                onDismiss()
                            }
                        )
                        .ignoresSafeArea(edges: .horizontal)
                        .transition(.opacity)
                        .allowsHitTesting(true)
                        .onChangeCompat(of: viewModel.isPlaying) { _ in scheduleAutoHide() }
                        .onChangeCompat(of: viewModel.currentEpisodeIndex) { _ in scheduleAutoHide() }
                        .onChangeCompat(of: viewModel.currentSourceIndex) { _ in scheduleAutoHide() }
                        .onChangeCompat(of: viewModel.playbackRate) { _ in scheduleAutoHide() }
                    }

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
                            .padding(.bottom, 88)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        .ignoresSafeArea(edges: .horizontal)
                        .allowsHitTesting(true)
                    }

                    // 缓冲浮层
                    PlayerBufferingOverlay(viewModel: viewModel)
                        .opacity(controlsVisible ? 0 : 1)
                        .allowsHitTesting(false)

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
                // 横向尺寸 = 竖屏高度，纵向尺寸 = 竖屏宽度，旋转后填满屏幕
                .frame(width: geo.size.height, height: geo.size.width)
                .rotationEffect(.degrees(90))
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear { scheduleAutoHide() }
        .onDisappear { hideTask?.cancel() }
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
