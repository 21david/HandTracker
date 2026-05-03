import Charts
import SwiftUI

private enum FiveMinuteMouseTravelChart {
    /// Pixel travel per five-minute slice before the bar hits the top of the Y scale (~2.5× prior default).
    static let comfortableTravelCapPixels: Double = 125_000
    static let pixelsAboveCapTowardFullWarm: Double = 37_500
    static let axisLineColor: Color = Color(.sRGB, white: 0.55, opacity: 1.0)
}

/// Five-minute summed pointer path length (pixels); same axes style as keystrokes/clicks charts.
struct MacMouseTravelFiveMinuteChart: View {
    @EnvironmentObject private var store: HandTrackStore

    private let cap = FiveMinuteMouseTravelChart.comfortableTravelCapPixels

    private var basePurple: Color { Color(red: 0.58, green: 0.35, blue: 0.96) }
    private var stressWarm: (Double, Double, Double) { (0.98, 0.72, 0.15) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            chartContent(referenceDate: timeline.date)
        }
    }

    @ViewBuilder
    private func chartContent(referenceDate: Date) -> some View {
        let slots = store.mouseTravelByFiveMinuteSlotsTrailing(reference: referenceDate, count: 12)
        let boundaries = Array(0...slots.count)

        Chart {
            baselineMark()
            travelMarks(slots: slots)
        }
        .chartYScale(domain: 0...cap)
        .chartXScale(domain: 0...Double(slots.count))
        .chartXAxis {
            xAxisMarks(boundaries: boundaries, slots: slots)
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartYAxisLabel("Pixels (5 min)", position: .leading)
        .frame(height: 200)
    }

    @ChartContentBuilder
    private func baselineMark() -> some ChartContent {
        RuleMark(y: .value("Baseline", 0.0))
            .foregroundStyle(FiveMinuteMouseTravelChart.axisLineColor)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    @ChartContentBuilder
    private func travelMarks(slots: [MouseTravelFiveMinuteSlot]) -> some ChartContent {
        let visible = slots.enumerated().compactMap { index, slot -> PlottedTravel? in
            guard slot.travelPixels > 0 else { return nil }
            return PlottedTravel(index: index, pixels: slot.travelPixels)
        }

        ForEach(visible) { plotted in
            travelBar(for: plotted)
        }
    }

    @ChartContentBuilder
    private func travelBar(for plotted: PlottedTravel) -> some ChartContent {
        let gap: Double = 0.04
        let displayed = min(plotted.pixels, cap)

        RectangleMark(
            xStart: PlottableValue.value("Start", Double(plotted.index) + gap),
            xEnd: PlottableValue.value("End", Double(plotted.index + 1) - gap),
            yStart: PlottableValue.value("Bottom", 0.0),
            yEnd: PlottableValue.value("Top", displayed)
        )
        .foregroundStyle(barColor(pixels: plotted.pixels))
        .cornerRadius(4, style: .continuous)
        .annotation(position: .top, alignment: .center, spacing: 4) {
            Text(Self.compactPixelLabel(plotted.pixels))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private struct PlottedTravel: Identifiable {
        let index: Int
        let pixels: Double
        var id: Int { index }
    }

    @AxisContentBuilder
    private func xAxisMarks(boundaries: [Int], slots: [MouseTravelFiveMinuteSlot]) -> some AxisContent {
        AxisMarks(preset: .aligned, values: boundaries) { value in
            AxisTick(length: 5, stroke: StrokeStyle(lineWidth: 1))
                .foregroundStyle(FiveMinuteMouseTravelChart.axisLineColor)
            if let idx = value.as(Int.self), let date = Self.tickDate(idx: idx, slots: slots) {
                AxisValueLabel(centered: false) {
                    Text(Self.axisLabelFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private static func tickDate(idx: Int, slots: [MouseTravelFiveMinuteSlot]) -> Date? {
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

    private static func compactPixelLabel(_ pixels: Double) -> String {
        guard pixels.isFinite else { return "—" }
        if pixels >= 1_000_000 {
            return String(format: "%.1fM px", pixels / 1_000_000)
        }
        if pixels >= 10_000 {
            return String(format: "%.0fk px", pixels / 1_000)
        }
        if pixels >= 1_000 {
            return String(format: "%.1fk px", pixels / 1_000)
        }
        return String(format: "%.0f px", pixels)
    }

    private func barColor(pixels: Double) -> Color {
        if pixels <= cap {
            return basePurple.opacity(0.92)
        }
        let excess = pixels - cap
        let tint = min(
            excess / FiveMinuteMouseTravelChart.pixelsAboveCapTowardFullWarm,
            1.0
        )
        let p: (Double, Double, Double) = (0.58, 0.35, 0.96)
        let w = stressWarm
        return Color(
            red: p.0 + (w.0 - p.0) * tint,
            green: p.1 + (w.1 - p.1) * tint,
            blue: p.2 + (w.2 - p.2) * tint
        )
    }
}
