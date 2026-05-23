import SwiftUI

@main
struct HandTrackMacApp: App {
    @StateObject private var store = HandTrackStore()

    init() {
        print("HandTrackMacApp init")
    }
    
    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(store)
        }
    }
}
