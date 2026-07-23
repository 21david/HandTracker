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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            MacKeystrokeFiveMinuteChartRender(
                store: store,
                referenceDate: timeline.date,
                refreshBucket: MacChartEquatableBucket.thirtySeconds(timeline.date)
            )
            .equatable()
        }
    }
}

private struct MacKeystrokeFiveMinuteChartRender: View, Equatable {
    let store: HandTrackStore
    let referenceDate: Date
    let refreshBucket: Int

    private let cap = FiveMinuteKeystrokeChart.comfortableKeystrokeCap

    var body: some View {
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
            MacFiveMinuteChartLeadingYAxis.marksNoGridGeneral()
        }
        .chartYAxisLabel(position: .leading) {
            MacFiveMinuteChartLeadingCaption.rotated180Degrees("Keystrokes")
        }
        .frame(height: 200)
        .padding(.top, 20)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.refreshBucket == rhs.refreshBucket
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
        .foregroundStyle(
            MacFiveMinuteBarStyle.barGradient(
                stressAmount: MacFiveMinuteBarStyle.stressAmount(
                    from: Double(plotted.count),
                    cap: cap,
                    excessWidth: FiveMinuteKeystrokeChart.keystrokesAboveCapTowardFullRed
                )
            )
        )
        .cornerRadius(4, style: .continuous)
        .annotation(position: .top, alignment: .center, spacing: 5) {
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
}
