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

    static func menuTitle(prefix: String, totalMinutes: Int) -> String {
        "\(prefix): \(formattedHoursAndMinutes(totalMinutes: totalMinutes))"
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

// MARK: - Custom popup (reliable white text; NSMenu items often render disabled/gray)

private struct MacUsageBreakdownPopupView: View {
    let keyboardMinutes: Int
    let mouseMinutes: Int
    let totalMinutes: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(prefix: "Keyboard", minutes: keyboardMinutes)
            row(prefix: "Mouse", minutes: mouseMinutes)
            Divider()
                .overlay(Color.white.opacity(0.25))
            row(prefix: "Total", minutes: totalMinutes)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 0.96)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    private func row(prefix: String, minutes: Int) -> some View {
        Button {
            onSelect(minutes)
        } label: {
            Text(MacUsageBreakdownClipboard.menuTitle(prefix: prefix, totalMinutes: minutes))
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

@MainActor
final class MacUsageBreakdownPopupPresenter {
    static let shared = MacUsageBreakdownPopupPresenter()

    private var panel: NSPanel?
    private var localDismissMonitor: Any?
    private var globalDismissMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    func show(keyboardMinutes: Int, mouseMinutes: Int) {
        dismiss()

        let totalMinutes = keyboardMinutes + mouseMinutes
        let rootView = MacUsageBreakdownPopupView(
            keyboardMinutes: keyboardMinutes,
            mouseMinutes: mouseMinutes,
            totalMinutes: totalMinutes,
            onSelect: { minutes in
                MacUsageBreakdownClipboard.copyMinutesValue(minutes)
                self.dismiss()
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x + 2, y: mouse.y - size.height - 2)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel

        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            self?.dismissIfClickOutsidePopup()
            return event
        }
        // Clicks in other apps never reach the local monitor.
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            self?.dismiss()
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismissIfClickOutsidePopup() {
        guard let panel else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) {
            dismiss()
        }
    }

    func dismiss() {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
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
            mouseMinutes: region.mouseMinutes
        )
    }
}

struct MacUsageBreakdownHitRegion: Equatable {
    let frame: CGRect
    let keyboardMinutes: Int
    let mouseMinutes: Int
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
