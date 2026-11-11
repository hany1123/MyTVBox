import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSubscriptionSheet: Bool = false

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
            if appState.hasEnabledSubscription {
                await appState.loadConfig()
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

