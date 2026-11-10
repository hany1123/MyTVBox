import UIKit

/// 兜底隐藏/恢复底部 TabBar。
///
/// SwiftUI 的 `.toolbar(.hidden, for: .tabBar)` 在 iOS 16 上偶发「退出播放页后 TabBar 不恢复」，
/// 这里在播放页出现/消失时直接操作 UITabBarController，保证两种状态一定正确。
/// 播放页本身 `.ignoresSafeArea()`，所以 TabBar 隐藏后不会留白。
enum TabBarVisibility {

    static func setHidden(_ hidden: Bool) {
        DispatchQueue.main.async {
            guard let tab = activeTabBarController() else { return }
            guard tab.tabBar.isHidden != hidden else { return }
            tab.tabBar.isHidden = hidden
        }
    }

    private static func activeTabBarController() -> UITabBarController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let tab = findTabBar(in: window.rootViewController) { return tab }
            }
        }
        return nil
    }

    private static func findTabBar(in vc: UIViewController?) -> UITabBarController? {
        guard let vc else { return nil }
        if let tab = vc as? UITabBarController { return tab }
        if let tab = vc.tabBarController { return tab }
        for child in vc.children {
            if let t = findTabBar(in: child) { return t }
        }
        if let presented = vc.presentedViewController {
            return findTabBar(in: presented)
        }
        return nil
    }
}
