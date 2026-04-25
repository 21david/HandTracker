import SwiftUI

@main
struct HandTrackiOSApp: App {
    @StateObject private var store = HandTrackStore()

    var body: some Scene {
        WindowGroup {
            iOSContentView()
                .environmentObject(store)
        }
    }
}
