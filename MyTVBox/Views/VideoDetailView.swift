import SwiftUI

// MARK: - 视频详情页（连接列表 → 播放器）

struct VideoDetailView: View {

    let vodId: String
    /// 列表项作为占位封面/标题
    let previewItem: VideoItem?
    /// 结果所属站点。搜索聚合结果会带站点；首页/分类/收藏传 nil，用当前站点
    let site: Site?

    @EnvironmentObject private var appState: AppState

    @State private var detail: VideoDetail?
    @State private var sources: [PlaySource] = []
    @State private var selectedSourceIndex: Int = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var isFavorite: Bool = false
    @State private var lastRecord: PlayHistoryManager.PlayRecord?

    @State private var pendingTarget: PlayTarget?
    @State private var isPlayerActive: Bool = false

    private struct PlayTarget: Identifiable, Hashable {
        var id: String { "\(sourceIndex)-\(episodeIndex)" }
        let sourceIndex: Int
        let episodeIndex: Int
    }

    private func play(sourceIndex: Int, episodeIndex: Int) {
        pendingTarget = PlayTarget(sourceIndex: sourceIndex, episodeIndex: episodeIndex)
        isPlayerActive = true
    }

    init(vodId: String, previewItem: VideoItem? = nil, site: Site? = nil) {
        self.vodId = vodId
        self.previewItem = previewItem
        self.site = site
    }

    /// 本片实际取详情的站点：优先用结果携带的站点，否则退回当前站点
    private var resolvedSite: Site? { site ?? appState.currentSite }
    private var resolvedSiteKey: String? { resolvedSite?.key ?? appState.currentSite?.key }

    var body: some View {
        ZStack {
            PlayerTheme.ink.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    metaSection
                    actionSection
                    sourceSection
                    episodeSection
                    descriptionSection
                    Color.clear.frame(height: 80)
                }
            }

            if isLoading {
                loadingView
            } else if let err = errorMessage {
                errorView(err)
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PlayerTheme.ink, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(detail?.vodName ?? previewItem?.vodName ?? "")
                    .font(PlayerTheme.display(15, weight: .bold))
                    .foregroundColor(PlayerTheme.textHigh)
                    .lineLimit(1)
            }
        }
        .navigationDestination(isPresented: $isPlayerActive) {
            if let target = pendingTarget,
               sources.indices.contains(target.sourceIndex),
               let detail = detail {
                VideoPlayerView(
                    playSource: sources[target.sourceIndex],
                    allSources: sources,
                    videoDetail: detail,
                    initialEpisodeIndex: target.episodeIndex,
                    originSiteKey: resolvedSiteKey
                )
            }
        }
        .task {
            await loadDetail()
            refreshLocalState()
        }
        .onAppear { refreshLocalState() }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                let url = (detail?.vodPic ?? previewItem?.vodPic).flatMap { URL(string: $0) }
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        PlayerTheme.charcoal
                    }
                }
                .frame(width: geo.size.width, height: 360)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, PlayerTheme.ink.opacity(0.4), PlayerTheme.ink],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                // 噪点纹理感的微小斜线条纹
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [PlayerTheme.amber.opacity(0.06), .clear],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                )
            }
            .frame(height: 360)

            VStack(alignment: .leading, spacing: 10) {
                if let typeName = detail?.typeName ?? previewItem?.typeName {
                    HStack(spacing: 6) {
                        Rectangle().fill(PlayerTheme.amber).frame(width: 14, height: 2)
                        Text(typeName.uppercased())
                            .font(PlayerTheme.mono(10, weight: .heavy))
                            .tracking(2)
                            .foregroundColor(PlayerTheme.amber)
                    }
                }
                Text(detail?.vodName ?? previewItem?.vodName ?? "")
                    .font(PlayerTheme.display(28, weight: .black))
                    .foregroundColor(PlayerTheme.textHigh)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    ForEach(metaTags, id: \.self) { tag in
                        Text(tag)
                            .font(PlayerTheme.mono(10, weight: .medium))
                            .foregroundColor(PlayerTheme.textMid)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(PlayerTheme.hairline)
                            )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    private var metaTags: [String] {
        var arr: [String] = []
        if let y = detail?.vodYear ?? previewItem?.vodYear, !y.isEmpty { arr.append(y) }
        if let a = detail?.vodArea ?? previewItem?.vodArea, !a.isEmpty { arr.append(a) }
        if let r = previewItem?.vodRemarks, !r.isEmpty { arr.append(r) }
        return arr
    }

    // MARK: - Meta (导演 / 演员)

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let siteName = resolvedSite?.name {
                metaLine(label: "SOURCE", value: siteName)
            }
            if let d = detail?.vodDirector, !d.isEmpty {
                metaLine(label: "DIRECTOR", value: d)
            }
            if let a = detail?.vodActor, !a.isEmpty {
                metaLine(label: "CAST", value: a)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func metaLine(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(PlayerTheme.mono(10, weight: .heavy))
                .tracking(2)
                .foregroundColor(PlayerTheme.gold)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(PlayerTheme.sans(13))
                .foregroundColor(PlayerTheme.textHigh)
                .lineLimit(2)
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        HStack(spacing: 10) {
            // 主按钮：播放 / 续播
            Button {
                if let rec = lastRecord {
                    play(
                        sourceIndex: min(rec.sourceIndex, max(sources.count - 1, 0)),
                        episodeIndex: rec.episodeIndex
                    )
                } else if !sources.isEmpty {
                    play(sourceIndex: selectedSourceIndex, episodeIndex: 0)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: lastRecord == nil ? "play.fill" : "memories")
                        .font(.system(size: 15, weight: .heavy))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lastRecord == nil ? "立即播放" : "继续播放")
                            .font(PlayerTheme.display(15, weight: .heavy))
                        if let rec = lastRecord {
                            Text("\(rec.episodeName) · \(PlayerTheme.timecode(rec.progress))")
                                .font(PlayerTheme.mono(10, weight: .medium))
                                .opacity(0.8)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .heavy))
                }
                .foregroundColor(PlayerTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [PlayerTheme.gold, PlayerTheme.amber],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .shadow(color: PlayerTheme.amber.opacity(0.4), radius: 12, y: 4)
                )
            }
            .buttonStyle(.plain)
            .disabled(sources.isEmpty)
            .opacity(sources.isEmpty ? 0.4 : 1)

            // 收藏
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(isFavorite ? PlayerTheme.amber : PlayerTheme.textHigh)
                    .frame(width: 50, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(PlayerTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isFavorite ? PlayerTheme.amber : PlayerTheme.hairline, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourceSection: some View {
        if sources.count > 0 {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "PLAY SOURCE", count: sources.count)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { idx, src in
                            Button {
                                selectedSourceIndex = idx
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 10, weight: .bold))
                                    Text(src.name)
                                        .font(PlayerTheme.sans(13, weight: idx == selectedSourceIndex ? .heavy : .medium))
                                }
                                .foregroundColor(idx == selectedSourceIndex ? PlayerTheme.ink : PlayerTheme.textHigh)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule()
                                        .fill(idx == selectedSourceIndex ? PlayerTheme.amber : PlayerTheme.surface)
                                        .overlay(Capsule().stroke(idx == selectedSourceIndex ? PlayerTheme.amber : PlayerTheme.hairline))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 22)
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodeSection: some View {
        if sources.indices.contains(selectedSourceIndex),
           !sources[selectedSourceIndex].episodes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "EPISODES",
                    count: sources[selectedSourceIndex].episodes.count
                )
                EpisodeGridView(
                    episodes: sources[selectedSourceIndex].episodes,
                    currentIndex: lastRecord?.sourceIndex == selectedSourceIndex ? lastRecord?.episodeIndex : nil
                ) { idx in
                    play(sourceIndex: selectedSourceIndex, episodeIndex: idx)
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 22)
        }
    }

    // MARK: - Description

    @ViewBuilder
    private var descriptionSection: some View {
        if let content = detail?.vodContent?.htmlStripped, !content.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "SYNOPSIS", count: nil)
                Text(content)
                    .font(PlayerTheme.sans(13))
                    .foregroundColor(PlayerTheme.textMid)
                    .lineSpacing(5)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 22)
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String, count: Int?) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(PlayerTheme.amber).frame(width: 4, height: 16)
            Text(title)
                .font(PlayerTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundColor(PlayerTheme.textHigh)
            if let c = count {
                Text(String(format: "%02d", c))
                    .font(PlayerTheme.mono(11, weight: .medium))
                    .foregroundColor(PlayerTheme.textLow)
            }
            Spacer()
            Rectangle().fill(PlayerTheme.hairline).frame(height: 1)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Loading / Error

    private var loadingView: some View {
        ZStack {
            PlayerTheme.ink.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(PlayerTheme.amber).scaleEffect(1.2)
                Text("LOADING")
                    .font(PlayerTheme.mono(11, weight: .heavy))
                    .tracking(4)
                    .foregroundColor(PlayerTheme.textMid)
            }
        }
    }

    private func errorView(_ err: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(PlayerTheme.amber)
            Text(err)
                .font(PlayerTheme.sans(13))
                .foregroundColor(PlayerTheme.textHigh)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await loadDetail() }
            }
            .font(PlayerTheme.sans(13, weight: .heavy))
            .foregroundColor(PlayerTheme.ink)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Capsule().fill(PlayerTheme.amber))
        }
        .padding(28)
    }

    // MARK: - Logic

    private func loadDetail() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let site = resolvedSite else {
            errorMessage = "未选择站点"
            return
        }
        do {
            if let d = try await APIService.shared.fetchVideoDetail(site: site, vodId: vodId) {
                self.detail = d
                let parsed = d.parsePlaySources()
                self.sources = parsed
                self.selectedSourceIndex = 0
            } else {
                self.errorMessage = "未找到视频信息"
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func refreshLocalState() {
        isFavorite = FavoritesManager.shared.isFavorite(vodId: vodId)
        lastRecord = PlayHistoryManager.shared.getRecord(vodId: vodId)
    }

    private func toggleFavorite() {
        let name = detail?.vodName ?? previewItem?.vodName ?? ""
        let pic = detail?.vodPic ?? previewItem?.vodPic
        isFavorite = FavoritesManager.shared.toggle(vodId: vodId, vodName: name, vodPic: pic)
    }
}

// MARK: - HTML 简单清洗

private extension String {
    var htmlStripped: String {
        let s = self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
