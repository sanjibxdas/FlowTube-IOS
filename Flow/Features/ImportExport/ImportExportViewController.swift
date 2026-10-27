import UIKit
import Compression

// MARK: - Errors

/// Everything that can go wrong reading a backup or a subscription export, in wording a person can
/// act on. A wrong file must never read as an empty one, so each failure is explicit rather than a
/// zero count.
enum FlowImportError: LocalizedError {
    case unreadableFile
    case notABackup
    case notANewPipeExport
    case corruptArchive(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The file could not be read. It may have been moved, or access to it was refused."
        case .notABackup:
            return "That file isn't a Flow backup. Choose a backup .zip, or the app_data.json inside one."
        case .notANewPipeExport:
            return "That file isn't a NewPipe subscriptions export."
        case .corruptArchive(let detail):
            return detail.isEmpty ? "The archive is damaged." : detail
        case .writeFailed(let detail):
            return detail.isEmpty ? "The file could not be written." : detail
        }
    }
}

// MARK: - CRC-32

/// The checksum ZIP records for every entry. Foundation has no CRC, and the archive the app writes
/// must be readable by other tools, so the table is built here.
enum FlowCRC32 {

    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        return table
    }()

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - ZIP

/// One file inside a ZIP archive.
struct FlowZipEntry {
    let name: String
    let data: Data
}

/// A ZIP writer and reader, limited to what a backup needs.
///
/// Writing uses the "stored" method: the payloads are JSON, already small, and storing them keeps
/// the writer free of a compressor. Reading accepts stored entries and deflated ones, because a
/// backup written by the Android app is deflated, and refusing those would make the port's own
/// files the only ones it could open.
enum FlowZipArchive {

    private static let localSignature: UInt32 = 0x04034B50
    private static let centralSignature: UInt32 = 0x02014B50
    private static let endSignature: UInt32 = 0x06054B50

    /// The largest single entry the reader will inflate, so a hostile archive cannot exhaust memory.
    private static let maximumEntrySize = 64 * 1024 * 1024

    // MARK: - Writing

    static func write(_ entries: [FlowZipEntry]) -> Data {
        var output = Data()
        var central = Data()
        let stamp = dosTimestamp(Date())

        for entry in entries {
            let localOffset = output.count
            let nameBytes = Array(entry.name.utf8)
            let payload = [UInt8](entry.data)
            let crc = FlowCRC32.checksum(payload)

            appendUInt32(localSignature, to: &output)
            appendUInt16(20, to: &output)              // version needed
            appendUInt16(0x0800, to: &output)          // UTF-8 names
            appendUInt16(0, to: &output)               // stored
            appendUInt16(stamp.time, to: &output)
            appendUInt16(stamp.date, to: &output)
            appendUInt32(crc, to: &output)
            appendUInt32(UInt32(payload.count), to: &output)
            appendUInt32(UInt32(payload.count), to: &output)
            appendUInt16(UInt16(nameBytes.count), to: &output)
            appendUInt16(0, to: &output)               // no extra field
            output.append(contentsOf: nameBytes)
            output.append(contentsOf: payload)

            appendUInt32(centralSignature, to: &central)
            appendUInt16(20, to: &central)             // version made by
            appendUInt16(20, to: &central)             // version needed
            appendUInt16(0x0800, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(stamp.time, to: &central)
            appendUInt16(stamp.date, to: &central)
            appendUInt32(crc, to: &central)
            appendUInt32(UInt32(payload.count), to: &central)
            appendUInt32(UInt32(payload.count), to: &central)
            appendUInt16(UInt16(nameBytes.count), to: &central)
            appendUInt16(0, to: &central)              // extra
            appendUInt16(0, to: &central)              // comment
            appendUInt16(0, to: &central)              // disk
            appendUInt16(0, to: &central)              // internal attributes
            appendUInt32(0, to: &central)              // external attributes
            appendUInt32(UInt32(localOffset), to: &central)
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = output.count
        output.append(central)

        appendUInt32(endSignature, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(UInt16(entries.count), to: &output)
        appendUInt16(UInt16(entries.count), to: &output)
        appendUInt32(UInt32(central.count), to: &output)
        appendUInt32(UInt32(centralOffset), to: &output)
        appendUInt16(0, to: &output)
        return output
    }

    // MARK: - Reading

    static func read(_ archive: Data) throws -> [FlowZipEntry] {
        let bytes = [UInt8](archive)
        guard let endOffset = findEndRecord(bytes) else {
            throw FlowImportError.corruptArchive("The archive has no directory. It may be truncated.")
        }
        let entryCount = Int(readUInt16(bytes, endOffset + 10))
        let centralOffset = Int(readUInt32(bytes, endOffset + 16))
        guard entryCount >= 0, centralOffset >= 0, centralOffset <= bytes.count else {
            throw FlowImportError.corruptArchive("The archive's directory is out of range.")
        }

        var entries: [FlowZipEntry] = []
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, readUInt32(bytes, cursor) == centralSignature else {
                throw FlowImportError.corruptArchive("The archive's directory is damaged.")
            }
            let method = readUInt16(bytes, cursor + 10)
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = Int(readUInt32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else {
                throw FlowImportError.corruptArchive("An entry name runs past the end of the archive.")
            }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            guard localOffset + 30 <= bytes.count, readUInt32(bytes, localOffset) == localSignature else {
                throw FlowImportError.corruptArchive("An entry header is damaged.")
            }
            let localNameLength = Int(readUInt16(bytes, localOffset + 26))
            let localExtraLength = Int(readUInt16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart >= 0, compressedSize >= 0, dataStart + compressedSize <= bytes.count else {
                throw FlowImportError.corruptArchive("An entry's contents run past the end of the archive.")
            }
            let payload = Data(bytes[dataStart..<(dataStart + compressedSize)])

            let contents: Data
            switch method {
            case 0:
                contents = payload
            case 8:
                guard uncompressedSize <= maximumEntrySize else {
                    throw FlowImportError.corruptArchive("An entry is too large to open.")
                }
                guard let inflated = inflate(payload, expectedSize: uncompressedSize) else {
                    throw FlowImportError.corruptArchive("An entry could not be decompressed.")
                }
                contents = inflated
            default:
                throw FlowImportError.corruptArchive("The archive uses a compression method Flow can't read.")
            }
            entries.append(FlowZipEntry(name: name, data: contents))
        }
        return entries
    }

    /// Raw DEFLATE, which is what ZIP's method 8 stores. `COMPRESSION_ZLIB` in Apple's framework is
    /// that same raw stream, not a zlib-framed one.
    private static func inflate(_ source: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return source.isEmpty ? Data() : nil }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, expectedSize, base, source.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(output[0..<written])
    }

    // MARK: - Byte helpers

    private static func findEndRecord(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 65535)
        var offset = bytes.count - 22
        while offset >= lowest {
            if readUInt32(bytes, offset) == endSignature {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    /// The DOS date and time pair ZIP stores, in local time.
    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980))
        let month = max(1, min(12, parts.month ?? 1))
        let day = max(1, min(31, parts.day ?? 1))
        let hour = max(0, min(23, parts.hour ?? 0))
        let minute = max(0, min(59, parts.minute ?? 0))
        let second = max(0, min(59, parts.second ?? 0))
        let packedTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let packedDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (packedTime, packedDate)
    }
}

// MARK: - Counts

/// What an import actually changed, collection by collection. The summary screen and the
/// onboarding importer both read these numbers, so they count what was written rather than what was
/// present in the file.
struct FlowBackupCounts {
    var subscriptions = 0
    var history = 0
    var playlists = 0
    var playlistItems = 0
    var notes = 0
    var searchHistory = 0
    var savedShorts = 0
    var settings = 0
    var skipped = 0

    var total: Int {
        return subscriptions + history + playlists + playlistItems + notes + searchHistory + savedShorts + settings
    }

    static func + (left: FlowBackupCounts, right: FlowBackupCounts) -> FlowBackupCounts {
        return FlowBackupCounts(
            subscriptions: left.subscriptions + right.subscriptions,
            history: left.history + right.history,
            playlists: left.playlists + right.playlists,
            playlistItems: left.playlistItems + right.playlistItems,
            notes: left.notes + right.notes,
            searchHistory: left.searchHistory + right.searchHistory,
            savedShorts: left.savedShorts + right.savedShorts,
            settings: left.settings + right.settings,
            skipped: left.skipped + right.skipped
        )
    }

    /// One line per collection that changed, for the result card.
    var summaryLines: [String] {
        var lines: [String] = []
        if subscriptions > 0 { lines.append(plural(subscriptions, "subscription")) }
        if history > 0 { lines.append(plural(history, "watch history entry", plural: "watch history entries")) }
        if playlists > 0 { lines.append(plural(playlists, "playlist")) }
        if playlistItems > 0 { lines.append(plural(playlistItems, "video in a playlist", plural: "videos in playlists")) }
        if notes > 0 { lines.append(plural(notes, "note")) }
        if searchHistory > 0 { lines.append(plural(searchHistory, "search")) }
        if savedShorts > 0 { lines.append(plural(savedShorts, "saved Short")) }
        if settings > 0 { lines.append(plural(settings, "setting")) }
        if skipped > 0 { lines.append(plural(skipped, "item skipped", plural: "items skipped")) }
        return lines
    }

    private func plural(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        let word = count == 1 ? singular : (plural ?? singular + "s")
        return String(count) + " " + word
    }
}

// MARK: - Records

/// One watch-history row in a backup. Times are stored in milliseconds, the unit the Android app's
/// backup uses, so one file can move between the two.
private struct FlowBackupHistoryRecord {
    let videoId: String
    let title: String
    let channelId: String
    let channelName: String
    let thumbnailUrl: String
    let duration: TimeInterval
    let position: TimeInterval
    let watchedAt: Date
    let isMusic: Bool

    init?(dictionary: [String: Any]) {
        guard let videoId = dictionary["videoId"] as? String, !videoId.isEmpty else { return nil }
        self.videoId = videoId
        title = (dictionary["title"] as? String) ?? ""
        channelId = (dictionary["channelId"] as? String) ?? ""
        channelName = (dictionary["channelName"] as? String) ?? ""
        thumbnailUrl = (dictionary["thumbnailUrl"] as? String) ?? ""
        duration = FlowBackupHistoryRecord.seconds(dictionary["duration"])
        position = FlowBackupHistoryRecord.seconds(dictionary["position"])
        watchedAt = Date(timeIntervalSince1970: FlowBackupHistoryRecord.milliseconds(dictionary["timestamp"]) / 1000.0)
        isMusic = (dictionary["isMusic"] as? Bool) ?? false
    }

    init(entry: HistoryEntry) {
        videoId = entry.videoId
        title = entry.title
        channelId = entry.channelId
        channelName = entry.channelName
        thumbnailUrl = entry.thumbnailUrl
        duration = entry.duration
        position = entry.position
        watchedAt = entry.watchedAt
        isMusic = entry.isMusic
    }

    var dictionary: [String: Any] {
        return [
            "videoId": videoId,
            "title": title,
            "channelId": channelId,
            "channelName": channelName,
            "thumbnailUrl": thumbnailUrl,
            "duration": Int((duration * 1000.0).rounded()),
            "position": Int((position * 1000.0).rounded()),
            "timestamp": Int(watchedAt.timeIntervalSince1970 * 1000.0),
            "isMusic": isMusic,
        ]
    }

    /// A duration or position in seconds, from either a millisecond count or a fractional second
    /// count. The Android app writes milliseconds; a file written by this port writes the same, so
    /// the millisecond reading wins whenever it is a whole number large enough to be one.
    static func seconds(_ value: Any?) -> TimeInterval {
        let raw = (value as? NSNumber)?.doubleValue ?? 0.0
        guard raw > 0 else { return 0.0 }
        return raw / 1000.0
    }

    static func milliseconds(_ value: Any?) -> Double {
        return (value as? NSNumber)?.doubleValue ?? 0.0
    }
}

private struct FlowBackupSubscriptionRecord {
    let channelId: String
    let name: String
    let avatarUrl: String
    let subscriberCount: Int
    let subscribedAt: Date
    let notificationsEnabled: Bool

    init?(dictionary: [String: Any]) {
        guard let channelId = dictionary["channelId"] as? String, !channelId.isEmpty else { return nil }
        self.channelId = channelId
        let channelName = (dictionary["channelName"] as? String) ?? ""
        name = channelName.isEmpty ? ((dictionary["name"] as? String) ?? channelId) : channelName
        avatarUrl = (dictionary["channelThumbnail"] as? String) ?? ((dictionary["avatarUrl"] as? String) ?? "")
        subscriberCount = (dictionary["subscriberCount"] as? NSNumber)?.intValue ?? 0
        subscribedAt = Date(timeIntervalSince1970: FlowBackupHistoryRecord.milliseconds(dictionary["subscribedAt"]) / 1000.0)
        notificationsEnabled = (dictionary["isNotificationEnabled"] as? Bool)
            ?? ((dictionary["notificationsEnabled"] as? Bool) ?? true)
    }

    init(subscription: Subscription) {
        channelId = subscription.channelId
        name = subscription.name
        avatarUrl = subscription.avatarUrl
        subscriberCount = subscription.subscriberCount
        subscribedAt = subscription.subscribedAt
        notificationsEnabled = subscription.notificationsEnabled
    }

    var dictionary: [String: Any] {
        return [
            "channelId": channelId,
            "channelName": name,
            "channelThumbnail": avatarUrl,
            "subscriberCount": subscriberCount,
            "subscribedAt": Int(subscribedAt.timeIntervalSince1970 * 1000.0),
            "isNotificationEnabled": notificationsEnabled,
        ]
    }
}

private struct FlowBackupPlaylistItemRecord {
    let videoId: String
    let title: String
    let channelName: String
    let thumbnailUrl: String
    let duration: TimeInterval
    let position: Int
    let addedAt: Date

    init?(dictionary: [String: Any]) {
        guard let videoId = dictionary["videoId"] as? String, !videoId.isEmpty else { return nil }
        self.videoId = videoId
        title = (dictionary["title"] as? String) ?? ""
        channelName = (dictionary["channelName"] as? String) ?? ""
        thumbnailUrl = (dictionary["thumbnailUrl"] as? String) ?? ""
        duration = (dictionary["duration"] as? NSNumber)?.doubleValue ?? 0.0
        position = (dictionary["position"] as? NSNumber)?.intValue ?? 0
        addedAt = Date(timeIntervalSince1970: FlowBackupHistoryRecord.milliseconds(dictionary["addedAt"]) / 1000.0)
    }

    init(entry: PlaylistEntry) {
        videoId = entry.videoId
        title = entry.title
        channelName = entry.channelName
        thumbnailUrl = entry.thumbnailUrl
        duration = entry.duration
        position = entry.position
        addedAt = entry.addedAt
    }

    var dictionary: [String: Any] {
        return [
            "videoId": videoId,
            "title": title,
            "channelName": channelName,
            "thumbnailUrl": thumbnailUrl,
            "duration": duration,
            "position": position,
            "addedAt": Int(addedAt.timeIntervalSince1970 * 1000.0),
        ]
    }
}

private struct FlowBackupPlaylistRecord {
    let title: String
    let description: String
    let thumbnailUrl: String
    let createdAt: Date
    let items: [FlowBackupPlaylistItemRecord]

    init(title: String, description: String, thumbnailUrl: String, createdAt: Date, items: [FlowBackupPlaylistItemRecord]) {
        self.title = title
        self.description = description
        self.thumbnailUrl = thumbnailUrl
        self.createdAt = createdAt
        self.items = items
    }

    init?(dictionary: [String: Any]) {
        let name = (dictionary["name"] as? String) ?? ((dictionary["title"] as? String) ?? "")
        guard !name.isBlank else { return nil }
        title = name
        description = (dictionary["description"] as? String) ?? ""
        thumbnailUrl = (dictionary["thumbnailUrl"] as? String) ?? ""
        createdAt = Date(timeIntervalSince1970: FlowBackupHistoryRecord.milliseconds(dictionary["createdAt"]) / 1000.0)
        let rawItems = (dictionary["items"] as? [[String: Any]]) ?? []
        items = rawItems.compactMap { FlowBackupPlaylistItemRecord(dictionary: $0) }
    }

    init(playlist: StoredPlaylist) {
        title = playlist.title
        description = playlist.description
        thumbnailUrl = playlist.thumbnailUrl
        createdAt = playlist.createdAt
        items = playlist.items.map { FlowBackupPlaylistItemRecord(entry: $0) }
    }

    var dictionary: [String: Any] {
        return [
            "name": title,
            "description": description,
            "thumbnailUrl": thumbnailUrl,
            "createdAt": Int(createdAt.timeIntervalSince1970 * 1000.0),
            "isUserCreated": true,
            "items": items.map { $0.dictionary },
        ]
    }
}

private struct FlowBackupNoteRecord {
    let videoId: String
    let videoTitle: String
    let channelName: String
    let body: String
    let timestamp: TimeInterval
    let updatedAt: Date

    init?(dictionary: [String: Any]) {
        // The Android app calls the video `targetId` and the text `text`; this port writes both
        // spellings so a file can be read by either.
        let target = (dictionary["videoId"] as? String) ?? ((dictionary["targetId"] as? String) ?? "")
        let text = (dictionary["body"] as? String) ?? ((dictionary["text"] as? String) ?? "")
        guard !target.isEmpty, !text.isBlank else { return nil }
        let kind = (dictionary["kind"] as? String) ?? "video"
        // Channel notes have no timestamp and no video to seek in, so they are dropped rather than
        // turned into a note on a video that does not exist.
        guard kind == "video" || kind.isEmpty else { return nil }
        videoId = target
        body = text
        videoTitle = (dictionary["title"] as? String) ?? ((dictionary["videoTitle"] as? String) ?? "")
        channelName = (dictionary["channelName"] as? String) ?? ""
        timestamp = (dictionary["timestampSeconds"] as? NSNumber)?.doubleValue ?? 0.0
        updatedAt = Date(timeIntervalSince1970: FlowBackupHistoryRecord.milliseconds(dictionary["updatedAt"]) / 1000.0)
    }

    init(note: VideoNote) {
        videoId = note.videoId
        videoTitle = note.videoTitle
        channelName = note.channelName
        body = note.body
        timestamp = note.timestamp
        updatedAt = note.updatedAt
    }

    var dictionary: [String: Any] {
        return [
            "id": "video:" + videoId + ":" + String(Int(timestamp * 1000.0)),
            "targetId": videoId,
            "kind": "video",
            "text": body,
            "title": videoTitle,
            "channelName": channelName,
            "videoId": videoId,
            "videoTitle": videoTitle,
            "body": body,
            "timestampSeconds": timestamp,
            "updatedAt": Int(updatedAt.timeIntervalSince1970 * 1000.0),
        ]
    }
}

// MARK: - Archive

/// A complete snapshot of the app's data, and the merge that puts one back.
///
/// The JSON shape follows the Android app's `BackupData` so a backup can move between the two
/// platforms: the same collection names, the same millisecond timestamps. Fields this port needs
/// and Android does not (`timestampSeconds` on a note, `items` on a playlist) are extra keys, which
/// the other side ignores.
struct FlowBackupArchive {

    static let formatVersion = 2
    static let entryName = "app_data.json"

    let exportedAt: Date
    let appVersion: String

    private let history: [FlowBackupHistoryRecord]
    private let subscriptions: [FlowBackupSubscriptionRecord]
    private let playlists: [FlowBackupPlaylistRecord]
    private let notes: [FlowBackupNoteRecord]
    private let searches: [(query: String, at: Date)]
    private let savedShorts: [(videoId: String, title: String, channelName: String, thumbnailUrl: String, savedAt: Date)]
    private let settings: [(key: PrefsStore.Key, kind: String, string: String?, number: Double?, list: [String]?)]

    // MARK: - Snapshot

    /// Reads the live stores into an archive. Runs on the calling thread; call it off the main
    /// queue, because it walks every table.
    static func make() -> FlowBackupArchive {
        let app = FlowApp.shared
        let playlists = app.playlistStore.allPlaylists().map { FlowBackupPlaylistRecord(playlist: $0) }
        let settings: [(key: PrefsStore.Key, kind: String, string: String?, number: Double?, list: [String]?)] =
            FlowBackupArchive.exportedSettings().map { key in
                if let text = app.prefs.string(for: key) {
                    return (key, "string", text, nil, nil)
                }
                if let list = UserDefaults.standard.stringArray(forKey: key.rawValue) {
                    return (key, "list", nil, nil, list)
                }
                guard let number = UserDefaults.standard.object(forKey: key.rawValue) as? NSNumber else {
                    return (key, "missing", nil, nil, nil)
                }
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return (key, "bool", nil, number.doubleValue, nil)
                }
                return (key, "double", nil, number.doubleValue, nil)
            }
        let searches: [(query: String, at: Date)] = SearchHistoryStore.shared.recent(limit: 200).map {
            (query: $0, at: Date())
        }
        let shorts: [(videoId: String, title: String, channelName: String, thumbnailUrl: String, savedAt: Date)] =
            SavedShortsStore.shared.all().map {
                (videoId: $0.videoId, title: $0.title, channelName: $0.channelName,
                 thumbnailUrl: $0.thumbnailUrl, savedAt: $0.savedAt)
            }
        return FlowBackupArchive(
            exportedAt: Date(),
            appVersion: FlowBackupArchive.appVersion(),
            history: app.historyStore.recent(limit: 5000).map { FlowBackupHistoryRecord(entry: $0) },
            subscriptions: app.subscriptionStore.all.map { FlowBackupSubscriptionRecord(subscription: $0) },
            playlists: playlists,
            notes: app.noteStore.all().map { FlowBackupNoteRecord(note: $0) },
            searches: searches,
            savedShorts: shorts,
            settings: settings.filter { $0.kind != "missing" }
        )
    }

    // MARK: - Decoding

    /// Opens a backup file: a `.zip` holding `app_data.json`, or that JSON on its own.
    static func decode(zipData: Data) throws -> FlowBackupArchive {
        // A JSON document starts with `{`; anything else is treated as an archive.
        if let first = zipData.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }), first == 0x7B {
            return try decode(jsonData: zipData)
        }
        let entries: [FlowZipEntry]
        do {
            entries = try FlowZipArchive.read(zipData)
        } catch {
            throw FlowImportError.corruptArchive(error.localizedDescription)
        }
        if let main = entries.first(where: { $0.name == FlowBackupArchive.entryName })
            ?? entries.first(where: { $0.name.hasSuffix("/" + FlowBackupArchive.entryName) }) {
            return try decode(jsonData: main.data)
        }
        // A backup written by an older build may name the file differently. Any JSON entry that
        // carries a collection this archive understands is accepted.
        for entry in entries where entry.name.lowercased().hasSuffix(".json") {
            if let archive = try? decode(jsonData: entry.data) {
                return archive
            }
        }
        throw FlowImportError.notABackup
    }

    static func decode(jsonData: Data) throws -> FlowBackupArchive {
        guard let root = (try? JSONSerialization.jsonObject(with: jsonData, options: [])) as? [String: Any] else {
            throw FlowImportError.notABackup
        }
        let knownKeys = ["viewHistory", "subscriptions", "playlists", "playlistVideos", "notes", "settings"]
        guard knownKeys.contains(where: { root[$0] != nil }) else {
            throw FlowImportError.notABackup
        }

        let history = ((root["viewHistory"] as? [[String: Any]]) ?? []).compactMap { FlowBackupHistoryRecord(dictionary: $0) }
        let subscriptions = ((root["subscriptions"] as? [[String: Any]]) ?? []).compactMap { FlowBackupSubscriptionRecord(dictionary: $0) }
        let notes = ((root["notes"] as? [[String: Any]]) ?? []).compactMap { FlowBackupNoteRecord(dictionary: $0) }

        // Playlist items arrive either inside each playlist (this port's export) or as a flat list
        // of cross-references (the Android export). The flat list has no titles, so it is only used
        // when a playlist carries no items of its own.
        let crossReferences = (root["playlistVideos"] as? [[String: Any]]) ?? []
        var itemsByPlaylist: [String: [FlowBackupPlaylistItemRecord]] = [:]
        for reference in crossReferences {
            guard let playlistId = reference["playlistId"] as? String,
                  let item = FlowBackupPlaylistItemRecord(dictionary: reference) else { continue }
            itemsByPlaylist[playlistId, default: []].append(item)
        }
        var playlists: [FlowBackupPlaylistRecord] = []
        for raw in (root["playlists"] as? [[String: Any]]) ?? [] {
            guard var record = FlowBackupPlaylistRecord(dictionary: raw) else { continue }
            if record.items.isEmpty, let identifier = raw["id"] as? String,
               let referenced = itemsByPlaylist[identifier] {
                record = FlowBackupPlaylistRecord(
                    title: record.title,
                    description: record.description,
                    thumbnailUrl: record.thumbnailUrl,
                    createdAt: record.createdAt,
                    items: referenced.sorted { $0.position < $1.position }
                )
            }
            playlists.append(record)
        }

        let searches: [(query: String, at: Date)] =
            ((root["searchHistory"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let query = entry["query"] as? String, !query.isBlank else { return nil }
                let at = Date(timeIntervalSince1970: FlowBackupHistoryRecord.milliseconds(entry["timestamp"]) / 1000.0)
                return (query: query, at: at)
            }
        let shorts: [(videoId: String, title: String, channelName: String, thumbnailUrl: String, savedAt: Date)] =
            ((root["savedShorts"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let videoId = entry["videoId"] as? String, !videoId.isEmpty else { return nil }
                return (
                    videoId: videoId,
                    title: (entry["title"] as? String) ?? "",
                    channelName: (entry["channelName"] as? String) ?? "",
                    thumbnailUrl: (entry["thumbnailUrl"] as? String) ?? "",
                    savedAt: Date(timeIntervalSince1970: FlowBackupHistoryRecord.milliseconds(entry["savedAt"]) / 1000.0)
                )
            }

        let settings = FlowBackupArchive.decodeSettings(root["settings"] as? [String: Any] ?? [:])
        let exportedAt = Date(timeIntervalSince1970: FlowBackupHistoryRecord.milliseconds(root["timestamp"]) / 1000.0)
        let version = (root["appVersion"] as? String) ?? ""

        return FlowBackupArchive(
            exportedAt: exportedAt,
            appVersion: version,
            history: history,
            subscriptions: subscriptions,
            playlists: playlists,
            notes: notes,
            searches: searches,
            savedShorts: shorts,
            settings: settings
        )
    }

    /// Settings are written as typed maps, which is the shape the Android backup uses.
    private static func decodeSettings(
        _ root: [String: Any]
    ) -> [(key: PrefsStore.Key, kind: String, string: String?, number: Double?, list: [String]?)] {
        var result: [(key: PrefsStore.Key, kind: String, string: String?, number: Double?, list: [String]?)] = []
        let strings = (root["strings"] as? [String: Any]) ?? [:]
        let booleans = (root["booleans"] as? [String: Any]) ?? [:]
        let numbers = (root["doubles"] as? [String: Any]) ?? [:]
        let integers = (root["ints"] as? [String: Any]) ?? [:]
        let floats = (root["floats"] as? [String: Any]) ?? [:]
        let longs = (root["longs"] as? [String: Any]) ?? [:]

        let lists = (root["lists"] as? [String: Any]) ?? [:]

        for key in exportedSettings() {
            if let value = strings[key.rawValue] as? String {
                result.append((key: key, kind: "string", string: value, number: nil, list: nil))
            } else if let value = lists[key.rawValue] as? [String] {
                result.append((key: key, kind: "list", string: nil, number: nil, list: value))
            } else if let value = booleans[key.rawValue] as? NSNumber {
                result.append((key: key, kind: "bool", string: nil, number: value.doubleValue, list: nil))
            } else if let value = numbers[key.rawValue] as? NSNumber {
                result.append((key: key, kind: "double", string: nil, number: value.doubleValue, list: nil))
            } else if let value = floats[key.rawValue] as? NSNumber {
                result.append((key: key, kind: "double", string: nil, number: value.doubleValue, list: nil))
            } else if let value = integers[key.rawValue] as? NSNumber {
                result.append((key: key, kind: "double", string: nil, number: value.doubleValue, list: nil))
            } else if let value = longs[key.rawValue] as? NSNumber {
                result.append((key: key, kind: "double", string: nil, number: value.doubleValue, list: nil))
            }
        }
        return result
    }

    // MARK: - Encoding

    /// The archive as the JSON document both apps read.
    func encodedJSON() -> Data {
        var strings: [String: String] = [:]
        var booleans: [String: Bool] = [:]
        var numbers: [String: Double] = [:]
        var lists: [String: [String]] = [:]
        for setting in settings {
            switch setting.kind {
            case "string":
                if let value = setting.string { strings[setting.key.rawValue] = value }
            case "list":
                if let value = setting.list { lists[setting.key.rawValue] = value }
            case "bool":
                if let value = setting.number { booleans[setting.key.rawValue] = value != 0 }
            case "double":
                if let value = setting.number { numbers[setting.key.rawValue] = value }
            default:
                break
            }
        }

        let root: [String: Any] = [
            "version": FlowBackupArchive.formatVersion,
            "appVersion": appVersion,
            "timestamp": Int(exportedAt.timeIntervalSince1970 * 1000.0),
            "viewHistory": history.map { $0.dictionary },
            "subscriptions": subscriptions.map { $0.dictionary },
            "playlists": playlists.map { $0.dictionary },
            "playlistVideos": playlists.flatMap { playlist in
                playlist.items.map { item in
                    [
                        "playlistId": playlist.title,
                        "videoId": item.videoId,
                        "position": item.position,
                        "addedAt": Int(item.addedAt.timeIntervalSince1970 * 1000.0),
                    ] as [String: Any]
                }
            },
            "notes": notes.map { $0.dictionary },
            "searchHistory": searches.map { entry in
                [
                    "query": entry.query,
                    "timestamp": Int(entry.at.timeIntervalSince1970 * 1000.0),
                ] as [String: Any]
            },
            "savedShorts": savedShorts.map { short in
                [
                    "videoId": short.videoId,
                    "title": short.title,
                    "channelName": short.channelName,
                    "thumbnailUrl": short.thumbnailUrl,
                    "savedAt": Int(short.savedAt.timeIntervalSince1970 * 1000.0),
                ] as [String: Any]
            },
            "settings": [
                "strings": strings,
                "booleans": booleans,
                "doubles": numbers,
                "lists": lists,
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return Data("{}".utf8)
        }
        return data
    }

    /// The archive as a ZIP holding one JSON document.
    func encodedZip() -> Data {
        return FlowZipArchive.write([FlowZipEntry(name: FlowBackupArchive.entryName, data: encodedJSON())])
    }

    // MARK: - Applying

    /// Writes the archive into the stores.
    ///
    /// With `merge` the archive adds what is missing and refreshes what it knows; without it the
    /// archive replaces each collection it carries. Collections the file does not mention are left
    /// alone either way, so a partial backup never wipes data it never had.
    ///
    /// `progress` is called on the calling thread with a fraction and a stage name, so a screen can
    /// show which collection is being written rather than an unchanging spinner.
    func apply(merge: Bool, progress: ((Double, String) -> Void)? = nil) -> FlowBackupCounts {
        var counts = FlowBackupCounts()
        let app = FlowApp.shared
        let stages: [(String, () -> FlowBackupCounts)] = [
            ("Subscriptions", { FlowBackupArchive.applySubscriptions(self.subscriptions, merge: merge) }),
            ("Watch history", { FlowBackupArchive.applyHistory(self.history, merge: merge) }),
            ("Playlists", { FlowBackupArchive.applyPlaylists(self.playlists, merge: merge) }),
            ("Notes", { FlowBackupArchive.applyNotes(self.notes, merge: merge) }),
            ("Search history", { FlowBackupArchive.applySearches(self.searches, merge: merge) }),
            ("Saved Shorts", { FlowBackupArchive.applyShorts(self.savedShorts, merge: merge) }),
            ("Settings", { FlowBackupArchive.applySettings(self.settings) }),
        ]

        for (index, stage) in stages.enumerated() {
            progress?(Double(index) / Double(stages.count), stage.0)
            counts = counts + stage.1()
        }
        progress?(1.0, "Finishing")

        app.prefs.set(Date(), for: .lastSyncAt)
        return counts
    }

    private static func applySubscriptions(_ records: [FlowBackupSubscriptionRecord], merge: Bool) -> FlowBackupCounts {
        var counts = FlowBackupCounts()
        guard !records.isEmpty else { return counts }
        let store = FlowApp.shared.subscriptionStore
        if !merge {
            store.clear()
        }
        for record in records {
            if merge && store.isSubscribed(record.channelId) {
                counts.skipped += 1
                continue
            }
            store.subscribe(
                channelId: record.channelId,
                name: record.name,
                avatarUrl: record.avatarUrl,
                subscriberCount: record.subscriberCount
            )
            counts.subscriptions += 1
        }
        return counts
    }

    private static func applyHistory(_ records: [FlowBackupHistoryRecord], merge: Bool) -> FlowBackupCounts {
        var counts = FlowBackupCounts()
        guard !records.isEmpty else { return counts }
        let store = FlowApp.shared.historyStore
        // Paused history refuses writes by design, and clearing first would then leave the viewer
        // with neither their old history nor the imported one. Saying so beats reporting a count
        // that never reached the table.
        guard !FlowApp.shared.prefs.historyPaused else {
            counts.skipped += records.count
            return counts
        }
        if !merge {
            store.clear()
        }
        for record in records {
            if merge && store.contains(videoId: record.videoId) {
                counts.skipped += 1
                continue
            }
            store.record(
                videoId: record.videoId,
                title: record.title,
                channelId: record.channelId,
                channelName: record.channelName,
                thumbnailUrl: record.thumbnailUrl,
                duration: record.duration,
                position: record.position,
                isMusic: record.isMusic,
                watchedAt: record.watchedAt
            )
            counts.history += 1
        }
        return counts
    }

    private static func applyPlaylists(_ records: [FlowBackupPlaylistRecord], merge: Bool) -> FlowBackupCounts {
        var counts = FlowBackupCounts()
        guard !records.isEmpty else { return counts }
        let store = FlowApp.shared.playlistStore
        if !merge {
            // `deleteAllLocalPlaylists` runs on the store's own queue while `createPlaylist` writes
            // synchronously, so calling one after the other could create the imported playlists
            // before the delete lands and lose them. The delete is therefore issued directly, and
            // the store is told to refresh its listeners afterwards.
            FlowDB.shared.transaction { transaction in
                transaction.execute(
                    "DELETE FROM playlist_items WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE is_local = 1);"
                )
                transaction.execute("DELETE FROM playlists WHERE is_local = 1;")
            }
            FlowEventBus.shared.broadcast("playlists", notification: .flowPlaylistsDidChange)
        }
        let existing = store.allPlaylists()
        for record in records {
            let match = merge
                ? existing.first { $0.title.caseInsensitiveCompare(record.title) == .orderedSame }
                : nil
            let playlistId: String
            if let match = match {
                playlistId = match.playlistId
                counts.skipped += 1
            } else {
                playlistId = store.createPlaylist(title: record.title, description: record.description)
                counts.playlists += 1
            }
            for item in record.items {
                let inserted = store.addVideo(
                    videoId: item.videoId,
                    title: item.title,
                    channelName: item.channelName,
                    thumbnailUrl: item.thumbnailUrl,
                    duration: item.duration,
                    to: playlistId
                )
                if inserted {
                    counts.playlistItems += 1
                } else {
                    counts.skipped += 1
                }
            }
        }
        return counts
    }

    private static func applyNotes(_ records: [FlowBackupNoteRecord], merge: Bool) -> FlowBackupCounts {
        var counts = FlowBackupCounts()
        guard !records.isEmpty else { return counts }
        let store = FlowApp.shared.noteStore
        if !merge {
            // Same queue mismatch as playlists: `deleteAll` is queued while `create` writes
            // synchronously, so the delete is issued directly and the event re-broadcast.
            FlowDB.shared.execute("DELETE FROM notes;")
            FlowEventBus.shared.broadcast("notes", notification: .flowNotesDidChange)
        }
        let existing = merge ? store.all() : []
        for record in records {
            if merge && existing.contains(where: { note in
                note.videoId == record.videoId
                    && note.body == record.body.trimmed
                    && abs(note.timestamp - record.timestamp) < 1.0
            }) {
                counts.skipped += 1
                continue
            }
            store.create(
                videoId: record.videoId,
                videoTitle: record.videoTitle,
                channelName: record.channelName,
                body: record.body,
                timestamp: record.timestamp
            )
            counts.notes += 1
        }
        return counts
    }

    private static func applySearches(_ records: [(query: String, at: Date)], merge: Bool) -> FlowBackupCounts {
        var counts = FlowBackupCounts()
        guard !records.isEmpty else { return counts }
        let store = SearchHistoryStore.shared
        if !merge {
            store.clear()
        }
        let known = Set(store.recent(limit: 200))
        for record in records {
            if known.contains(record.query) {
                counts.skipped += 1
                continue
            }
            store.record(record.query)
            counts.searchHistory += 1
        }
        return counts
    }

    private static func applyShorts(
        _ records: [(videoId: String, title: String, channelName: String, thumbnailUrl: String, savedAt: Date)],
        merge: Bool
    ) -> FlowBackupCounts {
        var counts = FlowBackupCounts()
        guard !records.isEmpty else { return counts }
        let store = SavedShortsStore.shared
        if !merge {
            FlowDB.shared.execute("DELETE FROM saved_shorts;")
            FlowEventBus.shared.broadcast("shorts", notification: .flowHistoryDidChange)
        }
        for record in records {
            if store.contains(videoId: record.videoId) {
                counts.skipped += 1
                continue
            }
            store.toggle(
                videoId: record.videoId,
                title: record.title,
                channelName: record.channelName,
                thumbnailUrl: record.thumbnailUrl
            )
            counts.savedShorts += 1
        }
        return counts
    }

    private static func applySettings(_ records: [(key: PrefsStore.Key, kind: String, string: String?, number: Double?)]) -> FlowBackupCounts {
        var counts = FlowBackupCounts()
        let prefs = FlowApp.shared.prefs
        for record in records {
            switch record.kind {
            case "string":
                guard let value = record.string else { continue }
                if prefs.string(for: record.key) == value {
                    counts.skipped += 1
                } else {
                    prefs.set(value, for: record.key)
                    counts.settings += 1
                }
            case "bool":
                guard let value = record.number else { continue }
                let flag = value != 0
                if prefs.bool(for: record.key, fallback: !flag) == flag {
                    counts.skipped += 1
                } else {
                    prefs.set(flag, for: record.key)
                    counts.settings += 1
                }
            case "double":
                guard let value = record.number else { continue }
                if abs(prefs.double(for: record.key, fallback: value + 1.0) - value) < 0.0001 {
                    counts.skipped += 1
                } else {
                    prefs.set(value, for: record.key)
                    counts.settings += 1
                }
            default:
                break
            }
        }
        return counts
    }

    // MARK: - Shared

    /// How many items each collection holds, for the export summary.
    var subscriptionCount: Int { return subscriptions.count }
    var historyCount: Int { return history.count }
    var playlistCount: Int { return playlists.count }
    var playlistItemCount: Int { return playlists.reduce(0) { $0 + $1.items.count } }
    var noteCount: Int { return notes.count }
    var searchCount: Int { return searches.count }
    var shortCount: Int { return savedShorts.count }
    var settingCount: Int { return settings.count }

    /// The preferences a backup carries. Account state (visitor data, cookies) is deliberately
    /// excluded: it belongs to a session, not to the viewer, and restoring it on another device
    /// would be a lie about who is signed in.
    static func exportedSettings() -> [PrefsStore.Key] {
        return [
            .themeMode, .themeVariant, .fontFamily,
            .playbackQuality, .playbackSpeed, .backgroundPlayback, .pictureInPicture,
            .autoplayNext, .resumePlayback, .audioOnlyOnCellular, .preferredAudioLanguage,
            .sleepTimerMinutes,
            .downloadQuality, .downloadWifiOnly, .downloadAudioOnly,
            .sponsorBlockEnabled, .sponsorBlockAutoSkip, .sponsorBlockCategories,
            .sponsorBlockShowOnSeekBar, .sponsorBlockNotifyOnSkip,
            .deArrowEnabled, .deArrowTitles, .deArrowThumbnails,
            .returnYouTubeDislikeEnabled,
            .subtitlesEnabled, .subtitleLanguage, .subtitleFontScale, .subtitleTextColor,
            .subtitleBackgroundOpacity,
            .historyPaused, .recommendationsEnabled, .sendUsageData, .searchHistoryEnabled,
            .gridItemSize, .showShortsShelf,
        ]
    }

    private static func appVersion() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return short + " (" + build + ")"
    }
}

// MARK: - NewPipe

/// NewPipe's subscription export:
/// `{app_version, app_version_int, subscriptions: [{service_id, url, name}]}`.
///
/// Only YouTube entries (`service_id` 0) are read. A `/channel/UC…` URL yields the channel id
/// directly; an `@handle` or a `/user/` or `/c/` link has to be looked up, so it is returned
/// unresolved and the importer resolves it through search.
enum NewPipeSubscriptionCodec {

    struct Entry {
        /// The channel id, when the URL named one.
        let channelId: String?
        /// The `@handle`, when the URL named one.
        let handle: String?
        /// A `/user/` or `/c/` URL, which only a search can turn into a channel.
        let legacyUrl: String?
        let name: String

        var isResolved: Bool {
            return !(channelId ?? "").isEmpty
        }
    }

    private static let youtubeServiceId = 0
    private static let youtubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
    ]

    /// Reads an export. Throws when the file is not a NewPipe export at all, so a wrong file never
    /// reads as an empty list.
    static func decode(data: Data) throws -> [Entry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let items = root["subscriptions"] as? [[String: Any]] else {
            throw FlowImportError.notANewPipeExport
        }

        var entries: [Entry] = []
        var seen: Set<String> = []
        for item in items {
            let service = (item["service_id"] as? NSNumber)?.intValue ?? youtubeServiceId
            guard service == youtubeServiceId else { continue }
            let url = (item["url"] as? String) ?? ""
            let name = ((item["name"] as? String) ?? "").trimmed
            guard let parsed = parse(url: url) else { continue }
            let key = parsed.channelId ?? parsed.handle ?? parsed.legacyUrl ?? ""
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            entries.append(Entry(
                channelId: parsed.channelId,
                handle: parsed.handle,
                legacyUrl: parsed.legacyUrl,
                name: name
            ))
        }
        return entries
    }

    /// Writes this device's subscriptions in NewPipe's format. Channels whose id is neither a `UC`
    /// id nor an `@handle` cannot be opened by NewPipe, so they are counted as skipped.
    static func encode(subscriptions: [Subscription]) -> (json: String, skipped: Int) {
        var items: [[String: Any]] = []
        var skipped = 0
        for subscription in subscriptions {
            let id = subscription.channelId.trimmed
            let url: String
            if isChannelId(id) {
                url = "https://www.youtube.com/channel/" + id
            } else if id.hasPrefix("@") && isHandle(String(id.dropFirst())) {
                url = "https://www.youtube.com/" + id
            } else {
                skipped += 1
                continue
            }
            let name = subscription.name.isBlank ? id : subscription.name.trimmed
            items.append(["service_id": youtubeServiceId, "url": url, "name": name])
        }
        let root: [String: Any] = [
            "app_version": appVersionString(),
            "app_version_int": appVersionInt(),
            "subscriptions": items,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}", skipped)
    }

    // MARK: - Parsing

    private struct ParsedURL {
        let channelId: String?
        let handle: String?
        let legacyUrl: String?
    }

    private static func parse(url: String) -> ParsedURL? {
        let trimmed = url.trimmed
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate) else { return nil }
        let host = (components.host ?? "").lowercased()
        guard youtubeHosts.contains(host) else { return nil }
        let segments = components.path
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
        guard let first = segments.first else { return nil }
        let second = segments.count > 1 ? segments[1] : nil

        if first == "channel", let id = second, isChannelId(id) {
            return ParsedURL(channelId: id, handle: nil, legacyUrl: nil)
        }
        if first.hasPrefix("@") {
            let handle = String(first.dropFirst())
            guard isHandle(handle) else { return nil }
            return ParsedURL(channelId: nil, handle: handle, legacyUrl: nil)
        }
        if (first == "user" || first == "c"), let name = second, !name.isBlank {
            return ParsedURL(channelId: nil, handle: nil, legacyUrl: "https://www.youtube.com/" + first + "/" + name)
        }
        return nil
    }

    /// A `UC` id is a `UC` prefix and 22 URL-safe characters, which is what YouTube issues.
    static func isChannelId(_ value: String) -> Bool {
        guard value.count == 24, value.hasPrefix("UC") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isHandle(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func appVersionString() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static func appVersionInt() -> Int {
        guard let text = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return 1 }
        return Int(text) ?? 1
    }
}

// MARK: - Row

/// One import source or export action: an icon, a name, a sentence about what it does and a button.
final class ImportExportRow: UIView {

    private let iconContainer = UIView()
    private let iconView = FlowIconView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    let button = FlowButton()

    init(icon: FlowIcon, title: String, detail: String, buttonTitle: String, style: FlowButtonStyle) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.configure(title: buttonTitle, style: style, icon: nil)

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 20.0
        iconContainer.layer.masksToBounds = true
        addSubview(iconContainer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.icon = icon
        iconView.iconSize = 20.0
        iconContainer.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleMedium
        titleLabel.numberOfLines = 2
        titleLabel.text = title
        addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 3
        detailLabel.text = detail
        addSubview(detailLabel)

        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconContainer.topAnchor.constraint(equalTo: topAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 40.0),
            iconContainer.heightAnchor.constraint(equalToConstant: 40.0),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: iconContainer.topAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),

            button.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            button.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: FlowSpacing.md),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 44.0),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        iconContainer.backgroundColor = scheme.surfaceContainerHigh
        iconView.iconColor = scheme.primary
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        button.applyTheme()
    }
}

// MARK: - Screen

/// Import and export. Two directions, four formats: a Flow backup that carries everything, a NewPipe
/// subscription list that carries one thing, and the same two the other way round.
final class ImportExportViewController: UIViewController {

    // MARK: - Types

    private enum ImportKind {
        case backup
        case newPipe
    }

    private enum WorkState {
        case idle
        case working(String, Double)
        case finished(title: String, lines: [String], detail: String)
        case failed(String)
    }

    // MARK: - Views

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let introLabel = UILabel()

    private let exportCard = FlowCard.make(elevation: .standard)
    private let exportTitle = UILabel()
    private let exportDetail = UILabel()
    private let exportButton = FlowButton.make("Export a backup", style: .filled, icon: .exportIcon)
    private let exportMeta = UILabel()
    private let newPipeExportButton = FlowButton.make("Export subscriptions for NewPipe", style: .text, icon: .exportIcon)

    private let importCard = FlowCard.make(elevation: .standard)
    private let importTitle = UILabel()
    private let backupRow = ImportExportRow(
        icon: .importIcon,
        title: "Flow backup",
        detail: "Everything this device knows: subscriptions, history, playlists, notes and settings.",
        buttonTitle: "Choose a backup",
        style: .tonal
    )
    private let newPipeRow = ImportExportRow(
        icon: .subscriptions,
        title: "NewPipe subscriptions",
        detail: "A subscriptions.json exported from NewPipe. Channels with a handle are looked up.",
        buttonTitle: "Choose a file",
        style: .outlined
    )

    private let progressCard = FlowCard.make(elevation: .standard)
    private let progressLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let progressDetail = UILabel()

    private let resultCard = FlowCard.make(elevation: .high)
    private let resultTitle = UILabel()
    private let resultBody = UILabel()
    private let resultDetail = UILabel()
    private let resultButton = FlowButton.make("Done", style: .filled)

    // MARK: - State

    private let workQueue = DispatchQueue(label: "org.flowtube.Flow.importExport", qos: .userInitiated)
    private var themeToken: ObservationToken?
    private var pendingImport: ImportKind = .backup
    private var isWorking = false
    private var lastExportURL: URL?

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Import & export"
        view.backgroundColor = FlowTheme.shared.background
        buildLayout()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        show(.idle)
        refreshExportMeta()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = FlowSpacing.lg
        scrollView.addSubview(contentStack)

        introLabel.font = FlowTypography.bodyMedium
        introLabel.numberOfLines = 0
        introLabel.text = "Your data is yours. Take it with you, or bring it from another app — nothing leaves the device unless you share it."
        contentStack.addArrangedSubview(introLabel)

        buildExportCard()
        buildImportCard()
        buildProgressCard()
        buildResultCard()

        contentStack.addArrangedSubview(exportCard)
        contentStack.addArrangedSubview(importCard)
        contentStack.addArrangedSubview(progressCard)
        contentStack.addArrangedSubview(resultCard)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.screenMargin),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: FlowSpacing.md),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -FlowSpacing.xxl),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -FlowSpacing.screenMargin * 2.0),
        ])
    }

    private func buildExportCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        exportCard.contentView.addSubview(stack)

        exportTitle.font = FlowTypography.titleLarge
        exportTitle.text = "Export"
        exportDetail.font = FlowTypography.bodyMedium
        exportDetail.numberOfLines = 3
        exportDetail.text = "A backup is a single .zip in this app's Documents folder. Share it to Files, iCloud Drive or another device."

        exportMeta.font = FlowTypography.bodySmall
        exportMeta.numberOfLines = 2

        exportButton.onTap = { [weak self] in
            self?.exportBackup()
        }
        newPipeExportButton.onTap = { [weak self] in
            self?.exportNewPipeSubscriptions()
        }

        stack.addArrangedSubview(exportTitle)
        stack.addArrangedSubview(exportDetail)
        stack.addArrangedSubview(exportButton)
        stack.addArrangedSubview(exportMeta)
        stack.addArrangedSubview(newPipeExportButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: exportCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: exportCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: exportCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: exportCard.contentView.bottomAnchor),
            exportButton.heightAnchor.constraint(equalToConstant: 48.0),
        ])
    }

    private func buildImportCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        importCard.contentView.addSubview(stack)

        importTitle.font = FlowTypography.titleLarge
        importTitle.text = "Import"

        backupRow.button.onTap = { [weak self] in
            self?.chooseFile(for: .backup)
        }
        newPipeRow.button.onTap = { [weak self] in
            self?.chooseFile(for: .newPipe)
        }

        stack.addArrangedSubview(importTitle)
        stack.addArrangedSubview(backupRow)
        stack.addArrangedSubview(newPipeRow)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: importCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: importCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: importCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: importCard.contentView.bottomAnchor),
        ])
    }

    private func buildProgressCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressCard.contentView.addSubview(stack)

        progressLabel.font = FlowTypography.titleSmall
        progressLabel.numberOfLines = 2
        progressDetail.font = FlowTypography.bodySmall
        progressDetail.numberOfLines = 2

        stack.addArrangedSubview(progressLabel)
        stack.addArrangedSubview(progressBar)
        stack.addArrangedSubview(progressDetail)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: progressCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: progressCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: progressCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: progressCard.contentView.bottomAnchor),
        ])
    }

    private func buildResultCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        resultCard.contentView.addSubview(stack)

        resultTitle.font = FlowTypography.titleLarge
        resultTitle.numberOfLines = 2
        resultBody.font = FlowTypography.bodyMedium
        resultBody.numberOfLines = 12
        resultDetail.font = FlowTypography.bodySmall
        resultDetail.numberOfLines = 3
        resultButton.onTap = { [weak self] in
            self?.show(.idle)
        }

        stack.addArrangedSubview(resultTitle)
        stack.addArrangedSubview(resultBody)
        stack.addArrangedSubview(resultDetail)
        stack.addArrangedSubview(resultButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: resultCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: resultCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: resultCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: resultCard.contentView.bottomAnchor),
            resultButton.heightAnchor.constraint(equalToConstant: 48.0),
        ])
    }

    // MARK: - Export

    private func exportBackup() {
        guard !isWorking else { return }
        show(.working("Collecting your data…", 0.05))
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let archive = FlowBackupArchive.make()
            DispatchQueue.main.async {
                self.show(.working("Writing the archive…", 0.4))
            }
            let data = archive.encodedZip()
            guard let url = self.write(data: data, name: "flow_master_backup_" + ImportExportViewController.stamp() + ".zip") else {
                DispatchQueue.main.async {
                    self.show(.failed("The backup could not be written to this app's Documents folder."))
                }
                return
            }
            let size = Int64(data.count)
            let counts = FlowBackupCounts(
                subscriptions: archive.subscriptionCount,
                history: archive.historyCount,
                playlists: archive.playlistCount,
                playlistItems: archive.playlistItemCount,
                notes: archive.noteCount,
                searchHistory: archive.searchCount,
                savedShorts: archive.shortCount,
                settings: archive.settingCount
            )
            DispatchQueue.main.async {
                self.lastExportURL = url
                self.refreshExportMeta()
                self.show(.finished(
                    title: "Backup ready",
                    lines: counts.summaryLines,
                    detail: url.lastPathComponent + " · " + Formatters.fileSize(size)
                ))
                self.presentShare(url: url, sourceView: self.exportButton)
            }
        }
    }

    private func exportNewPipeSubscriptions() {
        guard !isWorking else { return }
        let subscriptions = FlowApp.shared.subscriptionStore.all
        guard !subscriptions.isEmpty else {
            FlowSnackbar.showError("There are no subscriptions to export yet")
            return
        }
        show(.working("Writing subscriptions…", 0.3))
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let export = NewPipeSubscriptionCodec.encode(subscriptions: subscriptions)
            guard let data = export.json.data(using: .utf8),
                  let url = self.write(data: data, name: "newpipe_subscriptions_" + ImportExportViewController.stamp() + ".json") else {
                DispatchQueue.main.async {
                    self.show(.failed("The subscription file could not be written."))
                }
                return
            }
            let detail = export.skipped > 0
                ? String(export.skipped) + " channel(s) skipped: NewPipe can only open UC ids and handles."
                : url.lastPathComponent
            DispatchQueue.main.async {
                self.show(.finished(
                    title: "Subscriptions exported",
                    lines: [String(subscriptions.count - export.skipped) + " subscriptions written"],
                    detail: detail
                ))
                self.presentShare(url: url, sourceView: self.newPipeExportButton)
            }
        }
    }

    private func write(data: Data, name: String) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private func presentShare(url: URL, sourceView: UIView) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView
        activity.popoverPresentationController?.sourceRect = sourceView.bounds
        present(activity, animated: true, completion: nil)
    }

    private func refreshExportMeta() {
        if let url = lastExportURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            exportMeta.text = "Last export: " + url.lastPathComponent + " · " + Formatters.fileSize(size.int64Value)
        } else {
            exportMeta.text = "Backups are kept in the app's Documents folder, visible in Files under On My iPhone › Flow."
        }
    }

    // MARK: - Import

    private func chooseFile(for kind: ImportKind) {
        guard !isWorking else { return }
        pendingImport = kind
        let types = kind == .backup
            ? ["public.zip-archive", "public.json", "public.data"]
            : ["public.json", "public.text"]
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true, completion: nil)
    }

    private func beginImport(from url: URL) {
        let kind = pendingImport
        show(.working("Reading the file…", 0.05))
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                DispatchQueue.main.async {
                    self.show(.failed(FlowImportError.unreadableFile.errorDescription ?? "The file could not be read."))
                }
                return
            }

            switch kind {
            case .backup:
                self.importBackup(data: data, fileName: url.lastPathComponent)
            case .newPipe:
                self.importNewPipe(data: data, fileName: url.lastPathComponent)
            }
        }
    }

    private func importBackup(data: Data, fileName: String) {
        let archive: FlowBackupArchive
        do {
            archive = try FlowBackupArchive.decode(zipData: data)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DispatchQueue.main.async {
                self.show(.failed(message))
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.askMergeMode(fileName: fileName) { merge in
                self?.apply(archive: archive, merge: merge, fileName: fileName)
            }
        }
    }

    private func apply(archive: FlowBackupArchive, merge: Bool, fileName: String) {
        show(.working("Importing…", 0.1))
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let counts = archive.apply(merge: merge) { fraction, stage in
                DispatchQueue.main.async {
                    self.show(.working(stage + "…", 0.1 + fraction * 0.85))
                }
            }
            DispatchQueue.main.async {
                self.show(.finished(
                    title: merge ? "Merged into this device" : "Replaced with the backup",
                    lines: counts.summaryLines.isEmpty ? ["Nothing needed to change."] : counts.summaryLines,
                    detail: fileName
                ))
                FlowEventBus.shared.post("prefs")
            }
        }
    }

    private func importNewPipe(data: Data, fileName: String) {
        let entries: [NewPipeSubscriptionCodec.Entry]
        do {
            entries = try NewPipeSubscriptionCodec.decode(data: data)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DispatchQueue.main.async {
                self.show(.failed(message))
            }
            return
        }
        guard !entries.isEmpty else {
            DispatchQueue.main.async {
                self.show(.failed("The file lists no YouTube channels Flow can import."))
            }
            return
        }

        let store = FlowApp.shared.subscriptionStore
        var imported = 0
        var skipped = 0
        var unresolved = 0
        var pending: [NewPipeSubscriptionCodec.Entry] = []

        for entry in entries {
            if let channelId = entry.channelId, !channelId.isEmpty {
                if store.isSubscribed(channelId) {
                    skipped += 1
                    continue
                }
                store.subscribe(
                    channelId: channelId,
                    name: entry.name.isEmpty ? channelId : entry.name,
                    avatarUrl: "",
                    subscriberCount: 0
                )
                imported += 1
            } else {
                pending.append(entry)
            }
        }

        guard !pending.isEmpty else {
            DispatchQueue.main.async {
                self.finishNewPipeImport(imported: imported, skipped: skipped, unresolved: 0, fileName: fileName)
            }
            return
        }

        // A handle or a legacy /user/ link has no channel id in the file. YouTube is the only thing
        // that can map one, so each is searched for and the first channel result is followed.
        resolveSequentially(pending, index: 0, imported: imported, skipped: skipped, unresolved: 0) { imported, skipped, unresolved in
            DispatchQueue.main.async {
                self.finishNewPipeImport(imported: imported, skipped: skipped, unresolved: unresolved, fileName: fileName)
            }
        }
    }

    private func resolveSequentially(
        _ entries: [NewPipeSubscriptionCodec.Entry],
        index: Int,
        imported: Int,
        skipped: Int,
        unresolved: Int,
        completion: @escaping (Int, Int, Int) -> Void
    ) {
        guard index < entries.count else {
            completion(imported, skipped, unresolved)
            return
        }
        let entry = entries[index]
        let query = entry.handle.map { "@" + $0 } ?? entry.name
        let total = entries.count
        DispatchQueue.main.async { [weak self] in
            self?.show(.working("Looking up " + String(index + 1) + " of " + String(total) + "…", 0.15))
        }

        guard !query.isBlank else {
            resolveSequentially(entries, index: index + 1, imported: imported, skipped: skipped, unresolved: unresolved + 1, completion: completion)
            return
        }

        FlowApp.shared.youtubeAPI.search(query: query, filter: .channels) { result in
            var nextImported = imported
            var nextSkipped = skipped
            var nextUnresolved = unresolved
            switch result {
            case .success(let results):
                if let channel = results.channels.first {
                    let store = FlowApp.shared.subscriptionStore
                    if store.isSubscribed(channel.id) {
                        nextSkipped += 1
                    } else {
                        store.subscribe(
                            channelId: channel.id,
                            name: channel.name.isEmpty ? (entry.name.isEmpty ? channel.id : entry.name) : channel.name,
                            avatarUrl: channel.thumbnailUrl,
                            subscriberCount: Int(min(channel.subscriberCount, Int64(Int.max)))
                        )
                        nextImported += 1
                    }
                } else {
                    nextUnresolved += 1
                }
            case .failure:
                nextUnresolved += 1
            }
            self.resolveSequentially(
                entries,
                index: index + 1,
                imported: nextImported,
                skipped: nextSkipped,
                unresolved: nextUnresolved,
                completion: completion
            )
        }
    }

    private func finishNewPipeImport(imported: Int, skipped: Int, unresolved: Int, fileName: String) {
        var lines: [String] = []
        if imported > 0 {
            lines.append(String(imported) + (imported == 1 ? " subscription added" : " subscriptions added"))
        }
        if skipped > 0 {
            lines.append(String(skipped) + (skipped == 1 ? " already followed" : " already followed"))
        }
        if unresolved > 0 {
            lines.append(String(unresolved) + (unresolved == 1 ? " channel could not be found" : " channels could not be found"))
        }
        if lines.isEmpty {
            lines.append("Nothing was imported.")
        }
        show(.finished(
            title: imported > 0 ? "Subscriptions imported" : "Nothing new to add",
            lines: lines,
            detail: fileName
        ))
    }

    /// Asks whether the backup should merge or replace. Merging is the default because it cannot
    /// lose data; replacing is offered second and says what it does.
    private func askMergeMode(fileName: String, completion: @escaping (Bool) -> Void) {
        let actions = [
            FlowActionSheetContent.Action(
                title: "Merge into this device",
                icon: .add,
                isDestructive: false,
                handler: { completion(true) }
            ),
            FlowActionSheetContent.Action(
                title: "Replace this device's data",
                icon: .trash,
                isDestructive: true,
                handler: { completion(false) }
            ),
        ]
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(
            content: content,
            title: "Import " + fileName,
            detent: .medium,
            showsGrabber: true
        )
        content.onActionSelected = { [weak sheet] in
            sheet?.dismissSheet()
        }
        sheet.present(from: self)
    }

    // MARK: - State

    private func show(_ state: WorkState) {
        progressCard.isHidden = true
        resultCard.isHidden = true
        exportButton.isEnabled = true
        newPipeExportButton.isEnabled = true
        backupRow.button.isEnabled = true
        newPipeRow.button.isEnabled = true
        isWorking = false

        switch state {
        case .idle:
            break

        case .working(let message, let fraction):
            isWorking = true
            progressCard.isHidden = false
            progressLabel.text = message
            progressBar.progress = Float(min(max(fraction, 0.0), 1.0))
            progressDetail.text = String(Int((min(max(fraction, 0.0), 1.0) * 100.0).rounded())) + "%"
            exportButton.isEnabled = false
            newPipeExportButton.isEnabled = false
            backupRow.button.isEnabled = false
            newPipeRow.button.isEnabled = false

        case .finished(let title, let lines, let detail):
            resultCard.isHidden = false
            resultTitle.text = title
            resultBody.text = lines.joined(separator: "\n")
            resultDetail.text = detail

        case .failed(let message):
            resultCard.isHidden = false
            resultTitle.text = "That didn't work"
            resultBody.text = message
            resultDetail.text = ""
        }
        applyTheme()
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        scrollView.backgroundColor = .clear
        introLabel.textColor = scheme.onSurfaceVariant
        for card in [exportCard, importCard, progressCard, resultCard] {
            card.applyTheme()
        }
        exportTitle.textColor = scheme.onSurface
        exportDetail.textColor = scheme.onSurfaceVariant
        exportMeta.textColor = scheme.onSurfaceVariant
        exportButton.applyTheme()
        newPipeExportButton.applyTheme()
        importTitle.textColor = scheme.onSurface
        backupRow.applyTheme()
        newPipeRow.applyTheme()
        progressLabel.textColor = scheme.onSurface
        progressDetail.textColor = scheme.onSurfaceVariant
        progressBar.progressTintColor = scheme.primary
        progressBar.trackTintColor = scheme.surfaceContainerHighest
        resultTitle.textColor = scheme.onSurface
        resultBody.textColor = scheme.onSurfaceVariant
        resultDetail.textColor = scheme.onSurfaceVariant
        resultButton.applyTheme()
    }

    // MARK: - Helpers

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Document picker

extension ImportExportViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        beginImport(from: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        show(.idle)
    }
}
