import Foundation
import UserNotifications

/// Schedules hourly check-in alerts aligned to `:00`.
enum HourlyReminderManager {

    /// First eligible reminder hour after quiet periods overnight (device local time).
    static let morningResumeHour = 7

    private static let canonicalIdentifierPrefix = "hourly-hand-slot-"

    /// How many **eligible** `:00` slots to enqueue (skipped overnight hours aren’t billed).
    private static let defaultEligibleSlotBudget = 168

    enum QuietStopChoice: Int, CaseIterable, Identifiable {

        /// Silence from **10 p.m.** onward until \(morningResumeHour):00.
        case tenPM = 0
        case elevenPM = 1
        /// Silence midnight until morning only (evening 10–11 p.m. still allowed).
        case twelveAM = 2
        /// Silence from **1 a.m.** onward until morning (midnight ding still allowed).
        case oneAM = 3

        var id: Int { rawValue }

        var pickerTitle: String {
            switch self {
            case .tenPM: return "10 p.m."
            case .elevenPM: return "11 p.m."
            case .twelveAM: return "12 a.m."
            case .oneAM: return "1 a.m."
            }
        }

        /// Hour is `.hour` for the scheduled `:00` fire time (local).
        func allowsFire(atHour hour: Int, wakeHour: Int) -> Bool {
            let wake = HourlyReminderManager.clampedWakeHour(wakeHour)

            switch self {
            case .tenPM:
                return !(hour >= 22 || hour < wake)
            case .elevenPM:
                return !(hour >= 23 || hour < wake)
            case .twelveAM:
                return hour >= wake
            case .oneAM:
                return !(hour >= 1 && hour < wake)
            }
        }
    }

    static func requestPermissionAndSchedule(
        quietChoice: QuietStopChoice = .elevenPM,
        wakeHour: Int = morningResumeHour,
        eligibleSlotBudget: Int = defaultEligibleSlotBudget
    ) async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        guard granted else { return }

        await cancelAllScheduled(center: center)

        let cursor = startOfNextClockHour(from: Date())
        try await enqueueHourlySlots(
            startingAt: cursor,
            eligibleSlotBudget: eligibleSlotBudget,
            quietChoice: quietChoice,
            wakeHour: wakeHour,
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

    private static func clampedWakeHour(_ wakeHour: Int) -> Int {
        min(max(wakeHour, 0), 23)
    }

    private static func pendingRequests(in center: UNUserNotificationCenter) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
    }

    /// **Strictly after** now — next `:00`.
    private static func startOfNextClockHour(from date: Date) -> Date {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .hour, for: date) else {
            return date.addingTimeInterval(3600)
        }
        return interval.end
    }

    private static func enqueueHourlySlots(
        startingAt firstFire: Date,
        eligibleSlotBudget: Int,
        quietChoice: QuietStopChoice,
        wakeHour: Int,
        center: UNUserNotificationCenter
    ) async throws {

        guard eligibleSlotBudget > 0 else { return }

        let calendar = Calendar.current
        var fireDate = firstFire
        var added = 0
        var probes = 0
        let safetyCap = max(eligibleSlotBudget * 12, eligibleSlotBudget + 200)

        while added < eligibleSlotBudget && probes < safetyCap {
            probes += 1

            let hour = calendar.component(.hour, from: fireDate)

            if quietChoice.allowsFire(atHour: hour, wakeHour: wakeHour) {
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
                added += 1
            }

            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: fireDate) else {
                fireDate = fireDate.addingTimeInterval(3600)
                continue
            }
            fireDate = nextHour
        }
    }
}
