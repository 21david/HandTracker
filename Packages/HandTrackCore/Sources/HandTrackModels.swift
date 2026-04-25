import Foundation

enum SyncStatus: String, Codable, Hashable {
    case pending
    case synced
}

struct HourlyHandLog: Identifiable, Codable, Hashable {
    var id: UUID
    var hourStart: Date
    var painLevel: Int
    var minutesHandsUsed: Int
    var journalEntry: String
    var createdAt: Date
    var updatedAt: Date
    var syncStatus: SyncStatus

    init(
        id: UUID = UUID(),
        hourStart: Date,
        painLevel: Int,
        minutesHandsUsed: Int,
        journalEntry: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        syncStatus: SyncStatus = .pending
    ) {
        self.id = id
        self.hourStart = hourStart
        self.painLevel = painLevel
        self.minutesHandsUsed = minutesHandsUsed
        self.journalEntry = journalEntry
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncStatus = syncStatus
    }
}

struct KeystrokeEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var timestamp: Date

    init(id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.timestamp = timestamp
    }
}

struct KeystrokeBucket: Identifiable, Hashable {
    var id: Date { start }
    var start: Date
    var end: Date
    var count: Int
}

struct SyncResponse: Codable {
    var acceptedIDs: [UUID]
}

extension Date {
    var startOfHour: Date {
        Calendar.current.dateInterval(of: .hour, for: self)?.start ?? self
    }

    func nextBucketBoundary(interval: TimeInterval) -> Date {
        guard interval > 0 else { return self }
        let nextInterval = ceil(timeIntervalSince1970 / interval) * interval
        return Date(timeIntervalSince1970: nextInterval)
    }

    var displayHour: String {
        Self.hourFormatter.string(from: self)
    }

    var displayTime: String {
        Self.timeFormatter.string(from: self)
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
