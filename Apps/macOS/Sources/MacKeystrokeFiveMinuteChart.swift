import Charts
import SwiftUI

private enum FiveMinuteKeystrokeChart {
    /// Keystrokes per bucket that fills the vertical scale (~55/min if evenly spread). Tune freely.
    static let comfortableKeystrokeCap: Double = 275
    /// How many keystrokes above the cap it takes before the fill reads as strongly red (~20+ visibly warm per your note).
    static let keystrokesAboveCapTowardFullRed: Double = 40
}

struct MacKeystrokeFiveMinuteChart: View {
    @EnvironmentObject private var store: HandTrackStore

    private let cap = FiveMinuteKeystrokeChart.comfortableKeystrokeCap

    /// Solid bar color at and below the cap.
    private var baseBlue: Color { Color(red: 0.12, green: 0.52, blue: 1.0) }

    /// Red target when heavily over cap.
    private var stressRed: (Double, Double, Double) { (0.95, 0.08, 0.08) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            chartContent(referenceDate: timeline.date)
        }
    }

    @ViewBuilder
    private func chartContent(referenceDate: Date) -> some View {
        let slots = store.keystrokesByFiveMinuteSlotsTrailing(reference: referenceDate, count: 12)
        let boundaries = Array(0...slots.count)

        Chart {
            keystrokeMarks(slots: slots)
        }
        .chartYScale(domain: 0...cap)
        .chartXScale(domain: 0...Double(slots.count))
        .chartXAxis {
            xAxisMarks(boundaries: boundaries, slots: slots)
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

    @ChartContentBuilder
    private func keystrokeMarks(slots: [KeystrokeFiveMinuteSlot]) -> some ChartContent {
        let visibleSlots = slots.enumerated().compactMap { index, slot -> PlottedKeystroke? in
            // We still want to show a tiny bar even for 0 keys to maintain the full-width look if desired,
            // but the user said "if slot.keyCount > 0" in previous iterations.
            // Let's stick to showing only positive counts but ensure they are full width.
            guard slot.keyCount > 0 else { return nil }
            return PlottedKeystroke(index: index, count: slot.keyCount)
        }

        ForEach(visibleSlots) { plotted in
            let displayedHeight = min(Double(plotted.count), cap)
            let gap: Double = 0.02 // Very small gap for "full width" look
            BarMark(
                xStart: .value("Start", Double(plotted.index) + gap),
                xEnd: .value("End", Double(plotted.index + 1) - gap),
                yStart: .value("Bottom", 0.0),
                yEnd: .value("Top", displayedHeight)
            )
            .foregroundStyle(barColor(keystrokes: plotted.count))
            .cornerRadius(4, style: .continuous)
            .annotation(position: .top, alignment: .center, spacing: 4) {
                Text("\(plotted.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct PlottedKeystroke: Identifiable {
        let index: Int
        let count: Int
        var id: Int { index }
    }

    @AxisContentBuilder
    private func xAxisMarks(boundaries: [Int], slots: [KeystrokeFiveMinuteSlot]) -> some AxisContent {
        AxisMarks(values: boundaries) { value in
            AxisTick()
            if let idx = value.as(Int.self), slots.indices.contains(idx) {
                AxisValueLabel {
                    Text(slots[idx].slotStart, format: .dateTime.hour().minute(.twoDigits))
                        .font(.caption2)
                }
            }
        }
    }

    /// At or below cap: steady blue; above cap, blend subtly toward red as excess grows.
    private func barColor(keystrokes: Int) -> Color {
        if Double(keystrokes) <= cap {
            return baseBlue.opacity(0.92)
        }
        let excess = Double(keystrokes) - cap
        let tint = min(
            excess / FiveMinuteKeystrokeChart.keystrokesAboveCapTowardFullRed,
            1.0
        )
        let b: (Double, Double, Double) = (0.12, 0.52, 1.0)
        let r = stressRed
        return Color(
            red: b.0 + (r.0 - b.0) * tint,
            green: b.1 + (r.1 - b.1) * tint,
            blue: b.2 + (r.2 - b.2) * tint
        )
    }
}
