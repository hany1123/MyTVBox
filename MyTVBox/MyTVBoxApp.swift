import SwiftUI
import UIKit
import AVFoundation

// MARK: - AppDelegate（管理运行时方向锁定 + 后台音频）

class AppDelegate: NSObject, UIApplicationDelegate {
    /// 当前允许的方向
    var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        orientationLock
    }

    /// 获取共享 AppDelegate 实例
    static var shared: AppDelegate? {
        UIApplication.shared.delegate as? AppDelegate
    }

    // MARK: - 生命周期

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 注册后台/前台切换通知
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)

        // 确保后台音频控制可被接收
        application.beginReceivingRemoteControlEvents()

        // 激活音频会话（全局激活一次，后续由各播放器按需调整）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        return true
    }

    // MARK: - 后台音频保活

    @objc private func didEnterBackground() {
        // 通知视频播放器：禁用视频轨道，只保留音频输出
        // iOS 在后台不允许渲染视频，但允许音频继续
        // 如果不禁用视频轨道，整个 AVPlayer 会被挂起
        NotificationCenter.default.post(name: .appDidEnterBackground, object: nil)

        // 重新激活音频会话（防止被系统 deactive）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    @objc private func willEnterForeground() {
        // 通知视频播放器：恢复视频轨道
        NotificationCenter.default.post(name: .appWillEnterForeground, object: nil)

        // 确保音频会话活跃
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

// MARK: - 自定义通知

extension Notification.Name {
    static let appDidEnterBackground = Notification.Name("appDidEnterBackground")
    static let appWillEnterForeground = Notification.Name("appWillEnterForeground")
}

// MARK: - 方向管理器

@MainActor
enum OrientationManager {
    /// 强制横屏（全屏播放时调用）
    static func forceLandscape() {
        AppDelegate.shared?.orientationLock = .landscape
        forceOrientation(.landscapeRight)
    }

    /// 恢复竖屏（退出全屏时调用）
    static func forcePortrait() {
        AppDelegate.shared?.orientationLock = .allButUpsideDown
        forceOrientation(.portrait)
    }

    private static func forceOrientation(_ orientation: UIInterfaceOrientation) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }

        if #available(iOS 16.0, *) {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask(for: orientation))) { _ in }
            windowScene.windows.first?.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
    }

    private static func orientationMask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft:  return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portrait:       return .portrait
        default:              return .allButUpsideDown
        }
    }
}

@main
struct MyTVBoxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    /// 保证端上 Node 只引导一次（视图重建时 .task 可能再次触发）
    @State private var nodeBootTriggered = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    guard !nodeBootTriggered else { return }
                    nodeBootTriggered = true
                    await bootEmbeddedNode()
                }
        }
    }

    /// 1.7.0：启动 App 内置的 Node 运行时，就绪后自动挂上本机猫爪源。
    ///
    /// 这里不需要改 1.6.0 的任何转发逻辑 —— `NodeRelayService` 本来就是
    /// 「说 Node 协议」的客户端，只是把 baseURL 从电脑 IP 换成 127.0.0.1。
    private func bootEmbeddedNode() async {
        NodeRuntime.shared.startIfNeeded()

        // iOS 上的 Node 是 interpreter-only（无 JIT），加载 6.6 MB bundle 偏慢，
        // 首次启动给足 120 秒；之后就绪标记已在，会很快返回。
        let ok = await NodeRuntime.shared.waitUntilReady(timeout: 120)
        guard ok else {
            NSLog("[App] 端上 Node 启动失败，日志:\n%@", NodeRuntime.shared.tailLog())
            return
        }

        NodeRelayService.shared.baseURL = NodeRuntime.shared.baseURL

        await MainActor.run {
            appState.installLocalNodeSource(base: NodeRuntime.shared.baseURL)
        }
        NSLog("[App] 端上 Node 就绪: %@", NodeRuntime.shared.baseURL)
    }
}
