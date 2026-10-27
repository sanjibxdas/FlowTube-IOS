import UIKit

/// Every place the app can navigate to, independent of the screen that shows it.
///
/// Routes are values so they can be queued (a deep link that arrives while the splash is up),
/// compared (so the same video is not pushed twice) and logged. A route carries only the id or
/// query it needs; the screen it maps to is registered by the feature that owns it.
enum Route: Hashable {
    case home
    case shorts
    case music
    case subscriptions
    case library

    case watch(videoId: String)
    case channel(id: String)
    case playlist(id: String)
    case search(query: String)
    case musicArtist(id: String)
    case settings

    /// A stable string for de-duplication and for the accessibility identifier a UI test can read.
    var identifier: String {
        switch self {
        case .home: return "home"
        case .shorts: return "shorts"
        case .music: return "music"
        case .subscriptions: return "subscriptions"
        case .library: return "library"
        case .watch(let videoId): return "watch/\(videoId)"
        case .channel(let id): return "channel/\(id)"
        case .playlist(let id): return "playlist/\(id)"
        case .search(let query): return "search/\(query)"
        case .musicArtist(let id): return "music/artist/\(id)"
        case .settings: return "settings"
        }
    }

    /// The tab that owns this route, so a destination with no stack of its own still lands in a
    /// sensible place.
    var owningTab: Route? {
        switch self {
        case .home, .shorts, .music, .subscriptions, .library:
            return self
        case .watch, .channel, .playlist, .search:
            return .home
        case .musicArtist:
            return .music
        case .settings:
            return .library
        }
    }
}

/// Parses the app's `flow://` links into routes. Kept next to `Route` so the URL grammar and the
/// route vocabulary cannot drift apart.
enum DeepLink {

    /// `flow://watch?v=ID`, `flow://channel?id=ID`, `flow://playlist?id=ID`,
    /// `flow://search?q=QUERY`, `flow://music/artist?id=ID`, `flow://settings`.
    ///
    /// Also accepts the shapes the Android app shares: `https://youtu.be/ID`,
    /// `https://www.youtube.com/watch?v=ID`, `/channel/ID`, `/playlist?list=ID` and `/@handle`
    /// is deliberately not guessed at — a handle needs a network lookup, so it is rejected here.
    static func parse(_ url: URL) -> Route? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let values = queryValues(components)

        if scheme == "flow" {
            let host = url.host?.lowercased() ?? ""
            let pathParts = url.path.split(separator: "/").map { String($0) }
            switch host {
            case "watch", "video":
                if let videoId = values["v"] ?? values["id"] ?? pathParts.first, !videoId.isBlank {
                    return .watch(videoId: videoId)
                }
                return nil
            case "channel":
                if let id = values["id"] ?? pathParts.first, !id.isBlank {
                    return .channel(id: id)
                }
                return nil
            case "playlist":
                if let id = values["list"] ?? values["id"] ?? pathParts.first, !id.isBlank {
                    return .playlist(id: id)
                }
                return nil
            case "search":
                if let query = values["q"] ?? values["query"] ?? pathParts.first, !query.isBlank {
                    return .search(query: query)
                }
                return nil
            case "music":
                if pathParts.first == "artist", let id = values["id"] ?? pathParts.dropFirst().first, !id.isBlank {
                    return .musicArtist(id: id)
                }
                return .music
            case "settings":
                return .settings
            case "home":
                return .home
            case "shorts":
                return .shorts
            case "subscriptions":
                return .subscriptions
            case "library":
                return .library
            default:
                return nil
            }
        }

        guard scheme == "http" || scheme == "https" else { return nil }
        let host = url.host?.lowercased() ?? ""
        if host == "youtu.be" {
            if let videoId = url.path.split(separator: "/").first.map(String.init), !videoId.isBlank {
                return .watch(videoId: videoId)
            }
            return nil
        }
        guard host.hasSuffix("youtube.com") else { return nil }
        let pathParts = url.path.split(separator: "/").map { String($0) }
        if pathParts.first == "watch", let videoId = values["v"], !videoId.isBlank {
            return .watch(videoId: videoId)
        }
        if pathParts.first == "shorts", pathParts.count > 1, !pathParts[1].isBlank {
            return .watch(videoId: pathParts[1])
        }
        if pathParts.first == "channel", pathParts.count > 1, !pathParts[1].isBlank {
            return .channel(id: pathParts[1])
        }
        if pathParts.first == "playlist", let id = values["list"], !id.isBlank {
            return .playlist(id: id)
        }
        if pathParts.first == "results", let query = values["search_query"], !query.isBlank {
            return .search(query: query)
        }
        return nil
    }

    private static func queryValues(_ components: URLComponents?) -> [String: String] {
        var values: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            guard let value = item.value, !value.isBlank else { continue }
            values[item.name] = value
        }
        return values
    }
}

/// The app's navigation entry point. Every screen calls this instead of reaching for its own
/// navigation controller, so a tap deep inside one tab still lands on the right stack and the same
/// destination is never pushed twice.
///
/// Screens register themselves for the routes they own during launch; the tab bar registers its
/// five roots. A route with no owner is reported to the viewer rather than silently dropped, which
/// is what the Android app's "link not supported" message does.
final class Router {

    static let shared = Router()

    /// Builds the screen for a route. Registered by the feature that owns the destination, so this
    /// file never has to know a feature screen's initialiser.
    typealias Builder = (Route) -> UIViewController?

    private var builders: [Route: Builder] = [:]
    private let lock = NSLock()

    /// The shell, used to switch tabs. Set by `RootTabBarController` when it is built.
    weak var rootTabBarController: RootTabBarController?

    private init() {}

    // MARK: - Registration

    /// Registers the builder for `route`. Registering the same route again replaces the builder,
    /// which is how a feature can swap in a variant screen without the router knowing why.
    func register(_ route: Route, builder: @escaping Builder) {
        lock.lock()
        builders[route] = builder
        lock.unlock()
    }

    /// Whether a screen exists for `route`.
    func canOpen(_ route: Route) -> Bool {
        lock.lock()
        let hasBuilder = builders[route] != nil
        lock.unlock()
        if hasBuilder { return true }
        return isTabRoute(route)
    }

    private func isTabRoute(_ route: Route) -> Bool {
        switch route {
        case .home, .shorts, .music, .subscriptions, .library:
            return true
        default:
            return false
        }
    }

    // MARK: - Destinations

    func openWatch(videoId: String) {
        guard !videoId.isBlank else { return }
        open(.watch(videoId: videoId))
    }

    func openChannel(id: String) {
        guard !id.isBlank else { return }
        open(.channel(id: id))
    }

    func openPlaylist(id: String) {
        guard !id.isBlank else { return }
        open(.playlist(id: id))
    }

    func openSearch(query: String) {
        open(.search(query: query.trimmed))
    }

    func openMusic(artistId: String) {
        guard !artistId.isBlank else { return }
        open(.musicArtist(id: artistId))
    }

    func openSettings() {
        open(.settings)
    }

    /// Opens `route`, switching tabs when it names one and pushing otherwise.
    func open(_ route: Route) {
        if isTabRoute(route) {
            selectTab(route)
            return
        }

        guard let presenter = Router.topViewController() else { return }

        // Already on screen: bring it back instead of stacking a duplicate on top of it.
        if let existing = existingController(for: route) {
            pop(to: existing)
            return
        }

        guard let destination = makeViewController(for: route) else {
            FlowSnackbar.showError("This link can't be opened.")
            return
        }
        destination.flowRouteIdentifier = route.identifier

        // The player is a full-screen surface, not a page inside a tab: presenting it keeps the
        // tab's stack intact underneath, so dismissing it returns the viewer exactly where they were.
        if case .watch = route {
            present(destination, from: presenter)
            return
        }
        push(destination, from: presenter)
    }

    /// Builds the screen for `route`. A registered builder wins; otherwise the built-in mapping
    /// below covers the core destinations, so a link works before any feature has registered.
    ///
    /// The music artist and settings screens are registered by their own features at launch: they
    /// are the only destinations whose initialiser is not part of the core contract, and the router
    /// deliberately does not guess at one.
    func makeViewController(for route: Route) -> UIViewController? {
        lock.lock()
        let builder = builders[route]
        lock.unlock()
        if let builder = builder, let controller = builder(route) {
            return controller
        }
        return defaultViewController(for: route)
    }

    /// The destinations the router can build on its own.
    private func defaultViewController(for route: Route) -> UIViewController? {
        let app = FlowApp.shared
        switch route {
        case .watch(let videoId):
            return VideoPlayerViewController(videoId: videoId, service: app.playback)
        case .channel(let id):
            return ChannelViewController(channelId: id, api: app.youtubeAPI)
        case .playlist(let id):
            return PlaylistViewController(playlistId: id, api: app.youtubeAPI)
        case .search(let query):
            let controller = SearchViewController()
            controller.initialQuery = query
            return controller
        case .home, .shorts, .music, .subscriptions, .library, .musicArtist, .settings:
            return nil
        }
    }

    // MARK: - Tab switching

    /// Selects the tab for a tab route, popping that tab's stack to its root so the tab shows its
    /// first screen rather than whatever the viewer left there.
    func selectTab(_ route: Route) {
        guard let tabBar = rootTabBarController ?? Router.shell() else { return }
        guard let index = tabBar.index(of: route) else { return }
        tabBar.selectedIndex = index
        if let navigation = tabBar.selectedViewController as? UINavigationController {
            navigation.popToRootViewController(animated: false)
        }
    }

    // MARK: - Pushing and presenting

    /// Pushes `viewController` onto the nearest navigation stack. A controller presented modally
    /// with its own navigation stack is pushed inside that stack, so a sheet's links stay in the
    /// sheet rather than replacing the whole app.
    func push(_ viewController: UIViewController, from presenter: UIViewController? = nil, animated: Bool = true) {
        guard let host = presenter ?? Router.topViewController() else { return }
        if let navigation = host.navigationController {
            navigation.pushViewController(viewController, animated: animated)
            return
        }
        if let navigation = host as? UINavigationController {
            navigation.pushViewController(viewController, animated: animated)
            return
        }
        // A controller with no stack of its own (a sheet, an alert host) gets a stack of its own
        // so the pushed screen has a back button.
        let navigation = UINavigationController(rootViewController: viewController)
        navigation.modalPresentationStyle = .fullScreen
        host.present(navigation, animated: animated, completion: nil)
    }

    /// Presents `viewController` modally from the current top controller.
    func present(_ viewController: UIViewController, from presenter: UIViewController? = nil, animated: Bool = true) {
        guard let host = presenter ?? Router.topViewController() else { return }
        // A controller that is already presenting must not be asked to present twice: present from
        // whatever it is presenting instead.
        if let presented = host.presentedViewController, !presented.isBeingDismissed {
            presented.present(viewController, animated: animated, completion: nil)
            return
        }
        host.present(viewController, animated: animated, completion: nil)
    }

    // MARK: - Lookup

    /// The controller already showing `route`, anywhere in the visible stacks.
    private func existingController(for route: Route) -> UIViewController? {
        guard let root = Router.rootViewController() else { return nil }
        var stack: [UIViewController] = [root]
        while let controller = stack.popLast() {
            if controller.flowRouteIdentifier == route.identifier {
                return controller
            }
            if let navigation = controller as? UINavigationController {
                stack.append(contentsOf: navigation.viewControllers)
            }
            if let tabBar = controller as? UITabBarController {
                stack.append(contentsOf: tabBar.viewControllers ?? [])
            }
            if let presented = controller.presentedViewController {
                stack.append(presented)
            }
            stack.append(contentsOf: controller.children)
        }
        return nil
    }

    /// Pops back to `controller` when it is on a stack, or leaves it alone when it is not.
    private func pop(to controller: UIViewController) {
        guard let navigation = controller.navigationController else { return }
        guard navigation.topViewController !== controller else { return }
        navigation.popToViewController(controller, animated: true)
    }

    // MARK: - Top controller

    /// The controller a new screen should be presented from: the deepest presented controller,
    /// then the visible controller of its navigation stack.
    static func topViewController() -> UIViewController? {
        guard var controller = rootViewController() else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return visibleController(in: controller)
    }

    /// The controller actually on screen inside a container.
    static func visibleController(in controller: UIViewController) -> UIViewController {
        if let navigation = controller as? UINavigationController {
            guard let visible = navigation.visibleViewController else { return navigation }
            return visibleController(in: visible)
        }
        if let tabBar = controller as? UITabBarController {
            guard let selected = tabBar.selectedViewController else { return tabBar }
            return visibleController(in: selected)
        }
        return controller
    }

    /// The window's root controller, whether the delegate is the app's or a test host's.
    static func rootViewController() -> UIViewController? {
        if let delegate = UIApplication.shared.delegate as? AppDelegate, let window = delegate.window {
            return window.rootViewController
        }
        return UIApplication.shared.keyWindow?.rootViewController
    }

    /// The shell, found through the delegate when it was not handed over directly.
    static func shell() -> RootTabBarController? {
        guard let root = rootViewController() else { return nil }
        var stack: [UIViewController] = [root]
        while let controller = stack.popLast() {
            if let tabBar = controller as? RootTabBarController {
                return tabBar
            }
            stack.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController {
                stack.append(presented)
            }
        }
        return nil
    }
}

// MARK: - Route identity on controllers

private var flowRouteKey: UInt8 = 0

extension UIViewController {
    /// The route this controller was opened for, so the router can recognise a destination that is
    /// already on screen. Stored as an associated object because feature screens should not have
    /// to declare a property for the router's bookkeeping.
    var flowRouteIdentifier: String? {
        get {
            return objc_getAssociatedObject(self, &flowRouteKey) as? String
        }
        set {
            objc_setAssociatedObject(self, &flowRouteKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
