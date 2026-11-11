import SwiftUI

// MARK: - 主题（暗夜影院 Cinematic Noir）

enum PlayerTheme {
    // 颜色
    static let ink       = Color(red: 0.031, green: 0.031, blue: 0.047)   // #08080C
    static let charcoal  = Color(red: 0.082, green: 0.082, blue: 0.118)   // #15151E
    static let surface   = Color.white.opacity(0.06)
    static let hairline  = Color.white.opacity(0.10)
    static let textHigh  = Color(red: 0.95, green: 0.93, blue: 0.90)      // 暖白
    static let textMid   = Color(red: 0.95, green: 0.93, blue: 0.90).opacity(0.62)
    static let textLow   = Color(red: 0.95, green: 0.93, blue: 0.90).opacity(0.36)
    static let amber     = Color(red: 1.00, green: 0.478, blue: 0.271)    // #FF7A45 主强调
    static let gold      = Color(red: 0.96, green: 0.78, blue: 0.42)      // #F5C76B 次强调

    // 字体
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // 时间码
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, !seconds.isNaN, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 自定义播放控制覆盖层

struct PlayerControlsView: View {

    @ObservedObject var viewModel: VideoPlayerViewModel
    @Binding var isVisible: Bool
    @Binding var isFullscreen: Bool

    let onClose: () -> Void
    let onToggleEpisodes: () -> Void
    let onToggleFullscreen: () -> Void
    var onBackgroundAudio: () -> Void = {}
    var onTapSurface: () -> Void = {}

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showRateMenu = false
    @State private var showSourceMenu = false

    private let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        ZStack {
            // 整个透明面板 — 但点击穿透由父视图处理
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                centerTransport
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [
                        PlayerTheme.ink.opacity(0.78),
                        PlayerTheme.ink.opacity(0.20),
                        .clear,
                        PlayerTheme.ink.opacity(0.20),
                        PlayerTheme.ink.opacity(0.86)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
            )
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.22), value: isVisible)
    }

    // MARK: Top Bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            iconButton(system: "chevron.left", size: 18) { onClose() }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.videoDetail.vodName)
                    .font(PlayerTheme.display(17, weight: .bold))
                    .foregroundColor(PlayerTheme.textHigh)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(viewModel.currentEpisode?.name ?? "—")
                        .font(PlayerTheme.mono(11, weight: .medium))
                        .foregroundColor(PlayerTheme.amber)
                    Rectangle()
                        .fill(PlayerTheme.textLow)
                        .frame(width: 2, height: 2)
                    Text(viewModel.currentSource?.name ?? "")
                        .font(PlayerTheme.sans(11, weight: .medium))
                        .foregroundColor(PlayerTheme.textMid)
                        .lineLimit(1)
                }
            }
            Spacer()

            // 线路切换
            Menu {
                ForEach(Array(viewModel.sources.enumerated()), id: \.offset) { idx, src in
                    Button {
                        viewModel.switchSource(to: idx)
                    } label: {
                        if idx == viewModel.currentSourceIndex {
                            Label(src.name, systemImage: "checkmark")
                        } else {
                            Text(src.name)
                        }
                    }
                }
            } label: {
                pillButton(label: viewModel.currentSource?.name ?? "线路", icon: "antenna.radiowaves.left.and.right")
            }

            // 倍速
            Menu {
                ForEach(rates, id: \.self) { r in
                    Button {
                        viewModel.setPlaybackRate(r)
                    } label: {
                        if abs(r - viewModel.playbackRate) < 0.01 {
                            Label(rateLabel(r), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(r))
                        }
                    }
                }
            } label: {
                pillButton(label: rateLabel(viewModel.playbackRate), icon: "gauge.with.dots.needle.67percent")
            }
        }
    }

    // MARK: Center Transport

    private var centerTransport: some View {
        HStack(spacing: 36) {
            iconButton(system: "gobackward.15", size: 26) {
                viewModel.skip(by: -15)
            }

            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(PlayerTheme.amber, lineWidth: 1.5)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(PlayerTheme.amber.opacity(0.15))
                        .frame(width: 64, height: 64)
                        .blur(radius: 6)
                    if viewModel.isStalling {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(PlayerTheme.amber)
                            .scaleEffect(1.4)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .black))
                            .foregroundColor(PlayerTheme.amber)
                            .offset(x: viewModel.isPlaying ? 0 : 2)
                    }
                }
                .contentShape(Circle())
                .onTapGesture { viewModel.togglePlayPause() }

                if viewModel.isStalling {
                    Text(viewModel.isLoading ? "加载中" : "缓冲中")
                        .font(PlayerTheme.mono(10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundColor(PlayerTheme.textMid)
                }
            }
            .frame(height: 100)   // 固定高度，转圈/文字出现时按钮不跳动

            iconButton(system: "goforward.15", size: 26) {
                viewModel.skip(by: 15)
            }
        }
    }

    // MARK: Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // 进度条
            ScrubBar(
                value: Binding(
                    get: { isScrubbing ? scrubTime : viewModel.currentTime },
                    set: { newValue in scrubTime = newValue }
                ),
                total: max(viewModel.duration, 0.001),
                buffered: viewModel.bufferedRatio,
                isScrubbing: $isScrubbing,
                onSeek: { v in viewModel.seek(to: v) }
            )
            .frame(height: 22)

            HStack(spacing: 12) {
                Text(PlayerTheme.timecode(isScrubbing ? scrubTime : viewModel.currentTime))
                    .font(PlayerTheme.mono(12, weight: .semibold))
                    .foregroundColor(PlayerTheme.textHigh)
                    .frame(minWidth: 56, alignment: .leading)

                Rectangle()
                    .fill(PlayerTheme.hairline)
                    .frame(height: 1)

                Text(PlayerTheme.timecode(viewModel.duration))
                    .font(PlayerTheme.mono(12, weight: .medium))
                    .foregroundColor(PlayerTheme.textMid)
                    .frame(minWidth: 56, alignment: .trailing)

                Button(action: onToggleEpisodes) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(PlayerTheme.textHigh)
                        .frame(width: 34, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(PlayerTheme.hairline, lineWidth: 1)
                        )
                }

                Button(action: onToggleFullscreen) {
                    Image(systemName: isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(PlayerTheme.textHigh)
                        .frame(width: 34, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(PlayerTheme.hairline, lineWidth: 1)
                        )
                }

                // 后台音频播放
                Button(action: onBackgroundAudio) {
                    Image(systemName: "speaker.wave.2.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(PlayerTheme.textHigh)
                        .frame(width: 34, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(PlayerTheme.hairline, lineWidth: 1)
                        )
                }
            }
        }
    }

    // MARK: Helpers

    private func rateLabel(_ r: Float) -> String {
        if abs(r - r.rounded()) < 0.01 { return String(format: "%.0f×", r) }
        return String(format: "%.2f×", r).replacingOccurrences(of: ".00", with: "")
    }

    private func iconButton(system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(PlayerTheme.textHigh)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private func pillButton(label: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(PlayerTheme.mono(11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(PlayerTheme.textHigh)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(PlayerTheme.surface)
                .overlay(Capsule().stroke(PlayerTheme.hairline, lineWidth: 1))
        )
    }
}

// MARK: - 自定义进度条

struct ScrubBar: View {
    @Binding var value: Double
    let total: Double
    /// 已缓冲进度 0...1（画在主进度条下面的浅色预读段）
    var buffered: Double = 0
    @Binding var isScrubbing: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = total > 0 ? CGFloat(value / total) : 0
            let clamped = min(max(progress, 0), 1)
            let bufferedWidth = width * CGFloat(min(max(buffered, 0), 1))

            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(PlayerTheme.hairline)
                    .frame(height: 3)

                // 已缓冲（预读段）—— 比轨道亮一点、比播放进度暗
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: max(0, bufferedWidth), height: 3)

                // 已播放
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [PlayerTheme.amber, PlayerTheme.gold],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, clamped * width), height: isScrubbing ? 5 : 3)
                    .shadow(color: PlayerTheme.amber.opacity(0.45), radius: 6, x: 0, y: 0)
                    .animation(.easeOut(duration: 0.15), value: isScrubbing)

                // Thumb
                Circle()
                    .fill(PlayerTheme.textHigh)
                    .frame(width: isScrubbing ? 16 : 10, height: isScrubbing ? 16 : 10)
                    .overlay(
                        Circle().stroke(PlayerTheme.amber, lineWidth: isScrubbing ? 2 : 0)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                    .offset(x: clamped * width - (isScrubbing ? 8 : 5))
                    .animation(.easeOut(duration: 0.15), value: isScrubbing)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isScrubbing = true
                        let ratio = min(max(g.location.x / width, 0), 1)
                        value = Double(ratio) * total
                    }
                    .onEnded { _ in
                        onSeek(value)
                        // 给 player 一帧同步时间，再恢复绑定
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            isScrubbing = false
                        }
                    }
            )
        }
    }
}

// MARK: - 缓冲状态浮层
//
// 控制层 3 秒后会自动隐藏，如果这时正好卡缓冲，用户会以为「画面死了」。
// 这个浮层不跟随控制层显隐，只要有加载/缓冲/线路慢提示就常驻。

struct PlayerBufferingOverlay: View {

    @ObservedObject var viewModel: VideoPlayerViewModel

    private var visible: Bool {
        viewModel.isLoading || viewModel.isBuffering
            || viewModel.slowLineHint != nil || viewModel.autoSwitchHint != nil
    }

    private var title: String {
        if let auto = viewModel.autoSwitchHint { return auto }
        if viewModel.isLoading { return "连接中" }
        if viewModel.isBuffering {
            if viewModel.bufferedAhead > 0.4 {
                return String(format: "缓冲中 %.0fs", viewModel.bufferedAhead)
            }
            return "缓冲中"
        }
        return ""
    }

    var body: some View {
        Group {
            if visible {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(PlayerTheme.amber)
                        .scaleEffect(1.15)

                    if !title.isEmpty {
                        Text(title)
                            .font(PlayerTheme.mono(11, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(PlayerTheme.textHigh)
                    }

                    if let hint = viewModel.slowLineHint {
                        Text(hint)
                            .font(PlayerTheme.sans(11))
                            .foregroundColor(PlayerTheme.amber)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(PlayerTheme.ink.opacity(0.75))
                                    .overlay(Capsule().stroke(PlayerTheme.amber.opacity(0.45), lineWidth: 1))
                            )
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(PlayerTheme.ink.opacity(0.55))
                )
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: visible)
    }
}
