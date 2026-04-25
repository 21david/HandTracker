#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum KeystrokeMonitorStatus {
    case eventTap
    case globalMonitor(reason: String)
    case stopped(reason: String)
}

final class KeystrokeMonitor {
    var onKeystroke: (() -> Void)?

    private var eventTap: CFMachPort?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var runLoopSource: CFRunLoopSource?

    var isMonitoring: Bool {
        eventTap != nil || globalMonitor != nil || localMonitor != nil
    }

    func start() -> KeystrokeMonitorStatus {
        guard !isMonitoring else {
            return eventTap == nil
                ? .globalMonitor(reason: "already using NSEvent monitor")
                : .eventTap
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
            return startNSEventMonitors(reason: "event tap denied")
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
        return .eventTap
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startNSEventMonitors(reason: String) -> KeystrokeMonitorStatus {
        let accessibilityTrusted = requestAccessibilityAccess()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.onKeystroke?()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.onKeystroke?()
            return event
        }

        guard isMonitoring else {
            return .stopped(reason: "\(reason); could not install NSEvent monitors")
        }

        if accessibilityTrusted {
            return .globalMonitor(reason: "\(reason); using Accessibility monitor")
        }

        return .globalMonitor(reason: "\(reason); grant Accessibility if keys outside this app are not counted")
    }

    private func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }

        eventTap = nil
        globalMonitor = nil
        localMonitor = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }
}
#endif
