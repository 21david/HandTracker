import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @StateObject private var viewModel = MacDashboardViewModel()
    @State private var chartNow = Date()

    private let chartRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let buckets = store.keystrokeBuckets(endingAtCurrentBucketFor: chartNow)

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
                Text("Keystrokes Last 12 Hours")
                    .font(.headline)
                KeystrokeBarChart(buckets: buckets)
                Text("5-minute buckets, fixed scale: 300 words")
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
        .onReceive(chartRefreshTimer) { now in
            chartNow = now
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

private struct KeystrokeBarChart: View {
    let buckets: [KeystrokeBucket]

    private let maxKeystrokes = 1_500
    private let maxBarHeight: CGFloat = 120

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index == buckets.indices.last ? .blue : .secondary)
                        .frame(height: barHeight(for: bucket.count))
                        .opacity(bucket.count == 0 ? 0.25 : 0.9)

                    if index.isMultiple(of: 12) || index == buckets.indices.last {
                        Text(bucket.start.displayTime)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(-45))
                            .fixedSize()
                    } else {
                        Text("")
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 165)
        .padding(.vertical, 8)
    }

    private func barHeight(for count: Int) -> CGFloat {
        let clampedCount = min(max(count, 0), maxKeystrokes)
        let fraction = CGFloat(clampedCount) / CGFloat(maxKeystrokes)
        return max(fraction * maxBarHeight, count == 0 ? 2 : 4)
    }
}
