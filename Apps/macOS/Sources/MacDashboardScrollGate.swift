import AppKit
import Foundation

/// Tracks live scrolling inside HandTrack so chart UI can pause and not fight the ScrollView.
@MainActor
enum MacDashboardScrollGate {
    private(set) static var isScrolling = false
    private static var endWorkItem: DispatchWorkItem?
    private static var installed = false

    static var shouldDeferLiveUI: Bool { isScrolling }

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Self.endWorkItem?.cancel()
                Self.isScrolling = true
            }
        }
        center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Self.endWorkItem?.cancel()
                let work = DispatchWorkItem {
                    Self.isScrolling = false
                }
                Self.endWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }
    }
}
