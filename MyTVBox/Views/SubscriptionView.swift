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
    /// 1.5.1 云端去广告（默认关；服务失败会自动退回直连）
    @AppStorage("MyTVBox.cloudAdFilterEnabled")
    private var cloudAdFilterEnabled: Bool = false
    /// 1.5.2 自动换源总开关（默认开；关闭后只提示，不擅自切线路）
    @AppStorage("MyTVBox.autoSwitchEnabled")
    private var autoSwitchEnabled: Bool = true

    /// 1.7.2 源内核（远程 bundle）状态刷新计数
    @State private var kernelTick: Int = 0
    @State private var kernelBusy: Bool = false
    @State private var kernelNotice: String = ""
    @State private var showKernelNotice: Bool = false
    /// 1.7.6 进页面后短暂轮询内核启动状态
    @State private var kernelWatchTask: Task<Void, Never>?

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
        .alert("源内核", isPresented: $showKernelNotice) {
            Button("知道了", role: .cancel) { showKernelNotice = false }
        } message: {
            Text(kernelNotice)
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
                        siteCount: appState.siteCount(for: sub.id),
                        usableCount: appState.usableSiteCount(for: sub.id),
                        isSuperseded: appState.isSupersededByLocalNode(sub),
                        onToggle: { newValue in
                            Task { await vm.setEnabled(sub, newValue) }
                        },
                        onTap: {
                            Task {
                                vm.focusSubscription(sub)
                                await vm.refresh(sub)
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
                HStack {
                    Text("订阅源")
                        .font(TVBoxTheme.mono(11, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(TVBoxTheme.textSecondary)
                    Spacer()
                    Text("已启用 \(vm.enabledCount) / \(vm.subscriptions.count)")
                        .font(TVBoxTheme.mono(10, weight: .bold))
                        .foregroundStyle(TVBoxTheme.accent)
                }
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
                kernelSection
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                Text("源内核")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TVBoxTheme.textSecondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $adFilterEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("智能过滤 m3u8 棋牌广告")
                                .font(TVBoxTheme.text(14, weight: .semibold))
                                .foregroundStyle(TVBoxTheme.textPrimary)
                            Text("按分片命名、分组、域名与时长识别插播的棋牌广告段")
                                .font(TVBoxTheme.text(11))
                                .foregroundStyle(TVBoxTheme.textMuted)
                        }
                    }
                    .tint(TVBoxTheme.accent)

                    Text(adFilterEnabled
                         ? "开启后由系统资源加载器清洗播放列表，分片仍直连源站；加载失败会自动退回直连。"
                         : "默认关闭，播放直连原始 m3u8。开启后可过滤棋牌等插播广告，失败会自动直连。")
                        .font(TVBoxTheme.mono(10))
                        .foregroundStyle(TVBoxTheme.textMuted)

                    Divider()
                        .background(TVBoxTheme.textMuted.opacity(0.35))
                        .padding(.vertical, 2)

                    Toggle(isOn: $cloudAdFilterEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("云端 m3u8 去广告")
                                .font(TVBoxTheme.text(14, weight: .semibold))
                                .foregroundStyle(TVBoxTheme.textPrimary)
                            Text("把播放列表交给服务端清洗后再播，真机实测可用")
                                .font(TVBoxTheme.text(11))
                                .foregroundStyle(TVBoxTheme.textMuted)
                        }
                    }
                    .tint(TVBoxTheme.accent)

                    Text(cloudAdFilterEnabled
                         ? "仅对 m3u8 直链生效；服务不可用或返回异常时自动直连原始地址，不会导致播不了。"
                         : "默认关闭。与上面的本地过滤可同时开启，云端优先。")
                        .font(TVBoxTheme.mono(10))
                        .foregroundStyle(TVBoxTheme.textMuted)

                    Divider()
                        .background(TVBoxTheme.textMuted.opacity(0.35))
                        .padding(.vertical, 2)

                    Toggle(isOn: $autoSwitchEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("播放卡顿时自动换源")
                                .font(TVBoxTheme.text(14, weight: .semibold))
                                .foregroundStyle(TVBoxTheme.textPrimary)
                            Text("失败或卡住时自动切线路，并从已播放位置续播")
                                .font(TVBoxTheme.text(11))
                                .foregroundStyle(TVBoxTheme.textMuted)
                        }
                    }
                    .tint(TVBoxTheme.accent)

                    Text(autoSwitchEnabled
                         ? "已开启：优先切不同站点的线路，换源后自动回到刚才的进度。"
                         : "已关闭：线路失败只提示，需要手动切换线路或站点。")
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
                Text("提示：开关决定该接口是否加入合并站点池（可同时开启多个）；点击行刷新该接口；左滑可删除")
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
            await vm.refreshAll()
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

    /// 顶部状态条：合并池概况
    private var statusBar: some View {
        let enabled = vm.enabledCount
        let online = enabled > 0
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(online ? TVBoxTheme.accent : TVBoxTheme.textMuted)
                    .frame(width: 8, height: 8)
                Circle()
                    .stroke(online ? TVBoxTheme.accent.opacity(0.4) : .clear, lineWidth: 1)
                    .frame(width: 16, height: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(online ? "MERGED POOL" : "OFFLINE")
                    .font(TVBoxTheme.mono(10, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(online ? TVBoxTheme.accent : TVBoxTheme.textMuted)
                Text(online
                     ? "已启用 \(enabled) 个接口 · 共 \(vm.mergedSiteCount) 个站点"
                     : "未启用任何接口")
                    .font(TVBoxTheme.text(13, weight: .semibold))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(vm.mergedSiteCount)")
                    .font(TVBoxTheme.mono(20, weight: .heavy))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                Text("SITES")
                    .font(TVBoxTheme.mono(9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(TVBoxTheme.textMuted)
            }
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

    // MARK: - 源内核（1.7.2）

    private var kernel: NodeRuntime.RemoteBundleStatus {
        // 依赖 kernelTick，操作后手动 +1 触发重算
        _ = kernelTick
        return NodeRuntime.shared.remoteBundleStatus
    }

    /// 当前真正在用的内核；还没读到（Node 正在起）就退回内置的描述
    private var active: NodeRuntime.ActiveKernel {
        _ = kernelTick
        return NodeRuntime.shared.activeKernel
            ?? NodeRuntime.ActiveKernel(source: "index.js", bytes: 0, md5: "")
    }

    /// 标题只在「确认过」的前提下才敢下结论，避免内核没起来时瞎猜
    private var activeTitle: String {
        if active.md5.isEmpty { return "内核启动中…" }
        return active.isRemote ? "运行中：下载的内核" : "运行中：App 自带内核"
    }

    private var kernelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1.7.6：这里显示的是「当前进程真正在跑的那份内核」，
            // 而不是「下载了哪份」—— 两者在冷启动之前会不一样，必须分开说。
            HStack(spacing: 10) {
                Image(systemName: active.isRemote ? "cpu.fill" : "cpu")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(active.isRemote ? TVBoxTheme.accent : TVBoxTheme.textSecondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(activeTitle)
                        .font(TVBoxTheme.text(14, weight: .semibold))
                        .foregroundStyle(TVBoxTheme.textPrimary)
                    Text(active.md5.isEmpty
                         ? "内核还没起来，稍等一下"
                         : "\(NodeRuntime.sizeText(active.bytes)) · md5 \(active.md5.prefix(8))…")
                        .font(TVBoxTheme.mono(10))
                        .foregroundStyle(TVBoxTheme.textMuted)
                }

                Spacer(minLength: 4)

                if kernelBusy {
                    ProgressView().tint(TVBoxTheme.accent)
                }
            }

            if let pending = NodeRuntime.shared.pendingKernelMD5 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TVBoxTheme.warn)
                    Text("已下载 md5 \(pending.prefix(8))… · 完全退出 App 再打开才生效")
                        .font(TVBoxTheme.mono(10))
                        .foregroundStyle(TVBoxTheme.warn)
                }
            }

            if let u = kernel.indexURL, !u.isEmpty {
                Text(u)
                    .font(TVBoxTheme.mono(10))
                    .foregroundStyle(TVBoxTheme.textMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await checkKernelUpdate() }
                } label: {
                    Text(kernelBusy ? "检查中…" : "检查更新")
                        .font(TVBoxTheme.text(12, weight: .semibold))
                        .foregroundStyle(TVBoxTheme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().stroke(TVBoxTheme.accent.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(kernelBusy)

                if kernel.isInstalled {
                    Button {
                        NodeRuntime.shared.clearRemoteBundle()
                        kernelTick += 1
                        kernelNotice = "已回退到 App 内置内核。\n\n完全退出 App 再打开后生效。"
                        showKernelNotice = true
                    } label: {
                        Text("回退内置")
                            .font(TVBoxTheme.text(12, weight: .semibold))
                            .foregroundStyle(TVBoxTheme.warn)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().stroke(TVBoxTheme.warn.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            Text("内核就是源本体（约 6.6 MB 的 index.js）。在「添加接口」里填 .../index.js.md5 即可让 App 自己拉新版，不用等我重新打包。")
                .font(TVBoxTheme.mono(10))
                .foregroundStyle(TVBoxTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .onAppear { watchKernelBoot() }
    }

    /// 内核启动要几秒到几十秒，这段时间「运行中」会一直显示「启动中」。
    /// 进来后轻量轮询 30 秒（每 2 秒一次，读一个几十字节的小文件），读到就停手。
    private func watchKernelBoot() {
        kernelWatchTask?.cancel()
        kernelWatchTask = Task {
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run { kernelTick += 1 }
                if let k = NodeRuntime.shared.activeKernel, !k.md5.isEmpty { return }
            }
        }
    }

    private func checkKernelUpdate() async {
        // 1.7.6：没配地址就用内置的默认内核源，省得用户去记那一长串
        if NodeRuntime.shared.remoteIndexURL == nil || NodeRuntime.shared.remoteIndexURL?.isEmpty == true {
            NodeRuntime.shared.remoteIndexURL = NodeRuntime.defaultIndexURL
            kernelTick += 1
        }
        guard let url = NodeRuntime.shared.remoteIndexURL, !url.isEmpty else {
            kernelNotice = "还没有配置远程内核地址。"
            showKernelNotice = true
            return
        }

        kernelBusy = true
        let changed = await NodeRuntime.shared.syncRemoteBundle()
        kernelBusy = false
        kernelTick += 1

        let s = NodeRuntime.shared.remoteBundleStatus
        if !s.isInstalled {
            kernelNotice = "拉取失败：地址不可达或返回内容不是内核。\n\n当前地址：\(url)"
        } else if changed {
            kernelNotice = "已更新到新内核（\(NodeRuntime.sizeText(s.byteSize))）。\n\n完全退出 App 再打开后生效。"
        } else {
            kernelNotice = "已是最新（\(NodeRuntime.sizeText(s.byteSize))），无需更新。"
        }
        showKernelNotice = true
    }
}

// MARK: - 行视图

private struct SubscriptionRow: View {
    let subscription: Subscription
    let isActive: Bool
    /// 该源贡献的站点总数
    let siteCount: Int
    /// 该源贡献的可用站点数（排除 JAR 型）
    let usableCount: Int
    /// 1.7.3：端上 Node 已就绪时，JS bundle 型订阅会被跳过（跑不起来）
    var isSuperseded: Bool = false
    let onToggle: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 左侧启用开关
            Toggle("", isOn: Binding(
                get: { subscription.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .tint(TVBoxTheme.accent)
            .padding(.top, 2)

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

                            if isSuperseded {
                                Text("已由端上内核接管")
                                    .font(TVBoxTheme.mono(9, weight: .bold))
                                    .foregroundStyle(TVBoxTheme.warn)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .overlay(
                                        Capsule()
                                            .stroke(TVBoxTheme.warn.opacity(0.6), lineWidth: 1)
                                    )
                            }

                            Spacer(minLength: 0)
                        }

                        Text(subscription.url)
                            .font(TVBoxTheme.mono(11))
                            .foregroundStyle(TVBoxTheme.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        HStack(spacing: 10) {
                            // 站点数统计
                            if siteCount > 0 {
                                Label("\(usableCount)/\(siteCount) 站点",
                                      systemImage: "square.stack.3d.up.fill")
                                    .font(TVBoxTheme.mono(10))
                                    .foregroundStyle(usableCount > 0 ? TVBoxTheme.accent : TVBoxTheme.textMuted)
                            } else {
                                Label("未加载站点", systemImage: "square.stack.3d.up")
                                    .font(TVBoxTheme.mono(10))
                                    .foregroundStyle(TVBoxTheme.textMuted)
                            }

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
                .opacity(subscription.isEnabled ? 1 : 0.55)
            }
            .buttonStyle(.plain)
        }
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

