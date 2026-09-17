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
                let was = Self.isScrolling
                Self.isScrolling = true
                guard !was else { return }
                // #region agent log
                MacAgentDebugLog.log(
                    hypothesisId: "P3",
                    location: "MacDashboardScrollGate.swift",
                    message: "scroll_start",
                    data: ["runId": "perf-responsive"]
                )
                // #endregion
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
                    // #region agent log
                    MacAgentDebugLog.log(
                        hypothesisId: "P3",
                        location: "MacDashboardScrollGate.swift",
                        message: "scroll_end",
                        data: ["runId": "perf-responsive"]
                    )
                    // #endregion
                }
                Self.endWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }
        // #region agent log
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MacAgentDebugLog.log(
                hypothesisId: "P5",
                location: "MacDashboardScrollGate.swift",
                message: "did_become_active",
                data: ["runId": "perf-responsive"]
            )
        }
        // #endregion
    }
}
