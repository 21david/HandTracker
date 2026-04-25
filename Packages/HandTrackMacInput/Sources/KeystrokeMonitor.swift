#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

enum KeystrokeMonitorStatus {
    case global
    case localFallback
    case stopped
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
            return eventTap == nil ? .localFallback : .global
        }

        if startGlobalEventTap() {
            return .global
        }

        if CGRequestListenEventAccess(), startGlobalEventTap() {
            return .global
        }

        startLocalFallback()
        return isMonitoring ? .localFallback : .stopped
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startGlobalEventTap() -> Bool {
        guard CGPreflightListenEventAccess() else { return false }

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
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
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
