import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @StateObject private var viewModel = MacDashboardViewModel()
    @State private var exportStatus = ""

    var body: some View {
        let recentBuckets = store.keystrokeBuckets(
            from: Date().addingTimeInterval(-60 * 60),
            to: Date(),
            interval: 5 * 60
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("HandTrack Mac")
                            .font(.largeTitle.bold())
                        Text(viewModel.syncStatus)
                            .foregroundStyle(.secondary)
                        Text("If key counts do not change, enable Input Monitoring for this app or Xcode, then rerun.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("On iPhone, enter this Mac's Wi-Fi IP or hostname. Sync uses port 8787.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack {
                        Button("Export CSV") {
                            exportCSV()
                        }

                        Button("Open Data Folder") {
                            store.openStorageDirectory()
                        }
                    }
                }

                HStack(spacing: 16) {
                    StatCard(title: "Keys This Hour", value: "\(store.keysSinceStartOfCurrentHour())")
                    StatCard(title: "Average WPM", value: String(format: "%.1f", store.averageWordsPerMinuteForCurrentHour()))
                    StatCard(title: "iOS Logs", value: "\(store.hourlyLogs.count)")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Keystrokes Last Hour")
                        .font(.headline)
                    KeystrokeBarChart(buckets: recentBuckets)
                    Text("5-minute buckets. Older raw keystrokes are kept for one year, then compacted into hourly summaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !exportStatus.isEmpty {
                    Text(exportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent iOS Logs")
                        .font(.headline)

                    if store.hourlyLogs.isEmpty {
                        Text("No iPhone logs received yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        List(store.recentHourlyLogs(limit: 8)) { log in
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
                        .frame(minHeight: 240)
                    }
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(minWidth: 820, minHeight: 700)
        .onAppear {
            viewModel.start(store: store)
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private func exportCSV() {
        do {
            let exportDirectory = try store.exportCSVFiles()
            exportStatus = "Exported CSV files to \(exportDirectory.lastPathComponent)"
            store.openDirectory(exportDirectory)
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
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

private struct KeystrokeBarChart: View {
    let buckets: [KeystrokeBucket]

    private var maxCount: Int {
        max(buckets.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(buckets) { bucket in
                VStack(spacing: 4) {
                    Text("\(bucket.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 3)
                        .frame(height: barHeight(for: bucket.count))
                        .foregroundStyle(.blue)
                    Text(bucket.start.displayTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(-45))
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150)
        .padding(.vertical, 8)
    }

    private func barHeight(for count: Int) -> CGFloat {
        max(CGFloat(count) / CGFloat(maxCount) * 90, count == 0 ? 2 : 8)
    }
}
