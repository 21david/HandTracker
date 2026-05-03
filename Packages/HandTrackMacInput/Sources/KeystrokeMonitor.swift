#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// Tracks input via a listen-only session event tap (events are not consumed or delayed for other apps).
/// Keystrokes/clicks schedule light MainActor work; pointer travel only does a lock + float add per event,
/// then one batched callback ~4×/s, so typical CPU impact is small compared to high tracking rate games.
final class KeystrokeMonitor {
    private static let flushInterval: TimeInterval = 0.25

    var onKeystroke: (() -> Void)?
    var onMouseClick: (() -> Void)?
    /// Buffered planar pointer travel in points/pixels (~0.25s batches).
    var onBufferedTravelPixels: ((Double) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let travelLock = NSLock()
    private var bufferedTravelPixels: Double = 0
    private var flushTimer: Timer?

    var isMonitoring: Bool {
        eventTap != nil
    }

    func start() {
        guard eventTap == nil else { return }

        let monitoredTypes: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        let mask: CGEventMask = monitoredTypes.reduce(0 as CGEventMask) { accumulator, kind in
            accumulator | CGEventMask(1 << kind.rawValue)
        }
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
            case .mouseMoved,
                 .leftMouseDragged,
                 .rightMouseDragged,
                 .otherMouseDragged:
                monitor.accumulateTravelPixels(from: event)
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

        scheduleFlushTimer()
    }

    func stop() {
        cancelFlushTimer()
        flushTravelBufferIfNeeded()

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

    private static func planarTravelIncrement(from event: CGEvent) -> Double {
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance > 0 else { return 0 }
        return distance
    }

    private func accumulateTravelPixels(from event: CGEvent) {
        let increment = Self.planarTravelIncrement(from: event)
        guard increment > 0 else { return }
        travelLock.lock()
        bufferedTravelPixels += increment
        travelLock.unlock()
    }

    private func flushTravelBufferIfNeeded() {
        travelLock.lock()
        let pending = bufferedTravelPixels
        bufferedTravelPixels = 0
        travelLock.unlock()
        guard pending > 0 else { return }
        onBufferedTravelPixels?(pending)
    }

    private func scheduleFlushTimer() {
        cancelFlushTimer()
        let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.flushTravelBufferIfNeeded()
        }
        RunLoop.current.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func cancelFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }
}
#endif
