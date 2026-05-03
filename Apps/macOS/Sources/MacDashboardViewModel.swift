import Foundation

@MainActor
final class MacDashboardViewModel: ObservableObject {

    /// Seconds since Unix epoch — alarms stay silent until this instant (recording continues).
    private static let recordingAlarmMuteExpiryKey = "HandTrack.recordingAlarmMuteExpiry"

    @Published private(set) var syncStatus = "Starting..."

    /// If non-nil and in the future, break-alarm sounds are suppressed.
    @Published private(set) var recordingAlarmMuteExpiresAt: Date?

    private let monitor = KeystrokeMonitor()
    private var syncServer: HandTrackSyncServer?

    init() {
        recordingAlarmMuteExpiresAt = Self.loadMutedExpiryFromDefaults()
        refreshExpiredMuteIfNeeded(now: Date())
    }

    /// Clears persisted mute once `now` has passed expiry; harmless to call often.
    func refreshExpiredMuteIfNeeded(now: Date = Date()) {
        guard let until = recordingAlarmMuteExpiresAt, until <= now else { return }
        recordingAlarmMuteExpiresAt = nil
        UserDefaults.standard.removeObject(forKey: Self.recordingAlarmMuteExpiryKey)
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
        if let until = recordingAlarmMuteExpiresAt {
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.recordingAlarmMuteExpiryKey)
        }
    }

    func breakAlarmsMutedForPlaybackNow() -> Bool {
        refreshExpiredMuteIfNeeded(now: Date())
        guard let until = recordingAlarmMuteExpiresAt else { return false }
        return until > Date()
    }

    func start(store: HandTrackStore) {
        refreshExpiredMuteIfNeeded(now: Date())
        monitor.onKeystroke = { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                store.recordKeystroke()
                MacRecordingAlarmFeedback.afterKeystrokeRecorded(
                    on: store,
                    userMutedAlarms: self.breakAlarmsMutedForPlaybackNow()
                )
            }
        }
        monitor.onMouseClick = { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                store.recordMouseClick()
                MacRecordingAlarmFeedback.afterMouseClickRecorded(
                    on: store,
                    userMutedAlarms: self.breakAlarmsMutedForPlaybackNow()
                )
            }
        }
        monitor.onBufferedTravelPixels = { [weak self, weak store] batch in
            Task { @MainActor in
                guard let self, let store else { return }
                store.recordMouseTravelPixels(batch)
                MacRecordingAlarmFeedback.afterPointerTravelBatchRecorded(
                    on: store,
                    batchPixels: batch,
                    userMutedAlarms: self.breakAlarmsMutedForPlaybackNow()
                )
            }
        }
        monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus =
            "Sync server listens on port 8787 while this window is open. Open the HandTrack iPhone app and enter your Mac's Wi‑Fi hostname or LAN IP."
    }

    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        syncStatus = "Stopped"
    }

    private static func loadMutedExpiryFromDefaults() -> Date? {
        let raw = UserDefaults.standard.double(forKey: recordingAlarmMuteExpiryKey)
        guard raw > 0 else { return nil }
        let date = Date(timeIntervalSince1970: raw)
        guard date > Date() else {
            UserDefaults.standard.removeObject(forKey: recordingAlarmMuteExpiryKey)
            return nil
        }
        return date
    }
}
