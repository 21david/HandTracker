import Foundation
import UserNotifications

/// Schedules hourly check-in alerts on the **calendar** (fires at `:00`).
enum HourlyReminderManager {

    private static let canonicalIdentifierPrefix = "hourly-hand-slot-"

    /// How many future hourly buckets to enqueue (rolls forward when user re-enables or opens Future hook).
    private static let defaultHorizonHours = 168

    static func requestPermissionAndSchedule(horizonHours: Int = defaultHorizonHours) async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        guard granted else { return }

        await cancelAllScheduled(center: center)

        let cursor = startOfNextClockHour(from: Date())
        try await enqueueHourlySlots(
            startingAt: cursor,
            count: horizonHours,
            center: center
        )
    }

    static func cancelAllScheduled(center: UNUserNotificationCenter = .current()) async {
        let requests = await pendingRequests(in: center)
        let stale = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(canonicalIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
    }

    // MARK: - Private

    private static func pendingRequests(in center: UNUserNotificationCenter) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
    }

    /// **Strictly after** now: exactly the next `:00`.
    private static func startOfNextClockHour(from date: Date) -> Date {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .hour, for: date) else {
            return date.addingTimeInterval(3600)
        }
        return interval.end
    }

    private static func enqueueHourlySlots(
        startingAt firstFire: Date,
        count: Int,
        center: UNUserNotificationCenter
    ) async throws {

        guard count > 0 else { return }

        let calendar = Calendar.current
        var fireDate = firstFire

        for _ in 0..<count {
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let epoch = Int(fireDate.timeIntervalSince1970)

            let content = UNMutableNotificationContent()
            content.title = "Hand Helper check-in"
            content.body = "Log your pain level, hand-use minutes, and notes for this hour."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: canonicalIdentifierPrefix + "\(epoch)",
                content: content,
                trigger: trigger
            )
            try await center.add(request)

            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: fireDate) else { break }
            fireDate = nextHour
        }
    }
}
