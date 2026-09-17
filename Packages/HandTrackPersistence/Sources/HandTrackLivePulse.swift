import Foundation
import Observation

/// Fine-grained live-input signals for five-minute charts.
/// Uses ``Observation`` so only charts that read a given field invalidate
/// (unlike ``ObservableObject``, where any `@Published` bump refreshes every observer).
@MainActor
@Observable
final class HandTrackLivePulse {
    var keystrokes: UInt64 = 0
    var mouseClicks: UInt64 = 0
    var mouseTravel: UInt64 = 0
    var scrollBumps: UInt64 = 0
    var builtinKeystrokes: UInt64 = 0
    var builtinTrackpadClicks: UInt64 = 0
    var builtinTrackpadTravel: UInt64 = 0
    var builtinTrackpadScroll: UInt64 = 0
    /// Summary tiles read this once per deferred flush.
    var summary: UInt64 = 0
    /// Cap expensive summary recomputes (full-array day/hour scans) while charts still pulse.
    private var lastSummaryBumpAt: CFAbsoluteTime = 0
    private static let summaryMinInterval: CFAbsoluteTime = 1.0

    enum Kind: Hashable {
        case keystrokes
        case mouseClicks
        case mouseTravel
        case scrollBumps
        case builtinKeystrokes
        case builtinTrackpadClicks
        case builtinTrackpadTravel
        case builtinTrackpadScroll
    }

    func bump(_ kind: Kind) {
        switch kind {
        case .keystrokes: keystrokes &+= 1
        case .mouseClicks: mouseClicks &+= 1
        case .mouseTravel: mouseTravel &+= 1
        case .scrollBumps: scrollBumps &+= 1
        case .builtinKeystrokes: builtinKeystrokes &+= 1
        case .builtinTrackpadClicks: builtinTrackpadClicks &+= 1
        case .builtinTrackpadTravel: builtinTrackpadTravel &+= 1
        case .builtinTrackpadScroll: builtinTrackpadScroll &+= 1
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastSummaryBumpAt >= Self.summaryMinInterval {
            lastSummaryBumpAt = now
            summary &+= 1
        }
    }

    // MARK: - Graphs debug panel (for debugging/testing — deletable)

    /// Immediate per-event signal (not coalesced) for the graphs debug overlay.
    struct DebugTick: Equatable {
        var kind: Kind
        var amount: Double
        var id: UInt64
    }

    /// Set while the debug panel is open. `noteDebug` is a no-op otherwise (avoids main-thread churn).
    static var debugPanelActive = false

    /// Monotonic id; debug UI observes this to flash tiles on every raw input.
    private(set) var debugTickID: UInt64 = 0
    private(set) var lastDebugTick: DebugTick?

    /// Call from each `record*` path so debug flashes track every keystroke/click, not coalesced UI publishes.
    func noteDebug(_ kind: Kind, amount: Double = 1) {
        guard Self.debugPanelActive, amount.isFinite, amount > 0 else { return }
        debugTickID &+= 1
        lastDebugTick = DebugTick(kind: kind, amount: amount, id: debugTickID)
    }
}
