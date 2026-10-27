import Foundation

/// The Home feed's state machine.
///
/// The screen owns three things at once: the last feed it managed to load, the filter the viewer
/// picked, and how far the feed has paged. This view model keeps them together so the controller
/// only ever draws `rows` and asks for `refresh()` or `loadMore()`.
final class HomeViewModel {

    /// The chips Home shows above the feed. YouTube's own chip row is server-driven and its browse
    /// endpoint is not exposed by the facade, so Home filters the loaded feed locally by these
    /// categories instead — the same set the specification lists.
    enum Filter: Int, CaseIterable {
        case all
        case music
        case gaming
        case news
        case podcasts
        case live

        var title: String {
            switch self {
            case .all: return "All"
            case .music: return "Music"
            case .gaming: return "Gaming"
            case .news: return "News"
            case .podcasts: return "Podcasts"
            case .live: return "Live"
            }
        }

        /// The words a shelf or a video may carry to belong to this filter.
        var keywords: [String] {
            switch self {
            case .all: return []
            case .music: return ["music", "song", "album", "artist", "mix"]
            case .gaming: return ["gaming", "game", "gameplay", "esports", "minecraft", "fortnite"]
            case .news: return ["news", "politics", "world", "breaking"]
            case .podcasts: return ["podcast", "episode", "interview", "talk"]
            case .live: return ["live", "stream"]
            }
        }
    }

    /// What the screen draws when there are no rows yet.
    enum State: Equatable {
        case loading
        case loaded
        case empty
        case error(String)
    }

    /// The feed's visible state.
    private(set) var state: State = .loading
    /// The rows the table draws, in order.
    private(set) var rows: [HomeRow] = []
    /// The selected chip.
    private(set) var filter: Filter = .all
    /// Whether a refresh is in flight, for the pull-to-refresh control.
    private(set) var isRefreshing = false

    /// Called whenever `rows` or `state` changes, on the main queue.
    var onChange: (() -> Void)?
    /// Called when a refresh fails while content is already on screen, so the screen can show a
    /// snackbar instead of replacing the feed with an error.
    var onRefreshFailure: ((String) -> Void)?

    private let api: YouTubeAPI
    private let history: HistoryStore
    private let prefs: PrefsStore
    private let cache: HomeFeedCache

    /// The feed as it arrived, before filtering. Kept so switching chips never re-requests.
    private var feed: VideoHomeFeed?
    private var continuation: String?
    private var isLoadingMore = false
    private var loadMoreError: String?
    private var hasLoadedOnce = false
    private var isRequesting = false

    init(
        api: YouTubeAPI = YouTubeAPI(),
        history: HistoryStore = .shared,
        prefs: PrefsStore = .shared,
        cache: HomeFeedCache = .shared
    ) {
        self.api = api
        self.history = history
        self.prefs = prefs
        self.cache = cache
    }

    // MARK: - Loading

    /// Shows the cached feed immediately, then loads a fresh one.
    ///
    /// The cached feed is what makes a cold launch feel instant: the last successful feed is on
    /// disk, so the screen paints real content before the network answers. A failed refresh leaves
    /// that content in place and reports the failure separately.
    func loadIfNeeded() {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        if let snapshot = cache.load(), !snapshot.feed.sections.isEmpty {
            feed = snapshot.feed
            continuation = snapshot.feed.continuation
            rebuildRows()
            state = rows.isEmpty ? .loading : .loaded
            notify()
        }
        refresh()
    }

    /// Reloads the first page. Pull-to-refresh and the retry button both call this.
    func refresh(completion: (() -> Void)? = nil) {
        guard !isRequesting else {
            completion?()
            return
        }
        isRequesting = true
        isRefreshing = true
        loadMoreError = nil
        if rows.isEmpty {
            state = .loading
            notify()
        }
        api.home { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isRequesting = false
                self.isRefreshing = false
                switch result {
                case .success(let feed):
                    self.feed = feed
                    self.continuation = feed.continuation
                    self.cache.save(feed)
                    self.rebuildRows()
                    self.state = self.rows.isEmpty ? .empty : .loaded
                    self.notify()
                case .failure(let error):
                    if self.rows.isEmpty {
                        self.state = .error(error.displayMessage)
                        self.notify()
                    } else {
                        self.onRefreshFailure?(error.displayMessage)
                    }
                }
                completion?()
            }
        }
    }

    /// Loads the next page, if there is one.
    func loadMore() {
        guard let token = continuation, !token.isEmpty, !isLoadingMore, !isRequesting else { return }
        isLoadingMore = true
        loadMoreError = nil
        rebuildRows()
        notify()
        api.homeContinuation(token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoadingMore = false
                switch result {
                case .success(let page):
                    var merged = self.feed ?? VideoHomeFeed(chips: [], sections: [], continuation: nil)
                    merged.sections.append(contentsOf: page.sections)
                    merged.continuation = page.continuation
                    self.feed = merged
                    self.continuation = page.continuation
                    self.cache.save(merged)
                    self.rebuildRows()
                    self.state = self.rows.isEmpty ? .empty : .loaded
                case .failure(let error):
                    self.loadMoreError = error.displayMessage
                    self.rebuildRows()
                }
                self.notify()
            }
        }
    }

    /// Switches the chip. Filtering is local, so the feed stays where it is.
    func selectFilter(_ newFilter: Filter) {
        guard newFilter != filter else { return }
        filter = newFilter
        rebuildRows()
        state = rows.isEmpty ? .empty : .loaded
        notify()
    }

    /// Re-reads the continue-watching row from the history table without touching the network.
    ///
    /// The history table changes while the viewer is elsewhere — a video they just watched becomes
    /// resumable, one they finished drops out — so Home refreshes that one row when it reappears.
    func reloadHistoryRow() {
        guard hasLoadedOnce, feed != nil else { return }
        let previous = rows
        rebuildRows()
        if previous.map({ $0.id }) != rows.map({ $0.id }) {
            notify()
        }
    }

    /// Retries the page that failed to load.
    func retryLoadMore() {
        loadMoreError = nil
        loadMore()
    }

    /// The videos currently on screen, in feed order, for prefetching thumbnails.
    var visibleVideos: [Video] {
        var result: [Video] = []
        for row in rows {
            switch row {
            case .video(let video):
                result.append(video)
            case .shelf(let shelf):
                result.append(contentsOf: shelf.items)
            case .shortsShelf(let videos):
                result.append(contentsOf: videos)
            case .continueWatching, .status:
                break
            }
        }
        return result
    }

    // MARK: - Rows

    /// Rebuilds `rows` from the cached feed, the filter and the paging state.
    private func rebuildRows() {
        var built: [HomeRow] = []

        if filter == .all {
            let entries = continueWatchingEntries()
            if !entries.isEmpty {
                built.append(.continueWatching(entries))
            }
            let shorts = shortsShelfVideos()
            if !shorts.isEmpty {
                built.append(.shortsShelf(shorts))
            }
        }

        let sections = filteredSections()
        for section in sections {
            if section.items.count >= 3 {
                built.append(.shelf(section))
            } else {
                for video in section.items {
                    built.append(.video(video))
                }
            }
        }

        if !built.isEmpty || state == .loaded {
            if isLoadingMore {
                built.append(.status(.loadingMore))
            } else if let message = loadMoreError {
                built.append(.status(.loadMoreFailed(message)))
            } else if continuation == nil || (continuation ?? "").isEmpty {
                built.append(.status(.end))
            }
        }

        rows = built
    }

    /// The feed's sections with the selected chip applied, empty shelves dropped.
    private func filteredSections() -> [VideoShelf] {
        guard let feed = feed else { return [] }
        guard filter != .all else {
            return feed.sections.filter { !$0.items.isEmpty }
        }
        var result: [VideoShelf] = []
        for section in feed.sections {
            let items = section.items.filter { matches($0, filter: filter) }
            if items.isEmpty { continue }
            result.append(VideoShelf(
                title: section.title,
                subtitle: section.subtitle,
                items: items,
                moreBrowseId: section.moreBrowseId
            ))
        }
        return result
    }

    /// Whether a video belongs to a chip.
    private func matches(_ video: Video, filter: Filter) -> Bool {
        switch filter {
        case .all:
            return true
        case .music:
            return video.isMusic
        case .live:
            return video.isLive
        case .gaming, .news, .podcasts:
            let haystack = [
                video.title,
                video.channelName,
                video.category ?? "",
                video.snippet,
                video.tags.joined(separator: " "),
            ].joined(separator: " ").lowercased()
            return filter.keywords.contains { haystack.contains($0) }
        }
    }

    /// The videos worth resuming: watched but not finished, newest first.
    private func continueWatchingEntries() -> [HistoryEntry] {
        let recent = history.recent(limit: 20)
        var result: [HistoryEntry] = []
        for entry in recent {
            if entry.isFinished { continue }
            if entry.progress <= 0.0 { continue }
            result.append(entry)
            if result.count >= 10 { break }
        }
        return result
    }

    /// Shorts for the shelf: the feed's own Shorts, or the shortest vertical-looking items.
    private func shortsShelfVideos() -> [Video] {
        guard prefs.bool(for: .showShortsShelf, fallback: true) else { return [] }
        guard let feed = feed else { return [] }
        var shorts: [Video] = []
        for section in feed.sections {
            for video in section.items where video.isShort {
                if shorts.contains(where: { $0.id == video.id }) { continue }
                shorts.append(video)
            }
        }
        if shorts.isEmpty {
            let lowered = ["short", "shorts", "#shorts"]
            for section in feed.sections {
                let title = section.title.lowercased()
                guard lowered.contains(where: { title.contains($0) }) else { continue }
                for video in section.items where !shorts.contains(where: { $0.id == video.id }) {
                    shorts.append(video)
                }
            }
        }
        return Array(shorts.prefix(12))
    }

    private func notify() {
        onChange?()
    }
}

// MARK: - Feed cache

/// The last successful Home feed, stored as JSON so a cold launch paints real content.
///
/// `Video` is not `Codable` — it carries dates and is built by the parsers — so the snapshot keeps
/// only what a row draws and rebuilds `Video` values from that.
final class HomeFeedCache {

    static let shared = HomeFeedCache()

    private struct Snapshot: Codable {
        var sections: [SnapshotShelf]
        var continuation: String?
        var savedAt: Double
    }

    private struct SnapshotShelf: Codable {
        var title: String
        var subtitle: String?
        var moreBrowseId: String?
        var items: [SnapshotVideo]
    }

    private struct SnapshotVideo: Codable {
        var id: String
        var title: String
        var channelName: String
        var channelId: String
        var thumbnailUrl: String
        var duration: Int
        var viewCount: Int64
        var uploadDate: String
        var channelThumbnailUrl: String
        var isMusic: Bool
        var isLive: Bool
        var isShort: Bool
        var timestamp: Double
    }

    /// The cached feed, when there is one.
    struct Cached {
        let feed: VideoHomeFeed
        let savedAt: Date
    }

    private let queue = DispatchQueue(label: "org.flowtube.Flow.homeCache", qos: .utility)
    private let fileURL: URL?

    init() {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
        if let directory = caches {
            fileURL = URL(fileURLWithPath: directory).appendingPathComponent("home-feed.json")
        } else {
            fileURL = nil
        }
    }

    /// Reads the snapshot. Returns nil when it is missing, unreadable or older than a week.
    func load() -> Cached? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        let savedAt = Date(timeIntervalSince1970: snapshot.savedAt)
        if Date().timeIntervalSince(savedAt) > 7 * 24 * 60 * 60 { return nil }
        let sections = snapshot.sections.map { shelf in
            VideoShelf(
                title: shelf.title,
                subtitle: shelf.subtitle,
                items: shelf.items.map(HomeFeedCache.video(from:)),
                moreBrowseId: shelf.moreBrowseId
            )
        }
        return Cached(
            feed: VideoHomeFeed(chips: [], sections: sections, continuation: snapshot.continuation),
            savedAt: savedAt
        )
    }

    /// Writes the feed, replacing the previous snapshot.
    func save(_ feed: VideoHomeFeed) {
        guard let url = fileURL else { return }
        let snapshot = Snapshot(
            sections: feed.sections.map { shelf in
                SnapshotShelf(
                    title: shelf.title,
                    subtitle: shelf.subtitle,
                    moreBrowseId: shelf.moreBrowseId,
                    items: shelf.items.map(HomeFeedCache.snapshot(from:))
                )
            },
            continuation: feed.continuation,
            savedAt: Date().timeIntervalSince1970
        )
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Removes the snapshot, for the storage settings' clear-cache action.
    func clear() {
        guard let url = fileURL else { return }
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func snapshot(from video: Video) -> SnapshotVideo {
        return SnapshotVideo(
            id: video.id,
            title: video.title,
            channelName: video.channelName,
            channelId: video.channelId,
            thumbnailUrl: video.thumbnailUrl,
            duration: video.duration,
            viewCount: video.viewCount,
            uploadDate: video.uploadDate,
            channelThumbnailUrl: video.channelThumbnailUrl,
            isMusic: video.isMusic,
            isLive: video.isLive,
            isShort: video.isShort,
            timestamp: video.timestamp.timeIntervalSince1970
        )
    }

    private static func video(from snapshot: SnapshotVideo) -> Video {
        return Video(
            id: snapshot.id,
            title: snapshot.title,
            channelName: snapshot.channelName,
            channelId: snapshot.channelId,
            thumbnailUrl: snapshot.thumbnailUrl,
            duration: snapshot.duration,
            viewCount: snapshot.viewCount,
            uploadDate: snapshot.uploadDate,
            timestamp: Date(timeIntervalSince1970: snapshot.timestamp),
            channelThumbnailUrl: snapshot.channelThumbnailUrl,
            isMusic: snapshot.isMusic,
            isLive: snapshot.isLive,
            isShort: snapshot.isShort
        )
    }
}
