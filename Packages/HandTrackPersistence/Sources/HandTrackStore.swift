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
        sqlite3_close(database)
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

        for var incoming in incomingLogs {
            incoming.syncStatus = .synced
            if let index = hourlyLogs.firstIndex(where: { $0.id == incoming.id }) {
                if incoming.updatedAt >= hourlyLogs[index].updatedAt {
                    hourlyLogs[index] = incoming
                }
            } else {
                hourlyLogs.append(incoming)
            }
            save(incoming)
            acceptedIDs.append(incoming.id)
        }

        hourlyLogs.sort { $0.hourStart > $1.hourStart }
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

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            try openDatabase()
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

    private func loadArray<T: Decodable>(from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try decoder.decode([T].self, from: data)
    }

    private func openDatabase() throws {
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw StoreError.databaseOpenFailed(sqliteErrorMessage)
        }

        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS hourly_hand_logs (
                id TEXT PRIMARY KEY NOT NULL,
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
                id TEXT PRIMARY KEY NOT NULL,
                timestamp REAL NOT NULL
            );
            """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_keystroke_events_timestamp
            ON keystroke_events(timestamp);
            """)

        try execute("""
            CREATE TABLE IF NOT EXISTS migration_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """)
    }

    private func migrateJSONIfNeeded() throws {
        guard try migrationValue(for: "json_imported") != "true" else { return }

        let legacyLogs: [HourlyHandLog] = try loadArray(from: logsURL)
        for log in legacyLogs {
            save(log)
        }

        let legacyKeystrokes: [KeystrokeEvent] = try loadArray(from: keystrokesURL)
        for event in legacyKeystrokes {
            save(event)
        }

        try setMigrationValue("true", for: "json_imported")
    }

    private func loadHourlyLogs() throws -> [HourlyHandLog] {
        let statement = try prepare("""
            SELECT id, hour_start, pain_level, minutes_hands_used, journal_entry, created_at, updated_at, sync_status
            FROM hourly_hand_logs
            ORDER BY hour_start DESC, updated_at DESC;
            """)
        defer { sqlite3_finalize(statement) }

        var logs: [HourlyHandLog] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let id = UUID(uuidString: String(cString: idText)),
                let journalText = sqlite3_column_text(statement, 4),
                let syncText = sqlite3_column_text(statement, 7),
                let syncStatus = SyncStatus(rawValue: String(cString: syncText))
            else {
                continue
            }

            logs.append(HourlyHandLog(
                id: id,
                hourStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                painLevel: Int(sqlite3_column_int(statement, 2)),
                minutesHandsUsed: Int(sqlite3_column_int(statement, 3)),
                journalEntry: String(cString: journalText),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                syncStatus: syncStatus
            ))
        }

        return logs
    }

    private func loadKeystrokeEvents() throws -> [KeystrokeEvent] {
        let statement = try prepare("""
            SELECT id, timestamp
            FROM keystroke_events
            ORDER BY timestamp ASC;
            """)
        defer { sqlite3_finalize(statement) }

        var events: [KeystrokeEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let id = UUID(uuidString: String(cString: idText))
            else {
                continue
            }

            events.append(KeystrokeEvent(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            ))
        }

        return events
    }

    private func save(_ log: HourlyHandLog) {
        do {
            let statement = try prepare("""
                INSERT INTO hourly_hand_logs (
                    id, hour_start, pain_level, minutes_hands_used, journal_entry, created_at, updated_at, sync_status
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    hour_start = excluded.hour_start,
                    pain_level = excluded.pain_level,
                    minutes_hands_used = excluded.minutes_hands_used,
                    journal_entry = excluded.journal_entry,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    sync_status = excluded.sync_status;
                """)
            defer { sqlite3_finalize(statement) }

            bind(log.id.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, log.hourStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(log.painLevel))
            sqlite3_bind_int(statement, 4, Int32(log.minutesHandsUsed))
            bind(log.journalEntry, to: statement, at: 5)
            sqlite3_bind_double(statement, 6, log.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, log.updatedAt.timeIntervalSince1970)
            bind(log.syncStatus.rawValue, to: statement, at: 8)
            try stepDone(statement)
        } catch {
            print("Failed to save hourly log: \(error)")
        }
    }

    private func save(_ event: KeystrokeEvent) {
        do {
            let statement = try prepare("""
                INSERT OR IGNORE INTO keystroke_events (id, timestamp)
                VALUES (?, ?);
                """)
            defer { sqlite3_finalize(statement) }

            bind(event.id.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
            try stepDone(statement)
        } catch {
            print("Failed to save keystroke event: \(error)")
        }
    }

    private func migrationValue(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM migration_state WHERE key = ?;")
        defer { sqlite3_finalize(statement) }

        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let valueText = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: valueText)
    }

    private func setMigrationValue(_ value: String, for key: String) throws {
        let statement = try prepare("""
            INSERT INTO migration_state (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
        defer { sqlite3_finalize(statement) }

        bind(key, to: statement, at: 1)
        bind(value, to: statement, at: 2)
        try stepDone(statement)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.databaseError(sqliteErrorMessage)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.databaseError(sqliteErrorMessage)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.databaseError(sqliteErrorMessage)
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private var sqliteErrorMessage: String {
        guard let database else { return "database is not open" }
        return String(cString: sqlite3_errmsg(database))
    }

    private static func defaultStorageDirectory() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return baseURL.appendingPathComponent("HandTrack", isDirectory: true)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private enum StoreError: LocalizedError {
    case databaseOpenFailed(String)
    case databaseError(String)

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message):
            return "Failed to open HandTrack database: \(message)"
        case .databaseError(let message):
            return message
        }
    }
}
