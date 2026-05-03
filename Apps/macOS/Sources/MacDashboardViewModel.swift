import Combine
import Foundation

@MainActor
final class MacDashboardViewModel: ObservableObject {
    private static let recordingAlarmsMutedKey = "HandTrack.recordingAlarmsMuted"

    @Published private(set) var syncStatus = "Starting..."
    /// When true, threshold dings never play but recording continues.
    @Published private(set) var recordingAlarmsMuted: Bool

    private let monitor = KeystrokeMonitor()
    private var syncServer: HandTrackSyncServer?

    init() {
        recordingAlarmsMuted = UserDefaults.standard.bool(forKey: Self.recordingAlarmsMutedKey)
    }

    func setRecordingAlarmsMuted(_ muted: Bool) {
        guard recordingAlarmsMuted != muted else { return }
        recordingAlarmsMuted = muted
        UserDefaults.standard.set(muted, forKey: Self.recordingAlarmsMutedKey)
    }

    func start(store: HandTrackStore) {
        monitor.onKeystroke = { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                store.recordKeystroke()
                MacRecordingAlarmFeedback.afterKeystrokeRecorded(
                    on: store,
                    userMutedAlarms: self.recordingAlarmsMuted
                )
            }
        }
        monitor.onMouseClick = { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                store.recordMouseClick()
                MacRecordingAlarmFeedback.afterMouseClickRecorded(
                    on: store,
                    userMutedAlarms: self.recordingAlarmsMuted
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
                    userMutedAlarms: self.recordingAlarmsMuted
                )
            }
        }
        monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus = "Recording keystrokes, mouse clicks, and pointer distance. Sync server runs on port 8787 while this app is open."
    }

    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        syncStatus = "Stopped"
    }
}
