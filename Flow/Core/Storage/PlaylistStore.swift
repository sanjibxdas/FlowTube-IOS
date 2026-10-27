import Foundation

/// One video inside a playlist, in playlist order.
struct PlaylistEntry {
    let rowId: Int64
    let playlistId: String
    let videoId: String
    let title: String
    let channelName: String
    let thumbnailUrl: String
    let duration: TimeInterval
    let position: Int
    let addedAt: Date
}

/// A playlist as the app stores it. `isLocal` distinguishes a playlist the viewer made from one
/// that lives on YouTube; only local playlists can be edited offline.
struct StoredPlaylist {
    let playlistId: String
    let title: String
    let description: String
    let thumbnailUrl: String
    let isLocal: Bool
    let createdAt: Date
    let updatedAt: Date
    var items: [PlaylistEntry]
}

/// Local playlists and their items. Ordering is an explicit integer column, rewritten on every
/// reorder, so a drag never leaves two rows claiming the same position.
final class PlaylistStore {

    static let shared = PlaylistStore()

    private let database: FlowDB
    private let queue = DispatchQueue(label: "org.flowtube.Flow.playlists", qos: .utility)

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
    }

    // MARK: - Reading

    /// Every playlist, most recently updated first.
    func allPlaylists() -> [StoredPlaylist] {
        let rows = database.query("SELECT * FROM playlists ORDER BY updated_at DESC;")
        return rows.map { row in
            let playlistId = row.string("playlist_id")
            return StoredPlaylist(
                playlistId: playlistId,
                title: row.string("title"),
                description: row.string("description"),
                thumbnailUrl: row.string("thumbnail_url"),
                isLocal: row.bool("is_local"),
                createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
                updatedAt: row.date("updated_at") ?? Date(timeIntervalSince1970: 0),
                items: items(in: playlistId)
            )
        }
    }

    /// Only the playlists the viewer made.
    func localPlaylists() -> [StoredPlaylist] {
        return allPlaylists().filter { $0.isLocal }
    }

    /// One playlist with its items, or nil when it is not stored.
    func playlist(id: String) -> StoredPlaylist? {
        guard let row = database.firstRow("SELECT * FROM playlists WHERE playlist_id = ? LIMIT 1;", [.text(id)]) else {
            return nil
        }
        return StoredPlaylist(
            playlistId: row.string("playlist_id"),
            title: row.string("title"),
            description: row.string("description"),
            thumbnailUrl: row.string("thumbnail_url"),
            isLocal: row.bool("is_local"),
            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
            updatedAt: row.date("updated_at") ?? Date(timeIntervalSince1970: 0),
            items: items(in: id)
        )
    }

    /// The items of `playlistId`, in playlist order.
    func items(in playlistId: String) -> [PlaylistEntry] {
        let rows = database.query(
            "SELECT * FROM playlist_items WHERE playlist_id = ? ORDER BY position ASC, id ASC;",
            [.text(playlistId)]
        )
        return rows.map { row in
            PlaylistEntry(
                rowId: row.int64("id"),
                playlistId: row.string("playlist_id"),
                videoId: row.string("video_id"),
                title: row.string("title"),
                channelName: row.string("channel_name"),
                thumbnailUrl: row.string("thumbnail_url"),
                duration: row.double("duration"),
                position: row.int("position"),
                addedAt: row.date("added_at") ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    /// The number of items in a playlist.
    func itemCount(in playlistId: String) -> Int {
        return database.scalarInt(
            "SELECT COUNT(*) AS value FROM playlist_items WHERE playlist_id = ?;",
            [.text(playlistId)]
        )
    }

    /// The playlists that contain `videoId`, for the "saved to" checkmark.
    func playlistsContaining(videoId: String) -> [String] {
        let rows = database.query(
            "SELECT DISTINCT playlist_id FROM playlist_items WHERE video_id = ?;",
            [.text(videoId)]
        )
        return rows.map { $0.string("playlist_id") }
    }

    /// Whether `videoId` is in `playlistId`.
    func contains(videoId: String, in playlistId: String) -> Bool {
        return database.firstRow(
            "SELECT 1 AS present FROM playlist_items WHERE playlist_id = ? AND video_id = ? LIMIT 1;",
            [.text(playlistId), .text(videoId)]
        ) != nil
    }

    // MARK: - Writing

    /// Creates a local playlist and returns its generated id.
    @discardableResult
    func createPlaylist(title: String, description: String = "") -> String {
        let trimmed = title.trimmed.isEmpty ? "New playlist" : title.trimmed
        let identifier = "FL" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        let now = Date()
        database.execute(
            """
            INSERT INTO playlists (playlist_id, title, description, thumbnail_url, is_local, created_at, updated_at)
            VALUES (?, ?, ?, ?, 1, ?, ?);
            """,
            [.text(identifier), .text(trimmed), .text(description), .text(""), .date(now), .date(now)]
        )
        FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        return identifier
    }

    /// Stores a playlist fetched from YouTube, replacing its cached items.
    func saveRemotePlaylist(
        playlistId: String,
        title: String,
        description: String,
        thumbnailUrl: String,
        items: [PlaylistEntry]
    ) {
        guard !playlistId.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            self.database.transaction { transaction in
                transaction.execute(
                    """
                    INSERT INTO playlists (playlist_id, title, description, thumbnail_url, is_local, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 0, ?, ?)
                    ON CONFLICT(playlist_id) DO UPDATE SET
                        title = excluded.title,
                        description = excluded.description,
                        thumbnail_url = excluded.thumbnail_url,
                        updated_at = excluded.updated_at;
                    """,
                    [
                        .text(playlistId),
                        .text(title),
                        .text(description),
                        .text(thumbnailUrl),
                        .date(now),
                        .date(now),
                    ]
                )
                transaction.execute("DELETE FROM playlist_items WHERE playlist_id = ?;", [.text(playlistId)])
                for (offset, item) in items.enumerated() {
                    transaction.execute(
                        """
                        INSERT INTO playlist_items
                        (playlist_id, video_id, title, channel_name, thumbnail_url, duration, position, added_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        [
                            .text(playlistId),
                            .text(item.videoId),
                            .text(item.title),
                            .text(item.channelName),
                            .text(item.thumbnailUrl),
                            .double(item.duration),
                            .int(offset),
                            .date(item.addedAt),
                        ]
                    )
                }
            }
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
    }

    /// Appends a video to a playlist. Adding a video already present is a no-op.
    @discardableResult
    func addVideo(
        videoId: String,
        title: String,
        channelName: String,
        thumbnailUrl: String,
        duration: TimeInterval,
        to playlistId: String
    ) -> Bool {
        guard !videoId.isEmpty, !playlistId.isEmpty else { return false }
        if contains(videoId: videoId, in: playlistId) { return false }
        let nextPosition = itemCount(in: playlistId)
        let now = Date()
        database.execute(
            """
            INSERT INTO playlist_items (playlist_id, video_id, title, channel_name, thumbnail_url, duration, position, added_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(playlistId),
                .text(videoId),
                .text(title),
                .text(channelName),
                .text(thumbnailUrl),
                .double(duration),
                .int(nextPosition),
                .date(now),
            ]
        )
        database.execute("UPDATE playlists SET updated_at = ? WHERE playlist_id = ?;", [.date(now), .text(playlistId)])
        FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        return true
    }

    /// Removes a video from a playlist and closes the gap in the ordering.
    func removeVideo(videoId: String, from playlistId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.transaction { transaction in
                transaction.execute(
                    "DELETE FROM playlist_items WHERE playlist_id = ? AND video_id = ?;",
                    [.text(playlistId), .text(videoId)]
                )
                self.renumber(playlistId: playlistId, transaction: transaction)
                transaction.execute(
                    "UPDATE playlists SET updated_at = ? WHERE playlist_id = ?;",
                    [.date(Date()), .text(playlistId)]
                )
            }
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
    }

    /// Removes the item at `rowId`.
    func removeItem(rowId: Int64, from playlistId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.transaction { transaction in
                transaction.execute("DELETE FROM playlist_items WHERE id = ?;", [.integer(rowId)])
                self.renumber(playlistId: playlistId, transaction: transaction)
            }
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
    }

    /// Moves the item at `from` to `to`, rewriting the order in one transaction.
    func moveItem(in playlistId: String, from: Int, to: Int) {
        guard from != to else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            var items = self.items(in: playlistId)
            guard from >= 0, from < items.count, to >= 0, to <= items.count else { return }
            let moved = items.remove(at: from)
            let target = min(to, items.count)
            items.insert(moved, at: target)
            self.database.transaction { transaction in
                for (offset, item) in items.enumerated() {
                    transaction.execute(
                        "UPDATE playlist_items SET position = ? WHERE id = ?;",
                        [.int(offset), .integer(item.rowId)]
                    )
                }
                transaction.execute(
                    "UPDATE playlists SET updated_at = ? WHERE playlist_id = ?;",
                    [.date(Date()), .text(playlistId)]
                )
            }
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
    }

    /// Renames a playlist.
    func renamePlaylist(id: String, title: String) {
        let trimmed = title.trimmed
        guard !trimmed.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                "UPDATE playlists SET title = ?, updated_at = ? WHERE playlist_id = ?;",
                [.text(trimmed), .date(Date()), .text(id)]
            )
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
    }

    /// Changes a playlist's description.
    func updateDescription(id: String, description: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                "UPDATE playlists SET description = ?, updated_at = ? WHERE playlist_id = ?;",
                [.text(description), .date(Date()), .text(id)]
            )
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
    }

    /// Deletes a playlist and all of its items.
    func deletePlaylist(id: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.transaction { transaction in
                transaction.execute("DELETE FROM playlist_items WHERE playlist_id = ?;", [.text(id)])
                transaction.execute("DELETE FROM playlists WHERE playlist_id = ?;", [.text(id)])
            }
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
    }

    /// Deletes every playlist the viewer made, leaving cached remote playlists alone.
    func deleteAllLocalPlaylists() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.transaction { transaction in
                transaction.execute(
                    "DELETE FROM playlist_items WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE is_local = 1);"
                )
                transaction.execute("DELETE FROM playlists WHERE is_local = 1;")
            }
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
    }

    // MARK: - Helpers

    /// Rewrites positions to 0..<count, closing any gaps left by a delete.
    private func renumber(playlistId: String, transaction: FlowDBTransaction) {
        let rows = transaction.query(
            "SELECT id FROM playlist_items WHERE playlist_id = ? ORDER BY position ASC, id ASC;",
            [.text(playlistId)]
        )
        for (offset, row) in rows.enumerated() {
            transaction.execute(
                "UPDATE playlist_items SET position = ? WHERE id = ?;",
                [.int(offset), .integer(row.int64("id"))]
            )
        }
    }
}
