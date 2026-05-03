import Foundation
import UserNotifications

enum HourlyReminderManager {
    static func requestPermissionAndSchedule() async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        guard granted else { return }

        center.removePendingNotificationRequests(withIdentifiers: ["hourly-hand-log"])

        let content = UNMutableNotificationContent()
        content.title = "Hand Helper check-in"
        content.body = "Log your pain level, hand-use minutes, and notes for this hour."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: true)
        let request = UNNotificationRequest(
            identifier: "hourly-hand-log",
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }
}
