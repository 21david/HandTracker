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
                    StatCard(title: "iOS Logs", value: "\(store.hourlyLogs.count)")
                }

                VStack(spacing: 12) {
                    Text("Keystrokes")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 10)
                    MacKeystrokeFiveMinuteChart()
                }

                VStack(spacing: 12) {
                    Text("Mouse clicks")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 10)
                    MacMouseClickFiveMinuteChart()
                }

                VStack(spacing: 12) {
                    Text("Pointer travel")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 10)
                    MacMouseTravelFiveMinuteChart()
                }

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
                                Text(log.hourStart.displayHour)
                                    .font(.headline)
                                Text("Pain \(log.painLevel), \(log.minutesHandsUsed) min hand use")
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

            HStack(spacing: 8) {
                Text("Mute")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    ForEach(MuteInterval.allCases) { interval in
                        Button(interval.shortLabel) {
                            viewModel.muteBreakAlarms(minutes: interval.rawValue)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(interval.help)
                    }
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
