import AVFoundation
import Foundation

/// Where a Shorts reel's videos come from.
enum ShortsSource {
    /// The recommended Shorts, taken from the home feed.
    case feed
    /// A fixed list, e.g. the Shorts of one channel or the ones the viewer saved.
    case seeded([Video])
    /// Everything the viewer saved, newest first.
    case saved
    /// One channel's Shorts tab.
    case channel(String)
    /// A single Short opened from a link or a related row.
    case single(Video)
}

/// The Shorts reel's state: the queue, the current position, the per-video reactions and the
/// resolved playback items.
///
/// Playback items are resolved lazily and cached, because opening a Short costs a player request
/// and the reel must not stall the swipe. The controller asks for the item of the cell it is about
/// to show; the view model hands back a cached one or starts the request.
final class ShortsViewModel {

    /// The reel's queue, in order.
    private(set) var videos: [Video] = []
    /// The index the viewer is on.
    private(set) var currentIndex = 0
    /// Whether the first page is still loading.
    private(set) var isLoading = false
    /// The message to show when the reel could not load at all.
    private(set) var errorMessage: String?

    /// Called when `videos`, `currentIndex` or the loading state changes.
    var onChange: (() -> Void)?
    /// Called when a Short is liked or unliked, so the cell can animate.
    var onLikeChanged: ((String, Bool) -> Void)?

    private let source: ShortsSource
    private let api: YouTubeAPI
    private let savedShorts: SavedShortsStore
    private let history: HistoryStore

    private var likes: Set<String> = []
    private var dislikes: Set<String> = []
    private var items: [String: AVPlayerItem] = [:]
    private var resolving: Set<String> = []
    private var itemWaiters: [String: [(AVPlayerItem?) -> Void]] = [:]
    private var continuation: String?
    private var isLoadingMore = false

    init(
        source: ShortsSource,
        api: YouTubeAPI = YouTubeAPI(),
        savedShorts: SavedShortsStore = .shared,
        history: HistoryStore = .shared
    ) {
        self.source = source
        self.api = api
        self.savedShorts = savedShorts
        self.history = history
    }

    // MARK: - Loading

    /// Loads the reel's first page.
    func load() {
        if case .seeded(let seeded) = source {
            videos = seeded
            isLoading = false
            onChange?()
            return
        }
        if case .single(let video) = source {
            videos = [video]
            isLoading = false
            onChange?()
            return
        }
        if case .saved = source {
            videos = savedShorts.all().map { entry in
                Video(
                    id: entry.videoId,
                    title: entry.title,
                    channelName: entry.channelName,
                    thumbnailUrl: entry.thumbnailUrl,
                    isShort: true
                )
            }
            isLoading = false
            onChange?()
            return
        }

        isLoading = true
        errorMessage = nil
        onChange?()

        switch source {
        case .channel(let channelId):
            api.channelTab(id: channelId, params: ShortsViewModel.shortsTabParams) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isLoading = false
                    switch result {
                    case .success(let page):
                        self.videos = page.shorts
                        self.continuation = page.shortsContinuation
                        if self.videos.isEmpty {
                            self.errorMessage = nil
                        }
                    case .failure(let error):
                        self.errorMessage = error.displayMessage
                    }
                    self.onChange?()
                }
            }
        case .feed, .seeded, .saved, .single:
            api.home { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isLoading = false
                    switch result {
                    case .success(let feed):
                        self.videos = ShortsViewModel.shorts(from: feed)
                        self.continuation = feed.continuation
                    case .failure(let error):
                        self.errorMessage = error.displayMessage
                    }
                    self.onChange?()
                }
            }
        }
    }

    /// Loads more Shorts when the reel nears its end.
    func loadMoreIfNeeded(index: Int) {
        guard index >= videos.count - 3, !isLoadingMore else { return }
        guard let token = continuation, !token.isEmpty else { return }
        if case .channel = source {
            // The channel's Shorts tab pages through its own continuation; the facade exposes the
            // main-site continuation only, so a channel reel stops at the first page rather than
            // requesting the wrong feed.
            return
        }
        isLoadingMore = true
        api.homeContinuation(token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoadingMore = false
                guard case .success(let page) = result else { return }
                let more = ShortsViewModel.shorts(from: page)
                var known = Set(self.videos.map { $0.id })
                for video in more where !known.contains(video.id) {
                    self.videos.append(video)
                    known.insert(video.id)
                }
                self.continuation = page.continuation
                self.onChange?()
            }
        }
    }

    /// Records that the viewer reached `index`, so the history row can resume there later.
    func markCurrent(index: Int) {
        guard index != currentIndex else { return }
        currentIndex = index
        loadMoreIfNeeded(index: index)
        onChange?()
    }

    // MARK: - Playback items

    /// The playback item for a Short, resolving it if this is the first time.
    ///
    /// The completion is called on the main queue with nil when the video has no playable stream.
    func playerItem(for video: Video, completion: @escaping (AVPlayerItem?) -> Void) {
        if let cached = items[video.id] {
            completion(cached)
            return
        }
        if itemWaiters[video.id] != nil {
            itemWaiters[video.id]?.append(completion)
            return
        }
        itemWaiters[video.id] = [completion]
        resolving.insert(video.id)

        api.player(videoId: video.id) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                var resolved: AVPlayerItem?
                if case .success(let player) = result {
                    resolved = ShortsViewModel.makeItem(from: player)
                }
                self.resolving.remove(video.id)
                if let item = resolved {
                    self.items[video.id] = item
                }
                let waiters = self.itemWaiters.removeValue(forKey: video.id) ?? []
                for waiter in waiters {
                    waiter(resolved)
                }
            }
        }
    }

    /// Drops a cached item, e.g. when playback failed and the stream should be fetched again.
    func invalidateItem(for videoId: String) {
        items.removeValue(forKey: videoId)
    }

    /// Prefetches the items for the next `count` Shorts, so a swipe is instant.
    func prefetchItems(from index: Int, count: Int = 2) {
        let end = min(index + count, videos.count - 1)
        guard index < end else { return }
        for position in (index + 1)...end {
            guard let video = videos.element(at: position) else { continue }
            guard items[video.id] == nil, !resolving.contains(video.id) else { continue }
            playerItem(for: video) { _ in }
        }
    }

    // MARK: - Reactions

    /// Whether the viewer liked this Short.
    func isLiked(_ videoId: String) -> Bool {
        return likes.contains(videoId)
    }

    /// Whether the viewer disliked this Short.
    func isDisliked(_ videoId: String) -> Bool {
        return dislikes.contains(videoId)
    }

    /// Whether the Short is in the saved list.
    func isSaved(_ videoId: String) -> Bool {
        return savedShorts.contains(videoId: videoId)
    }

    /// Toggles the like. Returns the new state.
    @discardableResult
    func toggleLike(_ video: Video) -> Bool {
        let liked: Bool
        if likes.contains(video.id) {
            likes.remove(video.id)
            liked = false
        } else {
            likes.insert(video.id)
            dislikes.remove(video.id)
            liked = true
        }
        onLikeChanged?(video.id, liked)
        return liked
    }

    /// Toggles the dislike. Returns the new state.
    @discardableResult
    func toggleDislike(_ video: Video) -> Bool {
        let disliked: Bool
        if dislikes.contains(video.id) {
            dislikes.remove(video.id)
            disliked = false
        } else {
            dislikes.insert(video.id)
            likes.remove(video.id)
            disliked = true
        }
        return disliked
    }

    /// Toggles the Short in the saved list. Returns the new state.
    @discardableResult
    func toggleSave(_ video: Video) -> Bool {
        let saved = savedShorts.toggle(
            videoId: video.id,
            title: video.title,
            channelName: video.channelName,
            thumbnailUrl: video.thumbnailUrl
        )
        if case .saved = source {
            // Removing from the saved reel removes the page, so the reel does not keep showing a
            // Short the viewer just unsaved.
            if !saved {
                videos.removeAll { $0.id == video.id }
                if currentIndex >= videos.count {
                    currentIndex = max(0, videos.count - 1)
                }
                onChange?()
            }
        }
        return saved
    }

    /// Records the Short in the history table so it can be resumed.
    func recordView(_ video: Video, position: TimeInterval, duration: TimeInterval) {
        history.record(
            videoId: video.id,
            title: video.title,
            channelId: video.channelId,
            channelName: video.channelName,
            thumbnailUrl: video.thumbnailUrl,
            duration: duration,
            position: position,
            isMusic: video.isMusic
        )
    }

    // MARK: - Building playback

    /// Turns a player response into an `AVPlayerItem`, preferring HLS.
    ///
    /// HLS is what YouTube serves for Shorts and what AVPlayer handles best; a progressive stream
    /// is the fallback when no manifest was offered. Adaptive-only responses cannot be played by a
    /// single `AVPlayerItem` without composing them, and Shorts are always served with at least one
    /// of the first two, so those are the only cases handled here.
    static func makeItem(from player: PlayerParser.Result) -> AVPlayerItem? {
        if let manifest = player.hlsManifestUrl, let url = URL(string: manifest) {
            let asset = AVURLAsset(url: url, options: ShortsViewModel.assetOptions)
            return AVPlayerItem(asset: asset)
        }
        let progressive = player.formats.filter { $0.isProgressive && $0.url != nil }
        if let best = progressive.max(by: { $0.bitrate < $1.bitrate }),
           let text = best.url, let url = URL(string: text) {
            let asset = AVURLAsset(url: url, options: ShortsViewModel.assetOptions)
            return AVPlayerItem(asset: asset)
        }
        let anyFormat = player.formats.first { $0.url != nil }
        if let text = anyFormat?.url, let url = URL(string: text) {
            let asset = AVURLAsset(url: url, options: ShortsViewModel.assetOptions)
            return AVPlayerItem(asset: asset)
        }
        return nil
    }

    /// The headers YouTube's media servers require. Without the referer the CDN answers 403.
    static var assetOptions: [String: Any] {
        return [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "Referer": "https://www.youtube.com/",
                "Origin": "https://www.youtube.com",
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1",
            ],
        ]
    }

    /// The `params` value that opens a channel's Shorts tab.
    static let shortsTabParams = "EgZzaG9ydHPyBgUKA5oBAA%3D%3D"

    /// The Shorts in a home feed: the flagged ones first, then anything from a Shorts shelf.
    static func shorts(from feed: VideoHomeFeed) -> [Video] {
        var result: [Video] = []
        var seen = Set<String>()
        for section in feed.sections {
            let title = section.title.lowercased()
            let isShortsShelf = title.contains("short")
            for video in section.items {
                guard video.isShort || isShortsShelf else { continue }
                if seen.contains(video.id) { continue }
                seen.insert(video.id)
                result.append(video)
            }
        }
        if result.isEmpty {
            for section in feed.sections {
                for video in section.items where !seen.contains(video.id) {
                    seen.insert(video.id)
                    result.append(video)
                }
            }
        }
        return result
    }
}
