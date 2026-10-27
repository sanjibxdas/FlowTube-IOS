import UIKit

/// The app shell: five tabs, each with its own navigation stack, and the mini player that stays
/// above the tab bar on every screen.
///
/// The mini player is a sibling of the tab bar rather than part of any tab, which is what makes it
/// persistent: switching tabs never tears it down, and a track that started in Music is still
/// reachable from Library. Its height is added to each tab's safe area so no list hides its last
/// row underneath it, and it steps aside while a full-screen player covers the shell.
final class RootTabBarController: UITabBarController, UITabBarControllerDelegate {

    /// The five roots, in tab order. Kept as a value so the order is written once and the tab bar
    /// items, the route mapping and the restoration all read from it.
    private enum Tab: Int, CaseIterable {
        case home
        case shorts
        case music
        case subscriptions
        case library

        var title: String {
            switch self {
            case .home: return "Home"
            case .shorts: return "Shorts"
            case .music: return "Music"
            case .subscriptions: return "Subscriptions"
            case .library: return "Library"
            }
        }

        var icon: FlowIcon {
            switch self {
            case .home: return .home
            case .shorts: return .shorts
            case .music: return .music
            case .subscriptions: return .subscriptions
            case .library: return .library
            }
        }

        var route: Route {
            switch self {
            case .home: return .home
            case .shorts: return .shorts
            case .music: return .music
            case .subscriptions: return .subscriptions
            case .library: return .library
            }
        }

        /// The accessibility identifier a UI test uses to reach the tab.
        var accessibilityIdentifier: String {
            return "tab.\(route.identifier)"
        }
    }

    /// The persistent playback bar. It observes the playback service itself; the shell only
    /// positions it and decides when it must step aside.
    private let miniPlayer = MiniPlayerView()

    /// The height the bar currently reserves. Zero while hidden, so each tab's safe area collapses
    /// with it and lists reclaim the space.
    private var reservedMiniPlayerHeight: CGFloat = 0.0

    /// Playback and theme observers, held for the shell's lifetime.
    private var tokens: [ObservationToken] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        delegate = self
        buildTabs()
        installMiniPlayer()
        restoreSelectedTab()
        observeSignals()
        applyTheme()
        Router.shared.rootTabBarController = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A full-screen player may have been dismissed since the last refresh.
        refreshMiniPlayer(animated: false)
    }

    deinit {
        for token in tokens {
            token.cancelObservation()
        }
    }

    // MARK: - Construction

    private func buildTabs() {
        var controllers: [UIViewController] = []
        for tab in Tab.allCases {
            let root = makeRootController(for: tab)
            root.tabBarItem = makeTabBarItem(for: tab)
            root.tabBarItem.accessibilityIdentifier = tab.accessibilityIdentifier
            let navigation = UINavigationController(rootViewController: root)
            navigation.navigationBar.prefersLargeTitles = false
            navigation.view.backgroundColor = FlowTheme.shared.background
            controllers.append(navigation)
        }
        viewControllers = controllers
    }

    /// The first screen of each tab. The shell does not wrap or decorate them, so a tab looks
    /// exactly like the screen it hosts.
    private func makeRootController(for tab: Tab) -> UIViewController {
        let controller: UIViewController
        switch tab {
        case .home:
            controller = HomeViewController()
        case .shorts:
            controller = ShortsViewController()
        case .music:
            controller = MusicHomeViewController()
        case .subscriptions:
            controller = SubscriptionsViewController()
        case .library:
            controller = LibraryViewController()
        }
        controller.flowRouteIdentifier = tab.route.identifier
        return controller
    }

    private func makeTabBarItem(for tab: Tab) -> UITabBarItem {
        let scheme = FlowTheme.shared.scheme
        let image = tab.icon.drawing.image(size: 25.0, color: scheme.onSurfaceVariant)
        let selectedColor = tab == .shorts ? FlowTheme.shared.shortsAccent : scheme.primary
        let selected = tab.icon.drawing.image(size: 25.0, color: selectedColor)
        return UITabBarItem(title: tab.title, image: image, selectedImage: selected)
    }

    // MARK: - Mini player

    private func installMiniPlayer() {
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        miniPlayer.isHidden = true
        miniPlayer.bind(to: FlowApp.shared.playback)
        miniPlayer.onExpand = { [weak self] in
            self?.expandMiniPlayer()
        }
        miniPlayer.onPlayPause = { [weak self] in
            self?.toggleMiniPlayerPlayback()
        }
        miniPlayer.onSkip = { [weak self] forward in
            self?.skipMiniPlayer(forward: forward)
        }
        miniPlayer.onDismiss = { [weak self] in
            self?.dismissMiniPlayer()
        }

        // The bar fixes its own height, so only its horizontal position and its anchor to the tab
        // bar are set here.
        view.addSubview(miniPlayer)
        NSLayoutConstraint.activate([
            miniPlayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            miniPlayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        miniPlayer.bottomAnchor.constraint(equalTo: tabBar.topAnchor).isActive = true
    }

    /// Shows the bar when something is queued and no full-screen player is covering the shell.
    private func refreshMiniPlayer(animated: Bool) {
        let hasItem = FlowApp.shared.playback.state.value.item != nil
        let shouldShow = hasItem && !isFullPlayerCovering

        miniPlayer.isHidden = !shouldShow

        let newHeight = shouldShow ? MiniPlayerView.barHeight : 0.0
        guard newHeight != reservedMiniPlayerHeight else { return }
        reservedMiniPlayerHeight = newHeight
        applyMiniPlayerInset()

        guard animated else {
            view.layoutIfNeeded()
            return
        }
        FlowMotion.animate({
            self.view.layoutIfNeeded()
        }, completion: nil)
    }

    /// Whether a modal player is on screen. A full-screen presentation covers the tab bar anyway;
    /// hiding the bar as well keeps it from animating behind the player's dismissal.
    private var isFullPlayerCovering: Bool {
        guard let presented = presentedViewController else { return false }
        return presented.modalPresentationStyle == .fullScreen
    }

    /// Pushes each tab's content up by the bar's height so the last row of a list stays reachable.
    private func applyMiniPlayerInset() {
        let inset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: reservedMiniPlayerHeight, right: 0.0)
        for controller in viewControllers ?? [] {
            controller.additionalSafeAreaInsets = inset
        }
    }

    /// Subscribes to playback and palette changes.
    private func observeSignals() {
        tokens.append(FlowApp.shared.playback.state.observeChanges { [weak self] _ in
            self?.refreshMiniPlayer(animated: true)
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
        refreshMiniPlayer(animated: false)
    }

    // MARK: - Mini player actions

    /// Tapping the bar opens the full player for the current item.
    private func expandMiniPlayer() {
        guard let item = FlowApp.shared.playback.state.value.item else { return }
        if item.isMusic {
            Router.shared.open(.music)
            return
        }
        Router.shared.openWatch(videoId: item.videoId)
    }

    private func toggleMiniPlayerPlayback() {
        FlowApp.shared.playback.togglePlayPause()
    }

    private func skipMiniPlayer(forward: Bool) {
        if forward {
            FlowApp.shared.playback.playNext()
        } else {
            FlowApp.shared.playback.playPrevious()
        }
    }

    /// Dragging the bar away stops playback, which is what dismissing it means on Android.
    private func dismissMiniPlayer() {
        FlowApp.shared.playback.stop()
        refreshMiniPlayer(animated: true)
    }

    // MARK: - Theme

    /// Repaints the shell, the tab bar and the mini player in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tabBar.barTintColor = scheme.surfaceContainer
        tabBar.tintColor = scheme.primary
        tabBar.unselectedItemTintColor = scheme.onSurfaceVariant
        tabBar.barStyle = scheme.isDark ? .black : .default
        tabBar.isTranslucent = false

        for controller in viewControllers ?? [] {
            guard let navigation = controller as? UINavigationController else { continue }
            navigation.navigationBar.barTintColor = scheme.surface
            navigation.navigationBar.tintColor = scheme.primary
            navigation.navigationBar.barStyle = scheme.isDark ? .black : .default
            navigation.navigationBar.titleTextAttributes = [
                NSAttributedString.Key.foregroundColor: scheme.onSurface,
                NSAttributedString.Key.font: FlowTypography.titleLarge,
            ]
            navigation.view.backgroundColor = scheme.background
        }

        // Rebuild the glyphs so the unselected tint follows the palette.
        let controllers = viewControllers ?? []
        for (index, tab) in Tab.allCases.enumerated() where index < controllers.count {
            let item = makeTabBarItem(for: tab)
            item.accessibilityIdentifier = tab.accessibilityIdentifier
            controllers[index].tabBarItem = item
        }

        miniPlayer.applyTheme()
        setNeedsStatusBarAppearanceUpdate()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Tab restoration

    /// The tab the viewer left on. Stored as the tab's raw value, so a tab inserted later cannot
    /// shift the meaning of a saved index.
    private func restoreSelectedTab() {
        let stored = FlowApp.shared.prefs.int(for: PrefsStore.Key.selectedTab, fallback: Tab.home.rawValue)
        let tab = Tab(rawValue: stored) ?? .home
        selectedIndex = tab.rawValue
        persistSelectedTab(tab)
    }

    private func persistSelectedTab(_ tab: Tab) {
        FlowApp.shared.prefs.set(tab.rawValue, for: PrefsStore.Key.selectedTab)
    }

    /// The tab index for a tab route, used by the router when a link names a tab.
    func index(of route: Route) -> Int? {
        for tab in Tab.allCases where tab.route == route {
            return tab.rawValue
        }
        return nil
    }

    // MARK: - UITabBarControllerDelegate

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard let tab = Tab(rawValue: selectedIndex) else { return }
        persistSelectedTab(tab)
        // Tapping a tab that is already selected returns to its first screen, matching the
        // Android bottom bar.
        if let navigation = viewController as? UINavigationController,
           navigation.viewControllers.count > 1 {
            navigation.popToRootViewController(animated: true)
        }
    }
}
