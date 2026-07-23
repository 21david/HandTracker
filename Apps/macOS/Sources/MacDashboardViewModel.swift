import Foundation

@MainActor
final class MacDashboardViewModel: ObservableObject {

    /// Seconds since Unix epoch — alarms stay silent until this instant (recording continues).
    private static let recordingAlarmMuteExpiryKey = "HandTrack.recordingAlarmMuteExpiry"
    /// Last mute duration preset the user tapped (highlight persists until mute ends).
    private static let recordingAlarmMuteChosenMinutesKey = "HandTrack.recordingAlarmMuteChosenMinutes"
    private static let activityLimitsPauseExpiryKey = "HandTrack.activityLimitsPauseExpiry"
    private static let activityLimitsPauseChosenMinutesKey = "HandTrack.activityLimitsPauseChosenMinutes"

    @Published private(set) var syncStatus = "Starting..."

    /// If non-nil and in the future, break-alarm sounds are suppressed.
    @Published private(set) var recordingAlarmMuteExpiresAt: Date?

    /// Which mute pill was chosen for the active window (`nil` while not muted).
    @Published private(set) var mutedBreakAlarmChosenMinutes: Int?
    /// Activity is still recorded while this is active, but events do not count toward Activity Limits.
    @Published private(set) var activityLimitsPauseExpiresAt: Date?
    @Published private(set) var activityLimitsPauseChosenMinutes: Int?

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
        activityLimitsPauseExpiresAt = Self.loadFutureDate(forKey: Self.activityLimitsPauseExpiryKey)
        if activityLimitsPauseExpiresAt != nil {
            activityLimitsPauseChosenMinutes = UserDefaults.standard.object(
                forKey: Self.activityLimitsPauseChosenMinutesKey
            ) == nil ? nil : UserDefaults.standard.integer(forKey: Self.activityLimitsPauseChosenMinutesKey)
        }
        refreshExpiredMuteIfNeeded(now: Date())
        refreshExpiredPauseIfNeeded(now: Date())
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

    func refreshExpiredPauseIfNeeded(now: Date = Date()) {
        guard let until = activityLimitsPauseExpiresAt, until <= now else { return }
        activityLimitsPauseExpiresAt = nil
        activityLimitsPauseChosenMinutes = nil
        Self.clearPausePersistence()
    }

    func pauseActivityLimits(minutes: Int) {
        let now = Date()
        let candidate = now.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        refreshExpiredPauseIfNeeded(now: now)
        if let existing = activityLimitsPauseExpiresAt {
            activityLimitsPauseExpiresAt = max(existing, candidate)
        } else {
            activityLimitsPauseExpiresAt = candidate
        }
        activityLimitsPauseChosenMinutes = minutes
        activityLimits.clearActiveBreaksForPause()
        persistPause()
    }

    func clearActivityLimitsPause() {
        activityLimitsPauseExpiresAt = nil
        activityLimitsPauseChosenMinutes = nil
        Self.clearPausePersistence()
    }

    func activityLimitsPausedNow(at now: Date = Date()) -> Bool {
        refreshExpiredPauseIfNeeded(now: now)
        return activityLimitsPauseExpiresAt.map { $0 > now } ?? false
    }

    func start(store: HandTrackStore) {
        refreshExpiredMuteIfNeeded(now: Date())
        refreshExpiredPauseIfNeeded(now: Date())
        activityLimits.attach(store: store)
        monitor.onKeystroke = { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                let now = Date()
                store.recordKeystroke(at: now)
                if self.activityLimitsPausedNow(at: now) {
                    self.activityLimits.ignoreEventDuringPause(of: .keystrokes, at: now)
                } else {
                    self.activityLimits.registerEvent(
                        of: .keystrokes,
                        at: now,
                        playSound: !self.breakAlarmsMutedForPlaybackNow()
                    )
                }
            }
        }
        monitor.onMouseClick = { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                let now = Date()
                store.recordMouseClick(at: now)
                if self.activityLimitsPausedNow(at: now) {
                    self.activityLimits.ignoreEventDuringPause(of: .mouseClicks, at: now)
                } else {
                    self.activityLimits.registerEvent(
                        of: .mouseClicks,
                        at: now,
                        playSound: !self.breakAlarmsMutedForPlaybackNow()
                    )
                }
            }
        }
        monitor.onScrollBumps = { [weak store] bumps in
            Task { @MainActor in
                store?.recordScrollBumps(bumps, at: Date())
            }
        }
        monitor.onBufferedTravelPixels = { [weak self, weak store] batch in
            Task { @MainActor in
                guard let self, let store else { return }
                let now = Date()
                store.recordMouseTravelPixels(batch, at: now)
                if self.activityLimitsPausedNow(at: now) {
                    self.activityLimits.ignoreEventDuringPause(
                        of: .pointerTravel,
                        eventMagnitude: batch,
                        at: now
                    )
                } else {
                    self.activityLimits.registerEvent(
                        of: .pointerTravel,
                        eventMagnitude: batch,
                        at: now,
                        playSound: !self.breakAlarmsMutedForPlaybackNow()
                    )
                }
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

    private func persistPause() {
        guard let until = activityLimitsPauseExpiresAt else { return }
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.activityLimitsPauseExpiryKey)
        if let minutes = activityLimitsPauseChosenMinutes {
            UserDefaults.standard.set(minutes, forKey: Self.activityLimitsPauseChosenMinutesKey)
        }
    }

    private static func loadFutureDate(forKey key: String) -> Date? {
        let raw = UserDefaults.standard.double(forKey: key)
        guard raw > 0 else { return nil }
        let date = Date(timeIntervalSince1970: raw)
        guard date > Date() else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return date
    }

    private static func clearPausePersistence() {
        UserDefaults.standard.removeObject(forKey: activityLimitsPauseExpiryKey)
        UserDefaults.standard.removeObject(forKey: activityLimitsPauseChosenMinutesKey)
    }
}
