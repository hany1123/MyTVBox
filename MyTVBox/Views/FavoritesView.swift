import SwiftUI

/// 收藏与播放历史页面
/// - 顶部分段控件：收藏 / 播放历史
/// - 收藏标签：网格展示已收藏视频（复用 VideoCardView），支持滑动删除
/// - 播放历史标签：列表展示历史记录，含进度条，支持清除全部
struct FavoritesView: View {

    @EnvironmentObject var appState: AppState
    @State private var selectedTab: FavTab = .favorites
    @State private var favorites: [FavoritesManager.FavoriteItem] = []
    @State private var histories: [PlayHistoryManager.PlayRecord] = []
    @State private var showClearConfirm: Bool = false
    @State private var path = NavigationPath()

    enum FavTab: String, CaseIterable {
        case favorites = "收藏"
        case history   = "历史"
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TVBoxTheme.atmosphere

                VStack(spacing: 0) {
                    // 自定义分段控件
                    segmentedControl
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 16)

                    // 内容区域
                    Group {
                        switch selectedTab {
                        case .favorites:
                            favoritesContent
                        case .history:
                            historyContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(TVBoxTheme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: VideoItem.self) { item in
                VideoDetailView(vodId: item.vodId, previewItem: item)
                    .environmentObject(appState)
            }
        }
        .onAppear(perform: refreshData)
    }

    // MARK: - 分段控件

    private var segmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(FavTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.rawValue)
                            .font(TVBoxTheme.text(15, weight: .semibold))
                            .foregroundStyle(selectedTab == tab ? TVBoxTheme.accent : TVBoxTheme.textSecondary)

                        Rectangle()
                            .fill(selectedTab == tab ? TVBoxTheme.accent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TVBoxTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TVBoxTheme.stroke, lineWidth: 1)
        )
    }

    // MARK: - 收藏内容

    @ViewBuilder
    private var favoritesContent: some View {
        if favorites.isEmpty {
            emptyState(icon: "heart", title: "暂无收藏内容", subtitle: "在视频详情页点击心形图标即可收藏")
        } else {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 14) {
                    ForEach(favorites) { fav in
                        let item = VideoItem(
                            vodId: fav.vodId,
                            vodName: fav.vodName,
                            vodPic: fav.vodPic
                        )
                        NavigationLink(value: item) {
                            VideoCardView(item: item)
                        }
                        .buttonStyle(CardPressStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                removeFavorite(fav)
                            } label: {
                                Label("取消收藏", systemImage: "heart.slash.fill")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
        }
    }

    // MARK: - 播放历史内容

    @ViewBuilder
    private var historyContent: some View {
        if histories.isEmpty {
            emptyState(icon: "clock", title: "暂无播放记录", subtitle: "观看过的视频会自动记录在这里")
        } else {
            List {
                Section {
                    ForEach(histories) { record in
                        historyRow(record)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteRecord(record)
                                } label: {
                                    Label("删除", systemImage: "trash.fill")
                                }
                            }
                            .onTapGesture {
                                navigateToDetail(record)
                            }
                    }
                } header: {
                    HStack {
                        Text("播放记录")
                            .font(TVBoxTheme.mono(11, weight: .heavy))
                            .tracking(2)
                            .foregroundStyle(TVBoxTheme.textSecondary)
                        Spacer()
                        Button {
                            showClearConfirm = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("清除全部")
                                    .font(TVBoxTheme.mono(10, weight: .heavy))
                                    .tracking(1)
                            }
                            .foregroundStyle(TVBoxTheme.danger)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .listStyle(.plain)
            .alert("清除全部历史？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    PlayHistoryManager.shared.clearAll()
                    refreshData()
                }
            } message: {
                Text("所有播放记录将被删除，此操作不可撤销。")
            }
        }
    }

    // MARK: - 历史记录行

    private func historyRow(_ record: PlayHistoryManager.PlayRecord) -> some View {
        HStack(spacing: 14) {
            // 缩略图
            ZStack {
                if let pic = record.vodPic, !pic.isEmpty, let url = URL(string: pic) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            thumbPlaceholder
                        }
                    }
                } else {
                    thumbPlaceholder
                }
            }
            .frame(width: 80, height: 56)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TVBoxTheme.stroke, lineWidth: 1)
            )

            // 文字信息
            VStack(alignment: .leading, spacing: 5) {
                Text(record.vodName)
                    .font(TVBoxTheme.text(14, weight: .semibold))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(record.episodeName)
                        .font(TVBoxTheme.mono(10, weight: .medium))
                        .foregroundStyle(TVBoxTheme.textSecondary)
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(TVBoxTheme.textMuted)

                    Text(record.timestamp.relativeShort)
                        .font(TVBoxTheme.mono(10))
                        .foregroundStyle(TVBoxTheme.textMuted)
                }

                // 进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(TVBoxTheme.surfaceRaised)
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(TVBoxTheme.accent.opacity(0.8))
                            .frame(width: max(geo.size.width * record.percent, record.percent > 0 ? 4 : 0), height: 4)
                    }
                }
                .frame(height: 4)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TVBoxTheme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TVBoxTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TVBoxTheme.stroke, lineWidth: 1)
        )
    }

    private var thumbPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [TVBoxTheme.surfaceRaised, TVBoxTheme.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "tv")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(TVBoxTheme.textMuted)
        }
    }

    // MARK: - 空状态

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(TVBoxTheme.stroke, lineWidth: 1)
                    .frame(width: 100, height: 100)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(TVBoxTheme.textMuted)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(TVBoxTheme.display(20))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                Text(subtitle)
                    .font(TVBoxTheme.text(13))
                    .foregroundStyle(TVBoxTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 操作

    private func refreshData() {
        favorites = FavoritesManager.shared.getAll()
        histories = PlayHistoryManager.shared.getAllRecords()
    }

    private func removeFavorite(_ fav: FavoritesManager.FavoriteItem) {
        _ = FavoritesManager.shared.toggle(vodId: fav.vodId, vodName: fav.vodName, vodPic: fav.vodPic)
        refreshData()
    }

    private func deleteRecord(_ record: PlayHistoryManager.PlayRecord) {
        PlayHistoryManager.shared.deleteRecord(vodId: record.vodId)
        refreshData()
    }

    private func navigateToDetail(_ record: PlayHistoryManager.PlayRecord) {
        let item = VideoItem(
            vodId: record.vodId,
            vodName: record.vodName,
            vodPic: record.vodPic
        )
        path.append(item)
    }
}

// MARK: - 工具

private extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: self, relativeTo: Date())
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

#if compiler(>=5.9)
@available(iOS 17, *)
struct Preview_FavoritesView: PreviewProvider {
    static var previews: some View {
        FavoritesView()
            .environmentObject(AppState())
            .preferredColorScheme(.dark)
    }
}
#endif

