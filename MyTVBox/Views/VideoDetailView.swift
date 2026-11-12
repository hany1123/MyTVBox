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
    /// 本片所有可用线路：本片所在站点在前，其它站点的同片线路在后
    @State private var sources: [PlaySource] = []
    @State private var selectedSourceIndex: Int = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// 正在从其它站点拉同片线路
    @State private var isLoadingCrossSite = false

    /// 1.7.1：本片详情是从其它站点接管过来的提示（豆瓣这类首页墙站点用得上）
    @State private var adoptInfo: String?
    /// 接管详情时实际提供数据的站点 key
    @State private var adoptedSiteKey: String?

    /// 1.7.1：详情正文里识别出的「配置中心」地址（已改写成 127.0.0.1）
    @State private var configCenterURL: URL?
    @State private var showConfigCenter = false

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

    /// 其它站点的同片线路
    private var crossSiteSources: [PlaySource] {
        sources.filter { $0.isCrossSite }
    }

    /// 跨站线路涉及的其它站点数量
    private var crossSiteSiteCount: Int {
        Set(crossSiteSources.compactMap { $0.siteKey }).count
    }

    var body: some View {
        ZStack {
            PlayerTheme.ink.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    metaSection
                    actionSection
                    configCenterSection
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
                    originSiteKey: resolvedSiteKey,
                    site: resolvedSite
                )
            }
        }
        .task {
            // 1.7.1：从播放器返回时这个 .task 会再执行一次。以前无条件重拉详情，
            // 等于每次返回都再打一轮「详情 + 8 个站的跨站线路」，既费流量又推高
            // 内存峰值（端上跑着 Node，内存本来就紧）。已经有详情就直接复用。
            if detail == nil {
                await loadDetail()
            }
            refreshLocalState()
        }
        .sheet(isPresented: $showConfigCenter) {
            if let url = configCenterURL {
                ConfigCenterSheet(url: url)
            }
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
                                    Image(systemName: src.isCrossSite
                                          ? "globe.badge.chevron.backward"
                                          : "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 10, weight: .bold))
                                    Text(src.name)
                                        .font(PlayerTheme.sans(13, weight: idx == selectedSourceIndex ? .heavy : .medium))
                                    if let siteName = src.siteName {
                                        Text(siteName)
                                            .font(PlayerTheme.mono(9, weight: .bold))
                                            .foregroundColor(idx == selectedSourceIndex
                                                             ? PlayerTheme.ink.opacity(0.75)
                                                             : PlayerTheme.textLow)
                                    }
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

                // 跨站线路分组说明
                if !crossSiteSources.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("含 \(crossSiteSiteCount) 个其它站点的同片线路（带站点名），播放卡顿时会自动切换")
                            .font(PlayerTheme.mono(10))
                            .lineLimit(2)
                    }
                    .foregroundColor(PlayerTheme.textLow)
                    .padding(.horizontal, 20)
                } else if isLoadingCrossSite {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(PlayerTheme.amber)
                        Text("正在其它站点查找同片线路…")
                            .font(PlayerTheme.mono(10))
                            .lineLimit(2)
                    }
                    .foregroundColor(PlayerTheme.textLow)
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

    /// 1.7.1：配置中心入口。
    ///
    /// 猫爪源的「配置|中心」站点没有可播内容，正文里只给了一行
    /// 「手机扫码打开：http://10.64.81.45:18923/website」。这里把它变成
    /// 一个可直接点的按钮，用 App 内 WebView 打开（地址已改写成 127.0.0.1）。
    @ViewBuilder
    private var configCenterSection: some View {
        if let url = configCenterURL {
            Button {
                showConfigCenter = true
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(PlayerTheme.amber)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("打开配置中心")
                            .font(PlayerTheme.sans(14, weight: .heavy))
                            .foregroundColor(PlayerTheme.textHigh)
                        Text(url.absoluteString)
                            .font(PlayerTheme.sans(10))
                            .foregroundColor(PlayerTheme.textHigh.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(PlayerTheme.amber)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(PlayerTheme.amber.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(PlayerTheme.amber.opacity(0.45), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)
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
                applyDetail(d)
            } else {
                // 1.7.1：豆瓣这类「首页推荐墙」站点的 detail 接口本来就返回空
                // （实测 douban detail -> {}）。以前这里直接报「未找到视频信息」，
                // 用户点了等于死路。改成自动去其它站搜同名片的详情来接管。
                if await adoptDetailFromOtherSites(title: previewItem?.vodName ?? "") {
                    return
                }
                self.errorMessage = "未找到视频信息"
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// 把详情灌进视图状态（本片详情与「跨站接管的详情」共用）。
    private func applyDetail(_ d: VideoDetail) {
        self.detail = d
        let parsed = d.parsePlaySources()
        self.sources = parsed
        self.selectedSourceIndex = 0
        // 1.7.1：配置中心类站点的正文里带 http://<ip>:<port>/website，
        // 识别出来并把局域网 IP 换成端上 Node 的 127.0.0.1。
        self.configCenterURL = ConfigCenterURL.extract(from: d.vodContent ?? "")
        // 后台加载其它站点的同片线路（不阻塞详情展示）
        Task { await loadCrossSiteLines(title: d.vodName) }
    }

    /// 当前站拿不到详情时，去其它已启用站点搜同名片的详情。
    ///
    /// 只接受标题完全一致的命中（relevance == 2），避免把「第二季」「番外」
    /// 之类当成同一部；并且要求目标站能解析出至少一条线路，否则继续找下一个。
    private func adoptDetailFromOtherSites(title rawTitle: String) async -> Bool {
        let title = CrossSiteResolver.normalizedTitle(rawTitle)
        guard title.count >= 2 else { return false }

        let allSites = appState.currentConfig?.sites ?? []
        guard !allSites.isEmpty else { return false }

        var excluding = Set<String>()
        if let key = resolvedSiteKey { excluding.insert(key) }

        let hits = await CrossSiteResolver.search(
            keyword: title,
            in: allSites,
            limitPerSite: 6,
            limitTotal: 40,
            preferredSiteKey: nil
        )

        for hit in hits where hit.relevance >= 2 {
            if excluding.contains(hit.site.key) { continue }
            guard let d = try? await APIService.shared.fetchVideoDetail(
                site: hit.site, vodId: hit.item.vodId, timeout: 8
            ) else { continue }
            guard !d.parsePlaySources().isEmpty else { continue }

            adoptInfo = "本片由「\(hit.site.name)」提供"
            applyDetail(d)
            adoptedSiteKey = hit.site.key
            return true
        }
        return false
    }


    /// 从其它已启用站点找同片线路，让「片源可以在所有源里切换」
    private func loadCrossSiteLines(title: String) async {
        let key = resolvedSiteKey
        let allSites = appState.currentConfig?.sites ?? []
        guard !allSites.isEmpty else { return }
        var excluding = Set<String>()
        if let key { excluding.insert(key) }

        isLoadingCrossSite = true
        defer { isLoadingCrossSite = false }

        let lines = await CrossSiteResolver.fetchCrossSiteLines(
            title: title,
            in: allSites,
            excludingKeys: excluding,
            maxSites: 8
        )
        guard !lines.isEmpty else { return }

        // 只保留与本片线路不重复的（按线路名+首集地址去重）
        var seen = Set<String>()
        for src in sources {
            if let first = src.episodes.first {
                seen.insert("\(src.name)|\(first.url)")
            }
        }
        var appended: [PlaySource] = []
        for line in lines {
            for src in line.sources {
                guard let first = src.episodes.first else { continue }
                let sig = "\(src.name)|\(first.url)"
                if seen.insert(sig).inserted {
                    appended.append(src)
                }
            }
        }
        guard !appended.isEmpty else { return }
        sources.append(contentsOf: appended)
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
