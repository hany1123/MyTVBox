import SwiftUI

/// 首页 —— 当前站点的最新内容
/// - 顶部站点信息卡（含切换按钮）
/// - 网格展示最新视频，下拉刷新 + 上拉加载更多
/// - 监听 appState.currentSite 变化自动重载
struct HomeView: View {

    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ContentViewModel()

    @State private var path = NavigationPath()
    @State private var showSitePicker: Bool = false
    @State private var headerPulse: Bool = false

    private var availableSites: [Site] {
        (appState.currentConfig?.sites ?? []).filter { $0.type != 3 && $0.api != nil }
    }

    private var availableSitesCount: Int { availableSites.count }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TVBoxTheme.atmosphere

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        siteHeader
                            .padding(.horizontal, 16)
                            .padding(.top, 6)

                        if viewModel.isLoading && viewModel.videoList.isEmpty {
                            loadingState.padding(.top, 80)
                        } else if let err = viewModel.errorMessage, viewModel.videoList.isEmpty {
                            errorState(err).padding(.top, 60)
                        } else if viewModel.videoList.isEmpty && appState.currentSite != nil {
                            emptyState.padding(.top, 80)
                        } else if appState.currentSite == nil {
                            noSiteState.padding(.top, 80)
                        } else {
                            sectionTitle
                                .padding(.horizontal, 16)
                                .padding(.top, 4)

                            ContentGridView(
                                items: viewModel.videoList,
                                isLoadingMore: viewModel.isLoadingMore,
                                onLoadMore: { Task { await loadMore() } },
                                onItemTap: { item in path.append(item) }
                            )

                            // MiniPlayer + TabBar 占位
                            Color.clear.frame(height: 110)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await refresh()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: VideoItem.self) { item in
                VideoDetailView(vodId: item.vodId, previewItem: item)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showSitePicker) {
                SitePickerView(isPresented: $showSitePicker)
                    .environmentObject(appState)
            }
        }
        .task(id: appState.currentSite?.key) {
            guard let site = appState.currentSite else { return }
            // 切换站点后立即重载（有缓存则先渲染缓存再静默刷新），
            // 请求由 ViewModel 自行持有，不会因视图 task 取消而中断
            viewModel.reload(site: site, category: nil)
            warmUpNeighbors(around: site)
        }
        .onAppear { headerPulse = true }
    }

    // MARK: - 顶部站点信息卡

    private var siteHeader: some View {
        HStack(spacing: 14) {
            // 信号徽标
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TVBoxTheme.accentSoft)
                Circle()
                    .stroke(TVBoxTheme.accent.opacity(0.5), lineWidth: 1)
                    .frame(width: 28, height: 28)
                    .scaleEffect(headerPulse ? 1.15 : 1.0)
                    .opacity(headerPulse ? 0.0 : 0.9)
                    .animation(
                        .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                        value: headerPulse
                    )
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(TVBoxTheme.accent)
                    .shadow(color: TVBoxTheme.accent.opacity(0.7), radius: 6)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(TVBoxTheme.accent).frame(width: 6, height: 6)
                        .shadow(color: TVBoxTheme.accent, radius: 4)
                    Text("ON AIR")
                        .font(TVBoxTheme.mono(10, weight: .heavy))
                        .tracking(3)
                        .foregroundStyle(TVBoxTheme.accent)
                }
                Text(appState.currentSite?.name ?? "未选择站点")
                    .font(TVBoxTheme.display(20))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                    .lineLimit(1)
                Text("CH \(String(format: "%02d", channelIndex)) // \(viewModel.videoList.count) ITEMS")
                    .font(TVBoxTheme.mono(10))
                    .foregroundStyle(TVBoxTheme.textMuted)
            }

            Spacer(minLength: 6)

            // 切换站点按钮
            Button {
                showSitePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 11, weight: .heavy))
                    Text("SWITCH")
                        .font(TVBoxTheme.mono(10, weight: .heavy))
                        .tracking(1.5)
                }
                .foregroundStyle(availableSitesCount > 1 ? TVBoxTheme.accent : TVBoxTheme.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(
                    Capsule().stroke(
                        availableSitesCount > 1 ? TVBoxTheme.accent : TVBoxTheme.stroke,
                        lineWidth: 1
                    )
                )
            }
            .buttonStyle(.plain)
            .disabled(availableSitesCount <= 1)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TVBoxTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TVBoxTheme.stroke, lineWidth: 1)
        )
    }

    private var channelIndex: Int {
        let sites = (appState.currentConfig?.sites ?? []).filter { $0.type != 3 }
        if let key = appState.currentSite?.key,
           let idx = sites.firstIndex(where: { $0.key == key }) {
            return idx + 1
        }
        return 0
    }

    // MARK: - 标题分隔

    private var sectionTitle: some View {
        HStack(spacing: 10) {
            Rectangle().fill(TVBoxTheme.accent).frame(width: 3, height: 14)
            Text("LATEST FEED")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text(String(format: "// %02d", viewModel.videoList.count))
                .font(TVBoxTheme.mono(10, weight: .medium))
                .foregroundStyle(TVBoxTheme.textMuted)

            // 缓存已出图、后台仍在刷新时的细微提示
            if viewModel.isLoading && viewModel.isShowingCached {
                ProgressView()
                    .controlSize(.mini)
                    .tint(TVBoxTheme.accent)
                    .scaleEffect(0.7)
            }

            Rectangle().fill(TVBoxTheme.stroke).frame(height: 1)
        }
    }

    // MARK: - 状态视图

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(TVBoxTheme.accent).scaleEffect(1.2)
            Text("// FETCHING SIGNAL")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        // 1.7.3：分两种情况说清楚。端上内核还在起的时候，界面不能只说「暂无内容」——
        // 那会让人以为源坏了，实际是 6.6 MB bundle 在解释执行。
        let nodeReady = NodeRuntime.shared.isReady
        return VStack(spacing: 12) {
            Image(systemName: nodeReady
                  ? "antenna.radiowaves.left.and.right.slash"
                  : "bolt.horizontal.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(TVBoxTheme.textMuted)
            Text(nodeReady ? "NO CONTENT" : "Booting kernel")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textSecondary)
            Text(nodeReady
                 ? "当前站点暂无内容"
                 : "端上内核正在启动（首次约 10~60 秒）")
                .font(TVBoxTheme.text(13))
                .foregroundStyle(TVBoxTheme.textMuted)
            if !nodeReady {
                Text("首次要解释执行 6.6 MB 源码，慢是正常的。若一直停在这里，去「设置」里的站点诊断，把输出发我。")
                    .font(TVBoxTheme.mono(10))
                    .foregroundStyle(TVBoxTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var noSiteState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(TVBoxTheme.textMuted)
            Text("NO CHANNEL")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textSecondary)
            Text(appState.configNotice ?? "请先在设置中添加并激活订阅源")
                .font(TVBoxTheme.text(13))
                .foregroundStyle(TVBoxTheme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)
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
                    .shadow(color: TVBoxTheme.accent.opacity(0.4), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 行为

    /// 后台预热相邻站点首页，来回切换时秒开
    @MainActor
    private func warmUpNeighbors(around site: Site) {
        let list = availableSites
        guard list.count > 1,
              let idx = list.firstIndex(where: { $0.key == site.key }) else { return }
        var targets: [Site] = []
        for offset in [1, -1, 2] {
            let i = (idx + offset + list.count) % list.count
            if i != idx { targets.append(list[i]) }
        }
        ContentViewModel.prefetch(sites: targets)
    }

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
struct Preview_HomeView: PreviewProvider {
    static var previews: some View {
        HomeView()
            .environmentObject(AppState())
            .preferredColorScheme(.dark)
    }
}
#endif

#endif
