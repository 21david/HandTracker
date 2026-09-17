import Foundation

enum SyncStatus: String, Codable, Hashable {
    case pending
    case synced
}

struct HourlyHandLog: Identifiable, Hashable {
    var id: UUID
    /// Start of calendar hour containing this entry (hour bucket label, e.g. 5:39 PM → start of 5 PM hour).
    var hourStart: Date
    var painLevelLeft: Double
    var painLevelRight: Double
    var minutesHandsUsed: Int
    var journalEntry: String
    var createdAt: Date
    var updatedAt: Date
    var syncStatus: SyncStatus

    init(
        id: UUID = UUID(),
        hourStart: Date,
        painLevelLeft: Double,
        painLevelRight: Double,
        minutesHandsUsed: Int,
        journalEntry: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        syncStatus: SyncStatus = .pending
    ) {
        self.id = id
        self.hourStart = hourStart
        self.painLevelLeft = painLevelLeft
        self.painLevelRight = painLevelRight
        self.minutesHandsUsed = minutesHandsUsed
        self.journalEntry = journalEntry
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncStatus = syncStatus
    }
}

extension HourlyHandLog: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, hourStart, minutesHandsUsed, journalEntry, createdAt, updatedAt, syncStatus
        case painLevelLeft, painLevelRight
        /// Legacy payload from older clients — copied to both hands when decoding.
        case painLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        hourStart = try c.decode(Date.self, forKey: .hourStart)

        func decodeSide(_ key: CodingKeys, legacyFallback: Double) throws -> Double {
            if let d = try c.decodeIfPresent(Double.self, forKey: key) {
                return d
            }
            if let i = try c.decodeIfPresent(Int.self, forKey: key) {
                return Double(i)
            }
            return legacyFallback
        }

        let legacyResolved: Double
        if let d = try c.decodeIfPresent(Double.self, forKey: .painLevel) {
            legacyResolved = d
        } else if let i = try c.decodeIfPresent(Int.self, forKey: .painLevel) {
            legacyResolved = Double(i)
        } else {
            legacyResolved = 1
        }

        painLevelLeft = try decodeSide(.painLevelLeft, legacyFallback: legacyResolved)
        painLevelRight = try decodeSide(.painLevelRight, legacyFallback: legacyResolved)

        minutesHandsUsed = try c.decode(Int.self, forKey: .minutesHandsUsed)
        journalEntry = try c.decode(String.self, forKey: .journalEntry)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        syncStatus = try c.decode(SyncStatus.self, forKey: .syncStatus)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(hourStart, forKey: .hourStart)
        try c.encode(painLevelLeft, forKey: .painLevelLeft)
        try c.encode(painLevelRight, forKey: .painLevelRight)
        try c.encode(painLevelLeft, forKey: .painLevel)
        try c.encode(minutesHandsUsed, forKey: .minutesHandsUsed)
        try c.encode(journalEntry, forKey: .journalEntry)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(syncStatus, forKey: .syncStatus)
    }
}

extension HourlyHandLog {
    /// Readable pain summary for log rows (“left 0.5, right 3”; halves shown as decimals).
    var handTrackPainLeftRightLogPhrase: String {
        "left \(painLevelLeft.handTrackPainLoggedNumber), right \(painLevelRight.handTrackPainLoggedNumber)"
    }
}

struct KeystrokeMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var keyCount: Int

    var id: Date { minuteStart }
}

/// One clock-aligned usage span (typically 1 or 5 minutes) for live histograms.
struct KeystrokeFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var keyCount: Int
    /// Bar width in minutes (5 for classic charts, 1 for one-minute mode).
    var durationMinutes: Int = 5

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: durationMinutes, to: slotStart) ?? slotStart
    }
}

/// Mouse click counts summed into the same clock-aligned windows as keystrokes.
struct MouseClickFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var clickCount: Int
    var durationMinutes: Int = 5

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: durationMinutes, to: slotStart) ?? slotStart
    }
}

struct MouseClickMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var clickCount: Int

    var id: Date { minuteStart }
}

/// Accumulated on-screen pointer movement in **pixels** (AppKit points / backing-independent units)
/// per calendar minute, summed from CGEvent mouse deltas.
struct MouseTravelMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var travelPixels: Double

    var id: Date { minuteStart }
}

struct MouseTravelFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var travelPixels: Double
    var durationMinutes: Int = 5

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: durationMinutes, to: slotStart) ?? slotStart
    }
}

/// Discrete mouse-wheel / scroll “bumps” (notches) per calendar minute.
struct ScrollBumpMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var bumpCount: Int

    var id: Date { minuteStart }
}

struct ScrollBumpFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var bumpCount: Int
    var durationMinutes: Int = 5

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: durationMinutes, to: slotStart) ?? slotStart
    }
}

struct ExternalKeyboardIdentity: Hashable, Codable, Identifiable {
    var id: String
    var vendorID: Int
    var productID: Int
    var manufacturer: String
    var product: String
    var serial: String
    var defaultName: String

    static let unknown = ExternalKeyboardIdentity(
        id: "unknown-external",
        vendorID: -1,
        productID: -1,
        manufacturer: "",
        product: "",
        serial: "",
        defaultName: "External"
    )

    /// List-only row for the laptop keyboard. Not stored in external-keyboard buckets.
    static let macbookBuiltin = ExternalKeyboardIdentity(
        id: "builtin-macbook",
        vendorID: 1452,
        productID: 832,
        manufacturer: "Apple",
        product: "Internal Keyboard",
        serial: "",
        defaultName: "MacBook keyboard"
    )

    /// Display-only label for leftover lumped external keys on today + the past 3 days.
    /// Does not rewrite stored minute buckets.
    static let assumedKinesisRGBSplit = ExternalKeyboardIdentity(
        id: "handtrack:kinesis-rgb-split",
        vendorID: -1,
        productID: -1,
        manufacturer: "Kinesis",
        product: "RGB Split",
        serial: "",
        defaultName: "Kinesis RGB Split"
    )

    static func make(
        vendorID: Int,
        productID: Int,
        manufacturer: String,
        product: String,
        serial: String = ""
    ) -> ExternalKeyboardIdentity {
        let defaultName = defaultHumanName(manufacturer: manufacturer, product: product)
        let family = normalizedFamily(product: product, manufacturer: manufacturer)
        let id: String
        if vendorID > 0, !family.isEmpty {
            id = "v\(vendorID):\(family)"
        } else if vendorID > 0, productID > 0 {
            id = String(format: "v%d:p%d", vendorID, productID)
        } else if !family.isEmpty {
            id = "n:\(family)"
        } else {
            id = unknown.id
        }
        return ExternalKeyboardIdentity(
            id: id,
            vendorID: vendorID,
            productID: productID,
            manufacturer: manufacturer,
            product: product,
            serial: serial,
            defaultName: defaultName
        )
    }

    static func keyboardTitle(displayName: String) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "External keyboard" }
        if name.range(of: "keyboard", options: .caseInsensitive) != nil {
            return name
        }
        return "\(name) keyboard"
    }

    static func defaultHumanName(manufacturer: String, product: String) -> String {
        let productClean = collapseSpaces(product)
        let brand = cleanedBrand(manufacturer)
        if productClean.isEmpty {
            return brand.isEmpty ? "External" : brand
        }
        let stripped = stripGenericSuffixes(productClean)
        if !brand.isEmpty, stripped.range(of: brand, options: .caseInsensitive) == nil {
            let combined = collapseSpaces("\(brand) \(stripped)")
            return combined.isEmpty ? "External" : combined
        }
        if stripped.isEmpty {
            return brand.isEmpty ? "External" : brand
        }
        return stripped
    }

    static func cleanedBrand(_ raw: String) -> String {
        var parts = collapseSpaces(raw)
            .split(separator: " ")
            .map(String.init)
        let suffixes: Set<String> = [
            "incorporated", "inc.", "inc", "corporation", "corp.", "corp",
            "limited", "ltd.", "ltd", "llc", "co.", "co", "gmbh",
        ]
        while let last = parts.last, suffixes.contains(last.lowercased()) {
            parts.removeLast()
        }
        let joined = parts.joined(separator: " ")
        let lower = joined.lowercased()
        if lower.hasPrefix("kinesis") { return "Kinesis" }
        if lower.hasPrefix("keychron") { return "Keychron" }
        if lower.hasPrefix("apple") { return "Apple" }
        if lower.hasPrefix("logitech") { return "Logitech" }
        return joined
    }

    static func normalizedFamily(product: String, manufacturer: String) -> String {
        let source = product.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? manufacturer
            : product
        var tokens = source.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        let junk: Set<String> = [
            "keyboard", "keypad", "hid", "usb", "device", "left", "right",
            "lh", "rh", "consumer", "control", "composite", "interface",
        ]
        tokens.removeAll { junk.contains($0) }
        return tokens.joined(separator: "-")
    }

    private static func stripGenericSuffixes(_ raw: String) -> String {
        var parts = collapseSpaces(raw)
            .split(separator: " ")
            .map(String.init)
        let suffixes: Set<String> = ["keyboard", "keyboards", "keypad", "hid", "usb"]
        while let last = parts.last, suffixes.contains(last.lowercased()), parts.count > 1 {
            parts.removeLast()
        }
        return parts.joined(separator: " ")
    }

    private static func collapseSpaces(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ExternalKeyboardProfile: Hashable, Codable, Identifiable {
    var id: String
    var vendorID: Int
    var productID: Int
    var manufacturer: String
    var product: String
    var serial: String
    var defaultName: String
    var customName: String?
    var firstSeen: Date
    var lastSeen: Date

    var displayName: String {
        let custom = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        if !defaultName.isEmpty { return defaultName }
        return "External"
    }

    var breakdownTitle: String {
        ExternalKeyboardIdentity.keyboardTitle(displayName: displayName)
    }

    init(
        id: String,
        vendorID: Int,
        productID: Int,
        manufacturer: String,
        product: String,
        serial: String,
        defaultName: String,
        customName: String? = nil,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturer = manufacturer
        self.product = product
        self.serial = serial
        self.defaultName = defaultName
        self.customName = customName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    init(identity: ExternalKeyboardIdentity, at date: Date = Date(), customName: String? = nil) {
        self.init(
            id: identity.id,
            vendorID: identity.vendorID,
            productID: identity.productID,
            manufacturer: identity.manufacturer,
            product: identity.product,
            serial: identity.serial,
            defaultName: identity.defaultName,
            customName: customName,
            firstSeen: date,
            lastSeen: date
        )
    }
}

struct ExternalKeyboardMinuteBucket: Identifiable, Hashable {
    var minuteStart: Date
    var keyboardId: String
    var keyCount: Int

    var id: String { "\(minuteStart.timeIntervalSince1970)|\(keyboardId)" }
}

struct BuiltinKeyboardMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var keyCount: Int

    var id: Date { minuteStart }
}

struct BuiltinKeyboardFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var keyCount: Int
    var durationMinutes: Int = 5

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: durationMinutes, to: slotStart) ?? slotStart
    }
}

struct BuiltinTrackpadClickMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var clickCount: Int

    var id: Date { minuteStart }
}

struct BuiltinTrackpadClickFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var clickCount: Int
    var durationMinutes: Int = 5

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: durationMinutes, to: slotStart) ?? slotStart
    }
}

struct BuiltinTrackpadTravelMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var travelPixels: Double

    var id: Date { minuteStart }
}

struct BuiltinTrackpadTravelFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var travelPixels: Double
    var durationMinutes: Int = 5

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: durationMinutes, to: slotStart) ?? slotStart
    }
}

struct BuiltinTrackpadScrollMinuteBucket: Identifiable, Codable, Hashable {
    var minuteStart: Date
    var scrollPixels: Double

    var id: Date { minuteStart }
}

struct BuiltinTrackpadScrollFiveMinuteSlot: Identifiable, Hashable {
    var slotStart: Date
    var scrollPixels: Double
    var durationMinutes: Int = 5

    var id: Date { slotStart }

    var slotEnd: Date {
        Calendar.current.date(byAdding: .minute, value: durationMinutes, to: slotStart) ?? slotStart
    }
}

/// Mac‑recorded aggregates for a time window. External (plug‑in) series are the primary
/// keystroke/click/travel/scrollBump fields; MacBook built‑in series are separate so bars
/// can merge them for height while context menus can still split keyboard vs trackpad time.
struct ComputerUsageHourSlot: Identifiable, Hashable {
    var hourStart: Date
    var keystrokeCount: Int
    var mouseClickCount: Int
    var travelPixels: Double
    var scrollBumpCount: Int = 0
    var builtinKeystrokeCount: Int = 0
    var builtinTrackpadClickCount: Int = 0
    var builtinTrackpadTravelPixels: Double = 0
    var builtinTrackpadScrollPixels: Double = 0
    /// Per-device external keystrokes. Lumped ``keystrokeCount`` stays the External-tab total.
    var externalKeyboardKeystrokes: [String: Int] = [:]

    var id: Date { hourStart }
}

/// One **hand-tracking day** of Mac-recorded aggregates: minute buckets from **local 3:00 AM → next 3:00 AM**
/// (aligned with ``Date/startOfHandTrackingDay`` — same boundary as iPhone “logical today”).
struct ComputerUsageDaySlot: Identifiable, Hashable {
    var dayStart: Date
    var keystrokeCount: Int
    var mouseClickCount: Int
    var travelPixels: Double
    var scrollBumpCount: Int = 0
    var builtinKeystrokeCount: Int = 0
    var builtinTrackpadClickCount: Int = 0
    var builtinTrackpadTravelPixels: Double = 0
    var builtinTrackpadScrollPixels: Double = 0
    /// Per-device external keystrokes. Lumped ``keystrokeCount`` stays the External-tab total.
    var externalKeyboardKeystrokes: [String: Int] = [:]

    var id: Date { dayStart }
}

/// One **calendar week** (Monday 00:00 → next Monday) of Mac-recorded aggregates.
struct ComputerUsageWeekSlot: Identifiable, Hashable {
    var weekStart: Date
    var keystrokeCount: Int
    var mouseClickCount: Int
    var travelPixels: Double
    var scrollBumpCount: Int = 0
    var builtinKeystrokeCount: Int = 0
    var builtinTrackpadClickCount: Int = 0
    var builtinTrackpadTravelPixels: Double = 0
    var builtinTrackpadScrollPixels: Double = 0

    var id: Date { weekStart }
}

/// One **calendar month** (first day 00:00 → first day of next month) of Mac-recorded aggregates.
struct ComputerUsageMonthSlot: Identifiable, Hashable {
    var monthStart: Date
    var keystrokeCount: Int
    var mouseClickCount: Int
    var travelPixels: Double
    var scrollBumpCount: Int = 0
    var builtinKeystrokeCount: Int = 0
    var builtinTrackpadClickCount: Int = 0
    var builtinTrackpadTravelPixels: Double = 0
    var builtinTrackpadScrollPixels: Double = 0

    var id: Date { monthStart }
}

/// Denormalized rollup of iPhone hourly pain buckets by **hand-tracking day** (3 AM rollover) on the Mac. ``painPlotValue`` retains the legacy “means of hourly averages, then max(L,R)” statistic; twelve‑day lines use worst / average‑of‑logged‑instant snapshot fields.
struct DailyPainRollup: Identifiable, Hashable, Codable {
    var dayStart: Date
    var meanOfHourlyAverageLeft: Double
    var meanOfHourlyAverageRight: Double
    var painPlotValue: Double
    var worstHigherHandPain: Double
    var averageHigherHandPainPerLog: Double
    var hoursWithLogs: Int

    var id: Date { dayStart }
}

struct SyncResponse: Codable {
    var acceptedIDs: [UUID]
}

extension Double {
    /// Unicode vulgar fraction one half (preferred over `"0.5"` in HandTrack UI).
    static let handTrackPainHalfGlyph = "\u{00BD}"

    /// Pain logged in ½ steps for 0 … 5.5 — compact chips (`"3"`, `"3.5"`, `"0.5"`).
    var handTrackPainCompactLabel: String {
        let snapped = (self * 2).rounded() / 2
        let whole = snapped.rounded(.towardZero)
        if abs(snapped - whole) < 0.001 {
            return String(format: "%.0f", snapped)
        }
        return String(format: "%.1f", snapped)
    }

    /// Half-step-snapped numeric string for synced log rows (`"3"`, `"0.5"`).
    var handTrackPainLoggedNumber: String {
        let snapped = (self * 2).rounded() / 2
        let frac = snapped - snapped.rounded(.towardZero)
        if abs(frac) < 0.001 {
            return String(format: "%.0f", snapped)
        }
        return String(format: "%.1f", snapped)
    }
}

extension Date {
    var startOfHour: Date {
        Calendar.current.dateInterval(of: .hour, for: self)?.start ?? self
    }

    var startOfCalendarDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// Start of the calendar week containing this instant (Monday-based).
    var startOfCalendarWeek: Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return calendar.date(from: components) ?? startOfCalendarDay
    }

    /// Start of the calendar month containing this instant.
    var startOfCalendarMonth: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: self)
        return calendar.date(from: components) ?? startOfCalendarDay
    }

    /// Local “hand day” rolls at **3:00 AM** — timestamps before then belong to the window that began yesterday at 3 AM.
    /// Matches iPhone hourly UI’s notion of logical today.
    var startOfHandTrackingDay: Date {
        let calendar = Calendar.current
        let calStart = calendar.startOfDay(for: self)
        guard let threeAMToday = calendar.date(byAdding: .hour, value: 3, to: calStart) else {
            return self
        }
        if self >= threeAMToday {
            return threeAMToday
        }
        return calendar.date(byAdding: .day, value: -1, to: threeAMToday) ?? threeAMToday
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

    /// Locale-friendly hour label without date (e.g. `"5 PM"`) — hour bucket grouping.
    var displayHourBucket: String {
        Self.hourBucketFormatter.string(from: self)
    }

    var displayTime: String {
        Self.timeFormatter.string(from: self)
    }

    private static let hourBucketFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = Calendar.current
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "ha", options: 0, locale: .current) ?? "h a"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
