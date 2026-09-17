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
        // #region agent log
        MacAgentDebugLog.log(
            hypothesisId: named == nil ? "C" : "B",
            location: "MacActivityLimitController.swift:playBreakSound",
            message: "activity-limit break sound playing",
            data: [
                "soundName": name,
                "volumePercent": volumePercent,
                "usedNamedSound": named != nil,
                "fallbackBeep": named == nil,
                "appActive": NSApp.isActive,
                "activeBreakKinds": activeBreaks.keys.map(\.rawValue).sorted(),
            ]
        )
        // #endregion
        if let sound = named {
            sound.volume = clamped
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
