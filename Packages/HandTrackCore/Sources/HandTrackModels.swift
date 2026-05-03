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

struct KeystrokeMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var keyCount: Int

    var id: Date { minuteStart }
}

/// Twelve consecutive five-minute spans within a calendar hour (e.g. 12:00–12:04, …, 12:55–12:59).
struct KeystrokeFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var keyCount: Int

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) ?? slotStart
    }
}

struct SyncResponse: Codable {
    var acceptedIDs: [UUID]
}

extension Date {
    var startOfHour: Date {
        Calendar.current.dateInterval(of: .hour, for: self)?.start ?? self
    }

    var startOfMinute: Date {
        Calendar.current.dateInterval(of: .minute, for: self)?.start ?? self
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
