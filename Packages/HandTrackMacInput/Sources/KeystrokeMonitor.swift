#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

final class KeystrokeMonitor {
    var onKeystroke: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    var isMonitoring: Bool {
        localMonitor != nil || globalMonitor != nil
    }

    func start() -> Bool {
        guard !isMonitoring else { return true }

        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.onKeystroke?()
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.onKeystroke?()
        }

        return isMonitoring
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        localMonitor = nil
        globalMonitor = nil
    }

    deinit {
        stop()
    }
}
#endif
