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
    @Published private(set) var activeBreaks: [HandTrackActivityKind: ActiveActivityBreak] = [:]

    private weak var store: HandTrackStore?
    private var tickTimer: Timer?

    func attach(store: HandTrackStore) {
        self.store = store
        startTickTimer()
    }

    func detach() {
        tickTimer?.invalidate()
        tickTimer = nil
        activeBreaks.removeAll()
    }

    /// Forces a snapshot reload + recomputes remaining timers — call after the settings popover
    /// changes values so the UI reflects new threshold/break durations immediately.
    func refreshAfterSettingsChange() {
        let snapshot = HandTrackActivityLimitsSnapshot.loadFromUserDefaults()
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
    func registerEvent(of kind: HandTrackActivityKind, eventMagnitude: Double = 1, at now: Date = Date()) {
        let snapshot = HandTrackActivityLimitsSnapshot.loadFromUserDefaults()
        guard snapshot.masterEnabled else { return }
        let activity = perActivity(in: snapshot, for: kind)
        guard activity.enabled else { return }

        if var existing = activeBreaks[kind] {
            existing.expiresAt = existing.expiresAt.addingTimeInterval(Double(existing.extensionSecondsPerEvent))
            activeBreaks[kind] = existing
            playBreakSound(volumePercent: snapshot.soundVolumePercent, name: snapshot.soundName)
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

        guard activity.threshold > 0, currentTotal >= activity.threshold else { return }

        let breakSeconds = max(1, activity.breakMinutes) * 60
        let brk = ActiveActivityBreak(
            kind: kind,
            startedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(breakSeconds)),
            extensionSecondsPerEvent: activity.extensionSeconds
        )
        activeBreaks[kind] = brk
        playBreakSound(volumePercent: snapshot.soundVolumePercent, name: snapshot.soundName)
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
        for (kind, brk) in activeBreaks where brk.expiresAt <= now {
            activeBreaks.removeValue(forKey: kind)
        }
        objectWillChange.send()
    }

    private func playBreakSound(volumePercent: Int, name: String) {
        let nsName = NSSound.Name(name)
        let clamped = max(0, min(Float(volumePercent) / 100.0, 1))
        if let sound = NSSound(named: nsName) {
            sound.volume = clamped
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
