import Foundation

/// One row of watch history: enough to render a row and resume the video without a network call.
struct HistoryEntry {
    let videoId: String
    let title: String
    let channelId: String
    let channelName: String
    let thumbnailUrl: String
    let duration: TimeInterval
    let position: TimeInterval
    let watchedAt: Date
    let isMusic: Bool

    /// How far through the video the viewer got, 0...1.
    var progress: Double {
        guard duration > 0 else { return 0.0 }
        return min(max(position / duration, 0.0), 1.0)
    }

    /// Whether the video was finished, within the last few seconds.
    var isFinished: Bool {
        return duration > 0 && position >= duration - 10.0
    }
}

/// Watch history, persisted in SQLite. Recording is a single upsert keyed on the video id, so a
/// rewatch moves the row to the top rather than duplicating it — the same behaviour as the
/// Android app's history table.
final class HistoryStore {

    static let shared = HistoryStore()

    private let database: FlowDB
    private let queue = DispatchQueue(label: "org.flowtube.Flow.history", qos: .utility)

    /// The most recent entries, kept in memory so Home can render instantly on launch.
    private(set) var cachedEntries: [HistoryEntry] = []
    private let lock = NSLock()

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
        reloadCache()
    }

    // MARK: - Reading

    /// The newest `limit` entries, optionally restricted to music.
    func recent(limit: Int = 100, musicOnly: Bool = false) -> [HistoryEntry] {
        var statement = "SELECT * FROM history"
        var arguments: [FlowDBValue] = []
        if musicOnly {
            statement += " WHERE is_music = 1"
        }
        statement += " ORDER BY watched_at DESC LIMIT ?;"
        arguments.append(.int(limit))
        return database.query(statement, arguments).map(HistoryStore.entry(from:))
    }

    /// Entries whose title, channel or video id matches `query`, newest first.
    func search(_ query: String, limit: Int = 100) -> [HistoryEntry] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return recent(limit: limit) }
        let pattern = "%\(trimmed)%"
        let rows = database.query(
            "SELECT * FROM history WHERE title LIKE ? COLLATE NOCASE OR channel_name LIKE ? COLLATE NOCASE OR video_id = ? ORDER BY watched_at DESC LIMIT ?;",
            [.text(pattern), .text(pattern), .text(trimmed), .int(limit)]
        )
        return rows.map(HistoryStore.entry(from:))
    }

    /// Entries grouped by calendar day, newest day first. Used by the History screen's sections.
    func groupedByDay(limit: Int = 500) -> [(day: Date, entries: [HistoryEntry])] {
        let entries = recent(limit: limit)
        var order: [Date] = []
        var buckets: [Date: [HistoryEntry]] = [:]
        for entry in entries {
            let day = entry.watchedAt.startOfDay
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// The resume position for a video, or nil when it was never watched or was finished.
    func resumePosition(for videoId: String) -> TimeInterval? {
        guard let row = database.firstRow("SELECT position, duration FROM history WHERE video_id = ? LIMIT 1;", [.text(videoId)]) else {
            return nil
        }
        let position = row.double("position")
        let duration = row.double("duration")
        guard position > 5.0 else { return nil }
        if duration > 0 && position >= duration - 10.0 { return nil }
        return position
    }

    /// Whether a video appears in history at all.
    func contains(videoId: String) -> Bool {
        return database.firstRow("SELECT 1 AS present FROM history WHERE video_id = ? LIMIT 1;", [.text(videoId)]) != nil
    }

    /// The total number of stored entries.
    var count: Int {
        return database.scalarInt("SELECT COUNT(*) AS value FROM history;")
    }

    /// The distinct channels the viewer watches most, with their watch counts. Feeds the on-device
    /// recommendation engine and the Recap screen.
    func topChannels(limit: Int = 10) -> [(channelId: String, channelName: String, watches: Int)] {
        let rows = database.query(
            "SELECT channel_id, channel_name, COUNT(*) AS watches FROM history WHERE channel_id != '' GROUP BY channel_id ORDER BY watches DESC LIMIT ?;",
            [.int(limit)]
        )
        return rows.map { ($0.string("channel_id"), $0.string("channel_name"), $0.int("watches")) }
    }

    /// Total watch time in seconds, optionally only since a date.
    func totalWatchTime(since: Date? = nil) -> TimeInterval {
        let rows: [FlowDBRow]
        if let start = since {
            rows = database.query("SELECT position FROM history WHERE watched_at >= ?;", [.date(start)])
        } else {
            rows = database.query("SELECT position FROM history;")
        }
        return rows.reduce(0.0) { $0 + $1.double("position") }
    }

    /// Watch time per day for the last `days` days, oldest first. Recap draws this as a bar chart.
    func watchTimeByDay(days: Int = 7) -> [(day: Date, seconds: TimeInterval)] {
        let calendar = Calendar.current
        let today = Date().startOfDay
        var result: [(Date, TimeInterval)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let next = day.addingDays(1)
            let row = database.firstRow(
                "SELECT SUM(position) AS total FROM history WHERE watched_at >= ? AND watched_at < ?;",
                [.date(day), .date(next)]
            )
            result.append((day, row?.double("total") ?? 0.0))
        }
        return result
    }

    // MARK: - Writing

    /// Records a watch. Called on pause, on video change and periodically during playback.
    func record(
        videoId: String,
        title: String,
        channelId: String,
        channelName: String,
        thumbnailUrl: String,
        duration: TimeInterval,
        position: TimeInterval,
        isMusic: Bool = false,
        watchedAt: Date = Date()
    ) {
        guard !videoId.isEmpty else { return }
        guard !PrefsStore.shared.historyPaused else { return }
        let safePosition = max(0.0, position)
        let safeDuration = max(0.0, duration)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                """
                INSERT INTO history (video_id, title, channel_id, channel_name, thumbnail_url, duration, position, watched_at, is_music)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(video_id) DO UPDATE SET
                    title = excluded.title,
                    channel_id = excluded.channel_id,
                    channel_name = excluded.channel_name,
                    thumbnail_url = excluded.thumbnail_url,
                    duration = excluded.duration,
                    position = excluded.position,
                    watched_at = excluded.watched_at,
                    is_music = excluded.is_music;
                """,
                [
                    .text(videoId),
                    .text(title),
                    .text(channelId),
                    .text(channelName),
                    .text(thumbnailUrl),
                    .double(safeDuration),
                    .double(safePosition),
                    .date(watchedAt),
                    .bool(isMusic),
                ]
            )
            self.reloadCache()
            FlowEventBus.shared.broadcast("history", notification: .flowHistoryDidChange)
        }
    }

    /// Updates only the resume position, without touching the metadata or the timestamp. Used by the
    /// periodic save during playback so a long watch does not re-sort the history list every minute.
    func updatePosition(videoId: String, position: TimeInterval, duration: TimeInterval) {
        guard !videoId.isEmpty, !PrefsStore.shared.historyPaused else { return }
        queue.async { [weak self] in
            self?.database.execute(
                "UPDATE history SET position = ?, duration = ? WHERE video_id = ?;",
                [.double(max(0.0, position)), .double(max(0.0, duration)), .text(videoId)]
            )
        }
    }

    /// Removes one entry.
    func remove(videoId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM history WHERE video_id = ?;", [.text(videoId)])
            self.reloadCache()
            FlowEventBus.shared.broadcast("history", notification: .flowHistoryDidChange)
        }
    }

    /// Removes every entry.
    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM history;")
            self.reloadCache()
            FlowEventBus.shared.broadcast("history", notification: .flowHistoryDidChange)
        }
    }

    /// Removes entries older than `date`. Used by the storage screen's "clear older than" action.
    func removeOlderThan(_ date: Date) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM history WHERE watched_at < ?;", [.date(date)])
            self.reloadCache()
            FlowEventBus.shared.broadcast("history", notification: .flowHistoryDidChange)
        }
    }

    /// Prunes the oldest entries beyond `maximum`, keeping the history bounded.
    func prune(maximum: Int = 5000) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                "DELETE FROM history WHERE video_id NOT IN (SELECT video_id FROM history ORDER BY watched_at DESC LIMIT ?);",
                [.int(maximum)]
            )
            self.reloadCache()
        }
    }

    // MARK: - Cache

    private func reloadCache() {
        let rows = database.query("SELECT * FROM history ORDER BY watched_at DESC LIMIT 200;")
        let entries = rows.map(HistoryStore.entry(from:))
        lock.lock()
        cachedEntries = entries
        lock.unlock()
    }

    private static func entry(from row: FlowDBRow) -> HistoryEntry {
        return HistoryEntry(
            videoId: row.string("video_id"),
            title: row.string("title"),
            channelId: row.string("channel_id"),
            channelName: row.string("channel_name"),
            thumbnailUrl: row.string("thumbnail_url"),
            duration: row.double("duration"),
            position: row.double("position"),
            watchedAt: row.date("watched_at") ?? Date(timeIntervalSince1970: 0),
            isMusic: row.bool("is_music")
        )
    }
}

/// The search history behind the search bar's chips. Separate from watch history: clearing one must
/// not clear the other.
final class SearchHistoryStore {

    static let shared = SearchHistoryStore()

    private let database: FlowDB
    private let queue = DispatchQueue(label: "org.flowtube.Flow.searchHistory", qos: .utility)

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
    }

    /// The most recent queries, newest first.
    func recent(limit: Int = 12) -> [String] {
        let rows = database.query("SELECT query FROM search_history ORDER BY searched_at DESC LIMIT ?;", [.int(limit)])
        return rows.map { $0.string("query") }
    }

    /// Records a query, moving an existing one to the top.
    func record(_ query: String) {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty, PrefsStore.shared.bool(for: .searchHistoryEnabled, fallback: true) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                """
                INSERT INTO search_history (query, searched_at) VALUES (?, ?)
                ON CONFLICT(query) DO UPDATE SET searched_at = excluded.searched_at;
                """,
                [.text(trimmed), .date(Date())]
            )
            self.database.execute(
                "DELETE FROM search_history WHERE query NOT IN (SELECT query FROM search_history ORDER BY searched_at DESC LIMIT 30);"
            )
        }
    }

    /// Removes one query.
    func remove(_ query: String) {
        queue.async { [weak self] in
            self?.database.execute("DELETE FROM search_history WHERE query = ?;", [.text(query)])
        }
    }

    /// Removes every query.
    func clear() {
        queue.async { [weak self] in
            self?.database.execute("DELETE FROM search_history;")
        }
    }
}
