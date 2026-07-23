import Charts
import SwiftUI

private enum LiveScrollBumpChart {
    static let fiveMinuteCap: Double = 200
    static let fiveMinuteExcess: Double = 40
    static let axisLineColor: Color = Color(.sRGB, white: 0.55, opacity: 1.0)
}

struct MacScrollBumpFiveMinuteChart: View {
    @EnvironmentObject private var store: HandTrackStore
    @AppStorage(MacLiveUsageBucketResolution.storageKey)
    private var resolutionRaw = MacLiveUsageBucketResolution.fiveMinutes.rawValue

    private var resolution: Binding<MacLiveUsageBucketResolution> {
        Binding(
            get: { MacLiveUsageBucketResolution(rawValue: resolutionRaw) ?? .fiveMinutes },
            set: { resolutionRaw = $0.rawValue }
        )
    }

    var body: some View {
        let liveRevision = MacChartEquatableBucket.scrollBumpRevision(store)
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            MacScrollBumpFiveMinuteChartRender(
                store: store,
                referenceDate: timeline.date,
                refreshBucket: MacChartEquatableBucket.thirtySeconds(timeline.date),
                liveRevision: liveRevision,
                resolution: resolution.wrappedValue
            )
            .equatable()
            .id(liveRevision)
        }
    }
}

private struct MacScrollBumpFiveMinuteChartRender: View, Equatable {
    let store: HandTrackStore
    let referenceDate: Date
    let refreshBucket: Int
    let liveRevision: Int
    let resolution: MacLiveUsageBucketResolution

    private var cap: Double { resolution.scaledCap(fiveMinuteCap: LiveScrollBumpChart.fiveMinuteCap) }
    private var excess: Double { resolution.scaledExcess(fiveMinuteExcess: LiveScrollBumpChart.fiveMinuteExcess) }

    var body: some View {
        let slots = store.scrollBumpsByFiveMinuteSlotsTrailing(
            reference: referenceDate,
            count: resolution.barCount,
            minutesPerSlot: resolution.minutesPerBar
        )
        let boundaries = Array(0...slots.count)

        Chart {
            RuleMark(y: .value("Baseline", 0.0))
                .foregroundStyle(LiveScrollBumpChart.axisLineColor)
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(Array(slots.enumerated().compactMap { index, slot -> Plotted? in
                guard slot.bumpCount > 0 else { return nil }
                return Plotted(index: index, count: slot.bumpCount)
            })) { plotted in
                let gap: Double = resolution == .oneMinute ? 0.08 : 0.04
                RectangleMark(
                    xStart: .value("Start", Double(plotted.index) + gap),
                    xEnd: .value("End", Double(plotted.index + 1) - gap),
                    yStart: .value("Bottom", 0.0),
                    yEnd: .value("Top", min(Double(plotted.count), cap))
                )
                .foregroundStyle(
                    MacFiveMinuteBarStyle.stackedHourBandGradient(
                        metric: .scrollBumps,
                        stressAmount: MacFiveMinuteBarStyle.stressAmount(
                            from: Double(plotted.count),
                            cap: cap,
                            excessWidth: excess
                        )
                    )
                )
                .cornerRadius(resolution == .oneMinute ? 2 : 4, style: .continuous)
                .annotation(position: .top, alignment: .center, spacing: 5) {
                    Text("\(plotted.count)")
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
                    .foregroundStyle(LiveScrollBumpChart.axisLineColor)
                if let idx = value.as(Int.self),
                   (idx % labelEvery == 0 || idx == slots.count),
                   let date = tickDate(idx: idx, slots: slots)
                {
                    AxisValueLabel(centered: false) {
                        Text(axisLabelFormatter.string(from: date))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .chartYAxis { MacFiveMinuteChartLeadingYAxis.marksNoGridGeneral() }
        .chartYAxisLabel(position: .leading) {
            MacFiveMinuteChartLeadingCaption.rotated180Degrees("Scrolls")
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
        let count: Int
        var id: Int { index }
    }

    private func tickDate(idx: Int, slots: [ScrollBumpFiveMinuteSlot]) -> Date? {
        if idx >= 0 && idx < slots.count { return slots[idx].slotStart }
        if idx == slots.count, let last = slots.last { return last.slotEnd }
        return nil
    }

    private var axisLabelFormatter: DateFormatter { Self.axisLabelFormatter }
    private static let axisLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()
}
