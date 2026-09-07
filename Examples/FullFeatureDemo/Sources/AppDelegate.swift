import UIKit

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(
            rootViewController: FeatureDashboardViewController()
        )
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task { await TelemetryDemoService.shared.flushAtBackgroundBoundary() }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // iOS does not guarantee time for asynchronous termination work. The app
        // therefore flushes on background entry above and does not pretend that a
        // last-second upload here would be reliable.
    }
}
