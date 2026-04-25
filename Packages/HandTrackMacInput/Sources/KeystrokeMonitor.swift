#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

enum KeystrokeMonitorStatus {
    case global
    case stopped(reason: String)
}

final class KeystrokeMonitor {
    var onKeystroke: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isMonitoring: Bool {
        eventTap != nil
    }

    func start() -> KeystrokeMonitorStatus {
        guard !isMonitoring else {
            return .global
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .keyDown,
                  let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<KeystrokeMonitor>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            monitor.onKeystroke?()
            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            openInputMonitoringSettings()
            return .stopped(reason: "macOS denied the global event tap")
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let runLoopSource else {
            CFMachPortInvalidate(tap)
            eventTap = nil
            return .stopped(reason: "could not attach the event tap to the run loop")
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return .global
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }
}
#endif
