import Foundation
import Combine

@MainActor
final class MacDashboardViewModel: ObservableObject {
    @Published private(set) var syncStatus = "Starting..."

    private let monitor = KeystrokeMonitor()
    private var syncServer: HandTrackSyncServer?

    func start(store: HandTrackStore) {
        monitor.onKeystroke = { [weak store] in
            Task { @MainActor in
                guard let store else { return }
                store.recordKeystroke()
                MacRecordingAlarmFeedback.afterKeystrokeRecorded(on: store)
            }
        }
        monitor.onMouseClick = { [weak store] in
            Task { @MainActor in
                guard let store else { return }
                store.recordMouseClick()
                MacRecordingAlarmFeedback.afterMouseClickRecorded(on: store)
            }
        }
        monitor.onBufferedTravelPixels = { [weak store] batch in
            Task { @MainActor in
                guard let store else { return }
                store.recordMouseTravelPixels(batch)
                MacRecordingAlarmFeedback.afterPointerTravelBatchRecorded(on: store, batchPixels: batch)
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
