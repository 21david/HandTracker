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
                store?.recordKeystroke()
            }
        }
        let isMonitoring = monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus = isMonitoring
            ? "Recording keystrokes. Sync server runs on port 8787 while this app is open."
            : "Key tracking did not start. Check Input Monitoring permission in System Settings."
    }

    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        syncStatus = "Stopped"
    }
}
