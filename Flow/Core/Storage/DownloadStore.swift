import Foundation

/// Where a download is in its lifecycle. Persisted by its string so a queued download survives a
/// relaunch and resumes as queued.
enum DownloadState: String {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        return self == .queued || self == .downloading
    }

    var isFinished: Bool {
        return self == .completed
    }

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Downloaded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// A downloaded or downloading video. `filePath` is relative to the app's media directory so the
/// record survives the container path changing between launches.
struct DownloadRecord {
    let videoId: String
    let title: String
    let channelName: String
    let thumbnailUrl: String
    let filePath: String
    let audioPath: String
    let quality: String
    let byteSize: Int64
    let duration: TimeInterval
    let state: DownloadState
    let progress: Double
    let createdAt: Date
    let isMusic: Bool

    /// The absolute URL of the downloaded video, or nil for an audio-only download.
    var fileURL: URL? {
        guard !filePath.isEmpty else { return nil }
        return DownloadStore.mediaDirectory.appendingPathComponent(filePath)
    }

    /// The absolute URL of the downloaded audio track, if one was kept separately.
    var audioURL: URL? {
        guard !audioPath.isEmpty else { return nil }
        return DownloadStore.mediaDirectory.appendingPathComponent(audioPath)
    }
}

/// The download queue and its records. The bytes themselves live in the media directory; this store
/// owns the metadata, the state machine and the storage accounting.
final class DownloadStore {

    static let shared = DownloadStore()

    /// The directory every download is written into. Created on first access.
    static var mediaDirectory: URL {
        let support = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: support).appendingPathComponent("Flow/Media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        return directory
    }

    private let database: FlowDB
    private let queue = DispatchQueue(label: "org.flowtube.Flow.downloads", qos: .utility)

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
        markInterruptedDownloads()
    }

    // MARK: - Reading

    /// Every record, newest first.
    func all() -> [DownloadRecord] {
        return database.query("SELECT * FROM downloads ORDER BY created_at DESC;").map(DownloadStore.record(from:))
    }

    /// Records that finished downloading and can be played offline.
    func completed() -> [DownloadRecord] {
        return all().filter { $0.state == .completed }
    }

    /// Records still waiting or in flight.
    func active() -> [DownloadRecord] {
        return all().filter { $0.state.isActive || $0.state == .paused }
    }

    /// One record, if the video was ever queued.
    func record(videoId: String) -> DownloadRecord? {
        guard let row = database.firstRow("SELECT * FROM downloads WHERE video_id = ? LIMIT 1;", [.text(videoId)]) else {
            return nil
        }
        return DownloadStore.record(from: row)
    }

    /// Whether `videoId` is downloaded and playable offline.
    func isDownloaded(videoId: String) -> Bool {
        guard let stored = record(videoId: videoId) else { return false }
        return stored.state == .completed
    }

    /// Whether `videoId` is queued or downloading.
    func isDownloading(videoId: String) -> Bool {
        guard let stored = record(videoId: videoId) else { return false }
        return stored.state.isActive
    }

    /// The total bytes used by completed downloads.
    func storageUsed() -> Int64 {
        let records = completed()
        var total: Int64 = 0
        for item in records {
            total += item.byteSize
        }
        return total
    }

    /// The number of completed downloads.
    var completedCount: Int {
        return database.scalarInt("SELECT COUNT(*) AS value FROM downloads WHERE state = 'completed';")
    }

    // MARK: - Writing

    /// Adds a video to the queue, replacing any failed or cancelled record for it.
    func enqueue(
        videoId: String,
        title: String,
        channelName: String,
        thumbnailUrl: String,
        quality: String,
        duration: TimeInterval,
        isMusic: Bool
    ) {
        guard !videoId.isEmpty else { return }
        let existing = record(videoId: videoId)
        if let current = existing, current.state == .completed || current.state.isActive { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                """
                INSERT INTO downloads
                (video_id, title, channel_name, thumbnail_url, file_path, audio_path, quality, byte_size, duration, state, progress, created_at, is_music)
                VALUES (?, ?, ?, ?, '', '', ?, 0, ?, 'queued', 0, ?, ?)
                ON CONFLICT(video_id) DO UPDATE SET
                    title = excluded.title,
                    channel_name = excluded.channel_name,
                    thumbnail_url = excluded.thumbnail_url,
                    quality = excluded.quality,
                    duration = excluded.duration,
                    state = 'queued',
                    progress = 0,
                    created_at = excluded.created_at,
                    is_music = excluded.is_music;
                """,
                [
                    .text(videoId),
                    .text(title),
                    .text(channelName),
                    .text(thumbnailUrl),
                    .text(quality),
                    .double(duration),
                    .date(Date()),
                    .bool(isMusic),
                ]
            )
            FlowEventBus.shared.broadcast("downloads", notification: .flowDownloadsDidChange, payload: videoId)
        }
    }

    /// Records progress for an in-flight download. Called frequently, so it writes only the two
    /// columns that change.
    func updateProgress(videoId: String, progress: Double, byteSize: Int64) {
        queue.async { [weak self] in
            self?.database.execute(
                "UPDATE downloads SET progress = ?, byte_size = ?, state = 'downloading' WHERE video_id = ?;",
                [.double(min(max(progress, 0.0), 1.0)), .integer(byteSize), .text(videoId)]
            )
        }
    }

    /// Marks a download complete with the files it produced.
    func complete(videoId: String, filePath: String, audioPath: String, byteSize: Int64) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                """
                UPDATE downloads SET
                    file_path = ?,
                    audio_path = ?,
                    byte_size = ?,
                    state = 'completed',
                    progress = 1
                WHERE video_id = ?;
                """,
                [.text(filePath), .text(audioPath), .integer(byteSize), .text(videoId)]
            )
            FlowEventBus.shared.broadcast("downloads", notification: .flowDownloadsDidChange, payload: videoId)
        }
    }

    /// Marks a download failed, keeping the record so the row can offer a retry.
    func fail(videoId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("UPDATE downloads SET state = 'failed' WHERE video_id = ?;", [.text(videoId)])
            FlowEventBus.shared.broadcast("downloads", notification: .flowDownloadsDidChange, payload: videoId)
        }
    }

    /// Pauses a download, keeping its bytes for a later resume.
    func pause(videoId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("UPDATE downloads SET state = 'paused' WHERE video_id = ?;", [.text(videoId)])
            FlowEventBus.shared.broadcast("downloads", notification: .flowDownloadsDidChange, payload: videoId)
        }
    }

    /// Puts a paused download back in the queue.
    func resume(videoId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("UPDATE downloads SET state = 'queued' WHERE video_id = ?;", [.text(videoId)])
            FlowEventBus.shared.broadcast("downloads", notification: .flowDownloadsDidChange, payload: videoId)
        }
    }

    /// Deletes a record and the files it owns.
    func remove(videoId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let stored = self.record(videoId: videoId) {
                DownloadStore.deleteFiles(for: stored)
            }
            self.database.execute("DELETE FROM downloads WHERE video_id = ?;", [.text(videoId)])
            FlowEventBus.shared.broadcast("downloads", notification: .flowDownloadsDidChange, payload: videoId)
        }
    }

    /// Deletes every download and its files.
    func removeAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            for stored in self.all() {
                DownloadStore.deleteFiles(for: stored)
            }
            self.database.execute("DELETE FROM downloads;")
            FlowEventBus.shared.broadcast("downloads", notification: .flowDownloadsDidChange)
        }
    }

    /// The next queued record, for the download manager to pick up.
    func nextQueued() -> DownloadRecord? {
        guard let row = database.firstRow(
            "SELECT * FROM downloads WHERE state = 'queued' ORDER BY created_at ASC LIMIT 1;"
        ) else {
            return nil
        }
        return DownloadStore.record(from: row)
    }

    // MARK: - Helpers

    /// Downloads interrupted by a crash or a force-quit come back as queued, not stuck downloading.
    private func markInterruptedDownloads() {
        database.execute("UPDATE downloads SET state = 'queued' WHERE state = 'downloading';")
    }

    private static func deleteFiles(for record: DownloadRecord) {
        let manager = FileManager.default
        if let url = record.fileURL, manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
        }
        if let url = record.audioURL, manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
        }
    }

    private static func record(from row: FlowDBRow) -> DownloadRecord {
        return DownloadRecord(
            videoId: row.string("video_id"),
            title: row.string("title"),
            channelName: row.string("channel_name"),
            thumbnailUrl: row.string("thumbnail_url"),
            filePath: row.string("file_path"),
            audioPath: row.string("audio_path"),
            quality: row.string("quality"),
            byteSize: row.int64("byte_size"),
            duration: row.double("duration"),
            state: DownloadState(rawValue: row.string("state")) ?? .queued,
            progress: row.double("progress"),
            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
            isMusic: row.bool("is_music")
        )
    }
}
