import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Everything a screen needs to know about playback, in one value.
///
/// Views observe this instead of reaching into `AVPlayer`, which keeps the player's thread-safety
/// rules inside the service and lets the mini player, the watch screen and the lock screen all read
/// the same snapshot.
struct PlaybackSnapshot: Equatable {

    /// The item playing, or nil when nothing is loaded.
    var item: PlaybackQueueItem?
    /// Whether audio is currently advancing.
    var isPlaying: Bool
    /// Whether the player is waiting for data.
    var isBuffering: Bool
    /// The item's duration in seconds, or 0 when unknown (a live stream).
    var duration: TimeInterval
    /// The current position in seconds.
    var position: TimeInterval
    /// The playback speed.
    var rate: Float
    /// The queue's repeat mode.
    var repeatMode: RepeatMode
    /// Whether the queue is shuffled.
    var shuffleEnabled: Bool
    /// The queue's title, when it has one.
    var queueTitle: String?
    /// How many items are queued, including the current one.
    var queueCount: Int
    /// The current item's index in the queue, or -1.
    var queueIndex: Int
    /// The error that stopped playback, if any.
    var error: String?

    static let idle = PlaybackSnapshot(
        item: nil,
        isPlaying: false,
        isBuffering: false,
        duration: 0,
        position: 0,
        rate: 1.0,
        repeatMode: .off,
        shuffleEnabled: false,
        queueTitle: nil,
        queueCount: 0,
        queueIndex: -1,
        error: nil
    )

    /// The fraction played, 0...1.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0.0), 1.0)
    }
}

/// The app's one player.
///
/// `PlaybackService` owns the `AVPlayer`, the queue, the audio session, the lock-screen metadata and
/// the remote commands. Every screen talks to it rather than to AVFoundation directly, which is what
/// makes the mini player survive a tab change and the lock screen controls work while the app is in
/// the background.
///
/// The service is main-thread confined: every public method may be called from anywhere, but the
/// work is hopped to the main queue first, and every callback is delivered there.
final class PlaybackService: NSObject {

    static let shared = PlaybackService()

    // MARK: - Public state

    /// The live snapshot. Observe it for every UI update.
    let state = FlowObservable<PlaybackSnapshot>(.idle)

    /// The queue.
    let queue = Queue()

    /// The player the video layer renders.
    private(set) var player: AVPlayer

    /// The watch page behind the current item, when it was loaded from YouTube.
    private(set) var currentPage: WatchPage?

    /// The SponsorBlock segments for the current video.
    private(set) var sponsorSegments: [SponsorBlockSegment] = []

    /// The caption tracks the current video offers.
    var captionTracks: [CaptionTrack] {
        return currentPage?.captionTracks ?? []
    }

    /// Whether the current item is a live stream.
    private(set) var isLive = false

    /// The audio session, exposed for the equalizer screen's diagnostics.
    let audioSession = AVAudioSession.sharedInstance()

    /// Called on the main queue when the item changes, so the video screen can rebuild its item
    /// observers and reload captions. A screen that may coexist with another player screen uses
    /// `addItemObserver(_:)` instead, so neither replaces the other's callback.
    var onItemChanged: ((PlaybackQueueItem?) -> Void)?

    /// Additional item-change listeners, keyed by token. The video and music screens both register
    /// here; the single `onItemChanged` property remains for the one owner that wants it.
    private var itemObservers: [UUID: (PlaybackQueueItem?) -> Void] = [:]

    /// Called on the main queue when playback reaches the end of the last queued item.
    var onQueueFinished: (() -> Void)?

    /// Called when a SponsorBlock segment is skipped, with the segment that was skipped.
    var onSegmentSkipped: ((SponsorBlockSegment) -> Void)?

    // MARK: - Private state

    private let api: YouTubeAPI
    private let watchService: WatchPageService
    private let history: HistoryStore
    private let prefs: PrefsStore

    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemKeepUpObservation: NSKeyValueObservation?
    private var playerRateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private var loadGeneration = 0
    private var pendingSeek: TimeInterval?
    private var lastHistorySave: Date = Date.distantPast
    private var skippedSegmentIDs: Set<String> = []
    private var wasPlayingBeforeInterruption = false
    private var artworkTask: URLSessionDataTask?
    private var currentArtworkKey: String = ""

    /// How often the position is written to history while playing.
    private static let historySaveInterval: TimeInterval = 10.0

    // MARK: - Init

    private init(
        api: YouTubeAPI = YouTubeAPI(),
        watchService: WatchPageService = .shared,
        history: HistoryStore = .shared,
        prefs: PrefsStore = .shared
    ) {
        self.api = api
        self.watchService = watchService
        self.history = history
        self.prefs = prefs
        player = AVPlayer()
        super.init()
        configurePlayer()
        configureQueue()
        configureAudioSession()
        configureRemoteCommands()
        observeSystemEvents()
        SleepTimer.shared.onExpire = { [weak self] expiry in
            self?.handleSleepTimerExpiry(expiry)
        }
    }

    // MARK: - Setup

    private func configurePlayer() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handleTimeUpdate(time.seconds.isFinite ? time.seconds : 0)
        }
    }

    private func configureQueue() {
        queue.onChange = { [weak self] in
            self?.publishState()
        }
    }

    /// Sets the playback category once, at launch.
    ///
    /// `.playback` keeps audio running with the screen off and the app in the background, which the
    /// `audio` background mode in Info.plist permits. AirPlay and Bluetooth are allowed so the
    /// route picker and car head units work.
    private func configureAudioSession() {
        do {
            try audioSession.setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true)
        } catch {
            // A failed activation is not fatal: the player still works while the app is foregrounded
            // and the next activation attempt (on play) retries.
        }
    }

    private func activateSession() {
        do {
            try audioSession.setActive(true)
        } catch {
            // The system refused activation, usually because another app holds a call. Playback
            // still starts; the interruption handler pauses it if the call takes over.
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }

        foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNowPlaying()
        }
    }

    // MARK: - Loading

    /// Loads a video and starts it.
    ///
    /// The watch page is fetched, the best stream is chosen, the resume position is applied and the
    /// item is installed. A video that is already current is not reloaded; it resumes instead.
    func load(videoId: String, autoplay: Bool = true, completion: ((Result<PlaybackQueueItem, FlowError>) -> Void)? = nil) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            if let current = self.queue.current, current.videoId == videoId, self.player.currentItem != nil {
                if autoplay { self.play() }
                completion?(.success(current))
                return
            }
            self.loadFresh(videoId: videoId, autoplay: autoplay, completion: completion)
        }
    }

    /// Loads a queue of items and starts at `startIndex`.
    func play(
        items: [PlaybackQueueItem],
        startIndex: Int = 0,
        title: String? = nil,
        shuffle: Bool? = nil,
        autoplay: Bool = true
    ) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            guard !items.isEmpty else {
                self.stop()
                return
            }
            self.queue.setItems(items, startIndex: startIndex, title: title, shuffle: shuffle)
            guard let item = self.queue.current else { return }
            self.begin(item: item, autoplay: autoplay, resume: true)
        }
    }

    /// Plays a single video, replacing the queue with it.
    func play(video: Video, autoplay: Bool = true) {
        let item = PlaybackQueueItem(video: video)
        play(items: [item], startIndex: 0, title: nil, autoplay: autoplay)
    }

    /// Plays a song, replacing the queue with it.
    func play(song: SongItem, autoplay: Bool = true) {
        let item = PlaybackQueueItem(song: song)
        play(items: [item], startIndex: 0, title: nil, autoplay: autoplay)
    }

    /// Adds an item to the end of the queue.
    func enqueue(_ item: PlaybackQueueItem) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.queue.append(item)
            if self.player.currentItem == nil {
                self.begin(item: item, autoplay: true, resume: true)
            } else {
                self.publishState()
            }
        }
    }

    /// Inserts an item to play next.
    func playNext(_ item: PlaybackQueueItem) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            if self.player.currentItem == nil {
                self.queue.setItems([item], startIndex: 0, title: nil)
                self.begin(item: item, autoplay: true, resume: true)
            } else {
                self.queue.insertNext(item)
                self.publishState()
            }
        }
    }

    /// Loads the item at a queue index.
    func playQueueItem(at index: Int) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            guard let item = self.queue.jump(to: index) else { return }
            self.begin(item: item, autoplay: true, resume: true)
        }
    }

    /// Removes a queue item, stopping playback when it was the current one and the queue empties.
    func removeQueueItem(at index: Int) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let wasCurrent = index == self.queue.currentIndex
            guard let removed = self.queue.remove(at: index) else { return }
            if self.queue.isEmpty {
                self.stop()
                return
            }
            if wasCurrent, let next = self.queue.current {
                self.begin(item: next, autoplay: self.player.rate > 0, resume: false)
            } else if self.queue.current?.videoId == removed.videoId {
                self.publishState()
            }
        }
    }

    /// Moves an item within the queue.
    func moveQueueItem(from source: Int, to destination: Int) {
        performOnMain { [weak self] in
            self?.queue.move(from: source, to: destination)
        }
    }

    private func loadFresh(
        videoId: String,
        autoplay: Bool,
        completion: ((Result<PlaybackQueueItem, FlowError>) -> Void)?
    ) {
        loadGeneration += 1
        let generation = loadGeneration
        state.mutate { snapshot in
            snapshot.isBuffering = true
            snapshot.error = nil
        }

        watchService.load(videoId: videoId) { [weak self] result in
            guard let self = self else { return }
            guard generation == self.loadGeneration else { return }
            switch result {
            case .failure(let error):
                self.state.mutate { snapshot in
                    snapshot.isBuffering = false
                    snapshot.error = error.displayMessage
                }
                completion?(.failure(error))
            case .success(let model):
                self.currentPage = model.page
                self.sponsorSegments = model.sponsorSegments
                self.skippedSegmentIDs = []
                let item = PlaybackQueueItem(
                    video: model.page.video,
                    isMusic: model.page.video.isMusic,
                    localFileURL: self.localFile(for: videoId)
                )
                self.queue.setItems([item], startIndex: 0, title: nil)
                self.begin(item: item, autoplay: autoplay, resume: true)
                completion?(.success(item))
            }
        }
    }

    /// Starts an item that is already current in the queue.
    private func begin(item: PlaybackQueueItem, autoplay: Bool, resume: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        skippedSegmentIDs = []
        detachItemObservers()

        if item.videoId != currentPage?.video.id {
            currentPage = nil
            sponsorSegments = []
        }
        isLive = currentPage?.isLive ?? false

        state.mutate { snapshot in
            snapshot.item = item
            snapshot.isBuffering = true
            snapshot.error = nil
            snapshot.duration = item.duration
            snapshot.position = 0
            snapshot.queueTitle = self.queue.title
            snapshot.queueCount = self.queue.count
            snapshot.queueIndex = self.queue.currentIndex
            snapshot.repeatMode = self.queue.repeatMode
            snapshot.shuffleEnabled = self.queue.shuffleEnabled
        }
        notifyItemChanged(item)

        if let local = item.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            install(localItem: local, item: item, autoplay: autoplay, resume: resume)
            return
        }

        // A page already loaded for this video (the watch screen fetched it) is reused; otherwise
        // the service fetches it itself.
        if let page = currentPage, page.video.id == item.videoId {
            buildItem(for: page, item: item, autoplay: autoplay, resume: resume, generation: generation)
            return
        }

        watchService.load(videoId: item.videoId) { [weak self] result in
            guard let self = self else { return }
            guard generation == self.loadGeneration else { return }
            switch result {
            case .failure(let error):
                self.state.mutate { snapshot in
                    snapshot.isBuffering = false
                    snapshot.error = error.displayMessage
                }
            case .success(let model):
                self.currentPage = model.page
                self.sponsorSegments = model.sponsorSegments
                self.isLive = model.page.isLive
                self.buildItem(for: model.page, item: item, autoplay: autoplay, resume: resume, generation: generation)
            }
        }
    }

    private func buildItem(
        for page: WatchPage,
        item: PlaybackQueueItem,
        autoplay: Bool,
        resume: Bool,
        generation: Int
    ) {
        let options = PlayerItemFactory.Options(
            quality: prefs.string(for: .playbackQuality) ?? "auto",
            audioLanguage: prefs.string(for: .preferredAudioLanguage),
            localFileURL: item.localFileURL,
            forwardBufferDuration: 0.0,
            automaticallyWaits: true,
            referer: "https://www.youtube.com/watch?v=" + item.videoId
        )
        PlayerItemFactory.makeItem(for: page, options: options) { [weak self] result in
            guard let self = self else { return }
            guard generation == self.loadGeneration else { return }
            switch result {
            case .failure(let error):
                self.state.mutate { snapshot in
                    snapshot.isBuffering = false
                    snapshot.error = error.displayMessage
                }
            case .success(let playerItem):
                self.install(playerItem: playerItem, item: item, autoplay: autoplay, resume: resume)
            }
        }
    }

    private func install(localItem url: URL, item: PlaybackQueueItem, autoplay: Bool, resume: Bool) {
        let playerItem = AVPlayerItem(url: url)
        install(playerItem: playerItem, item: item, autoplay: autoplay, resume: resume)
    }

    private func install(playerItem: AVPlayerItem, item: PlaybackQueueItem, autoplay: Bool, resume: Bool) {
        playerItem.audioMix = AudioEngine.shared.audioMix(for: playerItem)
        player.replaceCurrentItem(with: playerItem)
        observeItem(playerItem)
        attachEndObserver(for: playerItem)

        let start = resume ? startPosition(for: item) : 0.0
        pendingSeek = start > 0 ? start : nil
        if start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: CMTimeScale(NSEC_PER_SEC)), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        state.mutate { snapshot in
            snapshot.item = item
            snapshot.duration = item.duration
            snapshot.position = start
            snapshot.isBuffering = true
        }
        updateNowPlaying()
        if autoplay {
            play()
        } else {
            publishState()
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch observed.status {
                case .readyToPlay:
                    let duration = observed.duration.seconds
                    if duration.isFinite && duration > 0 {
                        self.state.mutate { snapshot in
                            snapshot.duration = duration
                        }
                    }
                    if let seek = self.pendingSeek {
                        self.pendingSeek = nil
                        self.player.seek(
                            to: CMTime(seconds: seek, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    }
                case .failed:
                    let message = observed.error?.localizedDescription ?? "This stream could not be played."
                    self.state.mutate { snapshot in
                        snapshot.isBuffering = false
                        snapshot.error = message
                    }
                default:
                    break
                }
            }
        }
        itemKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.state.mutate { snapshot in
                    snapshot.isBuffering = !observed.isPlaybackLikelyToKeepUp && self.player.rate > 0
                }
            }
        }
        playerRateObservation = player.observe(\.rate, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let playing = observed.rate > 0
                self.state.mutate { snapshot in
                    snapshot.isPlaying = playing
                    snapshot.rate = playing ? observed.rate : snapshot.rate
                }
                self.updateNowPlayingPlaybackState()
            }
        }
    }

    private func detachItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        itemKeepUpObservation?.invalidate()
        itemKeepUpObservation = nil
        playerRateObservation?.invalidate()
        playerRateObservation = nil
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }

    private func attachEndObserver(for item: AVPlayerItem) {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleItemEnded()
        }
    }

    // MARK: - Transport

    /// Starts or resumes playback.
    func play() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            guard self.player.currentItem != nil else {
                if let item = self.queue.current {
                    self.begin(item: item, autoplay: true, resume: true)
                }
                return
            }
            self.activateSession()
            let speed = self.playbackSpeed()
            self.player.playImmediately(atRate: speed)
            self.state.mutate { snapshot in
                snapshot.isPlaying = true
                snapshot.rate = speed
                snapshot.error = nil
            }
            self.updateNowPlayingPlaybackState()
        }
    }

    /// Pauses playback and saves the position.
    func pause() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.player.pause()
            self.state.mutate { snapshot in
                snapshot.isPlaying = false
            }
            self.saveHistory(force: true)
            self.updateNowPlayingPlaybackState()
        }
    }

    /// Toggles between playing and paused.
    func togglePlayPause() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            if self.player.rate > 0 {
                self.pause()
            } else {
                self.play()
            }
        }
    }

    /// Stops playback and clears the player, keeping the queue.
    func stop() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.saveHistory(force: true)
            self.player.pause()
            self.player.replaceCurrentItem(with: nil)
            self.detachItemObservers()
            self.currentPage = nil
            self.sponsorSegments = []
            self.queue.clear()
            self.state.set(.idle)
            self.clearNowPlaying()
            self.notifyItemChanged(nil)
        }
    }

    /// Registers an item-change listener. The token removes it when released.
    @discardableResult
    func addItemObserver(_ handler: @escaping (PlaybackQueueItem?) -> Void) -> ObservationToken {
        let identifier = UUID()
        itemObservers[identifier] = handler
        return ObservationToken { [weak self] in
            self?.itemObservers.removeValue(forKey: identifier)
        }
    }

    /// Fans an item change out to the single owner and to every registered listener.
    private func notifyItemChanged(_ item: PlaybackQueueItem?) {
        onItemChanged?(item)
        for handler in Array(itemObservers.values) {
            handler(item)
        }
    }

    /// Seeks to a position.
    func seek(to seconds: TimeInterval) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let duration = self.player.currentItem?.duration.seconds ?? 0
            var target = max(seconds, 0.0)
            if duration.isFinite && duration > 0 {
                target = min(target, max(duration - 0.25, 0.0))
            }
            self.player.seek(
                to: CMTime(seconds: target, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            self.state.mutate { snapshot in
                snapshot.position = target
            }
            self.updateNowPlayingElapsed()
        }
    }

    /// Seeks by a delta, used by the double-tap and the remote skip commands.
    func skip(by seconds: TimeInterval) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let current = self.player.currentTime().seconds
            self.seek(to: (current.isFinite ? current : 0) + seconds)
        }
    }

    /// Advances to the next queue item, or stops at the end.
    func playNext() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            guard let next = self.queue.advance(manual: true) else {
                self.player.pause()
                self.state.mutate { snapshot in
                    snapshot.isPlaying = false
                }
                return
            }
            self.begin(item: next, autoplay: true, resume: true)
        }
    }

    /// Goes back one queue item, or restarts the current one at the start.
    func playPrevious() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let position = self.player.currentTime().seconds
            if position.isFinite && position > 3.0 {
                self.seek(to: 0)
                return
            }
            guard let previous = self.queue.rewind() else {
                self.seek(to: 0)
                return
            }
            self.begin(item: previous, autoplay: true, resume: true)
        }
    }

    // MARK: - Modes

    /// Sets the playback speed. Pausing keeps the speed for the next play.
    func setPlaybackSpeed(_ speed: Double) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let clamped = Float(min(max(speed, 0.25), 2.0))
            self.state.mutate { snapshot in
                snapshot.rate = clamped
            }
            if self.player.rate > 0 {
                self.player.rate = clamped
            }
            self.prefs.playbackSpeed = Double(clamped)
            self.updateNowPlayingPlaybackState()
        }
    }

    /// The speed playback should use: the remembered speed, except for music, which stays at 1×
    /// unless the viewer explicitly changed it for the track.
    private func playbackSpeed() -> Float {
        let stored = Float(prefs.playbackSpeed)
        if queue.current?.isMusic == true && stored == 1.0 {
            return 1.0
        }
        return min(max(stored, 0.25), 2.0)
    }

    /// Turns shuffle on or off, keeping the current track playing.
    func setShuffle(_ enabled: Bool) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.queue.setShuffle(enabled)
            self.state.mutate { snapshot in
                snapshot.shuffleEnabled = enabled
                snapshot.queueIndex = self.queue.currentIndex
            }
        }
    }

    /// Sets the repeat mode.
    func setRepeatMode(_ mode: RepeatMode) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.queue.setRepeatMode(mode)
            self.state.mutate { snapshot in
                snapshot.repeatMode = mode
            }
        }
    }

    /// Cycles the repeat mode off → all → one → off.
    func cycleRepeatMode() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.queue.cycleRepeatMode()
            self.state.mutate { snapshot in
                snapshot.repeatMode = self.queue.repeatMode
            }
        }
    }

    /// Switches quality, keeping the position and the play state.
    func setQuality(_ quality: String) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.prefs.set(quality, for: .playbackQuality)
            guard let page = self.currentPage, let item = self.queue.current else { return }
            let position = self.player.currentTime().seconds
            let wasPlaying = self.player.rate > 0
            self.buildItem(for: page, item: item, autoplay: wasPlaying, resume: false, generation: self.loadGeneration)
            if position.isFinite && position > 0 {
                self.pendingSeek = position
            }
        }
    }

    /// Re-applies the equalizer to the current item.
    func refreshEqualizer() {
        performOnMain { [weak self] in
            guard let self = self, let item = self.player.currentItem else { return }
            item.audioMix = AudioEngine.shared.audioMix(for: item)
        }
    }

    // MARK: - Sleep timer

    /// Starts the sleep timer.
    func startSleepTimer(minutes: Int, closesApp: Bool = false) {
        SleepTimer.shared.start(minutes: minutes, closesApp: closesApp)
        prefs.set(minutes, for: .sleepTimerMinutes)
    }

    /// Arms the sleep timer for the end of the current item.
    func startSleepTimerAtEndOfItem(closesApp: Bool = false) {
        SleepTimer.shared.startEndOfMedia(closesApp: closesApp)
    }

    /// Cancels the sleep timer.
    func cancelSleepTimer() {
        SleepTimer.shared.cancel()
    }

    private func handleSleepTimerExpiry(_ expiry: SleepTimer.Expiry) {
        pause()
        switch expiry {
        case .minutes:
            FlowSnackbar.show("Sleep timer ended")
        case .endOfMedia:
            FlowSnackbar.show("Sleep timer ended at the end of the item")
        }
    }

    // MARK: - Time and history

    private func handleTimeUpdate(_ seconds: TimeInterval) {
        guard player.currentItem != nil else { return }
        state.mutate { snapshot in
            snapshot.position = seconds
            if !snapshot.isPlaying && self.player.rate > 0 {
                snapshot.isPlaying = true
            }
        }
        updateNowPlayingElapsed()
        applySponsorBlock(at: seconds)
        saveHistory(force: false)
    }

    /// Skips a SponsorBlock segment the moment playback enters it.
    private func applySponsorBlock(at time: TimeInterval) {
        guard prefs.bool(for: .sponsorBlockEnabled, fallback: true),
              prefs.bool(for: .sponsorBlockAutoSkip, fallback: true) else { return }
        let enabledCategories = Set(prefs.sponsorBlockCategories)
        let position = Float(time)
        for segment in sponsorSegments {
            guard enabledCategories.contains(segment.category) else { continue }
            guard !segment.isFullVideo else { continue }
            guard segment.actionType == "skip" else { continue }
            guard segment.contains(position) else { continue }
            guard !skippedSegmentIDs.contains(segment.uuid) else { continue }
            skippedSegmentIDs.insert(segment.uuid)
            let target = TimeInterval(segment.endTime) + 0.05
            seek(to: target)
            onSegmentSkipped?(segment)
            if prefs.bool(for: .sponsorBlockNotifyOnSkip, fallback: true) {
                FlowSnackbar.show("Skipped " + segment.displayName.lowercased())
            }
            break
        }
    }

    /// The position playback should start from, honouring the resume preference and the policy that
    /// restarts an almost-finished video.
    private func startPosition(for item: PlaybackQueueItem) -> TimeInterval {
        guard prefs.bool(for: .resumePlayback, fallback: true) else { return 0 }
        guard let saved = history.resumePosition(for: item.videoId) else { return 0 }
        let duration = item.duration
        if duration > 0 {
            let remaining = duration - saved
            if remaining <= 1.5 || saved >= duration * 0.98 {
                return 0
            }
        } else if saved > 4 * 60 * 60 {
            return 0
        }
        return saved
    }

    private func saveHistory(force: Bool) {
        guard let item = queue.current else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastHistorySave) < PlaybackService.historySaveInterval {
            return
        }
        lastHistorySave = now
        let position = player.currentTime().seconds
        guard position.isFinite, position > 0 else { return }
        let duration = player.currentItem?.duration.seconds ?? item.duration
        if item.isMusic {
            history.updatePosition(videoId: item.videoId, position: position, duration: duration)
        } else {
            history.record(
                videoId: item.videoId,
                title: item.title,
                channelId: item.channelId,
                channelName: item.channelName,
                thumbnailUrl: item.thumbnailUrl,
                duration: duration,
                position: position,
                isMusic: false
            )
        }
    }

    private func handleItemEnded() {
        SleepTimer.shared.mediaDidEnd()
        if SleepTimer.shared.isActive {
            // The timer pauses at the end of the item; do not advance.
            pause()
            return
        }
        saveHistory(force: true)
        if let next = queue.advance(manual: false) {
            begin(item: next, autoplay: true, resume: false)
            return
        }
        state.mutate { snapshot in
            snapshot.isPlaying = false
            snapshot.position = snapshot.duration
        }
        updateNowPlayingPlaybackState()
        onQueueFinished?()
    }

    // MARK: - Interruptions and routes

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = player.rate > 0
            player.pause()
            state.mutate { snapshot in
                snapshot.isPlaying = false
            }
            updateNowPlayingPlaybackState()
        case .ended:
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
                play()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones were unplugged: pause, the way every other player does, so the room does
            // not suddenly hear what was private.
            if player.rate > 0 {
                pause()
            }
        case .newDeviceAvailable:
            updateNowPlaying()
        default:
            break
        }
    }

    // MARK: - Now playing

    private func updateNowPlaying() {
        guard let item = queue.current else {
            clearNowPlaying()
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.channelName,
            MPMediaItemPropertyPlaybackDuration: item.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = item.albumName, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(for: item)
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            updateNowPlaying()
            return
        }
        let position = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.isFinite ? position : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let position = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.isFinite ? position : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlaying() {
        if queue.current != nil {
            updateNowPlaying()
        }
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artworkTask?.cancel()
        artworkTask = nil
        currentArtworkKey = ""
    }

    /// Loads the thumbnail and hands it to the lock screen.
    ///
    /// The lock screen keeps the artwork it was given, so a new image is only fetched when the track
    /// changes; re-sending the same picture on every position update would be wasted work.
    private func loadArtwork(for item: PlaybackQueueItem) {
        let key = item.thumbnailUrl
        guard key != currentArtworkKey else { return }
        currentArtworkKey = key
        guard !key.isEmpty, let url = URL(string: key) else { return }
        artworkTask?.cancel()
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self.currentArtworkKey == key else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
        artworkTask = task
        task.resume()
    }

    // MARK: - Remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: positionEvent.positionTime)
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: 10)]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.skip(by: interval)
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 10)]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.skip(by: -interval)
            return .success
        }
    }

    // MARK: - Helpers

    private func publishState() {
        state.mutate { snapshot in
            snapshot.item = self.queue.current
            snapshot.queueTitle = self.queue.title
            snapshot.queueCount = self.queue.count
            snapshot.queueIndex = self.queue.currentIndex
            snapshot.repeatMode = self.queue.repeatMode
            snapshot.shuffleEnabled = self.queue.shuffleEnabled
            snapshot.isPlaying = self.player.rate > 0
        }
    }

    private func localFile(for videoId: String) -> URL? {
        guard let record = DownloadStore.shared.record(videoId: videoId), record.state == .completed else {
            return nil
        }
        return record.fileURL
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// The position the current item is at, for a screen that just appeared.
    var currentPosition: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    /// The current item's duration, read from the player when it knows better than the queue.
    var currentDuration: TimeInterval {
        let seconds = player.currentItem?.duration.seconds ?? 0
        if seconds.isFinite && seconds > 0 { return seconds }
        return queue.current?.duration ?? 0
    }
}
