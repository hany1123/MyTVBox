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
            Text("· 站点解析 —— site.key 是 noderelay_* 还是 catpaw_*")
            Text("· 最近轨迹 —— 开/完/弃 的先后顺序，闪退就断在最后一个「开」")
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
