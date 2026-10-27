import UIKit

/// The app's entry point. There is no scene: on iOS 12 the delegate owns the window, so the app
/// builds its interface in `application(_:didFinishLaunchingWithOptions:)` and keeps it for the
/// life of the process.
///
/// Startup order matters and mirrors Android's `FlowApplication` then `MainActivity`:
/// the service container bootstraps first (database, preferences, theme, playback), then the tab
/// bar becomes the root, and the launch screen covers the first frame until the shell is ready.
@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    /// The one window. `FlowSheet` and `FlowSnackbar` reach it through this property to find the
    /// top-most controller, so it must be assigned before anything is presented.
    var window: UIWindow?

    /// The tab shell, kept so a URL can route into it after launch.
    private(set) var rootTabBarController: RootTabBarController?

    /// The splash currently covering the shell, if any.
    private var launchViewController: LaunchViewController?

    /// The theme observer, held for the process lifetime so a palette switch repaints the bars.
    private var themeToken: ObservationToken?

    // MARK: - Launch

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window

        // The container opens the database, restores the theme, the visitor identity and starts
        // playback. It is synchronous on purpose: the first screen is then drawn in the right
        // palette instead of repainting a frame later.
        FlowApp.shared.bootstrap()

        applyAppearanceProxies()
        observeTheme()

        let shell = RootTabBarController()
        rootTabBarController = shell
        window.rootViewController = shell
        window.makeKeyAndVisible()

        presentLaunchScreen(over: shell)

        // A cold launch from a link arrives here rather than in `open url`.
        if let url = launchOptions?[.url] as? URL {
            handleIncoming(url)
        }

        return true
    }

    /// Shows the splash over the shell. It dismisses itself once the minimum display time has
    /// passed and the container reports it is ready, so the hand-off never shows a blank frame.
    private func presentLaunchScreen(over shell: RootTabBarController) {
        let launch = LaunchViewController()
        launch.modalPresentationStyle = .fullScreen
        launch.modalTransitionStyle = .crossDissolve
        launch.onFinished = { [weak self, weak shell] in
            guard let self = self else { return }
            self.launchViewController = nil
            if let shell = shell, shell.presentedViewController === launch {
                shell.dismiss(animated: true, completion: nil)
            }
        }
        launchViewController = launch
        shell.present(launch, animated: false, completion: nil)
    }

    // MARK: - Appearance

    /// Paints the navigation and tab bars through the iOS 12 appearance proxies. The newer
    /// `UINavigationBarAppearance` / `UITabBarAppearance` classes do not exist on this OS.
    private func applyAppearanceProxies() {
        let theme = FlowApp.shared.theme
        let scheme = theme.scheme

        let navigationBar = UINavigationBar.appearance()
        navigationBar.isTranslucent = false
        navigationBar.barTintColor = scheme.surface
        navigationBar.tintColor = scheme.primary
        navigationBar.barStyle = scheme.isDark ? .black : .default
        navigationBar.titleTextAttributes = [
            NSAttributedString.Key.foregroundColor: scheme.onSurface,
            NSAttributedString.Key.font: FlowTypography.titleLarge,
        ]
        navigationBar.largeTitleTextAttributes = [
            NSAttributedString.Key.foregroundColor: scheme.onSurface,
            NSAttributedString.Key.font: FlowTypography.headlineMedium,
        ]

        let tabBar = UITabBar.appearance()
        tabBar.isTranslucent = false
        tabBar.barTintColor = scheme.surfaceContainer
        tabBar.tintColor = scheme.primary
        tabBar.unselectedItemTintColor = scheme.onSurfaceVariant
        tabBar.barStyle = scheme.isDark ? .black : .default

        window?.backgroundColor = scheme.background
    }

    /// Repaints the bars whenever the user picks a different palette.
    private func observeTheme() {
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            guard let self = self else { return }
            self.applyAppearanceProxies()
            self.rootTabBarController?.applyTheme()
            self.launchViewController?.applyTheme()
        }
    }

    // MARK: - URLs

    /// Handles `flow://watch`, `flow://channel`, `flow://playlist`, `flow://search`,
    /// `flow://music` and `flow://settings`. Anything else is reported to the viewer rather than
    /// silently dropped, matching Android's "link not supported" toast.
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        return handleIncoming(url)
    }

    @discardableResult
    private func handleIncoming(_ url: URL) -> Bool {
        guard let destination = DeepLink.parse(url) else {
            FlowSnackbar.showError("That link isn't supported.")
            return false
        }
        // The shell must be on screen before a push can happen; if the splash is still up, the
        // route waits for it to finish instead of being pushed underneath.
        if let launch = launchViewController {
            launch.enqueue(destination)
            return true
        }
        Router.shared.open(destination)
        return true
    }

    // MARK: - Lifecycle

    /// Leaving the foreground is the last reliable moment before the process may be suspended, so
    /// the playback position is written here rather than only on termination.
    func applicationDidEnterBackground(_ application: UIApplication) {
        FlowApp.shared.persistPlaybackPosition()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        FlowApp.shared.persistPlaybackPosition()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        FlowApp.shared.persistPlaybackPosition()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        FlowApp.shared.handleMemoryWarning()
    }
}
