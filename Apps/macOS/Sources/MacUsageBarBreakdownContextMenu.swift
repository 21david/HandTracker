import AppKit
import SwiftUI

enum MacUsageBreakdownClipboard {
    /// Spoken label, e.g. `2 hours 38 minutes` or `45 minutes`.
    static func formattedHoursAndMinutes(totalMinutes: Int) -> String {
        let clamped = max(0, totalMinutes)
        let hours = clamped / 60
        let minutes = clamped % 60

        switch (hours, minutes) {
        case (0, 0):
            return "0 minutes"
        case (0, 1):
            return "1 minute"
        case (0, _):
            return "\(minutes) minutes"
        case (1, 0):
            return "1 hour"
        case (1, 1):
            return "1 hour 1 minute"
        case (1, _):
            return "1 hour \(minutes) minutes"
        case (_, 0):
            return "\(hours) hours"
        case (_, 1):
            return "\(hours) hours 1 minute"
        default:
            return "\(hours) hours \(minutes) minutes"
        }
    }

    /// When hours are present, copies only the minutes component (e.g. 2h 38m → `38`); otherwise copies total minutes.
    static func minutesValueForClipboard(totalMinutes: Int) -> Int {
        let clamped = max(0, totalMinutes)
        let hours = clamped / 60
        let minutes = clamped % 60
        if hours > 0 {
            return minutes
        }
        return clamped
    }

    static func copyMinutesValue(_ totalMinutes: Int) {
        let value = minutesValueForClipboard(totalMinutes: totalMinutes)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(value), forType: .string)
    }
}

extension Notification.Name {
    /// Posted when the day-bar breakdown popup asks to open the 24-hour detail screen.
    /// `userInfo["dayStart"]` is the hand-tracking day start (`Date`).
    static let handTrackOpenHourlyDayDetail = Notification.Name("HandTrack.openHourlyDayDetail")
}

// MARK: - Custom popup (reliable white text; NSMenu items often render disabled/gray)

private enum MacUsageBreakdownPopupLayout {
    static let screenEdgeMargin: CGFloat = 8
}

private struct MacUsageBreakdownPopupView: View {
    let keyboardMinutes: Int
    let mouseMinutes: Int
    let macbookKeyboardMinutes: Int?
    let macbookTrackpadMinutes: Int?
    /// Grand total: keyboards (external + MacBook) + mouse + trackpad.
    let totalMinutes: Int
    /// When set (day bars on the 12-day chart), show “See hourly graphs” under Total.
    let handTrackingDayStart: Date?
    let onSelect: (Int) -> Void
    let onClose: () -> Void
    let onSeeHourlyGraphs: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Reserve trailing room for ✕ on the first line only so dividers stay full-width.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                row(prefix: "External keyboard", minutes: keyboardMinutes)
                Color.clear.frame(width: 16, height: 1)
            }
            row(prefix: "External mouse", minutes: mouseMinutes)

            if macbookKeyboardMinutes != nil || macbookTrackpadMinutes != nil {
                rule
                if let macbookKeyboardMinutes {
                    row(prefix: "MacBook keyboard", minutes: macbookKeyboardMinutes)
                }
                if let macbookTrackpadMinutes {
                    row(prefix: "MacBook trackpad", minutes: macbookTrackpadMinutes)
                }
            }

            rule
            row(prefix: "Total", minutes: totalMinutes)

            if handTrackingDayStart != nil, let onSeeHourlyGraphs {
                Button(action: onSeeHourlyGraphs) {
                    Text("See hourly graphs")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: NSColor(calibratedRed: 0.45, green: 0.78, blue: 1.0, alpha: 1)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .help("Open all 24 hours for this hand-tracking day")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 0.96)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.25))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private func row(prefix: String, minutes: Int) -> some View {
        Button {
            onSelect(minutes)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(prefix): ")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Text(MacUsageBreakdownClipboard.formattedHoursAndMinutes(totalMinutes: minutes))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
    }
}

@MainActor
final class MacUsageBreakdownPopupPresenter {
    static let shared = MacUsageBreakdownPopupPresenter()

    private var panel: NSPanel?
    private var escapeLocalMonitor: Any?
    private var escapeGlobalMonitor: Any?

    /// MacBook rows appear only when each is ≥ 5 minutes; omit both + their divider when neither qualifies.
    /// Total is always at the bottom: keyboards (external + MacBook) + mouse + trackpad.
    /// Stays open across app switches; drag anywhere; close with ✕ or Escape.
    /// Pass `handTrackingDayStart` for 12-day bars to offer “See hourly graphs”.
    func show(
        keyboardMinutes: Int,
        mouseMinutes: Int,
        macbookKeyboardMinutes: Int = 0,
        macbookTrackpadMinutes: Int = 0,
        handTrackingDayStart: Date? = nil
    ) {
        dismiss()

        let showMacKeyboard = macbookKeyboardMinutes >= 5
        let showMacTrackpad = macbookTrackpadMinutes >= 5
        let keyboardsMinutes = keyboardMinutes + macbookKeyboardMinutes
        let totalMinutes = keyboardsMinutes + mouseMinutes + macbookTrackpadMinutes
        let dayStart = handTrackingDayStart
        let rootView = MacUsageBreakdownPopupView(
            keyboardMinutes: keyboardMinutes,
            mouseMinutes: mouseMinutes,
            macbookKeyboardMinutes: showMacKeyboard ? macbookKeyboardMinutes : nil,
            macbookTrackpadMinutes: showMacTrackpad ? macbookTrackpadMinutes : nil,
            totalMinutes: totalMinutes,
            handTrackingDayStart: dayStart,
            onSelect: { minutes in
                MacUsageBreakdownClipboard.copyMinutesValue(minutes)
            },
            onClose: { [weak self] in
                self?.dismiss()
            },
            onSeeHourlyGraphs: dayStart.map { start in
                { [weak self] in
                    self?.dismiss()
                    NotificationCenter.default.post(
                        name: .handTrackOpenHourlyDayDetail,
                        object: nil,
                        userInfo: ["dayStart": start]
                    )
                }
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let mouse = NSEvent.mouseLocation
        let preferred = NSPoint(x: mouse.x + 2, y: mouse.y - size.height - 2)
        let origin = Self.clampedOrigin(preferred: preferred, size: size, near: mouse)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Above normal windows on every display; user can drag across monitors freely.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        installEscapeMonitors()
    }

    /// Keep the popup fully inside the screen’s visible frame on first show (menu bar / dock inset).
    /// After that, the user can drag it anywhere — including onto other monitors.
    private static func clampedOrigin(preferred: NSPoint, size: NSSize, near point: NSPoint) -> NSPoint {
        let margin = MacUsageBreakdownPopupLayout.screenEdgeMargin
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return preferred }

        let visible = screen.visibleFrame
        var x = preferred.x
        var y = preferred.y

        if x + size.width > visible.maxX - margin {
            x = visible.maxX - size.width - margin
        }
        if x < visible.minX + margin {
            x = visible.minX + margin
        }

        if y < visible.minY + margin {
            let above = point.y + margin
            if above + size.height <= visible.maxY - margin {
                y = above
            } else {
                y = visible.minY + margin
            }
        }
        if y + size.height > visible.maxY - margin {
            y = visible.maxY - size.height - margin
        }
        if y < visible.minY + margin {
            y = visible.minY + margin
        }

        return NSPoint(x: x, y: y)
    }

    private func installEscapeMonitors() {
        removeEscapeMonitors()
        let handleEscape: (NSEvent) -> NSEvent? = { [weak self] event in
            // 53 = Escape
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handleEscape)
        // Nonactivating panel + other apps focused: still allow Escape to dismiss.
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async { self?.dismiss() }
        }
    }

    private func removeEscapeMonitors() {
        if let escapeLocalMonitor {
            NSEvent.removeMonitor(escapeLocalMonitor)
            self.escapeLocalMonitor = nil
        }
        if let escapeGlobalMonitor {
            NSEvent.removeMonitor(escapeGlobalMonitor)
            self.escapeGlobalMonitor = nil
        }
    }

    func dismiss() {
        removeEscapeMonitors()
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Right-click capture layer

final class MacUsageBreakdownRightClickCaptureView: NSView {
    var regions: [MacUsageBreakdownHitRegion] = []
    override var isFlipped: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let region = regions.first(where: { $0.frame.contains(point) }) else {
            super.rightMouseDown(with: event)
            return
        }
        MacUsageBreakdownPopupPresenter.shared.show(
            keyboardMinutes: region.keyboardMinutes,
            mouseMinutes: region.mouseMinutes,
            macbookKeyboardMinutes: region.macbookKeyboardMinutes,
            macbookTrackpadMinutes: region.macbookTrackpadMinutes,
            handTrackingDayStart: region.handTrackingDayStart
        )
    }
}

struct MacUsageBreakdownHitRegion: Equatable {
    let frame: CGRect
    let keyboardMinutes: Int
    let mouseMinutes: Int
    var macbookKeyboardMinutes: Int = 0
    var macbookTrackpadMinutes: Int = 0
    /// Set for 12-day chart bars so the popup can offer hourly drill-in.
    var handTrackingDayStart: Date? = nil
}

struct MacUsageBreakdownRightClickLayer: NSViewRepresentable {
    let regions: [MacUsageBreakdownHitRegion]

    func makeNSView(context: Context) -> MacUsageBreakdownRightClickCaptureView {
        MacUsageBreakdownRightClickCaptureView()
    }

    func updateNSView(_ nsView: MacUsageBreakdownRightClickCaptureView, context: Context) {
        nsView.regions = regions
    }
}
