import Foundation
import Combine
import SQLite3
#if os(macOS)
import AppKit
#endif

@MainActor
final class HandTrackStore: ObservableObject {
    @Published private(set) var hourlyLogs: [HourlyHandLog] = []
    @Published private(set) var keystrokeEvents: [KeystrokeEvent] = []

    let storageDirectory: URL

    private let logsURL: URL
    private let keystrokesURL: URL
    private let databaseURL: URL
    private let decoder: JSONDecoder
    private var database: OpaquePointer?

    init(storageDirectory: URL? = nil) {
        let baseDirectory = storageDirectory ?? Self.defaultStorageDirectory()
        self.storageDirectory = baseDirectory
        self.logsURL = baseDirectory.appendingPathComponent("hourly_logs.json")
        self.keystrokesURL = baseDirectory.appendingPathComponent("keystrokes.json")
        self.databaseURL = baseDirectory.appendingPathComponent("handtrack.sqlite")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func saveHourlyLog(painLevel: Int, minutesHandsUsed: Int, journalEntry: String) {
        let now = Date()
        let log = HourlyHandLog(
            hourStart: now.startOfHour,
            painLevel: painLevel,
            minutesHandsUsed: minutesHandsUsed,
            journalEntry: journalEntry,
            createdAt: now,
            updatedAt: now,
            syncStatus: .pending
        )
        hourlyLogs.insert(log, at: 0)
        save(log)
    }

    func importHourlyLogs(_ incomingLogs: [HourlyHandLog]) -> [UUID] {
        var acceptedIDs: [UUID] = []
        var logsToSave: [HourlyHandLog] = []

        for var incoming in incomingLogs {
            incoming.syncStatus = .synced
            if let index = hourlyLogs.firstIndex(where: { $0.id == incoming.id }) {
                if incoming.updatedAt >= hourlyLogs[index].updatedAt {
                    hourlyLogs[index] = incoming
                    logsToSave.append(incoming)
                }
            } else {
                hourlyLogs.append(incoming)
                logsToSave.append(incoming)
            }
            acceptedIDs.append(incoming.id)
        }

        hourlyLogs.sort { $0.hourStart > $1.hourStart }
        logsToSave.forEach(save)
        return acceptedIDs
    }

    func markLogsSynced(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for index in hourlyLogs.indices where ids.contains(hourlyLogs[index].id) {
            hourlyLogs[index].syncStatus = .synced
            hourlyLogs[index].updatedAt = Date()
            save(hourlyLogs[index])
        }
    }

    func pendingLogs() -> [HourlyHandLog] {
        hourlyLogs.filter { $0.syncStatus == .pending }
    }

    func recordKeystroke(at timestamp: Date = Date()) {
        let event = KeystrokeEvent(timestamp: timestamp)
        keystrokeEvents.append(event)
        save(event)
    }

    func keysSinceStartOfCurrentHour() -> Int {
        let hourStart = Date().startOfHour
        return keystrokeEvents.filter { $0.timestamp >= hourStart }.count
    }

    func averageWordsPerMinuteForCurrentHour() -> Double {
        let hourStart = Date().startOfHour
        let elapsedMinutes = max(Date().timeIntervalSince(hourStart) / 60, 1)
        let words = Double(keysSinceStartOfCurrentHour()) / 5
        return words / elapsedMinutes
    }

    func openStorageDirectory() {
        #if os(macOS)
        NSWorkspace.shared.open(storageDirectory)
        #endif
    }

    func reloadFromDisk() {
        load()
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            try openDatabaseIfNeeded()
            try createSchema()
            try migrateJSONIfNeeded()
            hourlyLogs = try loadHourlyLogs()
            keystrokeEvents = try loadKeystrokeEvents()
        } catch {
            hourlyLogs = []
            keystrokeEvents = []
            print("Failed to load HandTrack data: \(error)")
        }
    }

    private func openDatabaseIfNeeded() throws {
        guard database == nil else { return }
        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw StoreError.sqlite(message: lastSQLiteError)
        }
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS hourly_logs (
            id TEXT PRIMARY KEY,
            hour_start REAL NOT NULL,
            pain_level INTEGER NOT NULL,
            minutes_hands_used INTEGER NOT NULL,
            journal_entry TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            sync_status TEXT NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS keystroke_events (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL
        );
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_keystroke_events_timestamp ON keystroke_events(timestamp);")
        try execute("CREATE INDEX IF NOT EXISTS idx_hourly_logs_hour_start ON hourly_logs(hour_start);")
    }

    private func migrateJSONIfNeeded() throws {
        guard try metadataValue(for: "jsonMigrationComplete") != "true" else { return }

        let legacyLogs: [HourlyHandLog] = try loadLegacyArray(from: logsURL)
        let legacyKeystrokes: [KeystrokeEvent] = try loadLegacyArray(from: keystrokesURL)

        for log in legacyLogs {
            try saveOrThrow(log)
        }

        for event in legacyKeystrokes {
            try saveOrThrow(event)
        }

        try setMetadataValue("true", for: "jsonMigrationComplete")
    }

    private func loadLegacyArray<T: Decodable>(from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try decoder.decode([T].self, from: data)
    }

    private func save(_ log: HourlyHandLog) {
        do {
            try saveOrThrow(log)
        } catch {
            print("Failed to save hourly log: \(error)")
        }
    }

    private func save(_ event: KeystrokeEvent) {
        do {
            try saveOrThrow(event)
        } catch {
            print("Failed to save keystroke: \(error)")
        }
    }

    private func saveOrThrow(_ log: HourlyHandLog) throws {
        try withStatement("""
        INSERT OR REPLACE INTO hourly_logs (
            id,
            hour_start,
            pain_level,
            minutes_hands_used,
            journal_entry,
            created_at,
            updated_at,
            sync_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            bindText(log.id.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, log.hourStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(log.painLevel))
            sqlite3_bind_int(statement, 4, Int32(log.minutesHandsUsed))
            bindText(log.journalEntry, to: statement, at: 5)
            sqlite3_bind_double(statement, 6, log.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, log.updatedAt.timeIntervalSince1970)
            bindText(log.syncStatus.rawValue, to: statement, at: 8)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func saveOrThrow(_ event: KeystrokeEvent) throws {
        try withStatement("""
        INSERT OR IGNORE INTO keystroke_events (id, timestamp)
        VALUES (?, ?);
        """) { statement in
            bindText(event.id.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadHourlyLogs() throws -> [HourlyHandLog] {
        try query("""
        SELECT id, hour_start, pain_level, minutes_hands_used, journal_entry, created_at, updated_at, sync_status
        FROM hourly_logs
        ORDER BY hour_start DESC;
        """) { statement in
            guard let id = UUID(uuidString: columnText(statement, at: 0)) else {
                throw StoreError.invalidData("Invalid hourly log UUID")
            }

            return HourlyHandLog(
                id: id,
                hourStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                painLevel: Int(sqlite3_column_int(statement, 2)),
                minutesHandsUsed: Int(sqlite3_column_int(statement, 3)),
                journalEntry: columnText(statement, at: 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                syncStatus: SyncStatus(rawValue: columnText(statement, at: 7)) ?? .pending
            )
        }
    }

    private func loadKeystrokeEvents() throws -> [KeystrokeEvent] {
        try query("""
        SELECT id, timestamp
        FROM keystroke_events
        ORDER BY timestamp ASC;
        """) { statement in
            guard let id = UUID(uuidString: columnText(statement, at: 0)) else {
                throw StoreError.invalidData("Invalid keystroke UUID")
            }

            return KeystrokeEvent(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            )
        }
    }

    private func metadataValue(for key: String) throws -> String? {
        try withStatement("SELECT value FROM metadata WHERE key = ?;") { statement in
            bindText(key, to: statement, at: 1)
            let result = sqlite3_step(statement)

            if result == SQLITE_ROW {
                return columnText(statement, at: 0)
            }

            if result == SQLITE_DONE {
                return nil
            }

            throw StoreError.sqlite(message: lastSQLiteError)
        }
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        try withStatement("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?);") { statement in
            bindText(key, to: statement, at: 1)
            bindText(value, to: statement, at: 2)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(message: lastSQLiteError)
        }
    }

    private func query<T>(_ sql: String, row: (OpaquePointer) throws -> T) throws -> [T] {
        try withStatement(sql) { statement in
            var values: [T] = []

            while true {
                let result = sqlite3_step(statement)

                if result == SQLITE_ROW {
                    values.append(try row(statement))
                } else if result == SQLITE_DONE {
                    return values
                } else {
                    throw StoreError.sqlite(message: lastSQLiteError)
                }
            }
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.sqlite(message: lastSQLiteError)
        }

        defer {
            sqlite3_finalize(statement)
        }

        return try body(statement)
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) {
        value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    private var lastSQLiteError: String {
        guard let database else { return "Database is not open" }
        guard let message = sqlite3_errmsg(database) else { return "Unknown SQLite error" }
        return String(cString: message)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func defaultStorageDirectory() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return baseURL.appendingPathComponent("HandTrack", isDirectory: true)
    }
}

private enum StoreError: LocalizedError {
    case sqlite(message: String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return "SQLite error: \(message)"
        case .invalidData(let message):
            return message
        }
    }
}
