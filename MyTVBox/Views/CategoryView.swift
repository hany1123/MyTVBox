import SwiftUI

/// 分类浏览页 —— 顶部横向分类条 + 网格内容区
struct CategoryView: View {

    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ContentViewModel()

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TVBoxTheme.atmosphere

                VStack(spacing: 0) {
                    categoryBar
                    Rectangle()
                        .fill(TVBoxTheme.stroke)
                        .frame(height: 1)
                    contentBody
                }
            }
            .navigationTitle("CATEGORY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TVBoxTheme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: VideoItem.self) { item in
                VideoDetailView(vodId: item.vodId, previewItem: item)
                    .environmentObject(appState)
            }
        }
        .task(id: appState.currentSite?.key) {
            guard let site = appState.currentSite else { return }
            // 1.5.2 分类与内容并发拉取，首屏从「两次往返相加」变成「取较慢的一次」
            await viewModel.loadInitial(site: site)
        }
    }

    // MARK: - 分类标签栏

    @ViewBuilder
    private var categoryBar: some View {
        if !viewModel.categories.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // 默认「最新」：分类还没回来也能先看到内容并随时切回
                        Button {
                            guard let site = appState.currentSite else { return }
                            guard viewModel.currentCategory != nil else { return }
                            Task { await viewModel.loadVideoList(site: site, category: nil) }
                        } label: {
                            Text("最新")
                                .font(TVBoxTheme.text(13, weight: viewModel.currentCategory == nil ? .heavy : .medium))
                                .foregroundStyle(viewModel.currentCategory == nil ? .black : TVBoxTheme.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(viewModel.currentCategory == nil
                                                   ? TVBoxTheme.accent : TVBoxTheme.surfaceRaised)
                                )
                        }
                        .buttonStyle(.plain)

                        ForEach(Array(viewModel.categories.enumerated()), id: \.element.id) { idx, cat in
                            categoryPill(cat: cat, index: idx)
                                .id(cat.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.currentCategory?.id) { newId in
                    guard let id = newId else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .background(TVBoxTheme.surface.opacity(0.6))
        } else if viewModel.isLoading && viewModel.videoList.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(TVBoxTheme.accent)
                    .scaleEffect(0.7)
                Text("// CHANNELS LOADING")
                    .font(TVBoxTheme.mono(10, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TVBoxTheme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        } else {
            // 没有分类时占位
            Text("// NO CATEGORIES")
                .font(TVBoxTheme.mono(10, weight: .heavy))
                .tracking(2)
                .foregroundStyle(TVBoxTheme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }

    private func categoryPill(cat: VideoCategory, index: Int) -> some View {
        let active = cat.id == viewModel.currentCategory?.id
        return Button {
            guard let site = appState.currentSite else { return }
            // 同分类点击不重复加载
            guard cat.id != viewModel.currentCategory?.id else { return }
            Task { await viewModel.loadVideoList(site: site, category: cat) }
        } label: {
            HStack(spacing: 6) {
                Text(String(format: "%02d", index + 1))
                    .font(TVBoxTheme.mono(9, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(active ? .black.opacity(0.65) : TVBoxTheme.accent)
                Text(cat.typeName)
                    .font(TVBoxTheme.text(13, weight: active ? .heavy : .medium))
                    .foregroundStyle(active ? .black : TVBoxTheme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(active ? TVBoxTheme.accent : TVBoxTheme.surfaceRaised)
            )
            .overlay(
                Capsule().stroke(
                    active ? TVBoxTheme.accent : TVBoxTheme.stroke,
                    lineWidth: 1
                )
            )
            .shadow(color: active ? TVBoxTheme.accent.opacity(0.45) : .clear, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentBody: some View {
        ScrollView {
            VStack(spacing: 14) {
                if viewModel.isLoading && viewModel.videoList.isEmpty {
                    loadingState.padding(.top, 60)
                } else if let err = viewModel.errorMessage, viewModel.videoList.isEmpty {
                    errorState(err).padding(.top, 60)
                } else if viewModel.videoList.isEmpty {
                    emptyState.padding(.top, 60)
                } else {
                    headerLine
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    ContentGridView(
                        items: viewModel.videoList,
                        isLoadingMore: viewModel.isLoadingMore,
                        onLoadMore: { Task { await loadMore() } },
                        onItemTap: { item in path.append(item) }
                    )
                    Color.clear.frame(height: 110)
                }
            }
        }
        .refreshable { await refresh() }
    }

    private var headerLine: some View {
        HStack(spacing: 10) {
            Rectangle().fill(TVBoxTheme.accent).frame(width: 3, height: 14)
            Text((viewModel.currentCategory?.typeName ?? "ALL").uppercased())
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text("PG \(viewModel.currentPage)/\(max(viewModel.totalPages, viewModel.currentPage))")
                .font(TVBoxTheme.mono(10))
                .foregroundStyle(TVBoxTheme.textMuted)
            Rectangle().fill(TVBoxTheme.stroke).frame(height: 1)
        }
    }

    // MARK: - 状态

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(TVBoxTheme.accent).scaleEffect(1.2)
            Text("// FETCHING")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(TVBoxTheme.textMuted)
            Text("NO CONTENT")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textSecondary)
            Text("该分类下暂无内容")
                .font(TVBoxTheme.text(12))
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
                Task { await refresh() }
            } label: {
                Text("RETRY")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(TVBoxTheme.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 行为

    private func refresh() async {
        guard let site = appState.currentSite else { return }
        await viewModel.refresh(site: site)
    }

    private func loadMore() async {
        guard let site = appState.currentSite else { return }
        await viewModel.loadMore(site: site)
    }
}

#if DEBUG
#if compiler(>=5.9)
@available(iOS 17, *)
struct Preview_CategoryView: PreviewProvider {
    static var previews: some View {
        CategoryView()
            .environmentObject(AppState())
            .preferredColorScheme(.dark)
    }
}
#endif

#endif
