import Charts
import SwiftUI

private enum LiveMouseTravelChart {
    static let fiveMinuteCap: Double = 125_000
    static let fiveMinuteExcess: Double = 37_500
    static let axisLineColor: Color = Color(.sRGB, white: 0.55, opacity: 1.0)
}

struct MacMouseTravelFiveMinuteChart: View {
    @EnvironmentObject private var store: HandTrackStore
    @Environment(HandTrackLivePulse.self) private var livePulse
    @AppStorage(MacLiveUsageBucketResolution.storageKey)
    private var resolutionRaw = MacLiveUsageBucketResolution.fiveMinutes.rawValue

    private var resolution: Binding<MacLiveUsageBucketResolution> {
        Binding(
            get: { MacLiveUsageBucketResolution(rawValue: resolutionRaw) ?? .fiveMinutes },
            set: { resolutionRaw = $0.rawValue }
        )
    }

    var body: some View {
        let _ = livePulse.mouseTravel
        let liveRevision = MacChartEquatableBucket.mouseTravelRevision(store)
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            MacMouseTravelFiveMinuteChartRender(
                store: store,
                referenceDate: timeline.date,
                refreshBucket: MacChartEquatableBucket.thirtySeconds(timeline.date),
                liveRevision: liveRevision,
                resolution: resolution.wrappedValue
            )
            .equatable()

        }
    }
}

private struct MacMouseTravelFiveMinuteChartRender: View, Equatable {
    let store: HandTrackStore
    let referenceDate: Date
    let refreshBucket: Int
    let liveRevision: Int
    let resolution: MacLiveUsageBucketResolution

    private var cap: Double { resolution.scaledCap(fiveMinuteCap: LiveMouseTravelChart.fiveMinuteCap) }
    private var excess: Double { resolution.scaledExcess(fiveMinuteExcess: LiveMouseTravelChart.fiveMinuteExcess) }

    var body: some View {
        let slots = store.mouseTravelByFiveMinuteSlotsTrailing(
            reference: referenceDate,
            count: resolution.barCount,
            minutesPerSlot: resolution.minutesPerBar
        )
        let boundaries = Array(0...slots.count)

        Chart {
            RuleMark(y: .value("Baseline", 0.0))
                .foregroundStyle(LiveMouseTravelChart.axisLineColor)
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(Array(slots.enumerated().compactMap { index, slot -> Plotted? in
                guard slot.travelPixels > 0 else { return nil }
                return Plotted(index: index, pixels: slot.travelPixels)
            })) { plotted in
                let gap: Double = resolution == .oneMinute ? 0.08 : 0.04
                RectangleMark(
                    xStart: .value("Start", Double(plotted.index) + gap),
                    xEnd: .value("End", Double(plotted.index + 1) - gap),
                    yStart: .value("Bottom", 0.0),
                    yEnd: .value("Top", min(plotted.pixels, cap))
                )
                .foregroundStyle(
                    MacFiveMinuteBarStyle.stackedHourBandGradient(
                        metric: .pixelTravel,
                        stressAmount: MacFiveMinuteBarStyle.stressAmount(
                            from: plotted.pixels,
                            cap: cap,
                            excessWidth: excess
                        )
                    )
                )
                .cornerRadius(resolution == .oneMinute ? 2 : 4, style: .continuous)
                .annotation(position: .top, alignment: .center, spacing: 5) {
                    Text(Self.compactPixels(plotted.pixels))
                        .font(resolution == .oneMinute ? .system(size: 8) : .caption2)
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
        }
        .chartYScale(domain: 0...cap)
        .chartXScale(domain: 0...Double(slots.count))
        .chartXAxis {
            let labelEvery = resolution == .oneMinute ? 10 : 1
            AxisMarks(preset: .aligned, values: boundaries) { value in
                AxisTick(length: 5, stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(LiveMouseTravelChart.axisLineColor)
                if let idx = value.as(Int.self),
                   (idx % labelEvery == 0 || idx == slots.count),
                   let date = tickDate(idx: idx, slots: slots)
                {
                    AxisValueLabel(centered: false) {
                        Text(Self.axisLabelFormatter.string(from: date))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .chartYAxis { MacFiveMinuteChartLeadingYAxis.marksNoGridPixelThousands() }
        .chartYAxisLabel(position: .leading) {
            MacFiveMinuteChartLeadingCaption.rotated180Degrees("Pointer travel", deviceNote: "external mouse")
        }
        .frame(height: 200)
        .padding(.top, 20)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.refreshBucket == rhs.refreshBucket
            && lhs.liveRevision == rhs.liveRevision
            && lhs.resolution == rhs.resolution
    }

    private struct Plotted: Identifiable {
        let index: Int
        let pixels: Double
        var id: Int { index }
    }

    private func tickDate(idx: Int, slots: [MouseTravelFiveMinuteSlot]) -> Date? {
        if idx >= 0 && idx < slots.count { return slots[idx].slotStart }
        if idx == slots.count, let last = slots.last { return last.slotEnd }
        return nil
    }

    private static func compactPixels(_ p: Double) -> String {
        if p >= 1_000_000 { return String(format: "%.1fM", p / 1_000_000) }
        if p >= 1000 { return String(format: "%.0fk", p / 1000) }
        return String(format: "%.0f", p)
    }

    private static let axisLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()
}
