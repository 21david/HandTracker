#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

// Owns the low-level macOS keyboard listener.
// This class is intentionally small because the event tap is fragile:
// any expensive work should happen outside this callback path.
final class KeystrokeMonitor {
    // Called once for each key-down event that macOS delivers to the event tap.
    // The monitor does not know about storage or UI; callers decide what to do.
    var onKeystroke: (() -> Void)?

    // CFMachPort representing the active event tap. If this is nil, global key capture is not running.
    private var eventTap: CFMachPort?

    // Run-loop source that keeps the event tap alive on the current run loop.
    private var runLoopSource: CFRunLoopSource?

    // Simple status check used by the app to avoid installing duplicate event taps.
    var isMonitoring: Bool {
        eventTap != nil
    }

    // Starts global key monitoring.
    // Important: this listens only; it does not modify or block keyboard events.
    func start() {
        // Avoid creating two event taps for the same app instance.
        guard eventTap == nil else { return }

        // Tell CoreGraphics we only care about key-down events.
        // This keeps the callback from receiving every mouse/scroll/keyboard event.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        // CoreGraphics calls this closure outside normal SwiftUI event handling.
        // Keep it lightweight and immediately hand off to `onKeystroke`.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .keyDown,
                  let refcon else {
                // Return the original event so the system/app receiving the key press is unaffected.
                return Unmanaged.passUnretained(event)
            }

            // `refcon` is the `KeystrokeMonitor` instance passed into `tapCreate` below.
            // We use it to get back to Swift object state from the C callback.
            let monitor = Unmanaged<KeystrokeMonitor>
                .fromOpaque(refcon)
                .takeUnretainedValue()

            // This should stay cheap. Heavy persistence/aggregation here can make capture unreliable.
            monitor.onKeystroke?()

            // The tap is listen-only, but returning the event is still required by the callback contract.
            return Unmanaged.passUnretained(event)
        }

        // Pass this object into the C callback so the callback can call `onKeystroke`.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Install a session-level, listen-only event tap.
        // If macOS denies this, Input Monitoring permission is usually missing/stale.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            // Open the relevant permission pane as a recovery path for denied taps.
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            return
        }

        eventTap = tap

        // Convert the event tap into a run-loop source so macOS can deliver events to it.
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource {
            // Attach to common modes so the tap keeps receiving keys during normal UI interactions.
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

            // The tap is not active until explicitly enabled.
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // Stops key monitoring and detaches the event tap from the run loop.
    // This is called when the Mac dashboard disappears and from `deinit`.
    func stop() {
        if let eventTap {
            // Disable first so macOS stops delivering callbacks before we remove references.
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource {
            // Remove the source that was added in `start`.
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }

        // Clear both references so a future `start` can install a fresh tap.
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        // Defensive cleanup if the monitor is deallocated while still active.
        stop()
    }
}
#endif
