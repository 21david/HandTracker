#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

final class KeystrokeMonitor {
    var onKeystroke: (() -> Void)?
    var onMouseClick: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isMonitoring: Bool {
        eventTap != nil
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
        )
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<KeystrokeMonitor>
                .fromOpaque(refcon)
                .takeUnretainedValue()

            switch type {
            case .keyDown:
                monitor.onKeystroke?()
            case .leftMouseDown:
                monitor.onMouseClick?()
            default:
                break
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
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
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
