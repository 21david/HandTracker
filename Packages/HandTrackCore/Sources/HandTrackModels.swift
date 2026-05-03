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

/// One five-minute span aligned to real clock boundaries (:00, :05, …).
struct KeystrokeFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var keyCount: Int

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) ?? slotStart
    }
}

/// Mouse click counts summed into the same clock-aligned five-minute windows as keystrokes.
struct MouseClickFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var clickCount: Int

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) ?? slotStart
    }
}

struct MouseClickMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var clickCount: Int

    var id: Date { minuteStart }
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

    /// Start of the five-minute window that contains this instant (e.g. 8:07 → 8:05).
    var startOfFiveMinuteSlot: Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        let m = c.minute ?? 0
        c.minute = (m / 5) * 5
        c.second = 0
        c.nanosecond = 0
        return cal.date(from: c) ?? self
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
