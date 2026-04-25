import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @StateObject private var viewModel = MacDashboardViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text("HandTrack Mac")
                        .font(.largeTitle.bold())
                    Text(viewModel.syncStatus)
                        .foregroundStyle(.secondary)
                    Text("On iPhone, enter this Mac's Wi-Fi IP or hostname. Sync uses port 8787.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open Data Folder") {
                    store.openStorageDirectory()
                }
            }

            HStack(spacing: 16) {
                StatCard(title: "Keys This Hour", value: "\(store.keysSinceStartOfCurrentHour())")
                StatCard(title: "Average WPM", value: String(format: "%.1f", store.averageWordsPerMinuteForCurrentHour()))
                StatCard(title: "iOS Logs", value: "\(store.hourlyLogs.count)")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Keystrokes")
                    .font(.headline)
                StaticKeystrokeBarPlot()
                Text("12 five-minute intervals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

private struct StaticKeystrokeBarPlot: View {
    private let barHeights: [CGFloat] = [2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(index == barHeights.indices.last ? .blue : .secondary)
                        .frame(height: height)
                        .opacity(0.25)

                    Text(label(for: index))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 120)
        .padding(.vertical, 6)
    }

    private func label(for index: Int) -> String {
        index == barHeights.indices.last ? "now" : ""
    }
}
