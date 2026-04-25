import Foundation
import Combine
import SQLite3
#if os(macOS)
import AppKit
#endif

@MainActor
final class HandTrackStore: ObservableObject {
    @Published private(set) var hourlyLogs: [HourlyHandLog] = []

    let storageDirectory: URL

    private let logsURL: URL
    private let keystrokesURL: URL
    private let databaseURL: URL
    private let decoder: JSONDecoder
    private var database: OpaquePointer?
    private var lastRetentionRun = Date.distantPast

    private static let rawKeystrokeRetention: TimeInterval = 365 * 24 * 60 * 60

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
        upsertHourlyLog(log)
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
            upsertHourlyLog(incoming)
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
            upsertHourlyLog(hourlyLogs[index])
        }
    }

    func pendingLogs() -> [HourlyHandLog] {
        hourlyLogs.filter { $0.syncStatus == .pending }
    }

    func recordKeystroke(at timestamp: Date = Date()) {
        insertKeystroke(KeystrokeEvent(timestamp: timestamp))
        objectWillChange.send()
    }

    func keysSinceStartOfCurrentHour() -> Int {
        let hourStart = Date().startOfHour
        return keystrokeCount(since: hourStart)
    }

    func averageWordsPerMinuteForCurrentHour() -> Double {
        let hourStart = Date().startOfHour
        let elapsedMinutes = max(Date().timeIntervalSince(hourStart) / 60, 1)
        let words = Double(keysSinceStartOfCurrentHour()) / 5
        return words / elapsedMinutes
    }

    func keystrokeBuckets(from startDate: Date, to endDate: Date, interval: TimeInterval) -> [KeystrokeBucket] {
        guard interval > 0, endDate > startDate else { return [] }

        let bucketCount = Int(ceil(endDate.timeIntervalSince(startDate) / interval))
        guard bucketCount > 0 else { return [] }

        var counts = Array(repeating: 0, count: bucketCount)
        addRawKeystrokeCounts(to: &counts, startDate: startDate, endDate: endDate, interval: interval)
        addSummarizedKeystrokeCounts(to: &counts, startDate: startDate, endDate: endDate, interval: interval)

        return counts.indices.map { index in
            let start = startDate.addingTimeInterval(Double(index) * interval)
            return KeystrokeBucket(
                start: start,
                end: min(start.addingTimeInterval(interval), endDate),
                count: counts[index]
            )
        }
    }

    func exportCSVFiles() throws -> URL {
        let exportDirectory = storageDirectory
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent("HandTrackExport-\(Self.exportTimestampFormatter.string(from: Date()))", isDirectory: true)

        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )

        try exportHourlyLogs(to: exportDirectory.appendingPathComponent("hourly_logs.csv"))
        try exportRawKeystrokes(to: exportDirectory.appendingPathComponent("keystroke_events.csv"))
        try exportHourlyKeystrokeSummaries(to: exportDirectory.appendingPathComponent("keystroke_hourly_summaries.csv"))

        return exportDirectory
    }

    func openStorageDirectory() {
        #if os(macOS)
        NSWorkspace.shared.open(storageDirectory)
        #endif
    }

    func openDirectory(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
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
            enforceKeystrokeRetentionIfNeeded(force: true)
            hourlyLogs = try loadHourlyLogs()
        } catch {
            hourlyLogs = []
            print("Failed to load HandTrack data: \(error)")
        }
    }

    private func openDatabase() throws {
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw StoreError.databaseOpenFailed(message: sqliteErrorMessage)
        }

        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA foreign_keys=ON;")
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
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL
            );
            """)

        try execute("""
            CREATE TABLE IF NOT EXISTS keystroke_hourly_summaries (
                hour_start REAL PRIMARY KEY NOT NULL,
                key_count INTEGER NOT NULL
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
            upsertHourlyLog(log)
        }

        let legacyKeystrokes: [KeystrokeEvent] = try loadArray(from: keystrokesURL)
        for event in legacyKeystrokes {
            insertKeystroke(event)
        }

        try setMigrationValue("true", for: "json_imported")
    }

    private func loadArray<T: Decodable>(from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try decoder.decode([T].self, from: data)
    }

    private func loadHourlyLogs() throws -> [HourlyHandLog] {
        let statement = try prepare("""
            SELECT id, hour_start, pain_level, minutes_hands_used, journal_entry, created_at, updated_at, sync_status
            FROM hourly_hand_logs
            ORDER BY hour_start DESC;
            """)
        defer { sqlite3_finalize(statement) }

        var logs: [HourlyHandLog] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idString = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                let id = UUID(uuidString: idString),
                let journalEntry = sqlite3_column_text(statement, 4).map({ String(cString: $0) }),
                let syncStatusString = sqlite3_column_text(statement, 7).map({ String(cString: $0) }),
                let syncStatus = SyncStatus(rawValue: syncStatusString)
            else {
                continue
            }

            logs.append(HourlyHandLog(
                id: id,
                hourStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                painLevel: Int(sqlite3_column_int(statement, 2)),
                minutesHandsUsed: Int(sqlite3_column_int(statement, 3)),
                journalEntry: journalEntry,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                syncStatus: syncStatus
            ))
        }

        return logs
    }

    private func upsertHourlyLog(_ log: HourlyHandLog) {
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

    private func insertKeystroke(_ event: KeystrokeEvent) {
        do {
            let statement = try prepare("INSERT INTO keystroke_events (timestamp) VALUES (?);")
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, event.timestamp.timeIntervalSince1970)
            try stepDone(statement)
            enforceKeystrokeRetentionIfNeeded()
        } catch {
            print("Failed to save keystroke: \(error)")
        }
    }

    private func enforceKeystrokeRetentionIfNeeded(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRetentionRun) > 24 * 60 * 60 else { return }
        lastRetentionRun = Date()

        let cutoff = Date().addingTimeInterval(-Self.rawKeystrokeRetention)
        do {
            try compactKeystrokes(olderThan: cutoff)
        } catch {
            print("Failed to compact old keystrokes: \(error)")
        }
    }

    private func compactKeystrokes(olderThan cutoff: Date) throws {
        let cutoffTime = cutoff.timeIntervalSince1970

        try execute("BEGIN TRANSACTION;")
        do {
            let summarizeStatement = try prepare("""
                INSERT INTO keystroke_hourly_summaries (hour_start, key_count)
                SELECT CAST(timestamp / 3600 AS INTEGER) * 3600 AS hour_start, COUNT(*) AS key_count
                FROM keystroke_events
                WHERE timestamp < ?
                GROUP BY hour_start
                ON CONFLICT(hour_start) DO UPDATE SET
                    key_count = keystroke_hourly_summaries.key_count + excluded.key_count;
                """)
            defer { sqlite3_finalize(summarizeStatement) }
            sqlite3_bind_double(summarizeStatement, 1, cutoffTime)
            try stepDone(summarizeStatement)

            let deleteStatement = try prepare("DELETE FROM keystroke_events WHERE timestamp < ?;")
            defer { sqlite3_finalize(deleteStatement) }
            sqlite3_bind_double(deleteStatement, 1, cutoffTime)
            try stepDone(deleteStatement)

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func keystrokeCount(since startDate: Date) -> Int {
        do {
            let statement = try prepare("SELECT COUNT(*) FROM keystroke_events WHERE timestamp >= ?;")
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        } catch {
            print("Failed to count keystrokes: \(error)")
            return 0
        }
    }

    private func addRawKeystrokeCounts(
        to counts: inout [Int],
        startDate: Date,
        endDate: Date,
        interval: TimeInterval
    ) {
        do {
            let statement = try prepare("""
                SELECT CAST((timestamp - ?) / ? AS INTEGER) AS bucket_index, COUNT(*)
                FROM keystroke_events
                WHERE timestamp >= ? AND timestamp < ?
                GROUP BY bucket_index;
                """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, interval)
            sqlite3_bind_double(statement, 3, startDate.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, endDate.timeIntervalSince1970)

            while sqlite3_step(statement) == SQLITE_ROW {
                let index = Int(sqlite3_column_int64(statement, 0))
                guard counts.indices.contains(index) else { continue }
                counts[index] += Int(sqlite3_column_int64(statement, 1))
            }
        } catch {
            print("Failed to bucket raw keystrokes: \(error)")
        }
    }

    private func addSummarizedKeystrokeCounts(
        to counts: inout [Int],
        startDate: Date,
        endDate: Date,
        interval: TimeInterval
    ) {
        do {
            let statement = try prepare("""
                SELECT CAST((hour_start - ?) / ? AS INTEGER) AS bucket_index, SUM(key_count)
                FROM keystroke_hourly_summaries
                WHERE hour_start >= ? AND hour_start < ?
                GROUP BY bucket_index;
                """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, interval)
            sqlite3_bind_double(statement, 3, startDate.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, endDate.timeIntervalSince1970)

            while sqlite3_step(statement) == SQLITE_ROW {
                let index = Int(sqlite3_column_int64(statement, 0))
                guard counts.indices.contains(index) else { continue }
                counts[index] += Int(sqlite3_column_int64(statement, 1))
            }
        } catch {
            print("Failed to bucket summarized keystrokes: \(error)")
        }
    }

    private func exportHourlyLogs(to url: URL) throws {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }

        writer.write("id,hour_start,hour_start_unix,pain_level,minutes_hands_used,journal_entry,created_at,updated_at,sync_status\n")
        for log in hourlyLogs.sorted(by: { $0.hourStart < $1.hourStart }) {
            writer.write([
                log.id.uuidString,
                Self.csvDateFormatter.string(from: log.hourStart),
                String(log.hourStart.timeIntervalSince1970),
                String(log.painLevel),
                String(log.minutesHandsUsed),
                log.journalEntry,
                Self.csvDateFormatter.string(from: log.createdAt),
                Self.csvDateFormatter.string(from: log.updatedAt),
                log.syncStatus.rawValue
            ])
        }
    }

    private func exportRawKeystrokes(to url: URL) throws {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }

        writer.write("id,timestamp,timestamp_unix\n")

        let statement = try prepare("SELECT id, timestamp FROM keystroke_events ORDER BY timestamp ASC;")
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            writer.write([
                String(id),
                Self.csvDateFormatter.string(from: timestamp),
                String(timestamp.timeIntervalSince1970)
            ])
        }
    }

    private func exportHourlyKeystrokeSummaries(to url: URL) throws {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }

        writer.write("hour_start,hour_start_unix,key_count\n")

        let statement = try prepare("""
            SELECT hour_start, key_count
            FROM keystroke_hourly_summaries
            ORDER BY hour_start ASC;
            """)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let hourStart = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            writer.write([
                Self.csvDateFormatter.string(from: hourStart),
                String(hourStart.timeIntervalSince1970),
                String(sqlite3_column_int64(statement, 1))
            ])
        }
    }

    private func migrationValue(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM migration_state WHERE key = ?;")
        defer { sqlite3_finalize(statement) }

        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
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
            throw StoreError.databaseError(message: sqliteErrorMessage)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.databaseError(message: sqliteErrorMessage)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.databaseError(message: sqliteErrorMessage)
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private var sqliteErrorMessage: String {
        guard let database else { return "Database is not open" }
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

    private static let csvDateFormatter = ISO8601DateFormatter()

    private static let exportTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private enum StoreError: LocalizedError {
    case databaseOpenFailed(message: String)
    case databaseError(message: String)

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message):
            return "Could not open database: \(message)"
        case .databaseError(let message):
            return message
        }
    }
}

private final class CSVWriter {
    private let handle: FileHandle

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        handle.write(Data(line.utf8))
    }

    func write(_ fields: [String]) {
        write(fields.map(Self.escape).joined(separator: ",") + "\n")
    }

    func close() {
        try? handle.close()
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
