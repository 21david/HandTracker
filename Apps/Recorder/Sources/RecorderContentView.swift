import SwiftUI

struct RecorderContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @StateObject private var viewModel = RecorderViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HandTrack Recorder")
                    .font(.largeTitle.bold())
                Text(viewModel.status)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                RecorderStatCard(title: "Keys This Hour", value: "\(viewModel.keysThisHour)")
                RecorderStatCard(title: "Average WPM", value: String(format: "%.1f", viewModel.averageWPM))
            }

            Divider()

            Text("This app is the stable key recorder. The dashboard can change later without changing this permission-bearing target.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Refresh Stats") {
                    viewModel.refreshStats()
                }

                Button("Open Data Folder") {
                    store.openStorageDirectory()
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear {
            viewModel.start(store: store)
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

private struct RecorderStatCard: View {
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
