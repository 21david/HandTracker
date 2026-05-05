import SwiftUI
import UIKit
import UserNotifications

final class HandTrackAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            await HourlyReminderManager.cancelLegacyDiagnosticNotifications()
        }
        return true
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

@main
struct HandTrackiOSApp: App {
    @UIApplicationDelegateAdaptor(HandTrackAppDelegate.self) private var appDelegate
    @StateObject private var store = HandTrackStore()

    var body: some Scene {
        WindowGroup {
            iOSContentView()
                .environmentObject(store)
        }
    }
}
