import Foundation
import Combine

@MainActor
final class MacDashboardViewModel: ObservableObject {
    @Published private(set) var syncStatus = "Starting..."

    private var syncServer: HandTrackSyncServer?

    func start(store: HandTrackStore) {
        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus = "Sync server runs on port 8787 while this app is open. Use HandTrack Recorder for key capture."
    }

    func stop() {
        syncServer?.stop()
        syncServer = nil
        syncStatus = "Stopped"
    }
}
