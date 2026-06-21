import Foundation

@MainActor
final class MacDashboardViewModel: ObservableObject {

    /// Seconds since Unix epoch — alarms stay silent until this instant (recording continues).
    private static let recordingAlarmMuteExpiryKey = "HandTrack.recordingAlarmMuteExpiry"
    /// Last mute duration preset the user tapped (highlight persists until mute ends).
    private static let recordingAlarmMuteChosenMinutesKey = "HandTrack.recordingAlarmMuteChosenMinutes"

    @Published private(set) var syncStatus = "Starting..."

    /// If non-nil and in the future, break-alarm sounds are suppressed.
    @Published private(set) var recordingAlarmMuteExpiresAt: Date?

    /// Which mute pill was chosen for the active window (`nil` while not muted).
    @Published private(set) var mutedBreakAlarmChosenMinutes: Int?

    let activityLimits = MacActivityLimitController()

    private let monitor = KeystrokeMonitor()
    private var syncServer: HandTrackSyncServer?

    init() {
        recordingAlarmMuteExpiresAt = Self.loadMutedExpiryFromDefaults()
        if let ex = recordingAlarmMuteExpiresAt, ex > Date() {
            mutedBreakAlarmChosenMinutes = Self.loadMutedChosenMinutesFromDefaults(forExpiry: ex)
        } else {
            mutedBreakAlarmChosenMinutes = nil
        }
        refreshExpiredMuteIfNeeded(now: Date())
    }

    /// Clears persisted mute once `now` has passed expiry; harmless to call often.
    func refreshExpiredMuteIfNeeded(now: Date = Date()) {
        guard let until = recordingAlarmMuteExpiresAt, until <= now else { return }
        recordingAlarmMuteExpiresAt = nil
        mutedBreakAlarmChosenMinutes = nil
        Self.clearMutedPersistence()
    }

    /// Extends the mute expiry to at least ``now`` plus the given duration (never shortens).
    func muteBreakAlarms(minutes: Int) {
        let duration = TimeInterval(minutes * 60)
        let candidate = Date().addingTimeInterval(duration)
        refreshExpiredMuteIfNeeded(now: Date())
        if let existing = recordingAlarmMuteExpiresAt {
            recordingAlarmMuteExpiresAt = candidate > existing ? candidate : existing
        } else {
            recordingAlarmMuteExpiresAt = candidate
        }
        mutedBreakAlarmChosenMinutes = minutes
        persistMutedExpiryAndChosenMinutes()
    }

    /// Clears timed mute immediately (break alarms can resume).
    func clearBreakAlarmMute() {
        recordingAlarmMuteExpiresAt = nil
        mutedBreakAlarmChosenMinutes = nil
        Self.clearMutedPersistence()
    }

    func breakAlarmsMutedForPlaybackNow() -> Bool {
        refreshExpiredMuteIfNeeded(now: Date())
        guard let until = recordingAlarmMuteExpiresAt else { return false }
        return until > Date()
    }

    func start(store: HandTrackStore) {
        refreshExpiredMuteIfNeeded(now: Date())
        activityLimits.attach(store: store)
        monitor.onKeystroke = { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                store.recordKeystroke()
                guard !self.breakAlarmsMutedForPlaybackNow() else { return }
                self.activityLimits.registerEvent(of: .keystrokes)
            }
        }
        monitor.onMouseClick = { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                store.recordMouseClick()
                guard !self.breakAlarmsMutedForPlaybackNow() else { return }
                self.activityLimits.registerEvent(of: .mouseClicks)
            }
        }
        monitor.onBufferedTravelPixels = { [weak self, weak store] batch in
            Task { @MainActor in
                guard let self, let store else { return }
                store.recordMouseTravelPixels(batch)
                guard !self.breakAlarmsMutedForPlaybackNow() else { return }
                self.activityLimits.registerEvent(of: .pointerTravel, eventMagnitude: batch)
            }
        }
        monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus =
            "Listening on TCP 8787 — click “Sync & iPhone …” near the mute controls for full setup steps."
    }

    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        activityLimits.detach()
        syncStatus = "Stopped"
    }

    private static func loadMutedExpiryFromDefaults() -> Date? {
        let raw = UserDefaults.standard.double(forKey: recordingAlarmMuteExpiryKey)
        guard raw > 0 else {
            Self.clearStaleChosenMinutesOnly()
            return nil
        }
        let date = Date(timeIntervalSince1970: raw)
        guard date > Date() else {
            Self.clearMutedPersistence()
            return nil
        }
        return date
    }

    /// Load chosen interval from defaults once `expiresAt` is known to still be active.
    private static func loadMutedChosenMinutesFromDefaults(forExpiry expiresAt: Date) -> Int? {
        guard expiresAt > Date() else { return nil }
        guard UserDefaults.standard.object(forKey: recordingAlarmMuteChosenMinutesKey) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: recordingAlarmMuteChosenMinutesKey)
    }

    private func persistMutedExpiryAndChosenMinutes() {
        guard let until = recordingAlarmMuteExpiresAt else { return }
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.recordingAlarmMuteExpiryKey)
        if let mins = mutedBreakAlarmChosenMinutes {
            UserDefaults.standard.set(mins, forKey: Self.recordingAlarmMuteChosenMinutesKey)
        }
    }

    /// Clear interval key leftover when expiry key is absent (defensive migration).
    private static func clearStaleChosenMinutesOnly() {
        guard UserDefaults.standard.object(forKey: recordingAlarmMuteExpiryKey) == nil else { return }
        UserDefaults.standard.removeObject(forKey: recordingAlarmMuteChosenMinutesKey)
    }

    private static func clearMutedPersistence() {
        UserDefaults.standard.removeObject(forKey: recordingAlarmMuteExpiryKey)
        UserDefaults.standard.removeObject(forKey: recordingAlarmMuteChosenMinutesKey)
    }
}
