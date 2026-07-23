import Foundation
import Combine
import SQLite3
#if os(macOS)
import AppKit
#endif

private struct DailyPainRollupSnapshot {
    /// Legacy ``DailyPainRollup.painPlotValue`` (hourly means pipeline).
    var legacyPainPlot: Double
    /// Highest `max(left, right)` seen in any synced log that calendar day.
    var worstHigherHand: Double
    /// Mean of `max(left, right)` over every log that day (one value per entry).
    var averageHigherHandPerLog: Double
}

@MainActor
final class HandTrackStore: ObservableObject {
    @Published private(set) var hourlyLogs: [HourlyHandLog] = []
    @Published private(set) var keystrokeBuckets: [KeystrokeMinuteBucket] = []
    @Published private(set) var mouseClickBuckets: [MouseClickMinuteBucket] = []
    @Published private(set) var mouseTravelBuckets: [MouseTravelMinuteBucket] = []
    @Published private(set) var scrollBumpBuckets: [ScrollBumpMinuteBucket] = []
    @Published private(set) var dailyPainRollups: [DailyPainRollup] = []

    let storageDirectory: URL

    private let databaseURL: URL
    private var database: OpaquePointer?
    /// Pain figures keyed by ``Date/startOfHandTrackingDay`` epoch (`timeIntervalSince1970`), mirrored in ``dailyPainRollups``.
    private var dailyPainRollupSnapshots: [TimeInterval: DailyPainRollupSnapshot] = [:]

    /// Coalesce rapid live-input publishes so scrolling the dashboard doesn't rebuild Charts every notch.
    private var livePublishScheduled = false
    private var lastLivePublishAt: CFAbsoluteTime = 0
    private static let livePublishMinInterval: CFAbsoluteTime = 0.08

    init(storageDirectory: URL? = nil) {
        let baseDirectory = storageDirectory ?? Self.defaultStorageDirectory()
        self.storageDirectory = baseDirectory
        self.databaseURL = baseDirectory.appendingPathComponent("handtrack.sqlite")

        load()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func saveHourlyLog(
        painLevelLeft: Double,
        painLevelRight: Double,
        minutesHandsUsed: Int,
        journalEntry: String
    ) {
        let now = Date()
        let log = HourlyHandLog(
            hourStart: now.startOfHour,
            painLevelLeft: painLevelLeft,
            painLevelRight: painLevelRight,
            minutesHandsUsed: minutesHandsUsed,
            journalEntry: journalEntry,
            createdAt: now,
            updatedAt: now,
            syncStatus: .pending
        )
        hourlyLogs.insert(log, at: 0)
        save(log)
        hourlyLogsDidChangePersisted()
    }

    func importHourlyLogs(_ incomingLogs: [HourlyHandLog]) -> [UUID] {
        var acceptedIDs: [UUID] = []
        var logsToSave: [HourlyHandLog] = []

        for var incoming in incomingLogs {
            incoming.syncStatus = .synced
            if let index = hourlyLogs.firstIndex(where: { $0.id == incoming.id }) {
                if incoming.updatedAt >= hourlyLogs[index].updatedAt {
                    hourlyLogs[index] = incoming
                    logsToSave.append(incoming)
                }
            } else {
                hourlyLogs.append(incoming)
                logsToSave.append(incoming)
            }
            acceptedIDs.append(incoming.id)
        }

        hourlyLogs.sort {
            if $0.hourStart != $1.hourStart { return $0.hourStart > $1.hourStart }
            return $0.createdAt > $1.createdAt
        }
        for log in logsToSave {
            do {
                try saveOrThrow(log)
            } catch {
                print("Failed to persist imported hourly log: \(error)")
            }
        }
        try? rebuildDailyPainRollupsFromHourlyLogs()
        return acceptedIDs
    }

    func markLogsSynced(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for index in hourlyLogs.indices where ids.contains(hourlyLogs[index].id) {
            hourlyLogs[index].syncStatus = .synced
            hourlyLogs[index].updatedAt = Date()
            save(hourlyLogs[index])
        }
    }

    func pendingLogs() -> [HourlyHandLog] {
        hourlyLogs.filter { $0.syncStatus == .pending }
    }

    func recordKeystroke(at timestamp: Date = Date()) {
        let minuteStart = timestamp.startOfMinute
        if let index = keystrokeBuckets.firstIndex(where: { $0.minuteStart == minuteStart }) {
            keystrokeBuckets[index].keyCount += 1
            save(keystrokeBuckets[index])
        } else {
            let bucket = KeystrokeMinuteBucket(minuteStart: minuteStart, keyCount: 1)
            keystrokeBuckets.append(bucket)
            keystrokeBuckets.sort { $0.minuteStart < $1.minuteStart }
            save(bucket)
        }
        // In-place bucket mutations don't go through @Published's setter.
        publishLiveBucketsChanged()
    }

    func recordMouseClick(at timestamp: Date = Date()) {
        let minuteStart = timestamp.startOfMinute
        if let index = mouseClickBuckets.firstIndex(where: { $0.minuteStart == minuteStart }) {
            mouseClickBuckets[index].clickCount += 1
            saveMouseClick(mouseClickBuckets[index])
        } else {
            let bucket = MouseClickMinuteBucket(minuteStart: minuteStart, clickCount: 1)
            mouseClickBuckets.append(bucket)
            mouseClickBuckets.sort { $0.minuteStart < $1.minuteStart }
            saveMouseClick(bucket)
        }
        publishLiveBucketsChanged()
    }

    func recordMouseTravelPixels(_ pixels: Double, at timestamp: Date = Date()) {
        guard pixels.isFinite, pixels > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        if let index = mouseTravelBuckets.firstIndex(where: { $0.minuteStart == minuteStart }) {
            mouseTravelBuckets[index].travelPixels += pixels
            saveMouseTravel(mouseTravelBuckets[index])
        } else {
            let bucket = MouseTravelMinuteBucket(minuteStart: minuteStart, travelPixels: pixels)
            mouseTravelBuckets.append(bucket)
            mouseTravelBuckets.sort { $0.minuteStart < $1.minuteStart }
            saveMouseTravel(bucket)
        }
        publishLiveBucketsChanged()
    }

    func recordScrollBumps(_ count: Int = 1, at timestamp: Date = Date()) {
        guard count > 0 else { return }
        let minuteStart = timestamp.startOfMinute
        if let index = scrollBumpBuckets.firstIndex(where: { $0.minuteStart == minuteStart }) {
            scrollBumpBuckets[index].bumpCount += count
            saveScrollBump(scrollBumpBuckets[index])
        } else {
            let bucket = ScrollBumpMinuteBucket(minuteStart: minuteStart, bumpCount: count)
            scrollBumpBuckets.append(bucket)
            scrollBumpBuckets.sort { $0.minuteStart < $1.minuteStart }
            saveScrollBump(bucket)
        }
        publishLiveBucketsChanged()
    }

    /// Notify SwiftUI of live input changes, coalesced so bursty scroll/travel doesn't jank the window.
    private func publishLiveBucketsChanged() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLivePublishAt >= Self.livePublishMinInterval {
            lastLivePublishAt = now
            objectWillChange.send()
            return
        }
        guard !livePublishScheduled else { return }
        livePublishScheduled = true
        let delay = Self.livePublishMinInterval - (now - lastLivePublishAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay)) { [weak self] in
            guard let self else { return }
            self.livePublishScheduled = false
            self.lastLivePublishAt = CFAbsoluteTimeGetCurrent()
            self.objectWillChange.send()
        }
    }

    func scrollsInLastMinutes(_ minutes: Int, reference: Date = Date()) -> Int {
        let window = max(1, minutes)
        guard let start = Calendar.current.date(byAdding: .minute, value: -window, to: reference) else { return 0 }
        return scrollBumpBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= start, bucket.minuteStart <= reference else { return sum }
            return sum + bucket.bumpCount
        }
    }

    func scrollsSinceStartOfCurrentHour(reference: Date = Date()) -> Int {
        let calendar = Calendar.current
        let hourStart = reference.startOfHour
        guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return 0 }
        return scrollBumpBuckets
            .filter { $0.minuteStart >= hourStart && $0.minuteStart < hourEnd }
            .reduce(0) { $0 + $1.bumpCount }
    }

    func keysSinceStartOfCurrentHour(reference: Date = Date()) -> Int {
        let calendar = Calendar.current
        let hourStart = reference.startOfHour
        guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return 0 }
        return keystrokeBuckets
            .filter { $0.minuteStart >= hourStart && $0.minuteStart < hourEnd }
            .reduce(0) { $0 + $1.keyCount }
    }

    func clicksSinceStartOfCurrentHour(reference: Date = Date()) -> Int {
        let calendar = Calendar.current
        let hourStart = reference.startOfHour
        guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return 0 }
        return mouseClickBuckets
            .filter { $0.minuteStart >= hourStart && $0.minuteStart < hourEnd }
            .reduce(0) { $0 + $1.clickCount }
    }

    func mouseTravelPixelsSinceStartOfCurrentHour(reference: Date = Date()) -> Double {
        let calendar = Calendar.current
        let hourStart = reference.startOfHour
        guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return 0 }
        return mouseTravelBuckets
            .filter { $0.minuteStart >= hourStart && $0.minuteStart < hourEnd }
            .reduce(0.0) { $0 + $1.travelPixels }
    }

    // MARK: - Current five-minute slot (clock-aligned like the histograms)

    func keysInCurrentFiveMinuteSlot(reference: Date = Date()) -> Int {
        let slotStart = reference.startOfFiveMinuteSlot
        guard let slotEnd = Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) else {
            return 0
        }
        return keystrokeBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
            return sum + bucket.keyCount
        }
    }

    func clicksInCurrentFiveMinuteSlot(reference: Date = Date()) -> Int {
        let slotStart = reference.startOfFiveMinuteSlot
        guard let slotEnd = Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) else {
            return 0
        }
        return mouseClickBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
            return sum + bucket.clickCount
        }
    }

    func mouseTravelPixelsInCurrentFiveMinuteSlot(reference: Date = Date()) -> Double {
        let slotStart = reference.startOfFiveMinuteSlot
        guard let slotEnd = Calendar.current.date(byAdding: .minute, value: 5, to: slotStart) else {
            return 0
        }
        return mouseTravelBuckets.reduce(0.0) { sum, bucket in
            guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
            return sum + bucket.travelPixels
        }
    }

    // MARK: - Trailing rolling window (not clock-aligned, used by activity limits + dashboard row)

    /// Sum of keystrokes whose minute-bucket starts within the last `minutes` minutes ending at `reference`.
    func keysInLastMinutes(_ minutes: Int, reference: Date = Date()) -> Int {
        let span = max(1, minutes)
        let start = reference.addingTimeInterval(-Double(span) * 60.0)
        return keystrokeBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= start, bucket.minuteStart <= reference else { return sum }
            return sum + bucket.keyCount
        }
    }

    func clicksInLastMinutes(_ minutes: Int, reference: Date = Date()) -> Int {
        let span = max(1, minutes)
        let start = reference.addingTimeInterval(-Double(span) * 60.0)
        return mouseClickBuckets.reduce(0) { sum, bucket in
            guard bucket.minuteStart >= start, bucket.minuteStart <= reference else { return sum }
            return sum + bucket.clickCount
        }
    }

    func mouseTravelPixelsInLastMinutes(_ minutes: Int, reference: Date = Date()) -> Double {
        let span = max(1, minutes)
        let start = reference.addingTimeInterval(-Double(span) * 60.0)
        return mouseTravelBuckets.reduce(0.0) { sum, bucket in
            guard bucket.minuteStart >= start, bucket.minuteStart <= reference else { return sum }
            return sum + bucket.travelPixels
        }
    }

    func averageWordsPerMinuteForCurrentHour(reference: Date = Date()) -> Double {
        let hourStart = reference.startOfHour
        let elapsedMinutes = max(reference.timeIntervalSince(hourStart) / 60, 1)
        let words = Double(keysSinceStartOfCurrentHour(reference: reference)) / 5
        return words / elapsedMinutes
    }

    func keystrokesByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [KeystrokeFiveMinuteSlot] {
        trailingCountSlots(reference: reference, count: count, minutesPerSlot: minutesPerSlot) { slotStart, slotEnd, duration in
            let keyCount = keystrokeBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
                return sum + bucket.keyCount
            }
            return KeystrokeFiveMinuteSlot(slotStart: slotStart, keyCount: keyCount, durationMinutes: duration)
        }
    }

    func mouseClicksByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [MouseClickFiveMinuteSlot] {
        trailingCountSlots(reference: reference, count: count, minutesPerSlot: minutesPerSlot) { slotStart, slotEnd, duration in
            let clickCount = mouseClickBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
                return sum + bucket.clickCount
            }
            return MouseClickFiveMinuteSlot(slotStart: slotStart, clickCount: clickCount, durationMinutes: duration)
        }
    }

    func mouseTravelByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [MouseTravelFiveMinuteSlot] {
        trailingCountSlots(reference: reference, count: count, minutesPerSlot: minutesPerSlot) { slotStart, slotEnd, duration in
            let travelPixels = mouseTravelBuckets.reduce(0.0) { sum, bucket in
                guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
                return sum + bucket.travelPixels
            }
            return MouseTravelFiveMinuteSlot(slotStart: slotStart, travelPixels: travelPixels, durationMinutes: duration)
        }
    }

    func scrollBumpsByFiveMinuteSlotsTrailing(
        reference: Date = Date(),
        count: Int = 12,
        minutesPerSlot: Int = 5
    ) -> [ScrollBumpFiveMinuteSlot] {
        trailingCountSlots(reference: reference, count: count, minutesPerSlot: minutesPerSlot) { slotStart, slotEnd, duration in
            let bumpCount = scrollBumpBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= slotStart, bucket.minuteStart < slotEnd else { return sum }
                return sum + bucket.bumpCount
            }
            return ScrollBumpFiveMinuteSlot(slotStart: slotStart, bumpCount: bumpCount, durationMinutes: duration)
        }
    }

    private func trailingCountSlots<Slot>(
        reference: Date,
        count: Int,
        minutesPerSlot: Int,
        makeSlot: (_ slotStart: Date, _ slotEnd: Date, _ duration: Int) -> Slot
    ) -> [Slot] {
        let calendar = Calendar.current
        let duration = max(1, minutesPerSlot)
        let currentSlotStart = duration == 5 ? reference.startOfFiveMinuteSlot : reference.startOfMinute
        var slots: [Slot] = []
        slots.reserveCapacity(count)
        for i in 0..<count {
            let minutesBack = duration * (count - 1 - i)
            guard let slotStart = calendar.date(byAdding: .minute, value: -minutesBack, to: currentSlotStart),
                  let slotEnd = calendar.date(byAdding: .minute, value: duration, to: slotStart)
            else { continue }
            slots.append(makeSlot(slotStart, slotEnd, duration))
        }
        return slots
    }

    /// The last `count` **calendar hours** ending at the hour containing `reference`, oldest → newest.
    func computerUsageByTrailingCalendarHours(reference: Date = Date(), count: Int = 12) -> [ComputerUsageHourSlot] {
        let calendar = Calendar.current
        let anchorHour = reference.startOfHour

        var slots: [ComputerUsageHourSlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let hoursBack = count - 1 - i
            guard let hourStart = calendar.date(byAdding: .hour, value: -hoursBack, to: anchorHour),
                  let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart)
            else { continue }

            let keystrokeCount = keystrokeBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= hourStart, bucket.minuteStart < hourEnd else { return sum }
                return sum + bucket.keyCount
            }
            let mouseClickCount = mouseClickBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= hourStart, bucket.minuteStart < hourEnd else { return sum }
                return sum + bucket.clickCount
            }
            let travelPixels = mouseTravelBuckets.reduce(0.0) { sum, bucket in
                guard bucket.minuteStart >= hourStart, bucket.minuteStart < hourEnd else { return sum }
                return sum + bucket.travelPixels
            }
            let scrollBumpCount = scrollBumpBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= hourStart, bucket.minuteStart < hourEnd else { return sum }
                return sum + bucket.bumpCount
            }

            slots.append(
                ComputerUsageHourSlot(
                    hourStart: hourStart,
                    keystrokeCount: keystrokeCount,
                    mouseClickCount: mouseClickCount,
                    travelPixels: travelPixels,
                    scrollBumpCount: scrollBumpCount
                )
            )
        }

        return slots
    }

    /// The last `count` **hand-tracking days** (3 AM → 3 AM) ending on the day segment containing `reference`, oldest → newest.
    func computerUsageByTrailingCalendarDays(reference: Date = Date(), count: Int = 12) -> [ComputerUsageDaySlot] {
        let calendar = Calendar.current
        let anchorDay = reference.startOfHandTrackingDay

        var slots: [ComputerUsageDaySlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let daysBack = count - 1 - i
            guard let dayStart = calendar.date(byAdding: .day, value: -daysBack, to: anchorDay),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }

            let keystrokeCount = keystrokeBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= dayStart, bucket.minuteStart < nextDay else { return sum }
                return sum + bucket.keyCount
            }
            let mouseClickCount = mouseClickBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= dayStart, bucket.minuteStart < nextDay else { return sum }
                return sum + bucket.clickCount
            }
            let travelPixels = mouseTravelBuckets.reduce(0.0) { sum, bucket in
                guard bucket.minuteStart >= dayStart, bucket.minuteStart < nextDay else { return sum }
                return sum + bucket.travelPixels
            }
            let scrollBumpCount = scrollBumpBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= dayStart, bucket.minuteStart < nextDay else { return sum }
                return sum + bucket.bumpCount
            }

            slots.append(
                ComputerUsageDaySlot(
                    dayStart: dayStart,
                    keystrokeCount: keystrokeCount,
                    mouseClickCount: mouseClickCount,
                    travelPixels: travelPixels,
                    scrollBumpCount: scrollBumpCount
                )
            )
        }

        return slots
    }

    /// Segment for the hand-tracking window that contains ``reference`` (same as trailing `count: 1`).
    func computerUsageOnCalendarDayContaining(reference: Date = Date()) -> ComputerUsageDaySlot? {
        computerUsageByTrailingCalendarDays(reference: reference, count: 1).first
    }

    /// Bucket for the **prior** hand-tracking day (relative to ``reference``) when trailing data includes it.
    func computerUsageOnPreviousCalendarDay(reference: Date = Date()) -> ComputerUsageDaySlot? {
        let slots = computerUsageByTrailingCalendarDays(reference: reference, count: 2)
        guard slots.count >= 2 else { return slots.first }
        return slots.first
    }

    /// The last `count` **calendar weeks** (Monday → Monday) ending on the week containing `reference`, oldest → newest.
    func computerUsageByTrailingCalendarWeeks(reference: Date = Date(), count: Int = 12) -> [ComputerUsageWeekSlot] {
        let calendar = Calendar.current
        let anchorWeek = reference.startOfCalendarWeek

        var slots: [ComputerUsageWeekSlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let weeksBack = count - 1 - i
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: anchorWeek),
                  let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart)
            else { continue }

            let keystrokeCount = keystrokeBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= weekStart, bucket.minuteStart < weekEnd else { return sum }
                return sum + bucket.keyCount
            }
            let mouseClickCount = mouseClickBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= weekStart, bucket.minuteStart < weekEnd else { return sum }
                return sum + bucket.clickCount
            }
            let travelPixels = mouseTravelBuckets.reduce(0.0) { sum, bucket in
                guard bucket.minuteStart >= weekStart, bucket.minuteStart < weekEnd else { return sum }
                return sum + bucket.travelPixels
            }
            let scrollBumpCount = scrollBumpBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= weekStart, bucket.minuteStart < weekEnd else { return sum }
                return sum + bucket.bumpCount
            }

            slots.append(
                ComputerUsageWeekSlot(
                    weekStart: weekStart,
                    keystrokeCount: keystrokeCount,
                    mouseClickCount: mouseClickCount,
                    travelPixels: travelPixels,
                    scrollBumpCount: scrollBumpCount
                )
            )
        }

        return slots
    }

    /// The last `count` **calendar months** ending on the month containing `reference`, oldest → newest.
    func computerUsageByTrailingCalendarMonths(reference: Date = Date(), count: Int = 12) -> [ComputerUsageMonthSlot] {
        let calendar = Calendar.current
        let anchorMonth = reference.startOfCalendarMonth

        var slots: [ComputerUsageMonthSlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let monthsBack = count - 1 - i
            guard let monthStart = calendar.date(byAdding: .month, value: -monthsBack, to: anchorMonth),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else { continue }

            let keystrokeCount = keystrokeBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= monthStart, bucket.minuteStart < monthEnd else { return sum }
                return sum + bucket.keyCount
            }
            let mouseClickCount = mouseClickBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= monthStart, bucket.minuteStart < monthEnd else { return sum }
                return sum + bucket.clickCount
            }
            let travelPixels = mouseTravelBuckets.reduce(0.0) { sum, bucket in
                guard bucket.minuteStart >= monthStart, bucket.minuteStart < monthEnd else { return sum }
                return sum + bucket.travelPixels
            }
            let scrollBumpCount = scrollBumpBuckets.reduce(0) { sum, bucket in
                guard bucket.minuteStart >= monthStart, bucket.minuteStart < monthEnd else { return sum }
                return sum + bucket.bumpCount
            }

            slots.append(
                ComputerUsageMonthSlot(
                    monthStart: monthStart,
                    keystrokeCount: keystrokeCount,
                    mouseClickCount: mouseClickCount,
                    travelPixels: travelPixels,
                    scrollBumpCount: scrollBumpCount
                )
            )
        }

        return slots
    }

    func monthlyPainWorstLoggedLeftHand(forOrderedMonthStarts months: [Date]) -> [Double?] {
        monthlyPainLoggedHandAggregate(forOrderedMonthStarts: months, hand: \.painLevelLeft) { vals in vals.max()! }
    }

    func monthlyPainWorstLoggedRightHand(forOrderedMonthStarts months: [Date]) -> [Double?] {
        monthlyPainLoggedHandAggregate(forOrderedMonthStarts: months, hand: \.painLevelRight) { vals in vals.max()! }
    }

    func monthlyPainMeanLoggedLeftHand(forOrderedMonthStarts months: [Date]) -> [Double?] {
        monthlyPainLoggedHandAggregate(forOrderedMonthStarts: months, hand: \.painLevelLeft) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    func monthlyPainMeanLoggedRightHand(forOrderedMonthStarts months: [Date]) -> [Double?] {
        monthlyPainLoggedHandAggregate(forOrderedMonthStarts: months, hand: \.painLevelRight) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    private func monthlyPainLoggedHandAggregate(
        forOrderedMonthStarts months: [Date],
        hand: KeyPath<HourlyHandLog, Double>,
        aggregate: ([Double]) -> Double
    ) -> [Double?] {
        let cal = Calendar.current
        return months.map { monthStart in
            guard let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            let vals = hourlyLogs.filter { $0.hourStart >= monthStart && $0.hourStart < monthEnd }.map { $0[keyPath: hand] }
            guard !vals.isEmpty else { return nil }
            return aggregate(vals)
        }
    }

    func weeklyPainWorstLoggedLeftHand(forOrderedWeekStarts weeks: [Date]) -> [Double?] {
        weeklyPainLoggedHandAggregate(forOrderedWeekStarts: weeks, hand: \.painLevelLeft) { vals in vals.max()! }
    }

    func weeklyPainWorstLoggedRightHand(forOrderedWeekStarts weeks: [Date]) -> [Double?] {
        weeklyPainLoggedHandAggregate(forOrderedWeekStarts: weeks, hand: \.painLevelRight) { vals in vals.max()! }
    }

    func weeklyPainMeanLoggedLeftHand(forOrderedWeekStarts weeks: [Date]) -> [Double?] {
        weeklyPainLoggedHandAggregate(forOrderedWeekStarts: weeks, hand: \.painLevelLeft) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    func weeklyPainMeanLoggedRightHand(forOrderedWeekStarts weeks: [Date]) -> [Double?] {
        weeklyPainLoggedHandAggregate(forOrderedWeekStarts: weeks, hand: \.painLevelRight) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    private func weeklyPainLoggedHandAggregate(
        forOrderedWeekStarts weeks: [Date],
        hand: KeyPath<HourlyHandLog, Double>,
        aggregate: ([Double]) -> Double
    ) -> [Double?] {
        let cal = Calendar.current
        return weeks.map { weekStart in
            guard let weekEnd = cal.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { return nil }
            let vals = hourlyLogs.filter { $0.hourStart >= weekStart && $0.hourStart < weekEnd }.map { $0[keyPath: hand] }
            guard !vals.isEmpty else { return nil }
            return aggregate(vals)
        }
    }

    /// Legacy daily figure: hourly means, then max(L̄, R̄). Order matches ``computerUsageByTrailingCalendarDays``.
    func dailyPainMaxOfMeanHourlyAverages(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        days.map { dailyPainRollupSnapshots[$0.timeIntervalSince1970]?.legacyPainPlot }
    }

    /// Highest `max(left, right)` among all hand logs in that **hand-tracking** segment (`nil` if no logs).
    func dailyPainWorstHigherHandForDay(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        days.map { dailyPainRollupSnapshots[$0.timeIntervalSince1970]?.worstHigherHand }
    }

    /// Mean `max(left, right)` over every hourly log row in that segment (`nil` if no logs).
    func dailyPainAverageHigherHandPerLoggedSample(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        days.map { dailyPainRollupSnapshots[$0.timeIntervalSince1970]?.averageHigherHandPerLog }
    }

    /// First iPhone log in each **hand-tracking** segment (by `hourStart`, then `createdAt`). Order matches ``computerUsageByTrailingCalendarDays``.
    func dailyPainFirstLoggedLeftHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainFirstLoggedHand(forOrderedCalendarDayStarts: days, hand: \.painLevelLeft)
    }

    /// Same as ``dailyPainFirstLoggedLeftHand`` but **right** hand pain on that first log.
    func dailyPainFirstLoggedRightHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainFirstLoggedHand(forOrderedCalendarDayStarts: days, hand: \.painLevelRight)
    }

    private func dailyPainFirstLoggedHand(forOrderedCalendarDayStarts days: [Date], hand: KeyPath<HourlyHandLog, Double>) -> [Double?] {
        let cal = Calendar.current
        return days.map { dayStart in
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let dayLogs = hourlyLogs.filter { $0.hourStart >= dayStart && $0.hourStart < dayEnd }
            guard let first = dayLogs.min(by: {
                if $0.hourStart != $1.hourStart { return $0.hourStart < $1.hourStart }
                return $0.createdAt < $1.createdAt
            }) else { return nil }
            return first[keyPath: hand]
        }
    }

    /// Highest **left‑hand** pain among logs in that **hand-tracking** segment (`nil` if none).
    func dailyPainWorstLoggedLeftHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainLoggedHandAggregate(forOrderedCalendarDayStarts: days, hand: \.painLevelLeft) { vals in vals.max()! }
    }

    /// Highest **right‑hand** pain in that segment (`nil` if none).
    func dailyPainWorstLoggedRightHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainLoggedHandAggregate(forOrderedCalendarDayStarts: days, hand: \.painLevelRight) { vals in vals.max()! }
    }

    /// Mean **left‑hand** pain averaged over **every log row** in that segment (`nil` if none).
    func dailyPainMeanLoggedLeftHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainLoggedHandAggregate(forOrderedCalendarDayStarts: days, hand: \.painLevelLeft) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    /// Mean **right‑hand** pain over all log rows in that segment (`nil` if none).
    func dailyPainMeanLoggedRightHand(forOrderedCalendarDayStarts days: [Date]) -> [Double?] {
        dailyPainLoggedHandAggregate(forOrderedCalendarDayStarts: days, hand: \.painLevelRight) { vals in
            vals.reduce(0, +) / Double(vals.count)
        }
    }

    private func dailyPainLoggedHandAggregate(
        forOrderedCalendarDayStarts days: [Date],
        hand: KeyPath<HourlyHandLog, Double>,
        aggregate: ([Double]) -> Double
    ) -> [Double?] {
        let cal = Calendar.current
        return days.map { dayStart in
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let vals = hourlyLogs.filter { $0.hourStart >= dayStart && $0.hourStart < dayEnd }.map { $0[keyPath: hand] }
            guard !vals.isEmpty else { return nil }
            return aggregate(vals)
        }
    }

    /// For ordered hour starts from ``computerUsageByTrailingCalendarHours``, max of left/right logged pain (`nil` where no hourly log landed in that bucket).
    func loggedPainHigherOfHandsByHour(forOrderedHourStarts hours: [Date]) -> [Double?] {
        hours.map { h in
            let highs = hourlyLogs
                .filter { $0.hourStart == h }
                .map { max($0.painLevelLeft, $0.painLevelRight) }
            guard let m = highs.max() else { return nil }
            return m
        }
    }

    func openStorageDirectory() {
        #if os(macOS)
        NSWorkspace.shared.open(storageDirectory)
        #endif
    }

    func reloadFromDisk() {
        load()
    }

    private func rebuildDailyPainRollupsFromHourlyLogs() throws {
        dailyPainRollupSnapshots.removeAll()
        try execute("DELETE FROM daily_pain_rollups;")

        var nested: [TimeInterval: [TimeInterval: [(Double, Double)]]] = [:]
        var logHigherPerDay: [TimeInterval: [Double]] = [:]

        for log in hourlyLogs {
            let dayKey = log.hourStart.startOfHandTrackingDay.timeIntervalSince1970
            let hourKey = log.hourStart.startOfHour.timeIntervalSince1970
            nested[dayKey, default: [:]][hourKey, default: []].append((log.painLevelLeft, log.painLevelRight))

            let higher = max(log.painLevelLeft, log.painLevelRight)
            logHigherPerDay[dayKey, default: []].append(higher)
        }

        var rollups: [DailyPainRollup] = []
        rollups.reserveCapacity(nested.count)

        for (dayKey, hourMap) in nested {
            var leftHourAvgs: [Double] = []
            var rightHourAvgs: [Double] = []

            for (_, pairs) in hourMap.sorted(by: { $0.key < $1.key }) {
                let n = Double(pairs.count)
                let sumL = pairs.reduce(0.0) { $0 + $1.0 }
                let sumR = pairs.reduce(0.0) { $0 + $1.1 }
                leftHourAvgs.append(sumL / n)
                rightHourAvgs.append(sumR / n)
            }
            guard !leftHourAvgs.isEmpty else { continue }

            let highs = logHigherPerDay[dayKey] ?? []
            guard !highs.isEmpty else { continue }

            let hCount = leftHourAvgs.count
            let meanLeft = leftHourAvgs.reduce(0.0, +) / Double(hCount)
            let meanRight = rightHourAvgs.reduce(0.0, +) / Double(hCount)
            let plot = max(meanLeft, meanRight)
            let worstHigher = highs.max() ?? plot
            let avgLoggedHigher = highs.reduce(0.0, +) / Double(highs.count)

            try upsertDailyPainRollup(
                dayStart: dayKey,
                meanLeft: meanLeft,
                meanRight: meanRight,
                plot: plot,
                worstHigherHand: worstHigher,
                avgLoggedHigherHand: avgLoggedHigher,
                hoursWithLogs: hCount
            )

            dailyPainRollupSnapshots[dayKey] = DailyPainRollupSnapshot(
                legacyPainPlot: plot,
                worstHigherHand: worstHigher,
                averageHigherHandPerLog: avgLoggedHigher
            )

            rollups.append(
                DailyPainRollup(
                    dayStart: Date(timeIntervalSince1970: dayKey),
                    meanOfHourlyAverageLeft: meanLeft,
                    meanOfHourlyAverageRight: meanRight,
                    painPlotValue: plot,
                    worstHigherHandPain: worstHigher,
                    averageHigherHandPainPerLog: avgLoggedHigher,
                    hoursWithLogs: hCount
                )
            )
        }

        rollups.sort { $0.dayStart > $1.dayStart }
        dailyPainRollups = rollups
    }

    private func upsertDailyPainRollup(
        dayStart: TimeInterval,
        meanLeft: Double,
        meanRight: Double,
        plot: Double,
        worstHigherHand: Double,
        avgLoggedHigherHand: Double,
        hoursWithLogs: Int
    ) throws {
        try withStatement("""
        INSERT OR REPLACE INTO daily_pain_rollups (
            day_start,
            mean_hourly_avg_left,
            mean_hourly_avg_right,
            pain_plot_value,
            worst_higher_hand,
            avg_logged_higher_hand,
            hours_with_logs
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, dayStart)
            sqlite3_bind_double(statement, 2, meanLeft)
            sqlite3_bind_double(statement, 3, meanRight)
            sqlite3_bind_double(statement, 4, plot)
            sqlite3_bind_double(statement, 5, worstHigherHand)
            sqlite3_bind_double(statement, 6, avgLoggedHigherHand)
            sqlite3_bind_int(statement, 7, Int32(hoursWithLogs))
            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            try openDatabaseIfNeeded()
            try createSchema()
            hourlyLogs = try loadHourlyLogs()
            keystrokeBuckets = try loadKeystrokeBuckets()
            mouseClickBuckets = try loadMouseClickBuckets()
            mouseTravelBuckets = try loadMouseTravelBuckets()
            scrollBumpBuckets = try loadScrollBumpBuckets()
            try rebuildDailyPainRollupsFromHourlyLogs()
        } catch {
            hourlyLogs = []
            keystrokeBuckets = []
            mouseClickBuckets = []
            mouseTravelBuckets = []
            scrollBumpBuckets = []
            dailyPainRollups = []
            dailyPainRollupSnapshots = [:]
            print("Failed to load HandTrack data: \(error)")
        }
    }

    private func openDatabaseIfNeeded() throws {
        guard database == nil else { return }
        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw StoreError.sqlite(message: lastSQLiteError)
        }
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS hourly_logs (
            id TEXT PRIMARY KEY,
            hour_start REAL NOT NULL,
            pain_level REAL NOT NULL,
            pain_level_left REAL NOT NULL,
            pain_level_right REAL NOT NULL,
            minutes_hands_used INTEGER NOT NULL,
            journal_entry TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            sync_status TEXT NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS keystroke_minute_buckets (
            minute_start REAL PRIMARY KEY,
            key_count INTEGER NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS mouse_click_minute_buckets (
            minute_start REAL PRIMARY KEY,
            click_count INTEGER NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS mouse_travel_minute_buckets (
            minute_start REAL PRIMARY KEY,
            travel_pixels REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS scroll_bump_minute_buckets (
            minute_start REAL PRIMARY KEY,
            bump_count INTEGER NOT NULL
        );
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_hourly_logs_hour_start ON hourly_logs(hour_start);")

        try execute("""
        CREATE TABLE IF NOT EXISTS daily_pain_rollups (
            day_start REAL PRIMARY KEY NOT NULL,
            mean_hourly_avg_left REAL NOT NULL,
            mean_hourly_avg_right REAL NOT NULL,
            pain_plot_value REAL NOT NULL,
            worst_higher_hand REAL NOT NULL,
            avg_logged_higher_hand REAL NOT NULL,
            hours_with_logs INTEGER NOT NULL
        );
        """)

        try migrateDailyPainRollupSnapshotColumnsIfNeeded()
        try migrateHourlyLogsPainSidesIfNeeded()
        try migrateHourlyPainLevelsToHalfStepStorageIfNeeded()
    }

    private func dailyPainRollupColumnNames() throws -> Set<String> {
        try query("PRAGMA table_info(daily_pain_rollups)") { statement in
            columnText(statement, at: 1)
        }
        .reduce(into: Set<String>()) { $0.insert($1) }
    }

    /// Adds daily worst / per‑log‑average snapshot columns introduced after the original rollup table.
    private func migrateDailyPainRollupSnapshotColumnsIfNeeded() throws {
        var columns = try dailyPainRollupColumnNames()
        if columns.isEmpty { return }

        if !columns.contains("worst_higher_hand") {
            try execute("""
                ALTER TABLE daily_pain_rollups ADD COLUMN worst_higher_hand REAL NOT NULL DEFAULT 0;
            """)
            columns.insert("worst_higher_hand")
        }
        if !columns.contains("avg_logged_higher_hand") {
            try execute("""
                ALTER TABLE daily_pain_rollups ADD COLUMN avg_logged_higher_hand REAL NOT NULL DEFAULT 0;
            """)
        }
        // Rows are rewritten in ``rebuildDailyPainRollupsFromHourlyLogs()`` after logs load.
    }

    private func hourlyLogColumnNames() throws -> Set<String> {
        try query("PRAGMA table_info(hourly_logs)") { statement in
            columnText(statement, at: 1)
        }
        .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func migrateHourlyLogsPainSidesIfNeeded() throws {
        var columns = try hourlyLogColumnNames()
        if columns.isEmpty { return }

        var addedSides = false
        if !columns.contains("pain_level_left") {
            try execute("""
                ALTER TABLE hourly_logs ADD COLUMN pain_level_left INTEGER NOT NULL DEFAULT 1;
            """)
            columns.insert("pain_level_left")
            addedSides = true
        }
        if !columns.contains("pain_level_right") {
            try execute("""
                ALTER TABLE hourly_logs ADD COLUMN pain_level_right INTEGER NOT NULL DEFAULT 1;
            """)
            addedSides = true
        }
        if addedSides {
            try execute("""
                UPDATE hourly_logs SET pain_level_left = pain_level, pain_level_right = pain_level;
            """)
        }
    }

    /// INTEGER affinity rounding can truncate half steps (`2.5` → `2`). Recreate rows with REAL pain columns once.
    private func migrateHourlyPainLevelsToHalfStepStorageIfNeeded() throws {
        guard !(try hourlyLogColumnNames()).isEmpty else { return }
        guard try hourlyPainColumnsDeclareExplicitIntegerAffinity() else { return }

        try execute("""
        BEGIN IMMEDIATE;
        CREATE TABLE hourly_logs_half_step_migr (
            id TEXT PRIMARY KEY,
            hour_start REAL NOT NULL,
            pain_level REAL NOT NULL,
            pain_level_left REAL NOT NULL,
            pain_level_right REAL NOT NULL,
            minutes_hands_used INTEGER NOT NULL,
            journal_entry TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            sync_status TEXT NOT NULL
        );
        INSERT INTO hourly_logs_half_step_migr (
            id, hour_start, pain_level, pain_level_left, pain_level_right,
            minutes_hands_used, journal_entry, created_at, updated_at, sync_status
        )
        SELECT id, hour_start,
            CAST(pain_level AS REAL),
            CAST(pain_level_left AS REAL),
            CAST(pain_level_right AS REAL),
            minutes_hands_used, journal_entry, created_at, updated_at, sync_status
        FROM hourly_logs;
        DROP TABLE hourly_logs;
        ALTER TABLE hourly_logs_half_step_migr RENAME TO hourly_logs;
        CREATE INDEX IF NOT EXISTS idx_hourly_logs_hour_start ON hourly_logs(hour_start);
        COMMIT;
        """)
    }

    private func hourlyPainColumnsDeclareExplicitIntegerAffinity() throws -> Bool {
        let rows: [(String, String)] = try query("PRAGMA table_info(hourly_logs)") { statement in
            (columnText(statement, at: 1).lowercased(), columnText(statement, at: 2).lowercased())
        }
        let painNames = Set(["pain_level", "pain_level_left", "pain_level_right"])
        for (name, typeDecl) in rows {
            guard painNames.contains(name) else { continue }
            let trimmed = typeDecl.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("int") {
                return true
            }
        }
        return false
    }

    private func save(_ log: HourlyHandLog) {
        do {
            try saveOrThrow(log)
        } catch {
            print("Failed to save hourly log: \(error)")
        }
    }

    /// Call after persisted hourly-log mutations that skip ``save(_:)`` (SQLite only).
    private func hourlyLogsDidChangePersisted() {
        try? rebuildDailyPainRollupsFromHourlyLogs()
    }

    private func save(_ bucket: KeystrokeMinuteBucket) {
        do {
            try saveOrThrow(bucket)
        } catch {
            print("Failed to save keystroke bucket: \(error)")
        }
    }

    private func saveMouseClick(_ bucket: MouseClickMinuteBucket) {
        do {
            try saveMouseClickOrThrow(bucket)
        } catch {
            print("Failed to save mouse click bucket: \(error)")
        }
    }

    private func saveMouseTravel(_ bucket: MouseTravelMinuteBucket) {
        do {
            try saveMouseTravelOrThrow(bucket)
        } catch {
            print("Failed to save mouse travel bucket: \(error)")
        }
    }

    private func saveOrThrow(_ log: HourlyHandLog) throws {
        try withStatement("""
        INSERT OR REPLACE INTO hourly_logs (
            id,
            hour_start,
            pain_level,
            pain_level_left,
            pain_level_right,
            minutes_hands_used,
            journal_entry,
            created_at,
            updated_at,
            sync_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            bindText(log.id.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, log.hourStart.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, log.painLevelLeft)
            sqlite3_bind_double(statement, 4, log.painLevelLeft)
            sqlite3_bind_double(statement, 5, log.painLevelRight)
            sqlite3_bind_int(statement, 6, Int32(log.minutesHandsUsed))
            bindText(log.journalEntry, to: statement, at: 7)
            sqlite3_bind_double(statement, 8, log.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 9, log.updatedAt.timeIntervalSince1970)
            bindText(log.syncStatus.rawValue, to: statement, at: 10)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func saveOrThrow(_ bucket: KeystrokeMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO keystroke_minute_buckets (minute_start, key_count)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(bucket.keyCount))

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func saveMouseClickOrThrow(_ bucket: MouseClickMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO mouse_click_minute_buckets (minute_start, click_count)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(bucket.clickCount))

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func saveMouseTravelOrThrow(_ bucket: MouseTravelMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO mouse_travel_minute_buckets (minute_start, travel_pixels)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, bucket.travelPixels)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadHourlyLogs() throws -> [HourlyHandLog] {
        try query("""
        SELECT id, hour_start, pain_level_left, pain_level_right,
               minutes_hands_used, journal_entry, created_at, updated_at, sync_status
        FROM hourly_logs
        ORDER BY hour_start DESC, created_at DESC;
        """) { statement in
            guard let id = UUID(uuidString: columnText(statement, at: 0)) else {
                throw StoreError.invalidData("Invalid hourly log UUID")
            }

            return HourlyHandLog(
                id: id,
                hourStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                painLevelLeft: sqlite3_column_double(statement, 2),
                painLevelRight: sqlite3_column_double(statement, 3),
                minutesHandsUsed: Int(sqlite3_column_int(statement, 4)),
                journalEntry: columnText(statement, at: 5),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                syncStatus: SyncStatus(rawValue: columnText(statement, at: 8)) ?? .pending
            )
        }
    }

    private func loadKeystrokeBuckets() throws -> [KeystrokeMinuteBucket] {
        try query("""
        SELECT minute_start, key_count
        FROM keystroke_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return KeystrokeMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                keyCount: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func loadMouseClickBuckets() throws -> [MouseClickMinuteBucket] {
        try query("""
        SELECT minute_start, click_count
        FROM mouse_click_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return MouseClickMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                clickCount: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func loadMouseTravelBuckets() throws -> [MouseTravelMinuteBucket] {
        try query("""
        SELECT minute_start, travel_pixels
        FROM mouse_travel_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return MouseTravelMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                travelPixels: sqlite3_column_double(statement, 1)
            )
        }
    }

    private func saveScrollBump(_ bucket: ScrollBumpMinuteBucket) {
        do {
            try saveScrollBumpOrThrow(bucket)
        } catch {
            print("Failed to save scroll bump bucket: \(error)")
        }
    }

    private func saveScrollBumpOrThrow(_ bucket: ScrollBumpMinuteBucket) throws {
        try withStatement("""
        INSERT OR REPLACE INTO scroll_bump_minute_buckets (minute_start, bump_count)
        VALUES (?, ?);
        """) { statement in
            sqlite3_bind_double(statement, 1, bucket.minuteStart.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(bucket.bumpCount))

            if sqlite3_step(statement) != SQLITE_DONE {
                throw StoreError.sqlite(message: lastSQLiteError)
            }
        }
    }

    private func loadScrollBumpBuckets() throws -> [ScrollBumpMinuteBucket] {
        try query("""
        SELECT minute_start, bump_count
        FROM scroll_bump_minute_buckets
        ORDER BY minute_start ASC;
        """) { statement in
            return ScrollBumpMinuteBucket(
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                bumpCount: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(message: lastSQLiteError)
        }
    }

    private func query<T>(_ sql: String, row: (OpaquePointer) throws -> T) throws -> [T] {
        try withStatement(sql) { statement in
            var values: [T] = []

            while true {
                let result = sqlite3_step(statement)

                if result == SQLITE_ROW {
                    values.append(try row(statement))
                } else if result == SQLITE_DONE {
                    return values
                } else {
                    throw StoreError.sqlite(message: lastSQLiteError)
                }
            }
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.sqlite(message: lastSQLiteError)
        }

        defer {
            sqlite3_finalize(statement)
        }

        return try body(statement)
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    private var lastSQLiteError: String {
        guard let database else { return "Database is not open" }
        guard let message = sqlite3_errmsg(database) else { return "Unknown SQLite error" }
        return String(cString: message)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func defaultStorageDirectory() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return baseURL.appendingPathComponent("HandTrack", isDirectory: true)
    }
}

private enum StoreError: LocalizedError {
    case sqlite(message: String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return "SQLite error: \(message)"
        case .invalidData(let message):
            return message
        }
    }
}
