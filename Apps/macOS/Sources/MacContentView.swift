import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @StateObject private var viewModel = MacDashboardViewModel()
    @State private var showSyncInfo = false

    private static let muteTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBar

                HStack(spacing: 16) {
                    StatCard(title: "Keys This Hour", value: "\(store.keysSinceStartOfCurrentHour())")
                    StatCard(title: "Clicks This Hour", value: "\(store.clicksSinceStartOfCurrentHour())")
                    StatCard(title: "Pointer travel", value: formatTravelStat(store.mouseTravelPixelsSinceStartOfCurrentHour()))
                    StatCard(title: "Average WPM", value: String(format: "%.1f", store.averageWordsPerMinuteForCurrentHour()))
                }

                MacKeystrokeFiveMinuteChart()
                MacMouseClickFiveMinuteChart()
                MacMouseTravelFiveMinuteChart()

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent iOS Logs")
                        .font(.headline)

                    if store.hourlyLogs.isEmpty {
                        Text("No iPhone logs received yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        List(store.hourlyLogs.prefix(8)) { log in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(log.createdAt.displayTime) · \(log.hourStart.displayHourBucket)")
                                    .font(.headline)
                                Text(
                                    "L \(log.painLevelLeft.handTrackPainCompactLabel), R \(log.painLevelRight.handTrackPainCompactLabel); \(log.minutesHandsUsed) min"
                                )
                                    .foregroundStyle(.secondary)
                                if !log.journalEntry.isEmpty {
                                    Text(log.journalEntry)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: 220)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 900, idealWidth: 960, maxWidth: .infinity)
        .frame(minHeight: 940, idealHeight: 980, maxHeight: .infinity)
        .onAppear {
            viewModel.start(store: store)
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                showSyncInfo.toggle()
            } label: {
                Label("Sync & iPhone", systemImage: "info.circle")
            }
            .buttonStyle(.bordered)
            .help("Wi‑Fi sync details and HandTrack mobile setup")
            .popover(isPresented: $showSyncInfo, attachmentAnchor: .point(.bottom), arrowEdge: .bottom) {
                syncInfoPopover
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 10)) { timeline in
                muteControls(now: timeline.date)
            }

            Button("Open Data Folder") {
                store.openStorageDirectory()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum MuteInterval: Int, CaseIterable, Identifiable {
        case five = 5
        case ten = 10
        case fifteen = 15
        case thirty = 30
        case oneHour = 60
        case threeHours = 180
        case sixHours = 360

        var id: Int { rawValue }

        var shortLabel: String {
            switch self {
            case .five: return "5m"
            case .ten: return "10m"
            case .fifteen: return "15m"
            case .thirty: return "30m"
            case .oneHour: return "1h"
            case .threeHours: return "3h"
            case .sixHours: return "6h"
            }
        }

        var help: String {
            switch self {
            case .five: return "Silence break-alarm sounds for 5 minutes."
            case .ten: return "Silence break-alarm sounds for 10 minutes."
            case .fifteen: return "Silence break-alarm sounds for 15 minutes."
            case .thirty: return "Silence break-alarm sounds for 30 minutes."
            case .oneHour: return "Silence break-alarm sounds for 1 hour."
            case .threeHours: return "Silence break-alarm sounds for 3 hours."
            case .sixHours: return "Silence break-alarm sounds for 6 hours."
            }
        }
    }

    /// Refreshes expiry so mute label disappears when time is up (~10 s Timeline ticks).
    @ViewBuilder
    private func muteControls(now: Date) -> some View {
        let _ = viewModel.refreshExpiredMuteIfNeeded(now: now)

        let until = viewModel.recordingAlarmMuteExpiresAt
        let activeMute = until.map { $0 > now } ?? false

        VStack(alignment: .leading, spacing: 8) {
            if activeMute, let expiry = until, expiry > now {
                Text("Muted until \(Self.muteTimeFormatter.string(from: expiry))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .center, spacing: 10) {
                Text("Mute")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(MuteInterval.allCases) { interval in
                        Button {
                            viewModel.muteBreakAlarms(minutes: interval.rawValue)
                        } label: {
                            Text(interval.shortLabel)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .tracking(0.25)
                                .minimumScaleFactor(0.8)
                                .lineLimit(1)
                        }
                        .buttonStyle(MuteDurationPillStyle())
                        .help(interval.help)
                    }

                    Button {
                        viewModel.clearBreakAlarmMute()
                    } label: {
                        Text("Unmute")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .tracking(0.2)
                            .minimumScaleFactor(0.85)
                            .lineLimit(1)
                    }
                    .buttonStyle(UnmutePillButtonStyle())
                    .disabled(!activeMute)
                    .opacity(activeMute ? 1 : 0.42)
                    .help(activeMute ? "Resume break alarms immediately." : "Timers are not muted.")
                }
            }
        }
    }

    private var syncInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync from iPhone")
                .font(.headline)
            Text(
                """
                Open HandTrack on your iPhone and enter this Mac’s hostname \
                (e.g. My-Mac.local) or its LAN IP (e.g. 192.168.1.23). Keep both \
                devices on the same Wi-Fi.
                """
            )
            .font(.body)
            Text(
                """
                While this Mac app is open it listens on port 8787. If the phone \
                can’t reach it, double-check Firewall settings.
                """
            )
                .font(.body)
                .foregroundStyle(.secondary)

            Divider()

            Text(viewModel.syncStatus)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Button("Done") {
                showSyncInfo = false
            }
        }
        .padding(16)
        .frame(minWidth: 380, alignment: .leading)
    }

    private func formatTravelStat(_ pixels: Double) -> String {
        guard pixels.isFinite else { return "—" }
        if pixels >= 1_000_000 {
            return String(format: "%.1fM px", pixels / 1_000_000)
        }
        if pixels >= 10_000 {
            return String(format: "%.0fk px", pixels / 1_000)
        }
        if pixels >= 1_000 {
            return String(format: "%.1fk px", pixels / 1_000)
        }
        return String(format: "%.0f px", pixels)
    }
}

// MARK: - Mute controls (pill + soft 3D)

private struct MuteDurationPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.88 : 0.98))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.38, green: 0.58, blue: 0.98),
                                    Color(red: 0.16, green: 0.35, blue: 0.78),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.38), Color.clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.55)
                            )
                        )
                        .padding(1)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.55),
                                    Color.black.opacity(0.22),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.28), radius: configuration.isPressed ? 1 : 3, x: 0, y: configuration.isPressed ? 0 : 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct UnmutePillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.88 : 0.98) : 0.55)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: isEnabled
                                    ? [
                                        Color(red: 0.22, green: 0.72, blue: 0.48),
                                        Color(red: 0.08, green: 0.48, blue: 0.32),
                                    ]
                                    : [
                                        Color(red: 0.28, green: 0.32, blue: 0.36),
                                        Color(red: 0.16, green: 0.18, blue: 0.22),
                                    ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(isEnabled ? 0.32 : 0.12), Color.clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.55)
                            )
                        )
                        .padding(1)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isEnabled ? 0.45 : 0.2),
                                    Color.black.opacity(0.2),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: .black.opacity(isEnabled ? 0.26 : 0.12),
                    radius: configuration.isPressed ? 1 : 3,
                    x: 0,
                    y: configuration.isPressed ? 0 : 2
                )
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
