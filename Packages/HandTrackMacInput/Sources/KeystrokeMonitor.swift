#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// Tracks input via a listen-only session event tap (events are not consumed or delayed for other apps).
/// Keystrokes/clicks schedule light MainActor work; pointer travel only does a lock + float add per event,
/// then one batched callback ~4×/s, so typical CPU impact is small compared to high tracking rate games.
final class KeystrokeMonitor {
    private static let flushInterval: TimeInterval = 0.25
    /// Drop the duplicate companion CGEvent for the same notch; keeps single-notch ≈ 1.
    /// Fast multi-notch flicks may under-count — accepted tradeoff vs double-counting.
    private static let scrollDuplicateWindow: CFTimeInterval = 0.05
    private static let scrollDuplicateWindowNs: CGEventTimestamp = 50_000_000
    /// Trackpad / Magic Mouse: about this many scroll points ⇒ 1 bump.
    private static let trackpadPointsPerBump: Double = 14

    var onKeystroke: (() -> Void)?
    var onMouseClick: (() -> Void)?
    /// Discrete scroll-wheel / trackpad scroll bumps (notches or quantized deltas).
    var onScrollBumps: ((Int) -> Void)?
    /// Buffered planar pointer travel in points/pixels (~0.25s batches).
    var onBufferedTravelPixels: ((Double) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let travelLock = NSLock()
    private var bufferedTravelPixels: Double = 0
    private var flushTimer: Timer?

    private let scrollLock = NSLock()
    private var lastScrollBumpMediaTime: CFTimeInterval = 0
    private var lastScrollEventTimestamp: CGEventTimestamp = 0
    private var trackpadPointAccumulator: Double = 0

    var isMonitoring: Bool {
        eventTap != nil
    }

    func start() {
        guard eventTap == nil else { return }

        let monitoredTypes: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .scrollWheel,
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
            case .scrollWheel:
                let bumps = monitor.takeScrollBumps(from: event)
                if bumps > 0 {
                    monitor.onScrollBumps?(bumps)
                }
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

    /// Convert one `scrollWheel` CGEvent into 0…N bumps.
    ///
    /// Important: macOS often reports **one wheel notch as line delta ≈ 10–14**, not ±1.
    /// Never use the raw line magnitude as the bump count — that turns 1 notch into ~10.
    ///
    /// - Discrete mouse wheel: **1 bump per accepted event** (line delta present).
    ///   A ~50ms window drops the duplicate companion event for the *same* notch.
    /// - Trackpad / Magic Mouse: accumulate point deltas into bumps across the gesture.
    private func takeScrollBumps(from event: CGEvent) -> Int {
        scrollLock.lock()
        defer { scrollLock.unlock() }

        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if momentum != 0 { return 0 }

        let phase = NSEvent.Phase(rawValue: UInt(event.getIntegerValueField(.scrollWheelEventScrollPhase)))
        if phase.contains(.ended) || phase.contains(.cancelled) {
            trackpadPointAccumulator = 0
            return 0
        }
        if phase.contains(.stationary) { return 0 }

        let line1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let point1 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let point2 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let hasLine = line1 != 0 || line2 != 0

        if isContinuous {
            // Prefer point-stream quantization. If a device only reports line ticks, count
            // each tick as **1** (never abs(line) — that over-counts by ~10×).
            if hasLine {
                guard !isDuplicateScrollEvent(event) else { return 0 }
                markScrollEventAccepted(event)
                return 1
            }
            let points = (point1.isFinite ? abs(point1) : 0) + (point2.isFinite ? abs(point2) : 0)
            guard points > 0.5 else { return 0 }
            trackpadPointAccumulator += points
            let bumps = Int(trackpadPointAccumulator / Self.trackpadPointsPerBump)
            if bumps > 0 {
                trackpadPointAccumulator -= Double(bumps) * Self.trackpadPointsPerBump
                return min(bumps, 8)
            }
            return 0
        }

        // Discrete wheel: any non-zero line delta = one notch (ignore pixel-only companions).
        guard hasLine else { return 0 }
        if phase.contains(.changed) { return 0 }
        if isDuplicateScrollEvent(event) { return 0 }
        markScrollEventAccepted(event)
        return 1
    }

    private func isDuplicateScrollEvent(_ event: CGEvent) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastScrollBumpMediaTime < Self.scrollDuplicateWindow {
            return true
        }
        let ts = event.timestamp
        if lastScrollEventTimestamp != 0, ts >= lastScrollEventTimestamp {
            let deltaNs = ts - lastScrollEventTimestamp
            if deltaNs < Self.scrollDuplicateWindowNs {
                return true
            }
        }
        return false
    }

    private func markScrollEventAccepted(_ event: CGEvent) {
        lastScrollBumpMediaTime = CFAbsoluteTimeGetCurrent()
        lastScrollEventTimestamp = event.timestamp
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
