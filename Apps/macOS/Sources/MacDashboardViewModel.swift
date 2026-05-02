import Foundation
import Combine

@MainActor
final class MacDashboardViewModel: ObservableObject {
    @Published private(set) var syncStatus = "Starting..."

    // Keep the monitor owned for as long as the dashboard is active.
    // If this object were released, the event tap would stop receiving key events.
    private let monitor = KeystrokeMonitor()
    private var syncServer: HandTrackSyncServer?

    // Wires together keyboard capture and local storage.
    // The callback is intentionally minimal: it just schedules the store write on the main actor.
    func start(store: HandTrackStore) {
        monitor.onKeystroke = { [weak store] in
            Task { @MainActor in
                // Store remains responsible for appending and persisting the keystroke.
                // Avoid putting charting or aggregation work here; this path runs per keypress.
                store?.recordKeystroke()
            }
        }

        // Starts the macOS event tap. If permissions are missing, the monitor opens System Settings.
        monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus = "Recording keystrokes. Sync server runs on port 8787 while this app is open."
    }

    // Tears down runtime services owned by the Mac dashboard.
    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        syncStatus = "Stopped"
    }
}
