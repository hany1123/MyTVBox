import SwiftUI

/// 搜索页 —— 关键字搜索 + 搜索历史 + 结果网格
struct SearchView: View {

    @EnvironmentObject var appState: AppState

    // MARK: - 搜索状态

    @State private var keyword: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var results: [VideoItem] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var hasSearched: Bool = false   // 是否已发起过搜索

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

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

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
                VideoDetailView(vodId: item.vodId, previewItem: item)
                    .environmentObject(appState)
            }
        }
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

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 结果标题
            HStack(spacing: 10) {
                Rectangle()
                    .fill(TVBoxTheme.accent)
                    .frame(width: 3, height: 14)
                Text("SEARCH RESULT")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(TVBoxTheme.textPrimary)
                Text(String(format: "// %02d", results.count))
                    .font(TVBoxTheme.mono(10, weight: .medium))
                    .foregroundStyle(TVBoxTheme.textMuted)
                Text("「\(keyword)」")
                    .font(TVBoxTheme.text(12))
                    .foregroundStyle(TVBoxTheme.accent.opacity(0.7))
                Rectangle()
                    .fill(TVBoxTheme.stroke)
                    .frame(height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // 结果网格
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                    Button {
                        path.append(item)
                    } label: {
                        VideoCardView(item: item, index: idx + 1)
                    }
                    .buttonStyle(CardPressStyle())
                }
            }
            .padding(.horizontal, 16)
        }
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
        guard let site = appState.currentSite else { return }

        isSearchFocused = false
        saveSearchHistory(trimmed)
        keyword = trimmed

        isLoading = true
        errorMessage = nil
        hasSearched = true

        Task {
            do {
                let items = try await APIService.shared.searchVideos(site: site, keyword: trimmed)
                await MainActor.run {
                    self.results = items
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
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
