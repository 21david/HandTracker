import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @StateObject private var viewModel = MacDashboardViewModel()
    @State private var isShowingSettings = false
    @State private var exportStatus = ""

    var body: some View {
        let bucketInterval: TimeInterval = 5 * 60
        let chartStart = Date().startOfHour
        let chartEnd = max(Date().nextBucketBoundary(interval: bucketInterval), chartStart.addingTimeInterval(bucketInterval))
        let recentBuckets = store.keystrokeBuckets(
            from: chartStart,
            to: chartEnd,
            interval: bucketInterval
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("HandTrack Mac")
                            .font(.largeTitle.bold())
                        Text(viewModel.syncStatus)
                            .foregroundStyle(.secondary)
                        Text(viewModel.keyTrackingStatus)
                            .foregroundStyle(viewModel.needsInputMonitoringPermission ? .orange : .secondary)
                        if viewModel.needsInputMonitoringPermission {
                            HStack {
                                Button("Input Monitoring") {
                                    viewModel.openInputMonitoringSettings()
                                }
                                .buttonStyle(.link)

                                Button("Accessibility") {
                                    viewModel.openAccessibilitySettings()
                                }
                                .buttonStyle(.link)
                            }
                        }
                        Text("On iPhone, enter this Mac's Wi-Fi IP or hostname. Sync uses port 8787.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }
                    .help("Settings")
                }

                if !exportStatus.isEmpty {
                    Text(exportStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    StatCard(title: "Keys This Hour", value: "\(store.keysSinceStartOfCurrentHour())")
                    StatCard(title: "Average WPM", value: String(format: "%.1f", store.averageWordsPerMinuteForCurrentHour()))
                    StatCard(title: "iOS Logs", value: "\(store.hourlyLogs.count)")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Keystrokes This Hour")
                        .font(.headline)
                    KeystrokeBarChart(buckets: recentBuckets)
                    Text("5-minute buckets")
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
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                exportStatus: exportStatus,
                exportCSV: exportCSV,
                openDataFolder: store.openStorageDirectory
            )
        }
    }

    private func exportCSV() {
        do {
            let exportDirectory = try store.exportCSVFiles()
            exportStatus = "Exported to \(exportDirectory.lastPathComponent)"
            store.openDirectory(exportDirectory)
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }
}

private struct SettingsView: View {
    let exportStatus: String
    let exportCSV: () -> Void
    let openDataFolder: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            Button("Export CSV") {
                exportCSV()
            }

            Button("Open Data Folder") {
                openDataFolder()
            }

            if !exportStatus.isEmpty {
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 360, height: 220)
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
