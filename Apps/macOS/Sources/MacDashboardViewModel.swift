import Foundation
import Combine

@MainActor
final class MacDashboardViewModel: ObservableObject {
    @Published private(set) var syncStatus = "Starting..."
    @Published private(set) var keyTrackingStatus = "Starting key tracking..."
    @Published private(set) var needsInputMonitoringPermission = false
    @Published private(set) var detectedKeysThisRun = 0

    private let monitor = KeystrokeMonitor()
    private var syncServer: HandTrackSyncServer?

    func start(store: HandTrackStore) {
        monitor.onKeystroke = { [weak store] in
            Task { @MainActor in
                self.detectedKeysThisRun += 1
                store?.recordKeystroke()
            }
        }
        let monitorStatus = monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus = "Sync server runs on port 8787 while this app is open."
        switch monitorStatus {
        case .eventTap:
            keyTrackingStatus = "Key tracking: event tap"
            needsInputMonitoringPermission = false
        case .globalMonitor(let reason):
            keyTrackingStatus = "Key tracking: monitor fallback (\(reason))"
            needsInputMonitoringPermission = true
        case .stopped(let reason):
            keyTrackingStatus = "Key tracking: stopped (\(reason))"
            needsInputMonitoringPermission = true
        }
    }

    func openInputMonitoringSettings() {
        monitor.openInputMonitoringSettings()
    }

    func openAccessibilitySettings() {
        monitor.openAccessibilitySettings()
    }

    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        syncStatus = "Stopped"
        keyTrackingStatus = "Key tracking: stopped"
    }

    func recordDiagnosticKeystroke(store: HandTrackStore) {
        detectedKeysThisRun += 1
        store.recordKeystroke()
    }
}
