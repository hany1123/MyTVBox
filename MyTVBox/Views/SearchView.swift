import SwiftUI

/// 搜索页 —— 关键字搜索 + 搜索历史 + 结果网格
struct SearchView: View {

    @EnvironmentObject var appState: AppState

    // MARK: - 搜索状态

    @State private var keyword: String = ""
    @FocusState private var isSearchFocused: Bool
    /// 1.4.7：结果带站点归属，跨站点同名片不再撞 ID
    @State private var results: [CrossSiteResolver.SiteSearchResult] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var hasSearched: Bool = false   // 是否已发起过搜索
    @State private var searchedSiteCount: Int = 0
    /// 1.7.5：左侧站点筛选（nil = 全部）
    @State private var siteFilter: String? = nil
    /// 是否聚合当前配置的全部 CMS 站点（关掉则只搜当前站点）
    @AppStorage("MyTVBox.aggregateSearch")
    private var aggregateSearch: Bool = true
    @State private var searchTask: Task<Void, Never>?

    // MARK: - 搜索历史

    @AppStorage("MyTVBox.searchHistory")
    private var searchHistoryData: Data = Data()

    private var searchHistory: [String] {
        get {
            (try? JSONDecoder().decode([String].self, from: searchHistoryData)) ?? []
        }
    }

    private func saveSearchHistory(_ keyword: String) {
        var history = searchHistory
        // 去重：移除已有相同项
        history.removeAll { $0 == keyword }
        // 插入到最前
        history.insert(keyword, at: 0)
        // 最多保留 10 条
        if history.count > 10 {
            history = Array(history.prefix(10))
        }
        searchHistoryData = (try? JSONEncoder().encode(history)) ?? Data()
    }

    private func removeSearchHistory(_ keyword: String) {
        var history = searchHistory
        history.removeAll { $0 == keyword }
        searchHistoryData = (try? JSONEncoder().encode(history)) ?? Data()
    }

    private func clearSearchHistory() {
        searchHistoryData = Data()
    }

    // MARK: - 导航

    @State private var path = NavigationPath()

    // MARK: - 网格列

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TVBoxTheme.atmosphere

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 搜索框
                        searchBar
                            .padding(.horizontal, 16)
                            .padding(.top, 6)

                        // 聚合开关
                        aggregateBar
                            .padding(.horizontal, 16)

                        if isLoading {
                            loadingState
                                .padding(.top, 80)
                        } else if let err = errorMessage, hasSearched {
                            errorState(err)
                                .padding(.top, 60)
                        } else if hasSearched && results.isEmpty {
                            emptyResultState
                                .padding(.top, 80)
                        } else if !hasSearched {
                            // 未搜索时：搜索历史 + 引导
                            historySection
                        } else {
                            // 搜索结果
                            resultSection
                        }

                        // MiniPlayer + TabBar 占位
                        Color.clear.frame(height: 110)
                    }
                    .padding(.bottom, 24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: VideoItem.self) { item in
                VideoDetailView(vodId: item.vodId, previewItem: item,
                                autoSearchOnOpen: false)
                    .environmentObject(appState)
            }
            .navigationDestination(for: CrossSiteResolver.SiteSearchResult.self) { result in
                VideoDetailView(vodId: result.item.vodId,
                                previewItem: result.item,
                                site: result.site,
                                autoSearchOnOpen: false)
                    .environmentObject(appState)
            }
            // 1.7.4：详情页「去搜索」把关键词扔过来，这里接住并直接搜
            .onChange(of: appState.pendingSearchKeyword) { _ in
                consumePendingKeyword()
            }
            .onAppear {
                consumePendingKeyword()
            }
        }
    }

    /// 取走详情页递过来的关键词；取完就清空，避免来回切 Tab 重复触发
    private func consumePendingKeyword() {
        guard let kw = appState.pendingSearchKeyword,
              !kw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appState.pendingSearchKeyword = nil
        keyword = kw
        performSearch()
    }

    // MARK: - 聚合开关

    private var availableSiteCount: Int {
        CrossSiteResolver.usableSites(appState.currentConfig?.sites ?? []).count
    }

    private var aggregateBar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $aggregateSearch) {
                Text("聚合全部站点")
                    .font(TVBoxTheme.text(12, weight: .medium))
                    .foregroundStyle(TVBoxTheme.textSecondary)
            }
            .tint(TVBoxTheme.accent)
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            if aggregateSearch, availableSiteCount > 0 {
                Text("\(availableSiteCount) 个站点并发")
                    .font(TVBoxTheme.mono(10, weight: .medium))
                    .foregroundStyle(TVBoxTheme.textMuted)
            } else if let name = appState.currentSite?.name {
                Text("仅 \(name)")
                    .font(TVBoxTheme.mono(10, weight: .medium))
                    .foregroundStyle(TVBoxTheme.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TVBoxTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TVBoxTheme.stroke, lineWidth: 1)
        )
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TVBoxTheme.accent)

                TextField("搜索影片名称…", text: $keyword)
                    .font(TVBoxTheme.text(15))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                    .tint(TVBoxTheme.accent)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        performSearch()
                    }

                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(TVBoxTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TVBoxTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSearchFocused ? TVBoxTheme.accent.opacity(0.6) : TVBoxTheme.stroke,
                        lineWidth: isSearchFocused ? 1.5 : 1
                    )
            )
            .shadow(
                color: isSearchFocused ? TVBoxTheme.accent.opacity(0.15) : .clear,
                radius: 8, y: 2
            )
            .animation(.easeOut(duration: 0.2), value: isSearchFocused)

            // 搜索按钮
            Button {
                performSearch()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(TVBoxTheme.accent)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                }
                .frame(width: 48, height: 48)
                .shadow(color: TVBoxTheme.accent.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(keyword.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1.0)
        }
    }

    // MARK: - 搜索历史

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 引导界面
            if searchHistory.isEmpty {
                guideState
                    .padding(.top, 60)
            } else {
                // 标题行
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(TVBoxTheme.accent)
                        .frame(width: 3, height: 14)
                    Text("SEARCH HISTORY")
                        .font(TVBoxTheme.mono(11, weight: .heavy))
                        .tracking(3)
                        .foregroundStyle(TVBoxTheme.textPrimary)
                    Text(String(format: "// %02d", searchHistory.count))
                        .font(TVBoxTheme.mono(10, weight: .medium))
                        .foregroundStyle(TVBoxTheme.textMuted)
                    Spacer()
                    Button {
                        clearSearchHistory()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .bold))
                            Text("CLEAR")
                                .font(TVBoxTheme.mono(9, weight: .heavy))
                                .tracking(1)
                        }
                        .foregroundStyle(TVBoxTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // 历史标签
                FlowLayout(spacing: 10) {
                    ForEach(searchHistory, id: \.self) { word in
                        historyTag(word)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func historyTag(_ word: String) -> some View {
        Button {
            keyword = word
            performSearch()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TVBoxTheme.textMuted)
                Text(word)
                    .font(TVBoxTheme.text(13, weight: .medium))
                    .foregroundStyle(TVBoxTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(TVBoxTheme.surface)
            )
            .overlay(
                Capsule()
                    .stroke(TVBoxTheme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                removeSearchHistory(word)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 初始引导界面

    private var guideState: some View {
        VStack(spacing: 16) {
            ZStack {
                // 装饰圆环
                Circle()
                    .stroke(TVBoxTheme.accent.opacity(0.15), lineWidth: 1)
                    .frame(width: 100, height: 100)
                Circle()
                    .stroke(TVBoxTheme.accent.opacity(0.25), lineWidth: 1.5)
                    .frame(width: 60, height: 60)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(TVBoxTheme.accent.opacity(0.6))
            }
            .frame(height: 120)

            Text("SEARCH SIGNAL")
                .font(TVBoxTheme.mono(12, weight: .heavy))
                .tracking(4)
                .foregroundStyle(TVBoxTheme.textSecondary)

            Text("输入关键词搜索影片")
                .font(TVBoxTheme.text(14))
                .foregroundStyle(TVBoxTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 搜索结果

    // MARK: - 站点分组（对标 MiraPlay 左侧筛选列）

    private struct SiteBucket: Identifiable {
        let key: String
        let name: String
        let count: Int
        var id: String { key }
    }

    /// 按站点聚合命中数，顺序沿用配置里的站序（和 MiraPlay 一致，不按数量重排）
    private var siteBuckets: [SiteBucket] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for r in results {
            let k = r.site.key
            if counts[k] == nil {
                order.append(k)
                names[k] = r.site.name
            }
            counts[k, default: 0] += 1
        }
        return order.map { SiteBucket(key: $0, name: names[$0] ?? $0, count: counts[$0] ?? 0) }
    }

    private var filteredResults: [CrossSiteResolver.SiteSearchResult] {
        guard let f = siteFilter else { return results }
        return results.filter { $0.site.key == f }
    }

    private var resultColumns: [GridItem] {
        // 左侧有筛选列时，右边只放得下 2 列
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 结果标题
            HStack(spacing: 8) {
                Rectangle()
                    .fill(TVBoxTheme.accent)
                    .frame(width: 3, height: 14)
                Text("SEARCH RESULT")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TVBoxTheme.textPrimary)
                Text(String(format: "// %02d", results.count))
                    .font(TVBoxTheme.mono(10, weight: .medium))
                    .foregroundStyle(TVBoxTheme.textMuted)
                if searchedSiteCount > 0 {
                    Text("· \(siteBuckets.count)/\(searchedSiteCount) 站有结果")
                        .font(TVBoxTheme.mono(9, weight: .medium))
                        .foregroundStyle(TVBoxTheme.accent.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            HStack(alignment: .top, spacing: 10) {
                siteFilterColumn

                LazyVGrid(columns: resultColumns, spacing: 14) {
                    ForEach(Array(filteredResults.enumerated()), id: \.element.id) { idx, result in
                        Button {
                            path.append(result)
                        } label: {
                            VideoCardView(item: result.item, index: idx + 1)
                                .overlay(alignment: .topTrailing) {
                                    Text(result.siteName)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(TVBoxTheme.accent.opacity(0.9)))
                                        .padding(4)
                                }
                        }
                        .buttonStyle(CardPressStyle())
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)

            if filteredResults.isEmpty {
                Text("这个站点没有可用结果的预览")
                    .font(TVBoxTheme.mono(10))
                    .foregroundStyle(TVBoxTheme.textMuted)
                    .padding(.horizontal, 16)
            }
        }
    }

    /// 左侧竖排站点筛选：全部 + 每个有命中的站点（带命中数）
    private var siteFilterColumn: some View {
        VStack(spacing: 6) {
            siteFilterRow(title: "全部", count: results.count, key: nil)
            ForEach(siteBuckets) { b in
                siteFilterRow(title: b.name, count: b.count, key: b.key)
            }
        }
        .frame(width: 104)
    }

    private func siteFilterRow(title: String, count: Int, key: String?) -> some View {
        let selected = (siteFilter == key)
        return Button {
            siteFilter = key
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TVBoxTheme.text(11, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.black : TVBoxTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(count)")
                    .font(TVBoxTheme.mono(10, weight: .heavy))
                    .foregroundStyle(selected ? Color.black.opacity(0.75) : TVBoxTheme.accent.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? TVBoxTheme.accent : TVBoxTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.clear : TVBoxTheme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态视图

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(TVBoxTheme.accent).scaleEffect(1.2)
            Text("// SCANNING SIGNAL")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyResultState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(TVBoxTheme.textMuted)
            Text("NO RESULT")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textSecondary)
            Text("未找到「\(keyword)」相关内容")
                .font(TVBoxTheme.text(13))
                .foregroundStyle(TVBoxTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ err: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(TVBoxTheme.warn)
            Text("SIGNAL LOST")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.warn)
            Text(err)
                .font(TVBoxTheme.text(12))
                .foregroundStyle(TVBoxTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                performSearch()
            } label: {
                Text("RETRY")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(TVBoxTheme.accent))
                    .shadow(color: TVBoxTheme.accent.opacity(0.4), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 搜索行为

    private func performSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isSearchFocused = false
        saveSearchHistory(trimmed)
        keyword = trimmed

        searchTask?.cancel()
        isLoading = true
        errorMessage = nil
        hasSearched = true
        results = []
        siteFilter = nil

        // 快照当前配置，避免搜索过程中切站导致结果错位
        let useAll = aggregateSearch
        let allSites = appState.currentConfig?.sites ?? []
        let current = appState.currentSite
        let preferred = current?.key

        searchTask = Task { @MainActor in
            let sites: [Site] = useAll ? allSites : (current.map { [$0] } ?? [])
            let usable = CrossSiteResolver.usableSites(sites)
            guard !usable.isEmpty else {
                self.errorMessage = "当前配置没有可用于搜索的 CMS 站点，建议切回内置源"
                self.searchedSiteCount = 0
                self.isLoading = false
                return
            }
            // 1.8.0：面包屑。闪退时进程直接消失，下次启动靠这行定位「死在哪一步」。
            SessionTrace.mark("开 搜索 \(trimmed) 站=\(usable.count)")
            // 1.7.5：搜索页就是要「全站聚合」，别只搜前 24 个。
            // 1.8.0：每站 30 → 16、总量 400 → 240。海报张数直接决定内存峰值，
            // 24 站并发时每站 30 条会把 700+ 张封面同时排队解码，容易顶到 Jetsam。
            let found = await CrossSiteResolver.search(
                keyword: trimmed,
                in: usable,
                limitPerSite: 16,
                limitTotal: 240,
                preferredSiteKey: preferred,
                maxSites: 200
            )
            SessionTrace.mark("完 搜索 \(trimmed) 命中 \(found.count)")
            guard !Task.isCancelled else { return }
            self.searchedSiteCount = usable.count
            self.results = found
            self.isLoading = false
        }
    }
}

// MARK: - 流式布局（标签换行）

private struct FlowLayout: Layout {

    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct ArrangeResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, currentX + size.width)
            totalHeight = max(totalHeight, currentY + size.height)
            currentX += size.width + spacing
        }

        return ArrangeResult(
            size: CGSize(width: totalWidth, height: totalHeight),
            positions: positions
        )
    }
}

// MARK: - 卡片按下动效（复用 ContentGridView 中的样式）

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

#if DEBUG
#if compiler(>=5.9)
@available(iOS 17, *)
struct Preview_SearchView: PreviewProvider {
    static var previews: some View {
        SearchView()
            .environmentObject(AppState())
            .preferredColorScheme(.dark)
    }
}
#endif

#endif
