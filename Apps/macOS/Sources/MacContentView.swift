import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @StateObject private var viewModel = MacDashboardViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Hand Helper")
                        .font(.largeTitle.bold())
                    Text(viewModel.syncStatus)
                        .foregroundStyle(.secondary)
                    Text("On iPhone, enter this Mac's Wi-Fi IP or hostname. Sync uses port 8787.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Mute break alarms", isOn: Binding(
                    get: { viewModel.recordingAlarmsMuted },
                    set: { viewModel.setRecordingAlarmsMuted($0) }
                ))
                .toggleStyle(.switch)
                .help("Silence five-minute overload dings until you turn this off.")

                Button("Open Data Folder") {
                    store.openStorageDirectory()
                }
            }

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

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            viewModel.start(store: store)
        }
        .onDisappear {
            viewModel.stop()
        }
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
                .font(.system(size: 32, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
