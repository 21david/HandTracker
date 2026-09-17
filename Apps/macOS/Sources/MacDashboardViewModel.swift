import AppKit
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
    private weak var store: HandTrackStore?

    /// Shared with the CGEvent tap thread — one main flush instead of one Task per key.
    private let pendingDiscrete = PendingDiscreteInputBuffer()

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
        self.store = store
        activityLimits.attach(store: store)
        monitor.onKeystroke = { [weak self] in
            self?.enqueueDiscreteInput(\.externalKeys)
        }
        monitor.onExternalKeyboardKeystroke = { [weak self] identity in
            self?.enqueueExternalKeyboard(identity)
        }
        monitor.onExternalKeyboardInventory = { [weak store] identities in
            Task { @MainActor in
                store?.registerExternalKeyboards(identities)
            }
        }
        monitor.onMouseClick = { [weak self] in
            self?.enqueueDiscreteInput(\.mouseClicks)
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
        monitor.onBuiltinKeystroke = { [weak self] in
            self?.enqueueDiscreteInput(\.builtinKeys)
        }
        monitor.onBuiltinTrackpadClick = { [weak store] in
            Task { @MainActor in
                store?.recordBuiltinTrackpadClick(at: Date())
            }
        }
        monitor.onBufferedBuiltinTrackpadTravelPixels = { [weak store] batch in
            Task { @MainActor in
                store?.recordBuiltinTrackpadTravelPixels(batch, at: Date())
            }
        }
        monitor.onBufferedBuiltinTrackpadScrollPixels = { [weak store] batch in
            Task { @MainActor in
                store?.recordBuiltinTrackpadScrollPixels(batch, at: Date())
            }
        }
        monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus =
            "Listening on TCP 8787 — click “Sync & iPhone …” near the mute controls for full setup steps."
    }

    /// Called from the CGEvent tap thread — coalesce into one main-queue flush (~30ms).
    nonisolated private func enqueueDiscreteInput(_ keyPath: WritableKeyPath<PendingDiscreteInputBuffer.Counters, Int>) {
        let shouldSchedule = pendingDiscrete.increment(keyPath)
        guard shouldSchedule else { return }
        scheduleDiscreteFlush()
    }

    nonisolated private func enqueueExternalKeyboard(_ identity: ExternalKeyboardIdentity) {
        let shouldSchedule = pendingDiscrete.incrementExternalKeyboard(identity)
        guard shouldSchedule else { return }
        scheduleDiscreteFlush()
    }

    nonisolated private func scheduleDiscreteFlush() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.flushPendingDiscreteInput()
        }
    }

    private func flushPendingDiscreteInput() {
        let batch = pendingDiscrete.take()
        guard let store else { return }
        guard batch.externalKeys > 0
            || batch.builtinKeys > 0
            || batch.mouseClicks > 0
            || !batch.externalByKeyboard.isEmpty
        else { return }

        let now = Date()
        // #region agent log
        MacAgentDebugLog.log(
            hypothesisId: "P5",
            location: "MacDashboardViewModel.flushPendingDiscreteInput",
            message: "input_batch_flush",
            data: [
                "runId": "perf-responsive",
                "externalKeys": batch.externalKeys,
                "builtinKeys": batch.builtinKeys,
                "clicks": batch.mouseClicks,
                "appActive": NSApp.isActive,
            ]
        )
        // #endregion

        if batch.externalKeys > 0 {
            store.recordKeystrokes(batch.externalKeys, at: now)
            applyActivityLimit(for: .keystrokes, eventCount: batch.externalKeys, at: now)
        }
        for (identity, count) in batch.externalByKeyboard where count > 0 {
            store.recordExternalKeyboardKeystrokes(count, identity: identity, at: now)
        }
        if batch.builtinKeys > 0 {
            store.recordBuiltinKeystrokes(batch.builtinKeys, at: now)
            applyActivityLimit(for: .keystrokes, eventCount: batch.builtinKeys, at: now)
        }
        if batch.mouseClicks > 0 {
            store.recordMouseClicks(batch.mouseClicks, at: now)
            applyActivityLimit(for: .mouseClicks, eventCount: batch.mouseClicks, at: now)
        }
    }

    private func applyActivityLimit(for kind: HandTrackActivityKind, eventCount: Int, at now: Date) {
        let magnitude = Double(max(1, eventCount))
        if activityLimitsPausedNow(at: now) {
            activityLimits.ignoreEventDuringPause(of: kind, eventMagnitude: magnitude, at: now)
        } else {
            activityLimits.registerEvent(
                of: kind,
                eventMagnitude: magnitude,
                at: now,
                playSound: !breakAlarmsMutedForPlaybackNow()
            )
        }
    }

    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        store = nil
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

/// Lock-protected counters shared with the CGEvent tap thread.
private final class PendingDiscreteInputBuffer: @unchecked Sendable {
    struct Counters {
        var externalKeys = 0
        var builtinKeys = 0
        var mouseClicks = 0
        var externalByKeyboard: [(identity: ExternalKeyboardIdentity, count: Int)] = []
    }

    private let lock = NSLock()
    private var counters = Counters()
    private var flushScheduled = false

    /// Returns `true` when the caller should schedule a main-queue flush.
    func increment(_ keyPath: WritableKeyPath<Counters, Int>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        counters[keyPath: keyPath] += 1
        if flushScheduled { return false }
        flushScheduled = true
        return true
    }

    private var pendingExternalByID: [String: (identity: ExternalKeyboardIdentity, count: Int)] = [:]

    func incrementExternalKeyboard(_ identity: ExternalKeyboardIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var current = pendingExternalByID[identity.id] ?? (identity, 0)
        current.identity = identity
        current.count += 1
        pendingExternalByID[identity.id] = current
        if flushScheduled { return false }
        flushScheduled = true
        return true
    }

    func take() -> Counters {
        lock.lock()
        defer { lock.unlock() }
        var batch = counters
        batch.externalByKeyboard = Array(pendingExternalByID.values)
        counters = Counters()
        pendingExternalByID.removeAll(keepingCapacity: true)
        flushScheduled = false
        return batch
    }
}
