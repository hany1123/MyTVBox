import SwiftUI

/// 接口地址（订阅源）管理主页面
///
/// - 列表展示：名称 / URL / 状态 / 是否激活
/// - 点击切换激活
/// - 滑动删除
/// - 右上角 + 添加新接口
/// - 空态引导
struct SubscriptionView: View {

    @EnvironmentObject var appState: AppState
    @StateObject private var vm = SubscriptionViewModel()

    @State private var showAddSheet: Bool = false
    @State private var pendingDelete: Subscription? = nil
    /// m3u8 广告过滤开关（默认关，保证升级后播放行为与 1.4.6 一致）
    @AppStorage("MyTVBox.adFilterEnabled")
    private var adFilterEnabled: Bool = false

    var body: some View {
        ZStack {
            TVBoxTheme.atmosphere

            Group {
                if vm.subscriptions.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .navigationTitle("接口管理")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(TVBoxTheme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(TVBoxTheme.accent)
                }
                .accessibilityLabel("添加接口")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSubscriptionView()
                .environmentObject(appState)
        }
        .alert("删除接口？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let s = pendingDelete {
                    vm.deleteSubscription(s)
                }
                pendingDelete = nil
            }
        } message: {
            if let s = pendingDelete {
                Text("\(s.name) 将从设备中移除。")
            }
        }
        .alert("出错了", isPresented: $vm.showError) {
            Button("好的", role: .cancel) { vm.showError = false }
        } message: {
            Text(vm.errorMessage)
        }
        .alert("接口信息", isPresented: $vm.showNotice) {
            Button("知道了", role: .cancel) { vm.showNotice = false }
        } message: {
            Text(vm.noticeMessage)
        }
        .task {
            vm.attach(appState: appState)
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(TVBoxTheme.stroke, lineWidth: 1)
                    .frame(width: 160, height: 160)
                Circle()
                    .stroke(TVBoxTheme.stroke, lineWidth: 1)
                    .frame(width: 110, height: 110)
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(TVBoxTheme.textMuted)
            }
            VStack(spacing: 8) {
                Text("信号未连接")
                    .font(TVBoxTheme.display(24))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                Text("点击右上角 + 添加你的第一个接口地址")
                    .font(TVBoxTheme.text(13))
                    .foregroundStyle(TVBoxTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showAddSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("添加接口")
                }
                .font(TVBoxTheme.text(14, weight: .bold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(TVBoxTheme.accent)
                .clipShape(Capsule())
                .shadow(color: TVBoxTheme.accent.opacity(0.45), radius: 14, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            // 顶部状态条
            Section {
                statusBar
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(vm.subscriptions) { sub in
                    SubscriptionRow(
                        subscription: sub,
                        isActive: vm.activeId == sub.id,
                        onTap: {
                            Task {
                                await vm.activateSubscription(sub)
                            }
                        }
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pendingDelete = sub
                        } label: {
                            Label("删除", systemImage: "trash.fill")
                        }
                    }
                }
                .onDelete { offsets in
                    vm.deleteSubscription(at: offsets)
                }
            } header: {
                Text("订阅源")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TVBoxTheme.textSecondary)
            }

            if !appState.availableRepos.isEmpty {
                Section {
                    ForEach(appState.availableRepos) { repo in
                        Button {
                            Task { await appState.selectRepo(repo) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: appState.activeRepoURL == repo.url
                                      ? "checkmark.circle.fill" : "shippingbox")
                                    .font(.system(size: 15))
                                    .foregroundStyle(appState.activeRepoURL == repo.url
                                                     ? TVBoxTheme.accent : TVBoxTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(repo.name)
                                        .font(TVBoxTheme.text(14, weight: .semibold))
                                        .foregroundStyle(TVBoxTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(repo.url)
                                        .font(TVBoxTheme.mono(10))
                                        .foregroundStyle(TVBoxTheme.textMuted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("多仓 · 子仓库 (\(appState.availableRepos.count)) · 点击切换")
                        .font(TVBoxTheme.mono(11, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(TVBoxTheme.textSecondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $adFilterEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("智能过滤 m3u8 广告")
                                .font(TVBoxTheme.text(14, weight: .semibold))
                                .foregroundStyle(TVBoxTheme.textPrimary)
                            Text("按分片分组、域名、时长与广告路径识别插播片段")
                                .font(TVBoxTheme.text(11))
                                .foregroundStyle(TVBoxTheme.textMuted)
                        }
                    }
                    .tint(TVBoxTheme.accent)

                    Text(adFilterEnabled
                         ? "开启后由系统资源加载器清洗播放列表，分片仍直连源站；加载失败会自动退回直连。"
                         : "默认关闭，播放直连原始 m3u8。开启后可过滤插播广告，失败会自动直连。")
                        .font(TVBoxTheme.mono(10))
                        .foregroundStyle(TVBoxTheme.textMuted)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text("播放设置")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TVBoxTheme.textSecondary)
            }

            Section {
                Text("提示：长按 / 左滑 可删除接口；点击切换激活")
                    .font(TVBoxTheme.mono(10))
                    .foregroundStyle(TVBoxTheme.textMuted)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listStyle(.plain)
        .refreshable {
            if let active = vm.activeSubscription {
                await vm.activateSubscription(active)
            }
        }
        .overlay(alignment: .top) {
            if vm.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(TVBoxTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        }
    }

    /// 顶部状态条：当前激活源信息
    private var statusBar: some View {
        let active = vm.activeSubscription
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(active != nil ? TVBoxTheme.accent : TVBoxTheme.textMuted)
                    .frame(width: 8, height: 8)
                Circle()
                    .stroke(active != nil ? TVBoxTheme.accent.opacity(0.4) : .clear, lineWidth: 1)
                    .frame(width: 16, height: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(active != nil ? "ONLINE" : "OFFLINE")
                    .font(TVBoxTheme.mono(10, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(active != nil ? TVBoxTheme.accent : TVBoxTheme.textMuted)
                Text(active?.name ?? "未激活任何接口")
                    .font(TVBoxTheme.text(13, weight: .semibold))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(vm.subscriptions.count)")
                .font(TVBoxTheme.mono(20, weight: .heavy))
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text("SRC")
                .font(TVBoxTheme.mono(9, weight: .bold))
                .tracking(1.5)
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
}

// MARK: - 行视图

private struct SubscriptionRow: View {
    let subscription: Subscription
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // 左侧状态指示
                VStack {
                    ZStack {
                        Circle()
                            .stroke(isActive ? TVBoxTheme.accent : TVBoxTheme.strokeStrong, lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                        if isActive {
                            Circle()
                                .fill(TVBoxTheme.accent)
                                .frame(width: 10, height: 10)
                                .shadow(color: TVBoxTheme.accent.opacity(0.7), radius: 6)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 22)
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(subscription.name)
                            .font(TVBoxTheme.text(15, weight: .bold))
                            .foregroundStyle(TVBoxTheme.textPrimary)
                            .lineLimit(1)

                        if isActive {
                            Text("ACTIVE")
                                .font(TVBoxTheme.mono(9, weight: .heavy))
                                .tracking(1.5)
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TVBoxTheme.accent)
                                .clipShape(Capsule())
                        }

                        Spacer(minLength: 0)
                    }

                    Text(subscription.url)
                        .font(TVBoxTheme.mono(11))
                        .foregroundStyle(TVBoxTheme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack(spacing: 10) {
                        if let updated = subscription.lastUpdated {
                            Label(updated.relativeShort, systemImage: "clock")
                                .font(TVBoxTheme.mono(10))
                                .foregroundStyle(TVBoxTheme.textMuted)
                        } else {
                            Label("尚未同步", systemImage: "clock.badge.questionmark")
                                .font(TVBoxTheme.mono(10))
                                .foregroundStyle(TVBoxTheme.textMuted)
                        }
                    }
                    .padding(.top, 2)
                }

                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isActive ? TVBoxTheme.accent : TVBoxTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive ? TVBoxTheme.surfaceRaised : TVBoxTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isActive ? TVBoxTheme.accent.opacity(0.7) : TVBoxTheme.stroke,
                        lineWidth: isActive ? 1.4 : 1
                    )
            )
            .shadow(
                color: isActive ? TVBoxTheme.accent.opacity(0.20) : .clear,
                radius: isActive ? 14 : 0,
                x: 0, y: 4
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 工具

private extension Date {
    /// 简短的相对时间："3 分钟前"
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - 预览

#if compiler(>=5.9)
@available(iOS 17, *)
struct Preview_SubscriptionView: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SubscriptionView()
                .environmentObject(AppState())
        }
        .preferredColorScheme(.dark)
    }
}
#endif

