import Foundation
import Combine

@MainActor
final class MacDashboardViewModel: ObservableObject {
    @Published private(set) var syncStatus = "Starting..."
    @Published private(set) var chartBuckets: [KeystrokeBucket] = []

    private let monitor = KeystrokeMonitor()
    private var syncServer: HandTrackSyncServer?
    private var chartTimer: AnyCancellable?

    private static let bucketCount = 12
    private static let bucketInterval: TimeInterval = 5 * 60

    func start(store: HandTrackStore) {
        chartBuckets = Self.buckets(from: store.keystrokeEvents, now: Date())
        monitor.onKeystroke = { [weak store] in
            Task { @MainActor in
                store?.recordKeystroke()
            }
        }
        monitor.start()

        let server = HandTrackSyncServer(store: store)
        server.start()
        syncServer = server

        syncStatus = "Recording keystrokes. Sync server runs on port 8787 while this app is open."

        chartTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self, weak store] now in
                Task { @MainActor in
                    guard let store else { return }
                    self?.chartBuckets = Self.buckets(from: store.keystrokeEvents, now: now)
                }
            }
    }

    func stop() {
        monitor.stop()
        syncServer?.stop()
        syncServer = nil
        chartTimer?.cancel()
        chartTimer = nil
        syncStatus = "Stopped"
    }

    private static func buckets(from events: [KeystrokeEvent], now: Date) -> [KeystrokeBucket] {
        var buckets = emptyBuckets(now: now)
        guard let firstStart = buckets.first?.start,
              let lastStart = buckets.last?.start else {
            return buckets
        }

        let chartEnd = lastStart.addingTimeInterval(bucketInterval)
        for event in events.reversed() {
            guard event.timestamp < chartEnd else { continue }
            guard event.timestamp >= firstStart else { break }

            let index = Int(event.timestamp.timeIntervalSince(firstStart) / bucketInterval)
            if buckets.indices.contains(index) {
                buckets[index].count += 1
            }
        }

        return buckets
    }

    private static func emptyBuckets(now: Date) -> [KeystrokeBucket] {
        let latestStart = now.startOfBucket(interval: bucketInterval)
        let firstStart = latestStart.addingTimeInterval(-Double(bucketCount - 1) * bucketInterval)

        return (0..<bucketCount).map { index in
            KeystrokeBucket(
                start: firstStart.addingTimeInterval(Double(index) * bucketInterval),
                count: 0
            )
        }
    }
}
