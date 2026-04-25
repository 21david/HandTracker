import SwiftUI

@main
struct HandTrackMacApp: App {
    @StateObject private var store = HandTrackStore()

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 900, height: 760)
    }
}
