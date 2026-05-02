import Foundation

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published private(set) var status = "Starting recorder..."
    @Published private(set) var keysThisHour = 0
    @Published private(set) var averageWPM = 0.0

    private let monitor = KeystrokeMonitor()
    private weak var store: HandTrackStore?

    func start(store: HandTrackStore) {
        self.store = store
        refreshStats()

        monitor.onKeystroke = { [weak self] in
            Task { @MainActor in
                guard let self, let store = self.store else { return }
                store.recordKeystroke()
                self.refreshStats()
            }
        }
        monitor.start()

        status = "Recording keys. Keep this app open while you work."
    }

    func stop() {
        monitor.stop()
        status = "Stopped"
    }

    func refreshStats() {
        guard let store else { return }
        keysThisHour = store.keysSinceStartOfCurrentHour()
        averageWPM = store.averageWordsPerMinuteForCurrentHour()
    }
}
