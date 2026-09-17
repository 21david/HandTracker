import AppKit
import SwiftUI

/// Full-window 24-hour view for one hand-tracking day (opened from the 12-day chart).
struct MacDayHourlyUsageDetailView: View {
    @EnvironmentObject private var store: HandTrackStore
    let dayStart: Date
    let onBack: () -> Void

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("Return to the main dashboard")

                Spacer(minLength: 8)

                VStack(spacing: 2) {
                    Text(Self.dayTitleFormatter.string(from: dayStart))
                        .font(.title2.weight(.semibold))
                    Text("24 hours · hand-tracking day (3am–3am)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }

            Text("Same stacked usage + pain format as Past 12 hours. Right-click any hour for a breakdown.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            MacHourlyStackedUsagePainChart(
                store: store,
                mode: .handTrackingDay(dayStart: dayStart),
                title: "All 24 hours",
                chartHeight: 520,
                refreshBucket: 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
