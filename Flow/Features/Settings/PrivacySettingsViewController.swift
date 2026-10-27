import UIKit

/// Privacy: what the app remembers, and the actions that forget it.
///
/// Flow has no account and no server-side profile, so "privacy" here is entirely about the local
/// database and the local preferences. Every destructive action names exactly what it removes and
/// asks first; the export writes a JSON file the viewer can keep, which is the counterpart of the
/// Android app's "Export Data".
final class PrivacySettingsViewController: SettingsListViewController {

    private let prefs = FlowApp.shared.prefs

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "History & privacy"
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            recordingSection(),
            historySection(),
            searchSection(),
            exportSection(),
            eraseSection(),
        ]
    }

    private func recordingSection() -> SettingsSection {
        return SettingsSection(
            header: "Watch history",
            footer: "Pausing stops new videos from being saved. What is already saved stays until you clear it.",
            rows: [
                .toggle(
                    "Pause watch history",
                    icon: .pause,
                    subtitle: "Stop saving what you watch. Deep Flow also pauses learning",
                    isOn: prefs.historyPaused,
                    onChange: { [weak self] value in
                        self?.prefs.historyPaused = value
                        self?.rebuild()
                    }
                ),
                .toggle(
                    "Search history",
                    icon: .search,
                    subtitle: "Suggest recent searches while you type",
                    isOn: prefs.bool(for: .searchHistoryEnabled, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .searchHistoryEnabled)
                    }
                ),
                .toggle(
                    "Show recommendations on Home",
                    icon: .home,
                    subtitle: "Personalized recommendations on the home feed",
                    isOn: prefs.bool(for: .recommendationsEnabled, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .recommendationsEnabled)
                    }
                ),
            ]
        )
    }

    private func historySection() -> SettingsSection {
        let count = FlowApp.shared.historyStore.count
        let searches = SearchHistoryStore.shared.recent(limit: 1000).count
        return SettingsSection(
            header: "History",
            footer: "Clearing history also forgets where you were in each video.",
            rows: [
                .detail(
                    icon: .clock,
                    title: "Videos watched",
                    subtitle: "Saved in the local database",
                    value: "\(count)"
                ),
                .detail(
                    icon: .search,
                    title: "Searches saved",
                    subtitle: "Used for suggestions",
                    value: "\(searches)"
                ),
                .destructive(
                    "Clear watch history",
                    icon: .trash,
                    subtitle: "Remove every video from your history",
                    action: { [weak self] in
                        self?.confirmClearHistory()
                    }
                ),
                .destructive(
                    "Clear Search History",
                    icon: .trash,
                    subtitle: "Permanently delete all search history",
                    action: { [weak self] in
                        self?.confirmClearSearchHistory()
                    }
                ),
            ]
        )
    }

    private func searchSection() -> SettingsSection {
        return SettingsSection(
            header: "Search & History",
            footer: "Search suggestions come from this device only. Nothing is sent to a suggestion service.",
            rows: [
                .detail(
                    icon: .search,
                    title: "Suggestions",
                    subtitle: "Built from your own recent searches",
                    value: prefs.bool(for: .searchHistoryEnabled, fallback: true) ? "On" : "Off"
                ),
            ]
        )
    }

    private func exportSection() -> SettingsSection {
        return SettingsSection(
            header: "Export Data",
            footer: "The file contains your history, subscriptions, playlists, notes and settings. Share it somewhere safe; Flow keeps no copy.",
            rows: [
                .nav(
                    "Export Data",
                    icon: .exportIcon,
                    subtitle: "Backup your data as a JSON file",
                    value: nil,
                    action: { [weak self] in
                        self?.exportData()
                    }
                ),
            ]
        )
    }

    private func eraseSection() -> SettingsSection {
        return SettingsSection(
            header: "Data Management",
            footer: "Erasing all data cannot be undone. Downloads and cached artwork are removed too.",
            rows: [
                .destructive(
                    "Clear all data",
                    icon: .trash,
                    subtitle: "Erase history, subscriptions, playlists, notes and settings",
                    action: { [weak self] in
                        self?.confirmClearAllData()
                    }
                ),
            ]
        )
    }

    // MARK: - Actions

    private func confirmClearHistory() {
        let alert = UIAlertController(
            title: "Clear watch history?",
            message: "This will remove all videos from your watch history. This action cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { [weak self] _ in
            FlowApp.shared.historyStore.clear()
            FlowEventBus.shared.broadcast("history", notification: .flowHistoryDidChange)
            self?.rebuild()
            FlowSnackbar.show("Watch history cleared")
        }))
        present(alert, animated: true, completion: nil)
    }

    private func confirmClearSearchHistory() {
        let alert = UIAlertController(
            title: "Clear Search History?",
            message: "Permanently delete all search history.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { [weak self] _ in
            SearchHistoryStore.shared.clear()
            self?.rebuild()
            FlowSnackbar.show("Search history cleared")
        }))
        present(alert, animated: true, completion: nil)
    }

    private func confirmClearAllData() {
        let alert = UIAlertController(
            title: "Clear all data?",
            message: "This erases your history, subscriptions, playlists, notes, downloads and settings. Flow returns to a fresh install. This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear All", style: .destructive, handler: { [weak self] _ in
            self?.eraseEverything()
        }))
        present(alert, animated: true, completion: nil)
    }

    /// Empties every store and puts the theme back to its default, in the order that keeps the UI
    /// consistent: data first, then preferences, then a repaint.
    private func eraseEverything() {
        let app = FlowApp.shared
        app.historyStore.clear()
        SearchHistoryStore.shared.clear()
        app.subscriptionStore.clear()
        app.playlistStore.deleteAllLocalPlaylists()
        app.noteStore.deleteAll()
        TopicStore.shared.reset()
        SavedShortsStore.shared.clear()
        app.downloadStore.removeAll()
        app.imageLoader.clearMemory()
        app.imageLoader.clearDisk()
        FlowDB.shared.eraseAll()
        prefs.removeAll()

        FlowEventBus.shared.broadcast("history", notification: .flowHistoryDidChange)
        FlowEventBus.shared.broadcast("subscriptions", notification: .flowSubscriptionsDidChange)
        FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        FlowEventBus.shared.broadcast("downloads", notification: .flowDownloadsDidChange)
        FlowEventBus.shared.broadcast("notes", notification: .flowNotesDidChange)
        NotificationCenter.default.post(name: Notification.Name.flowImageCacheDidClear, object: nil)

        FlowTheme.shared.apply(mode: .default)
        FlowTheme.shared.persist(to: prefs)
        rebuild()
        FlowSnackbar.show("All data cleared")
    }

    /// Writes a JSON backup and hands it to the share sheet.
    ///
    /// The share sheet is the iOS equivalent of Android's `ACTION_CREATE_DOCUMENT`: it lets the
    /// viewer put the file in Files, iCloud Drive or another app without the app needing a
    /// document-picker session of its own.
    private func exportData() {
        let payload = DataExporter.makeBackup()
        let name = DataExporter.fileName()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            FlowSnackbar.showError("Export failed: " + error.localizedDescription)
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.midY,
            width: 1.0,
            height: 1.0
        )
        present(activity, animated: true, completion: nil)
    }
}

// MARK: - Export

/// Builds the JSON backup the Privacy screen shares.
///
/// The shape is deliberately flat and readable: a version, a timestamp, and one array per kind of
/// record. It is not the Android backup format — the two apps store different columns — but it is
/// self-describing and can be read back by the import screen.
enum DataExporter {

    /// The backup's format version. Bumped when a field changes meaning.
    static let version = 1

    /// A dated file name, so two exports do not overwrite each other in Files.
    static func fileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "flow-backup-" + formatter.string(from: now) + ".json"
    }

    /// Serialises the stores into JSON. Returns an empty object rather than nil when a store is
    /// empty, so the file always has the same shape.
    static func makeBackup() -> Data {
        let app = FlowApp.shared
        var root: [String: Any] = [:]
        root["version"] = version
        root["exportedAt"] = ISO8601DateFormatter().string(from: Date())

        let history = app.historyStore.recent(limit: 100000).map { entry -> [String: Any] in
            return [
                "videoId": entry.videoId,
                "title": entry.title,
                "channelId": entry.channelId,
                "channelName": entry.channelName,
                "thumbnailUrl": entry.thumbnailUrl,
                "duration": entry.duration,
                "position": entry.position,
                "watchedAt": ISO8601DateFormatter().string(from: entry.watchedAt),
                "isMusic": entry.isMusic,
            ]
        }
        root["history"] = history

        let subscriptions = app.subscriptionStore.all.map { subscription -> [String: Any] in
            return [
                "channelId": subscription.channelId,
                "name": subscription.name,
                "avatarUrl": subscription.avatarUrl,
                "subscriberCount": subscription.subscriberCount,
                "subscribedAt": ISO8601DateFormatter().string(from: subscription.subscribedAt),
                "notificationsEnabled": subscription.notificationsEnabled,
            ]
        }
        root["subscriptions"] = subscriptions

        let playlists = app.playlistStore.localPlaylists().map { playlist -> [String: Any] in
            let items = playlist.items.map { item -> [String: Any] in
                return [
                    "videoId": item.videoId,
                    "title": item.title,
                    "channelName": item.channelName,
                    "thumbnailUrl": item.thumbnailUrl,
                    "duration": item.duration,
                    "position": item.position,
                ]
            }
            return [
                "playlistId": playlist.playlistId,
                "title": playlist.title,
                "description": playlist.description,
                "createdAt": ISO8601DateFormatter().string(from: playlist.createdAt),
                "items": items,
            ]
        }
        root["playlists"] = playlists

        let notes = app.noteStore.all().map { note -> [String: Any] in
            return [
                "videoId": note.videoId,
                "videoTitle": note.videoTitle,
                "channelName": note.channelName,
                "body": note.body,
                "timestamp": note.timestamp,
                "createdAt": ISO8601DateFormatter().string(from: note.createdAt),
            ]
        }
        root["notes"] = notes

        let searches = SearchHistoryStore.shared.recent(limit: 100000)
        root["searches"] = searches

        // Preferences are exported by their stored value, whatever its type. The defaults object is
        // read directly because `PrefsStore` exposes typed accessors, not the raw entry.
        var settings: [String: Any] = [:]
        let defaults = UserDefaults.standard
        for key in PrefsStore.Key.allCasesForReset {
            guard let value = defaults.object(forKey: key.rawValue) else { continue }
            if let date = value as? Date {
                settings[key.rawValue] = ISO8601DateFormatter().string(from: date)
            } else if JSONSerialization.isValidJSONObject([key.rawValue: value]) {
                settings[key.rawValue] = value
            }
        }
        root["settings"] = settings

        guard
            JSONSerialization.isValidJSONObject(root),
            let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else {
            return Data("{}".utf8)
        }
        return data
    }
}
