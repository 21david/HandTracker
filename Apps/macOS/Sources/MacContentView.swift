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

                VStack(spacing: 8) {
                    Text("Keystrokes")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
                    MacKeystrokeFiveMinuteChart()
                }

                VStack(spacing: 8) {
                    Text("Mouse clicks")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
                    MacMouseClickFiveMinuteChart()
                }

                VStack(spacing: 8) {
                    Text("Pointer travel")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
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
        .frame(minWidth: 800, idealWidth: 880, maxWidth: .infinity)
        .frame(minHeight: 940, idealHeight: 980, maxHeight: .infinity)
        .onAppear {
            viewModel.start(store: store)
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
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

    /// Refreshes expiry so mute label disappears when time is up (~10 s Timeline ticks).
    @ViewBuilder
    private func muteControls(now: Date) -> some View {
        let _ = viewModel.refreshExpiredMuteIfNeeded(now: now)

        let until = viewModel.recordingAlarmMuteExpiresAt
        let activeMute = until.map { $0 > now } ?? false

        HStack(spacing: 10) {
            if activeMute, let expiry = until, expiry > now {
                Text("Muted until \(Self.muteTimeFormatter.string(from: expiry))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("Mute 5 min") {
                viewModel.muteBreakAlarms(minutes: 5)
            }
            .buttonStyle(.bordered)
            .help("Silence overload dings for five minutes")

            Button("Mute 15 min") {
                viewModel.muteBreakAlarms(minutes: 15)
            }
            .buttonStyle(.bordered)
            .help("Silence overload dings for fifteen minutes")

            Button("Mute 1 hr") {
                viewModel.muteBreakAlarms(minutes: 60)
            }
            .buttonStyle(.bordered)
            .help("Silence overload dings for one hour")
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
