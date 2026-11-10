import SwiftUI

/// 主标签页容器：将原 ContentView 中的 TabView 抽出
///
/// 各 Tab 的内容会随后续任务逐步填充，这里先以占位视图与统一外观呈现，
/// 同时把"接口管理"嵌入到设置 Tab 中。
struct MainTabView: View {

    @EnvironmentObject var appState: AppState
    @State private var selection: Int = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                HomeView()
                    .environmentObject(appState)
                    .tabItem {
                        Label("首页", systemImage: "house.fill")
                    }
                    .tag(0)

                CategoryView()
                    .environmentObject(appState)
                    .tabItem {
                        Label("分类", systemImage: "square.grid.2x2.fill")
                    }
                    .tag(1)

                SearchView()
                    .environmentObject(appState)
                    .tabItem {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                    .tag(2)

                FavoritesView()
                    .environmentObject(appState)
                    .tabItem {
                        Label("收藏", systemImage: "heart.fill")
                    }
                    .tag(3)

                SettingsTab()
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    .tag(4)
            }
            .tint(TVBoxTheme.accent)
            .background(TVBoxTheme.bg.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .onAppear {
                // 让 TabBar 在深色风格下保持视觉一致
                let appearance = UITabBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor(TVBoxTheme.surface)
                appearance.shadowColor = UIColor.white.withAlphaComponent(0.05)
                UITabBar.appearance().standardAppearance = appearance
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }

            // 底部迷你播放条 —— 浮于 TabBar 之上
            MiniPlayerView()
                .padding(.bottom, 49) // TabBar 高度
                .ignoresSafeArea(.keyboard)
                .allowsHitTesting(true)
        }
    }
}

// MARK: - 设置 Tab

/// 设置 Tab：包含"接口管理"入口
private struct SettingsTab: View {
    @EnvironmentObject var appState: AppState

    /// 从 Info.plist 读取，避免手写版本号跟工程配置脱节
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TVBoxTheme.atmosphere

                ScrollView {
                    VStack(spacing: 18) {
                        SectionHeader(title: "数据源", code: "01")

                        NavigationLink {
                            SubscriptionView()
                                .environmentObject(appState)
                        } label: {
                            settingRow(
                                icon: "antenna.radiowaves.left.and.right",
                                title: "接口管理",
                                subtitle: appState.activeSubscription?.name ?? "尚未配置",
                                badge: "\(appState.subscriptions.count)"
                            )
                        }
                        .buttonStyle(.plain)

                        SectionHeader(title: "关于", code: "02")
                            .padding(.top, 8)

                        infoRow(icon: "info.circle", title: "版本", value: appVersion)
                        infoRow(icon: "lock.shield", title: "隐私", value: "所有数据仅本机存储")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(TVBoxTheme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func settingRow(icon: String, title: String, subtitle: String, badge: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(TVBoxTheme.accentSoft)
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TVBoxTheme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TVBoxTheme.text(15, weight: .semibold))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                Text(subtitle)
                    .font(TVBoxTheme.mono(11))
                    .foregroundStyle(TVBoxTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(badge)
                .font(TVBoxTheme.mono(11, weight: .bold))
                .foregroundStyle(TVBoxTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().stroke(TVBoxTheme.accent.opacity(0.5), lineWidth: 1)
                )
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TVBoxTheme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TVBoxTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TVBoxTheme.stroke, lineWidth: 1)
        )
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TVBoxTheme.textSecondary)
                .frame(width: 22)
            Text(title)
                .font(TVBoxTheme.text(14))
                .foregroundStyle(TVBoxTheme.textPrimary)
            Spacer()
            Text(value)
                .font(TVBoxTheme.mono(11))
                .foregroundStyle(TVBoxTheme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TVBoxTheme.surface.opacity(0.7))
        )
    }
}

/// 通用区块标题（带编号 / 终端风）
struct SectionHeader: View {
    let title: String
    let code: String

    var body: some View {
        HStack(spacing: 10) {
            Text(code)
                .font(TVBoxTheme.mono(10, weight: .bold))
                .foregroundStyle(TVBoxTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(TVBoxTheme.accent.opacity(0.5), lineWidth: 1)
                )
            Text(title.uppercased())
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(TVBoxTheme.textSecondary)
            Rectangle()
                .fill(TVBoxTheme.stroke)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if compiler(>=5.9)
@available(iOS 17, *)
struct Preview_MainTabView: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(AppState())
            .preferredColorScheme(.dark)
    }
}
#endif

