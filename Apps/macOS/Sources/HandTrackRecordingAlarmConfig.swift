import Foundation

/// Storage keys + defaults for the **Activity Limits** feature. Each activity (keystrokes, mouse clicks,
/// pointer travel) gets its own enabled flag, threshold (count over a rolling minute window), break
/// duration in minutes, and the extra seconds each event adds to a running break timer. Values are
/// persisted via `@AppStorage` so users can edit them in the Activity Limits popover.
enum HandTrackActivityLimitsStorage {
    static let masterEnabledKey = "HandTrack.activityLimits.enabled"
    static let soundNameKey = "HandTrack.activityLimits.soundName"
    static let soundVolumeKey = "HandTrack.activityLimits.soundVolumePercent"

    static let keysEnabledKey = "HandTrack.activityLimits.keys.enabled"
    static let keysThresholdKey = "HandTrack.activityLimits.keys.threshold"
    static let keysWindowMinutesKey = "HandTrack.activityLimits.keys.windowMinutes"
    static let keysBreakMinutesKey = "HandTrack.activityLimits.keys.breakMinutes"
    static let keysExtensionSecondsKey = "HandTrack.activityLimits.keys.extensionSeconds"

    static let clicksEnabledKey = "HandTrack.activityLimits.clicks.enabled"
    static let clicksThresholdKey = "HandTrack.activityLimits.clicks.threshold"
    static let clicksWindowMinutesKey = "HandTrack.activityLimits.clicks.windowMinutes"
    static let clicksBreakMinutesKey = "HandTrack.activityLimits.clicks.breakMinutes"
    static let clicksExtensionSecondsKey = "HandTrack.activityLimits.clicks.extensionSeconds"

    static let travelEnabledKey = "HandTrack.activityLimits.travel.enabled"
    static let travelThresholdKey = "HandTrack.activityLimits.travel.threshold"
    static let travelWindowMinutesKey = "HandTrack.activityLimits.travel.windowMinutes"
    static let travelBreakMinutesKey = "HandTrack.activityLimits.travel.breakMinutes"
    static let travelExtensionSecondsKey = "HandTrack.activityLimits.travel.extensionSeconds"

    /// Window length (minutes) for the "Last XX minutes" dashboard row.
    static let dashboardRollingWindowMinutesKey = "HandTrack.dashboard.rollingWindowMinutes"

    enum Defaults {
        static let masterEnabled = true
        static let soundName = "Tink"
        static let soundVolumePercent = 35

        static let keysEnabled = true
        static let keysThreshold = 1000
        static let keysWindowMinutes = 10
        static let keysBreakMinutes = 3
        static let keysExtensionSeconds = 3

        static let clicksEnabled = true
        static let clicksThreshold = 350
        static let clicksWindowMinutes = 10
        static let clicksBreakMinutes = 3
        static let clicksExtensionSeconds = 3

        static let travelEnabled = true
        static let travelThreshold = 500_000
        static let travelWindowMinutes = 10
        static let travelBreakMinutes = 3
        static let travelExtensionSeconds = 3

        static let dashboardRollingWindowMinutes = 10
    }
}

/// Snapshot of all activity-limit settings at a single point in time. Read from `UserDefaults` so
/// non-View consumers (the controller, alarm feedback) can avoid SwiftUI dependencies.
struct HandTrackActivityLimitsSnapshot {
    struct PerActivity {
        var enabled: Bool
        var threshold: Double
        var windowMinutes: Int
        var breakMinutes: Int
        var extensionSeconds: Int
    }

    var masterEnabled: Bool
    var soundName: String
    var soundVolumePercent: Int

    var keys: PerActivity
    var clicks: PerActivity
    var travel: PerActivity

    static func loadFromUserDefaults() -> HandTrackActivityLimitsSnapshot {
        let d = UserDefaults.standard

        func boolOrDefault(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
        }
        func intOrDefault(_ key: String, _ fallback: Int) -> Int {
            d.object(forKey: key) == nil ? fallback : d.integer(forKey: key)
        }
        func stringOrDefault(_ key: String, _ fallback: String) -> String {
            d.string(forKey: key) ?? fallback
        }

        let keys = PerActivity(
            enabled: boolOrDefault(HandTrackActivityLimitsStorage.keysEnabledKey,
                                   HandTrackActivityLimitsStorage.Defaults.keysEnabled),
            threshold: Double(intOrDefault(HandTrackActivityLimitsStorage.keysThresholdKey,
                                           HandTrackActivityLimitsStorage.Defaults.keysThreshold)),
            windowMinutes: intOrDefault(HandTrackActivityLimitsStorage.keysWindowMinutesKey,
                                        HandTrackActivityLimitsStorage.Defaults.keysWindowMinutes),
            breakMinutes: intOrDefault(HandTrackActivityLimitsStorage.keysBreakMinutesKey,
                                       HandTrackActivityLimitsStorage.Defaults.keysBreakMinutes),
            extensionSeconds: intOrDefault(HandTrackActivityLimitsStorage.keysExtensionSecondsKey,
                                           HandTrackActivityLimitsStorage.Defaults.keysExtensionSeconds)
        )
        let clicks = PerActivity(
            enabled: boolOrDefault(HandTrackActivityLimitsStorage.clicksEnabledKey,
                                   HandTrackActivityLimitsStorage.Defaults.clicksEnabled),
            threshold: Double(intOrDefault(HandTrackActivityLimitsStorage.clicksThresholdKey,
                                           HandTrackActivityLimitsStorage.Defaults.clicksThreshold)),
            windowMinutes: intOrDefault(HandTrackActivityLimitsStorage.clicksWindowMinutesKey,
                                        HandTrackActivityLimitsStorage.Defaults.clicksWindowMinutes),
            breakMinutes: intOrDefault(HandTrackActivityLimitsStorage.clicksBreakMinutesKey,
                                       HandTrackActivityLimitsStorage.Defaults.clicksBreakMinutes),
            extensionSeconds: intOrDefault(HandTrackActivityLimitsStorage.clicksExtensionSecondsKey,
                                           HandTrackActivityLimitsStorage.Defaults.clicksExtensionSeconds)
        )
        let travel = PerActivity(
            enabled: boolOrDefault(HandTrackActivityLimitsStorage.travelEnabledKey,
                                   HandTrackActivityLimitsStorage.Defaults.travelEnabled),
            threshold: Double(intOrDefault(HandTrackActivityLimitsStorage.travelThresholdKey,
                                           HandTrackActivityLimitsStorage.Defaults.travelThreshold)),
            windowMinutes: intOrDefault(HandTrackActivityLimitsStorage.travelWindowMinutesKey,
                                        HandTrackActivityLimitsStorage.Defaults.travelWindowMinutes),
            breakMinutes: intOrDefault(HandTrackActivityLimitsStorage.travelBreakMinutesKey,
                                       HandTrackActivityLimitsStorage.Defaults.travelBreakMinutes),
            extensionSeconds: intOrDefault(HandTrackActivityLimitsStorage.travelExtensionSecondsKey,
                                           HandTrackActivityLimitsStorage.Defaults.travelExtensionSeconds)
        )

        return HandTrackActivityLimitsSnapshot(
            masterEnabled: boolOrDefault(HandTrackActivityLimitsStorage.masterEnabledKey,
                                         HandTrackActivityLimitsStorage.Defaults.masterEnabled),
            soundName: stringOrDefault(HandTrackActivityLimitsStorage.soundNameKey,
                                       HandTrackActivityLimitsStorage.Defaults.soundName),
            soundVolumePercent: intOrDefault(HandTrackActivityLimitsStorage.soundVolumeKey,
                                             HandTrackActivityLimitsStorage.Defaults.soundVolumePercent),
            keys: keys,
            clicks: clicks,
            travel: travel
        )
    }

    /// Persists the editable Activity Limits fields. Sound settings are left unchanged unless
    /// the caller mutated them on this snapshot.
    func saveToUserDefaults() {
        let d = UserDefaults.standard
        d.set(masterEnabled, forKey: HandTrackActivityLimitsStorage.masterEnabledKey)
        d.set(soundName, forKey: HandTrackActivityLimitsStorage.soundNameKey)
        d.set(soundVolumePercent, forKey: HandTrackActivityLimitsStorage.soundVolumeKey)

        func saveActivity(_ activity: PerActivity, enabledKey: String, thresholdKey: String,
                          windowKey: String, breakKey: String, extensionKey: String) {
            d.set(activity.enabled, forKey: enabledKey)
            d.set(Int(activity.threshold.rounded()), forKey: thresholdKey)
            d.set(activity.windowMinutes, forKey: windowKey)
            d.set(activity.breakMinutes, forKey: breakKey)
            d.set(activity.extensionSeconds, forKey: extensionKey)
        }

        saveActivity(
            keys,
            enabledKey: HandTrackActivityLimitsStorage.keysEnabledKey,
            thresholdKey: HandTrackActivityLimitsStorage.keysThresholdKey,
            windowKey: HandTrackActivityLimitsStorage.keysWindowMinutesKey,
            breakKey: HandTrackActivityLimitsStorage.keysBreakMinutesKey,
            extensionKey: HandTrackActivityLimitsStorage.keysExtensionSecondsKey
        )
        saveActivity(
            clicks,
            enabledKey: HandTrackActivityLimitsStorage.clicksEnabledKey,
            thresholdKey: HandTrackActivityLimitsStorage.clicksThresholdKey,
            windowKey: HandTrackActivityLimitsStorage.clicksWindowMinutesKey,
            breakKey: HandTrackActivityLimitsStorage.clicksBreakMinutesKey,
            extensionKey: HandTrackActivityLimitsStorage.clicksExtensionSecondsKey
        )
        saveActivity(
            travel,
            enabledKey: HandTrackActivityLimitsStorage.travelEnabledKey,
            thresholdKey: HandTrackActivityLimitsStorage.travelThresholdKey,
            windowKey: HandTrackActivityLimitsStorage.travelWindowMinutesKey,
            breakKey: HandTrackActivityLimitsStorage.travelBreakMinutesKey,
            extensionKey: HandTrackActivityLimitsStorage.travelExtensionSecondsKey
        )
    }
}

enum HandTrackActivityKind: String, CaseIterable, Identifiable, Hashable {
    case keystrokes
    case mouseClicks
    case pointerTravel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keystrokes: return "Keys"
        case .mouseClicks: return "Clicks"
        case .pointerTravel: return "Pointer travel"
        }
    }

    var unitNoun: String {
        switch self {
        case .keystrokes: return "keys"
        case .mouseClicks: return "clicks"
        case .pointerTravel: return "px"
        }
    }
}

// MARK: - Per-keyboard limits (Keyboards tab)

enum KeyboardLimitWindowHours: Int, CaseIterable, Identifiable, Codable {
    case one = 1
    case three = 3
    case six = 6
    case twelve = 12
    case twentyFour = 24

    var id: Int { rawValue }

    var menuTitle: String {
        self == .one ? "1 hour" : "\(rawValue) hours"
    }
}

enum KeyboardLimitUnit: String, CaseIterable, Identifiable, Codable {
    case keystrokes
    case minutes

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .keystrokes: return "keystrokes"
        case .minutes: return "minutes"
        }
    }
}

struct KeyboardLimitRule: Codable, Equatable {
    var enabled: Bool
    var windowHours: Int
    var unit: KeyboardLimitUnit
    var threshold: Int

    static let disabledDefault = KeyboardLimitRule(
        enabled: false,
        windowHours: KeyboardLimitWindowHours.six.rawValue,
        unit: .minutes,
        threshold: 30
    )

    var resolvedWindowHours: Int {
        KeyboardLimitWindowHours(rawValue: windowHours)?.rawValue
            ?? KeyboardLimitWindowHours.six.rawValue
    }
}

enum KeyboardLimitClock {
    static func rollingStart(hours: Int, now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(max(1, hours) * 3600))
    }
}

enum HandTrackKeyboardLimitsStorage {
    static let rulesKey = "HandTrack.keyboardLimits.rulesById"

    static func loadRules() -> [String: KeyboardLimitRule] {
        guard let data = UserDefaults.standard.data(forKey: rulesKey),
              let decoded = try? JSONDecoder().decode([String: KeyboardLimitRule].self, from: data)
        else { return [:] }
        return decoded
    }

    static func saveRules(_ rules: [String: KeyboardLimitRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: rulesKey)
    }
}

struct KeyboardLimitStatus: Equatable {
    var rule: KeyboardLimitRule
    var keystrokes: Int
    var usedAmount: Int
    var resetsAt: Date?
    var isOver: Bool

    var resetCaption: String? {
        guard isOver, let resetsAt else { return nil }
        return "Limit resets at \(Self.timeFormatter.string(from: resetsAt))"
    }

    var usageCaption: String {
        let unit = rule.unit.menuTitle
        return "\(usedAmount.formatted()) of \(max(1, rule.threshold).formatted()) \(unit)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
