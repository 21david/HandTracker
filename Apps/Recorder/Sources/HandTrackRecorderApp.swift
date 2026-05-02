import SwiftUI

@main
struct HandTrackRecorderApp: App {
    @StateObject private var store = HandTrackStore()

    var body: some Scene {
        WindowGroup {
            RecorderContentView()
                .environmentObject(store)
        }
    }
}
