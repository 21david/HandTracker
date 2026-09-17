import SwiftUI

@main
struct HandTrackMacApp: App {
    @StateObject private var store = HandTrackStore()

    init() {
        print("HandTrackMacApp init")
        DispatchQueue.main.async {
            MacDashboardScrollGate.installIfNeeded()
            HandTrackStore.shouldDeferLiveUIFlush = {
                MacDashboardScrollGate.isScrolling
            }
            // #region agent log
            MacUnhandledKeystrokeBeepProbe.startIfNeeded()
            // #endregion
        }
    }
    
    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(store)
                .environment(store.livePulse)
        }
    }
}
