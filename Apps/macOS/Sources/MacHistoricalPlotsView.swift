import AppKit
import SwiftUI

/// All-time histograms via bundled Python (seaborn PNG or plotly HTML).
struct MacHistoricalPlotsView: View {
    @EnvironmentObject private var store: HandTrackStore
    let onBack: () -> Void

    @State private var selectedMetric: MacHistoricalPlotMetric = .keystrokes
    @State private var selectedEngine: MacHistoricalPlotEngine = .seaborn
    @State private var image: NSImage?
    @State private var htmlURL: URL?
    @State private var isRendering = false
    @State private var errorMessage: String?
    @State private var renderToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 16) {
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(MacHistoricalPlotMetric.allCases) { metric in
                        Text(metric.menuTitle).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)

                Picker("Engine", selection: $selectedEngine) {
                    ForEach(MacHistoricalPlotEngine.allCases) { engine in
                        Text(engine.menuTitle).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
                .help("Seaborn: static poster PNG · Plotly: zoom/pan/hover HTML")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            Text(selectedEngine == .plotly
                 ? "Interactive Plotly chart — hover for counts, zoom and pan the axes."
                 : "All-time distribution of each active minute — wide poster from your SQLite history.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            plotCard
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: "\(selectedMetric.rawValue)-\(selectedEngine.rawValue)") {
            await renderSelected()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .help("Return to the main dashboard")

            Spacer(minLength: 8)

            Text("Plots")
                .font(.title2.weight(.semibold))

            Spacer(minLength: 8)

            Button {
                Task { await renderSelected(force: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isRendering)
            .help("Re-run the Python plot against the latest database")
        }
    }

    @ViewBuilder
    private var plotCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))

            if selectedEngine == .plotly, let htmlURL {
                MacPlotHTMLWebView(fileURL: htmlURL)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(6)
            } else if selectedEngine == .seaborn, let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(6)
            } else if isRendering {
                ProgressView(
                    selectedEngine == .plotly
                        ? "Rendering interactive Plotly chart…"
                        : "Rendering with pandas + seaborn…"
                )
                .controlSize(.large)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Text("Couldn’t render plot")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    Button("Try again") {
                        Task { await renderSelected(force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
            }
        }
        .frame(minHeight: 560)
    }

    private func renderSelected(force: Bool = false) async {
        renderToken += 1
        let token = renderToken
        isRendering = true
        errorMessage = nil
        if force {
            image = nil
            htmlURL = nil
        }

        let dbURL = store.storageDirectory.appendingPathComponent("handtrack.sqlite")
        do {
            let url = try await MacHistoricalPlotRenderer.render(
                metric: selectedMetric,
                engine: selectedEngine,
                databaseURL: dbURL,
                force: force
            )
            guard token == renderToken else { return }
            switch selectedEngine {
            case .seaborn:
                htmlURL = nil
                if let nsImage = NSImage(contentsOf: url) {
                    image = nsImage
                } else {
                    errorMessage = "Rendered file could not be opened as an image."
                }
            case .plotly:
                image = nil
                htmlURL = url
            }
        } catch {
            guard token == renderToken else { return }
            errorMessage = error.localizedDescription
            image = nil
            htmlURL = nil
        }
        if token == renderToken {
            isRendering = false
        }
    }
}
