import Foundation
import UserNotifications

/// Schedules recurring check-in alerts each clock hour (device local calendar).
enum HourlyReminderManager {

    /// Minute past each clock hour reminders fire (**0** = top of hour: 1:00, 2:00, … local time).
    static let reminderMinuteWithinHour = 0

    /// AppStorage fallback when migrating or corrupted values (`HandTrack.hourlyReminderMorningStartHour`).
    static let fallbackMorningStartHour = 9

    /// “Reminders start” chip hours, **chronological** (shown in UI order).
    static let reminderMorningStartChoices: [Int] = [8, 9, 10, 11]

    /// User-facing `AppStorage` stores the hour literal **8 … 11**; invalid values clamp to **`fallbackMorningStartHour`**.
    static func clampedMorningStartHour(_ stored: Int) -> Int {
        if reminderMorningStartChoices.contains(stored) { return stored }
        return fallbackMorningStartHour
    }

    private static let canonicalIdentifierPrefix = "hourly-hand-slot-"
    /// Old diagnostic bursts used this prefix — **pending** ones survive app updates until removed.
    private static let legacyDiagnosticIdentifierPrefix = "diagnostic-hand-slot-"

    /// How many **eligible** hourly slots to enqueue when building a rolling window (skipped quiet hours aren’t billed).
    private static let defaultEligibleSlotBudget = 168

    /// iOS persists at most **64** local notification requests — stay under that so alarms aren’t dropped.
    private static let maxPendingCanonicalNotifications = 56

    /// When canonical HandTrack hourly requests fall below this, rebuild the horizon (typically after burns + app foreground).
    private static let replenishWhenCanonicalCountFallsBelow = 44

    enum QuietStopChoice: Int, CaseIterable, Identifiable {

        case tenPM = 0
        case elevenPM = 1
        case twelveAM = 2
        case oneAM = 3

        var id: Int { rawValue }

        var pickerTitle: String {
            switch self {
            case .tenPM: return "10 PM"
            case .elevenPM: return "11 PM"
            case .twelveAM: return "12 AM"
            case .oneAM: return "1 AM"
            }
        }

        /// Clock **hour** of the scheduled reminder (local). `wakeHour` is earliest allowed reminder hour (**Reminders start**).
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

    @discardableResult
    static func requestAuthorizationForAlerts() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    @discardableResult
    static func requestPermissionAndSchedule(
        quietChoice: QuietStopChoice = .elevenPM,
        wakeHour: Int = fallbackMorningStartHour,
        eligibleSlotBudget: Int = defaultEligibleSlotBudget
    ) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = try await requestAuthorizationForAlerts()
        guard granted else { return false }

        try await rescheduleAllHourlySlots(
            quietChoice: quietChoice,
            wakeHour: wakeHour,
            eligibleSlotBudget: eligibleSlotBudget,
            center: center
        )
        return true
    }

    /// Rebuilds hourly slots from the **next** `:minute` occurrence after now, honoring quiet‑hour rules.
    static func rescheduleAllHourlySlots(
        quietChoice: QuietStopChoice = .elevenPM,
        wakeHour: Int = fallbackMorningStartHour,
        eligibleSlotBudget: Int = defaultEligibleSlotBudget,
        center: UNUserNotificationCenter = .current()
    ) async throws {
        let settings = await center.notificationSettings()
        guard settings.permitsEnqueueingLocalNotifications else { return }

        await cancelLegacyDiagnosticNotifications(center: center)
        await cancelPendingMatching(prefix: canonicalIdentifierPrefix, center: center)

        let cursor = startOfNextFireOnMinuteWithinHour(from: Date(), minute: reminderMinuteWithinHour)
        try await enqueueHourlySlots(
            startingAt: cursor,
            eligibleSlotBudget: eligibleSlotBudget,
            quietChoice: quietChoice,
            wakeHour: wakeHour,
            center: center
        )
    }

    static func cancelAllScheduled(center: UNUserNotificationCenter = .current()) async {
        await cancelLegacyDiagnosticNotifications(center: center)
        await cancelPendingMatching(prefix: canonicalIdentifierPrefix, center: center)
    }

    /// Drops abandoned **diagnostic** notification requests from older installs (never recreated by current code).
    static func cancelLegacyDiagnosticNotifications(center: UNUserNotificationCenter = .current()) async {
        await cancelPendingMatching(prefix: legacyDiagnosticIdentifierPrefix, center: center)
    }

    static func hasScheduledHourlyReminders(center: UNUserNotificationCenter = .current()) async -> Bool {
        let requests = await pendingRequests(in: center)
        return requests.contains { $0.identifier.hasPrefix(canonicalIdentifierPrefix) }
    }

    /// Earliest pending canonical reminder fire (`nil` if none or trigger has no predictable next date).
    static func nextScheduledCanonicalReminderDate(center: UNUserNotificationCenter = .current()) async -> Date? {
        let requests = await pendingRequests(in: center)
        let dates: [Date] = requests.compactMap { req in
            guard req.identifier.hasPrefix(canonicalIdentifierPrefix) else { return nil }
            guard let trigger = req.trigger else { return nil }
            if let cal = trigger as? UNCalendarNotificationTrigger {
                return cal.nextTriggerDate()
            }
            if let interval = trigger as? UNTimeIntervalNotificationTrigger {
                return interval.nextTriggerDate()
            }
            return nil
        }
        return dates.min()
    }

    static func replenishRollingIfDesired(
        quietChoice: QuietStopChoice = .elevenPM,
        wakeHour: Int = fallbackMorningStartHour,
        userWantsNotifications: Bool,
        center: UNUserNotificationCenter = .current()
    ) async throws {
        guard userWantsNotifications else { return }
        let settings = await center.notificationSettings()
        guard settings.permitsEnqueueingLocalNotifications else { return }

        let requests = await pendingRequests(in: center)
        let canonical = requests.filter { $0.identifier.hasPrefix(canonicalIdentifierPrefix) }
        guard canonical.count < replenishWhenCanonicalCountFallsBelow else { return }

        try await rescheduleAllHourlySlots(
            quietChoice: quietChoice,
            wakeHour: wakeHour,
            eligibleSlotBudget: defaultEligibleSlotBudget,
            center: center
        )
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

    private static func cancelPendingMatching(prefix: String, center: UNUserNotificationCenter) async {
        let requests = await pendingRequests(in: center)
        let stale = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !stale.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: stale)
    }

    /// **Strictly after** `date` — next fire at `:mark` past that clock hour (**0** = top of hour).
    private static func startOfNextFireOnMinuteWithinHour(from date: Date, minute mark: Int) -> Date {
        let calendar = Calendar.current
        let clampedMinute = min(59, max(0, mark))
        var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        comps.minute = clampedMinute
        comps.second = 0
        guard var candidate = calendar.date(from: comps) else {
            return date.addingTimeInterval(3600)
        }
        if candidate <= date {
            candidate = calendar.date(byAdding: .hour, value: 1, to: candidate) ?? candidate.addingTimeInterval(3600)
        }
        return candidate
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
        let slotLimit = min(eligibleSlotBudget, maxPendingCanonicalNotifications)
        var fireDate = firstFire
        var added = 0
        var probes = 0
        let safetyCap = max(slotLimit * 12, slotLimit + 200)

        while added < slotLimit && probes < safetyCap {
            probes += 1

            let hour = calendar.component(.hour, from: fireDate)

            if quietChoice.allowsFire(atHour: hour, wakeHour: wakeHour) {
                var comps = calendar.dateComponents([.year, .month, .day, .hour], from: fireDate)
                comps.minute = min(59, max(0, reminderMinuteWithinHour))
                comps.second = 0
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

extension UNNotificationSettings {

    var permitsEnqueueingLocalNotifications: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        case .denied, .notDetermined:
            false
        @unknown default:
            false
        }
    }
}
