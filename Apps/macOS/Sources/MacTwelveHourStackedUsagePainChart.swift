import AppKit
import Charts
import SwiftUI

// MARK: - Persisted tuning (moderate‑minute averages)

private enum TwelveHourComfortStorage {
    static let avgKeysPerMinuteKey = "HandTrack.mac.twelveHourAvgKeysPerMinute"
    static let avgClicksPerMinuteKey = "HandTrack.mac.twelveHourAvgClicksPerMinute"
    static let avgPixelThousandsPerMinuteKey = "HandTrack.mac.twelveHourAvgPixelThousandsPerMinute"
    static let avgScrollsPerMinuteKey = "HandTrack.mac.twelveHourAvgScrollsPerMinute"

    static let showLeftPainKey = "HandTrack.mac.twelveHourShowLeftPain"
    static let showRightPainKey = "HandTrack.mac.twelveHourShowRightPain"
}

/// Legacy name kept for call sites; bar heights now use ``MacEstimatedWorkloadMinutes`` ratios.
/// Stress / overflow still keyed off sustained-hour activity caps when needed.
private struct HourComfortCaps {
    let rates: MacEstimatedWorkloadMinutes.Rates

    static func fromModerateMinuteAverages(
        keysPerMinute: Int,
        clicksPerMinute: Int,
        pixelThousandsPerMinute: Int,
        scrollsPerMinute: Int
    ) -> HourComfortCaps {
        HourComfortCaps(
            rates: .from(
                keysPerMinute: keysPerMinute,
                clicksPerMinute: clicksPerMinute,
                pixelThousandsPerMinute: pixelThousandsPerMinute,
                scrollsPerMinute: scrollsPerMinute
            )
        )
    }
}

private enum TwelveHourCombinedChart {
    /// Same numeric domain as twelve‑day pain / usage (`0 … 10`).
    static let chartUsageAxisMax = 10.0

    static let xSlotGap = 0.04

    static let minimumStackHeightForInteriorLabel = 1.1

    /// Plot `chartY 0 … 10` ↔ **`0 … 60`** reference minutes labeled on leading axis (**6 min per 1 Y**, ticks every 2 Y → **12 min** steps).
    static let leadingMinutesPerPlotYUnit = 6.0

    /// Visual height caps at 60 estimated minutes; anything above gets an overflow hat.
    static var cappedWorkloadMinutes: Double { chartUsageAxisMax * leadingMinutesPerPlotYUnit }

    /// Thin cap drawn at the top when estimated minutes exceed 60.
    static let overflowHatHeight = 0.35

    static let axisBaseline = Color(.sRGB, white: 0.55, opacity: 1.0)

    static let axisLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()
}

// MARK: - Types & prep (isolates generics from SwiftUI.Chart)

private enum StackHourMetric: Hashable {
    case keystrokes(Int)
    case mouseClicks(Int)
    case travel(Double)
    case scrollBumps(Int)
    /// Thin top marker when estimated workload exceeds the 60‑minute axis.
    case overflowHat

    var gradientKind: MacFiveMinuteBarStyle.StackedHourInputKind {
        switch self {
        case .keystrokes: return .keystrokes
        case .mouseClicks: return .mouseClicks
        case .travel: return .pixelTravel
        case .scrollBumps: return .scrollBumps
        case .overflowHat: return .keystrokes
        }
    }

    /// Matches 12‑day in‑bar wording (count + modality label).
    var interiorCaption: String {
        switch self {
        case .keystrokes(let n):
            return "\(Self.siInteger(n)) keys"
        case .mouseClicks(let n):
            return "\(Self.siInteger(n)) clicks"
        case .travel(let px):
            return "\(Self.siTravelPixels(px)) px traveled"
        case .scrollBumps(let n):
            return "\(Self.siInteger(n)) scrolls"
        case .overflowHat:
            return ""
        }
    }

    func tooltipText(plotIndex: Int, slots: [ComputerUsageHourSlot]) -> String {
        let bucket = slots.indices.contains(plotIndex)
            ? TwelveHourCombinedChart.axisLabelFormatter.string(from: slots[plotIndex].hourStart)
            : "?"

        switch self {
        case .keystrokes(let n):
            return "\(bucket): \(Self.siInteger(n)) keys (hour)"
        case .mouseClicks(let n):
            return "\(bucket): \(Self.siInteger(n)) clicks"
        case .travel(let px):
            return "\(bucket): \(Self.siTravelPixels(px)) px traveled"
        case .scrollBumps(let n):
            return "\(bucket): \(Self.siInteger(n)) scrolls"
        case .overflowHat:
            return "\(bucket): over 60m estimated work"
        }
    }

    private static func siInteger(_ n: Int) -> String {
        let v = Double(n)
        guard v >= 0 else { return "\(n)" }
        if v >= 1_000_000 {
            let m = v / 1_000_000
            return m >= 100 ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        }
        if v >= 1000 {
            let k = v / 1000
            return k >= 100 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
        }
        return "\(n)"
    }

    private static func siTravelPixels(_ pixels: Double) -> String {
        guard pixels.isFinite, pixels >= 0 else { return "—" }
        if pixels >= 1_000_000 {
            let m = pixels / 1_000_000
            return m >= 100 ? String(format: "%.0fM", m) : String(format: "%.2fM", m)
        }
        if pixels >= 1000 {
            let k = pixels / 1000
            return k >= 100 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
        }
        return String(format: "%.0f", pixels)
    }
}

private struct HourStackLayer: Identifiable {
    let plotIndex: Int
    let metric: StackHourMetric
    let yLow: Double
    let yHigh: Double
    let stress: Double

    var id: String { "\(plotIndex)-\(metricTag)" }

    private var metricTag: String {
        switch metric {
        case .keystrokes: return "k"
        case .mouseClicks: return "c"
        case .travel: return "t"
        case .scrollBumps: return "s"
        case .overflowHat: return "o"
        }
    }
}

private struct TwelveHourPainVisibility: Equatable {
    var showLeft = true
    var showRight = true
}

private enum TwelveHourPainStyle {
    static let leftColor = Color.orange
    static let rightColor = Color.yellow

    static let leftInk = Color(red: 0.35, green: 0.15, blue: 0.02)
    static let rightInk = Color(red: 0.30, green: 0.25, blue: 0.02)
}

private struct TwelveHourPainDotOverlay: View {
    let pain: Double
    let hand: HourPainSample.Hand

    private var dotColor: Color {
        hand == .left ? TwelveHourPainStyle.leftColor : TwelveHourPainStyle.rightColor
    }

    private var dotInk: Color {
        hand == .left ? TwelveHourPainStyle.leftInk : TwelveHourPainStyle.rightInk
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(dotColor)
                .overlay(
                    Circle()
                        .strokeBorder(dotInk.opacity(0.42), lineWidth: 0.65)
                )
            Text(pain.handTrackPainCompactLabel)
                .font(.system(size: 9.75, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .tracking(-0.55)
                .scaleEffect(x: 0.9, anchor: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.43)
                .foregroundStyle(dotInk)
        }
        .frame(width: 24, height: 24)
    }
}

private struct HourPainSample: Identifiable {
    enum Hand: String, Equatable {
        case left
        case right
    }

    let plotIndex: Int
    let hourStart: Date
    let createdAt: Date
    let pain: Double
    let hand: Hand

    var xPosition: Double {
        let calendar = Calendar.current
        let minute = Double(calendar.component(.minute, from: createdAt))
        let second = Double(calendar.component(.second, from: createdAt))
        let fraction = (minute + second / 60.0) / 60.0
        return Double(plotIndex) + fraction
    }

    var id: String {
        "\(createdAt.timeIntervalSince1970)-\(hand.rawValue)"
    }
}

/// Bar height = estimated workload minutes on the leading axis (`0…60m` ↔ plot `0…10`).
/// Segments are proportional to each modality’s minutes; totals over 60m cap at the top + overflow hat.
private func buildStackLayers(slots: [ComputerUsageHourSlot], caps: HourComfortCaps) -> [HourStackLayer] {
    let rates = caps.rates
    let minutesPerY = TwelveHourCombinedChart.leadingMinutesPerPlotYUnit
    let capMinutes = TwelveHourCombinedChart.cappedWorkloadMinutes
    let maxY = TwelveHourCombinedChart.chartUsageAxisMax
    var rows: [HourStackLayer] = []

    func modalityMinutes(amount: Double, perMinute: Double) -> Double {
        guard amount.isFinite, amount > 0, perMinute.isFinite, perMinute > 1e-9 else { return 0 }
        return amount / perMinute
    }

    for (i, slot) in slots.enumerated() {
        let keyM = modalityMinutes(amount: Double(slot.keystrokeCount), perMinute: rates.keysPerMinute)
        let clickM = modalityMinutes(amount: Double(slot.mouseClickCount), perMinute: rates.clicksPerMinute)
        let travelM = modalityMinutes(amount: slot.travelPixels, perMinute: rates.pixelsPerMinute)
        let scrollM = modalityMinutes(amount: Double(slot.scrollBumpCount), perMinute: rates.scrollsPerMinute)

        // Stack bottom → top: pointer travel → scrolls → clicks → keys.
        let parts: [(StackHourMetric, Double)] = [
            (.travel(slot.travelPixels), travelM),
            (.scrollBumps(slot.scrollBumpCount), scrollM),
            (.mouseClicks(slot.mouseClickCount), clickM),
            (.keystrokes(slot.keystrokeCount), keyM),
        ].filter { $0.1 > 1e-9 }

        let totalMinutes = parts.reduce(0.0) { $0 + $1.1 }
        guard totalMinutes > 1e-9 else { continue }

        let overflowed = totalMinutes > capMinutes + 1e-9
        let displayMinutes = min(totalMinutes, capMinutes)
        let minuteScale = displayMinutes / totalMinutes
        let overflowStress = overflowed
            ? min(max((totalMinutes - capMinutes) / 30.0, 0.35), 1.0)
            : 0.0

        var yCursor = 0.0
        for (metric, minutes) in parts {
            let h = (minutes * minuteScale) / minutesPerY
            guard h > 0.000_1 else { continue }
            let top = min(yCursor + h, maxY)
            rows.append(HourStackLayer(
                plotIndex: i,
                metric: metric,
                yLow: yCursor,
                yHigh: top,
                stress: overflowStress
            ))
            yCursor = top
            if yCursor >= maxY - 1e-9 { break }
        }

        if overflowed {
            let hat = TwelveHourCombinedChart.overflowHatHeight
            let yHigh = maxY
            let yLow = max(0, maxY - hat)
            rows.append(HourStackLayer(
                plotIndex: i,
                metric: .overflowHat,
                yLow: yLow,
                yHigh: yHigh,
                stress: 1.0
            ))
        }
    }
    return rows
}

private struct TwelveHourUsagePrepared {
    let slots: [ComputerUsageHourSlot]
    let stackLayers: [HourStackLayer]
    let hourBoundaries: [Int]
    let leftPainSamples: [HourPainSample]
    let rightPainSamples: [HourPainSample]

    /// Must run on the main actor: reads from `@MainActor` ``HandTrackStore``.
    @MainActor
    init(store: HandTrackStore, referenceDate: Date, comfortCaps: HourComfortCaps) {
        slots = store.computerUsageByTrailingCalendarHours(reference: referenceDate, count: 12)
        stackLayers = buildStackLayers(slots: slots, caps: comfortCaps)
        hourBoundaries = Array(0...slots.count)

        let logsByHour = Dictionary(grouping: store.hourlyLogs, by: { $0.hourStart.startOfHour })
        var left: [HourPainSample] = []
        var right: [HourPainSample] = []
        for (index, slot) in slots.enumerated() {
            guard let logs = logsByHour[slot.hourStart] else {
                continue
            }
            // Sort by createdAt to ensure lines connect correctly across multiple logs in the same hour
            let sortedLogs = logs.sorted(by: { $0.createdAt < $1.createdAt })
            for log in sortedLogs {
                left.append(HourPainSample(
                    plotIndex: index,
                    hourStart: slot.hourStart,
                    createdAt: log.createdAt,
                    pain: log.painLevelLeft,
                    hand: .left
                ))
                right.append(HourPainSample(
                    plotIndex: index,
                    hourStart: slot.hourStart,
                    createdAt: log.createdAt,
                    pain: log.painLevelRight,
                    hand: .right
                ))
            }
        }
        leftPainSamples = left
        rightPainSamples = right
    }
}

private func twelveHourLeadingWorkloadMinuteTickLabel(chartY: Double) -> String {
    guard chartY.isFinite else { return "—" }
    let m = Int(
        (chartY * TwelveHourCombinedChart.leadingMinutesPerPlotYUnit)
            .rounded(.toNearestOrAwayFromZero)
    )
    return "\(m)m"
}

/// Same uncapped ratio math as the twelve-day chart (`count ÷ rate`).
private func twelveHourEstimatedMinutesLabel(slot: ComputerUsageHourSlot) -> String {
    let rates = MacEstimatedWorkloadMinutes.Rates.fromUserDefaults()
    let total = MacEstimatedWorkloadMinutes.totalMinutes(
        keystrokes: slot.keystrokeCount,
        clicks: slot.mouseClickCount,
        travelPixels: slot.travelPixels,
        scrollBumps: slot.scrollBumpCount,
        rates: rates
    )
    return MacEstimatedWorkloadMinutes.compactDurationLabel(totalMinutes: total)
}

@AxisContentBuilder
private func twelveHourDualYAxes() -> some AxisContent {
    let tickValues = stride(from: 0.0, through: 10.0, by: 2.0).map { $0 }

    AxisMarks(position: .leading, values: tickValues) { value in
        AxisTick().foregroundStyle(.secondary.opacity(0.55))
        AxisValueLabel {
            if let y = value.as(Double.self) {
                Text(twelveHourLeadingWorkloadMinuteTickLabel(chartY: y))
            }
        }
    }

    AxisMarks(position: .trailing, values: tickValues) { value in
        AxisTick().foregroundStyle(.secondary.opacity(0.55))
        AxisValueLabel {
            if let y = value.as(Double.self) {
                Text(twelveHourYAxisNumericTickLabel(y))
            }
        }
    }
}

private func twelveHourYAxisNumericTickLabel(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    let r = round(value)
    guard abs(value - r) >= 1e-3 else {
        return String(format: "%.0f", r)
    }
    return String(format: "%g", value)
}

private struct TwelveHourComfortCalibrationPopover: View {
    @Binding var keysPerMinute: Int
    @Binding var clicksPerMinute: Int
    @Binding var pixelThousandsPerMinute: Int
    @Binding var scrollsPerMinute: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Average minute")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))

            Text(
                "Used to convert raw keys / clicks / scrolls / pointer travel into estimated minutes (count ÷ rate). Also scales bar heights."
            )
            .font(.caption2)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .fixedSize(horizontal: false, vertical: true)

            minuteRow(title: "Keys / min") {
                Stepper("", value: $keysPerMinute, in: Self.keysRange, step: 5)
                    .labelsHidden()
                    .accessibilityLabel(Text("Average keys per minute"))
                Text("\(keysPerMinute)")
                    .font(.body)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                    .foregroundStyle(Color(nsColor: .labelColor))
            }

            minuteRow(title: "Clicks / min") {
                Stepper("", value: $clicksPerMinute, in: Self.clicksRange, step: 1)
                    .labelsHidden()
                    .accessibilityLabel(Text("Average clicks per minute"))
                Text("\(clicksPerMinute)")
                    .font(.body)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                    .foregroundStyle(Color(nsColor: .labelColor))
            }

            minuteRow(title: "Thousand px/min") {
                Stepper("", value: $pixelThousandsPerMinute, in: Self.pxKRange, step: 1)
                    .labelsHidden()
                    .accessibilityLabel(Text("Average thousands of pixels per minute"))
                Text("\(pixelThousandsPerMinute)")
                    .font(.body)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                    .foregroundStyle(Color(nsColor: .labelColor))
            }

            minuteRow(title: "Scrolls / min") {
                Stepper("", value: $scrollsPerMinute, in: Self.scrollsRange, step: 1)
                    .labelsHidden()
                    .accessibilityLabel(Text("Average scroll bumps per minute"))
                Text("\(scrollsPerMinute)")
                    .font(.body)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                    .foregroundStyle(Color(nsColor: .labelColor))
            }

            HStack {
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: Self.popoverReadableWidth, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func minuteRow<Controls: View>(title: String, @ViewBuilder controls: () -> Controls) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(minWidth: 124, alignment: .leading)

            controls()

            Spacer(minLength: 0)
        }
    }

    private static let keysRange = 0...800
    private static let clicksRange = 0...360
    private static let pxKRange = 1...500
    private static let scrollsRange = 1...300

    private static let popoverReadableWidth: CGFloat = 312
}


private func twelveHourColumnUsageMinutes(slot: ComputerUsageHourSlot) -> (keyboard: Int, mouse: Int) {
    MacEstimatedWorkloadMinutes.columnBreakdown(
        keystrokes: slot.keystrokeCount,
        clicks: slot.mouseClickCount,
        travelPixels: slot.travelPixels,
        scrollBumps: slot.scrollBumpCount,
        rates: .fromUserDefaults()
    )
}

private struct TwelveHourColumnContextMenuOverlay: View {
    let slots: [ComputerUsageHourSlot]
    let chartProxy: ChartProxy
    let geometry: GeometryProxy

    var body: some View {
        if let plotFrameAnchor = chartProxy.plotFrame {
            let plotBounds = geometry[plotFrameAnchor]
            let gap = TwelveHourCombinedChart.xSlotGap
            let regions = Array(slots.enumerated()).compactMap { idx, slot -> MacUsageBreakdownHitRegion? in
                guard slot.keystrokeCount > 0 || slot.mouseClickCount > 0 || slot.travelPixels > 0 || slot.scrollBumpCount > 0 else {
                    return nil
                }
                let centerXData = Double(idx) + 0.5
                let xStartData = Double(idx) + gap
                let xEndData = Double(idx + 1) - gap
                guard let xStart = chartProxy.position(for: (x: xStartData, y: 0.0)),
                      let xEnd = chartProxy.position(for: (x: xEndData, y: 0.0)),
                      let yBottom = chartProxy.position(for: (x: centerXData, y: 0.0)),
                      let yTop = chartProxy.position(for: (x: centerXData, y: TwelveHourCombinedChart.chartUsageAxisMax))
                else { return nil }
                let minutes = twelveHourColumnUsageMinutes(slot: slot)
                return MacUsageBreakdownHitRegion(
                    frame: CGRect(
                        x: plotBounds.origin.x + min(xStart.x, xEnd.x),
                        y: plotBounds.origin.y + min(yBottom.y, yTop.y),
                        width: max(8, abs(xEnd.x - xStart.x)),
                        height: max(8, abs(yTop.y - yBottom.y))
                    ),
                    keyboardMinutes: minutes.keyboard,
                    mouseMinutes: minutes.mouse
                )
            }
            MacUsageBreakdownRightClickLayer(regions: regions)
        }
    }
}

// MARK: - Chart panel (narrow `some View` inference)

private struct TwelveHourUsageChartPanel: View {
    let prepared: TwelveHourUsagePrepared
    let painVisibility: TwelveHourPainVisibility

    private var slots: [ComputerUsageHourSlot] { prepared.slots }

    var body: some View {
        Chart {
            usageBaselineMark()
            stackedUsageRectangleMarks()
            if painVisibility.showLeft {
                leftPainLineMarks()
            }
            if painVisibility.showRight {
                rightPainLineMarks()
            }
            painPointMarks()
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...TwelveHourCombinedChart.chartUsageAxisMax)
        .chartYAxis {
            twelveHourDualYAxes()
        }
        .chartYAxisLabel(position: .leading, spacing: 10) {
            MacFiveMinuteChartLeadingCaption.rotated180Degrees {
                VStack(alignment: .center, spacing: 2) {
                    Text("Estimated average minutes")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    Text("worth of work (bars)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .chartYAxisLabel(position: .trailing, spacing: 10) {
            MacFiveMinuteChartLeadingCaption.rotated180Degrees {
                VStack(alignment: .center, spacing: 2) {
                    Text("Pain levels")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    Text("(line graphs)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .chartXScale(domain: 0...Double(slots.count))
        .chartXAxis {
            hourlyBoundaryAxisMarks(boundaries: prepared.hourBoundaries, slots: slots)
        }
        .frame(height: 276)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                TwelveHourColumnContextMenuOverlay(
                    slots: slots,
                    chartProxy: proxy,
                    geometry: geometry
                )
            }
        }
    }

    @ChartContentBuilder
    private func usageBaselineMark() -> some ChartContent {
        RuleMark(y: .value("Baseline", 0.0))
            .foregroundStyle(TwelveHourCombinedChart.axisBaseline)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    @ChartContentBuilder
    private func stackedUsageRectangleMarks() -> some ChartContent {
        let slots = self.slots
        let topmostIDByIndex = topmostLayerIDByPlotIndex
        ForEach(prepared.stackLayers) { layer in
            RectangleMark(
                xStart: .value(
                    "Start",
                    Double(layer.plotIndex) + TwelveHourCombinedChart.xSlotGap
                ),
                xEnd: .value(
                    "End",
                    Double(layer.plotIndex + 1) - TwelveHourCombinedChart.xSlotGap
                ),
                yStart: .value("Bottom", layer.yLow),
                yEnd: .value("Top", layer.yHigh)
            )
            .foregroundStyle(
                MacFiveMinuteBarStyle.stackedHourBandGradient(
                    metric: layer.metric.gradientKind,
                    stressAmount: layer.stress
                )
            )
            .cornerRadius(6, style: .continuous)
            .annotation(position: .overlay, alignment: .center, spacing: 0) {
                stackedUsageSegmentOverlay(layer: layer, slots: slots)
            }
            .annotation(position: .top, alignment: .center, spacing: 5) {
                if topmostIDByIndex[layer.plotIndex] == layer.id,
                   slots.indices.contains(layer.plotIndex)
                {
                    Text(twelveHourEstimatedMinutesLabel(slot: slots[layer.plotIndex]))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    EmptyView()
                }
            }
        }
    }

    /// Highest stack layer (by `yHigh`) for each `plotIndex`. The "estimated minutes" annotation is
    /// drawn only for that topmost layer so the label sits above the entire column.
    private var topmostLayerIDByPlotIndex: [Int: String] {
        var byIndex: [Int: HourStackLayer] = [:]
        for layer in prepared.stackLayers {
            if (byIndex[layer.plotIndex]?.yHigh ?? -.infinity) < layer.yHigh {
                byIndex[layer.plotIndex] = layer
            }
        }
        return byIndex.mapValues(\.id)
    }

    @ChartContentBuilder
    private func leftPainLineMarks() -> some ChartContent {
        ForEach(prepared.leftPainSamples) { sample in
            LineMark(
                x: .value("Hour", sample.xPosition),
                y: .value("Pain", sample.pain),
                series: .value("Hand", "Left")
            )
            .interpolationMethod(.linear)
            .foregroundStyle(TwelveHourPainStyle.leftColor.opacity(0.70))
            .lineStyle(StrokeStyle(lineWidth: 2.55, lineCap: .round, lineJoin: .round))
        }
    }

    @ChartContentBuilder
    private func rightPainLineMarks() -> some ChartContent {
        ForEach(prepared.rightPainSamples) { sample in
            LineMark(
                x: .value("Hour", sample.xPosition),
                y: .value("Pain", sample.pain),
                series: .value("Hand", "Right")
            )
            .interpolationMethod(.linear)
            .foregroundStyle(TwelveHourPainStyle.rightColor.opacity(0.70))
            .lineStyle(StrokeStyle(lineWidth: 2.55, lineCap: .round, lineJoin: .round))
        }
    }

    @ChartContentBuilder
    private func painPointMarks() -> some ChartContent {
        if painVisibility.showLeft {
            ForEach(prepared.leftPainSamples) { sample in
                PointMark(
                    x: .value("Hour", sample.xPosition),
                    y: .value("Pain", sample.pain)
                )
                .symbol(.circle)
                .symbolSize(176)
                .foregroundStyle(Color.clear)
                .annotation(position: .overlay, alignment: .center, spacing: 0) {
                    TwelveHourPainDotOverlay(pain: sample.pain, hand: .left)
                }
            }
        }

        if painVisibility.showRight {
            ForEach(prepared.rightPainSamples) { sample in
                PointMark(
                    x: .value("Hour", sample.xPosition),
                    y: .value("Pain", sample.pain)
                )
                .symbol(.circle)
                .symbolSize(176)
                .foregroundStyle(Color.clear)
                .annotation(position: .overlay, alignment: .center, spacing: 0) {
                    TwelveHourPainDotOverlay(pain: sample.pain, hand: .right)
                }
            }
        }
    }

    /// Tooltips go on these SwiftUI views; `RectangleMark`/PointMark `.help` resolves to opaque `some ChartContent` without that API here.
    @ViewBuilder
    private func stackedUsageSegmentOverlay(layer: HourStackLayer, slots: [ComputerUsageHourSlot]) -> some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .help(layer.metric.tooltipText(plotIndex: layer.plotIndex, slots: slots))
            if case .overflowHat = layer.metric {
                EmptyView()
            } else if stackSegmentShowsInteriorLabel(yLow: layer.yLow, yHigh: layer.yHigh) {
                Text(layer.metric.interiorCaption)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 0.5)
            }
        }
    }

    private func stackSegmentShowsInteriorLabel(yLow: Double, yHigh: Double) -> Bool {
        yHigh - yLow >= TwelveHourCombinedChart.minimumStackHeightForInteriorLabel
    }

    @AxisContentBuilder
    private func hourlyBoundaryAxisMarks(boundaries: [Int], slots: [ComputerUsageHourSlot]) -> some AxisContent {
        AxisMarks(preset: .aligned, values: boundaries) { value in
            AxisTick(length: 5, stroke: StrokeStyle(lineWidth: 1))
                .foregroundStyle(TwelveHourCombinedChart.axisBaseline)
            if let idx = value.as(Int.self),
               let date = Self.hourTickDate(idx: idx, slots: slots)
            {
                AxisValueLabel(centered: false) {
                    Text(TwelveHourCombinedChart.axisLabelFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private static func hourTickDate(idx: Int, slots: [ComputerUsageHourSlot]) -> Date? {
        if slots.isEmpty { return nil }
        if idx >= 0, idx < slots.count {
            return slots[idx].hourStart
        }
        if idx == slots.count {
            guard let last = slots.last else { return nil }
            return Calendar.current.date(byAdding: .hour, value: 1, to: last.hourStart)
        }
        return nil
    }
}

private struct TwelveHourPainGraphsToggleMatrix: View {
    @Binding var visibility: TwelveHourPainVisibility

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Left", isOn: $visibility.showLeft)
                .toggleStyle(.checkbox)
                .font(.caption2.weight(.medium))
            Toggle("Right", isOn: $visibility.showRight)
                .toggleStyle(.checkbox)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Public entry point

struct MacTwelveHourStackedUsagePainChart: View {
    @EnvironmentObject private var store: HandTrackStore

    @AppStorage(TwelveHourComfortStorage.avgKeysPerMinuteKey)
    private var avgKeysPerMinute = MacEstimatedWorkloadMinutes.defaultKeysPerMinute

    @AppStorage(TwelveHourComfortStorage.avgClicksPerMinuteKey)
    private var avgClicksPerMinute = MacEstimatedWorkloadMinutes.defaultClicksPerMinute

    /// Thousands of px per minute (example: `10` → 10,000 px/min).
    @AppStorage(TwelveHourComfortStorage.avgPixelThousandsPerMinuteKey)
    private var avgPixelThousandsPerMinute = MacEstimatedWorkloadMinutes.defaultPixelThousandsPerMinute

    @AppStorage(TwelveHourComfortStorage.avgScrollsPerMinuteKey)
    private var avgScrollsPerMinute = MacEstimatedWorkloadMinutes.defaultScrollsPerMinute

    @State private var showComfortCalibration = false

    @AppStorage(TwelveHourComfortStorage.showLeftPainKey) private var showLeftPain = true
    @AppStorage(TwelveHourComfortStorage.showRightPainKey) private var showRightPain = true

    private var painVisibilityBinding: Binding<TwelveHourPainVisibility> {
        Binding(
            get: { TwelveHourPainVisibility(showLeft: showLeftPain, showRight: showRightPain) },
            set: { newValue in
                showLeftPain = newValue.showLeft
                showRightPain = newValue.showRight
            }
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            MacTwelveHourStackedUsagePainChartFrame(
                store: store,
                referenceDate: timeline.date,
                refreshBucket: MacChartEquatableBucket.stackedChartClockBucket(timeline.date),
                painRevision: MacChartEquatableBucket.painLogsRevision(store),
                capsFingerprint: capsFingerprint,
                painVisibility: TwelveHourPainVisibility(showLeft: showLeftPain, showRight: showRightPain),
                showComfortCalibration: $showComfortCalibration,
                avgKeysPerMinute: $avgKeysPerMinute,
                avgClicksPerMinute: $avgClicksPerMinute,
                avgPixelThousandsPerMinute: $avgPixelThousandsPerMinute,
                avgScrollsPerMinute: $avgScrollsPerMinute,
                painVisibilityBinding: painVisibilityBinding
            )
            .equatable()
        }
    }

    private var capsFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(avgKeysPerMinute)
        hasher.combine(avgClicksPerMinute)
        hasher.combine(avgPixelThousandsPerMinute)
        hasher.combine(avgScrollsPerMinute)
        return hasher.finalize()
    }
}

/// Skips rebuilding the heavy 12‑hour chart when only live key/click/scroll counters change.
private struct MacTwelveHourStackedUsagePainChartFrame: View, Equatable {
    let store: HandTrackStore
    let referenceDate: Date
    let refreshBucket: Int
    let painRevision: UInt64
    let capsFingerprint: Int
    let painVisibility: TwelveHourPainVisibility
    @Binding var showComfortCalibration: Bool
    @Binding var avgKeysPerMinute: Int
    @Binding var avgClicksPerMinute: Int
    @Binding var avgPixelThousandsPerMinute: Int
    @Binding var avgScrollsPerMinute: Int
    var painVisibilityBinding: Binding<TwelveHourPainVisibility>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.refreshBucket == rhs.refreshBucket
            && lhs.painRevision == rhs.painRevision
            && lhs.capsFingerprint == rhs.capsFingerprint
            && lhs.painVisibility == rhs.painVisibility
    }

    var body: some View {
        let caps = HourComfortCaps.fromModerateMinuteAverages(
            keysPerMinute: avgKeysPerMinute,
            clicksPerMinute: avgClicksPerMinute,
            pixelThousandsPerMinute: avgPixelThousandsPerMinute,
            scrollsPerMinute: avgScrollsPerMinute
        )
        let prepared = TwelveHourUsagePrepared(store: store, referenceDate: referenceDate, comfortCaps: caps)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Past 12 hours")
                    .font(.headline)

                Spacer(minLength: 8)

                TwelveHourPainGraphsToggleMatrix(visibility: painVisibilityBinding)

                Button {
                    showComfortCalibration.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(minWidth: 24, minHeight: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Average‑minute defaults for bar heights (saved)")
                .popover(isPresented: $showComfortCalibration, arrowEdge: .bottom) {
                    TwelveHourComfortCalibrationPopover(
                        keysPerMinute: $avgKeysPerMinute,
                        clicksPerMinute: $avgClicksPerMinute,
                        pixelThousandsPerMinute: $avgPixelThousandsPerMinute,
                        scrollsPerMinute: $avgScrollsPerMinute
                    )
                }
            }

            TwelveHourUsageChartPanel(prepared: prepared, painVisibility: painVisibility)
        }
    }
}
