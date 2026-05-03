import Charts
import SwiftUI

private enum FiveMinuteKeystrokeChart {
    /// Keystrokes per bucket that fills the vertical scale (~55/min if evenly spread). Tune freely.
    static let comfortableKeystrokeCap: Double = 275
    /// How many keystrokes above the cap it takes before the fill reads as strongly red (~20+ visibly warm per your note).
    static let keystrokesAboveCapTowardFullRed: Double = 40
    /// Solid (non-transparent) gray used by both the x-axis baseline and tick marks so their
    /// intersection composites to the same shade rather than appearing brighter.
    static let axisLineColor: Color = Color(.sRGB, white: 0.55, opacity: 1.0)
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
            baselineMark()
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
    }

    /// Solid horizontal baseline at y=0, matching the x-axis tick color.
    @ChartContentBuilder
    private func baselineMark() -> some ChartContent {
        RuleMark(y: .value("Baseline", 0.0))
            .foregroundStyle(FiveMinuteKeystrokeChart.axisLineColor)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    @ChartContentBuilder
    private func keystrokeMarks(slots: [KeystrokeFiveMinuteSlot]) -> some ChartContent {
        let visibleSlots = slots.enumerated().compactMap { index, slot -> PlottedKeystroke? in
            guard slot.keyCount > 0 else { return nil }
            return PlottedKeystroke(index: index, count: slot.keyCount)
        }

        ForEach(visibleSlots) { plotted in
            keystrokeBar(for: plotted)
        }
    }

    @ChartContentBuilder
    private func keystrokeBar(for plotted: PlottedKeystroke) -> some ChartContent {
        let gap: Double = 0.04
        let xStartValue = PlottableValue.value("Start", Double(plotted.index) + gap)
        let xEndValue = PlottableValue.value("End", Double(plotted.index + 1) - gap)
        let yStartValue = PlottableValue.value("Bottom", 0.0)
        let yEndValue = PlottableValue.value("Top", min(Double(plotted.count), cap))

        RectangleMark(
            xStart: xStartValue,
            xEnd: xEndValue,
            yStart: yStartValue,
            yEnd: yEndValue
        )
        .foregroundStyle(barColor(keystrokes: plotted.count))
        .cornerRadius(4, style: .continuous)
        .annotation(position: .top, alignment: .center, spacing: 4) {
            Text("\(plotted.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private struct PlottedKeystroke: Identifiable {
        let index: Int
        let count: Int
        var id: Int { index }
    }

    @AxisContentBuilder
    private func xAxisMarks(boundaries: [Int], slots: [KeystrokeFiveMinuteSlot]) -> some AxisContent {
        AxisMarks(preset: .aligned, values: boundaries) { value in
            AxisTick(length: 5, stroke: StrokeStyle(lineWidth: 1))
                .foregroundStyle(FiveMinuteKeystrokeChart.axisLineColor)
            if let idx = value.as(Int.self), let date = Self.tickDate(idx: idx, slots: slots) {
                AxisValueLabel(centered: false) {
                    Text(Self.axisLabelFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    /// Returns the date to display under tick `idx`. The first 12 ticks show each slot's start time;
    /// the trailing tick (idx == slots.count) shows the end time of the last slot.
    private static func tickDate(idx: Int, slots: [KeystrokeFiveMinuteSlot]) -> Date? {
        if idx >= 0 && idx < slots.count {
            return slots[idx].slotStart
        }
        if idx == slots.count, let last = slots.last {
            return last.slotEnd
        }
        return nil
    }

    private static let axisLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()

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
