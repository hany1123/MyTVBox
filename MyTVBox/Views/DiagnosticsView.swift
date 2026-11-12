import SwiftUI
import UIKit

/// 1.8.1：把 Spider 诊断从「站点选择器工具栏」搬进设置。
/// 老大反馈「诊断信息不在设置里」——原来只有从首页进站点选择器才看得到，
/// 出问题时那个入口本身可能就是坏的（站点列表空 → 进不去）。
/// 这里独立成页：不依赖任何站点列表，随时可跑、可复制。
struct DiagnosticsView: View {

    @EnvironmentObject var appState: AppState

    @State private var report = ""
    @State private var running = false
    @State private var copiedAt: Date?

    private var siteLabel: String {
        if let site = appState.currentSite {
            return "\(site.name) · \(site.key)"
        }
        return "无当前站点（报告里会说明）"
    }

    var body: some View {
        ZStack {
            TVBoxTheme.atmosphere

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard
                    actionCard
                    if !report.isEmpty {
                        resultCard
                    }
                    explainCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TVBoxTheme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // MARK: - 概览

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "当前状态", code: "01")
                .padding(.bottom, 2)

            kv("可用站点", "\(appState.usableSiteCount) 个")
            kv("启用接口", "\(appState.enabledSubscriptions.count) 个")
            kv("当前站点", siteLabel)
            kv("海报缓存", "420px 缩略 · 96 张 / 28MB")
            kv("站点健康", "\(SiteHealth.shared.coolingKeys().count) 站冷却中")
            kv("进程内存", MemoryProbe.summary())
            // 1.8.6：把「Node 到底起没起来」摆到概览第一行区，别让人对着
            // 97 个缓存站点猜为什么首页 NO CONTENT
            kv("Node 启动", NodeRuntime.shared.bootFailureText
               ?? (NodeRuntime.shared.nodeDidExit
                   ? "已退出（rc=\(NodeRuntime.shared.lastExitCode.map(String.init) ?? "?")）"
                   : (NodeRuntime.shared.isReady ? "已就绪" : "未就绪")))
            kv("fetch 兼容层", NodeRuntime.shared.fetchShimText)
            // 1.8.10：原生信号崩溃（CrashGuard 抓不到的那一类）
            kv("上次原生信号", SignalGuard.lastSignal() ?? "未捕获到")
            kv("signal 监听", SignalGuard.status())
            kv("App 版本", appVersion)
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

    // MARK: - 操作

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                run()
            } label: {
                HStack(spacing: 8) {
                    if running {
                        ProgressView().tint(TVBoxTheme.bg)
                    } else {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 14, weight: .bold))
                    }
                    Text(running ? "诊断中…" : "开始诊断")
                        .font(TVBoxTheme.text(15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(TVBoxTheme.accent)
                .foregroundStyle(TVBoxTheme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(running)

            // 1.8.6：Node 启动失败（rc=9）或运行中退出后，一键重引导
            Button {
                NodeRuntime.shared.restartNode()
                SessionTrace.mark("手 重启本机内核")
            } label: {
                Label("重启本机内核（Node 退出后）", systemImage: "arrow.clockwise")
                    .font(TVBoxTheme.text(13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(TVBoxTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(TVBoxTheme.stroke, lineWidth: 1)
                    )
                    .foregroundStyle(TVBoxTheme.warn)
            }
            .buttonStyle(.plain)

            // 1.8.3：内存吃紧时手动释放海报位图，不重启也能缓一口气
            Button {
                RemoteImageLoader.shared.clearCache()
                SessionTrace.mark("手 清理海报缓存")
            } label: {
                Label("清空海报缓存", systemImage: "photo.badge.arrow.down.fill")
                    .font(TVBoxTheme.text(13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(TVBoxTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(TVBoxTheme.stroke, lineWidth: 1)
                    )
                    .foregroundStyle(TVBoxTheme.accent)
            }
            .buttonStyle(.plain)

            // 1.8.4：万一某个站被误拉黑（临时网络抖动），一键恢复全量搜索
            Button {
                SiteHealth.shared.reset()
                SessionTrace.mark("手 重置站点健康记录")
            } label: {
                Label("重置站点健康（恢复全量搜索）", systemImage: "arrow.uturn.backward")
                    .font(TVBoxTheme.text(13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(TVBoxTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(TVBoxTheme.stroke, lineWidth: 1)
                    )
                    .foregroundStyle(TVBoxTheme.accent)
            }
            .buttonStyle(.plain)

            Text("会跑一遍内核启动、配置拉取、站点解析，数秒内出结果。崩溃类问题请把整段报告复制给我。")
                .font(TVBoxTheme.mono(10))
                .foregroundStyle(TVBoxTheme.textMuted)
        }
    }

    // MARK: - 结果

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("REPORT")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TVBoxTheme.textPrimary)
                Text("// \(report.count) 字符")
                    .font(TVBoxTheme.mono(10))
                    .foregroundStyle(TVBoxTheme.textMuted)
                Spacer()
                Button {
                    UIPasteboard.general.string = report
                    copiedAt = Date()
                } label: {
                    Label(copiedAt == nil ? "复制" : "已复制", systemImage: "doc.on.doc")
                        .font(TVBoxTheme.mono(10, weight: .semibold))
                        .foregroundStyle(TVBoxTheme.accent)
                }
                .buttonStyle(.plain)
            }

            Text(report)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TVBoxTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var explainCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("报告里这几段最有用")
                .font(TVBoxTheme.text(13, weight: .semibold))
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text("· 内核与崩溃 —— 实际在跑哪个内核、本机源配置耗时、上次停在哪一步")
            Text("· 崩溃原因判别 —— 9 类原因逐项列证据，不预设结论")
            Text("· 最近轨迹 —— 开/完/弃 的先后顺序；播放心跳带 rss 和主线程状态")
            Text("· /play 在飞取证 —— 100ms 高频内存尖峰 + Node 侧 REQ/RES/FETCH 轨迹")

            Divider().padding(.vertical, 4)
            Text("进程消失的 9 类可能原因")
                .font(TVBoxTheme.text(13, weight: .semibold))
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text("[1] Jetsam 内存回收  → 看心跳的 rss 与 foot 曲线（Jetsam 依据 phys_footprint）")
            Text("[2] Watchdog 主线程卡死 → 看心跳里有没有「主=卡」")
            Text("[3] Node V8 abort    → 看 node.log 有没有 FATAL / EXIT code")
            Text("[4] AVFoundation 失败 → 看本次播放有没有「败 播放」")
            Text("[5] NSException      → 看 CrashGuard 的崩溃记录")
            Text("[6] 切后台 / 主动结束 → 看「命 进入后台 / 播放页消失」")
            Text("[7] 原生信号崩溃     → 看 signal.log（SIGABRT / SIGSEGV / SIGTRAP）")
            Text("[8] 起播阶段 / 重活并发 → 看本次播放停在哪一步、跨站搜索是否还在飞")
            Text("[9] /play 在飞          → 看 spike.log 有没有亚秒级尖峰、Node 有没有回 RES")
            Text("1s 心跳采不到亚秒级尖峰；`/play` 窗口另有 100ms 采样，两者结论不一致时以 spike.log 为准。")
                .foregroundStyle(TVBoxTheme.textMuted)
            Text("证据范围已收窄到最后一个完整会话；`启 启动` 是重开时间，不是死亡时刻。")
                .foregroundStyle(TVBoxTheme.textMuted)
        }
        .font(TVBoxTheme.mono(10))
        .foregroundStyle(TVBoxTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 逻辑

    private func run() {
        guard !running else { return }
        running = true
        copiedAt = nil
        let site = appState.currentSite
        // 诊断会执行 bundle + 可能发同步网络请求，必须离开主线程
        DispatchQueue.global(qos: .userInitiated).async {
            let text = SpiderEngine.shared.diagnoseSync(site: site)
            DispatchQueue.main.async {
                self.report = text
                self.running = false
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(TVBoxTheme.mono(10, weight: .semibold))
                .foregroundStyle(TVBoxTheme.textMuted)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(TVBoxTheme.mono(10))
                .foregroundStyle(TVBoxTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
