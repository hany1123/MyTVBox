import SwiftUI

// MARK: - 视频详情页（连接列表 → 播放器）

struct VideoDetailView: View {

    let vodId: String
    /// 列表项作为占位封面/标题
    let previewItem: VideoItem?
    /// 结果所属站点。搜索聚合结果会带站点；首页/分类/收藏传 nil，用当前站点
    let site: Site?

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// 1.7.4：详情/接管的链路记录，出问题时长按复制即可，不用再跑整站诊断
    @State private var detailDiag: [String] = []

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
    /// 1.8.1：自动跳搜索只允许发生一次。
    /// 之前这个跳转写在 `.task` 里，只要视图重新出现（Tab 切回、详情没真正退出、
    /// 转场被打断）就会再触发一次 —— 于是「详情 → 搜索 → 详情 → 搜索」自己循环，
    /// 每轮都开一次 110 站聚合搜索，最后把进程顶崩。守卫住就断了这个环。
    @State private var didAutoJumpToSearch = false

    private struct PlayTarget: Identifiable, Hashable {
        var id: String { "\(sourceIndex)-\(episodeIndex)" }
        let sourceIndex: Int
        let episodeIndex: Int
    }

    private func play(sourceIndex: Int, episodeIndex: Int) {
        pendingTarget = PlayTarget(sourceIndex: sourceIndex, episodeIndex: episodeIndex)
        isPlayerActive = true
    }

    /// 1.7.5：推荐墙条目是否「一进来就跳全站搜索」。
    /// 首页/分类/收藏进来要跳（对标 MiraPlay）；从搜索结果再点进详情则不能跳，
    /// 否则会在「搜索 → 详情 → 搜索」之间来回弹。
    let autoSearchOnOpen: Bool

    init(vodId: String, previewItem: VideoItem? = nil, site: Site? = nil,
         autoSearchOnOpen: Bool = true) {
        self.vodId = vodId
        self.previewItem = previewItem
        self.site = site
        self.autoSearchOnOpen = autoSearchOnOpen
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

            HStack(spacing: 12) {
                Button("重试") {
                    Task { await loadDetail() }
                }
                .font(PlayerTheme.sans(13, weight: .heavy))
                .foregroundColor(PlayerTheme.ink)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Capsule().fill(PlayerTheme.amber))

                // 1.7.4：推荐墙条目（豆瓣这类）唯一的出路是按片名去别的站找，
                // 一键把用户送到搜索页，别让人卡在这一页。
                if let kw = (previewItem?.vodName ?? detail?.vodName), !kw.isEmpty {
                    Button("去搜索") {
                        // 1.8.0：同样是「先关，再切 Tab」
                        dismiss()
                        appState.jumpToSearch(keyword: kw)
                    }
                    .font(PlayerTheme.sans(13, weight: .heavy))
                    .foregroundColor(PlayerTheme.textHigh)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Capsule().stroke(PlayerTheme.textHigh.opacity(0.4), lineWidth: 1))
                }
            }

            // 详情链路诊断：出问题时长按这段文字复制给我即可，不用再跑整站诊断
            if !detailDiag.isEmpty {
                DisclosureGroup("详情链路诊断") {
                    Text(detailDiag.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(PlayerTheme.textHigh.opacity(0.75))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(PlayerTheme.sans(11))
                .foregroundColor(PlayerTheme.textHigh.opacity(0.6))
                .padding(.top, 4)
            }
        }
        .padding(28)
    }

    private func diag(_ line: String) {
        detailDiag.append(line)
        print("[Detail] " + line)
    }

    // MARK: - Logic

    /// 1.7.4：推荐墙站点的条目 id 前缀。
    ///
    /// 源里这些站点的 detail / play / search 全是空实现（实测：
    /// `meta:{key:"douban",indexs:1}` 的 spider 就是 `async detail(){return{}}`）。
    /// 条目只有「片名 + 豆瓣 id」，片源必须按片名去别的站找 —— 这是设计如此，不是 bug。
    /// 所以见到 `msearch:` 就别再浪费一次往返去问 detail。
    private var isRecommendWallItem: Bool {
        vodId.lowercased().hasPrefix("msearch")
    }

    private func loadDetail() async {
        isLoading = true
        errorMessage = nil
        detailDiag.removeAll()
        defer { isLoading = false }

        guard let site = resolvedSite else {
            errorMessage = "未选择站点"
            return
        }

        let title = previewItem?.vodName ?? detail?.vodName ?? ""
        diag("站点 \(site.key) · vodId=\(vodId) · 标题=\(title)")
        diag(isRecommendWallItem ? "判定：推荐墙条目 → 直接跨站找片源" : "判定：普通条目 → 先问本驿站")

        // 1.7.5：豆瓣这类推荐墙，直接跳到「全站聚合搜索」。
        // 以前是在详情页里静默接管一个站，用户看不到「这部片还有哪些源有」，
        // 也没法挑。跳过去能按站点筛选，和 MiraPlay 一致。
        if autoSearchOnOpen, isRecommendWallItem, !title.isEmpty, !didAutoJumpToSearch {
            didAutoJumpToSearch = true
            diag("推荐墙条目 → 跳转全站搜索「\(title)」")
            // 1.8.0：先退详情，再隔一拍切 Tab。
            // 同一帧里「关导航栈 + 切 Tab」会让 SwiftUI 在视图更新中拆掉正在
            // dismiss 的 NavigationStack —— 这就是「点豆瓣电影直接闪退」。
            dismiss()
            appState.jumpToSearch(keyword: title)
            return
        }

        var failReason = "推荐墙条目，本站无片源"
        if !isRecommendWallItem {
            let t0 = Date()
            do {
                // 1.8.14：20 → 10 秒。1.8.13 诊断里 `开 详情 21:04:34.481` →
                // `记 搜索 21:04:54.502` 正好空等 20 秒，Node 侧那条
                // `REQ POST /spider/appv7zhuijudaren/3/detail` 始终没有 RES。
                // 本站没数据就是没数据，等 20 秒不会让它变出来，只是把用户
                // 和「仍在飞的请求」一起拖进后面的 16 路跨站搜索。
                if let d = try await APIService.shared.fetchVideoDetail(
                    site: site, vodId: vodId, timeout: 10) {
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let parsed = d.parsePlaySources()
                    diag("本站 detail: OK \(ms)ms · 线路 \(parsed.count) 条")
                    if !parsed.isEmpty {
                        applyDetail(d)
                        return
                    }
                    diag("本站 detail 有数据但没有可播线路 → 跨站")
                    failReason = "本站 \(ms)ms 有数据但无线路"
                } else {
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    diag("本站 detail: 空响应 \(ms)ms → 跨站")
                    failReason = "本站 \(ms)ms 空响应"
                }
            } catch {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                diag("本站 detail: 失败 \(ms)ms · \(error.localizedDescription) → 跨站")
                failReason = "本站 \(ms)ms 失败:\(error.localizedDescription)"
            }
        }

        // 1.8.2：这行「完 详情 … 无线路」以前写在跨站接管**之前**，结果日志里
        // 一进详情 1 毫秒就出现「无线路」，看起来像瞬间失败 —— 其实接管还在跑。
        // 现在挪到接管之后，并把本站失败原因一起记下。
        if Task.isCancelled { return }
        if await adoptDetailFromOtherSites(title: title) { return }

        if title.isEmpty {
            errorMessage = "没拿到这个条目的详情（id=\(vodId)），也没有片名可以拿去其它站搜。"
        } else if isRecommendWallItem {
            errorMessage = """
            「\(site.name)」只做推荐，条目本身不带片源，需要按片名到其它站找。
            自动搜索没搜到可播的「\(title)」—— 可以点「去搜索」换个名字试试。
            """
        } else {
            errorMessage = "「\(title)」在本站和其它站都没拿到可播线路。可以重试，或点「去搜索」换个站点找。"
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

    /// 并发试若干候选站点，谁先拿到可播线路就用谁。
    /// 串行试的话，第一个候选如果是「详情要现解析网盘」的慢站（实测 wogg 那种
    /// 200 KB play_url 能拖十几秒），用户就干等着；并发 3 路能把首播等待压下来。
    private struct PlayableHit: @unchecked Sendable {
        let hit: CrossSiteResolver.SiteSearchResult
        let detail: VideoDetail
    }

    private func firstPlayableDetail(
        _ candidates: [CrossSiteResolver.SiteSearchResult],
        width: Int = 3,
        timeout: TimeInterval = 15
    ) async -> PlayableHit? {
        var queue = candidates
        while !queue.isEmpty {
            let batch = Array(queue.prefix(width))
            queue.removeFirst(min(width, queue.count))

            let got: PlayableHit? = await withTaskGroup(
                of: PlayableHit?.self, returning: PlayableHit?.self
            ) { group in
                for c in batch {
                    group.addTask {
                        guard let d = try? await APIService.shared.fetchVideoDetail(
                            site: c.site, vodId: c.item.vodId, timeout: timeout) else { return nil }
                        guard !d.parsePlaySources().isEmpty else { return nil }
                        return PlayableHit(hit: c, detail: d)
                    }
                }
                for await r in group {
                    if let r { group.cancelAll(); return r }
                }
                return nil
            }
            if let got { return got }
            diag("  批内 \(batch.count) 个站都没拿到线路：\(batch.map { $0.site.name }.joined(separator: "、"))")
        }
        return nil
    }

    /// 当前站拿不到详情时，去其它已启用站点搜同名片的详情来接管。
    ///
    /// 只接受标题一致的命中（relevance == 2）；第一轮搜前 16 个站就够覆盖热门站，
    /// 没命中才扩大到全部站点并用包含匹配兜底 —— 97 个站全量搜一轮在端上要几十秒，
    /// 不能一上来就这么干。
    private func adoptDetailFromOtherSites(title rawTitle: String) async -> Bool {
        let query = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = CrossSiteResolver.normalizedTitle(query)
        guard title.count >= 2 else {
            diag("接管：标题太短（\"\(rawTitle)\"），放弃跨站")
            return false
        }

        let allSites = appState.currentConfig?.sites ?? []
        guard !allSites.isEmpty else {
            diag("接管：没有可用站点")
            return false
        }

        var excluding = Set<String>()
        if let key = resolvedSiteKey { excluding.insert(key) }

        // 第一轮：热门站，严格同名片
        let t0 = Date()
        let hits1 = await CrossSiteResolver.search(
            keyword: query, in: allSites, limitPerSite: 6, limitTotal: 40, maxSites: 16)
        let exact = hits1.filter { $0.relevance >= 2 && !excluding.contains($0.site.key) }
        diag("接管第一轮：搜 16 站 \(Int(Date().timeIntervalSince(t0) * 1000))ms · 命中 \(hits1.count) · 同名 \(exact.count)")

        if !exact.isEmpty, let got = await firstPlayableDetail(exact) {
            adoptInfo = "本片由「\(got.hit.site.name)」提供"
            applyDetail(got.detail)
            adoptedSiteKey = got.hit.site.key
            diag("接管成功：\(got.hit.site.name)（\(got.detail.parsePlaySources().count) 条线路）")
            return true
        }

        // 第二轮：放宽到包含匹配。
        // 1.8.2：maxSites 200 → 60。原来这轮会把 110 个站全搜一遍，正好和搜索页的
        // 聚合搜索撞在一起，两批 spider 同时跑把 V8 堆顶爆（闪退）。
        // 页面上早就 dismiss 掉的时候也没必要再扫，先判取消。
        if Task.isCancelled {
            diag("接管：页面已退，放弃第二轮")
            return false
        }
        let t1 = Date()
        let hits2 = await CrossSiteResolver.search(
            keyword: query, in: allSites, limitPerSite: 3, limitTotal: 60, maxSites: 60)
        let loose = hits2.filter { $0.relevance >= 1 && !excluding.contains($0.site.key) }
            .filter { h in !exact.contains(where: { $0.site.key == h.site.key && $0.item.vodId == h.item.vodId }) }
        diag("接管第二轮：全量 \(Int(Date().timeIntervalSince(t1) * 1000))ms · 命中 \(hits2.count) · 可用候选 \(loose.count)")

        if !loose.isEmpty, let got = await firstPlayableDetail(loose) {
            adoptInfo = "本片由「\(got.hit.site.name)」提供（\(got.hit.item.vodName)）"
            applyDetail(got.detail)
            adoptedSiteKey = got.hit.site.key
            diag("接管成功：\(got.hit.site.name)")
            return true
        }

        diag("接管失败：两轮都没有可播线路")
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
