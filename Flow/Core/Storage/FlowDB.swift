import Foundation
import SQLite3

/// A value a SQLite statement can bind, so callers never touch the C API directly.
enum FlowDBValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func int(_ value: Int) -> FlowDBValue {
        return .integer(Int64(value))
    }

    static func bool(_ value: Bool) -> FlowDBValue {
        return .integer(value ? 1 : 0)
    }

    static func double(_ value: Double) -> FlowDBValue {
        return .real(value)
    }

    static func string(_ value: String?) -> FlowDBValue {
        guard let text = value else { return .null }
        return .text(text)
    }

    static func date(_ value: Date?) -> FlowDBValue {
        guard let date = value else { return .null }
        return .real(date.timeIntervalSince1970)
    }
}

/// One row of a query result, addressed by column name. Reads are tolerant: a missing column or a
/// NULL yields the type's default rather than trapping.
struct FlowDBRow {
    private let storage: [String: FlowDBValue]

    init(storage: [String: FlowDBValue]) {
        self.storage = storage
    }

    func value(_ column: String) -> FlowDBValue {
        return storage[column] ?? .null
    }

    func int(_ column: String) -> Int {
        switch value(column) {
        case .integer(let number): return Int(number)
        case .real(let number): return Int(number)
        case .text(let text): return Int(text) ?? 0
        default: return 0
        }
    }

    func int64(_ column: String) -> Int64 {
        switch value(column) {
        case .integer(let number): return number
        case .real(let number): return Int64(number)
        case .text(let text): return Int64(text) ?? 0
        default: return 0
        }
    }

    func double(_ column: String) -> Double {
        switch value(column) {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        case .text(let text): return Double(text) ?? 0.0
        default: return 0.0
        }
    }

    func bool(_ column: String) -> Bool {
        return int(column) != 0
    }

    func string(_ column: String) -> String {
        switch value(column) {
        case .text(let text): return text
        case .integer(let number): return String(number)
        case .real(let number): return String(number)
        default: return ""
        }
    }

    func optionalString(_ column: String) -> String? {
        switch value(column) {
        case .text(let text): return text
        case .integer(let number): return String(number)
        case .real(let number): return String(number)
        default: return nil
        }
    }

    func date(_ column: String) -> Date? {
        switch value(column) {
        case .real(let number): return Date(timeIntervalSince1970: number)
        case .integer(let number): return Date(timeIntervalSince1970: Double(number))
        default: return nil
        }
    }

    func data(_ column: String) -> Data? {
        if case .blob(let data) = value(column) { return data }
        return nil
    }
}

/// A thin, thread-safe wrapper over the system SQLite. All access is serialised on one queue, WAL
/// is on, and every statement is prepared and finalised per call so nothing leaks on a throw.
///
/// The wrapper deliberately exposes no ORM: each store writes its own SQL, which keeps the schema
/// visible in one place per feature.
final class FlowDB {

    /// The error a failed database operation reports.
    struct Failure: Error, CustomStringConvertible {
        let message: String
        let code: Int32

        var description: String {
            return "FlowDB error \(code): \(message)"
        }
    }

    static let shared = FlowDB()

    private let queue = DispatchQueue(label: "org.flowtube.Flow.db")
    private var handle: OpaquePointer?
    private let path: String

    /// Opens (and migrates) the database at the default location.
    init(name: String = "flow.sqlite") {
        let support = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let directory = (support as NSString).appendingPathComponent("Flow")
        if !FileManager.default.fileExists(atPath: directory) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        }
        path = (directory as NSString).appendingPathComponent(name)
        queue.sync {
            openLocked()
            migrateLocked()
        }
    }

    /// For tests and for the export reader, which opens a copy elsewhere.
    init(filePath: String) {
        path = filePath
        queue.sync {
            openLocked()
            migrateLocked()
        }
    }

    deinit {
        let localHandle = handle
        handle = nil
        if let localHandle = localHandle {
            sqlite3_close_v2(localHandle)
        }
    }

    /// The file the database lives in.
    var filePath: String {
        return path
    }

    // MARK: - Opening

    private func openLocked() {
        guard handle == nil else { return }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let opened = database else {
            if let failed = database {
                sqlite3_close_v2(failed)
            }
            return
        }
        handle = opened
        sqlite3_busy_timeout(opened, 5000)
        executeRaw("PRAGMA journal_mode=WAL;")
        executeRaw("PRAGMA synchronous=NORMAL;")
        executeRaw("PRAGMA foreign_keys=ON;")
    }

    // MARK: - Schema

    /// The schema version this build writes. Bump it and add a migration step for every change.
    private static let schemaVersion = 1

    private func migrateLocked() {
        executeRaw("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);")
        let current = queryLocked("SELECT version FROM schema_version LIMIT 1;", []).first?.int("version") ?? 0
        if current == 0 {
            executeRaw("INSERT INTO schema_version (version) VALUES (0);")
        }
        if current < 1 {
            executeRaw(Self.schemaV1)
            executeRaw("UPDATE schema_version SET version = 1;")
        }
        if current < Self.schemaVersion {
            executeRaw("UPDATE schema_version SET version = \(Self.schemaVersion);")
        }
    }

    /// Version 1: history, subscriptions, playlists, downloads, notes, and the recommendation
    /// topic vectors the home feed builds on device.
    private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS history (
        video_id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        channel_id TEXT NOT NULL DEFAULT '',
        channel_name TEXT NOT NULL DEFAULT '',
        thumbnail_url TEXT NOT NULL DEFAULT '',
        duration REAL NOT NULL DEFAULT 0,
        position REAL NOT NULL DEFAULT 0,
        watched_at REAL NOT NULL DEFAULT 0,
        is_music INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS history_watched_at ON history (watched_at DESC);

    CREATE TABLE IF NOT EXISTS subscriptions (
        channel_id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        avatar_url TEXT NOT NULL DEFAULT '',
        subscriber_count INTEGER NOT NULL DEFAULT 0,
        subscribed_at REAL NOT NULL DEFAULT 0,
        notifications_enabled INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS subscriptions_name ON subscriptions (name COLLATE NOCASE);

    CREATE TABLE IF NOT EXISTS playlists (
        playlist_id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        thumbnail_url TEXT NOT NULL DEFAULT '',
        is_local INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS playlist_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id TEXT NOT NULL,
        video_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        channel_name TEXT NOT NULL DEFAULT '',
        thumbnail_url TEXT NOT NULL DEFAULT '',
        duration REAL NOT NULL DEFAULT 0,
        position INTEGER NOT NULL DEFAULT 0,
        added_at REAL NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS playlist_items_playlist ON playlist_items (playlist_id, position);

    CREATE TABLE IF NOT EXISTS downloads (
        video_id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        channel_name TEXT NOT NULL DEFAULT '',
        thumbnail_url TEXT NOT NULL DEFAULT '',
        file_path TEXT NOT NULL DEFAULT '',
        audio_path TEXT NOT NULL DEFAULT '',
        quality TEXT NOT NULL DEFAULT '',
        byte_size INTEGER NOT NULL DEFAULT 0,
        duration REAL NOT NULL DEFAULT 0,
        state TEXT NOT NULL DEFAULT 'queued',
        progress REAL NOT NULL DEFAULT 0,
        created_at REAL NOT NULL DEFAULT 0,
        is_music INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS downloads_created ON downloads (created_at DESC);

    CREATE TABLE IF NOT EXISTS notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id TEXT NOT NULL,
        video_title TEXT NOT NULL DEFAULT '',
        channel_name TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL DEFAULT '',
        timestamp REAL NOT NULL DEFAULT 0,
        created_at REAL NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS notes_video ON notes (video_id, timestamp);

    CREATE TABLE IF NOT EXISTS search_history (
        query TEXT PRIMARY KEY NOT NULL,
        searched_at REAL NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS topic_weights (
        token TEXT PRIMARY KEY NOT NULL,
        weight REAL NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS saved_shorts (
        video_id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        channel_name TEXT NOT NULL DEFAULT '',
        thumbnail_url TEXT NOT NULL DEFAULT '',
        saved_at REAL NOT NULL DEFAULT 0
    );
    """

    // MARK: - Public API

    /// Runs `statement` with `arguments`, returning the number of rows it changed.
    @discardableResult
    func execute(_ statement: String, _ arguments: [FlowDBValue] = []) -> Int {
        var changed = 0
        queue.sync {
            changed = executeLocked(statement, arguments)
        }
        return changed
    }

    /// Runs several statements as one transaction. A failure rolls the whole batch back.
    @discardableResult
    func transaction(_ body: (FlowDBTransaction) -> Void) -> Bool {
        var success = false
        queue.sync {
            executeRaw("BEGIN IMMEDIATE TRANSACTION;")
            let transaction = FlowDBTransaction(database: self, queue: self.queue)
            body(transaction)
            if transaction.failed {
                executeRaw("ROLLBACK;")
                success = false
            } else {
                executeRaw("COMMIT;")
                success = true
            }
        }
        return success
    }

    /// Runs a query and returns every row. Column names are matched case-sensitively.
    func query(_ statement: String, _ arguments: [FlowDBValue] = []) -> [FlowDBRow] {
        var rows: [FlowDBRow] = []
        queue.sync {
            rows = queryLocked(statement, arguments)
        }
        return rows
    }

    /// The first row of a query, or nil.
    func firstRow(_ statement: String, _ arguments: [FlowDBValue] = []) -> FlowDBRow? {
        return query(statement, arguments).first
    }

    /// A single integer result, e.g. `SELECT COUNT(*)`.
    func scalarInt(_ statement: String, _ arguments: [FlowDBValue] = []) -> Int {
        guard let row = firstRow(statement, arguments) else { return 0 }
        let firstColumn = row.value("value")
        switch firstColumn {
        case .integer(let number): return Int(number)
        case .real(let number): return Int(number)
        case .text(let text): return Int(text) ?? 0
        case .null:
            if let any = row.optionalString("count") { return Int(any) ?? 0 }
            return 0
        default: return 0
        }
    }

    /// Deletes every row from every table. Used by "clear all data" in Privacy settings.
    func eraseAll() {
        queue.sync {
            let tables = ["history", "subscriptions", "playlists", "playlist_items", "downloads",
                          "notes", "search_history", "topic_weights", "saved_shorts"]
            executeRaw("BEGIN IMMEDIATE TRANSACTION;")
            for table in tables {
                executeRaw("DELETE FROM \(table);")
            }
            executeRaw("COMMIT;")
            executeRaw("VACUUM;")
        }
    }

    // MARK: - Locked internals

    /// Executes a statement and returns the number of changed rows. Must run on `queue`.
    fileprivate func executeLocked(_ statement: String, _ arguments: [FlowDBValue]) -> Int {
        guard let database = handle else { return 0 }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, statement, -1, &prepared, nil) == SQLITE_OK, let statementHandle = prepared else {
            return 0
        }
        defer { sqlite3_finalize(statementHandle) }
        bind(arguments, to: statementHandle, database: database)
        let result = sqlite3_step(statementHandle)
        if result != SQLITE_DONE && result != SQLITE_ROW {
            return 0
        }
        return Int(sqlite3_changes(database))
    }

    /// Runs a statement whose result is not needed. Must run on `queue`.
    fileprivate func executeRaw(_ statement: String) {
        guard let database = handle else { return }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, statement, -1, &prepared, nil) == SQLITE_OK, let statementHandle = prepared else {
            return
        }
        sqlite3_step(statementHandle)
        sqlite3_finalize(statementHandle)
    }

    /// Runs a query and materialises every row. Must run on `queue`.
    fileprivate func queryLocked(_ statement: String, _ arguments: [FlowDBValue]) -> [FlowDBRow] {
        guard let database = handle else { return [] }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, statement, -1, &prepared, nil) == SQLITE_OK, let statementHandle = prepared else {
            return []
        }
        defer { sqlite3_finalize(statementHandle) }
        bind(arguments, to: statementHandle, database: database)

        var columns: [String] = []
        let columnCount = sqlite3_column_count(statementHandle)
        var index: Int32 = 0
        while index < columnCount {
            if let name = sqlite3_column_name(statementHandle, index) {
                columns.append(String(cString: name))
            } else {
                columns.append("column_\(index)")
            }
            index += 1
        }

        var rows: [FlowDBRow] = []
        while sqlite3_step(statementHandle) == SQLITE_ROW {
            var storage: [String: FlowDBValue] = [:]
            for columnIndex in 0..<columnCount {
                let name = columns[Int(columnIndex)]
                storage[name] = readValue(statementHandle, columnIndex)
            }
            rows.append(FlowDBRow(storage: storage))
        }
        return rows
    }

    private func readValue(_ statement: OpaquePointer, _ index: Int32) -> FlowDBValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            if let text = sqlite3_column_text(statement, index) {
                return .text(String(cString: text))
            }
            return .null
        case SQLITE_BLOB:
            let length = sqlite3_column_bytes(statement, index)
            if let bytes = sqlite3_column_blob(statement, index), length > 0 {
                return .blob(Data(bytes: bytes, count: Int(length)))
            }
            return .blob(Data())
        default:
            return .null
        }
    }

    private func bind(_ arguments: [FlowDBValue], to statement: OpaquePointer, database: OpaquePointer) {
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                sqlite3_bind_double(statement, index, number)
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .blob(let data):
                if data.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    data.withUnsafeBytes { buffer in
                        let base = buffer.baseAddress
                        sqlite3_bind_blob(statement, index, base, Int32(data.count), Self.transient)
                    }
                }
            }
        }
    }

    /// SQLite's SQLITE_TRANSIENT, which makes SQLite copy the bound bytes.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// A handle passed to a `FlowDB.transaction` body. Statements run inside the surrounding
/// transaction; setting `failed` rolls the whole batch back.
final class FlowDBTransaction {
    private let database: FlowDB
    private let queue: DispatchQueue
    private(set) var failed = false

    init(database: FlowDB, queue: DispatchQueue) {
        self.database = database
        self.queue = queue
    }

    /// Marks the transaction for rollback.
    func fail() {
        failed = true
    }

    @discardableResult
    func execute(_ statement: String, _ arguments: [FlowDBValue] = []) -> Int {
        return database.executeLocked(statement, arguments)
    }

    func query(_ statement: String, _ arguments: [FlowDBValue] = []) -> [FlowDBRow] {
        return database.queryLocked(statement, arguments)
    }
}
