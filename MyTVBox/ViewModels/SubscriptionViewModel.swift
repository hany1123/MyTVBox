import Foundation
import SwiftUI
import Combine

/// 接口订阅管理 ViewModel
///
/// 作为 `AppState` 的视图门面（facade）：所有持久化由 AppState 统一负责，
/// 这里只暴露面向视图的便捷 CRUD / 校验 / 加载语义。
///
/// 使用方式：
/// ```swift
/// @StateObject private var vm = SubscriptionViewModel()
/// // ...
/// .task { vm.attach(appState: appState) }
/// ```
@MainActor
final class SubscriptionViewModel: ObservableObject {

    // MARK: - 对外可观察状态

    @Published var subscriptions: [Subscription] = []
    @Published var activeId: UUID?
    @Published var isLoading: Bool = false
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    /// 非错误类提示（接口体检结果等）
    @Published var showNotice: Bool = false
    @Published var noticeMessage: String = ""

    // MARK: - 依赖

    private weak var appState: AppState?

    init() {}

    /// 绑定 AppState（重复调用同一实例时安全）
    func attach(appState: AppState) {
        guard self.appState !== appState else { return }
        self.appState = appState

        // 同步初始值
        self.subscriptions = appState.subscriptions
        self.activeId = appState.activeSubscriptionId

        // 持续镜像 AppState 的状态变化（AppState 已在 MainActor 上发布）
        appState.$subscriptions
            .assign(to: &$subscriptions)
        appState.$activeSubscriptionId
            .assign(to: &$activeId)
    }

    // MARK: - 派生属性

    /// 当前激活订阅
    var activeSubscription: Subscription? {
        guard let id = activeId else { return nil }
        return subscriptions.first { $0.id == id }
    }

    // MARK: - CRUD

    /// 新增订阅；保存后自动尝试加载一次以验证可用性
    func addSubscription(name: String, url: String) async {
        guard let appState else { return }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            present(error: "URL 不能为空")
            return
        }
        guard isLikelyValidURL(trimmedURL) else {
            present(error: "URL 格式不合法")
            return
        }

        let displayName = trimmedName.isEmpty ? autoName(from: trimmedURL) : trimmedName
        let sub = Subscription(name: displayName, url: trimmedURL)
        appState.addSubscription(sub)

        // 自动测试可用性（首个订阅会被设置为 active）
        isLoading = true
        let ok = await testSubscription(url: trimmedURL)
        let stats = ConfigService.shared.lastStats
        isLoading = false

        if !ok {
            present(error: "已保存，但无法解析配置：\(errorMessage.isEmpty ? "未知错误" : errorMessage)")
            return
        }

        // 若添加完成后是激活源，则真正加载一次配置
        if appState.activeSubscriptionId == sub.id {
            await appState.loadConfig()
        }

        // 接口体检结果：明确告诉用户「有几个站、几个能用、为什么不能用」
        if let s = stats {
            if s.totalSites > 0 && s.usableSites == 0 {
                var msg = "接口已添加并成功读取。\n共 \(s.totalSites) 个站点，全部为 JAR 型（需 Android 运行时），iOS 无法加载。"
                if s.lives > 0 { msg += "\n另有 \(s.lives) 路直播源可用。" }
                msg += "\n\n建议换一个含 CMS / JS 站点的接口，或切回内置源。"
                presentNotice(msg)
            } else if s.usableSites > 0 {
                var msg = "接口已添加。\n可用站点 \(s.usableSites) 个"
                if s.droppedJarSites > 0 { msg += "，另有 \(s.droppedJarSites) 个 JAR 型站点不支持" }
                if s.lives > 0 { msg += "，直播 \(s.lives) 路" }
                presentNotice(msg + "。")
            }
        }
    }

    /// 滑动删除
    func deleteSubscription(at offsets: IndexSet) {
        guard let appState else { return }
        let toDelete = offsets.map { subscriptions[$0] }
        for sub in toDelete {
            appState.removeSubscription(sub.id)
        }
    }

    /// 单条删除
    func deleteSubscription(_ subscription: Subscription) {
        appState?.removeSubscription(subscription.id)
    }

    /// 切换激活订阅，并立即加载其配置
    func activateSubscription(_ subscription: Subscription) async {
        guard let appState else { return }
        appState.setActive(subscription.id)
        isLoading = true
        await appState.loadConfig()
        isLoading = false
        if let err = appState.errorMessage {
            present(error: err)
        } else if let notice = appState.configNotice {
            presentNotice(notice)
        }
    }

    /// 验证一个 URL 是否能加载到合法配置
    @discardableResult
    func testSubscription(url: String) async -> Bool {
        do {
            _ = try await ConfigService.shared.loadConfig(from: url)
            return true
        } catch {
            // 默认 Spider 模块 URL 有内置 fallback，视为可用
            if url == AppState.defaultSubscriptionURL {
                errorMessage = "Spider 模块接口，将使用内置源"
                return true
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - 持久化代理

    func loadSubscriptions() {
        appState?.loadSubscriptions()
    }

    func saveSubscriptions() {
        appState?.saveSubscriptions()
    }

    // MARK: - 辅助

    /// 简单 URL 校验：协议 + 主机
    /// 注意：必须走 `URLNormalizer`，否则中文域名（如 `hb.小虎斑.site`）会被
    /// `URL(string:)` 判为 nil，导致「URL 格式不合法」的误报。
    private func isLikelyValidURL(_ s: String) -> Bool {
        guard let url = URLNormalizer.url(s) else { return false }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// 根据 URL 自动生成一个友好的名称（保留中文域名原文，不做 punycode 转换）
    private func autoName(from url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[s.startIndex..<cut])
        }
        return s.isEmpty ? "未命名接口" : s
    }

    private func present(error: String) {
        self.errorMessage = error
        self.showError = true
    }

    private func presentNotice(_ text: String) {
        self.noticeMessage = text
        self.showNotice = true
    }
}
