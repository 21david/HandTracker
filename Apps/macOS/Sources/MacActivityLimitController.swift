import AppKit
import Foundation
import Combine

/// One running break timer for a single activity. Mutated as new events arrive (extension seconds)
/// and as the wall clock advances. `expiresAt` is the authoritative end-of-break instant.
struct ActiveActivityBreak: Identifiable, Equatable {
    var id: HandTrackActivityKind { kind }
    let kind: HandTrackActivityKind
    var startedAt: Date
    var expiresAt: Date
    var extensionSecondsPerEvent: Int

    func remainingSeconds(now: Date) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(now))))
    }
}

/// Owns the per-activity break-timer lifecycle: detects threshold breach inside a rolling window,
/// starts a break, plays a sound + extends the timer on every event during the break, and clears
/// the timer when wall-clock time has caught up to `expiresAt`.
@MainActor
final class MacActivityLimitController: ObservableObject {
    /// Not `@Published`: extending a break on every keystroke must not rebuild the dashboard.
    /// UI is notified only when breaks start/end via ``publishBreaksStructureChanged()``.
    private(set) var activeBreaks: [HandTrackActivityKind: ActiveActivityBreak] = [:]

    private struct IgnoredActivityEvent {
        let kind: HandTrackActivityKind
        let magnitude: Double
        let timestamp: Date
    }

    private weak var store: HandTrackStore?
    private var tickTimer: Timer?
    private var ignoredEvents: [IgnoredActivityEvent] = []
    /// Avoid UserDefaults + decode on every keystroke; refresh only on attach / settings Done.
    private var cachedSnapshot: HandTrackActivityLimitsSnapshot?

    func attach(store: HandTrackStore) {
        self.store = store
        cachedSnapshot = HandTrackActivityLimitsSnapshot.loadFromUserDefaults()
        startTickTimer()
    }

    func detach() {
        tickTimer?.invalidate()
        tickTimer = nil
        let hadBreaks = !activeBreaks.isEmpty
        activeBreaks.removeAll()
        ignoredEvents.removeAll()
        cachedSnapshot = nil
        if hadBreaks { publishBreaksStructureChanged() }
    }

    /// Forces a snapshot reload + recomputes remaining timers — call after the settings popover
    /// changes values so the UI reflects new threshold/break durations immediately.
    func refreshAfterSettingsChange() {
        let snapshot = HandTrackActivityLimitsSnapshot.loadFromUserDefaults()
        cachedSnapshot = snapshot
        for (kind, var brk) in activeBreaks {
            let perActivity = perActivity(in: snapshot, for: kind)
            brk.extensionSecondsPerEvent = perActivity.extensionSeconds
            activeBreaks[kind] = brk
        }
        pruneExpired(now: Date())
    }

    // MARK: - Per-event hooks

    /// Called by the dashboard view-model from each keystroke / click / travel-batch callback.
    /// `eventMagnitude` is `1` for keys/clicks; for pointer travel pass the batched pixel count
    /// so each batch contributes its full delta to the rolling window check.
    func registerEvent(
        of kind: HandTrackActivityKind,
        eventMagnitude: Double = 1,
        at now: Date = Date(),
        playSound: Bool = true
    ) {
        let snapshot = cachedSnapshot ?? HandTrackActivityLimitsSnapshot.loadFromUserDefaults()
        if cachedSnapshot == nil { cachedSnapshot = snapshot }
        guard snapshot.masterEnabled else { return }
        let activity = perActivity(in: snapshot, for: kind)
        guard activity.enabled else { return }
        pruneIgnoredEvents(before: now.addingTimeInterval(-Double(maximumWindowMinutes(in: snapshot)) * 60))

        if var existing = activeBreaks[kind] {
            // Keys/clicks may arrive batched; travel batches already represent one UI event.
            let extensionUnits: Double = {
                switch kind {
                case .pointerTravel: return 1
                case .keystrokes, .mouseClicks: return max(1, eventMagnitude)
                }
            }()
            existing.expiresAt = existing.expiresAt.addingTimeInterval(
                Double(existing.extensionSecondsPerEvent) * extensionUnits
            )
            activeBreaks[kind] = existing
            // No objectWillChange — banner TimelineView rereads expiresAt on its 0.5s tick.
            if playSound {
                playBreakSound(volumePercent: snapshot.soundVolumePercent, name: snapshot.soundName)
            }
            return
        }

        guard let store = store else { return }
        let currentTotal: Double
        switch kind {
        case .keystrokes:
            currentTotal = Double(store.keysInLastMinutes(activity.windowMinutes, reference: now))
        case .mouseClicks:
            currentTotal = Double(store.clicksInLastMinutes(activity.windowMinutes, reference: now))
        case .pointerTravel:
            currentTotal = store.mouseTravelPixelsInLastMinutes(activity.windowMinutes, reference: now)
        }

        let ignoredTotal = ignoredEvents.reduce(0.0) { sum, event in
            let windowStart = now.addingTimeInterval(-Double(max(1, activity.windowMinutes)) * 60)
            guard event.kind == kind, event.timestamp >= windowStart, event.timestamp <= now else { return sum }
            return sum + event.magnitude
        }
        let countedTotal = max(0, currentTotal - ignoredTotal)
        guard activity.threshold > 0, countedTotal >= activity.threshold else { return }

        let breakSeconds = max(1, activity.breakMinutes) * 60
        let brk = ActiveActivityBreak(
            kind: kind,
            startedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(breakSeconds)),
            extensionSecondsPerEvent: activity.extensionSeconds
        )
        activeBreaks[kind] = brk
        publishBreaksStructureChanged()
        if playSound {
            playBreakSound(volumePercent: snapshot.soundVolumePercent, name: snapshot.soundName)
        }
    }

    /// Records an event that remains in normal usage history but is excluded from Activity Limits.
    func ignoreEventDuringPause(
        of kind: HandTrackActivityKind,
        eventMagnitude: Double = 1,
        at now: Date = Date()
    ) {
        ignoredEvents.append(IgnoredActivityEvent(kind: kind, magnitude: eventMagnitude, timestamp: now))
    }

    /// Pausing Activity Limits also dismisses any currently enforced break.
    func clearActiveBreaksForPause() {
        guard !activeBreaks.isEmpty else { return }
        activeBreaks.removeAll()
        publishBreaksStructureChanged()
    }

    private func publishBreaksStructureChanged() {
        objectWillChange.send()
    }

    // MARK: - Internals

    private func perActivity(
        in snapshot: HandTrackActivityLimitsSnapshot,
        for kind: HandTrackActivityKind
    ) -> HandTrackActivityLimitsSnapshot.PerActivity {
        switch kind {
        case .keystrokes: return snapshot.keys
        case .mouseClicks: return snapshot.clicks
        case .pointerTravel: return snapshot.travel
        }
    }

    private func maximumWindowMinutes(in snapshot: HandTrackActivityLimitsSnapshot) -> Int {
        max(
            1,
            [snapshot.keys.windowMinutes, snapshot.clicks.windowMinutes, snapshot.travel.windowMinutes].max() ?? 1
        )
    }

    private func pruneIgnoredEvents(before cutoff: Date) {
        ignoredEvents.removeAll { $0.timestamp < cutoff }
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneExpired(now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func pruneExpired(now: Date) {
        guard !activeBreaks.isEmpty else { return }
        var removed = false
        for (kind, brk) in activeBreaks where brk.expiresAt <= now {
            activeBreaks.removeValue(forKey: kind)
            removed = true
        }
        if removed {
            publishBreaksStructureChanged()
        }
    }

    private func playBreakSound(volumePercent: Int, name: String) {
        let nsName = NSSound.Name(name)
        let clamped = max(0, min(Float(volumePercent) / 100.0, 1))
        let named = NSSound(named: nsName)
        if let sound = named {
            sound.volume = clamped
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

/// Per-keyboard usage caps on the Keyboards tab. Trailing 1/3/6/12/24 hour windows;
/// once the cap is hit, each keystroke on that board plays the Activity Limits alarm until
/// enough of that window’s typing ages out.
@MainActor
final class MacKeyboardLimitController: ObservableObject {
    private weak var store: HandTrackStore?
    private var rules: [String: KeyboardLimitRule] = [:]
    private var alarmUntil: [String: Date] = [:]
    private var tickTimer: Timer?
    private var didPlayRecoveryFor: Set<String> = []

    func attach(store: HandTrackStore) {
        self.store = store
        rules = HandTrackKeyboardLimitsStorage.loadRules()
        startTickTimer()
    }

    func detach() {
        tickTimer?.invalidate()
        tickTimer = nil
        store = nil
        rules.removeAll()
        alarmUntil.removeAll()
        didPlayRecoveryFor.removeAll()
    }

    func rule(for keyboardId: String) -> KeyboardLimitRule {
        rules[keyboardId] ?? .disabledDefault
    }

    func setRule(_ rule: KeyboardLimitRule, for keyboardId: String) {
        var next = rule
        next.windowHours = next.resolvedWindowHours
        next.threshold = max(1, next.threshold)
        rules[keyboardId] = next
        HandTrackKeyboardLimitsStorage.saveRules(rules)
        if !next.enabled {
            alarmUntil.removeValue(forKey: keyboardId)
        }
        objectWillChange.send()
    }

    func status(for keyboardId: String, at now: Date = Date()) -> KeyboardLimitStatus? {
        let current = rule(for: keyboardId)
        guard current.enabled, let store else { return nil }
        let hours = current.resolvedWindowHours
        let windowStart = KeyboardLimitClock.rollingStart(hours: hours, now: now)
        let buckets = store.keyboardKeystrokeMinuteCounts(
            forKeyboard: keyboardId,
            from: windowStart,
            through: now
        )
        let keys = buckets.reduce(0) { $0 + $1.count }
        let rates = MacEstimatedWorkloadMinutes.Rates.fromUserDefaults()
        let used: Int
        let thresholdKeys: Double
        switch current.unit {
        case .keystrokes:
            used = keys
            thresholdKeys = Double(max(1, current.threshold))
        case .minutes:
            used = MacEstimatedWorkloadMinutes.keyboardMinutes(keystrokes: keys, rates: rates)
            thresholdKeys = Double(max(1, current.threshold)) * rates.keysPerMinute
        }
        let isOver = used >= current.threshold
        let resetsAt = isOver ? Self.resetTime(buckets: buckets, thresholdKeys: thresholdKeys, hours: hours) : nil
        return KeyboardLimitStatus(
            rule: current,
            keystrokes: keys,
            usedAmount: used,
            resetsAt: resetsAt,
            isOver: isOver
        )
    }

    func registerKeystrokes(keyboardId: String, count: Int, at now: Date, playSound: Bool) {
        guard count > 0 else { return }
        guard let status = status(for: keyboardId, at: now) else { return }
        if status.isOver, let resetsAt = status.resetsAt {
            alarmUntil[keyboardId] = resetsAt
            didPlayRecoveryFor.remove(keyboardId)
            if playSound {
                playLimitSound()
            }
        }
    }

    private static func resetTime(
        buckets: [(minuteStart: Date, count: Int)],
        thresholdKeys: Double,
        hours: Int
    ) -> Date {
        let window = TimeInterval(max(1, hours) * 3600)
        var remaining = buckets.reduce(0.0) { $0 + Double($1.count) }
        let ordered = buckets.sorted { $0.minuteStart < $1.minuteStart }
        for bucket in ordered {
            remaining -= Double(bucket.count)
            if remaining < thresholdKeys {
                return bucket.minuteStart.addingTimeInterval(window)
            }
        }
        return (ordered.last?.minuteStart ?? Date()).addingTimeInterval(window)
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneRecovered(now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func pruneRecovered(now: Date) {
        guard !alarmUntil.isEmpty else { return }
        for (keyboardId, until) in alarmUntil {
            if let live = status(for: keyboardId, at: now), live.isOver, let reset = live.resetsAt, reset > now {
                alarmUntil[keyboardId] = reset
                continue
            }
            guard until <= now else { continue }
            alarmUntil.removeValue(forKey: keyboardId)
            guard !didPlayRecoveryFor.contains(keyboardId) else { continue }
            didPlayRecoveryFor.insert(keyboardId)
            playRecoverySound()
        }
    }

    private func playLimitSound() {
        playNamedSound(HandTrackActivityLimitsSnapshot.loadFromUserDefaults().soundName)
    }

    private func playRecoverySound() {
        playNamedSound("Glass")
    }

    private func playNamedSound(_ name: String) {
        let snapshot = HandTrackActivityLimitsSnapshot.loadFromUserDefaults()
        let clamped = max(0, min(Float(snapshot.soundVolumePercent) / 100.0, 1))
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = clamped
            sound.play()
        } else if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.volume = clamped
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
