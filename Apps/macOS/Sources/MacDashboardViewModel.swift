import Foundation
import Combine

@MainActor
final class MacDashboardViewModel: ObservableObject {
    @Published private(set) var syncStatus = "Starting..."
    @Published private(set) var keyTrackingStatus = "Starting key tracking..."
    @Published private(set) var needsInputMonitoringPermission = false

    private let monitor = KeystrokeMonitor()
    private var syncServer: HandTrackSyncServer?

    func start(store: HandTrackStore) {
        monitor.onKeystroke = { [weak store] in
            Task { @MainActor in
                store?.recordKeystroke()
            }
        }
        let monitorStatus = monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus = "Sync server runs on port 8787 while this app is open."
        switch monitorStatus {
        case .global:
            keyTrackingStatus = "Key tracking: global"
            needsInputMonitoringPermission = false
        case .localFallback:
            keyTrackingStatus = "Key tracking: app window only"
            needsInputMonitoringPermission = true
        case .stopped:
            keyTrackingStatus = "Key tracking: stopped"
            needsInputMonitoringPermission = true
        }
    }

    func openInputMonitoringSettings() {
        monitor.openInputMonitoringSettings()
    }

    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        syncStatus = "Stopped"
        keyTrackingStatus = "Key tracking: stopped"
    }
}
