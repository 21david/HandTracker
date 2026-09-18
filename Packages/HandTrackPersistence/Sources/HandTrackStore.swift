import Foundation
import Combine
import SQLite3
#if os(macOS)
import AppKit
#endif

private struct DailyPainRollupSnapshot {
    /// Legacy ``DailyPainRollup.painPlotValue`` (hourly means pipeline).
    var legacyPainPlot: Double
    /// Highest `max(left, right)` seen in any synced log that calendar day.
    var worstHigherHand: Double
    /// Mean of `max(left, right)` over every log that day (one value per entry).
    var averageHigherHandPerLog: Double
}

@MainActor
final class HandTrackStore: ObservableObject {
    @Published private(set) var hourlyLogs: [HourlyHandLog] = []
    /// Live input series are intentionally *not* `@Published`. Mutating them on every
    /// keystroke used to invalidate the whole SwiftUI dashboard; macOS UI observes
    /// ``livePulse`` (coalesced) instead. Call ``notifyStructuralChange()`` after
    /// bulk loads / non-live edits. iOS still gets `objectWillChange` from the live flush.
    private(set) var keystrokeBuckets: [KeystrokeMinuteBucket] = []
    private(set) var mouseClickBuckets: [MouseClickMinuteBucket] = []
    private(set) var mouseTravelBuckets: [MouseTravelMinuteBucket] = []
    private(set) var scrollBumpBuckets: [ScrollBumpMinuteBucket] = []
    private(set) var builtinKeyboardBuckets: [BuiltinKeyboardMinuteBucket] = []
    /// Per-device external keystrokes. The lumped ``keystrokeBuckets`` series is unchanged.
    private(set) var externalKeyboardBuckets: [ExternalKeyboardMinuteBucket] = []
    private(set) var externalKeyboardProfiles: [String: ExternalKeyboardProfile] = [:]
    private(set) var builtinTrackpadClickBuckets: [BuiltinTrackpadClickMinuteBucket] = []
    private(set) var builtinTrackpadTravelBuckets: [BuiltinTrackpadTravelMinuteBucket] = []
    private(set) var builtinTrackpadScrollBuckets: [BuiltinTrackpadScrollMinuteBucket] = []
    @Published private(set) var dailyPainRollups: [DailyPainRollup] = []

    let storageDirectory: URL
    /// Mac live charts observe this instead of the whole store, so typing/scroll
    /// does not rebuild the heavy 12h/12d Charts stack.
    let livePulse = HandTrackLivePulse()

    private let databaseURL: URL
    private var database: OpaquePointer?
    /// Pain figures keyed by ``Date/startOfHandTrackingDay`` epoch (`timeIntervalSince1970`), mirrored in ``dailyPainRollups``.
    private var dailyPainRollupSnapshots: [TimeInterval: DailyPainRollupSnapshot] = [:]

    private var lastLivePublishAt: CFAbsoluteTime = 0
    private var lastDeferredLivePublishAt: CFAbsoluteTime = 0
    /// Live UI coalesce for keys/clicks/travel/scroll (~5 updates/sec).
    private static let livePublishMinInterval: CFAbsoluteTime = 0.18

    /// Keys/clicks — flush on the short live UI cadence.
    private var pendingLiveKinds: Set<HandTrackLivePulse.Kind> = []
    /// Travel/scroll — same cadence, separate queue so key flushes don't rebuild those charts.
    private var pendingDeferredLiveKinds: Set<HandTrackLivePulse.Kind> = []
    private var livePublishScheduled = false
    private var deferredLivePublishScheduled = false
    private var scrollGateRetryScheduled = false

    #if os(macOS)
    /// Set by the Mac app to pause Chart invalidation while a dashboard ScrollView is moving.
    static var shouldDeferLiveUIFlush: () -> Bool = { false }
    #endif

    /// Coalesce SQLite writes so typing doesn't sync-write on every key.
    private var persistFlushScheduled = false
    private var dirtyKeystrokeMinutes = Set<TimeInterval>()
    private var dirtyMouseClickMinutes = Set<TimeInterval>()
    private var dirtyMouseTravelMinutes = Set<TimeInterval>()
    private var dirtyScrollBumpMinutes = Set<TimeInterval>()
    private var dirtyBuiltinKeyboardMinutes = Set<TimeInterval>()
    private var dirtyExternalKeyboardKeys = Set<String>()
    private var dirtyBuiltinTrackpadClickMinutes = Set<TimeInterval>()
    private var dirtyBuiltinTrackpadTravelMinutes = Set<TimeInterval>()
    private var dirtyBuiltinTrackpadScrollMinutes = Set<TimeInterval>()
    private static let persistFlushDelay: TimeInterval = 2.0


    /// For rare non-live mutations (load, migrations) that views may read without a pulse bump.
    func notifyStructuralChange() {
        objectWillChange.send()
    }

    init(storageDirectory: URL? = nil) {
        let baseDirectory = storageDirectory ?? Self.defaultStorageDirectory()
        self.storageDirectory = baseDirectory
        self.databaseURL = baseDirectory.appendingPathComponent("handtrack.sqlite")

        load()
        #if os(macOS)
        migrateMisattributedMacBookKeystrokesToExternalLastHourIfNeeded()
        #endif
    }

    /// One-time: move recent MacBook built-in keystroke buckets into the external keyboard
    /// series (Karabiner misattribution counted docked typing as MacBook).
    func migrateMisattributedMacBookKeystrokesToExternalLastHourIfNeeded(reference: Date = Date()) {
        let flagKey = "HandTrack.migratedMisattributedMacBookKeystrokesToExternalLastHour.v3"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        // Slightly over one hour so minute-boundary / launch lag does not leave stragglers.
        let cutoff = reference.addingTimeInterval(-90 * 60).startOfMinute
        var transferredTotal = 0
        var clearedMinuteStarts: [Date] = []

        for bucket in builtinKeyboardBuckets where bucket.minuteStart >= cutoff && bucket.keyCount > 0 {
            let moveCount = bucket.keyCount
            transferredTotal += moveCount

            if let index = keystrokeBuckets.firstIndex(where: { $0.minuteStart == bucket.minuteStart }) {
                keystrokeBuckets[index].keyCount += moveCount
                save(keystrokeBuckets[index])
            } else {
                let external = KeystrokeMinuteBucket(
                    minuteStart: bucket.minuteStart,
                    keyCount: moveCount
                )
                keystrokeBuckets.append(external)
                save(external)
            }
            clearedMinuteStarts.append(bucket.minuteStart)
        }

        if !clearedMinuteStarts.isEmpty {
            let cleared = Set(clearedMinuteStarts)
            builtinKeyboardBuckets.removeAll { cleared.contains($0.minuteStart) }
            for minuteStart in clearedMinuteStarts {
                deleteBuiltinKeyboardBucket(minuteStart: minuteStart)
            }
            keystrokeBuckets.sort { $0.minuteStart < $1.minuteStart }
            publishLiveBucketsChanged()
        }

        UserDefaults.standard.set(true, forKey: flagKey)
        if transferredTotal > 0 {
            print("HandTrack: moved \(transferredTotal) keystrokes from last hour MacBook series into external keyboard")
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func saveHourlyLog(
        painLevelLeft: Double,
        painLevelRight: Double,
        minutesHandsUsed: Int,
        journalEntry: String
    ) {
        let now = Date()
        let log = HourlyHandLog(
            hourStart: now.startOfHour,
            painLevelLeft: painLevelLeft,
            painLevelRight: painLevelRight,
            minutesHandsUsed: minutesHandsUsed,
            journalEntry: journalEntry,
            createdAt: now,
            updatedAt: now,
            syncStatus: .pending
        )
        hourlyLogs.insert(log, at: 0)
        save(log)
        hourlyLogsDidChangePersisted()
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

        hourlyLogs.sort {
            if $0.hourStart != $1.hourStart { return $0.hourStart > $1.hourStart }
            return $0.createdAt > $1.createdAt
        }
        for log in logsToSave {
            do {
                try saveOrThrow(log)
            } catch {
                print("Failed to persist imported hourly log: \(error)")
            }
        }
        try? rebuildDailyPainRollupsFromHourlyLogs()
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
        recordKeystrokes(1, at: timestamp)
    }

    func recordKeystrokes(_ count: Int, at timestamp: Date = Date()) {
        guard count > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        upsertSortedMinuteBucket(
            minuteStart: minuteStart,
            buckets: &keystrokeBuckets,
            minuteOf: { $0.minuteStart },
            increment: { $0.keyCount += count },
            create: { KeystrokeMinuteBucket(minuteStart: minuteStart, keyCount: count) }
        )
        markDirtyKeystroke(minuteStart)
        publishLiveKind(.keystrokes, deferForScrollTravel: false)
        #if os(macOS)
        livePulse.noteDebug(.keystrokes, amount: Double(count))
        #endif
    }

    func recordMouseClick(at timestamp: Date = Date()) {
        recordMouseClicks(1, at: timestamp)
    }

    func recordMouseClicks(_ count: Int, at timestamp: Date = Date()) {
        guard count > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        upsertSortedMinuteBucket(
            minuteStart: minuteStart,
            buckets: &mouseClickBuckets,
            minuteOf: { $0.minuteStart },
            increment: { $0.clickCount += count },
            create: { MouseClickMinuteBucket(minuteStart: minuteStart, clickCount: count) }
        )
        markDirtyMouseClick(minuteStart)
        publishLiveKind(.mouseClicks, deferForScrollTravel: false)
        #if os(macOS)
        livePulse.noteDebug(.mouseClicks, amount: Double(count))
        #endif
    }

    func recordExternalKeyboardKeystrokes(
        _ count: Int,
        identity: ExternalKeyboardIdentity,
        at timestamp: Date = Date()
    ) {
        guard count > 0, !identity.id.isEmpty else { return }
        upsertExternalKeyboardProfile(identity, at: timestamp)
        let minuteStart = timestamp.startOfMinute
        if let last = externalKeyboardBuckets.last,
           last.minuteStart == minuteStart,
           last.keyboardId == identity.id
        {
            externalKeyboardBuckets[externalKeyboardBuckets.count - 1].keyCount += count
        } else if let index = externalKeyboardBuckets.lastIndex(where: {
            $0.minuteStart == minuteStart && $0.keyboardId == identity.id
        }) {
            externalKeyboardBuckets[index].keyCount += count
        } else {
            externalKeyboardBuckets.append(
                ExternalKeyboardMinuteBucket(
                    minuteStart: minuteStart,
                    keyboardId: identity.id,
                    keyCount: count
                )
            )
            if externalKeyboardBuckets.last.map({ $0.minuteStart < minuteStart }) != true {
                externalKeyboardBuckets.sort {
                    if $0.minuteStart != $1.minuteStart { return $0.minuteStart < $1.minuteStart }
                    return $0.keyboardId < $1.keyboardId
                }
            }
        }
        dirtyExternalKeyboardKeys.insert(Self.externalKeyboardDirtyKey(minuteStart: minuteStart, keyboardId: identity.id))
        schedulePersistFlush()
        #if os(macOS)
        // Same identity just stored in `external_keyboard_minute_buckets`.
        // The Keyboards list flashes this id so a correct highlight == correct tracking.
        livePulse.noteExternalKeyboardDebug(
            keyboardId: identity.id,
            displayName: displayName(forExternalKeyboard: identity.id),
            amount: Double(count)
        )
        #endif
    }

    func registerExternalKeyboards(_ identities: [ExternalKeyboardIdentity], at timestamp: Date = Date()) {
        var changed = false
        for identity in identities where identity.id != ExternalKeyboardIdentity.unknown.id {
            if upsertExternalKeyboardProfile(identity, at: timestamp) {
                changed = true
            }
        }
        if changed {
            persistExternalKeyboardProfiles()
            notifyStructuralChange()
        }
    }

    @discardableResult
    func setExternalKeyboardCustomName(id: String, name: String?) -> ExternalKeyboardProfile? {
        guard var profile = externalKeyboardProfiles[id] else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        profile.customName = trimmed.isEmpty ? nil : trimmed
        externalKeyboardProfiles[id] = profile
        persistExternalKeyboardProfiles()
        notifyStructuralChange()
        return profile
    }

    func displayName(forExternalKeyboard id: String) -> String {
        if let profile = externalKeyboardProfiles[id] {
            return profile.displayName
        }
        if id == ExternalKeyboardIdentity.unknown.id {
            return ExternalKeyboardIdentity.unknown.defaultName
        }
        return "External"
    }

    func breakdownTitle(forExternalKeyboard id: String) -> String {
        ExternalKeyboardIdentity.keyboardTitle(displayName: displayName(forExternalKeyboard: id))
    }

    func allExternalKeyboardProfiles() -> [ExternalKeyboardProfile] {
        let profiles = Array(externalKeyboardProfiles.values)
        let hasRealKinesis = profiles.contains { Self.isRealKinesisProfile($0) }
        return profiles
            .filter { profile in
                if hasRealKinesis, profile.id == ExternalKeyboardIdentity.assumedKinesisRGBSplit.id {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.firstSeen != rhs.firstSeen { return lhs.firstSeen < rhs.firstSeen }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// Leftover lumped external keys (no per-device buckets) stay “External keyboard”
    /// except today + the past 3 hand-tracking days, which display as the real Kinesis.
    /// `unknown-external` debug/fallback buckets in that window fold into the same row.
    /// Stored minute buckets are not rewritten.
    func attributedExternalKeyboardKeystrokes(
        lumpedKeystrokes: Int,
        perKeyboard: [String: Int],
        windowStart: Date,
        reference: Date = Date()
    ) -> [(id: String, keystrokes: Int)] {
        let attributed = perKeyboard.values.reduce(0, +)
        let leftover = max(0, lumpedKeystrokes - attributed)
        var merged = perKeyboard
        let foldIntoKinesis = Self.isAssumedKinesisDisplayWindow(windowStart: windowStart, reference: reference)
        let unknownCount = merged[ExternalKeyboardIdentity.unknown.id] ?? 0
        let kinesisID = kinesisDisplayKeyboardID()
        if foldIntoKinesis {
            if unknownCount > 0 {
                merged.removeValue(forKey: ExternalKeyboardIdentity.unknown.id)
                merged[kinesisID, default: 0] += unknownCount
            }
            if kinesisID != ExternalKeyboardIdentity.assumedKinesisRGBSplit.id,
               let assumedCount = merged.removeValue(forKey: ExternalKeyboardIdentity.assumedKinesisRGBSplit.id),
               assumedCount > 0
            {
                merged[kinesisID, default: 0] += assumedCount
            }
            if leftover > 0 {
                merged[kinesisID, default: 0] += leftover
            }
        } else if leftover > 0 {
            merged[ExternalKeyboardIdentity.unknown.id, default: 0] += leftover
        }
        return merged
            .filter { $0.value > 0 }
            .map { (id: $0.key, keystrokes: $0.value) }
            .sorted { lhs, rhs in
                if lhs.keystrokes != rhs.keystrokes { return lhs.keystrokes > rhs.keystrokes }
                return displayName(forExternalKeyboard: lhs.id)
                    .localizedCaseInsensitiveCompare(displayName(forExternalKeyboard: rhs.id)) == .orderedAscending
            }
    }

    @discardableResult
    private func upsertExternalKeyboardProfile(
        _ identity: ExternalKeyboardIdentity,
        at timestamp: Date
    ) -> Bool {
        guard identity.id != ExternalKeyboardIdentity.unknown.id else { return false }
        guard identity.id != ExternalKeyboardIdentity.macbookBuiltin.id else { return false }
        if var existing = externalKeyboardProfiles[identity.id] {
            var changed = false
            if timestamp.timeIntervalSince(existing.lastSeen) >= 3600 {
                existing.lastSeen = timestamp
                changed = true
            }
            if existing.defaultName.isEmpty, !identity.defaultName.isEmpty {
                existing.defaultName = identity.defaultName
                changed = true
            }
            if existing.manufacturer.isEmpty, !identity.manufacturer.isEmpty {
                existing.manufacturer = identity.manufacturer
                changed = true
            }
            if existing.product.isEmpty, !identity.product.isEmpty {
                existing.product = identity.product
                changed = true
            }
            if changed {
                externalKeyboardProfiles[identity.id] = existing
                persistExternalKeyboardProfiles()
            }
            return changed
        }
        externalKeyboardProfiles[identity.id] = ExternalKeyboardProfile(identity: identity, at: timestamp)
        persistExternalKeyboardProfiles()
        notifyStructuralChange()
        return true
    }

    private func kinesisDisplayKeyboardID() -> String {
        if let real = externalKeyboardProfiles.values.first(where: { Self.isRealKinesisProfile($0) }) {
            return real.id
        }
        if let match = externalKeyboardProfiles.values.first(where: { profile in
            profile.id == ExternalKeyboardIdentity.assumedKinesisRGBSplit.id
                || profile.displayName.localizedCaseInsensitiveContains("kinesis")
                || profile.defaultName.localizedCaseInsensitiveContains("kinesis")
                || profile.product.localizedCaseInsensitiveContains("kinesis")
                || profile.manufacturer.localizedCaseInsensitiveContains("kinesis")
        }) {
            return match.id
        }
        return ExternalKeyboardIdentity.assumedKinesisRGBSplit.id
    }

    private static func isRealKinesisProfile(_ profile: ExternalKeyboardProfile) -> Bool {
        guard profile.id != ExternalKeyboardIdentity.assumedKinesisRGBSplit.id else { return false }
        return profile.displayName.localizedCaseInsensitiveContains("kinesis")
            || profile.defaultName.localizedCaseInsensitiveContains("kinesis")
            || profile.product.localizedCaseInsensitiveContains("kinesis")
            || profile.manufacturer.localizedCaseInsensitiveContains("kinesis")
    }

    private static func isAssumedKinesisDisplayWindow(windowStart: Date, reference: Date) -> Bool {
        let today = reference.startOfHandTrackingDay
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -3, to: today) else {
            return windowStart >= today
        }
        return windowStart >= cutoff
    }

    private func ensureAssumedKinesisRGBSplitProfile() {
        if externalKeyboardProfiles.values.contains(where: { Self.isRealKinesisProfile($0) }) {
            return
        }
        let identity = ExternalKeyboardIdentity.assumedKinesisRGBSplit
        guard externalKeyboardProfiles[identity.id] == nil else { return }
        let now = Date()
        externalKeyboardProfiles[identity.id] = ExternalKeyboardProfile(
            identity: identity,
            at: now,
            customName: "Kinesis RGB Split"
        )
        persistExternalKeyboardProfiles()
    }

    private static func externalKeyboardDirtyKey(minuteStart: Date, keyboardId: String) -> String {
        "\(minuteStart.timeIntervalSince1970)|\(keyboardId)"
    }

    func recordBuiltinKeystrokes(_ count: Int, at timestamp: Date = Date()) {
        guard count > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        upsertSortedMinuteBucket(
            minuteStart: minuteStart,
            buckets: &builtinKeyboardBuckets,
            minuteOf: { $0.minuteStart },
            increment: { $0.keyCount += count },
            create: { BuiltinKeyboardMinuteBucket(minuteStart: minuteStart, keyCount: count) }
        )
        markDirtyBuiltinKeyboard(minuteStart)
        publishLiveKind(.builtinKeystrokes, deferForScrollTravel: false)
        #if os(macOS)
        livePulse.noteDebug(.builtinKeystrokes, amount: Double(count))
        livePulse.noteExternalKeyboardDebug(
            keyboardId: ExternalKeyboardIdentity.macbookBuiltin.id,
            displayName: ExternalKeyboardIdentity.macbookBuiltin.defaultName,
            amount: Double(count)
        )
        #endif
    }

    func recordMouseTravelPixels(_ pixels: Double, at timestamp: Date = Date()) {
        guard pixels.isFinite, pixels > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        upsertSortedMinuteBucket(
            minuteStart: minuteStart,
            buckets: &mouseTravelBuckets,
            minuteOf: { $0.minuteStart },
            increment: { $0.travelPixels += pixels },
            create: { MouseTravelMinuteBucket(minuteStart: minuteStart, travelPixels: pixels) }
        )
        markDirtyMouseTravel(minuteStart)
        publishLiveKind(.mouseTravel, deferForScrollTravel: true)
        #if os(macOS)
        livePulse.noteDebug(.mouseTravel, amount: pixels)
        #endif
    }

    func recordScrollBumps(_ count: Int = 1, at timestamp: Date = Date()) {
        guard count > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        upsertSortedMinuteBucket(
            minuteStart: minuteStart,
            buckets: &scrollBumpBuckets,
            minuteOf: { $0.minuteStart },
            increment: { $0.bumpCount += count },
            create: { ScrollBumpMinuteBucket(minuteStart: minuteStart, bumpCount: count) }
        )
        markDirtyScrollBump(minuteStart)
        publishLiveKind(.scrollBumps, deferForScrollTravel: true)
        #if os(macOS)
        livePulse.noteDebug(.scrollBumps, amount: Double(count))
        #endif
    }

    func recordBuiltinKeystroke(at timestamp: Date = Date()) {
        recordBuiltinKeystrokes(1, at: timestamp)
    }

    func recordBuiltinTrackpadClick(at timestamp: Date = Date()) {
        let minuteStart = timestamp.startOfMinute
        upsertSortedMinuteBucket(
            minuteStart: minuteStart,
            buckets: &builtinTrackpadClickBuckets,
            minuteOf: { $0.minuteStart },
            increment: { $0.clickCount += 1 },
            create: { BuiltinTrackpadClickMinuteBucket(minuteStart: minuteStart, clickCount: 1) }
        )
        markDirtyBuiltinTrackpadClick(minuteStart)
        publishLiveKind(.builtinTrackpadClicks, deferForScrollTravel: false)
        #if os(macOS)
        livePulse.noteDebug(.builtinTrackpadClicks, amount: 1)
        #endif
    }

    func recordBuiltinTrackpadTravelPixels(_ pixels: Double, at timestamp: Date = Date()) {
        guard pixels.isFinite, pixels > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        upsertSortedMinuteBucket(
            minuteStart: minuteStart,
            buckets: &builtinTrackpadTravelBuckets,
            minuteOf: { $0.minuteStart },
            increment: { $0.travelPixels += pixels },
            create: { BuiltinTrackpadTravelMinuteBucket(minuteStart: minuteStart, travelPixels: pixels) }
        )
        markDirtyBuiltinTrackpadTravel(minuteStart)
        publishLiveKind(.builtinTrackpadTravel, deferForScrollTravel: true)
        #if os(macOS)
        livePulse.noteDebug(.builtinTrackpadTravel, amount: pixels)
        #endif
    }

    func recordBuiltinTrackpadScrollPixels(_ pixels: Double, at timestamp: Date = Date()) {
        guard pixels.isFinite, pixels > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        upsertSortedMinuteBucket(
            minuteStart: minuteStart,
            buckets: &builtinTrackpadScrollBuckets,
            minuteOf: { $0.minuteStart },
            increment: { $0.scrollPixels += pixels },
            create: { BuiltinTrackpadScrollMinuteBucket(minuteStart: minuteStart, scrollPixels: pixels) }
        )
        markDirtyBuiltinTrackpadScroll(minuteStart)
        publishLiveKind(.builtinTrackpadScroll, deferForScrollTravel: true)
        #if os(macOS)
        livePulse.noteDebug(.builtinTrackpadScroll, amount: pixels)
        #endif
    }

    /// Hot path: current minute is almost always the last bucket — avoid O(n) scans per event.
    private func upsertSortedMinuteBucket<Bucket>(
        minuteStart: Date,
        buckets: inout [Bucket],
        minuteOf: (Bucket) -> Date,
        increment: (inout Bucket) -> Void,
        create: () -> Bucket
    ) {
        if let last = buckets.last, minuteOf(last) == minuteStart {
            increment(&buckets[buckets.count - 1])
            return
        }
        if buckets.last.map({ minuteOf($0) < minuteStart }) ?? true {
            buckets.append(create())
            return
        }
        if let index = buckets.firstIndex(where: { minuteOf($0) == minuteStart }) {
            increment(&buckets[index])
        } else {
            buckets.append(create())
            buckets.sort { minuteOf($0) < minuteOf($1) }
        }
    }

    private func markDirtyKeystroke(_ minuteStart: Date) {
        dirtyKeystrokeMinutes.insert(minuteStart.timeIntervalSince1970)
        schedulePersistFlush()
    }

    private func markDirtyMouseClick(_ minuteStart: Date) {
        dirtyMouseClickMinutes.insert(minuteStart.timeIntervalSince1970)
        schedulePersistFlush()
    }

    private func markDirtyMouseTravel(_ minuteStart: Date) {
        dirtyMouseTravelMinutes.insert(minuteStart.timeIntervalSince1970)
        schedulePersistFlush()
    }

    private func markDirtyScrollBump(_ minuteStart: Date) {
        dirtyScrollBumpMinutes.insert(minuteStart.timeIntervalSince1970)
        schedulePersistFlush()
    }

    private func markDirtyBuiltinKeyboard(_ minuteStart: Date) {
        dirtyBuiltinKeyboardMinutes.insert(minuteStart.timeIntervalSince1970)
        schedulePersistFlush()
    }

    private func markDirtyBuiltinTrackpadClick(_ minuteStart: Date) {
        dirtyBuiltinTrackpadClickMinutes.insert(minuteStart.timeIntervalSince1970)
        schedulePersistFlush()
    }

    private func markDirtyBuiltinTrackpadTravel(_ minuteStart: Date) {
        dirtyBuiltinTrackpadTravelMinutes.insert(minuteStart.timeIntervalSince1970)
        schedulePersistFlush()
    }

    private func markDirtyBuiltinTrackpadScroll(_ minuteStart: Date) {
        dirtyBuiltinTrackpadScrollMinutes.insert(minuteStart.timeIntervalSince1970)
        schedulePersistFlush()
    }

    private func schedulePersistFlush() {
        guard !persistFlushScheduled else { return }
        persistFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistFlushDelay) { [weak self] in
            self?.flushDirtyPersists()
        }
    }

    private func flushDirtyPersists() {
        persistFlushScheduled = false

        let keystrokes: [KeystrokeMinuteBucket] = dirtyKeystrokeMinutes.compactMap { epoch in
            let minute = Date(timeIntervalSince1970: epoch)
            return keystrokeBuckets.first { $0.minuteStart == minute }
        }
        let mouseClicks: [MouseClickMinuteBucket] = dirtyMouseClickMinutes.compactMap { epoch in
            let minute = Date(timeIntervalSince1970: epoch)
            return mouseClickBuckets.first { $0.minuteStart == minute }
        }
        let mouseTravel: [MouseTravelMinuteBucket] = dirtyMouseTravelMinutes.compactMap { epoch in
            let minute = Date(timeIntervalSince1970: epoch)
            return mouseTravelBuckets.first { $0.minuteStart == minute }
        }
        let scrollBumps: [ScrollBumpMinuteBucket] = dirtyScrollBumpMinutes.compactMap { epoch in
            let minute = Date(timeIntervalSince1970: epoch)
            return scrollBumpBuckets.first { $0.minuteStart == minute }
        }
        let builtinKeys: [BuiltinKeyboardMinuteBucket] = dirtyBuiltinKeyboardMinutes.compactMap { epoch in
            let minute = Date(timeIntervalSince1970: epoch)
            return builtinKeyboardBuckets.first { $0.minuteStart == minute }
        }
        let externalKeyboards: [ExternalKeyboardMinuteBucket] = dirtyExternalKeyboardKeys.compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let epoch = TimeInterval(parts[0]) else { return nil }
            let minute = Date(timeIntervalSince1970: epoch)
            let keyboardId = String(parts[1])
            return externalKeyboardBuckets.first { $0.minuteStart == minute && $0.keyboardId == keyboardId }
        }
        let builtinClicks: [BuiltinTrackpadClickMinuteBucket] = dirtyBuiltinTrackpadClickMinutes.compactMap { epoch in
            let minute = Date(timeIntervalSince1970: epoch)
            return builtinTrackpadClickBuckets.first { $0.minuteStart == minute }
        }
        let builtinTravel: [BuiltinTrackpadTravelMinuteBucket] = dirtyBuiltinTrackpadTravelMinutes.compactMap { epoch in
            let minute = Date(timeIntervalSince1970: epoch)
            return builtinTrackpadTravelBuckets.first { $0.minuteStart == minute }
        }
        let builtinScroll: [BuiltinTrackpadScrollMinuteBucket] = dirtyBuiltinTrackpadScrollMinutes.compactMap { epoch in
            let minute = Date(timeIntervalSince1970: epoch)
            return builtinTrackpadScrollBuckets.first { $0.minuteStart == minute }
        }
        let dirtyCount =
            keystrokes.count + mouseClicks.count + mouseTravel.count + scrollBumps.count
            + builtinKeys.count + builtinClicks.count + builtinTravel.count + builtinScroll.count
            + externalKeyboards.count

        dirtyKeystrokeMinutes.removeAll(keepingCapacity: true)
        dirtyMouseClickMinutes.removeAll(keepingCapacity: true)
        dirtyMouseTravelMinutes.removeAll(keepingCapacity: true)
        dirtyScrollBumpMinutes.removeAll(keepingCapacity: true)
        dirtyBuiltinKeyboardMinutes.removeAll(keepingCapacity: true)
        dirtyExternalKeyboardKeys.removeAll(keepingCapacity: true)
        dirtyBuiltinTrackpadClickMinutes.removeAll(keepingCapacity: true)
        dirtyBuiltinTrackpadTravelMinutes.removeAll(keepingCapacity: true)
        dirtyBuiltinTrackpadScrollMinutes.removeAll(keepingCapacity: true)

        guard dirtyCount > 0 else { return }

        for bucket in keystrokes { save(bucket) }
        for bucket in mouseClicks { saveMouseClick(bucket) }
        for bucket in mouseTravel { saveMouseTravel(bucket) }
        for bucket in scrollBumps { saveScrollBump(bucket) }
        for bucket in builtinKeys { saveBuiltinKeyboard(bucket) }
        for bucket in externalKeyboards { saveExternalKeyboardBucket(bucket) }
        for bucket in builtinClicks { saveBuiltinTrackpadClick(bucket) }
        for bucket in builtinTravel { saveBuiltinTrackpadTravel(bucket) }
        for bucket in builtinScroll { saveBuiltinTrackpadScroll(bucket) }
    }

    func builtinKeyboardActivityInLastHours(_ hours: Int, reference: Date = Date()) -> Bool {
        let windowStart = reference.addingTimeInterval(-Double(max(1, hours)) * 3600.0)
        return builtinKeyboardBuckets.contains { bucket in
            bucket.minuteStart >= windowStart && bucket.minuteStart <= reference && bucket.keyCount > 0
        }
    }

    func builtinTrackpadActivityInLastHours(_ hours: Int, reference: Date = Date()) -> Bool {
        let windowStart = reference.addingTimeInterval(-Double(max(1, hours)) * 3600.0)
        let inWindow: (Date) -> Bool = { $0 >= windowStart && $0 <= reference }
        if builtinTrackpadClickBuckets.contains(where: { inWindow($0.minuteStart) && $0.clickCount > 0 }) {
            return true
        }
        if builtinTrackpadTravelBuckets.contains(where: { inWindow($0.minuteStart) && $0.travelPixels > 0 }) {
            return true
        }
        if builtinTrackpadScrollBuckets.contains(where: { inWindow($0.minuteStart) && $0.scrollPixels > 0 }) {
            return true
        }
        return false
    }

    /// Used by one-off migrations that touch multiple live series at once.
    private func publishLiveBucketsChanged() {
        publishLiveKind(.keystrokes, deferForScrollTravel: false)
        publishLiveKind(.builtinKeystrokes, deferForScrollTravel: false)
    }

    private func publishLiveKind(_ kind: HandTrackLivePulse.Kind, deferForScrollTravel: Bool) {
        #if os(macOS)
        if deferForScrollTravel {
            pendingDeferredLiveKinds.insert(kind)
            scheduleLiveFlush(deferred: true)
            return
        }
        #endif
        pendingLiveKinds.insert(kind)
        scheduleLiveFlush(deferred: false)
    }

    private func scheduleLiveFlush(deferred: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let last = deferred ? lastDeferredLivePublishAt : lastLivePublishAt
        if now - last >= Self.livePublishMinInterval {
            flushPendingLiveKinds(
                reason: deferred ? "travel_scroll_immediate" : "immediate",
                deferred: deferred
            )
            return
        }
        if deferred {
            guard !deferredLivePublishScheduled else { return }
            deferredLivePublishScheduled = true
            let delay = Self.livePublishMinInterval - (now - last)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay)) { [weak self] in
                guard let self else { return }
                self.deferredLivePublishScheduled = false
                self.flushPendingLiveKinds(reason: "travel_scroll_coalesced", deferred: true)
            }
        } else {
            guard !livePublishScheduled else { return }
            livePublishScheduled = true
            let delay = Self.livePublishMinInterval - (now - last)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay)) { [weak self] in
                guard let self else { return }
                self.livePublishScheduled = false
                self.flushPendingLiveKinds(reason: "coalesced", deferred: false)
            }
        }
    }

    private func flushPendingLiveKinds(reason: String, deferred: Bool) {
        #if os(macOS)
        if Self.shouldDeferLiveUIFlush() {
            scheduleFlushAfterScrollGate(deferred: deferred)
            return
        }
        #endif

        let kinds: Set<HandTrackLivePulse.Kind>
        if deferred {
            kinds = pendingDeferredLiveKinds
            pendingDeferredLiveKinds.removeAll(keepingCapacity: true)
        } else {
            kinds = pendingLiveKinds
            pendingLiveKinds.removeAll(keepingCapacity: true)
        }
        guard !kinds.isEmpty else { return }
        if deferred {
            lastDeferredLivePublishAt = CFAbsoluteTimeGetCurrent()
        } else {
            lastLivePublishAt = CFAbsoluteTimeGetCurrent()
        }
        #if os(macOS)
        for kind in kinds {
            livePulse.bump(kind)
        }
        #else
        objectWillChange.send()
        #endif
    }

    #if os(macOS)
    private func scheduleFlushAfterScrollGate(deferred: Bool) {
        _ = deferred
        guard !scrollGateRetryScheduled else { return }
        scrollGateRetryScheduled = true
        scheduleScrollGateRetry()
    }

    private func scheduleScrollGateRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if Self.shouldDeferLiveUIFlush() {
                self.scheduleScrollGateRetry()
                return
            }
            self.scrollGateRetryScheduled = false
            if !self.pendingLiveKinds.isEmpty {
                self.flushPendingLiveKinds(reason: "after_scroll_gate", deferred: false)
            }
            if !self.pendingDeferredLiveKinds.isEmpty {
                self.flushPendingLiveKinds(reason: "after_scroll_gate", deferred: true)
            }
        }
    }
    #endif


    func scrollsInLastMinutes(_ minutes: Int, reference: Date = Date()) -> Int {
        let window = max(1, minutes)
        guard let start = Calendar.current.date(byAdding: .minute, value: -window, to: reference) else { return 0 }
        return scrollBumpBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= start, bucket.minuteStart <= reference else { return sum }
            return sum + bucket.bumpCount
        }
    }

    func scrollsSinceStartOfCurrentHour(reference: Date = Date()) -> Int {
        let calendar = Calendar.current
        let hourStart = reference.startOfHour
        guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return 0 }
        return scrollBumpBuckets
            .filter { $0.minuteStart >= hourStart && $0.minuteStart < hourEnd }
            .reduce(0) { $0 + $1.bumpCount }
    }

    func keysSinceStartOfCurrentHour(reference: Date = Date()) -> Int {
        let calendar = Calendar.current
        let hourStart = reference.startOfHour
        guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return 0 }
        return keystrokeBuckets
            .filter { $0.minuteStart >= hourStart && $0.minuteStart < hourEnd }
            .reduce(0) { $0 + $1.keyCount }
    }

    func clicksSinceStartOfCurrentHour(reference: Date = Date()) -> Int {
        let calendar = Calendar.current
        let hourStart = reference.startOfHour
        guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return 0 }
        return mouseClickBuckets
            .filter { $0.minuteStart >= hourStart && $0.minuteStart < hourEnd }
            .reduce(0) { $0 + $1.clickCount }
    }

    func mouseTravelPixelsSinceStartOfCurrentHour(reference: Date = Date()) -> Double {
        let calendar = Calendar.current
        let hourStart = reference.startOfHour
        guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return 0 }
        return mouseTravelBuckets
            .filter { $0.minuteStart >= hourStart && $0.minuteStart < hourEnd }
            .reduce(0.0) { $0 + $1.travelPixels }
    }

    // MARK: - Current five-minute slot (clock-aligned like the histograms)

    func keysInCurrentFiveMinuteSlot(reference: Date = Date()) -> Int {
        let slotStart = reference.startOfFiveMinuteSlot
        guard let slotEnd = Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) else {
            return 0
        }
        return keystrokeBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
            return sum + bucket.keyCount
        }
    }

    func clicksInCurrentFiveMinuteSlot(reference: Date = Date()) -> Int {
        let slotStart = reference.startOfFiveMinuteSlot
        guard let slotEnd = Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) else {
            return 0
        }
        return mouseClickBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
            return sum + bucket.clickCount
        }
    }

    func mouseTravelPixelsInCurrentFiveMinuteSlot(reference: Date = Date()) -> Double {
        let slotStart = reference.startOfFiveMinuteSlot
        guard let slotEnd = Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) else {
            return 0
        }
        return mouseTravelBuckets.reduce(0.0) { sum, bucket in
            guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
            return sum + bucket.travelPixels
        }
    }

    // MARK: - Trailing rolling window (not clock-aligned, used by activity limits + dashboard row)

    /// Sum of keystrokes whose minute-bucket starts within the last `minutes` minutes ending at `reference`.
    func keysInLastMinutes(_ minutes: Int, reference: Date = Date()) -> Int {
        let span = max(1, minutes)
        let start = reference.addingTimeInterval(-Double(span) * 60.0)
        return keystrokeBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= start, bucket.minuteStart <= reference else { return sum }
            return sum + bucket.keyCount
        }
    }

    func keystrokes(forKeyboard keyboardId: String, from start: Date, through end: Date) -> Int {
        keyboardKeystrokeMinuteCounts(forKeyboard: keyboardId, from: start, through: end)
            .reduce(0) { $0 + $1.count }
    }

    func keyboardKeystrokeMinuteCounts(
        forKeyboard keyboardId: String,
        from start: Date,
        through end: Date
    ) -> [(minuteStart: Date, count: Int)] {
        if keyboardId == ExternalKeyboardIdentity.macbookBuiltin.id {
            return builtinKeyboardBuckets.compactMap { bucket in
                guard bucket.minuteStart >= start, bucket.minuteStart <= end, bucket.keyCount > 0 else {
                    return nil
                }
                return (bucket.minuteStart, bucket.keyCount)
            }
        }
        return externalKeyboardBuckets.compactMap { bucket in
            guard bucket.keyboardId == keyboardId,
                  bucket.minuteStart >= start,
                  bucket.minuteStart <= end,
                  bucket.keyCount > 0
            else { return nil }
            return (bucket.minuteStart, bucket.keyCount)
        }
    }

    func clicksInLastMinutes(_ minutes: Int, reference: Date = Date()) -> Int {
        let span = max(1, minutes)
        let start = reference.addingTimeInterval(-Double(span) * 60.0)
        return mouseClickBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= start, bucket.minuteStart <= reference else { return sum }
            return sum + bucket.clickCount
        }
    }

    func mouseTravelPixelsInLastMinutes(_ minutes: Int, reference: Date = Date()) -> Double {
        let span = max(1, minutes)
        let start = reference.addingTimeInterval(-Double(span) * 60.0)
        return mouseTravelBuckets.reduce(0.0) { sum, bucket in
            guard bucket.minuteStart >= start, bucket.minuteStart <= reference else { return sum }
            return sum + bucket.travelPixels
        }
    }

    func averageWordsPerMinuteForCurrentHour(reference: Date = Date()) -> Double {
        let hourStart = reference.startOfHour
        let elapsedMinutes = max(reference.timeIntervalSince(hourStart) / 60, 1)
        let words = Double(keysSinceStartOfCurrentHour(reference: reference)) / 5
        return words / elapsedMinutes
    }

    func keystrokesByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [KeystrokeFiveMinuteSlot] {
        trailingSlotsSinglePass(
            reference: reference,
            count: count,
            minutesPerSlot: minutesPerSlot,
            buckets: keystrokeBuckets,
            minuteOf: { $0.minuteStart },
            valueOf: { Double($0.keyCount) },
            makeSlot: { start, total, duration in
                KeystrokeFiveMinuteSlot(slotStart: start, keyCount: Int(total.rounded()), durationMinutes: duration)
            }
        )
    }

    func mouseClicksByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [MouseClickFiveMinuteSlot] {
        trailingSlotsSinglePass(
            reference: reference,
            count: count,
            minutesPerSlot: minutesPerSlot,
            buckets: mouseClickBuckets,
            minuteOf: { $0.minuteStart },
            valueOf: { Double($0.clickCount) },
            makeSlot: { start, total, duration in
                MouseClickFiveMinuteSlot(slotStart: start, clickCount: Int(total.rounded()), durationMinutes: duration)
            }
        )
    }

    func mouseTravelByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [MouseTravelFiveMinuteSlot] {
        trailingSlotsSinglePass(
            reference: reference,
            count: count,
            minutesPerSlot: minutesPerSlot,
            buckets: mouseTravelBuckets,
            minuteOf: { $0.minuteStart },
            valueOf: { $0.travelPixels },
            makeSlot: { start, total, duration in
                MouseTravelFiveMinuteSlot(slotStart: start, travelPixels: total, durationMinutes: duration)
            }
        )
    }

    func scrollBumpsByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [ScrollBumpFiveMinuteSlot] {
        trailingSlotsSinglePass(
            reference: reference,
            count: count,
            minutesPerSlot: minutesPerSlot,
            buckets: scrollBumpBuckets,
            minuteOf: { $0.minuteStart },
            valueOf: { Double($0.bumpCount) },
            makeSlot: { start, total, duration in
                ScrollBumpFiveMinuteSlot(slotStart: start, bumpCount: Int(total.rounded()), durationMinutes: duration)
            }
        )
    }

    func builtinKeystrokesByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [BuiltinKeyboardFiveMinuteSlot] {
        trailingSlotsSinglePass(
            reference: reference,
            count: count,
            minutesPerSlot: minutesPerSlot,
            buckets: builtinKeyboardBuckets,
            minuteOf: { $0.minuteStart },
            valueOf: { Double($0.keyCount) },
            makeSlot: { start, total, duration in
                BuiltinKeyboardFiveMinuteSlot(slotStart: start, keyCount: Int(total.rounded()), durationMinutes: duration)
            }
        )
    }

    func builtinTrackpadClicksByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [BuiltinTrackpadClickFiveMinuteSlot] {
        trailingSlotsSinglePass(
            reference: reference,
            count: count,
            minutesPerSlot: minutesPerSlot,
            buckets: builtinTrackpadClickBuckets,
            minuteOf: { $0.minuteStart },
            valueOf: { Double($0.clickCount) },
            makeSlot: { start, total, duration in
                BuiltinTrackpadClickFiveMinuteSlot(slotStart: start, clickCount: Int(total.rounded()), durationMinutes: duration)
            }
        )
    }

    func builtinTrackpadTravelByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [BuiltinTrackpadTravelFiveMinuteSlot] {
        trailingSlotsSinglePass(
            reference: reference,
            count: count,
            minutesPerSlot: minutesPerSlot,
            buckets: builtinTrackpadTravelBuckets,
            minuteOf: { $0.minuteStart },
            valueOf: { $0.travelPixels },
            makeSlot: { start, total, duration in
                BuiltinTrackpadTravelFiveMinuteSlot(slotStart: start, travelPixels: total, durationMinutes: duration)
            }
        )
    }

    func builtinTrackpadScrollByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [BuiltinTrackpadScrollFiveMinuteSlot] {
        trailingSlotsSinglePass(
            reference: reference,
            count: count,
            minutesPerSlot: minutesPerSlot,
            buckets: builtinTrackpadScrollBuckets,
            minuteOf: { $0.minuteStart },
            valueOf: { $0.scrollPixels },
            makeSlot: { start, total, duration in
                BuiltinTrackpadScrollFiveMinuteSlot(slotStart: start, scrollPixels: total, durationMinutes: duration)
            }
        )
    }

    /// One pass over sorted minute buckets (was O(slots × history) and ~100ms+ at 1‑min / 60 bars).
    private func trailingSlotsSinglePass<Bucket, Slot>(
        reference: Date,
        count: Int,
        minutesPerSlot: Int,
        buckets: [Bucket],
        minuteOf: (Bucket) -> Date,
        valueOf: (Bucket) -> Double,
        makeSlot: (_ slotStart: Date, _ total: Double, _ duration: Int) -> Slot
    ) -> [Slot] {
        let calendar = Calendar.current
        let duration = max(1, minutesPerSlot)
        let slotCount = max(1, count)
        let currentSlotStart = duration == 5 ? reference.startOfFiveMinuteSlot : reference.startOfMinute
        guard let windowStart = calendar.date(
            byAdding: .minute,
            value: -duration * (slotCount - 1),
            to: currentSlotStart
        ),
            let windowEnd = calendar.date(byAdding: .minute, value: duration, to: currentSlotStart)
        else { return [] }

        var totals = [Double](repeating: 0, count: slotCount)
        let slotSeconds = Double(duration * 60)
        let windowStartTs = windowStart.timeIntervalSince1970

        // Buckets are kept sorted ascending — skip the long history before the window.
        var i = buckets.firstIndex(where: { minuteOf($0) >= windowStart }) ?? buckets.count
        while i < buckets.count {
            let minute = minuteOf(buckets[i])
            if minute >= windowEnd { break }
            let offset = minute.timeIntervalSince1970 - windowStartTs
            let idx = min(slotCount - 1, max(0, Int(offset / slotSeconds)))
            totals[idx] += valueOf(buckets[i])
            i += 1
        }

        var slots: [Slot] = []
        slots.reserveCapacity(slotCount)
        for index in 0..<slotCount {
            let minutesBack = duration * (slotCount - 1 - index)
            guard let slotStart = calendar.date(byAdding: .minute, value: -minutesBack, to: currentSlotStart)
            else { continue }
            slots.append(makeSlot(slotStart, totals[index], duration))
        }
        return slots
    }

    /// The last `count` **calendar hours** ending at the hour containing `reference`, oldest → newest.
    func computerUsageByTrailingCalendarHours(reference: Date = Date(), count: Int = 12) -> [ComputerUsageHourSlot] {
        let calendar = Calendar.current
        let anchorHour = reference.startOfHour

        var slots: [ComputerUsageHourSlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let hoursBack = count - 1 - i
            guard let hourStart = calendar.date(byAdding: .hour, value: -hoursBack, to: anchorHour),
                  let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart)
            else { continue }

            let agg = aggregateComputerUsage(from: hourStart, to: hourEnd)
            slots.append(
                ComputerUsageHourSlot(
                    hourStart: hourStart,
                    keystrokeCount: agg.keystrokeCount,
                    mouseClickCount: agg.mouseClickCount,
                    travelPixels: agg.travelPixels,
                    scrollBumpCount: agg.scrollBumpCount,
                    builtinKeystrokeCount: agg.builtinKeystrokeCount,
                    builtinTrackpadClickCount: agg.builtinTrackpadClickCount,
                    builtinTrackpadTravelPixels: agg.builtinTrackpadTravelPixels,
                    builtinTrackpadScrollPixels: agg.builtinTrackpadScrollPixels,
                    externalKeyboardKeystrokes: agg.externalKeyboardKeystrokes
                )
            )
        }

        return slots
    }

    /// All 24 calendar hours of a hand-tracking day (`dayStart` … `dayStart + 1 day`), oldest → newest.
    func computerUsageHours(forHandTrackingDayStarting dayStart: Date) -> [ComputerUsageHourSlot] {
        let calendar = Calendar.current
        var slots: [ComputerUsageHourSlot] = []
        slots.reserveCapacity(24)

        for hourOffset in 0..<24 {
            guard let hourStart = calendar.date(byAdding: .hour, value: hourOffset, to: dayStart),
                  let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart)
            else { continue }

            let agg = aggregateComputerUsage(from: hourStart, to: hourEnd)
            slots.append(
                ComputerUsageHourSlot(
                    hourStart: hourStart,
                    keystrokeCount: agg.keystrokeCount,
                    mouseClickCount: agg.mouseClickCount,
                    travelPixels: agg.travelPixels,
                    scrollBumpCount: agg.scrollBumpCount,
                    builtinKeystrokeCount: agg.builtinKeystrokeCount,
                    builtinTrackpadClickCount: agg.builtinTrackpadClickCount,
                    builtinTrackpadTravelPixels: agg.builtinTrackpadTravelPixels,
                    builtinTrackpadScrollPixels: agg.builtinTrackpadScrollPixels,
                    externalKeyboardKeystrokes: agg.externalKeyboardKeystrokes
                )
            )
        }

        return slots
    }

    /// The last `count` **hand-tracking days** (3 AM → 3 AM) ending on the day segment containing `reference`, oldest → newest.
    func computerUsageByTrailingCalendarDays(reference: Date = Date(), count: Int = 12) -> [ComputerUsageDaySlot] {
        let calendar = Calendar.current
        let anchorDay = reference.startOfHandTrackingDay

        var slots: [ComputerUsageDaySlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let daysBack = count - 1 - i
            guard let dayStart = calendar.date(byAdding: .day, value: -daysBack, to: anchorDay),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }

            let agg = aggregateComputerUsage(from: dayStart, to: nextDay)
            slots.append(
                ComputerUsageDaySlot(
                    dayStart: dayStart,
                    keystrokeCount: agg.keystrokeCount,
                    mouseClickCount: agg.mouseClickCount,
                    travelPixels: agg.travelPixels,
                    scrollBumpCount: agg.scrollBumpCount,
                    builtinKeystrokeCount: agg.builtinKeystrokeCount,
                    builtinTrackpadClickCount: agg.builtinTrackpadClickCount,
                    builtinTrackpadTravelPixels: agg.builtinTrackpadTravelPixels,
                    builtinTrackpadScrollPixels: agg.builtinTrackpadScrollPixels,
                    externalKeyboardKeystrokes: agg.externalKeyboardKeystrokes
                )
            )
        }

        return slots
    }

    /// Segment for the hand-tracking window that contains ``reference`` (same as trailing `count: 1`).
    func computerUsageOnCalendarDayContaining(reference: Date = Date()) -> ComputerUsageDaySlot? {
        computerUsageByTrailingCalendarDays(reference: reference, count: 1).first
    }

    /// Bucket for the **prior** hand-tracking day (relative to ``reference``) when trailing data includes it.
    func computerUsageOnPreviousCalendarDay(reference: Date = Date()) -> ComputerUsageDaySlot? {
        let slots = computerUsageByTrailingCalendarDays(reference: reference, count: 2)
        guard slots.count >= 2 else { return slots.first }
        return slots.first
    }

    /// The last `count` **calendar weeks** (Monday → Monday) ending on the week containing `reference`, oldest → newest.
    func computerUsageByTrailingCalendarWeeks(reference: Date = Date(), count: Int = 12) -> [ComputerUsageWeekSlot] {
        let calendar = Calendar.current
        let anchorWeek = reference.startOfCalendarWeek

        var slots: [ComputerUsageWeekSlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let weeksBack = count - 1 - i
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: anchorWeek),
                  let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart)
            else { continue }

            let agg = aggregateComputerUsage(from: weekStart, to: weekEnd)
            slots.append(
                ComputerUsageWeekSlot(
                    weekStart: weekStart,
                    keystrokeCount: agg.keystrokeCount,
                    mouseClickCount: agg.mouseClickCount,
                    travelPixels: agg.travelPixels,
                    scrollBumpCount: agg.scrollBumpCount,
                    builtinKeystrokeCount: agg.builtinKeystrokeCount,
                    builtinTrackpadClickCount: agg.builtinTrackpadClickCount,
                    builtinTrackpadTravelPixels: agg.builtinTrackpadTravelPixels,
                    builtinTrackpadScrollPixels: agg.builtinTrackpadScrollPixels
                )
            )
        }

        return slots
    }

    /// The last `count` **calendar months** ending on the month containing `reference`, oldest → newest.
    func computerUsageByTrailingCalendarMonths(reference: Date = Date(), count: Int = 12) -> [ComputerUsageMonthSlot] {
        let calendar = Calendar.current
        let anchorMonth = reference.startOfCalendarMonth

        var slots: [ComputerUsageMonthSlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let monthsBack = count - 1 - i
            guard let monthStart = calendar.date(byAdding: .month, value: -monthsBack, to: anchorMonth),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else { continue }

            let agg = aggregateComputerUsage(from: monthStart, to: monthEnd)
            slots.append(
                ComputerUsageMonthSlot(
                    monthStart: monthStart,
                    keystrokeCount: agg.keystrokeCount,
                    mouseClickCount: agg.mouseClickCount,
                    travelPixels: agg.travelPixels,
                    scrollBumpCount: agg.scrollBumpCount,
                    builtinKeystrokeCount: agg.builtinKeystrokeCount,
                    builtinTrackpadClickCount: agg.builtinTrackpadClickCount,
                    builtinTrackpadTravelPixels: agg.builtinTrackpadTravelPixels,
                    builtinTrackpadScrollPixels: agg.builtinTrackpadScrollPixels
                )
            )
        }

        return slots
    }

    private struct ComputerUsageAggregate {
        var keystrokeCount = 0
        var mouseClickCount = 0
        var travelPixels = 0.0
        var scrollBumpCount = 0
        var builtinKeystrokeCount = 0
        var builtinTrackpadClickCount = 0
        var builtinTrackpadTravelPixels = 0.0
        var builtinTrackpadScrollPixels = 0.0
        var externalKeyboardKeystrokes: [String: Int] = [:]
    }

    private func aggregateComputerUsage(from start: Date, to end: Date) -> ComputerUsageAggregate {
        var agg = ComputerUsageAggregate()
        for bucket in keystrokeBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.keystrokeCount += bucket.keyCount
        }
        for bucket in mouseClickBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.mouseClickCount += bucket.clickCount
        }
        for bucket in mouseTravelBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.travelPixels += bucket.travelPixels
        }
        for bucket in scrollBumpBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.scrollBumpCount += bucket.bumpCount
        }
        for bucket in builtinKeyboardBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.builtinKeystrokeCount += bucket.keyCount
        }
        for bucket in builtinTrackpadClickBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.builtinTrackpadClickCount += bucket.clickCount
        }
        for bucket in builtinTrackpadTravelBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.builtinTrackpadTravelPixels += bucket.travelPixels
        }
        for bucket in builtinTrackpadScrollBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.builtinTrackpadScrollPixels += bucket.scrollPixels
        }
        for bucket in externalKeyboardBuckets where bucket.minuteStart >= start && bucket.minuteStart < end {
            agg.externalKeyboardKeystrokes[bucket.keyboardId, default: 0] += bucket.keyCount
        }
        return agg
    }

    func monthlyPainWorstLoggedLeftHand(forOrderedMonthStarts months: [Date]) -> [Double?] {
        monthlyPainLoggedHandAggregate(forOrderedMonthStarts: months, hand: \.painLevelLeft) { vals in vals.max()! }
    }

    func monthlyPainWorstLoggedRightHand(forOrderedMonthStarts months: [Date]) -> [Double?] {
        monthlyPainLoggedHandAggregate(forOrderedMonthStarts: months, hand: \.painLevelRight) { vals in vals.max()! }
    }

    func monthlyPainMeanLoggedLeftHand(forOrderedMonthStarts months: [Date]) -> [Double?] {
        monthlyPainLoggedHandAggregate(forOrderedMonthStarts: months, hand: \.painLevelLeft) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    func monthlyPainMeanLoggedRightHand(forOrderedMonthStarts months: [Date]) -> [Double?] {
        monthlyPainLoggedHandAggregate(forOrderedMonthStarts: months, hand: \.painLevelRight) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    private func monthlyPainLoggedHandAggregate(
        forOrderedMonthStarts months: [Date],
        hand: KeyPath<HourlyHandLog, Double>,
        aggregate: ([Double]) -> Double
    ) -> [Double?] {
        let cal = Calendar.current
        return months.map { monthStart in
            guard let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            let vals = hourlyLogs.filter { $0.hourStart >= monthStart && $0.hourStart < monthEnd }.map { $0[keyPath: hand] }
            guard !vals.isEmpty else { return nil }
            return aggregate(vals)
        }
    }

    func weeklyPainWorstLoggedLeftHand(forOrderedWeekStarts weeks: [Date]) -> [Double?] {
        weeklyPainLoggedHandAggregate(forOrderedWeekStarts: weeks, hand: \.painLevelLeft) { vals in vals.max()! }
    }

    func weeklyPainWorstLoggedRightHand(forOrderedWeekStarts weeks: [Date]) -> [Double?] {
        weeklyPainLoggedHandAggregate(forOrderedWeekStarts: weeks, hand: \.painLevelRight) { vals in vals.max()! }
    }

    func weeklyPainMeanLoggedLeftHand(forOrderedWeekStarts weeks: [Date]) -> [Double?] {
        weeklyPainLoggedHandAggregate(forOrderedWeekStarts: weeks, hand: \.painLevelLeft) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    func weeklyPainMeanLoggedRightHand(forOrderedWeekStarts weeks: [Date]) -> [Double?] {
        weeklyPainLoggedHandAggregate(forOrderedWeekStarts: weeks, hand: \.painLevelRight) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    private func weeklyPainLoggedHandAggregate(
        forOrderedWeekStarts weeks: [Date],
        hand: KeyPath<HourlyHandLog, Double>,
        aggregate: ([Double]) -> Double
    ) -> [Double?] {
        let cal = Calendar.current
        return weeks.map { weekStart in
            guard let weekEnd = cal.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { return nil }
            let vals = hourlyLogs.filter { $0.hourStart >= weekStart && $0.hourStart < weekEnd }.map { $0[keyPath: hand] }
            guard !vals.isEmpty else { return nil }
            return aggregate(vals)
        }
    }

    /// Legacy daily figure: hourly means, then max(L̄, R̄). Order matches ``computerUsageByTrailingCalendarDays``.
    func dailyPainMaxOfMeanHourlyAverages(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        days.map { dailyPainRollupSnapshots[$0.timeIntervalSince1970]?.legacyPainPlot }
    }

    /// Highest `max(left, right)` among all hand logs in that **hand-tracking** segment (`nil` if no logs).
    func dailyPainWorstHigherHandForDay(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        days.map { dailyPainRollupSnapshots[$0.timeIntervalSince1970]?.worstHigherHand }
    }

    /// Mean `max(left, right)` over every hourly log row in that segment (`nil` if no logs).
    func dailyPainAverageHigherHandPerLoggedSample(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        days.map { dailyPainRollupSnapshots[$0.timeIntervalSince1970]?.averageHigherHandPerLog }
    }

    /// First iPhone log in each **hand-tracking** segment (by `hourStart`, then `createdAt`). Order matches ``computerUsageByTrailingCalendarDays``.
    func dailyPainFirstLoggedLeftHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainFirstLoggedHand(forOrderedCalendarDayStarts: days, hand: \.painLevelLeft)
    }

    /// Same as ``dailyPainFirstLoggedLeftHand`` but **right** hand pain on that first log.
    func dailyPainFirstLoggedRightHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainFirstLoggedHand(forOrderedCalendarDayStarts: days, hand: \.painLevelRight)
    }

    private func dailyPainFirstLoggedHand(forOrderedCalendarDayStarts days: [Date], hand: KeyPath<HourlyHandLog, Double>) -> [Double?] {
        let cal = Calendar.current
        return days.map { dayStart in
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let dayLogs = hourlyLogs.filter { $0.hourStart >= dayStart && $0.hourStart < dayEnd }
            guard let first = dayLogs.min(by: {
                if $0.hourStart != $1.hourStart { return $0.hourStart < $1.hourStart }
                return $0.createdAt < $1.createdAt
            }) else { return nil }
            return first[keyPath: hand]
        }
    }

    /// Highest **left‑hand** pain among logs in that **hand-tracking** segment (`nil` if none).
    func dailyPainWorstLoggedLeftHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainLoggedHandAggregate(forOrderedCalendarDayStarts: days, hand: \.painLevelLeft) { vals in vals.max()! }
    }

    /// Highest **right‑hand** pain in that segment (`nil` if none).
    func dailyPainWorstLoggedRightHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainLoggedHandAggregate(forOrderedCalendarDayStarts: days, hand: \.painLevelRight) { vals in vals.max()! }
    }

    /// Mean **left‑hand** pain averaged over **every log row** in that segment (`nil` if none).
    func dailyPainMeanLoggedLeftHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainLoggedHandAggregate(forOrderedCalendarDayStarts: days, hand: \.painLevelLeft) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    /// Mean **right‑hand** pain over all log rows in that segment (`nil` if none).
    func dailyPainMeanLoggedRightHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainLoggedHandAggregate(forOrderedCalendarDayStarts: days, hand: \.painLevelRight) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    private func dailyPainLoggedHandAggregate(
        forOrderedCalendarDayStarts days: [Date],
        hand: KeyPath<HourlyHandLog, Double>,
        aggregate: ([Double]) -> Double
    ) -> [Double?] {
        let cal = Calendar.current
        return days.map { dayStart in
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let vals = hourlyLogs.filter { $0.hourStart >= dayStart && $0.hourStart < dayEnd }.map { $0[keyPath: hand] }
            guard !vals.isEmpty else { return nil }
            return aggregate(vals)
        }
    }

    /// For ordered hour starts from ``computerUsageByTrailingCalendarHours``, max of left/right logged pain (`nil` where no hourly log landed in that bucket).
    func loggedPainHigherOfHandsByHour(forOrderedHourStarts hours: [Date]) -> [Double?] {
        hours.map { h in
            let highs = hourlyLogs
                .filter { $0.hourStart == h }
                .map { max($0.painLevelLeft, $0.painLevelRight) }
            guard let m = highs.max() else { return nil }
            return m
        }
    }

    func openStorageDirectory() {
        #if os(macOS)
        NSWorkspace.shared.open(storageDirectory)
        #endif
    }

    func reloadFromDisk() {
        load()
    }

    private func rebuildDailyPainRollupsFromHourlyLogs() throws {
        dailyPainRollupSnapshots.removeAll()
        try execute("DELETE FROM daily_pain_rollups;")

        var nested: [TimeInterval: [TimeInterval: [(Double, Double)]]] = [:]
        var logHigherPerDay: [TimeInterval: [Double]] = [:]

        for log in hourlyLogs {
            let dayKey = log.hourStart.startOfHandTrackingDay.timeIntervalSince1970
            let hourKey = log.hourStart.startOfHour.timeIntervalSince1970
            nested[dayKey, default: [:]][hourKey, default: []].append((log.painLevelLeft, log.painLevelRight))

            let higher = max(log.painLevelLeft, log.painLevelRight)
            logHigherPerDay[dayKey, default: []].append(higher)
        }

        var rollups: [DailyPainRollup] = []
        rollups.reserveCapacity(nested.count)

        for (dayKey, hourMap) in nested {
            var leftHourAvgs: [Double] = []
            var rightHourAvgs: [Double] = []

            for (_, pairs) in hourMap.sorted(by: { $0.key < $1.key }) {
                let n = Double(pairs.count)
                let sumL = pairs.reduce(0.0) { $0 + $1.0 }
                let sumR = pairs.reduce(0.0) { $0 + $1.1 }
                leftHourAvgs.append(sumL / n)
                rightHourAvgs.append(sumR / n)
            }
            guard !leftHourAvgs.isEmpty else { continue }

            let highs = logHigherPerDay[dayKey] ?? []
            guard !highs.isEmpty else { continue }

            let hCount = leftHourAvgs.count
            let meanLeft = leftHourAvgs.reduce(0.0, +) / Double(hCount)
            let meanRight = rightHourAvgs.reduce(0.0, +) / Double(hCount)
            let plot = max(meanLeft, meanRight)
            let worstHigher = highs.max() ?? plot
            let avgLoggedHigher = highs.reduce(0.0, +) / Double(highs.count)

            try upsertDailyPainRollup(
                dayStart: dayKey,
                meanLeft: meanLeft,
                meanRight: meanRight,
                plot: plot,
                worstHigherHand: worstHigher,
                avgLoggedHigherHand: avgLoggedHigher,
                hoursWithLogs: hCount
            )

            dailyPainRollupSnapshots[dayKey] = DailyPainRollupSnapshot(
                legacyPainPlot: plot,
                worstHigherHand: worstHigher,
                averageHigherHandPerLog: avgLoggedHigher
            )

            rollups.append(
                DailyPainRollup(
                    dayStart: Date(timeIntervalSince1970: dayKey),
                    meanOfHourlyAverageLeft: meanLeft,
                    meanOfHourlyAverageRight: meanRight,
                    painPlotValue: plot,
                    worstHigherHandPain: worstHigher,
                    averageHigherHandPainPerLog: avgLoggedHigher,
                    hoursWithLogs: hCount
                )
            )
        }

        rollups.sort { $0.dayStart > $1.dayStart }
        dailyPainRollups = rollups
    }

    private func upsertDailyPainRollup(
        dayStart: TimeInterval,
        meanLeft: Double,
        meanRight: Double,
        plot: Double,
        worstHigherHand: Double,
        avgLoggedHigherHand: Double,
        hoursWithLogs: Int
    ) throws {
        try withStatement("""
        INSERT OR REPLACE INTO daily_pain_rollups (
            day_start,
            mean_hourly_avg_left,
            mean_hourly_avg_right,
            pain_plot_value,
            worst_higher_hand,
            avg_logged_higher_hand,
            hours_with_logs
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, dayStart)
            sqlite3_bind_double(statement, 2, meanLeft)
            sqlite3_bind_double(statement, 3, meanRight)
            sqlite3_bind_double(statement, 4, plot)
            sqlite3_bind_double(statement, 5, worstHigherHand)
            sqlite3_bind_double(statement, 6, avgLoggedHigherHand)
            sqlite3_bind_int(statement, 7, Int32(hoursWithLogs))
            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            try openDatabaseIfNeeded()
            try createSchema()
            hourlyLogs = try loadHourlyLogs()
            keystrokeBuckets = try loadKeystrokeBuckets()
            mouseClickBuckets = try loadMouseClickBuckets()
            mouseTravelBuckets = try loadMouseTravelBuckets()
            scrollBumpBuckets = try loadScrollBumpBuckets()
            builtinKeyboardBuckets = try loadBuiltinKeyboardBuckets()
            externalKeyboardBuckets = try loadExternalKeyboardBuckets()
            externalKeyboardProfiles = try loadExternalKeyboardProfiles()
            builtinTrackpadClickBuckets = try loadBuiltinTrackpadClickBuckets()
            builtinTrackpadTravelBuckets = try loadBuiltinTrackpadTravelBuckets()
            builtinTrackpadScrollBuckets = try loadBuiltinTrackpadScrollBuckets()
            try rebuildDailyPainRollupsFromHourlyLogs()
            ensureAssumedKinesisRGBSplitProfile()
        } catch {
            hourlyLogs = []
            keystrokeBuckets = []
            mouseClickBuckets = []
            mouseTravelBuckets = []
            scrollBumpBuckets = []
            builtinKeyboardBuckets = []
            externalKeyboardBuckets = []
            externalKeyboardProfiles = [:]
            builtinTrackpadClickBuckets = []
            builtinTrackpadTravelBuckets = []
            builtinTrackpadScrollBuckets = []
            dailyPainRollups = []
            dailyPainRollupSnapshots = [:]
            print("Failed to load HandTrack data: \(error)")
            ensureAssumedKinesisRGBSplitProfile()
        }
        notifyStructuralChange()
    }

    private func openDatabaseIfNeeded() throws {
        guard database == nil else { return }
        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw StoreError.sqlite(message: lastSQLiteError)
        }
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS hourly_logs (
            id TEXT PRIMARY KEY,
            hour_start REAL NOT NULL,
            pain_level REAL NOT NULL,
            pain_level_left REAL NOT NULL,
            pain_level_right REAL NOT NULL,
            minutes_hands_used INTEGER NOT NULL,
            journal_entry TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            sync_status TEXT NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS keystroke_minute_buckets (
            minute_start REAL PRIMARY KEY,
            key_count INTEGER NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS mouse_click_minute_buckets (
            minute_start REAL PRIMARY KEY,
            click_count INTEGER NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS mouse_travel_minute_buckets (
            minute_start REAL PRIMARY KEY,
            travel_pixels REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS scroll_bump_minute_buckets (
            minute_start REAL PRIMARY KEY,
            bump_count INTEGER NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS builtin_keyboard_minute_buckets (
            minute_start REAL PRIMARY KEY,
            key_count INTEGER NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS external_keyboard_minute_buckets (
            minute_start REAL NOT NULL,
            keyboard_id TEXT NOT NULL,
            key_count INTEGER NOT NULL,
            PRIMARY KEY (minute_start, keyboard_id)
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS external_keyboards (
            id TEXT PRIMARY KEY,
            vendor_id INTEGER NOT NULL,
            product_id INTEGER NOT NULL,
            manufacturer TEXT NOT NULL,
            product TEXT NOT NULL,
            serial TEXT NOT NULL,
            default_name TEXT NOT NULL,
            custom_name TEXT,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS builtin_trackpad_click_minute_buckets (
            minute_start REAL PRIMARY KEY,
            click_count INTEGER NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS builtin_trackpad_travel_minute_buckets (
            minute_start REAL PRIMARY KEY,
            travel_pixels REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS builtin_trackpad_scroll_minute_buckets (
            minute_start REAL PRIMARY KEY,
            scroll_pixels REAL NOT NULL
        );
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_hourly_logs_hour_start ON hourly_logs(hour_start);")

        try execute("""
        CREATE TABLE IF NOT EXISTS daily_pain_rollups (
            day_start REAL PRIMARY KEY NOT NULL,
            mean_hourly_avg_left REAL NOT NULL,
            mean_hourly_avg_right REAL NOT NULL,
            pain_plot_value REAL NOT NULL,
            worst_higher_hand REAL NOT NULL,
            avg_logged_higher_hand REAL NOT NULL,
            hours_with_logs INTEGER NOT NULL
        );
        """)

        try migrateDailyPainRollupSnapshotColumnsIfNeeded()
        try migrateHourlyLogsPainSidesIfNeeded()
        try migrateHourlyPainLevelsToHalfStepStorageIfNeeded()
    }

    private func dailyPainRollupColumnNames() throws -> Set<String> {
        try query("PRAGMA table_info(daily_pain_rollups)") { statement in
            columnText(statement, at: 1)
        }
        .reduce(into: Set<String>()) { $0.insert($1) }
    }

    /// Adds daily worst / per‑log‑average snapshot columns introduced after the original rollup table.
    private func migrateDailyPainRollupSnapshotColumnsIfNeeded() throws {
        var columns = try dailyPainRollupColumnNames()
        if columns.isEmpty { return }

        if !columns.contains("worst_higher_hand") {
            try execute("""
                ALTER TABLE daily_pain_rollups ADD COLUMN worst_higher_hand REAL NOT NULL DEFAULT 0;
            """)
            columns.insert("worst_higher_hand")
        }
        if !columns.contains("avg_logged_higher_hand") {
            try execute("""
                ALTER TABLE daily_pain_rollups ADD COLUMN avg_logged_higher_hand REAL NOT NULL DEFAULT 0;
            """)
        }
        // Rows are rewritten in ``rebuildDailyPainRollupsFromHourlyLogs()`` after logs load.
    }

    private func hourlyLogColumnNames() throws -> Set<String> {
        try query("PRAGMA table_info(hourly_logs)") { statement in
            columnText(statement, at: 1)
        }
        .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func migrateHourlyLogsPainSidesIfNeeded() throws {
        var columns = try hourlyLogColumnNames()
        if columns.isEmpty { return }

        var addedSides = false
        if !columns.contains("pain_level_left") {
            try execute("""
                ALTER TABLE hourly_logs ADD COLUMN pain_level_left INTEGER NOT NULL DEFAULT 1;
            """)
            columns.insert("pain_level_left")
            addedSides = true
        }
        if !columns.contains("pain_level_right") {
            try execute("""
                ALTER TABLE hourly_logs ADD COLUMN pain_level_right INTEGER NOT NULL DEFAULT 1;
            """)
            addedSides = true
        }
        if addedSides {
            try execute("""
                UPDATE hourly_logs SET pain_level_left = pain_level, pain_level_right = pain_level;
            """)
        }
    }

    /// INTEGER affinity rounding can truncate half steps (`2.5` → `2`). Recreate rows with REAL pain columns once.
    private func migrateHourlyPainLevelsToHalfStepStorageIfNeeded() throws {
        guard !(try hourlyLogColumnNames()).isEmpty else { return }
        guard try hourlyPainColumnsDeclareExplicitIntegerAffinity() else { return }

        try execute("""
        BEGIN IMMEDIATE;
        CREATE TABLE hourly_logs_half_step_migr (
            id TEXT PRIMARY KEY,
            hour_start REAL NOT NULL,
            pain_level REAL NOT NULL,
            pain_level_left REAL NOT NULL,
            pain_level_right REAL NOT NULL,
            minutes_hands_used INTEGER NOT NULL,
            journal_entry TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            sync_status TEXT NOT NULL
        );
        INSERT INTO hourly_logs_half_step_migr (
            id, hour_start, pain_level, pain_level_left, pain_level_right,
            minutes_hands_used, journal_entry, created_at, updated_at, sync_status
        )
        SELECT id, hour_start,
            CAST(pain_level AS REAL),
            CAST(pain_level_left AS REAL),
            CAST(pain_level_right AS REAL),
            minutes_hands_used, journal_entry, created_at, updated_at, sync_status
        FROM hourly_logs;
        DROP TABLE hourly_logs;
        ALTER TABLE hourly_logs_half_step_migr RENAME TO hourly_logs;
        CREATE INDEX IF NOT EXISTS idx_hourly_logs_hour_start ON hourly_logs(hour_start);
        COMMIT;
        """)
    }

    private func hourlyPainColumnsDeclareExplicitIntegerAffinity() throws -> Bool {
        let rows: [(String, String)] = try query("PRAGMA table_info(hourly_logs)") { statement in
            (columnText(statement, at: 1).lowercased(), columnText(statement, at: 2).lowercased())
        }
        let painNames = Set(["pain_level", "pain_level_left", "pain_level_right"])
        for (name, typeDecl) in rows {
            guard painNames.contains(name) else { continue }
            let trimmed = typeDecl.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("int") {
                return true
            }
        }
        return false
    }

    private func save(_ log: HourlyHandLog) {
        do {
            try saveOrThrow(log)
        } catch {
            print("Failed to save hourly log: \(error)")
        }
    }

    /// Call after persisted hourly-log mutations that skip ``save(_:)`` (SQLite only).
    private func hourlyLogsDidChangePersisted() {
        try? rebuildDailyPainRollupsFromHourlyLogs()
    }

    private func save(_ bucket: KeystrokeMinuteBucket) {
        do {
            try saveOrThrow(bucket)
        } catch {
            print("Failed to save keystroke bucket: \(error)")
        }
    }

    private func deleteKeystrokeBucket(minuteStart: Date) {
        do {
            try withStatement("""
            DELETE FROM keystroke_minute_buckets WHERE minute_start = ?;
            """) { statement in
                sqlite3_bind_double(statement, 1, minuteStart.timeIntervalSince1970)
                if sqlite3_step(statement) != SQLITE_DONE {
                    throw StoreError.sqlite(message: lastSQLiteError)
                }
            }
        } catch {
            print("Failed to delete keystroke bucket: \(error)")
        }
    }

    private func deleteBuiltinKeyboardBucket(minuteStart: Date) {
        do {
            try withStatement("""
            DELETE FROM builtin_keyboard_minute_buckets WHERE minute_start = ?;
            """) { statement in
                sqlite3_bind_double(statement, 1, minuteStart.timeIntervalSince1970)
                if sqlite3_step(statement) != SQLITE_DONE {
                    throw StoreError.sqlite(message: lastSQLiteError)
                }
            }
        } catch {
            print("Failed to delete built-in keyboard bucket: \(error)")
        }
    }

    private func saveMouseClick(_ bucket: MouseClickMinuteBucket) {
        do {
            try saveMouseClickOrThrow(bucket)
        } catch {
            print("Failed to save mouse click bucket: \(error)")
        }
    }

    private func saveMouseTravel(_ bucket: MouseTravelMinuteBucket) {
        do {
            try saveMouseTravelOrThrow(bucket)
        } catch {
            print("Failed to save mouse travel bucket: \(error)")
        }
    }

    private func saveOrThrow(_ log: HourlyHandLog) throws {
        try withStatement("""
        INSERT OR REPLACE INTO hourly_logs (
            id,
            hour_start,
            pain_level,
            pain_level_left,
            pain_level_right,
            minutes_hands_used,
            journal_entry,
            created_at,
            updated_at,
            sync_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            bindText(log.id.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, log.hourStart.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, log.painLevelLeft)
            sqlite3_bind_double(statement, 4, log.painLevelLeft)
            sqlite3_bind_double(statement, 5, log.painLevelRight)
            sqlite3_bind_int(statement, 6, Int32(log.minutesHandsUsed))
            bindText(log.journalEntry, to: statement, at: 7)
            sqlite3_bind_double(statement, 8, log.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 9, log.updatedAt.timeIntervalSince1970)
            bindText(log.syncStatus.rawValue, to: statement, at: 10)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func saveOrThrow(_ bucket: KeystrokeMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO keystroke_minute_buckets (minute_start, key_count)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(bucket.keyCount))

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func saveMouseClickOrThrow(_ bucket: MouseClickMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO mouse_click_minute_buckets (minute_start, click_count)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(bucket.clickCount))

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func saveMouseTravelOrThrow(_ bucket: MouseTravelMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO mouse_travel_minute_buckets (minute_start, travel_pixels)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, bucket.travelPixels)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadHourlyLogs() throws -> [HourlyHandLog] {
        try query("""
        SELECT id, hour_start, pain_level_left, pain_level_right,
               minutes_hands_used, journal_entry, created_at, updated_at, sync_status
        FROM hourly_logs
        ORDER BY hour_start DESC, created_at DESC;
        """) { statement in
            guard let id = UUID(uuidString: columnText(statement, at: 0)) else {
                throw StoreError.invalidData("Invalid hourly log UUID")
            }

            return HourlyHandLog(
                id: id,
                hourStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                painLevelLeft: sqlite3_column_double(statement, 2),
                painLevelRight: sqlite3_column_double(statement, 3),
                minutesHandsUsed: Int(sqlite3_column_int(statement, 4)),
                journalEntry: columnText(statement, at: 5),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                syncStatus: SyncStatus(rawValue: columnText(statement, at: 8)) ?? .pending
            )
        }
    }

    private func loadKeystrokeBuckets() throws -> [KeystrokeMinuteBucket] {
        try query("""
        SELECT minute_start, key_count
        FROM keystroke_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return KeystrokeMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                keyCount: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func loadMouseClickBuckets() throws -> [MouseClickMinuteBucket] {
        try query("""
        SELECT minute_start, click_count
        FROM mouse_click_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return MouseClickMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                clickCount: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func loadMouseTravelBuckets() throws -> [MouseTravelMinuteBucket] {
        try query("""
        SELECT minute_start, travel_pixels
        FROM mouse_travel_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return MouseTravelMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                travelPixels: sqlite3_column_double(statement, 1)
            )
        }
    }

    private func saveScrollBump(_ bucket: ScrollBumpMinuteBucket) {
        do {
            try saveScrollBumpOrThrow(bucket)
        } catch {
            print("Failed to save scroll bump bucket: \(error)")
        }
    }

    private func saveScrollBumpOrThrow(_ bucket: ScrollBumpMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO scroll_bump_minute_buckets (minute_start, bump_count)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(bucket.bumpCount))

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadScrollBumpBuckets() throws -> [ScrollBumpMinuteBucket] {
        try query("""
        SELECT minute_start, bump_count
        FROM scroll_bump_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return ScrollBumpMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                bumpCount: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func saveExternalKeyboardBucket(_ bucket: ExternalKeyboardMinuteBucket) {
        do {
            try withStatement("""
            INSERT OR REPLACE INTO external_keyboard_minute_buckets (minute_start, keyboard_id, key_count)
            VALUES (?, ?, ?);
            """) { statement in
                sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
                bindText(bucket.keyboardId, to: statement, at: 2)
                sqlite3_bind_int(statement, 3, Int32(bucket.keyCount))
                if sqlite3_step(statement) != SQLITE_DONE {
                    throw StoreError.sqlite(message: lastSQLiteError)
                }
            }
        } catch {
            print("Failed to save external keyboard bucket: \(error)")
        }
    }

    private func loadExternalKeyboardBuckets() throws -> [ExternalKeyboardMinuteBucket] {
        try query("""
        SELECT minute_start, keyboard_id, key_count
        FROM external_keyboard_minute_buckets
        ORDER BY minute_start ASC, keyboard_id ASC;
        """) { statement in
            ExternalKeyboardMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                keyboardId: columnText(statement, at: 1),
                keyCount: Int(sqlite3_column_int(statement, 2))
            )
        }
    }

    private func persistExternalKeyboardProfiles() {
        do {
            for profile in externalKeyboardProfiles.values {
                try withStatement("""
                INSERT OR REPLACE INTO external_keyboards (
                    id, vendor_id, product_id, manufacturer, product, serial,
                    default_name, custom_name, first_seen, last_seen
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bindText(profile.id, to: statement, at: 1)
                    sqlite3_bind_int(statement, 2, Int32(profile.vendorID))
                    sqlite3_bind_int(statement, 3, Int32(profile.productID))
                    bindText(profile.manufacturer, to: statement, at: 4)
                    bindText(profile.product, to: statement, at: 5)
                    bindText(profile.serial, to: statement, at: 6)
                    bindText(profile.defaultName, to: statement, at: 7)
                    if let custom = profile.customName, !custom.isEmpty {
                        bindText(custom, to: statement, at: 8)
                    } else {
                        sqlite3_bind_null(statement, 8)
                    }
                    sqlite3_bind_double(statement, 9, profile.firstSeen.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 10, profile.lastSeen.timeIntervalSince1970)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        throw StoreError.sqlite(message: lastSQLiteError)
                    }
                }
            }
        } catch {
            print("Failed to save external keyboard profiles: \(error)")
        }
    }

    private func loadExternalKeyboardProfiles() throws -> [String: ExternalKeyboardProfile] {
        let rows: [ExternalKeyboardProfile] = try query("""
        SELECT id, vendor_id, product_id, manufacturer, product, serial,
               default_name, custom_name, first_seen, last_seen
        FROM external_keyboards;
        """) { statement in
            let custom = columnText(statement, at: 7)
            return ExternalKeyboardProfile(
                id: columnText(statement, at: 0),
                vendorID: Int(sqlite3_column_int(statement, 1)),
                productID: Int(sqlite3_column_int(statement, 2)),
                manufacturer: columnText(statement, at: 3),
                product: columnText(statement, at: 4),
                serial: columnText(statement, at: 5),
                defaultName: columnText(statement, at: 6),
                customName: custom.isEmpty ? nil : custom,
                firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
            )
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    private func saveBuiltinKeyboard(_ bucket: BuiltinKeyboardMinuteBucket) {
        do {
            try saveBuiltinKeyboardOrThrow(bucket)
        } catch {
            print("Failed to save built-in keyboard bucket: \(error)")
        }
    }

    private func saveBuiltinKeyboardOrThrow(_ bucket: BuiltinKeyboardMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO builtin_keyboard_minute_buckets (minute_start, key_count)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(bucket.keyCount))

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadBuiltinKeyboardBuckets() throws -> [BuiltinKeyboardMinuteBucket] {
        try query("""
        SELECT minute_start, key_count
        FROM builtin_keyboard_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return BuiltinKeyboardMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                keyCount: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func saveBuiltinTrackpadClick(_ bucket: BuiltinTrackpadClickMinuteBucket) {
        do {
            try saveBuiltinTrackpadClickOrThrow(bucket)
        } catch {
            print("Failed to save built-in trackpad click bucket: \(error)")
        }
    }

    private func saveBuiltinTrackpadClickOrThrow(_ bucket: BuiltinTrackpadClickMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO builtin_trackpad_click_minute_buckets (minute_start, click_count)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(bucket.clickCount))

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadBuiltinTrackpadClickBuckets() throws -> [BuiltinTrackpadClickMinuteBucket] {
        try query("""
        SELECT minute_start, click_count
        FROM builtin_trackpad_click_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return BuiltinTrackpadClickMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                clickCount: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func saveBuiltinTrackpadTravel(_ bucket: BuiltinTrackpadTravelMinuteBucket) {
        do {
            try saveBuiltinTrackpadTravelOrThrow(bucket)
        } catch {
            print("Failed to save built-in trackpad travel bucket: \(error)")
        }
    }

    private func saveBuiltinTrackpadTravelOrThrow(_ bucket: BuiltinTrackpadTravelMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO builtin_trackpad_travel_minute_buckets (minute_start, travel_pixels)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, bucket.travelPixels)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadBuiltinTrackpadTravelBuckets() throws -> [BuiltinTrackpadTravelMinuteBucket] {
        try query("""
        SELECT minute_start, travel_pixels
        FROM builtin_trackpad_travel_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return BuiltinTrackpadTravelMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                travelPixels: sqlite3_column_double(statement, 1)
            )
        }
    }

    private func saveBuiltinTrackpadScroll(_ bucket: BuiltinTrackpadScrollMinuteBucket) {
        do {
            try saveBuiltinTrackpadScrollOrThrow(bucket)
        } catch {
            print("Failed to save built-in trackpad scroll bucket: \(error)")
        }
    }

    private func saveBuiltinTrackpadScrollOrThrow(_ bucket: BuiltinTrackpadScrollMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO builtin_trackpad_scroll_minute_buckets (minute_start, scroll_pixels)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, bucket.scrollPixels)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadBuiltinTrackpadScrollBuckets() throws -> [BuiltinTrackpadScrollMinuteBucket] {
        try query("""
        SELECT minute_start, scroll_pixels
        FROM builtin_trackpad_scroll_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return BuiltinTrackpadScrollMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                scrollPixels: sqlite3_column_double(statement, 1)
            )
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
        _ = value.withCString { pointer in
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
