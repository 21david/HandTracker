import Foundation

/// Bucketing helpers so heavy dashboard charts skip rebuilds when only live input counters change.
enum MacChartEquatableBucket {
    static func hourStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
    }

    static func minuteStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
    }

    static func thirtySeconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 30.0)
    }

    @MainActor
    static func keystrokeRevision(_ store: HandTrackStore) -> Int {
        metricRevision(
            bucketCount: store.keystrokeBuckets.count,
            minuteStart: store.keystrokeBuckets.last?.minuteStart,
            value: Double(store.keystrokeBuckets.last?.keyCount ?? 0)
        )
    }

    @MainActor
    static func mouseClickRevision(_ store: HandTrackStore) -> Int {
        metricRevision(
            bucketCount: store.mouseClickBuckets.count,
            minuteStart: store.mouseClickBuckets.last?.minuteStart,
            value: Double(store.mouseClickBuckets.last?.clickCount ?? 0)
        )
    }

    @MainActor
    static func mouseTravelRevision(_ store: HandTrackStore) -> Int {
        metricRevision(
            bucketCount: store.mouseTravelBuckets.count,
            minuteStart: store.mouseTravelBuckets.last?.minuteStart,
            value: store.mouseTravelBuckets.last?.travelPixels ?? 0
        )
    }

    @MainActor
    static func scrollBumpRevision(_ store: HandTrackStore) -> Int {
        metricRevision(
            bucketCount: store.scrollBumpBuckets.count,
            minuteStart: store.scrollBumpBuckets.last?.minuteStart,
            value: Double(store.scrollBumpBuckets.last?.bumpCount ?? 0)
        )
    }

    private static func metricRevision(bucketCount: Int, minuteStart: Date?, value: Double) -> Int {
        var hasher = Hasher()
        hasher.combine(bucketCount)
        hasher.combine(minuteStart)
        hasher.combine(value)
        return hasher.finalize()
    }

    /// Changes when iPhone pain logs / daily rollups sync — not on every keystroke.
    @MainActor
    static func painLogsRevision(_ store: HandTrackStore) -> UInt64 {
        UInt64(store.hourlyLogs.count) &* 1_000_003 &+ UInt64(store.dailyPainRollups.count)
    }

    /// Heavy stacked charts: refresh on the clock / pain sync / settings — not every live input.
    static func stackedChartClockBucket(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 30.0)
    }
}
