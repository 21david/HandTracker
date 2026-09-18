import Charts
import SwiftUI

private enum LiveKeystrokeChart {
    static let fiveMinuteCap: Double = 275
    static let fiveMinuteExcess: Double = 40
    static let axisLineColor: Color = Color(.sRGB, white: 0.55, opacity: 1.0)
}

struct MacKeystrokeFiveMinuteChart: View {
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
        let _ = livePulse.keystrokes
        let liveRevision = MacChartEquatableBucket.keystrokeRevision(store)
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            MacKeystrokeFiveMinuteChartRender(
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

private struct MacKeystrokeFiveMinuteChartRender: View, Equatable {
    let store: HandTrackStore
    let referenceDate: Date
    let refreshBucket: Int
    let liveRevision: Int
    let resolution: MacLiveUsageBucketResolution

    private var cap: Double { resolution.scaledCap(fiveMinuteCap: LiveKeystrokeChart.fiveMinuteCap) }
    private var excess: Double { resolution.scaledExcess(fiveMinuteExcess: LiveKeystrokeChart.fiveMinuteExcess) }

    var body: some View {
        let slots = store.keystrokesByFiveMinuteSlotsTrailing(
            reference: referenceDate,
            count: resolution.barCount,
            minutesPerSlot: resolution.minutesPerBar
        )
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
            MacFiveMinuteChartLeadingCaption.rotated180Degrees("Keystrokes", deviceNote: "external keyboard")
        }
        .frame(height: 200)
        .padding(.top, 20)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.refreshBucket == rhs.refreshBucket
            && lhs.liveRevision == rhs.liveRevision
            && lhs.resolution == rhs.resolution
    }

    @ChartContentBuilder
    private func baselineMark() -> some ChartContent {
        RuleMark(y: .value("Baseline", 0.0))
            .foregroundStyle(LiveKeystrokeChart.axisLineColor)
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
        let gap: Double = resolution == .oneMinute ? 0.08 : 0.04
        RectangleMark(
            xStart: .value("Start", Double(plotted.index) + gap),
            xEnd: .value("End", Double(plotted.index + 1) - gap),
            yStart: .value("Bottom", 0.0),
            yEnd: .value("Top", min(Double(plotted.count), cap))
        )
        .foregroundStyle(
            MacFiveMinuteBarStyle.barGradient(
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

    private struct PlottedKeystroke: Identifiable {
        let index: Int
        let count: Int
        var id: Int { index }
    }

    @AxisContentBuilder
    private func xAxisMarks(boundaries: [Int], slots: [KeystrokeFiveMinuteSlot]) -> some AxisContent {
        let labelEvery = resolution == .oneMinute ? 10 : 1
        AxisMarks(preset: .aligned, values: boundaries) { value in
            AxisTick(length: 5, stroke: StrokeStyle(lineWidth: 1))
                .foregroundStyle(LiveKeystrokeChart.axisLineColor)
            if let idx = value.as(Int.self),
               (idx % labelEvery == 0 || idx == slots.count),
               let date = Self.tickDate(idx: idx, slots: slots)
            {
                AxisValueLabel(centered: false) {
                    Text(Self.axisLabelFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

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
