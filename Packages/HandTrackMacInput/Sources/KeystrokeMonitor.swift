#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

/// Tracks input via a listen-only session event tap (events are not consumed or delayed for other apps).
/// Keystrokes/clicks schedule light MainActor work; pointer travel only does a lock + float add per event,
/// then one batched callback ~4×/s, so typical CPU impact is small compared to high tracking rate games.
///
/// Keyboard separation: prefer IOHID `Built-In` when the device is not seized. With Karabiner (or anything
/// that exclusively grabs keyboards), fall back to CGEvent `keyboardEventKeyboardType` learned while no
/// external keyboard is connected. Trackpad scroll: continuous/precise events, plus suppress the discrete
/// companion line-scroll CGEvent that macOS emits alongside two-finger scrolls.
final class KeystrokeMonitor {
    private static let flushInterval: TimeInterval = 0.12
    /// Drop the duplicate companion CGEvent for the same notch; keeps single-notch ≈ 1.
    private static let scrollDuplicateWindow: CFTimeInterval = 0.05
    private static let scrollDuplicateWindowNs: CGEventTimestamp = 50_000_000
    /// Built-in MacBook trackpad pointer events use NX_SUBTYPE_MOUSE_TOUCH.
    private static let trackpadTouchSubtype: Int64 = 3
    /// After a phased trackpad scroll, ignore discrete companion “wheel” events.
    private static let trackpadScrollCompanionWindow: CFTimeInterval = 0.08
    /// Content-scroll deltas are smaller than one-finger pointer travel for the same pad
    /// stroke (~750–800 vs ~2–3k). Scale so two-finger scroll effort matches travel pixels.
    private static let trackpadScrollTravelScale: Double = 3.0
    /// Quantize continuous mouse pixel-only wheel streams into notches (G502-style).
    private static let mouseScrollPointsPerBump: Double = 14
    /// If the trackpad gesture latch is older than this with no contact, treat continuous
    /// scroll as mouse again (prevents a stuck latch from killing external wheel forever).
    private static let staleTrackpadGestureLatch: CFTimeInterval = 0.35
    /// When Karabiner is present, wait briefly so physical-device IOHID can claim the key
    /// before the virtual CGEvent is classified (DriverKit often still delivers HID).
    private static let karabinerHIDClassifyDelay: TimeInterval = 0.012
    private static let builtinHIDClaimWindow: CFTimeInterval = 0.12
    private static let externalHIDClaimWindow: CFTimeInterval = 0.12
    private static let keyboardInventoryRefreshInterval: CFTimeInterval = 2.0
    private static let learnedBuiltinKeyboardTypesKey = "HandTrack.learnedBuiltinKeyboardTypes"

    var onKeystroke: (() -> Void)?
    /// Fired with the same external key as ``onKeystroke``, plus a stable device identity.
    /// Built-in keystrokes never go through this callback.
    var onExternalKeyboardKeystroke: ((ExternalKeyboardIdentity) -> Void)?
    /// Connected plug-in boards (not MacBook / Karabiner / mouse receivers).
    var onExternalKeyboardInventory: (([ExternalKeyboardIdentity]) -> Void)?
    var onMouseClick: (() -> Void)?
    /// Discrete mouse-wheel notches.
    var onScrollBumps: ((Int) -> Void)?
    /// Buffered planar pointer travel in points/pixels (~0.25s batches).
    var onBufferedTravelPixels: ((Double) -> Void)?
    var onBuiltinKeystroke: (() -> Void)?
    var onBuiltinTrackpadClick: (() -> Void)?
    var onBufferedBuiltinTrackpadTravelPixels: ((Double) -> Void)?
    var onBufferedBuiltinTrackpadScrollPixels: ((Double) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let tapLifecycleLock = NSLock()
    private var hidManager: IOHIDManager?
    private var hidOpenSucceeded = false
    /// Per-device IOHID observers when Karabiner is not seizing the boards.
    private var physicalHIDObservers: [IOHIDDevice] = []
    private var physicalHIDObserverServiceIDs: Set<UInt64> = []
    /// True after IOHIDDeviceOpen returns ExclusiveAccess (Karabiner seize).
    private var physicalHIDSeizedByKarabiner = false
    /// Registry IDs for physical boards (no open required) — matched to event-system sender IDs.
    private var builtinKeyboardRegistryIDs: Set<UInt64> = []
    private var externalKeyboardRegistryIDs: Set<UInt64> = []
    private var didAttemptKarabinerBuiltinRelease = false

    private let travelLock = NSLock()
    private var bufferedTravelPixels: Double = 0
    private let builtinTrackpadTravelLock = NSLock()
    private var bufferedBuiltinTrackpadTravelPixels: Double = 0
    private let builtinTrackpadScrollLock = NSLock()
    private var bufferedBuiltinTrackpadScrollPixels: Double = 0
    private var flushTimer: Timer?

    private let scrollLock = NSLock()
    private var lastScrollBumpMediaTime: CFTimeInterval = 0
    private var lastScrollEventTimestamp: CGEventTimestamp = 0
    private var lastTrackpadScrollAt: CFTimeInterval = 0
    /// True between trackpad scroll-phase began/mayBegin and ended/cancelled (incl. short gaps).
    private var trackpadScrollGestureActive = false
    /// Accumulates continuous mouse point deltas when the device reports no line ticks.
    private var mouseContinuousPointAccumulator: Double = 0
    // #region agent log
    private var debugGestureScrollPixelSum: Double = 0
    private var debugGestureScrollEventCount: Int = 0
    private var debugGestureMomentumSkippedSum: Double = 0
    private var debugGestureMomentumSkippedCount: Int = 0
    private var debugGestureLatchSkippedSum: Double = 0
    private var debugGestureLatchSkippedCount: Int = 0
    // #endregion

    private let keyboardLock = NSLock()
    private var lastBuiltinHIDKeyAt: CFAbsoluteTime = 0
    private var lastExternalHIDKeyAt: CFAbsoluteTime = 0
    private var lastExternalHIDIdentity: ExternalKeyboardIdentity?
    private var lastUsedExternalIdentity: ExternalKeyboardIdentity?
    private var connectedExternalIdentities: [ExternalKeyboardIdentity] = []
    private var connectedExternalTransports: [String: String] = [:]
    private var hasExternalKeyboardConnected = false
    /// Karabiner’s virtual keyboard collapses every physical keyboard to one CGEvent type
    /// (observed: 46), so learned-type matching must not run while it is present.
    private var hasKarabinerVirtualKeyboard = false
    private var lastKeyboardInventoryAt: CFAbsoluteTime = 0
    private var learnedBuiltinKeyboardTypes: Set<Int64>
    /// G Hub / Logitech injects G502 extra buttons as keyDown with this keyboard type
    /// (verified via debug session — not otherMouseDown).
    private static let logitechGHubInjectedKeyboardType: Int64 = 70
    /// Distinctive NX_EVENT high bit G Hub sets on synthetic keyDowns.
    /// Must NOT include `maskCommand` (0x0010_0000): MacBook Cmd+letter is also type 70 and
    /// would otherwise be miscounted as an external mouse click.
    private static let logitechGHubInjectedFlagMask: UInt64 = 0x2000_0000

    // #region agent log
    private static let debugLogPath = "/Users/david1/Documents/Code/Cursor/HandTrack/.cursor/debug-b2bfc5.log"
    private static let debugLogQueue = DispatchQueue(label: "HandTrack.debugScrollLog")
    private var debugTrackpadRouteLogCount = 0
    private var debugMouseRouteLogCount = 0
    private var debugKeyClassifyLogCount = 0
    private var debugKeyDecisionLogCount = 0
    private var debugHIDClaimLogCount = 0
    private var debugInventoryLogCount = 0
    private var debugOtherMouseLogCount = 0
    private var debugPendingMouseBumpSchedules = 0
    private var debugTapWindowStartedAt: CFAbsoluteTime = 0
    private var debugTapCallbackCount = 0
    private var debugTapMouseMoveCount = 0
    private var debugTapKeyCount = 0
    private var debugTapScrollCount = 0
    private var debugTapCallbackNanos: UInt64 = 0
    private var debugTapMainThreadCount = 0
    private var debugSessionHIDLogCount = 0
    private var debugSessionEmitLogCount = 0
    private var debugSessionResolveLogCount = 0
    private var debugSessionAttachLogCount = 0
    private var debugSessionCGFieldLogCount = 0
    // #endregion

    var isMonitoring: Bool {
        eventTap != nil
    }

    init() {
        let stored = UserDefaults.standard.array(forKey: Self.learnedBuiltinKeyboardTypesKey) as? [Int] ?? []
        learnedBuiltinKeyboardTypes = Set(stored.map { Int64($0) })
    }

    // #region agent log
    private func agentDebugLog(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:]
    ) {
        // Disabled after verified fix — keep call sites folded for now.
        _ = (hypothesisId, location, message, data)
    }

    private func sessionDebugLog(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:]
    ) {
        let path = "/Users/david1/Documents/Code/Cursor/HandTrack/.cursor/debug-869910.log"
        var payload: [String: Any] = [
            "sessionId": "869910",
            "runId": "pre-fix",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "data": data,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: json, encoding: .utf8)
        else { return }
        line.append("\n")
        Self.debugLogQueue.async {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path),
               let handle = try? FileHandle(forWritingTo: url)
            {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: false, encoding: .utf8)
            }
        }
    }
    // #endregion

    func start() {
        tapLifecycleLock.lock()
        let alreadyRunning = eventTap != nil || tapThread != nil
        tapLifecycleLock.unlock()
        guard !alreadyRunning else { return }

        // Run the listen-only tap off the main run loop. Profiling showed 300–500
        // mouse-move callbacks/sec on the UI thread, which starved chart updates.
        let thread = Thread { [weak self] in
            self?.installEventTapAndRun()
        }
        thread.name = "HandTrack.InputTap"
        thread.qualityOfService = .userInteractive
        tapLifecycleLock.lock()
        tapThread = thread
        tapLifecycleLock.unlock()
        thread.start()
    }

    private func installEventTapAndRun() {
        refreshKeyboardInventory(force: true)
        startBuiltinKeyboardHID()

        let monitoredTypes: [CGEventType] = [
            .keyDown,
            .flagsChanged,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
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

            // #region agent log
            let tapT0 = DispatchTime.now().uptimeNanoseconds
            // #endregion

            switch type {
            case .keyDown:
                monitor.handleKeyDown(event)
            case .flagsChanged:
                // Caps Lock / Shift / Control / Option / Command arrive here, not as keyDown.
                monitor.handleFlagsChanged(event)
            case .leftMouseDown:
                // Keep the working trackpad-click path unchanged (subtype 3).
                if monitor.isTrackpadTouchEvent(event) {
                    monitor.onBuiltinTrackpadClick?()
                } else {
                    monitor.onMouseClick?()
                }
            case .rightMouseDown:
                // #region agent log
                monitor.debugLogMouseButton(event: event, kind: "rightMouseDown")
                // #endregion
                if monitor.isTrackpadTouchEvent(event) {
                    monitor.onBuiltinTrackpadClick?()
                } else {
                    monitor.onMouseClick?()
                }
            case .otherMouseDown:
                // #region agent log
                monitor.debugLogMouseButton(event: event, kind: "otherMouseDown")
                // #endregion
                if monitor.isTrackpadTouchEvent(event) {
                    monitor.onBuiltinTrackpadClick?()
                } else {
                    monitor.onMouseClick?()
                }
            case .scrollWheel:
                monitor.handleScrollWheel(event)
            case .mouseMoved,
                 .leftMouseDragged,
                 .rightMouseDragged,
                 .otherMouseDragged:
                // Keep the working trackpad-travel path unchanged (subtype 3).
                if monitor.isTrackpadTouchEvent(event) {
                    monitor.accumulateBuiltinTrackpadTravelPixels(from: event)
                } else {
                    monitor.accumulateTravelPixels(from: event)
                }
            default:
                break
            }

            // #region agent log
            // Tap window sampling disabled — was competing with UI during lag tests.
            // monitor.debugTapSample(type: type, startedNanos: tapT0)
            _ = tapT0
            // #endregion
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
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }
            tapLifecycleLock.lock()
            tapThread = nil
            tapLifecycleLock.unlock()
            return
        }

        let loop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapLifecycleLock.lock()
        eventTap = tap
        runLoopSource = source
        tapRunLoop = loop
        tapLifecycleLock.unlock()

        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // #region agent log
        agentDebugLog(
            hypothesisId: "L1",
            location: "KeystrokeMonitor.start",
            message: "event_tap_started",
            data: [
                "runId": "post-fix-lag",
                "onMainThread": Thread.isMainThread,
                "thread": Thread.current.name ?? "unnamed",
            ]
        )
        // #endregion

        scheduleFlushTimer()
        CFRunLoopRun()
    }

    // #region agent log
    private func debugTapSample(type: CGEventType, startedNanos: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedNanos
        if debugTapWindowStartedAt == 0 {
            debugTapWindowStartedAt = CFAbsoluteTimeGetCurrent()
        }
        debugTapCallbackCount += 1
        debugTapCallbackNanos += elapsed
        if Thread.isMainThread { debugTapMainThreadCount += 1 }
        switch type {
        case .keyDown: debugTapKeyCount += 1
        case .scrollWheel: debugTapScrollCount += 1
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            debugTapMouseMoveCount += 1
        default: break
        }
        let window = CFAbsoluteTimeGetCurrent() - debugTapWindowStartedAt
        guard window >= 1.0 else { return }
        agentDebugLog(
            hypothesisId: "L1",
            location: "KeystrokeMonitor.eventTap",
            message: "tap_callback_window",
            data: [
                "runId": "post-fix-lag",
                "windowMs": Int(window * 1000),
                "callbacks": debugTapCallbackCount,
                "mouseMoves": debugTapMouseMoveCount,
                "keys": debugTapKeyCount,
                "scrolls": debugTapScrollCount,
                "mainThreadCallbacks": debugTapMainThreadCount,
                "totalCallbackMs": Int(debugTapCallbackNanos / 1_000_000),
                "avgCallbackUs": debugTapCallbackCount > 0
                    ? Int(debugTapCallbackNanos / UInt64(debugTapCallbackCount) / 1_000)
                    : 0,
            ]
        )
        debugTapWindowStartedAt = CFAbsoluteTimeGetCurrent()
        debugTapCallbackCount = 0
        debugTapMouseMoveCount = 0
        debugTapKeyCount = 0
        debugTapScrollCount = 0
        debugTapCallbackNanos = 0
        debugTapMainThreadCount = 0
    }
    // #endregion

    func stop() {
        tapLifecycleLock.lock()
        let tap = eventTap
        let source = runLoopSource
        let loop = tapRunLoop
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        tapLifecycleLock.unlock()

        cancelFlushTimer()
        flushBufferedPixelsIfNeeded()
        stopBuiltinKeyboardHID()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source, let loop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Keyboard

    /// Carbon/HI keycodes for modifier keys (left + right where applicable).
    private static let modifierKeycodes: Set<Int64> = [
        54, // Right Command
        55, // Left Command
        56, // Left Shift
        57, // Caps Lock
        58, // Left Option
        59, // Left Control
        60, // Right Shift
        61, // Right Option
        62, // Right Control
    ]
    private static let capsLockKeycode: Int64 = 57
    /// Tracks Shift/Ctrl/Opt/Cmd down state so we count presses only (not releases).
    /// Caps Lock is sticky and is handled separately (one flagsChanged per physical press).
    private var modifierKeysDown: Set<Int64> = []

    private func handleKeyDown(_ event: CGEvent) {
        refreshKeyboardInventory(force: false)
        let kbdType = event.getIntegerValueField(.keyboardEventKeyboardType)
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue

        // G Hub maps G502 extras to keyDown type 70 *with* synthetic flag bits.
        // MacBook keys (after Karabiner ignore) also use type 70 but flags==256 — must not count as clicks.
        if Self.isLogitechGHubInjectedKeystroke(kbdType: kbdType, flags: flags) {
            // #region agent log
            debugKeyDecisionLogCount += 1
            if debugKeyDecisionLogCount <= 12 {
                agentDebugLog(
                    hypothesisId: "D",
                    location: "KeystrokeMonitor.handleKeyDown.classify",
                    message: "decision_mouse_click_ghub",
                    data: ["kbdType": kbdType, "keycode": keycode, "flags": flags, "runId": "post-fix6"]
                )
            }
            // #endregion
            onMouseClick?()
            return
        }

        logCGEventIdentityFields(event, keycode: keycode, kbdType: kbdType)
        classifyAndRecordKeystroke(keycode: keycode, kbdType: kbdType, flags: flags)
    }

    /// Modifier keys never arrive as `.keyDown` — only `.flagsChanged`. Count each press 1:1.
    private func handleFlagsChanged(_ event: CGEvent) {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard Self.modifierKeycodes.contains(keycode) else { return }

        let isPress: Bool
        if keycode == Self.capsLockKeycode {
            // Sticky: one flagsChanged per physical press (on and off both count as a press).
            isPress = true
        } else {
            // L/R Shift/Ctrl/Opt/Cmd: alternate press/release per keycode.
            // Flag masks alone can't tell left from right when both are held.
            keyboardLock.lock()
            if modifierKeysDown.contains(keycode) {
                modifierKeysDown.remove(keycode)
                isPress = false
            } else {
                modifierKeysDown.insert(keycode)
                isPress = true
            }
            keyboardLock.unlock()
        }
        guard isPress else { return }

        refreshKeyboardInventory(force: false)
        let kbdType = event.getIntegerValueField(.keyboardEventKeyboardType)
        let flags = event.flags.rawValue
        classifyAndRecordKeystroke(keycode: keycode, kbdType: kbdType, flags: flags)
    }

    private func classifyAndRecordKeystroke(
        keycode: Int64,
        kbdType: Int64,
        flags: UInt64
    ) {
        keyboardLock.lock()
        let karabinerPresent = hasKarabinerVirtualKeyboard
        keyboardLock.unlock()

        let classify = { [weak self] in
            guard let self else { return }

            self.keyboardLock.lock()
            let now = CFAbsoluteTimeGetCurrent()
            let builtinHIDClaimed = now - self.lastBuiltinHIDKeyAt < Self.builtinHIDClaimWindow
            let externalHIDClaimed = now - self.lastExternalHIDKeyAt < Self.externalHIDClaimWindow
            let externalConnected = self.hasExternalKeyboardConnected
            let karabiner = self.hasKarabinerVirtualKeyboard
            let learned = self.learnedBuiltinKeyboardTypes
            let resolvedExternal = self.resolvedExternalIdentityAssumingLocked(now: now)
            let hidAge = now - self.lastExternalHIDKeyAt
            let hidId = self.lastExternalHIDIdentity?.id ?? ""
            let lastUsedId = self.lastUsedExternalIdentity?.id ?? ""
            let connectedIds = self.connectedExternalIdentities.map(\.id)
            let connectedNames = self.connectedExternalIdentities.map(\.defaultName)
            let usbFallbackId = self.uniqueUSBExternalIdentityAssumingLocked()?.id ?? ""
            let transports = self.connectedExternalTransports
            self.keyboardLock.unlock()

            // With Karabiner, physical IOHID only stamps a claim; CGEvent counts once using it.
            if karabiner {
                if builtinHIDClaimed {
                    // #region agent log
                    self.debugKeyDecisionLogCount += 1
                    if self.debugKeyDecisionLogCount <= 20 {
                        self.agentDebugLog(
                            hypothesisId: "F",
                            location: "KeystrokeMonitor.handleKeyDown.classify",
                            message: "decision_builtin",
                            data: [
                                "reason": "karabiner_hid_builtin",
                                "keycode": keycode,
                                "runId": "post-fix6",
                            ]
                        )
                    }
                    // #endregion
                    self.onBuiltinKeystroke?()
                    return
                }
                if externalHIDClaimed {
                    // #region agent log
                    self.debugKeyDecisionLogCount += 1
                    if self.debugKeyDecisionLogCount <= 20 {
                        self.agentDebugLog(
                            hypothesisId: "F",
                            location: "KeystrokeMonitor.handleKeyDown.classify",
                            message: "decision_external",
                            data: [
                                "reason": "karabiner_hid_external",
                                "keycode": keycode,
                                "runId": "post-fix6",
                            ]
                        )
                    }
                    // #endregion
                    // #region agent log
                    self.debugSessionResolveLogCount += 1
                    if self.debugSessionResolveLogCount <= 25 {
                        self.sessionDebugLog(
                            hypothesisId: "C",
                            location: "KeystrokeMonitor.classifyAndRecordKeystroke",
                            message: "cgevent_karabiner_external",
                            data: [
                                "resolvedId": resolvedExternal.id,
                                "resolvedName": resolvedExternal.defaultName,
                                "hidAgeMs": Int(hidAge * 1000),
                                "hidId": hidId,
                                "lastUsedId": lastUsedId,
                                "connectedIds": connectedIds,
                                "connectedNames": connectedNames,
                                "kbdType": kbdType,
                                "keycode": keycode,
                            ]
                        )
                    }
                    // #endregion
                    self.emitExternalKeystroke(resolvedExternal)
                    return
                }
                // MacBook after Karabiner-ignore: type 70 + flags 256 (not G Hub). Prefer builtin
                // when we have an open Apple Internal HID observer.
                if !self.physicalHIDObservers.isEmpty,
                   kbdType == Self.logitechGHubInjectedKeyboardType,
                   (flags & Self.logitechGHubInjectedFlagMask) == 0
                {
                    // #region agent log
                    self.debugKeyDecisionLogCount += 1
                    if self.debugKeyDecisionLogCount <= 20 {
                        self.agentDebugLog(
                            hypothesisId: "J",
                            location: "KeystrokeMonitor.handleKeyDown.classify",
                            message: "decision_builtin",
                            data: [
                                "reason": "macbook_native_type70",
                                "keycode": keycode,
                                "flags": flags,
                                "runId": "post-fix6",
                            ]
                        )
                    }
                    // #endregion
                    self.onBuiltinKeystroke?()
                    return
                }
            } else if builtinHIDClaimed {
                // Non-Karabiner: HID already counted builtin; suppress CGEvent duplicate.
                return
            }

            let asBuiltin = self.isBuiltinKeystroke(
                kbdType: kbdType,
                externalConnected: externalConnected,
                karabinerPresent: karabiner,
                learned: learned
            )
            // #region agent log
            self.debugKeyDecisionLogCount += 1
            if self.debugKeyDecisionLogCount <= 20 {
                let reason: String
                if !externalConnected {
                    reason = "no_external_inventory"
                } else if karabiner {
                    reason = "karabiner_cgevent_fallback"
                } else if learned.contains(kbdType) {
                    reason = "learned_type_match"
                } else {
                    reason = "external_default"
                }
                self.agentDebugLog(
                    hypothesisId: "F",
                    location: "KeystrokeMonitor.handleKeyDown.classify",
                    message: asBuiltin ? "decision_builtin" : "decision_external",
                    data: [
                        "kbdType": kbdType,
                        "keycode": keycode,
                        "externalConnected": externalConnected,
                        "karabinerPresent": karabiner,
                        "reason": reason,
                        "runId": "post-fix3",
                    ]
                )
            }
            // #endregion

            if asBuiltin {
                self.rememberBuiltinKeyboardType(kbdType)
                self.onBuiltinKeystroke?()
            } else {
                // #region agent log
                self.debugSessionResolveLogCount += 1
                if self.debugSessionResolveLogCount <= 25 {
                    self.sessionDebugLog(
                        hypothesisId: "C",
                        location: "KeystrokeMonitor.classifyAndRecordKeystroke",
                        message: "cgevent_fallback_external",
                        data: [
                            "resolvedId": resolvedExternal.id,
                            "resolvedName": resolvedExternal.defaultName,
                            "hidAgeMs": Int(hidAge * 1000),
                            "hidId": hidId,
                            "lastUsedId": lastUsedId,
                            "connectedIds": connectedIds,
                            "connectedNames": connectedNames,
                            "usbFallbackId": usbFallbackId,
                            "transports": transports,
                            "hidClaimed": externalHIDClaimed,
                            "kbdType": kbdType,
                            "keycode": keycode,
                            "karabiner": karabiner,
                            "runId": "post-fix7",
                        ]
                    )
                }
                // #endregion
                self.emitExternalKeystroke(resolvedExternal)
            }
        }

        // Run on the tap thread (callbacks already hop to MainActor). Only delay when
        // Karabiner is present so physical IOHID can win the race.
        if karabinerPresent {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + Self.karabinerHIDClassifyDelay,
                execute: classify
            )
        } else {
            classify()
        }
    }

    private static func isLogitechGHubInjectedKeystroke(kbdType: Int64, flags: UInt64) -> Bool {
        guard kbdType == logitechGHubInjectedKeyboardType else { return false }
        return (flags & logitechGHubInjectedFlagMask) != 0
    }

    private func isBuiltinKeystroke(
        kbdType: Int64,
        externalConnected: Bool,
        karabinerPresent: Bool,
        learned: Set<Int64>
    ) -> Bool {
        // No plug-in keyboard present → this press is from the MacBook keyboard.
        if !externalConnected {
            return true
        }
        // Karabiner posts every physical keyboard as one CGEvent keyboard type (e.g. 46).
        // Without a physical HID claim we cannot know the source; prefer external so the
        // docked Kinesis board is not counted as MacBook. Physical HID should normally claim first.
        if karabinerPresent {
            return false
        }
        // With an external keyboard connected, only types previously seen as built-in count as laptop.
        if learned.contains(kbdType) {
            return true
        }
        return false
    }

    private func rememberBuiltinKeyboardType(_ kbdType: Int64) {
        keyboardLock.lock()
        let karabinerPresent = hasKarabinerVirtualKeyboard
        let externalConnected = hasExternalKeyboardConnected
        // Do not persist Karabiner’s shared virtual type as “MacBook”.
        guard !karabinerPresent else {
            keyboardLock.unlock()
            return
        }
        let inserted = learnedBuiltinKeyboardTypes.insert(kbdType).inserted
        let snapshot = learnedBuiltinKeyboardTypes
        keyboardLock.unlock()

        // Learn while typing on the laptop with no external keyboard attached.
        if inserted, !externalConnected {
            let ints = snapshot.map { Int($0) }.sorted()
            UserDefaults.standard.set(ints, forKey: Self.learnedBuiltinKeyboardTypesKey)
        }
    }

    private func refreshKeyboardInventory(force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        keyboardLock.lock()
        let due = force || now - lastKeyboardInventoryAt >= Self.keyboardInventoryRefreshInterval
        keyboardLock.unlock()
        guard due else { return }

        let inventory = Self.scanKeyboardInventory()
        keyboardLock.lock()
        hasExternalKeyboardConnected = inventory.externalConnected
        hasKarabinerVirtualKeyboard = inventory.karabinerPresent
        builtinKeyboardRegistryIDs = inventory.builtinRegistryIDs
        externalKeyboardRegistryIDs = inventory.externalRegistryIDs
        connectedExternalIdentities = inventory.externalIdentities
        connectedExternalTransports = inventory.identityTransports
        lastKeyboardInventoryAt = now
        let seized = physicalHIDSeizedByKarabiner
        let identities = inventory.externalIdentities
        keyboardLock.unlock()
        if !identities.isEmpty {
            onExternalKeyboardInventory?(identities)
        }

        // #region agent log
        debugInventoryLogCount += 1
        if debugInventoryLogCount <= 8 {
            sessionDebugLog(
                hypothesisId: "B",
                location: "KeystrokeMonitor.refreshKeyboardInventory",
                message: "keyboard_inventory",
                data: [
                    "externalConnected": inventory.externalConnected,
                    "karabinerPresent": inventory.karabinerPresent,
                    "observerCount": physicalHIDObservers.count,
                    "seized": seized,
                    "identities": identities.map {
                        [
                            "id": $0.id,
                            "name": $0.defaultName,
                            "vendor": $0.vendorID,
                            "productID": $0.productID,
                            "product": $0.product,
                            "manufacturer": $0.manufacturer,
                            "transport": inventory.identityTransports[$0.id] ?? "",
                        ]
                    },
                    "runId": "post-fix7",
                ]
            )
        }
        // #endregion

        // Only retry device opens when not already blocked by Karabiner seize.
        if hidManager != nil, !seized {
            attachPhysicalKeyboardHIDObservers()
        }

        // #region agent log
        debugInventoryLogCount += 1
        if debugInventoryLogCount <= 3 {
            agentDebugLog(
                hypothesisId: "A",
                location: "KeystrokeMonitor.refreshKeyboardInventory",
                message: "keyboard_inventory",
                data: [
                    "externalConnected": inventory.externalConnected,
                    "karabinerPresent": inventory.karabinerPresent,
                    "deviceCount": inventory.devices.count,
                    "builtinIDs": inventory.builtinRegistryIDs.map { Int($0) }.sorted(),
                    "externalIDs": inventory.externalRegistryIDs.map { Int($0) }.sorted(),
                    "observerCount": physicalHIDObservers.count,
                    "seized": seized,
                    "runId": "post-fix4",
                ]
            )
        }
        // #endregion
    }

    /// True when a real external USB/Bluetooth keyboard is present (not Karabiner/Touch Bar).
    private static func externalKeyboardConnected() -> Bool {
        scanKeyboardInventory().externalConnected
    }

    private struct KeyboardInventoryScan {
        var externalConnected: Bool
        var karabinerPresent: Bool
        var builtinRegistryIDs: Set<UInt64>
        var externalRegistryIDs: Set<UInt64>
        var externalIdentities: [ExternalKeyboardIdentity]
        var identityTransports: [String: String]
        var devices: [[String: Any]]
    }

    private static func scanKeyboardInventory() -> KeyboardInventoryScan {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        // CopyDevices works without Open — important when Karabiner has exclusive access.
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var summaries: [[String: Any]] = []
        var externalConnected = false
        var karabinerPresent = false
        var builtinIDs: Set<UInt64> = []
        var externalIDs: Set<UInt64> = []
        var identitiesByID: [String: ExternalKeyboardIdentity] = [:]
        var identityTransports: [String: String] = [:]
        for device in devices {
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
            let manufacturer = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? ""
            let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
            let builtInProp = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString)
            let builtIn: Bool? = {
                if let b = builtInProp as? Bool { return b }
                if let n = builtInProp as? NSNumber { return n.boolValue }
                return nil
            }()
            let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? -1
            let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? -1
            let isVirtual = isVirtualOrRemappingKeyboard(device)
            let isTouchBar = isTouchBarKeyboard(device)
            let isBuiltin = isBuiltinKeyboardDevice(device)
            let isMouseReceiver = isMouseReceiverPosingAsKeyboard(device)
            var registryID: UInt64 = 0
            let service = IOHIDDeviceGetService(device)
            if IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS, registryID != 0 {
                if isBuiltin, !isTouchBar {
                    builtinIDs.insert(registryID)
                } else if !isVirtual, !isTouchBar, !isBuiltin, !isMouseReceiver {
                    externalIDs.insert(registryID)
                }
            }
            if !isVirtual, !isTouchBar, !isBuiltin, !isMouseReceiver {
                let identity = identity(from: device)
                identitiesByID[identity.id] = identity
                let existingTransport = identityTransports[identity.id] ?? ""
                if existingTransport != "USB" {
                    identityTransports[identity.id] = transport
                }
            }
            if isVirtual { karabinerPresent = true }
            // Real external boards only — not Karabiner, Touch Bar, built-in, or mouse dongles
            // that expose a keyboard interface for G-keys (Logitech USB Receiver).
            let countsAsExternal = !isVirtual && !isTouchBar && !isBuiltin && !isMouseReceiver
            if countsAsExternal { externalConnected = true }
            summaries.append([
                "product": product,
                "manufacturer": manufacturer,
                "transport": transport,
                "builtInProp": builtIn.map { $0 ? "true" : "false" } ?? "nil",
                "vendor": vendor,
                "productID": productID,
                "registryID": registryID,
                "isVirtual": isVirtual,
                "isTouchBar": isTouchBar,
                "isBuiltin": isBuiltin,
                "isMouseReceiver": isMouseReceiver,
                "countsAsExternal": countsAsExternal,
            ])
        }
        return KeyboardInventoryScan(
            externalConnected: externalConnected,
            karabinerPresent: karabinerPresent,
            builtinRegistryIDs: builtinIDs,
            externalRegistryIDs: externalIDs,
            externalIdentities: Array(identitiesByID.values).sorted { $0.defaultName < $1.defaultName },
            identityTransports: identityTransports,
            devices: summaries
        )
    }

    /// Mouse / receiver HID keyboard interfaces (G Hub G-keys), not typing keyboards.
    private static func isMouseReceiverPosingAsKeyboard(_ device: IOHIDDevice?) -> Bool {
        guard let device else { return false }
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)?
            .lowercased() ?? ""
        let manufacturer = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String)?
            .lowercased() ?? ""
        if product.contains("usb receiver") { return true }
        if product.contains("receiver") && (manufacturer.contains("logitech") || product.contains("logitech")) {
            return true
        }
        if product.contains("g hub") || product.contains("logitech gaming") {
            return true
        }
        return false
    }

    // MARK: - Physical keyboard source (IOHID open when possible; else event-system sender IDs)

    private func startBuiltinKeyboardHID() {
        guard hidManager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        // Do NOT call IOHIDManagerOpen under Karabiner — ExclusiveAccess on seized boards.
        hidManager = manager
        hidOpenSucceeded = false
        attachPhysicalKeyboardHIDObservers()
    }

    private func attachPhysicalKeyboardHIDObservers() {
        guard hidManager != nil else { return }
        // Match inventory: a fresh CopyDevices sees newly plugged boards. The long-lived
        // hidManager snapshot can stay stuck on the MacBook keyboard after Kinesis connects.
        let probe = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(probe, matching as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(probe) as? Set<IOHIDDevice>) ?? []
        var sawExclusive = false
        for device in devices {
            let result = tryAttachPhysicalKeyboardObserver(for: device)
            if result == .builtinExclusive || result == .exclusive {
                sawExclusive = true
            }
        }
        if sawExclusive {
            releaseBuiltinKeyboardFromKarabinerIfNeeded()
        }
    }

    private enum PhysicalHIDAttachResult {
        case skipped
        case opened
        case exclusive
        case builtinExclusive
        case failed
    }

    @discardableResult
    private func tryAttachPhysicalKeyboardObserver(for device: IOHIDDevice) -> PhysicalHIDAttachResult {
        if Self.isVirtualOrRemappingKeyboard(device) { return .skipped }
        if Self.isTouchBarKeyboard(device) { return .skipped }
        if Self.isMouseReceiverPosingAsKeyboard(device) { return .skipped }

        let service = IOHIDDeviceGetService(device)
        var entryID: UInt64 = 0
        let idResult = IORegistryEntryGetRegistryEntryID(service, &entryID)
        guard idResult == KERN_SUCCESS else { return .failed }

        keyboardLock.lock()
        let alreadyOpen = physicalHIDObserverServiceIDs.contains(entryID)
        keyboardLock.unlock()
        if alreadyOpen { return .opened }

        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        let isBuiltin = Self.isBuiltinKeyboardDevice(device)

        guard let observer = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return .failed }
        let openResult = IOHIDDeviceOpen(observer, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnExclusiveAccess {
            // #region agent log
            agentDebugLog(
                hypothesisId: "G",
                location: "KeystrokeMonitor.tryAttachPhysicalKeyboardObserver",
                message: "hid_device_exclusive",
                data: [
                    "product": product,
                    "isBuiltin": isBuiltin,
                    "serviceID": entryID,
                    "runId": "post-fix5",
                ]
            )
            debugSessionAttachLogCount += 1
            if debugSessionAttachLogCount <= 16 {
                sessionDebugLog(
                    hypothesisId: "A",
                    location: "KeystrokeMonitor.tryAttachPhysicalKeyboardObserver",
                    message: "hid_attach",
                    data: [
                        "product": product,
                        "isBuiltin": isBuiltin,
                        "result": "exclusive",
                        "openResult": Int(openResult),
                    ]
                )
            }
            // #endregion
            return isBuiltin ? .builtinExclusive : .exclusive
        }
        guard openResult == kIOReturnSuccess else {
            // #region agent log
            debugSessionAttachLogCount += 1
            if debugSessionAttachLogCount <= 16 {
                sessionDebugLog(
                    hypothesisId: "A",
                    location: "KeystrokeMonitor.tryAttachPhysicalKeyboardObserver",
                    message: "hid_attach",
                    data: [
                        "product": product,
                        "isBuiltin": isBuiltin,
                        "result": "failed",
                        "openResult": Int(openResult),
                    ]
                )
            }
            // #endregion
            return .failed
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(observer, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<KeystrokeMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handlePhysicalHIDKeyboardValue(value)
        }, refcon)
        IOHIDDeviceScheduleWithRunLoop(observer, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

        keyboardLock.lock()
        physicalHIDObserverServiceIDs.insert(entryID)
        physicalHIDObservers.append(observer)
        keyboardLock.unlock()
        // #region agent log
        debugSessionAttachLogCount += 1
        if debugSessionAttachLogCount <= 16 {
            sessionDebugLog(
                hypothesisId: "A",
                location: "KeystrokeMonitor.tryAttachPhysicalKeyboardObserver",
                message: "hid_attach",
                data: [
                    "product": product,
                    "isBuiltin": isBuiltin,
                    "result": "opened",
                    "openResult": Int(openResult),
                ]
            )
        }
        // #endregion
        return .opened
    }

    private func releaseBuiltinKeyboardFromKarabinerIfNeeded() {
        guard !didAttemptKarabinerBuiltinRelease else { return }
        didAttemptKarabinerBuiltinRelease = true
        let changed = MacKarabinerBuiltinKeyboardRelease.ensureBuiltinKeyboardIgnored()
        // #region agent log
        sessionDebugLog(
            hypothesisId: "A",
            location: "KeystrokeMonitor.releaseBuiltinKeyboardFromKarabinerIfNeeded",
            message: "karabiner_release_devices",
            data: [
                "configChanged": changed,
                "runId": "post-fix7",
            ]
        )
        agentDebugLog(
            hypothesisId: "I",
            location: "KeystrokeMonitor.releaseBuiltinKeyboardFromKarabinerIfNeeded",
            message: "karabiner_release_builtin",
            data: [
                "configChanged": changed,
                "runId": "post-fix7",
            ]
        )
        // #endregion
        // Karabiner reloads async; retry HID open on the input-tap run loop (device callbacks need it).
        scheduleHIDRetryAfterKarabinerRelease(delay: 1.5)
        scheduleHIDRetryAfterKarabinerRelease(delay: 4.0)
    }

    private func scheduleHIDRetryAfterKarabinerRelease(delay: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let work = { [weak self] in
                guard let self else { return }
                self.physicalHIDSeizedByKarabiner = false
                self.attachPhysicalKeyboardHIDObservers()
                // #region agent log
                self.sessionDebugLog(
                    hypothesisId: "A",
                    location: "KeystrokeMonitor.releaseBuiltinKeyboardFromKarabinerIfNeeded",
                    message: "hid_retry_after_karabiner_release",
                    data: [
                        "delayMs": Int(delay * 1000),
                        "observerCount": self.physicalHIDObservers.count,
                        "runId": "post-fix7",
                    ]
                )
                self.agentDebugLog(
                    hypothesisId: "I",
                    location: "KeystrokeMonitor.releaseBuiltinKeyboardFromKarabinerIfNeeded",
                    message: "hid_retry_after_karabiner_release",
                    data: [
                        "observerCount": self.physicalHIDObservers.count,
                        "seized": self.physicalHIDSeizedByKarabiner,
                        "runId": "post-fix7",
                    ]
                )
                // #endregion
            }
            if let loop = self.tapRunLoop {
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, work)
                CFRunLoopWakeUp(loop)
            } else {
                work()
            }
        }
    }

    private func stopBuiltinKeyboardHID() {
        for observer in physicalHIDObservers {
            IOHIDDeviceUnscheduleFromRunLoop(observer, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceRegisterInputValueCallback(observer, nil, nil)
            IOHIDDeviceClose(observer, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        physicalHIDObservers.removeAll()
        physicalHIDObserverServiceIDs.removeAll()
        hidManager = nil
        hidOpenSucceeded = false
    }

    /// Attribute keys via the physical HID device. Karabiner’s virtual keyboard is ignored here;
    /// CGEvent handles dedupe after a short delay when Karabiner is present.
    private func handlePhysicalHIDKeyboardValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        let usage = IOHIDElementGetUsage(element)
        guard usage >= 4, usage <= 231 else { return }
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }

        let device = IOHIDElementGetDevice(element)
        if Self.isVirtualOrRemappingKeyboard(device) {
            // #region agent log
            debugHIDClaimLogCount += 1
            if debugHIDClaimLogCount <= 8 {
                agentDebugLog(
                    hypothesisId: "F",
                    location: "KeystrokeMonitor.handlePhysicalHIDKeyboardValue",
                    message: "hid_ignore_virtual",
                    data: ["usage": Int(usage), "runId": "post-fix3"]
                )
            }
            // #endregion
            return
        }
        if Self.isTouchBarKeyboard(device) { return }
        if Self.isMouseReceiverPosingAsKeyboard(device) { return }

        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        keyboardLock.lock()
        let karabiner = hasKarabinerVirtualKeyboard
        if Self.isBuiltinKeyboardDevice(device) {
            lastBuiltinHIDKeyAt = CFAbsoluteTimeGetCurrent()
            keyboardLock.unlock()
            // #region agent log
            debugHIDClaimLogCount += 1
            if debugHIDClaimLogCount <= 16 {
                agentDebugLog(
                    hypothesisId: "G",
                    location: "KeystrokeMonitor.handlePhysicalHIDKeyboardValue",
                    message: "hid_builtin_claim",
                    data: [
                        "usage": Int(usage),
                        "product": product,
                        "countNow": !karabiner,
                        "runId": "post-fix3",
                    ]
                )
            }
            // #endregion
            // With Karabiner, only stamp the claim — CGEvent path counts after the delay.
            if !karabiner {
                onBuiltinKeystroke?()
            }
        } else {
            let identity = Self.identity(from: device)
            lastExternalHIDKeyAt = CFAbsoluteTimeGetCurrent()
            lastExternalHIDIdentity = identity
            lastUsedExternalIdentity = identity
            keyboardLock.unlock()
            // #region agent log
            debugSessionHIDLogCount += 1
            if debugSessionHIDLogCount <= 25 {
                sessionDebugLog(
                    hypothesisId: "A",
                    location: "KeystrokeMonitor.handlePhysicalHIDKeyboardValue",
                    message: "hid_external_claim",
                    data: [
                        "usage": Int(usage),
                        "product": product,
                        "keyboardId": identity.id,
                        "defaultName": identity.defaultName,
                        "vendorID": identity.vendorID,
                        "productID": identity.productID,
                        "karabiner": karabiner,
                        "countNow": !karabiner,
                    ]
                )
            }
            // #endregion
            if !karabiner {
                emitExternalKeystroke(identity)
            }
        }
    }

    // #region agent log
    private func debugLogMouseButton(event: CGEvent, kind: String) {
        debugOtherMouseLogCount += 1
        guard debugOtherMouseLogCount <= 6 else { return }
        agentDebugLog(
            hypothesisId: "D",
            location: "KeystrokeMonitor.mouseButton",
            message: kind,
            data: [
                "buttonNumber": event.getIntegerValueField(.mouseEventButtonNumber),
                "subtype": event.getIntegerValueField(.mouseEventSubtype),
                "runId": "post-fix2",
            ]
        )
    }
    // #endregion

    private static func isVirtualOrRemappingKeyboard(_ device: IOHIDDevice?) -> Bool {
        guard let device else { return false }
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)?
            .lowercased() ?? ""
        if product.contains("karabiner")
            || product.contains("virtualhid")
            || product.contains("virtual keyboard")
        {
            return true
        }
        let manufacturer = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String)?
            .lowercased() ?? ""
        if manufacturer.contains("pqrs") {
            return true
        }
        return false
    }

    private static func isTouchBarKeyboard(_ device: IOHIDDevice?) -> Bool {
        guard let device else { return false }
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)?
            .lowercased() ?? ""
        return product.contains("touchbar") || product.contains("touch bar")
    }

    /// Prefer `Built-In` / product name. Internal keyboards are often USB + Built-In=1.
    private static func isBuiltinKeyboardDevice(_ device: IOHIDDevice?) -> Bool {
        guard let device else { return false }

        if let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool {
            return builtIn
        }
        if let builtInNum = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? NSNumber {
            return builtInNum.boolValue
        }

        if let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            let p = product.lowercased()
            if p.contains("internal keyboard")
                || p.contains("apple internal")
                || (p.contains("macbook") && p.contains("keyboard"))
            {
                return true
            }
        }

        if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String {
            let t = transport.lowercased()
            if t == "fifo" || t == "spi" || t == "i2c" || t == "built-in" || t.contains("built") {
                return true
            }
        }
        return false
    }

    private func emitExternalKeystroke(_ identity: ExternalKeyboardIdentity) {
        keyboardLock.lock()
        lastUsedExternalIdentity = identity
        keyboardLock.unlock()
        // #region agent log
        debugSessionEmitLogCount += 1
        if debugSessionEmitLogCount <= 25 {
            sessionDebugLog(
                hypothesisId: "D",
                location: "KeystrokeMonitor.emitExternalKeystroke",
                message: "emit_external",
                data: [
                    "keyboardId": identity.id,
                    "defaultName": identity.defaultName,
                    "vendorID": identity.vendorID,
                    "productID": identity.productID,
                    "product": identity.product,
                ]
            )
        }
        // #endregion
        onKeystroke?()
        onExternalKeyboardKeystroke?(identity)
    }

    /// Caller must already hold ``keyboardLock``.
    private func resolvedExternalIdentityAssumingLocked(now: CFAbsoluteTime) -> ExternalKeyboardIdentity {
        if now - lastExternalHIDKeyAt < Self.externalHIDClaimWindow, let hid = lastExternalHIDIdentity {
            return hid
        }
        if connectedExternalIdentities.count == 1, let only = connectedExternalIdentities.first {
            return only
        }
        // HID-claimed keys already returned above. Unique USB board is the only remaining
        // physical source Karabiner can still seize (Kinesis). Bluetooth Keychron is ignored
        // in Karabiner so its keys hit HID, not this fallback.
        if let usbOnly = uniqueUSBExternalIdentityAssumingLocked() {
            return usbOnly
        }
        if let lastUsed = lastUsedExternalIdentity,
           connectedExternalIdentities.contains(where: { $0.id == lastUsed.id })
        {
            return lastUsed
        }
        if let hid = lastExternalHIDIdentity {
            return hid
        }
        if let lastUsed = lastUsedExternalIdentity {
            return lastUsed
        }
        return .unknown
    }

    /// Caller must already hold ``keyboardLock``.
    private func uniqueUSBExternalIdentityAssumingLocked() -> ExternalKeyboardIdentity? {
        let usb = connectedExternalIdentities.filter { identity in
            (connectedExternalTransports[identity.id] ?? "").localizedCaseInsensitiveContains("USB")
        }
        return usb.count == 1 ? usb.first : nil
    }

    private func logCGEventIdentityFields(_ event: CGEvent, keycode: Int64, kbdType: Int64) {
        // #region agent log
        debugSessionCGFieldLogCount += 1
        guard debugSessionCGFieldLogCount <= 8 else { return }
        var nonzero: [String: Int] = [:]
        for field in 0...90 {
            guard let cgField = CGEventField(rawValue: UInt32(field)) else { continue }
            let value = event.getIntegerValueField(cgField)
            if value != 0 {
                nonzero["f\(field)"] = Int(value)
            }
        }
        sessionDebugLog(
            hypothesisId: "J",
            location: "KeystrokeMonitor.handleKeyDown",
            message: "cgevent_fields",
            data: [
                "keycode": keycode,
                "kbdType": kbdType,
                "srcPID": event.getIntegerValueField(.eventSourceUnixProcessID),
                "srcUser": event.getIntegerValueField(.eventSourceUserData),
                "srcState": event.getIntegerValueField(.eventSourceStateID),
                "nonzero": nonzero,
            ]
        )
        // #endregion
    }

    private static func identity(from device: IOHIDDevice) -> ExternalKeyboardIdentity {
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        let manufacturer = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? ""
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? -1
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? -1
        let serial = (IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String) ?? ""
        return ExternalKeyboardIdentity.make(
            vendorID: vendor,
            productID: productID,
            manufacturer: manufacturer,
            product: product,
            serial: serial
        )
    }

    // MARK: - Pointer / scroll classification

    private func isTrackpadTouchEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.mouseEventSubtype) == Self.trackpadTouchSubtype
    }

    private func handleScrollWheel(_ event: CGEvent) {
        let decision = classifyScrollEvent(event)
        // #region agent log
        // Separate caps so trackpad flood cannot hide mouse evidence.
        let logMessage: String
        let shouldLog: Bool
        // Keep route spam off during lag debugging; gesture totals + tap windows remain.
        if decision.isTrackpad {
            debugTrackpadRouteLogCount += 1
            shouldLog = false
            logMessage = "route_trackpad_scroll"
        } else if decision.ignore {
            debugMouseRouteLogCount += 1
            shouldLog = false
            logMessage = "route_mouse_pixel_ignored"
        } else {
            debugMouseRouteLogCount += 1
            shouldLog = false
            logMessage = "route_mouse_scroll_candidate"
        }
        // #endregion
        if decision.isTrackpad {
            // Momentum = inertia after finger lifts. Latch (`gestureActive_continuous`) also
            // catches mouse pixel companions (~±135) while the gesture flag is still set —
            // those must not add trackpad travel (logs showed 405 = 135×3 per stolen event).
            let isMomentum = decision.momentumPhase != 0
                || decision.reason == "momentumPhase"
            let countsContactPixels = !isMomentum
                && (decision.reason == "scrollPhase" || decision.reason == "mouseSubtype3")
            let pixels = countsContactPixels ? Self.scrollTravelPixels(from: event) : 0.0
            // #region agent log
            if countsContactPixels {
                debugGestureScrollPixelSum += pixels
                debugGestureScrollEventCount += 1
            } else if isMomentum {
                debugGestureMomentumSkippedSum += Self.scrollTravelPixels(from: event)
                debugGestureMomentumSkippedCount += 1
            } else {
                debugGestureLatchSkippedSum += Self.scrollTravelPixels(from: event)
                debugGestureLatchSkippedCount += 1
            }
            let phaseEnded = decision.scrollPhase == CGScrollPhaseCode.ended.rawValue
                || decision.scrollPhase == CGScrollPhaseCode.cancelled.rawValue
                || decision.momentumPhase == CGMomentumPhaseCode.end.rawValue
            var nsPhaseRaw: UInt = 0
            var nsMomRaw: UInt = 0
            if let ns = NSEvent(cgEvent: event) {
                nsPhaseRaw = ns.phase.rawValue
                nsMomRaw = ns.momentumPhase.rawValue
            }
            if shouldLog {
                var nsScroll = 0.0
                if let ns = NSEvent(cgEvent: event) {
                    nsScroll = abs(ns.scrollingDeltaX) + abs(ns.scrollingDeltaY)
                }
                agentDebugLog(
                    hypothesisId: decision.hypothesisId,
                    location: "KeystrokeMonitor.handleScrollWheel",
                    message: logMessage,
                    data: [
                        "runId": "post-fix-misattr-lag",
                        "tpN": debugTrackpadRouteLogCount,
                        "mouseN": debugMouseRouteLogCount,
                        "reason": decision.reason,
                        "cont": decision.continuous,
                        "precise": decision.precise,
                        "nsSub": decision.nsSubtype,
                        "mouseSub": decision.mouseSubtype,
                        "phase": decision.scrollPhase,
                        "mom": decision.momentumPhase,
                        "nsPhase": nsPhaseRaw,
                        "nsMom": nsMomRaw,
                        "isMomentum": isMomentum,
                        "countsPixels": countsContactPixels,
                        "line1": decision.line1,
                        "line2": decision.line2,
                        "pt1": decision.point1,
                        "pt2": decision.point2,
                        "nsScroll": nsScroll,
                        "pixelsAdded": pixels,
                        "rawNsScroll": nsScroll,
                        "scale": Self.trackpadScrollTravelScale,
                        "gestureSum": debugGestureScrollPixelSum,
                        "gestureEvents": debugGestureScrollEventCount,
                        "momSkippedSum": debugGestureMomentumSkippedSum,
                        "latchSkippedSum": debugGestureLatchSkippedSum,
                    ]
                )
            }
            if phaseEnded {
                agentDebugLog(
                    hypothesisId: "H",
                    location: "KeystrokeMonitor.handleScrollWheel",
                    message: "trackpad_gesture_pixel_total",
                    data: [
                        "runId": "post-fix-misattr-lag",
                        "gestureSum": debugGestureScrollPixelSum,
                        "gestureEvents": debugGestureScrollEventCount,
                        "momSkippedSum": debugGestureMomentumSkippedSum,
                        "momSkippedEvents": debugGestureMomentumSkippedCount,
                        "latchSkippedSum": debugGestureLatchSkippedSum,
                        "latchSkippedEvents": debugGestureLatchSkippedCount,
                        "endReason": decision.reason,
                        "phase": decision.scrollPhase,
                        "mom": decision.momentumPhase,
                        "scale": Self.trackpadScrollTravelScale,
                    ]
                )
                debugGestureScrollPixelSum = 0
                debugGestureScrollEventCount = 0
                debugGestureMomentumSkippedSum = 0
                debugGestureMomentumSkippedCount = 0
                debugGestureLatchSkippedSum = 0
                debugGestureLatchSkippedCount = 0
            }
            // #endregion
            // Only refresh companion suppress during finger contact — not for the whole
            // momentum coast (that was blocking immediate external mouse notches).
            if countsContactPixels || decision.reason == "scrollPhase" {
                noteTrackpadScroll()
            }
            if countsContactPixels {
                accumulateBuiltinTrackpadScrollPixels(from: event)
            }
            return
        }
        // #region agent log
        if shouldLog {
            agentDebugLog(
                hypothesisId: decision.hypothesisId,
                location: "KeystrokeMonitor.handleScrollWheel",
                message: logMessage,
                data: [
                    "runId": "post-fix-magnitude",
                    "tpN": debugTrackpadRouteLogCount,
                    "mouseN": debugMouseRouteLogCount,
                    "reason": decision.reason,
                    "cont": decision.continuous,
                    "precise": decision.precise,
                    "phase": decision.scrollPhase,
                    "line1": decision.line1,
                    "pt1": decision.point1,
                ]
            )
        }
        // #endregion
        if decision.ignore {
            // Continuous/precise mouse wheel (G502 etc.): often NO discrete companion event.
            // Do not treat as trackpad — but still count notches (line ticks / point quantize).
            scrollLock.lock()
            trackpadScrollGestureActive = false
            scrollLock.unlock()
            countContinuousMouseScrollBumpIfNeeded(decision: decision, timestamp: event.timestamp)
            return
        }
        // Discrete mouse-wheel notch (or trackpad line-companion). Count immediately; suppress
        // only when a recent phased trackpad scroll claimed the companion window.
        scrollLock.lock()
        trackpadScrollGestureActive = false
        mouseContinuousPointAccumulator = 0
        scrollLock.unlock()
        countMouseScrollBumpIfNeeded(timestamp: event.timestamp)
    }

    private struct ScrollClassification {
        let isTrackpad: Bool
        /// Continuous/precise mouse stream with no gesture phase — not trackpad; count as mouse bumps.
        let ignore: Bool
        let reason: String
        let hypothesisId: String
        let continuous: Int64
        let precise: Bool
        let nsSubtype: Int
        let mouseSubtype: Int64
        let scrollPhase: Int64
        let momentumPhase: Int64
        let line1: Int64
        let line2: Int64
        let point1: Double
        let point2: Double
    }

    /// CGEvent scroll-phase field uses CGScrollPhase values, NOT NSEvent.Phase bitmasks
    /// (e.g. CG changed=2 vs NS stationary=2; CG mayBegin=128 vs NS mayBegin=32).
    private enum CGScrollPhaseCode: Int64 {
        case none = 0
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
        case mayBegin = 128
    }

    /// CGEvent momentum-phase field uses CGMomentumScrollPhase (0/1/2/3), not NSEvent.Phase.
    private enum CGMomentumPhaseCode: Int64 {
        case none = 0
        case begin = 1
        case continuePhase = 2
        case end = 3
    }

    /// Built-in trackpad two-finger scroll sets scroll/momentum phases.
    /// Many external mice also emit continuous/precise pixel events (and a discrete companion);
    /// those must NOT be treated as trackpad — that both polluted the trackpad chart and suppressed
    /// real mouse notches via the companion window.
    private func classifyScrollEvent(_ event: CGEvent) -> ScrollClassification {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let mouseSubtype = event.getIntegerValueField(.mouseEventSubtype)
        let scrollPhaseRaw = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhaseRaw = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let line1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let point1 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let point2 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        var precise = false
        var nsSubtype = Int(NSEvent.EventSubtype.mouseEvent.rawValue)
        // Prefer AppKit phases when available (already mapped); fall back to CG codes.
        var nsScrollPhase = NSEvent.Phase()
        var nsMomentumPhase = NSEvent.Phase()
        var hasNSPhases = false
        if let nsEvent = NSEvent(cgEvent: event) {
            precise = nsEvent.hasPreciseScrollingDeltas
            nsSubtype = Int(nsEvent.subtype.rawValue)
            nsScrollPhase = nsEvent.phase
            nsMomentumPhase = nsEvent.momentumPhase
            hasNSPhases = true
        }

        func result(
            isTrackpad: Bool,
            ignore: Bool = false,
            reason: String,
            hypothesisId: String
        ) -> ScrollClassification {
            ScrollClassification(
                isTrackpad: isTrackpad,
                ignore: ignore,
                reason: reason,
                hypothesisId: hypothesisId,
                continuous: continuous,
                precise: precise,
                nsSubtype: nsSubtype,
                mouseSubtype: mouseSubtype,
                scrollPhase: scrollPhaseRaw,
                momentumPhase: momentumPhaseRaw,
                line1: line1,
                line2: line2,
                point1: point1,
                point2: point2
            )
        }

        // Same subtype used for working trackpad clicks/travel.
        if mouseSubtype == Self.trackpadTouchSubtype {
            return result(isTrackpad: true, reason: "mouseSubtype3", hypothesisId: "F")
        }

        let cgScroll = CGScrollPhaseCode(rawValue: scrollPhaseRaw)
        let cgMomentum = CGMomentumPhaseCode(rawValue: momentumPhaseRaw)

        let scrollBegan: Bool
        let scrollChanged: Bool
        let scrollEnded: Bool
        let scrollCancelled: Bool
        let scrollMayBegin: Bool
        let momentumBegan: Bool
        let momentumChanged: Bool
        let momentumEnded: Bool
        if hasNSPhases {
            scrollBegan = nsScrollPhase.contains(.began)
            scrollChanged = nsScrollPhase.contains(.changed)
            scrollEnded = nsScrollPhase.contains(.ended)
            scrollCancelled = nsScrollPhase.contains(.cancelled)
            scrollMayBegin = nsScrollPhase.contains(.mayBegin)
            momentumBegan = nsMomentumPhase.contains(.began)
            momentumChanged = nsMomentumPhase.contains(.changed)
            momentumEnded = nsMomentumPhase.contains(.ended)
        } else {
            scrollBegan = cgScroll == .began
            scrollChanged = cgScroll == .changed
            scrollEnded = cgScroll == .ended
            scrollCancelled = cgScroll == .cancelled
            scrollMayBegin = cgScroll == .mayBegin
            momentumBegan = cgMomentum == .begin
            momentumChanged = cgMomentum == .continuePhase
            momentumEnded = cgMomentum == .end
        }

        scrollLock.lock()
        if scrollBegan || scrollMayBegin || momentumBegan {
            trackpadScrollGestureActive = true
        }
        let gestureActive = trackpadScrollGestureActive
        if scrollEnded || scrollCancelled || momentumEnded {
            trackpadScrollGestureActive = false
        }
        scrollLock.unlock()

        if scrollBegan || scrollChanged || scrollMayBegin || scrollEnded || scrollCancelled {
            return result(isTrackpad: true, reason: "scrollPhase", hypothesisId: "C")
        }

        if momentumBegan || momentumChanged || momentumEnded {
            return result(isTrackpad: true, reason: "momentumPhase", hypothesisId: "C")
        }

        // Mid-gesture trackpad deltas often arrive as continuous/precise with empty phase.
        // Only keep the latch while contact was recent — a stuck latch was swallowing all
        // external mouse continuous wheels as "trackpad" with zero bumps.
        if gestureActive && (continuous != 0 || precise) {
            scrollLock.lock()
            let trackpadAgo = CFAbsoluteTimeGetCurrent() - lastTrackpadScrollAt
            if trackpadAgo < Self.staleTrackpadGestureLatch {
                scrollLock.unlock()
                return result(isTrackpad: true, reason: "gestureActive_continuous", hypothesisId: "G")
            }
            trackpadScrollGestureActive = false
            scrollLock.unlock()
        }

        // Continuous/precise without an active trackpad gesture = mouse wheel stream.
        // Many gaming mice never emit a discrete companion — count on the ignore path.
        if continuous != 0 || precise {
            return result(isTrackpad: false, ignore: true, reason: "continuous_mouse_wheel", hypothesisId: "A")
        }

        return result(isTrackpad: false, reason: "discrete_mouse", hypothesisId: "E")
    }

    private func isTrackpadScrollEvent(_ event: CGEvent) -> Bool {
        classifyScrollEvent(event).isTrackpad
    }

    private func noteTrackpadScroll() {
        scrollLock.lock()
        lastTrackpadScrollAt = CFAbsoluteTimeGetCurrent()
        scrollLock.unlock()
    }

    private func countMouseScrollBumpIfNeeded(timestamp: CGEventTimestamp) {
        scrollLock.lock()
        let trackpadAgo = CFAbsoluteTimeGetCurrent() - lastTrackpadScrollAt
        scrollLock.unlock()
        if trackpadAgo < Self.trackpadScrollCompanionWindow {
            // #region agent log
            if debugMouseRouteLogCount <= 40 {
                agentDebugLog(
                    hypothesisId: "E",
                    location: "KeystrokeMonitor.countMouseScrollBumpIfNeeded",
                    message: "mouse_bump_suppressed_by_trackpad_window",
                    data: ["trackpadAgoMs": Int(trackpadAgo * 1000)]
                )
            }
            // #endregion
            return
        }
        let bumps = takeScrollBumpsAcceptingDiscrete(timestamp: timestamp)
        if bumps > 0 {
            // #region agent log
            if debugMouseRouteLogCount <= 40 {
                agentDebugLog(
                    hypothesisId: "E",
                    location: "KeystrokeMonitor.countMouseScrollBumpIfNeeded",
                    message: "mouse_bump_counted",
                    data: ["bumps": bumps, "runId": "post-fix"]
                )
            }
            // #endregion
            onScrollBumps?(bumps)
        }
    }

    /// Continuous/precise mouse wheels: prefer line ticks (1 bump), else quantize point deltas.
    private func countContinuousMouseScrollBumpIfNeeded(
        decision: ScrollClassification,
        timestamp: CGEventTimestamp
    ) {
        scrollLock.lock()
        let trackpadAgo = CFAbsoluteTimeGetCurrent() - lastTrackpadScrollAt
        scrollLock.unlock()
        if trackpadAgo < Self.trackpadScrollCompanionWindow {
            return
        }

        let hasLine = decision.line1 != 0 || decision.line2 != 0
        if hasLine {
            // Same 50ms dedupe as discrete notches so continuous+discrete companions ≠ ×2.
            countMouseScrollBumpIfNeeded(timestamp: timestamp)
            return
        }

        let points = (decision.point1.isFinite ? abs(decision.point1) : 0)
            + (decision.point2.isFinite ? abs(decision.point2) : 0)
        guard points > 0.5 else { return }

        scrollLock.lock()
        mouseContinuousPointAccumulator += points
        let bumps = Int(mouseContinuousPointAccumulator / Self.mouseScrollPointsPerBump)
        guard bumps > 0 else {
            scrollLock.unlock()
            return
        }
        mouseContinuousPointAccumulator -= Double(bumps) * Self.mouseScrollPointsPerBump
        lastScrollBumpMediaTime = CFAbsoluteTimeGetCurrent()
        lastScrollEventTimestamp = timestamp
        let capped = min(bumps, 8)
        scrollLock.unlock()
        onScrollBumps?(capped)
    }

    private static func planarTravelIncrement(from event: CGEvent) -> Double {
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance > 0 else { return 0 }
        return distance
    }

    /// Prefer AppKit scrolling deltas; fall back to CG point / fixed-point fields.
    /// Applies `trackpadScrollTravelScale` so pad-stroke magnitude ≈ pointer travel.
    private static func scrollTravelPixels(from event: CGEvent) -> Double {
        let raw: Double
        if let nsEvent = NSEvent(cgEvent: event) {
            let fromNS = abs(nsEvent.scrollingDeltaX) + abs(nsEvent.scrollingDeltaY)
            if fromNS.isFinite, fromNS > 0 {
                raw = fromNS
            } else {
                raw = 0
            }
        } else {
            raw = 0
        }
        let unscaled: Double
        if raw > 0 {
            unscaled = raw
        } else {
            let point1 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let point2 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let fromPoints = (point1.isFinite ? abs(point1) : 0) + (point2.isFinite ? abs(point2) : 0)
            if fromPoints > 0 {
                unscaled = fromPoints
            } else {
                let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                let fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
                let fromFixed = (fixed1.isFinite ? abs(fixed1) : 0) + (fixed2.isFinite ? abs(fixed2) : 0)
                if fromFixed > 0 {
                    unscaled = fromFixed
                } else {
                    let line1 = abs(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                    let line2 = abs(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
                    let lines = Double(line1 + line2)
                    unscaled = lines > 0 ? lines * 10.0 : 0
                }
            }
        }
        guard unscaled > 0 else { return 0 }
        return unscaled * Self.trackpadScrollTravelScale
    }

    /// Discrete mouse-wheel notches only (after companion-suppress delay).
    private func takeScrollBumpsAcceptingDiscrete(timestamp: CGEventTimestamp) -> Int {
        scrollLock.lock()
        defer { scrollLock.unlock() }

        if CFAbsoluteTimeGetCurrent() - lastTrackpadScrollAt < Self.trackpadScrollCompanionWindow {
            return 0
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastScrollBumpMediaTime < Self.scrollDuplicateWindow {
            return 0
        }
        if lastScrollEventTimestamp != 0, timestamp >= lastScrollEventTimestamp {
            let deltaNs = timestamp - lastScrollEventTimestamp
            if deltaNs < Self.scrollDuplicateWindowNs {
                return 0
            }
        }

        lastScrollBumpMediaTime = now
        lastScrollEventTimestamp = timestamp
        return 1
    }

    private func accumulateTravelPixels(from event: CGEvent) {
        let increment = Self.planarTravelIncrement(from: event)
        guard increment > 0 else { return }
        travelLock.lock()
        bufferedTravelPixels += increment
        travelLock.unlock()
    }

    private func accumulateBuiltinTrackpadTravelPixels(from event: CGEvent) {
        let increment = Self.planarTravelIncrement(from: event)
        guard increment > 0 else { return }
        builtinTrackpadTravelLock.lock()
        bufferedBuiltinTrackpadTravelPixels += increment
        builtinTrackpadTravelLock.unlock()
    }

    private func accumulateBuiltinTrackpadScrollPixels(from event: CGEvent) {
        let increment = Self.scrollTravelPixels(from: event)
        guard increment > 0 else { return }
        builtinTrackpadScrollLock.lock()
        bufferedBuiltinTrackpadScrollPixels += increment
        builtinTrackpadScrollLock.unlock()
    }

    private func flushBufferedPixelsIfNeeded() {
        travelLock.lock()
        let pendingTravel = bufferedTravelPixels
        bufferedTravelPixels = 0
        travelLock.unlock()
        if pendingTravel > 0 {
            onBufferedTravelPixels?(pendingTravel)
        }

        builtinTrackpadTravelLock.lock()
        let pendingBuiltinTravel = bufferedBuiltinTrackpadTravelPixels
        bufferedBuiltinTrackpadTravelPixels = 0
        builtinTrackpadTravelLock.unlock()
        if pendingBuiltinTravel > 0 {
            onBufferedBuiltinTrackpadTravelPixels?(pendingBuiltinTravel)
        }

        builtinTrackpadScrollLock.lock()
        let pendingBuiltinScroll = bufferedBuiltinTrackpadScrollPixels
        bufferedBuiltinTrackpadScrollPixels = 0
        builtinTrackpadScrollLock.unlock()
        if pendingBuiltinScroll > 0 {
            onBufferedBuiltinTrackpadScrollPixels?(pendingBuiltinScroll)
        }
    }

    private func scheduleFlushTimer() {
        cancelFlushTimer()
        let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.flushBufferedPixelsIfNeeded()
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
