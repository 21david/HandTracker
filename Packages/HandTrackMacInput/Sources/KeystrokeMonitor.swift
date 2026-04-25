#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

enum KeystrokeMonitorStatus {
    case global
    case localFallback(reason: String)
    case stopped(reason: String)
}

private struct KeystrokeMonitorError: Error {
    let message: String
}

final class KeystrokeMonitor {
    var onKeystroke: (() -> Void)?

    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isMonitoring: Bool {
        localMonitor != nil || eventTap != nil
    }

    func start() -> KeystrokeMonitorStatus {
        guard !isMonitoring else {
            return eventTap == nil ? .localFallback(reason: "already using local fallback") : .global
        }

        switch startGlobalEventTap() {
        case .success:
            return .global
        case .failure(let firstFailure):
            if CGRequestListenEventAccess() {
                switch startGlobalEventTap() {
                case .success:
                    return .global
                case .failure(let secondFailure):
                    startLocalFallback()
                    return isMonitoring
                        ? .localFallback(reason: secondFailure.message)
                        : .stopped(reason: secondFailure.message)
                }
            }

            startLocalFallback()
            return isMonitoring
                ? .localFallback(reason: firstFailure.message)
                : .stopped(reason: firstFailure.message)
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startGlobalEventTap() -> Result<Void, KeystrokeMonitorError> {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown {
                let monitor = Unmanaged<KeystrokeMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                monitor.onKeystroke?()
            }

            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let tapLocations: [CGEventTapLocation] = [
            .cgSessionEventTap,
            .cgAnnotatedSessionEventTap,
            .cghidEventTap
        ]

        var tap: CFMachPort?
        for tapLocation in tapLocations {
            tap = CGEvent.tapCreate(
                tap: tapLocation,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: refcon
            )

            if tap != nil {
                break
            }
        }

        guard let tap else {
            let permissionState = CGPreflightListenEventAccess() ? "granted" : "not granted"
            return .failure(KeystrokeMonitorError(message: "macOS denied the global event tap; Input Monitoring is \(permissionState)"))
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .failure(KeystrokeMonitorError(message: "could not attach the event tap to the main run loop"))
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return .success(())
    }

    private func startLocalFallback() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.onKeystroke?()
            return event
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        localMonitor = nil
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }
}
#endif
