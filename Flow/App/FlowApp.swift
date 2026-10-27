import Foundation
import UIKit

/// The app's service container. One instance lives for the process; every screen reaches the
/// network, the stores and the theme through `FlowApp.shared` rather than building its own.
///
/// This is the iOS counterpart of Android's `FlowApplication`: it owns the singletons that Hilt
/// would inject there. `bootstrap()` is the one place that opens the database, restores the saved
/// preferences and starts playback, so the order is visible in a single function.
final class FlowApp {

    static let shared = FlowApp()

    // MARK: - Services

    /// The YouTube facade. Screens never touch `InnerTubeClient` directly.
    let youtubeAPI: YouTubeAPI

    let historyStore: HistoryStore
    let subscriptionStore: SubscriptionStore
    let playlistStore: PlaylistStore
    let downloadStore: DownloadStore
    let noteStore: NoteStore

    let prefs: PrefsStore
    let imageLoader: ImageLoader
    let theme: FlowTheme

    /// The audio/video engine. Declared here so the app shell can persist and restore a position
    /// without reaching into the playback layer's own singletons.
    let playback: PlaybackService

    /// Whether `bootstrap()` has run. The launch screen waits on this before handing the window to
    /// the tab bar, so the first screen is drawn in the right theme and with open stores.
    private(set) var isBootstrapped = false

    // MARK: - Construction

    private init() {
        // The stores are process-wide singletons because they are read from several tabs at once
        // and each opens the shared `FlowDB`. Taking the shared instances here keeps one cache,
        // not one per owner.
        prefs = PrefsStore.shared
        theme = FlowTheme.shared
        imageLoader = ImageLoader.shared
        historyStore = HistoryStore.shared
        subscriptionStore = SubscriptionStore.shared
        playlistStore = PlaylistStore.shared
        downloadStore = DownloadStore.shared
        noteStore = NoteStore.shared
        youtubeAPI = YouTubeAPI()
        playback = PlaybackService.shared
    }

    // MARK: - Startup

    /// Opens the database, restores the persisted identity and theme, and prepares playback.
    ///
    /// Safe to call more than once: the second call returns immediately. It runs on the main
    /// thread because `FlowTheme.restore` reads `UITraitCollection.current` and the launch screen
    /// swaps the window as soon as it returns.
    func bootstrap() {
        guard !isBootstrapped else { return }
        isBootstrapped = true

        // Touching the shared database opens it and runs the schema migration. Every store built
        // above already points at this handle.
        _ = FlowDB.shared

        prefs.recordLaunch()
        restoreNetworkIdentity()
        theme.restore(from: prefs)
        startPlaybackService()
    }

    /// Prepares the player without opening an audio session: the equalizer the viewer configured is
    /// attached to the next item, and the stored speed is applied when playback starts. The
    /// `AVAudioSession` is activated on the first play, not at launch, so opening the app does not
    /// interrupt whatever else is playing.
    private func startPlaybackService() {
        playback.refreshEqualizer()
    }

    // MARK: - Network identity

    /// Restores the visitor data, cookie and content locale the last session ended with, and wires
    /// the client so a refreshed visitor identity is written straight back to the preferences.
    ///
    /// YouTube issues a new visitor id when it dislikes one; losing it would make every request
    /// look like a brand-new viewer and reset the home feed.
    private func restoreNetworkIdentity() {
        let client = youtubeAPI.client
        client.onVisitorDataChanged = { [weak self] value in
            guard let self = self else { return }
            self.prefs.set(value, for: PrefsStore.Key.visitorData)
        }

        if let visitor = prefs.string(for: PrefsStore.Key.visitorData), !visitor.isEmpty {
            client.visitorData = visitor
        }
        if let cookie = prefs.string(for: PrefsStore.Key.cookie), !cookie.isEmpty {
            client.cookie = cookie
        }
        if let syncId = prefs.string(for: PrefsStore.Key.dataSyncId), !syncId.isEmpty {
            client.dataSyncId = syncId
        }

        let storedCountry = prefs.string(for: PrefsStore.Key.contentCountry)
        let storedLanguage = prefs.string(for: PrefsStore.Key.contentLanguage)
        if storedCountry != nil || storedLanguage != nil {
            let fallback = YouTubeLocale.current
            client.locale = YouTubeLocale(
                gl: storedCountry ?? fallback.gl,
                hl: storedLanguage ?? fallback.hl
            )
        }

        // A visitor id is required before the first browse request. This is a no-op when one was
        // restored above, and the request is already asynchronous.
        client.ensureVisitorData { _ in }
    }

    // MARK: - Lifecycle hooks

    /// Persists the playback position. Called when the app leaves the foreground and terminates,
    /// so a video resumes where it was left even if the process is killed.
    ///
    /// The player writes history on pause and on a timer; leaving the app is the one moment where
    /// neither has necessarily happened yet, so the current position is written here.
    func persistPlaybackPosition() {
        guard let item = playback.queue.current else { return }
        let position = playback.currentPosition
        guard position.isFinite, position > 0 else { return }
        let duration = playback.currentDuration
        historyStore.record(
            videoId: item.videoId,
            title: item.title,
            channelId: item.channelId,
            channelName: item.channelName,
            thumbnailUrl: item.thumbnailUrl,
            duration: duration,
            position: position,
            isMusic: item.isMusic
        )
    }

    /// Drops the decoded-image cache in response to a memory warning.
    func handleMemoryWarning() {
        imageLoader.clearMemory()
        NotificationCenter.default.post(name: Notification.Name.flowImageCacheDidClear, object: nil)
    }
}
