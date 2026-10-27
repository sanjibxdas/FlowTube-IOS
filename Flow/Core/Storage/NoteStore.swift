import Foundation

/// A note the viewer wrote about a moment in a video. `timestamp` is the playback position the note
/// is anchored to, so tapping it in the Notes screen seeks there.
struct VideoNote {
    let id: Int64
    let videoId: String
    let videoTitle: String
    let channelName: String
    let body: String
    let timestamp: TimeInterval
    let createdAt: Date
    let updatedAt: Date
}

/// Notes, stored per video and per timestamp. A note is editable and reorderable; ordering is by
/// timestamp inside a video and by recency across videos.
final class NoteStore {

    static let shared = NoteStore()

    private let database: FlowDB
    private let queue = DispatchQueue(label: "org.flowtube.Flow.notes", qos: .utility)

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
    }

    // MARK: - Reading

    /// Every note, newest first.
    func all() -> [VideoNote] {
        return database.query("SELECT * FROM notes ORDER BY updated_at DESC;").map(NoteStore.note(from:))
    }

    /// The notes for one video, in playback order.
    func notes(for videoId: String) -> [VideoNote] {
        let rows = database.query(
            "SELECT * FROM notes WHERE video_id = ? ORDER BY timestamp ASC, created_at ASC;",
            [.text(videoId)]
        )
        return rows.map(NoteStore.note(from:))
    }

    /// One note by row id.
    func note(id: Int64) -> VideoNote? {
        guard let row = database.firstRow("SELECT * FROM notes WHERE id = ? LIMIT 1;", [.integer(id)]) else {
            return nil
        }
        return NoteStore.note(from: row)
    }

    /// Notes whose body, video title or channel matches `query`.
    func search(_ query: String) -> [VideoNote] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return all() }
        let pattern = "%\(trimmed)%"
        let rows = database.query(
            "SELECT * FROM notes WHERE body LIKE ? COLLATE NOCASE OR video_title LIKE ? COLLATE NOCASE OR channel_name LIKE ? COLLATE NOCASE ORDER BY updated_at DESC;",
            [.text(pattern), .text(pattern), .text(pattern)]
        )
        return rows.map(NoteStore.note(from:))
    }

    /// The number of notes on a video.
    func count(for videoId: String) -> Int {
        return database.scalarInt("SELECT COUNT(*) AS value FROM notes WHERE video_id = ?;", [.text(videoId)])
    }

    /// The total number of notes.
    var totalCount: Int {
        return database.scalarInt("SELECT COUNT(*) AS value FROM notes;")
    }

    // MARK: - Writing

    /// Creates a note and returns its row id.
    @discardableResult
    func create(
        videoId: String,
        videoTitle: String,
        channelName: String,
        body: String,
        timestamp: TimeInterval
    ) -> Int64 {
        let trimmed = body.trimmed
        guard !trimmed.isEmpty, !videoId.isEmpty else { return 0 }
        let now = Date()
        database.execute(
            """
            INSERT INTO notes (video_id, video_title, channel_name, body, timestamp, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(videoId),
                .text(videoTitle),
                .text(channelName),
                .text(trimmed),
                .double(max(0.0, timestamp)),
                .date(now),
                .date(now),
            ]
        )
        FlowEventBus.shared.broadcast("notes", notification: .flowNotesDidChange, payload: videoId)
        let row = database.firstRow("SELECT id FROM notes ORDER BY id DESC LIMIT 1;")
        return row?.int64("id") ?? 0
    }

    /// Replaces a note's body.
    func update(id: Int64, body: String) {
        let trimmed = body.trimmed
        guard !trimmed.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                "UPDATE notes SET body = ?, updated_at = ? WHERE id = ?;",
                [.text(trimmed), .date(Date()), .integer(id)]
            )
            FlowEventBus.shared.broadcast("notes", notification: .flowNotesDidChange)
        }
    }

    /// Moves a note to a different playback position.
    func move(id: Int64, to timestamp: TimeInterval) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                "UPDATE notes SET timestamp = ?, updated_at = ? WHERE id = ?;",
                [.double(max(0.0, timestamp)), .date(Date()), .integer(id)]
            )
            FlowEventBus.shared.broadcast("notes", notification: .flowNotesDidChange)
        }
    }

    /// Deletes one note.
    func delete(id: Int64) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM notes WHERE id = ?;", [.integer(id)])
            FlowEventBus.shared.broadcast("notes", notification: .flowNotesDidChange)
        }
    }

    /// Deletes every note on a video.
    func deleteAll(for videoId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM notes WHERE video_id = ?;", [.text(videoId)])
            FlowEventBus.shared.broadcast("notes", notification: .flowNotesDidChange, payload: videoId)
        }
    }

    /// Deletes every note.
    func deleteAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM notes;")
            FlowEventBus.shared.broadcast("notes", notification: .flowNotesDidChange)
        }
    }

    // MARK: - Helpers

    private static func note(from row: FlowDBRow) -> VideoNote {
        return VideoNote(
            id: row.int64("id"),
            videoId: row.string("video_id"),
            videoTitle: row.string("video_title"),
            channelName: row.string("channel_name"),
            body: row.string("body"),
            timestamp: row.double("timestamp"),
            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
            updatedAt: row.date("updated_at") ?? Date(timeIntervalSince1970: 0)
        )
    }
}

/// Saved Shorts, kept apart from history so the Shorts screen can show a "saved" tab without
/// polluting the watch history list.
final class SavedShortsStore {

    static let shared = SavedShortsStore()

    private let database: FlowDB
    private let queue = DispatchQueue(label: "org.flowtube.Flow.savedShorts", qos: .utility)

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
    }

    /// Every saved Short, newest first.
    func all() -> [(videoId: String, title: String, channelName: String, thumbnailUrl: String, savedAt: Date)] {
        let rows = database.query("SELECT * FROM saved_shorts ORDER BY saved_at DESC;")
        return rows.map { row in
            (
                row.string("video_id"),
                row.string("title"),
                row.string("channel_name"),
                row.string("thumbnail_url"),
                row.date("saved_at") ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    /// Whether a Short was saved.
    func contains(videoId: String) -> Bool {
        return database.firstRow(
            "SELECT 1 AS present FROM saved_shorts WHERE video_id = ? LIMIT 1;",
            [.text(videoId)]
        ) != nil
    }

    /// Saves a Short, or removes it when it was already saved. Returns the new saved state.
    @discardableResult
    func toggle(videoId: String, title: String, channelName: String, thumbnailUrl: String) -> Bool {
        guard !videoId.isEmpty else { return false }
        if contains(videoId: videoId) {
            remove(videoId: videoId)
            return false
        }
        database.execute(
            "INSERT OR REPLACE INTO saved_shorts (video_id, title, channel_name, thumbnail_url, saved_at) VALUES (?, ?, ?, ?, ?);",
            [.text(videoId), .text(title), .text(channelName), .text(thumbnailUrl), .date(Date())]
        )
        FlowEventBus.shared.broadcast("shorts", notification: .flowHistoryDidChange, payload: videoId)
        return true
    }

    /// Removes a saved Short.
    func remove(videoId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM saved_shorts WHERE video_id = ?;", [.text(videoId)])
            FlowEventBus.shared.broadcast("shorts", notification: .flowHistoryDidChange, payload: videoId)
        }
    }

    /// Removes every saved Short.
    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM saved_shorts;")
            FlowEventBus.shared.broadcast("shorts", notification: .flowHistoryDidChange)
        }
    }
}

/// The on-device topic weights behind the recommendation engine. Nothing here leaves the device:
/// the weights are built from watch history and are inspectable and resettable in Settings.
final class TopicStore {

    static let shared = TopicStore()

    private let database: FlowDB
    private let queue = DispatchQueue(label: "org.flowtube.Flow.topics", qos: .utility)

    /// Words too common to say anything about what the viewer likes.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "you", "your", "our", "his", "her",
        "its", "are", "was", "were", "have", "has", "had", "not", "but", "all", "any", "can",
        "how", "why", "what", "when", "who", "will", "would", "could", "should", "about", "into",
        "over", "under", "more", "most", "some", "such", "than", "then", "them", "they", "there",
        "here", "just", "like", "make", "made", "get", "got", "out", "off", "new", "one", "two",
        "official", "video", "music", "full", "part", "feat", "ft", "live", "hd", "4k",
    ]

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
    }

    /// The strongest topics, heaviest first.
    func topTopics(limit: Int = 20) -> [(token: String, weight: Double)] {
        let rows = database.query(
            "SELECT token, weight FROM topic_weights ORDER BY weight DESC LIMIT ?;",
            [.int(limit)]
        )
        return rows.map { ($0.string("token"), $0.double("weight")) }
    }

    /// The weight of one token.
    func weight(of token: String) -> Double {
        guard let row = database.firstRow("SELECT weight FROM topic_weights WHERE token = ? LIMIT 1;", [.text(token)]) else {
            return 0.0
        }
        return row.double("weight")
    }

    /// The number of tracked topics.
    var topicCount: Int {
        return database.scalarInt("SELECT COUNT(*) AS value FROM topic_weights;")
    }

    /// Learns from a video the viewer watched: each meaningful word in its title and channel gains
    /// weight, and the whole set decays slightly so recent interests dominate.
    func learn(title: String, channelName: String, weight: Double = 1.0) {
        guard PrefsStore.shared.bool(for: .recommendationsEnabled, fallback: true) else { return }
        let tokens = TopicStore.tokenize(title + " " + channelName)
        guard !tokens.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.transaction { transaction in
                transaction.execute("UPDATE topic_weights SET weight = weight * 0.995;")
                for token in tokens {
                    transaction.execute(
                        """
                        INSERT INTO topic_weights (token, weight, updated_at) VALUES (?, ?, ?)
                        ON CONFLICT(token) DO UPDATE SET
                            weight = weight + excluded.weight,
                            updated_at = excluded.updated_at;
                        """,
                        [.text(token), .double(weight), .date(Date())]
                    )
                }
                transaction.execute("DELETE FROM topic_weights WHERE weight < 0.05;")
            }
        }
    }

    /// Scores a candidate video against the learned topics. Higher means a better match.
    func score(title: String, channelName: String) -> Double {
        let tokens = TopicStore.tokenize(title + " " + channelName)
        guard !tokens.isEmpty else { return 0.0 }
        let rows = database.query("SELECT token, weight FROM topic_weights;")
        var weights: [String: Double] = [:]
        for row in rows {
            weights[row.string("token")] = row.double("weight")
        }
        var total = 0.0
        for token in tokens {
            total += weights[token] ?? 0.0
        }
        return total / Double(tokens.count)
    }

    /// Forgets everything the engine learned.
    func reset() {
        queue.async { [weak self] in
            self?.database.execute("DELETE FROM topic_weights;")
            FlowEventBus.shared.broadcast("topics", notification: .flowPrefsDidChange)
        }
    }

    /// Splits text into lowercase tokens, dropping stop words, punctuation and short fragments.
    static func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let separators = CharacterSet(charactersIn: " \t\n\r.,;:!?()[]{}<>\"'`/\\|-_+=*&^%$#@~")
        let raw = lowered.components(separatedBy: separators)
        var result: [String] = []
        var seen: Set<String> = []
        for token in raw {
            let trimmed = token.trimmed
            guard trimmed.count >= 3 else { continue }
            guard !stopWords.contains(trimmed) else { continue }
            guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
