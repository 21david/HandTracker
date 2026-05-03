import Charts
import SwiftUI

/// Bar chart for the **current calendar hour**, split into 12 five-minute buckets aligned at :00, :05, …, :55.
struct MacKeystrokeFiveMinuteChart: View {
    @EnvironmentObject private var store: HandTrackStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let slots = store.keystrokesByFiveMinuteSlotsInHour(containing: timeline.date)
            Chart(slots) { slot in
                BarMark(
                    x: .value("slot", slot.slotStart),
                    y: .value("keys", slot.keyCount)
                )
                .foregroundStyle(.blue.opacity(0.85))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: slots.map(\.slotStart)) {
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour().minute(.twoDigits))
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartYAxisLabel("Keystrokes", position: .leading)
            .frame(height: 200)
            .chartPlotStyle { plotArea in
                plotArea.padding(.leading, 4)
            }
        }
    }
}
