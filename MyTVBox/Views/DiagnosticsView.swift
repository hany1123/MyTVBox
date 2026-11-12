import SwiftUI
import UIKit

/// 1.8.18 收尾版：设置页的「运行状态」。
/// 十类崩溃判读、内存/信号/心跳/高频取样探针已整体移除；
/// 这里只保留「内核跑没跑起来 / 配置读到没 / 站点健康」这些真正能动手修的信息。
/// 真崩了请以系统 .ips 的线程栈为准，说明卡里写了导出路径。
struct DiagnosticsView: View {

    @EnvironmentObject var appState: AppState

    @State private var report = ""
    @State private var running = false
    @State private var copiedAt: Date?

    private var siteLabel: String {
        if let site = appState.currentSite {
            return "\(site.name) · \(site.key)"
        }
        return "无当前站点"
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
            kv("站点健康", "\(SiteHealth.shared.coolingKeys().count) 站冷却中")
            kv("搜索模式", "流式增量上屏 · 自适应并发 · 快站优先")
            kv("Node 启动", NodeRuntime.shared.bootFailureText
               ?? (NodeRuntime.shared.nodeDidExit
                   ? "已退出（rc=\(NodeRuntime.shared.lastExitCode.map(String.init) ?? "?")）"
                   : (NodeRuntime.shared.isReady ? "已就绪" : "未就绪")))
            kv("fetch 兼容层", NodeRuntime.shared.fetchShimText)
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
                    Text(running ? "检查中…" : "检查运行状态")
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

            Button {
                NodeRuntime.shared.restartNode()
            } label: {
                actionLabel("重启本机内核（Node 退出后）", systemImage: "arrow.clockwise",
                            color: TVBoxTheme.warn)
            }
            .buttonStyle(.plain)

            Button {
                RemoteImageLoader.shared.clearCache()
            } label: {
                actionLabel("清空海报缓存", systemImage: "photo.badge.arrow.down.fill",
                            color: TVBoxTheme.accent)
            }
            .buttonStyle(.plain)

            Button {
                SiteHealth.shared.reset()
            } label: {
                actionLabel("重置站点健康（恢复全量搜索）", systemImage: "arrow.uturn.backward",
                            color: TVBoxTheme.accent)
            }
            .buttonStyle(.plain)

            Text("检查会跑一遍内核启动、配置拉取与站点解析，数秒内出结果。")
                .font(TVBoxTheme.mono(10))
                .foregroundStyle(TVBoxTheme.textMuted)
        }
    }

    private func actionLabel(_ title: String, systemImage: String,
                             color: Color) -> some View {
        Label(title, systemImage: systemImage)
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
            .foregroundStyle(color)
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
            Text("出问题看哪里")
                .font(TVBoxTheme.text(13, weight: .semibold))
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text("· 首页空白 / NO CONTENT → 看「Node 启动」和「fetch 兼容层」，必要时点重启内核")
            Text("· 搜不到 / 搜索慢 → 看「站点健康」冷却站名单，可一键重置")
            Text("· 播放失败 → 报告里的「站点路由」能看出站点 key 前缀是否走错路线")

            Divider().padding(.vertical, 4)
            Text("闪退请用系统崩溃日志")
                .font(TVBoxTheme.text(13, weight: .semibold))
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text("App 内的内存/信号/心跳探针已全部移除 —— 前 15 轮证明它们看不到")
            Text("NodeMobile / V8 内部的 C++ 层崩溃，只会增加开销。真闪退时请导出 .ips：")
            Text("设置 → 隐私与安全性 → 分析与改进 → 分析数据 → MyTVBox")
                .foregroundStyle(TVBoxTheme.accent)
            Text("以 .ips 里的崩溃线程栈为准，比任何 App 内判读都准。")
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
        // 会执行 bundle + 可能发同步网络请求，必须离开主线程
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
