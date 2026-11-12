import SwiftUI
import UIKit

/// 添加 / 编辑接口订阅 Sheet
struct AddSubscriptionView: View {

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var isSaving: Bool = false
    @State private var errorText: String? = nil
    @State private var showError: Bool = false
    @State private var noticeText: String = ""
    @State private var showNotice: Bool = false
    /// 接口体检备注（添加成功后是否需要额外说明）
    @State private var pendingNotice: String? = nil
    @State private var validationState: ValidationState = .idle
    @FocusState private var focusedField: Field?

    enum Field { case name, url }

    enum ValidationState {
        case idle
        case checking
        case ok
        /// 校验通过，但需要自定义说明（例如源内核下载完成）
        case okDetail(String)
        case fail(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TVBoxTheme.atmosphere

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header

                        // 名称
                        FieldGroup(label: "名称", code: "01", hint: "可选 · 留空则自动以域名作为名称") {
                            TextField("My TVBox Source", text: $name)
                                .textFieldStyle(TerminalFieldStyle())
                                .focused($focusedField, equals: .name)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .url }
                        }

                        // URL
                        FieldGroup(label: "接口地址", code: "02", hint: "支持 http(s) · 可含 user:pass@ 鉴权 · 支持 .md5 校验后缀") {
                            VStack(spacing: 10) {
                                TextField("http://user:pass@host/path/index.js.md5", text: $url, axis: .vertical)
                                    .textFieldStyle(TerminalFieldStyle())
                                    .lineLimit(2...4)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .focused($focusedField, equals: .url)

                                HStack(spacing: 10) {
                                    Button {
                                        pasteFromClipboard()
                                    } label: {
                                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                                            .font(TVBoxTheme.text(12, weight: .semibold))
                                            .foregroundStyle(TVBoxTheme.accent)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule().stroke(TVBoxTheme.accent.opacity(0.5), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)

                                    if !url.isEmpty {
                                        Button {
                                            url = ""
                                        } label: {
                                            Label("清空", systemImage: "xmark")
                                                .font(TVBoxTheme.text(12))
                                                .foregroundStyle(TVBoxTheme.textSecondary)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(
                                                    Capsule().stroke(TVBoxTheme.stroke, lineWidth: 1)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Spacer()
                                }
                            }
                        }

                        validationCard
                            .animation(.easeInOut(duration: 0.25), value: validationStateKey)

                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 80)
                }

                // 底部固定操作区
                VStack {
                    Spacer()
                    bottomBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle("新增接口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TVBoxTheme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(TVBoxTheme.textSecondary)
                }
            }
            .alert("出错了", isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .alert("接口信息", isPresented: $showNotice) {
                Button("知道了", role: .cancel) { dismiss() }
            } message: {
                Text(noticeText)
            }
            .onAppear { focusedField = .url }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    // MARK: - 顶部说明

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(TVBoxTheme.accent).frame(width: 3, height: 12)
                Text("CONNECT // NEW SOURCE")
                    .font(TVBoxTheme.mono(11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TVBoxTheme.accent)
            }
            Text("接入新的接口")
                .font(TVBoxTheme.display(28))
                .foregroundStyle(TVBoxTheme.textPrimary)
            Text("URL 将被本地保存，并自动尝试解析以验证可用性。")
                .font(TVBoxTheme.text(13))
                .foregroundStyle(TVBoxTheme.textSecondary)
        }
    }

    // MARK: - 验证状态卡片

    private var validationCard: some View {
        Group {
            switch validationState {
            case .idle:
                EmptyView()
            case .checking:
                statusBanner(
                    icon: "antenna.radiowaves.left.and.right",
                    color: TVBoxTheme.accent,
                    title: "正在握手…",
                    detail: "正在向服务端请求配置数据"
                )
            case .ok:
                statusBanner(
                    icon: "checkmark.seal.fill",
                    color: TVBoxTheme.accent,
                    title: "连接成功",
                    detail: "已解析到合法配置，可以保存"
                )
            case .okDetail(let msg):
                statusBanner(
                    icon: "checkmark.seal.fill",
                    color: TVBoxTheme.accent,
                    title: "操作成功",
                    detail: msg
                )
            case .fail(let msg):
                statusBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: TVBoxTheme.warn,
                    title: "无法解析",
                    detail: msg
                )
            }
        }
    }

    private func statusBanner(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(TVBoxTheme.text(13, weight: .bold))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                Text(detail)
                    .font(TVBoxTheme.mono(11))
                    .foregroundStyle(TVBoxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color.opacity(0.5), lineWidth: 1)
        )
    }

    private var validationStateKey: String {
        switch validationState {
        case .idle: return "idle"
        case .checking: return "checking"
        case .ok: return "ok"
        case .okDetail(let m): return "okDetail:\(m)"
        case .fail(let m): return "fail:\(m)"
        }
    }

    // MARK: - 底部操作区

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await runTest() }
            } label: {
                Text(testButtonTitle)
                    .font(TVBoxTheme.text(14, weight: .bold))
                    .foregroundStyle(TVBoxTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(TVBoxTheme.accent.opacity(0.6), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(url.trimmed.isEmpty || isSaving)

            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .tint(.black)
                    }
                    Text(isSaving ? "保存中…" : "保存接口")
                        .font(TVBoxTheme.text(15, weight: .heavy))
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [TVBoxTheme.accent, Color(red: 0.55, green: 1.0, blue: 0.95)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: TVBoxTheme.accent.opacity(0.4), radius: 14, x: 0, y: 6)
                .opacity(canSave ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(TVBoxTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TVBoxTheme.stroke, lineWidth: 1)
        )
    }

    private var testButtonTitle: String {
        switch validationState {
        case .checking: return "测试中…"
        default: return "测试连接"
        }
    }

    private var canSave: Bool {
        !url.trimmed.isEmpty && !isSaving
    }

    // MARK: - 行为

    private func pasteFromClipboard() {
        if let s = UIPasteboard.general.string {
            url = s.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            errorText = "剪贴板为空"
            showError = true
        }
    }

    /// 基础格式校验
    private func basicValidate() -> String? {
        let s = url.trimmed
        if s.isEmpty { return "URL 不能为空" }
        guard let parsed = URLNormalizer.url(s) else { return "URL 格式不合法" }
        guard let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "仅支持 http / https 协议"
        }
        guard let host = parsed.host, !host.isEmpty else { return "缺少主机地址" }
        return nil
    }

    @MainActor
    private func runTest() async {
        if let err = basicValidate() {
            validationState = .fail(err)
            return
        }
        validationState = .checking
        do {
            _ = try await ConfigService.shared.loadConfig(from: url.trimmed)
            validationState = .ok
        } catch {
            // 默认 Spider 模块 URL 有内置 fallback
            if url.trimmed == AppState.defaultSubscriptionURL {
                validationState = .ok
            } else {
                validationState = .fail(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func save() async {
        if let err = basicValidate() {
            errorText = err
            showError = true
            return
        }
        isSaving = true
        defer { isSaving = false }

        let trimmedURL = url.trimmed

        // 1.7.2：`.js.md5` 是猫爪源的「bundle 索引地址」，不是普通订阅。
        // 它指向的是源本体（6.6 MB），拉到本地后由端上 Node 加载。
        if NodeRuntime.isBundleIndexURL(trimmedURL) {
            await handleBundleIndexURL(trimmedURL)
            return
        }

        // 先尝试加载验证
        validationState = .checking
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? autoName(from: trimmedURL) : trimmedName

        do {
            _ = try await ConfigService.shared.loadConfig(from: trimmedURL)
            let st = ConfigService.shared.lastStats
            if let st = st, st.totalSites > 0, st.usableSites == 0 {
                var m = "接口读取成功，但 \(st.totalSites) 个站点全部为 JAR 型（需要 Android 运行时），iOS 无法加载。"
                if st.lives > 0 { m += "\n另有 \(st.lives) 路直播源可用。" }
                m += "\n\n建议换一个含 CMS / JS 站点的接口，或继续使用内置源。"
                pendingNotice = m
                validationState = .fail(m)
            } else if let st = st, st.droppedJarSites > 0, st.usableSites > 0 {
                validationState = .ok
                pendingNotice = "已加载 \(st.usableSites) 个可用站点，另有 \(st.droppedJarSites) 个 JAR 型站点无法在 iOS 运行。"
            } else {
                validationState = .ok
            }
        } catch {
            // 默认 Spider 模块 URL 有内置 fallback，视为可用
            if trimmedURL == AppState.defaultSubscriptionURL {
                validationState = .ok
            } else {
                // 仍允许保存，但提示用户
                validationState = .fail(error.localizedDescription)
                errorText = "无法解析配置：\(error.localizedDescription)\n仍可保存，稍后重试。"
                showError = true
            }
        }

        // 1.4.9：新接口默认加入合并池（可多选），并聚焦到它
        let sub = Subscription(name: displayName, url: trimmedURL, isEnabled: true)
        appState.addSubscription(sub)
        appState.setActive(sub.id)
        await appState.loadConfig()

        // 有体检结论就留在页面上把原因讲清楚，用户点「知道了」再关
        if let note = pendingNotice {
            noticeText = note
            showNotice = true
        } else {
            dismiss()
        }
    }

    /// 1.7.2：处理 `...../index.js.md5` 形式的「源内核索引地址」。
    ///
    /// 它**不是订阅**，而是猫爪源本体的分发接口：
    /// `GET .../index.js.md5` 拿到 32 位 md5，`GET .../index.js` 拿到 6.6 MB 的 bundle。
    /// 下载并校验后存到 Documents/nodejs-project/remote.js，端上 Node 启动时优先加载它。
    /// 这样以后源更新，换个地址就行，不用重打包 IPA。
    @MainActor
    private func handleBundleIndexURL(_ target: String) async {
        validationState = .checking
        let beforeMD5 = NodeRuntime.shared.remoteBundleStatus.md5

        NodeRuntime.shared.remoteIndexURL = target
        let changed = await NodeRuntime.shared.syncRemoteBundle()
        let status = NodeRuntime.shared.remoteBundleStatus

        guard status.isInstalled else {
            let msg = "没能从该地址拉到源内核（index.js）"
            validationState = .fail(msg + " · 检查地址是否能直接下载文件")
            errorText = """
            \(msg)。

            请确认：
            · 该地址能直接下到 index.js（不是网页）
            · index.js.md5 与 index.js 在同一目录
            · 网络可直连（必要时挂代理）
            """
            showError = true
            return
        }

        let sizeText = NodeRuntime.sizeText(status.byteSize)
        validationState = .okDetail("源内核已就位 · \(sizeText) · md5 \(status.md5.prefix(8))…")

        if changed {
            noticeText = """
            源内核已下载并校验通过（\(sizeText)）。

            这是源本体，不是普通订阅 —— 已装到本机，「本机猫爪源」会自动用上它。

            需要「完全退出 App」（后台卡片上滑划掉）再打开，才会切到新内核。
            """
        } else if !beforeMD5.isEmpty && beforeMD5 == status.md5 {
            noticeText = """
            源内核已是最新（\(sizeText)），无需更新。

            md5：\(status.md5)
            """
        } else {
            noticeText = """
            源内核已就位（\(sizeText)）。

            需要「完全退出 App」再打开才会生效。
            """
        }
        showNotice = true
    }

    private func autoName(from url: String) -> String {
        // 保留中文域名原文（URL(string:) 对 IDN 返回 nil，且 punycode 不好看）
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[s.startIndex..<cut])
        }
        return s.isEmpty ? "未命名接口" : s
    }
}

// MARK: - 通用字段块

private struct FieldGroup<Content: View>: View {
    let label: String
    let code: String
    let hint: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(code)
                    .font(TVBoxTheme.mono(10, weight: .bold))
                    .foregroundStyle(TVBoxTheme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(TVBoxTheme.accent.opacity(0.5), lineWidth: 1)
                    )
                Text(label)
                    .font(TVBoxTheme.text(13, weight: .heavy))
                    .foregroundStyle(TVBoxTheme.textPrimary)
            }
            content()
            Text(hint)
                .font(TVBoxTheme.mono(10))
                .foregroundStyle(TVBoxTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 终端风格输入框

private struct TerminalFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(TVBoxTheme.mono(13))
            .foregroundStyle(TVBoxTheme.textPrimary)
            .tint(TVBoxTheme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(TVBoxTheme.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(TVBoxTheme.strokeStrong, lineWidth: 1)
            )
    }
}

// MARK: - 字符串工具

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - 预览

#if compiler(>=5.9)
@available(iOS 17, *)
struct Preview_AddSubscriptionView: PreviewProvider {
    static var previews: some View {
        AddSubscriptionView()
            .environmentObject(AppState())
            .preferredColorScheme(.dark)
    }
}
#endif

