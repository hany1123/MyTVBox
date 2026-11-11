import SwiftUI

/// 站点切换选择器
/// - 仅展示 type != 3 的站点（iOS 不支持 Spider/JAR）
/// - 当前站点高亮 + 状态指示
struct SitePickerView: View {

    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    private var availableSites: [Site] {
        (appState.currentConfig?.sites ?? []).filter {
            $0.type != 3 || $0.spiderKey != nil
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
        .task {
            // 打开选择器时后台预热各站点首页，选定后立刻有画面
            ContentViewModel.prefetch(sites: availableSites)
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
