import SwiftUI
import UIKit

/// 站点切换选择器
/// - 1.5.4：JAR 站仍隐藏，但 JS Spider 站（有 bundle / spiderKey）可显示
/// - 当前站点高亮 + 状态指示
struct SitePickerView: View {

    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    // 1.5.5：真机 Spider 诊断（后台跑 JS，结果可一键复制）
    @State private var showDiagnose = false
    @State private var diagnoseText = ""
    @State private var isDiagnosing = false
    // 1.5.9：把 App 已经下载好的 6.6MB bundle 原文导出（系统分享面板）
    @State private var showBundleShare = false
    @State private var bundleShareURL: URL?
    @State private var bundleExportHint = ""

    private var availableSites: [Site] {
        (appState.currentConfig?.sites ?? []).filter {
            $0.type != 3 || $0.spiderKey != nil || SpiderEngine.isSpiderSite($0)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TVBoxTheme.atmosphere

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                            .padding(.horizontal, 16)
                            .padding(.top, 4)

                        if availableSites.isEmpty {
                            emptyView
                                .padding(.horizontal, 16)
                                .padding(.top, 24)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(Array(availableSites.enumerated()), id: \.element.id) { idx, site in
                                    siteRow(site: site, index: idx + 1)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("CHANNEL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        runDiagnose()
                    } label: {
                        Text(isDiagnosing ? "诊断中…" : "SPIDER 诊断")
                            .font(TVBoxTheme.mono(10, weight: .semibold))
                            .foregroundStyle(TVBoxTheme.accent)
                    }
                    .disabled(isDiagnosing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Text("完成")
                            .font(TVBoxTheme.text(14, weight: .semibold))
                            .foregroundStyle(TVBoxTheme.accent)
                    }
                }
            }
            .toolbarBackground(TVBoxTheme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDiagnose) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(diagnoseText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TVBoxTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider().padding(.vertical, 8)
                        Text("拿不到诊断报告之外的 bundle 原文？直接导出：")
                            .font(TVBoxTheme.text(12))
                            .foregroundStyle(TVBoxTheme.textPrimary)
                        Button {
                            exportBundle()
                        } label: {
                            Label("导出 BUNDLE 原文（约 6 MB）", systemImage: "square.and.arrow.up")
                                .font(TVBoxTheme.text(13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TVBoxTheme.accent)
                        if !bundleExportHint.isEmpty {
                            Text(bundleExportHint)
                                .font(TVBoxTheme.mono(10))
                                .foregroundStyle(TVBoxTheme.textPrimary)
                                .textSelection(.enabled)
                        }
                        Text("选择「存储到文件」或发给自己，再把文件放到电脑桌面给我。")
                            .font(TVBoxTheme.mono(10))
                            .foregroundStyle(TVBoxTheme.textPrimary)
                    }
                    .padding(14)
                }
                .background(TVBoxTheme.bg)
                .navigationTitle("SPIDER 诊断")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { showDiagnose = false }
                            .foregroundStyle(TVBoxTheme.accent)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            UIPasteboard.general.string = diagnoseText
                        } label: {
                            Label("复制报告", systemImage: "doc.on.doc")
                        }
                        .foregroundStyle(TVBoxTheme.accent)
                    }
                }
            }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showBundleShare) {
                if let url = bundleShareURL {
                    ActivityView(url: url)
                        .preferredColorScheme(.dark)
                }
            }
        }
        .task {
            // 打开选择器时后台预热各站点首页，选定后立刻有画面
            ContentViewModel.prefetch(sites: availableSites)
        }
    }

    // MARK: - 1.5.5 诊断

    /// 诊断要在后台线程跑：bundle 执行 + home() 可能发同步网络请求，
    /// 放主线程会把整个界面冻住。
    private func runDiagnose() {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        let site = appState.currentSite
        DispatchQueue.global(qos: .userInitiated).async {
            let report = SpiderEngine.shared.diagnoseSync(site: site)
            DispatchQueue.main.async {
                self.diagnoseText = report
                self.isDiagnosing = false
                self.showDiagnose = true
            }
        }
    }

    /// 1.5.9：App 里已经握着完整 bundle 原文，直接写临时文件走系统分享，
    /// 省得老大去源站手动下载（Basic Auth / 302 / 混淆文件名都容易踩坑）。
    private func exportBundle() {
        guard let site = appState.currentSite,
              let code = SpiderContextManager.shared.moduleCode(for: site.key) else {
            bundleExportHint = "当前站点没有 bundle：先切到猫爪 T3 站点再试"
            return
        }
        let hash = SpiderContextManager.shared.sourceHash(for: site.key) ?? "unknown"
        let fileName = "catpaw_" + hash + ".js"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try code.write(to: url, atomically: true, encoding: .utf8)
            bundleShareURL = url
            bundleExportHint = "已就绪：\(fileName)，\(code.utf8.count) 字节 / MD5 \(hash)"
            showBundleShare = true
        } catch {
            bundleExportHint = "写文件失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Rectangle().fill(TVBoxTheme.accent).frame(width: 3, height: 14)
            Text("CHANNEL LIST")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text(String(format: "// %02d", availableSites.count))
                .font(TVBoxTheme.mono(10, weight: .medium))
                .foregroundStyle(TVBoxTheme.textMuted)
            Rectangle().fill(TVBoxTheme.stroke).frame(height: 1)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func siteRow(site: Site, index: Int) -> some View {
        let active = site.key == appState.currentSite?.key
        Button {
            appState.selectSite(site)
            isPresented = false
        } label: {
            HStack(spacing: 14) {
                // 索引/激活点
                ZStack {
                    Circle()
                        .stroke(
                            active ? TVBoxTheme.accent : TVBoxTheme.strokeStrong,
                            lineWidth: 1.2
                        )
                        .frame(width: 36, height: 36)
                    if active {
                        Circle()
                            .fill(TVBoxTheme.accent)
                            .frame(width: 10, height: 10)
                            .shadow(color: TVBoxTheme.accent, radius: 6)
                    } else {
                        Text(String(format: "%02d", index))
                            .font(TVBoxTheme.mono(10, weight: .heavy))
                            .foregroundStyle(TVBoxTheme.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(site.name)
                        .font(TVBoxTheme.text(15, weight: .semibold))
                        .foregroundStyle(TVBoxTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("KEY")
                            .font(TVBoxTheme.mono(9, weight: .heavy))
                            .foregroundStyle(TVBoxTheme.accent.opacity(0.7))
                        Text(site.key)
                            .font(TVBoxTheme.mono(10))
                            .foregroundStyle(TVBoxTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // 来源接口标注（多订阅合并后，同名站点要能区分来自哪个接口）
                    if let source = appState.siteSourceNames[site.key], !source.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text(source)
                                .font(TVBoxTheme.mono(9, weight: .bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(TVBoxTheme.accent.opacity(0.85))
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 5) {
                    if site.isSearchable {
                        capsuleTag("SEARCH", color: TVBoxTheme.accent)
                    }
                    if site.isFilterable {
                        capsuleTag("FILTER", color: TVBoxTheme.warn)
                    }
                    capsuleTag("T\(site.type)", color: TVBoxTheme.textMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? TVBoxTheme.accentSoft : TVBoxTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        active ? TVBoxTheme.accent : TVBoxTheme.stroke,
                        lineWidth: 1
                    )
            )
            .shadow(color: active ? TVBoxTheme.accent.opacity(0.25) : .clear, radius: 10, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func capsuleTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(TVBoxTheme.mono(9, weight: .heavy))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(0.55), lineWidth: 1)
            )
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(TVBoxTheme.textMuted)
            Text("NO CHANNELS")
                .font(TVBoxTheme.mono(11, weight: .heavy))
                .tracking(3)
                .foregroundStyle(TVBoxTheme.textSecondary)
            Text("当前订阅中没有可用站点")
                .font(TVBoxTheme.text(12))
                .foregroundStyle(TVBoxTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
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


// MARK: - 1.5.9 系统分享（导出 bundle 原文）

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
