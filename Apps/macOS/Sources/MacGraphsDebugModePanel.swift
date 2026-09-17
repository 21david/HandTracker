import AppKit
import SwiftUI

// =============================================================================
// for debugging/testing - deletable
// Entire file (plus `HandTrackLivePulse.noteDebug` / store `noteDebug` calls) can
// be removed once graphs registration testing is done.
// =============================================================================

/// Floating 2×4 activity grid that stays open until dismissed. Session totals reset on each open.
@MainActor
enum MacGraphsDebugModePresenter {
    static let shared = MacGraphsDebugModePanelController()
}

@MainActor
final class MacGraphsDebugModePanelController {
    private var panel: NSPanel?

    func show(livePulse: HandTrackLivePulse) {
        dismiss()
        HandTrackLivePulse.debugPanelActive = true

        let root = MacGraphsDebugModeRootView(
            livePulse: livePulse,
            onClose: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: root)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = max(640, visible.width * 0.72)
        let height = max(420, visible.height * 0.70)
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2
        )

        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        HandTrackLivePulse.debugPanelActive = false
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct MacGraphsDebugModeRootView: View {
    let livePulse: HandTrackLivePulse
    let onClose: () -> Void

    var body: some View {
        MacGraphsDebugModeContent(livePulse: livePulse, onClose: onClose)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .padding(10)
    }
}

private struct MacGraphsDebugModeContent: View {
    let livePulse: HandTrackLivePulse
    let onClose: () -> Void

    @State private var totals: [HandTrackLivePulse.Kind: Double] = [:]
    @State private var flashing: Set<HandTrackLivePulse.Kind> = []
    @State private var lastSeenTickID: UInt64 = 0
    @State private var flashClearTasks: [HandTrackLivePulse.Kind: Task<Void, Never>] = [:]

    private let externalKinds: [HandTrackLivePulse.Kind] = [
        .keystrokes, .mouseClicks, .scrollBumps, .mouseTravel,
    ]
    private let macbookKinds: [HandTrackLivePulse.Kind] = [
        .builtinKeystrokes, .builtinTrackpadClicks, .builtinTrackpadScroll, .builtinTrackpadTravel,
    ]

    var body: some View {
        let _ = livePulse.debugTickID
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text("Graphs debug")
                    .font(.headline)
                Text("for debugging/testing — deletable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close debug panel")
            }

            Text("External")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            tileRow(kinds: externalKinds)

            Text("MacBook")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            tileRow(kinds: macbookKinds)
        }
        .padding(20)
        .onAppear {
            totals = [:]
            flashing = []
            lastSeenTickID = livePulse.debugTickID
        }
        .onDisappear {
            for task in flashClearTasks.values { task.cancel() }
            flashClearTasks.removeAll()
        }
        .onChange(of: livePulse.debugTickID) { _, newID in
            guard newID != lastSeenTickID, let tick = livePulse.lastDebugTick, tick.id == newID else { return }
            lastSeenTickID = newID
            totals[tick.kind, default: 0] += tick.amount
            flashing.insert(tick.kind)
            flashClearTasks[tick.kind]?.cancel()
            flashClearTasks[tick.kind] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled else { return }
                flashing.remove(tick.kind)
                flashClearTasks[tick.kind] = nil
            }
        }
    }

    private func tileRow(kinds: [HandTrackLivePulse.Kind]) -> some View {
        HStack(spacing: 12) {
            ForEach(kinds, id: \.self) { kind in
                MacGraphsDebugTile(
                    title: Self.title(for: kind),
                    valueText: Self.format(totals[kind, default: 0], kind: kind),
                    baseColor: Self.color(for: kind),
                    isFlashing: flashing.contains(kind)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func title(for kind: HandTrackLivePulse.Kind) -> String {
        switch kind {
        case .keystrokes: return "Keys"
        case .mouseClicks: return "Clicks"
        case .scrollBumps: return "Scrolls"
        case .mouseTravel: return "Px traveled"
        case .builtinKeystrokes: return "Keys"
        case .builtinTrackpadClicks: return "Clicks"
        case .builtinTrackpadScroll: return "Scroll travel"
        case .builtinTrackpadTravel: return "Px traveled"
        }
    }

    private static func color(for kind: HandTrackLivePulse.Kind) -> Color {
        switch kind {
        case .keystrokes, .builtinKeystrokes:
            return Color(red: 0.86, green: 0.28, blue: 0.28)
        case .mouseClicks, .builtinTrackpadClicks:
            return Color(red: 0.18, green: 0.68, blue: 0.55)
        case .scrollBumps, .builtinTrackpadScroll:
            return Color(red: 0.95, green: 0.55, blue: 0.18)
        case .mouseTravel, .builtinTrackpadTravel:
            return Color(red: 0.55, green: 0.35, blue: 0.85)
        }
    }

    private static func format(_ value: Double, kind: HandTrackLivePulse.Kind) -> String {
        switch kind {
        case .mouseTravel, .builtinTrackpadTravel, .builtinTrackpadScroll:
            return formatPixels(value)
        default:
            let n = Int(value.rounded(.towardZero))
            if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
            if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
            return "\(n)"
        }
    }

    private static func formatPixels(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", value / 1000) }
        return String(format: "%.0f", value)
    }
}

private struct MacGraphsDebugTile: View {
    let title: String
    let valueText: String
    let baseColor: Color
    let isFlashing: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(baseColor.opacity(isFlashing ? 0.95 : 0.55))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isFlashing ? 0.35 : 0.08),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: isFlashing)
        .shadow(color: baseColor.opacity(isFlashing ? 0.55 : 0.15), radius: isFlashing ? 14 : 4, y: 2)
    }
}
