import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSubscriptionSheet: Bool = false
    /// 回前台补加载的去重标记（防止来回切前后台叠好几轮）
    @State private var foregroundReloading: Bool = false

    var body: some View {
        Group {
            if appState.subscriptions.isEmpty {
                // 首次启动引导
                WelcomeView(showSubscriptionSheet: $showSubscriptionSheet)
            } else {
                MainTabView()
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) {
            AddSubscriptionView()
                .environmentObject(appState)
        }
        .task {
            appState.loadSubscriptions()
            // 1.7.7：端上内核还没就绪时别抢先去拉 —— 这时候打 127.0.0.1 只会立刻
            // 连接失败，既把 errorMessage 写成「所有接口都没能加载成功」，也白等
            // 一轮超时。真正的那次加载交给 bootEmbeddedNode（Node 就绪后预热 + 重试）。
            if NodeRuntime.shared.isReady || !appState.hasEnabledLocalNodeSubscription {
                if appState.hasEnabledSubscription {
                    await appState.loadConfig()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            // 1.8.6：Node 明确退出过（最典型是 rc=9 启动参数被拒）时，
            // 回前台自动重引导一次，并重新拉配置 —— 不用用户自己找按钮。
            // nodejs-mobile 不保证同进程可二次初始化，所以只做一次、失败就交给
            // 设置页的明确提示让用户冷启动。
            if NodeRuntime.shared.nodeDidExit {
                NodeRuntime.shared.restartNode()
                foregroundReloading = true
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    _ = await appState.loadConfigWithRetry(attempts: 3, delay: 1.5)
                    foregroundReloading = false
                }
                return
            }
            // 1.7.7：回前台还是 0 站点（后台被系统回收过、或首次加载没赶上），
            // 自动补一次 —— 不用再去「订阅源」里手点某一条。
            guard NodeRuntime.shared.isReady,
                  appState.usableSiteCount == 0,
                  appState.hasEnabledSubscription,
                  !foregroundReloading else { return }
            foregroundReloading = true
            Task {
                await appState.loadConfigWithRetry(attempts: 2, delay: 1.5)
                foregroundReloading = false
            }
        }
        .preferredColorScheme(.dark)
    }
}

#if compiler(>=5.9)
@available(iOS 17, *)
struct Preview_ContentView: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState())
            .preferredColorScheme(.dark)
    }
}
#endif
