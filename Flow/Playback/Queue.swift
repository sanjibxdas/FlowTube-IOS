import Foundation

/// One entry in the playback queue.
///
/// A queue holds videos and songs alike, so the item carries the metadata the mini player, the
/// queue sheet and the now-playing panel need without a second lookup. `localFileURL` is set when
/// the entry has a finished download, which lets playback continue with no network at all.
struct PlaybackQueueItem: Equatable {

    let videoId: String
    var title: String
    var channelName: String
    var channelId: String
    var thumbnailUrl: String
    var duration: TimeInterval
    var isMusic: Bool
    var albumName: String?
    /// The downloaded file, when this entry can be played offline.
    var localFileURL: URL?

    init(
        videoId: String,
        title: String,
        channelName: String = "",
        channelId: String = "",
        thumbnailUrl: String = "",
        duration: TimeInterval = 0,
        isMusic: Bool = false,
        albumName: String? = nil,
        localFileURL: URL? = nil
    ) {
        self.videoId = videoId
        self.title = title
        self.channelName = channelName
        self.channelId = channelId
        self.thumbnailUrl = thumbnailUrl
        self.duration = duration
        self.isMusic = isMusic
        self.albumName = albumName
        self.localFileURL = localFileURL
    }

    /// A queue entry for a video.
    init(video: Video, isMusic: Bool = false, albumName: String? = nil, localFileURL: URL? = nil) {
        self.init(
            videoId: video.id,
            title: video.title,
            channelName: video.channelName,
            channelId: video.channelId,
            thumbnailUrl: video.thumbnailUrl,
            duration: TimeInterval(video.duration),
            isMusic: isMusic || video.isMusic,
            albumName: albumName,
            localFileURL: localFileURL
        )
    }

    /// A queue entry for a music track.
    init(song: SongItem, albumName: String? = nil, localFileURL: URL? = nil) {
        self.init(
            videoId: song.id,
            title: song.title,
            channelName: song.artistLine,
            channelId: song.artists.first?.id ?? "",
            thumbnailUrl: song.thumbnailUrl,
            duration: TimeInterval(song.duration ?? 0),
            isMusic: true,
            albumName: albumName ?? song.albumName,
            localFileURL: localFileURL
        )
    }

    /// The plain video this entry describes, for history and related lookups.
    var video: Video {
        return Video(
            id: videoId,
            title: title,
            channelName: channelName,
            channelId: channelId,
            thumbnailUrl: thumbnailUrl,
            duration: Int(duration.rounded()),
            isMusic: isMusic
        )
    }

    /// Two entries are the same track when they are the same video.
    static func == (lhs: PlaybackQueueItem, rhs: PlaybackQueueItem) -> Bool {
        return lhs.videoId == rhs.videoId
    }
}

/// How the queue behaves when an item ends.
enum RepeatMode: String {
    case off
    case all
    case one

    var displayName: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    /// The mode after tapping the repeat button once more.
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    static func fromStored(_ raw: String?) -> RepeatMode {
        guard let raw = raw else { return .off }
        return RepeatMode(rawValue: raw) ?? .off
    }
}

/// The playback queue: its order, the current position, shuffle and repeat.
///
/// The queue never touches a player. It reports what changed through `onChange` and leaves
/// starting, stopping and reloading to `PlaybackService`, so the ordering rules can be reasoned
/// about on their own.
final class Queue {

    /// The items in the order they will play.
    private(set) var items: [PlaybackQueueItem] = []

    /// The order before shuffle was turned on, kept so shuffle can be turned back off.
    private(set) var originalItems: [PlaybackQueueItem] = []

    /// The index of the item that is playing, or -1 when the queue is empty.
    private(set) var currentIndex: Int = -1

    /// What the queue was started from — a playlist name, an album, "Up next".
    private(set) var title: String?

    /// What happens at the end of an item.
    private(set) var repeatMode: RepeatMode = .off

    /// Whether the order is shuffled.
    private(set) var shuffleEnabled = false

    /// Called on the main queue after every mutation.
    var onChange: (() -> Void)?

    // MARK: - Reading

    var isEmpty: Bool {
        return items.isEmpty
    }

    var count: Int {
        return items.count
    }

    var current: PlaybackQueueItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    var hasNext: Bool {
        return nextIndex(manual: false) != nil
    }

    var hasPrevious: Bool {
        return previousIndex() != nil
    }

    func item(at index: Int) -> PlaybackQueueItem? {
        return items.element(at: index)
    }

    func index(of videoId: String) -> Int? {
        return items.firstIndex { $0.videoId == videoId }
    }

    /// The index an advance would land on, or nil when playback should stop.
    func nextIndex(manual: Bool) -> Int? {
        guard !items.isEmpty else { return nil }
        if !manual && repeatMode == .one { return currentIndex }
        if currentIndex + 1 < items.count { return currentIndex + 1 }
        if repeatMode == .all { return 0 }
        return nil
    }

    /// The index a rewind would land on, or nil at the start of a non-looping queue.
    func previousIndex() -> Int? {
        guard !items.isEmpty else { return nil }
        if currentIndex > 0 { return currentIndex - 1 }
        if repeatMode == .all { return items.count - 1 }
        return nil
    }

    // MARK: - Replacing

    /// Replaces the queue and picks the starting item.
    ///
    /// When shuffle is on, the chosen item stays first and the rest are shuffled behind it, which is
    /// what a viewer expects when they start a shuffled playlist from track five.
    func setItems(
        _ newItems: [PlaybackQueueItem],
        startIndex: Int,
        title: String?,
        shuffle: Bool? = nil
    ) {
        if let shuffle = shuffle {
            shuffleEnabled = shuffle
        }
        originalItems = newItems
        self.title = title
        guard !newItems.isEmpty else {
            items = []
            currentIndex = -1
            notify()
            return
        }
        let start = min(max(startIndex, 0), newItems.count - 1)
        if shuffleEnabled && newItems.count > 1 {
            var rest = newItems
            let chosen = rest.remove(at: start)
            rest.shuffle()
            items = [chosen] + rest
            currentIndex = 0
        } else {
            items = newItems
            currentIndex = start
        }
        notify()
    }

    /// Empties the queue.
    func clear() {
        items = []
        originalItems = []
        currentIndex = -1
        title = nil
        repeatMode = .off
        shuffleEnabled = false
        notify()
    }

    // MARK: - Moving

    /// Moves the current position to `index`.
    @discardableResult
    func jump(to index: Int) -> PlaybackQueueItem? {
        guard index >= 0, index < items.count else { return nil }
        currentIndex = index
        notify()
        return current
    }

    /// Advances to the next item. A manual advance ignores repeat-one, because the viewer asked.
    @discardableResult
    func advance(manual: Bool = false) -> PlaybackQueueItem? {
        guard let index = nextIndex(manual: manual) else { return nil }
        currentIndex = index
        notify()
        return current
    }

    /// Goes back one item.
    @discardableResult
    func rewind() -> PlaybackQueueItem? {
        guard let index = previousIndex() else { return nil }
        currentIndex = index
        notify()
        return current
    }

    // MARK: - Editing

    /// Appends an item. An empty queue adopts it as the current item.
    @discardableResult
    func append(_ item: PlaybackQueueItem) -> Int {
        items.append(item)
        originalItems.append(item)
        if currentIndex < 0 {
            currentIndex = 0
        }
        notify()
        return items.count - 1
    }

    /// Appends several items at once.
    func append(contentsOf newItems: [PlaybackQueueItem]) {
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        originalItems.append(contentsOf: newItems)
        if currentIndex < 0 {
            currentIndex = 0
        }
        notify()
    }

    /// Inserts an item directly after the current one — "Play next".
    @discardableResult
    func insertNext(_ item: PlaybackQueueItem) -> Int {
        guard !items.isEmpty, currentIndex >= 0 else {
            return append(item)
        }
        let index = min(currentIndex + 1, items.count)
        items.insert(item, at: index)
        if let originalCurrent = current,
           let originalIndex = originalItems.firstIndex(where: { $0.videoId == originalCurrent.videoId }) {
            originalItems.insert(item, at: min(originalIndex + 1, originalItems.count))
        } else {
            originalItems.append(item)
        }
        notify()
        return index
    }

    /// Removes the item at `index` and returns it.
    ///
    /// When the removed item was playing, the position stays put so the next item slides into its
    /// place; the caller decides whether that item should start.
    @discardableResult
    func remove(at index: Int) -> PlaybackQueueItem? {
        guard index >= 0, index < items.count else { return nil }
        let removed = items.remove(at: index)
        originalItems.removeAll { $0.videoId == removed.videoId }
        if items.isEmpty {
            currentIndex = -1
        } else if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(index, items.count - 1)
        }
        notify()
        return removed
    }

    /// Moves an item within the queue.
    func move(from source: Int, to destination: Int) {
        guard source >= 0, source < items.count,
              destination >= 0, destination < items.count,
              source != destination else { return }
        let moved = items.remove(at: source)
        items.insert(moved, at: destination)
        if currentIndex == source {
            currentIndex = destination
        } else if source < currentIndex && destination >= currentIndex {
            currentIndex -= 1
        } else if source > currentIndex && destination <= currentIndex {
            currentIndex += 1
        }
        notify()
    }

    // MARK: - Modes

    /// Turns shuffle on or off, keeping the current track playing.
    func setShuffle(_ enabled: Bool) {
        guard enabled != shuffleEnabled else { return }
        let playing = current
        shuffleEnabled = enabled
        if enabled {
            guard let playing = playing, items.count > 1 else {
                notify()
                return
            }
            var rest = items
            if let index = rest.firstIndex(where: { $0.videoId == playing.videoId }) {
                rest.remove(at: index)
            }
            rest.shuffle()
            items = [playing] + rest
            currentIndex = 0
        } else {
            items = originalItems
            if let playing = playing, let index = items.firstIndex(where: { $0.videoId == playing.videoId }) {
                currentIndex = index
            } else {
                currentIndex = min(max(currentIndex, 0), max(items.count - 1, 0))
            }
        }
        notify()
    }

    /// Sets the repeat mode.
    func setRepeatMode(_ mode: RepeatMode) {
        guard mode != repeatMode else { return }
        repeatMode = mode
        notify()
    }

    /// Cycles off → all → one → off.
    func cycleRepeatMode() {
        setRepeatMode(repeatMode.next)
    }

    /// Restores a persisted mode without notifying, for launch.
    func restoreModes(repeatMode: RepeatMode, shuffle: Bool) {
        self.repeatMode = repeatMode
        shuffleEnabled = shuffle
    }

    private func notify() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onChange?()
            }
        }
    }
}
