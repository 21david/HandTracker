import Charts
import SwiftUI

private enum FiveMinuteMouseClickChart {
    /// Clicks per five-minute slice that fills the vertical scale (~24/min if evenly spread).
    static let comfortableClickCap: Double = 120
    /// Excess clicks above chart cap blended toward stressed red gradient.
    static let clicksAboveCapStressWidth: Double = 17
    static let axisLineColor: Color = Color(.sRGB, white: 0.55, opacity: 1.0)
}

struct MacMouseClickFiveMinuteChart: View {
    @EnvironmentObject private var store: HandTrackStore

    private let cap = FiveMinuteMouseClickChart.comfortableClickCap

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            chartContent(referenceDate: timeline.date)
        }
    }

    @ViewBuilder
    private func chartContent(referenceDate: Date) -> some View {
        let slots = store.mouseClicksByFiveMinuteSlotsTrailing(reference: referenceDate, count: 12)
        let boundaries = Array(0...slots.count)

        Chart {
            baselineMark()
            clickMarks(slots: slots)
        }
        .chartYScale(domain: 0...cap)
        .chartXScale(domain: 0...Double(slots.count))
        .chartXAxis {
            xAxisMarks(boundaries: boundaries, slots: slots)
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartYAxisLabel("Mouse clicks", position: .leading)
        .frame(height: 200)
        .padding(.top, 20)
    }

    @ChartContentBuilder
    private func baselineMark() -> some ChartContent {
        RuleMark(y: .value("Baseline", 0.0))
            .foregroundStyle(FiveMinuteMouseClickChart.axisLineColor)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    @ChartContentBuilder
    private func clickMarks(slots: [MouseClickFiveMinuteSlot]) -> some ChartContent {
        let visibleSlots = slots.enumerated().compactMap { index, slot -> PlottedClick? in
            guard slot.clickCount > 0 else { return nil }
            return PlottedClick(index: index, count: slot.clickCount)
        }

        ForEach(visibleSlots) { plotted in
            clickBar(for: plotted)
        }
    }

    @ChartContentBuilder
    private func clickBar(for plotted: PlottedClick) -> some ChartContent {
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
                    excessWidth: FiveMinuteMouseClickChart.clicksAboveCapStressWidth
                )
            )
        )
        .cornerRadius(4, style: .continuous)
        .annotation(position: .top, alignment: .center, spacing: 10) {
            Text("\(plotted.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private struct PlottedClick: Identifiable {
        let index: Int
        let count: Int
        var id: Int { index }
    }

    @AxisContentBuilder
    private func xAxisMarks(boundaries: [Int], slots: [MouseClickFiveMinuteSlot]) -> some AxisContent {
        AxisMarks(preset: .aligned, values: boundaries) { value in
            AxisTick(length: 5, stroke: StrokeStyle(lineWidth: 1))
                .foregroundStyle(FiveMinuteMouseClickChart.axisLineColor)
            if let idx = value.as(Int.self), let date = Self.tickDate(idx: idx, slots: slots) {
                AxisValueLabel(centered: false) {
                    Text(Self.axisLabelFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private static func tickDate(idx: Int, slots: [MouseClickFiveMinuteSlot]) -> Date? {
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
