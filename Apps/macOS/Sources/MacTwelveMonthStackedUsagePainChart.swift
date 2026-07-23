import AppKit
import Charts
import SwiftUI

private enum TwelveMonthCombinedChart {
    /// Comfort caps use this “reference day” extrapolation (`×12` five‑minute blocks → one hour‑wide slice).
    static let typicalWorkHours = 3.0
    static let scaleFactor = 12.0 * typicalWorkHours * 30.0

    /// Leading axis speaks in **hours 0 … ~5**, while plot Y stays `0 … 10` so pain stays on a 0–10 scale beside it.
    /// Calibrate modality caps (~legacy **three** heavy‑hour tiers) down so the **stack visually reaches the top nearer ~five aggregated hours**.
    static let hoursShownAtPlotTop = 130.0
    static let referenceHeavyHourBaseline = 130.0
    private static let usageCapEaseVersusDisplayedHours =
        referenceHeavyHourBaseline / hoursShownAtPlotTop

    /// Nudges plotted bars (+ pain line) slightly right (~20 % of a nominal day‑column) so x‑axis cues line up cleanly on device.
    static let horizontalBarShift = 0.2

    static func monthBarBucketCenter(plotIndex: Int) -> Double { Double(plotIndex) + 0.5 + horizontalBarShift }

    static func monthBarXStart(plotIndex: Int, gap: Double) -> Double { Double(plotIndex) + gap + horizontalBarShift }

    static func monthBarXEnd(plotIndex: Int, gap: Double) -> Double { Double(plotIndex + 1) - gap + horizontalBarShift }

    /// Integers **`1 … count−1`** (plus horizontal shift): vertical ticks sit **between** adjacent calendar‑day bars.
    static func monthBoundaryTickPositions(barCount: Int) -> [Double] {
        guard barCount > 1 else { return [] }
        return Array(1..<barCount).map { Double($0) + horizontalBarShift }
    }

    /// Pad from the **first / last bar edges** by the same amount so trailing vs leading margins match the stacked hour charts.
    static let chartXPlotSideInset: Double = 0.058

    static func chartXDomainLower(barCount _: Int) -> Double {
        monthBarXStart(plotIndex: 0, gap: xSlotGap) - chartXPlotSideInset
    }

    static func chartXDomainUpper(barCount: Int) -> Double {
        guard barCount > 0 else { return 1 }
        return monthBarXEnd(plotIndex: barCount - 1, gap: xSlotGap) + chartXPlotSideInset
    }

    static let keystrokesMonthCap = 275.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let keystrokesMonthExcess = 40.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let clicksMonthCap = 120.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let clicksMonthExcess = 17.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let travelMonthCap = 125_000.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let travelMonthExcess = 37_500.0 * scaleFactor * usageCapEaseVersusDisplayedHours

    static let usageBandThird = 10.0 / 3.0

    static let xSlotGap = 0.04

    static let minimumStackHeightForInteriorLabel = 0.38

    static let axisBaseline = Color(.sRGB, white: 0.55, opacity: 1.0)

    static let monthAxisLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter
    }()

    /// First and last calendar day of the month slot (for tooltips).
    static func monthRangeStart(forMonthStart monthStart: Date) -> Date {
        monthStart
    }

    static func monthRangeEnd(forMonthStart monthStart: Date) -> Date {
        let calendar = Calendar.current
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonth)
        else { return monthStart }
        return lastDay
    }

    static func monthOfYearNumber(forMonthStart monthStart: Date) -> Int {
        Calendar.current.component(.month, from: monthStart)
    }

    static func monthAxisCompactHeading(forMonthStart monthStart: Date) -> String {
        monthAxisLabelFormatter.string(from: monthStart)
    }
}

// MARK: - Types & prep

private enum StackMonthMetric: Hashable {
    case keystrokes(Int)
    case mouseClicks(Int)
    case travel(Double)

    var gradientKind: MacFiveMinuteBarStyle.StackedHourInputKind {
        switch self {
        case .keystrokes: return .keystrokes
        case .mouseClicks: return .mouseClicks
        case .travel: return .pixelTravel
        }
    }

    /// In-bar caption: SI-style **K**/ **M** for thousands / millions plus the modality word (avoids ambiguous single-letter modality prefixes).
    var interiorCaption: String {
        switch self {
        case .keystrokes(let n):
            return "\(Self.siInteger(n)) keys"
        case .mouseClicks(let n):
            return "\(Self.siInteger(n)) clicks"
        case .travel(let px):
            return "\(Self.siTravelPixels(px)) px traveled"
        }
    }

    func tooltipText(plotIndex: Int, slots: [ComputerUsageMonthSlot]) -> String {
        let bucket = slots.indices.contains(plotIndex)
            ? TwelveMonthCombinedChart.monthAxisCompactHeading(forMonthStart: slots[plotIndex].monthStart)
            : "?"

        switch self {
        case .keystrokes(let n):
            return "\(bucket): \(Self.siInteger(n)) keys"
        case .mouseClicks(let n):
            return "\(bucket): \(Self.siInteger(n)) clicks"
        case .travel(let px):
            return "\(bucket): \(Self.siTravelPixels(px)) px traveled"
        }
    }

    /// Thousands / millions with **K** / **M** when large.
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

private struct MonthStackLayer: Identifiable {
    let plotIndex: Int
    let metric: StackMonthMetric
    let yLow: Double
    let yHigh: Double
    let stress: Double

    var id: String { "\(plotIndex)-\(metricTag)" }

    private var metricTag: String {
        switch metric {
        case .keystrokes: return "k"
        case .mouseClicks: return "c"
        case .travel: return "t"
        }
    }
}

private struct TwelveMonthUsageModalityVisibility: Equatable {
    var showKeystrokes: Bool
    var showMouseClicks: Bool
    var showTravel: Bool

    static let allVisible = TwelveMonthUsageModalityVisibility(
        showKeystrokes: true,
        showMouseClicks: true,
        showTravel: true
    )
}

/// One Mac‑friendly pain statistic on the 12‑day chart (**per hand** × **metric**).
private enum TwelveMonthPainCurve: String, CaseIterable, Identifiable {
    case worstLeft
    case averageLeft
    case worstRight
    case averageRight

    var id: String { rawValue }

    /// Horizontally across each day column: **max / avg** at centre; **morning** sits **⅙** (~17 %) across from the leading edge.
    var fractionAlongBar: Double { 0.5 }

    /// Flat fill for rectangles / line colour (morning dots use a separate gradient overlay).
    var dotFill: Color {
        switch self {
        case .worstLeft: return Color(red: 0.96, green: 0.40, blue: 0.36)
        case .worstRight: return Color(red: 0.82, green: 0.22, blue: 0.20)
        case .averageLeft: return Color(red: 1.0, green: 0.90, blue: 0.28)
        case .averageRight: return Color(red: 0.85, green: 0.70, blue: 0.12)
        }
    }

    /// Solid tint for translucent connectors (readable next to gradients).
    var connectorLineTint: Color { dotFill }

    var dotInk: Color {
        switch self {
        case .worstLeft, .worstRight: return Color(red: 0.22, green: 0.05, blue: 0.04)
        case .averageLeft, .averageRight: return Color(red: 0.18, green: 0.12, blue: 0.02)
        }
    }

    func helpLine(monthHeading: String, compactPain: String) -> String {
        let handLetter: String
        switch self {
        case .worstLeft, .averageLeft: handLetter = "L"
        default: handLetter = "R"
        }
        switch self {
        case .worstLeft, .worstRight:
            return "\(monthHeading): \(handLetter) max \(compactPain)"
        case .averageLeft, .averageRight:
            return "\(monthHeading): \(handLetter) avg \(compactPain)"
        }
    }
}

/// One decimal chip for averages: `3.3`, drops trailing `.0` → `5`.
private func twelveMonthAveragePainChipString(_ pain: Double) -> String {
    let t = round(pain * 10) / 10
    let frac = abs(t.truncatingRemainder(dividingBy: 1))
    guard frac >= 1e-4 else {
        return String(format: "%.0f", t.rounded(.toNearestOrAwayFromZero))
    }
    return String(format: "%.1f", t)
}

private struct MonthPainSample: Identifiable {
    let plotIndex: Int
    let pain: Double
    let curve: TwelveMonthPainCurve

    var id: String { "\(curve.rawValue)-\(plotIndex)" }

    func plotX(gap: Double) -> Double {
        let frac = curve.fractionAlongBar
        let leading = TwelveMonthCombinedChart.monthBarXStart(plotIndex: plotIndex, gap: gap)
        let trailing = TwelveMonthCombinedChart.monthBarXEnd(plotIndex: plotIndex, gap: gap)
        return leading + frac * (trailing - leading)
    }
}

/// Extracted so `PointMark` annotations don't participate in huge `some View` inference inside `Chart`.
private struct TwelveMonthPainDotOverlay: View {
    let sample: MonthPainSample
    let curve: TwelveMonthPainCurve
    let slots: [ComputerUsageMonthSlot]

    private var compactPainLabel: String {
        switch curve {
        case .averageLeft, .averageRight:
            return twelveMonthAveragePainChipString(sample.pain)
        default:
            return sample.pain.handTrackPainCompactLabel
        }
    }

    private var hoverTip: String {
        let monthHeading = slots.indices.contains(sample.plotIndex)
            ? TwelveMonthCombinedChart.monthAxisCompactHeading(forMonthStart: slots[sample.plotIndex].monthStart)
            : "?"
        return curve.helpLine(monthHeading: monthHeading, compactPain: compactPainLabel)
    }

    private var dotInk: Color { curve.dotInk }

    @ViewBuilder
    private var dotFace: some View {
        Circle()
            .fill(curve.dotFill)
            .overlay(
                Circle()
                    .strokeBorder(dotInk.opacity(0.42), lineWidth: 0.65)
            )
    }

    var body: some View {
        ZStack {
            dotFace
            Text(compactPainLabel)
                .font(.system(size: 9.75, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .tracking(-0.55)
                .scaleEffect(x: 0.9, anchor: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.43)
                .foregroundStyle(dotInk)
                
        }
        .frame(width: 24, height: 24)
        .help(hoverTip)
    }
}

private func monthCappedFraction(_ value: Double, cap: Double) -> Double {
    guard cap > 0 else { return 0 }
    return min(1, value / cap)
}

/// Same workload ladder as the twelve-day chart: `plotY / 2` → hours.
private func twelveMonthEstimatedMinutes(plotY: Double) -> Int {
    guard plotY.isFinite, plotY > 0 else { return 0 }
    let hours = max(0, plotY / 2.0)
    return Int((hours * 60.0).rounded(.toNearestOrAwayFromZero))
}

private func twelveMonthEstimatedTimeLabel(plotY: Double) -> String {
    let totalMinutes = twelveMonthEstimatedMinutes(plotY: plotY)
    guard totalMinutes > 0 else { return "" }
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}

private func twelveMonthColumnUsageMinutes(
    plotIndex: Int,
    plotY: Double,
    stackLayers: [MonthStackLayer]
) -> (keyboard: Int, mouse: Int) {
    let total = twelveMonthEstimatedMinutes(plotY: plotY)
    guard total > 0 else { return (0, 0) }
    var keysY = 0.0
    var mouseY = 0.0
    for layer in stackLayers where layer.plotIndex == plotIndex {
        let h = layer.yHigh - layer.yLow
        switch layer.metric {
        case .keystrokes:
            keysY += h
        case .mouseClicks, .travel:
            mouseY += h
        }
    }
    let sum = keysY + mouseY
    guard sum > 1e-9 else { return (0, total) }
    let keyboard = Int((Double(total) * keysY / sum).rounded(.toNearestOrAwayFromZero))
    return (keyboard, max(0, total - keyboard))
}

private struct TwelveMonthColumnContextMenuOverlay: View {
    let slots: [ComputerUsageMonthSlot]
    let stackLayers: [MonthStackLayer]
    let topPlotYByIndex: [Int: Double]
    let gap: Double
    let chartProxy: ChartProxy
    let geometry: GeometryProxy

    var body: some View {
        if let plotFrameAnchor = chartProxy.plotFrame {
            let plotBounds = geometry[plotFrameAnchor]
            let regions = Array(slots.enumerated()).compactMap { idx, slot -> MacUsageBreakdownHitRegion? in
                let centerXData = TwelveMonthCombinedChart.monthBarBucketCenter(plotIndex: idx)
                let xStartData = TwelveMonthCombinedChart.monthBarXStart(plotIndex: idx, gap: gap)
                let xEndData = TwelveMonthCombinedChart.monthBarXEnd(plotIndex: idx, gap: gap)
                guard let xStart = chartProxy.position(for: (x: xStartData, y: 0.0)),
                      let xEnd = chartProxy.position(for: (x: xEndData, y: 0.0)),
                      let yBottom = chartProxy.position(for: (x: centerXData, y: 0.0)),
                      let yTop = chartProxy.position(for: (x: centerXData, y: 10.0))
                else { return nil }
                let minutes = MacEstimatedWorkloadMinutes.columnBreakdown(
                    keystrokes: slot.keystrokeCount,
                    clicks: slot.mouseClickCount,
                    travelPixels: slot.travelPixels,
                    scrollBumps: slot.scrollBumpCount,
                    rates: .fromUserDefaults()
                )
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

private struct BuiltMonthMetricStage {
    let unscaledHeight: Double
    let stress: Double
    let metric: StackMonthMetric
}

private func buildMonthStackLayers(
    slots: [ComputerUsageMonthSlot],
    usageVisibility: TwelveMonthUsageModalityVisibility
) -> [MonthStackLayer] {
    /// Fixed **10 ÷ 3** band per modality (same height meaning as toggling overlays off in the twelve‑hour chart).
    let bandSlice = TwelveMonthCombinedChart.usageBandThird
    let maxComposite = 10.0
    guard usageVisibility.showKeystrokes || usageVisibility.showMouseClicks || usageVisibility.showTravel else {
        return []
    }

    var rows: [MonthStackLayer] = []

    for (i, slot) in slots.enumerated() {
        let keysFrac = monthCappedFraction(Double(slot.keystrokeCount), cap: TwelveMonthCombinedChart.keystrokesMonthCap)
        let clickFrac = monthCappedFraction(Double(slot.mouseClickCount), cap: TwelveMonthCombinedChart.clicksMonthCap)
        let travelFrac = monthCappedFraction(slot.travelPixels, cap: TwelveMonthCombinedChart.travelMonthCap)

        let sKeys = MacFiveMinuteBarStyle.stressAmount(
            from: Double(slot.keystrokeCount),
            cap: TwelveMonthCombinedChart.keystrokesMonthCap,
            excessWidth: TwelveMonthCombinedChart.keystrokesMonthExcess
        )
        let sClicks = MacFiveMinuteBarStyle.stressAmount(
            from: Double(slot.mouseClickCount),
            cap: TwelveMonthCombinedChart.clicksMonthCap,
            excessWidth: TwelveMonthCombinedChart.clicksMonthExcess
        )
        let sTravel = MacFiveMinuteBarStyle.stressAmount(
            from: slot.travelPixels,
            cap: TwelveMonthCombinedChart.travelMonthCap,
            excessWidth: TwelveMonthCombinedChart.travelMonthExcess
        )

        // Stack bottom → top: pointer travel → clicks → keys (same order as twelve‑hour chart).
        var stages: [BuiltMonthMetricStage] = []
        if usageVisibility.showTravel {
            let h = travelFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltMonthMetricStage(unscaledHeight: h, stress: sTravel, metric: .travel(slot.travelPixels)))
            }
        }
        if usageVisibility.showMouseClicks {
            let h = clickFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltMonthMetricStage(unscaledHeight: h, stress: sClicks, metric: .mouseClicks(slot.mouseClickCount)))
            }
        }
        if usageVisibility.showKeystrokes {
            let h = keysFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltMonthMetricStage(unscaledHeight: h, stress: sKeys, metric: .keystrokes(slot.keystrokeCount)))
            }
        }

        guard !stages.isEmpty else { continue }

        let sumUnscaled = stages.reduce(0.0) { $0 + $1.unscaledHeight }
        guard sumUnscaled > 0 else { continue }
        let squeeze = sumUnscaled <= maxComposite ? 1.0 : maxComposite / sumUnscaled

        var yCursor = 0.0
        for stage in stages {
            let scaledH = stage.unscaledHeight * squeeze
            guard scaledH > 0.000_1 else { continue }
            rows.append(MonthStackLayer(
                plotIndex: i,
                metric: stage.metric,
                yLow: yCursor,
                yHigh: yCursor + scaledH,
                stress: stage.stress
            ))
            yCursor += scaledH
        }
    }
    return rows
}

private struct TwelveMonthPainPrepared {
    let slots: [ComputerUsageMonthSlot]
    let stackLayers: [MonthStackLayer]
    /// One array per ``TwelveMonthPainCurve`` (possibly empty when all days lack data).
    let painSamplesByCurve: [TwelveMonthPainCurve: [MonthPainSample]]

    @MainActor
    init(
        slots: [ComputerUsageMonthSlot],
        painsByCurve: [TwelveMonthPainCurve: [Double?]],
        usageVisibility: TwelveMonthUsageModalityVisibility = .allVisible
    ) {
        for curve in TwelveMonthPainCurve.allCases {
            precondition(painsByCurve[curve]?.count == slots.count, "pain array length must match day slots")
        }
        self.slots = slots
        stackLayers = buildMonthStackLayers(slots: slots, usageVisibility: usageVisibility)

        var byCurve: [TwelveMonthPainCurve: [MonthPainSample]] = [:]
        for curve in TwelveMonthPainCurve.allCases {
            byCurve[curve] = TwelveMonthPainPrepared.curveSamples(
                slots: slots,
                vals: painsByCurve[curve]!,
                curve: curve
            )
        }
        painSamplesByCurve = byCurve
    }

    @MainActor
    init(store: HandTrackStore, referenceDate: Date, usageVisibility: TwelveMonthUsageModalityVisibility) {
        let s = store.computerUsageByTrailingCalendarMonths(reference: referenceDate, count: 12)
        let ds = s.map(\.monthStart)
        let pains: [TwelveMonthPainCurve: [Double?]] = [
            .worstLeft: store.monthlyPainWorstLoggedLeftHand(forOrderedMonthStarts: ds),
            .worstRight: store.monthlyPainWorstLoggedRightHand(forOrderedMonthStarts: ds),
            .averageLeft: store.monthlyPainMeanLoggedLeftHand(forOrderedMonthStarts: ds),
            .averageRight: store.monthlyPainMeanLoggedRightHand(forOrderedMonthStarts: ds),
        ]
        self.init(slots: s, painsByCurve: pains, usageVisibility: usageVisibility)
    }

    private static func curveSamples(
        slots: [ComputerUsageMonthSlot],
        vals: [Double?],
        curve: TwelveMonthPainCurve
    ) -> [MonthPainSample] {
        zip(slots.indices, vals).compactMap { idx, optionalPain -> MonthPainSample? in
            guard let p = optionalPain else { return nil }
            return MonthPainSample(plotIndex: idx, pain: p, curve: curve)
        }
        .sorted { $0.plotIndex < $1.plotIndex }
    }
}

// MARK: - Pain visibility (6 lightweight toggles)

private struct TwelveMonthPainVisibility: Equatable {
    var worstLeft = false
    var averageLeft = false
    var worstRight = false
    var averageRight = false

    func samplesActive(for curve: TwelveMonthPainCurve) -> Bool {
        switch curve {
        case .worstLeft: worstLeft
        case .averageLeft: averageLeft
        case .worstRight: worstRight
        case .averageRight: averageRight
        }
    }
}

// MARK: - Chart content slices (keeps Swift type-check feasible)

private struct TwelveMonthBaselineRuleChartContent: ChartContent {
    var body: some ChartContent {
        RuleMark(y: .value("Baseline", 0.0))
            .foregroundStyle(TwelveMonthCombinedChart.axisBaseline)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }
}

private struct TwelveMonthStackedUsageSegmentOverlay: View {
    let layer: MonthStackLayer
    let slots: [ComputerUsageMonthSlot]
    let labelOffsetX: CGFloat

    private var showsInteriorCaption: Bool {
        layer.yHigh - layer.yLow >= TwelveMonthCombinedChart.minimumStackHeightForInteriorLabel
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .help(layer.metric.tooltipText(plotIndex: layer.plotIndex, slots: slots))
            if showsInteriorCaption {
                Text(layer.metric.interiorCaption)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.28)
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 0.5)
                    .offset(x: labelOffsetX)
            }
        }
    }
}

private struct TwelveMonthStackedUsageRectanglesChartContent: ChartContent {
    let layers: [MonthStackLayer]
    let gap: Double
    let slots: [ComputerUsageMonthSlot]
    let segmentInteriorLabelOffsetXByLayerID: [String: CGFloat]
    let topmostLayerIDByPlotIndex: [Int: String]

    var body: some ChartContent {
        ForEach(layers) { layer in
            rectangle(for: layer)
        }
    }

    @ChartContentBuilder
    private func rectangle(for layer: MonthStackLayer) -> some ChartContent {
        RectangleMark(
            xStart: .value(
                "Start",
                TwelveMonthCombinedChart.monthBarXStart(plotIndex: layer.plotIndex, gap: gap)
            ),
            xEnd: .value(
                "End",
                TwelveMonthCombinedChart.monthBarXEnd(plotIndex: layer.plotIndex, gap: gap)
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
            TwelveMonthStackedUsageSegmentOverlay(
                layer: layer,
                slots: slots,
                labelOffsetX: segmentInteriorLabelOffsetXByLayerID[layer.id] ?? 0
            )
        }
        .annotation(position: .top, alignment: .center, spacing: 5) {
            if topmostLayerIDByPlotIndex[layer.plotIndex] == layer.id {
                Text(twelveMonthEstimatedTimeLabel(plotY: layer.yHigh))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
    }
}

private struct TwelveMonthPainConnectorLinesChartContent: ChartContent {
    let curves: [TwelveMonthPainCurve]
    let samplesByCurve: [TwelveMonthPainCurve: [MonthPainSample]]
    let gap: Double

    var body: some ChartContent {
        ForEach(curves, id: \.rawValue) { curve in
            lines(for: curve, samples: samplesByCurve[curve] ?? [])
        }
    }

    @ChartContentBuilder
    private func lines(for curve: TwelveMonthPainCurve, samples: [MonthPainSample]) -> some ChartContent {
        if samples.count >= 2 {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Day", sample.plotX(gap: gap)),
                    y: .value("Pain", sample.pain),
                    series: .value("Curve", curve.rawValue)
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.55, lineCap: .round, lineJoin: .round))
                .foregroundStyle(curve.connectorLineTint.opacity(0.70))
            }
        }
    }
}

/// One visible pain dot — isolates ``PointMark`` + annotation typing (see ``TwelveMonthPainDotsChartContent``).
private struct TwelveMonthPainOneDotChartContent: ChartContent, Identifiable {
    let curve: TwelveMonthPainCurve
    let sample: MonthPainSample
    let gap: Double
    let slots: [ComputerUsageMonthSlot]

    var id: String { sample.id }

    var body: some ChartContent {
        PointMark(
            x: .value("Day", sample.plotX(gap: gap)),
            y: .value("Pain", sample.pain)
        )
        .symbol(.circle)
        .symbolSize(176)
        .foregroundStyle(Color.clear)
        .annotation(position: .overlay, alignment: .center, spacing: 0) {
            TwelveMonthPainDotOverlay(sample: sample, curve: curve, slots: slots)
        }
    }
}

private struct TwelveMonthPainDotsChartContent: ChartContent {
    let curves: [TwelveMonthPainCurve]
    let samplesByCurve: [TwelveMonthPainCurve: [MonthPainSample]]
    let gap: Double
    let slots: [ComputerUsageMonthSlot]

    private var flattenedDots: [TwelveMonthPainOneDotChartContent] {
        curves.flatMap { curve in
            (samplesByCurve[curve] ?? []).map { sample in
                TwelveMonthPainOneDotChartContent(curve: curve, sample: sample, gap: gap, slots: slots)
            }
        }
    }

    var body: some ChartContent {
        ForEach(flattenedDots) { dot in
            dot
        }
    }
}

@AxisContentBuilder
private func twelveMonthChartDualXAxisMarks(slots: [ComputerUsageMonthSlot]) -> some AxisContent {
    AxisMarks(values: TwelveMonthCombinedChart.monthBoundaryTickPositions(barCount: slots.count)) { _ in
        AxisTick(length: 6, stroke: StrokeStyle(lineWidth: 1))
            .foregroundStyle(TwelveMonthCombinedChart.axisBaseline)
    }
}

/// Same numeric ladder on left + right bar edges; captions distinguish **bars usage** vs **pain** interpretations.
@AxisContentBuilder
private func twelveMonthDualPainYAxes() -> some AxisContent {
    let tickValues = stride(from: 0.0, through: 10.0, by: 2.0).map { $0 }

    AxisMarks(position: .leading, values: tickValues) { value in
        AxisTick().foregroundStyle(.secondary.opacity(0.55))
        AxisValueLabel {
            if let y = value.as(Double.self) {
                Text(twelveMonthLeadingUsageHoursTickLabel(chartY: y))
            }
        }
    }

    AxisMarks(position: .trailing, values: tickValues) { value in
        AxisTick().foregroundStyle(.secondary.opacity(0.55))
        AxisValueLabel {
            if let y = value.as(Double.self) {
                Text(twelveMonthYAxisNumericTickLabel(y))
            }
        }
    }
}

/// Maps plot Y `0…10` ↔ **0…5 h** on the bars side (ticks every 2 Y → 1 h).
private func twelveMonthLeadingUsageHoursTickLabel(chartY: Double) -> String {
    guard chartY.isFinite else { return "—" }
    let h = Int((chartY * 13.0).rounded(.toNearestOrAwayFromZero))
    return "\(h) h"
}

private func twelveMonthYAxisNumericTickLabel(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    let r = round(value)
    guard abs(value - r) >= 1e-3 else {
        return String(format: "%.0f", r)
    }
    return String(format: "%g", value)
}

/// Uses ``ChartProxy`` so month names align with geometric bar centres.
private struct TwelveMonthBarCenterMonthLabelsOverlay: View {
    let slots: [ComputerUsageMonthSlot]
    let chartProxy: ChartProxy
    let geometry: GeometryProxy

    var body: some View {
        if let plotFrameAnchor = chartProxy.plotFrame {
            let plotBounds = geometry[plotFrameAnchor]
            ForEach(Array(slots.enumerated()), id: \.offset) { pair in
                let idx = pair.offset
                let slot = pair.element
                let centerXData = TwelveMonthCombinedChart.monthBarBucketCenter(plotIndex: idx)
                if let plotted = chartProxy.position(for: (x: centerXData, y: 0.0)) {
                    Text(TwelveMonthCombinedChart.monthAxisLabelFormatter.string(from: slot.monthStart))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .multilineTextAlignment(.center)
                        .position(
                            x: plotBounds.origin.x + plotted.x,
                            y: plotBounds.maxY + 11
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Owns `Chart { … }` plus axis/scales — keeps ``TwelveMonthPainChartPanel`` from inheriting giant `some View` composition.
private struct TwelveMonthPainChartSurface: View {
    let slots: [ComputerUsageMonthSlot]
    let stackLayers: [MonthStackLayer]
    let painSamplesByCurve: [TwelveMonthPainCurve: [MonthPainSample]]
    let activeCurves: [TwelveMonthPainCurve]
    let gap: Double
    let segmentInteriorLabelOffsetXByLayerID: [String: CGFloat]

    private var topPlotYByIndex: [Int: Double] {
        var byIndex: [Int: MonthStackLayer] = [:]
        for layer in stackLayers {
            if (byIndex[layer.plotIndex]?.yHigh ?? -.infinity) < layer.yHigh {
                byIndex[layer.plotIndex] = layer
            }
        }
        return byIndex.mapValues(\.yHigh)
    }

    private var topmostLayerIDByPlotIndex: [Int: String] {
        var byIndex: [Int: MonthStackLayer] = [:]
        for layer in stackLayers {
            if (byIndex[layer.plotIndex]?.yHigh ?? -.infinity) < layer.yHigh {
                byIndex[layer.plotIndex] = layer
            }
        }
        return byIndex.mapValues(\.id)
    }

    var body: some View {
        Chart {
            TwelveMonthBaselineRuleChartContent()
            TwelveMonthStackedUsageRectanglesChartContent(
                layers: stackLayers,
                gap: gap,
                slots: slots,
                segmentInteriorLabelOffsetXByLayerID: segmentInteriorLabelOffsetXByLayerID,
                topmostLayerIDByPlotIndex: topmostLayerIDByPlotIndex
            )
            TwelveMonthPainConnectorLinesChartContent(
                curves: activeCurves,
                samplesByCurve: painSamplesByCurve,
                gap: gap
            )
            TwelveMonthPainDotsChartContent(
                curves: activeCurves,
                samplesByCurve: painSamplesByCurve,
                gap: gap,
                slots: slots
            )
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...10)
        .chartYAxis {
            twelveMonthDualPainYAxes()
        }
        .chartYAxisLabel(position: .leading, spacing: 10) {
            MacFiveMinuteChartLeadingCaption.rotated180Degrees {
                VStack(alignment: .center, spacing: 2) {
                    Text("Estimated average hours")
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
        .chartXScale(
            domain: TwelveMonthCombinedChart.chartXDomainLower(barCount: slots.count)
                ... TwelveMonthCombinedChart.chartXDomainUpper(barCount: slots.count)
        )
        .chartXAxis {
            twelveMonthChartDualXAxisMarks(slots: slots)
        }
        .frame(height: 276)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    TwelveMonthBarCenterMonthLabelsOverlay(slots: slots, chartProxy: proxy, geometry: geometry)
                    TwelveMonthColumnContextMenuOverlay(
                        slots: slots,
                        stackLayers: stackLayers,
                        topPlotYByIndex: topPlotYByIndex,
                        gap: gap,
                        chartProxy: proxy,
                        geometry: geometry
                    )
                }
            }
        }
    }
}

/// Isolated chart body — equatable so keystroke/mouse churn does not rebuild this Chart every event.
private struct MacTwelveMonthChartPanelRender: View, Equatable {
    let store: HandTrackStore
    let referenceHour: Date
    let painLogsRevision: UInt64
    let usageBarsVisibility: TwelveMonthUsageModalityVisibility
    let painVisibility: TwelveMonthPainVisibility

    var body: some View {
        let prepared = TwelveMonthPainPrepared(
            store: store,
            referenceDate: referenceHour,
            usageVisibility: usageBarsVisibility
        )
        TwelveMonthPainChartPanel(prepared: prepared, painVisibility: painVisibility)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.referenceHour == rhs.referenceHour
            && lhs.painLogsRevision == rhs.painLogsRevision
            && lhs.usageBarsVisibility == rhs.usageBarsVisibility
            && lhs.painVisibility == rhs.painVisibility
    }
}

// MARK: - Chart panel

private struct TwelveMonthPainChartPanel: View {
    let prepared: TwelveMonthPainPrepared
    var painVisibility: TwelveMonthPainVisibility

    private var slots: [ComputerUsageMonthSlot] { prepared.slots }

    private var gap: Double { TwelveMonthCombinedChart.xSlotGap }

    private var activeCurves: [TwelveMonthPainCurve] {
        TwelveMonthPainCurve.allCases.filter { painVisibility.samplesActive(for: $0) }
    }

    private var segmentInteriorLabelOffsetXByLayerID: [String: CGFloat] { [:] }

    var body: some View {
        chartBody
    }

    private var chartBody: some View {
        TwelveMonthPainChartSurface(
            slots: slots,
            stackLayers: prepared.stackLayers,
            painSamplesByCurve: prepared.painSamplesByCurve,
            activeCurves: activeCurves,
            gap: gap,
            segmentInteriorLabelOffsetXByLayerID: segmentInteriorLabelOffsetXByLayerID
        )
    }
}

// MARK: - Pain graph toggles

private struct TwelveMonthPainGraphsToggleMatrix: View {
    @Binding var visibility: TwelveMonthPainVisibility

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pain level graphs")
                .font(.caption.weight(.semibold))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(" ")
                    .frame(width: 38, alignment: .leading)
                columnHeader("Max")
                columnHeader("Avg")
            }
            .foregroundStyle(.secondary)

            toggleRow(sideLabel: "Left", keys: [.worstLeft, .averageLeft])
            toggleRow(sideLabel: "Right", keys: [.worstRight, .averageRight])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
        )
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .frame(width: 52, alignment: .center)
    }

    private func toggleRow(sideLabel: String, keys: [TwelveMonthPainVisibilityKey]) -> some View {
        let allOn = keys.allSatisfy { bool(for: $0) }
        return HStack(spacing: 4) {
            Button {
                flipRow(keys: keys, isOn: !allOn)
            } label: {
                Text(sideLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(allOn ? "Turn off all \(sideLabel.lowercased()) graphs" : "Turn on all \(sideLabel.lowercased()) graphs")

            ForEach(keys, id: \.self) { key in
                Toggle("", isOn: boolBinding(for: key))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 52, alignment: .center)
            }
        }
    }

    private func bool(for key: TwelveMonthPainVisibilityKey) -> Bool {
        switch key {
        case .worstLeft: visibility.worstLeft
        case .averageLeft: visibility.averageLeft
        case .worstRight: visibility.worstRight
        case .averageRight: visibility.averageRight
        }
    }

    private func flipRow(keys: [TwelveMonthPainVisibilityKey], isOn: Bool) {
        var next = visibility
        for key in keys {
            switch key {
            case .worstLeft: next.worstLeft = isOn
            case .averageLeft: next.averageLeft = isOn
            case .worstRight: next.worstRight = isOn
            case .averageRight: next.averageRight = isOn
            }
        }
        visibility = next
    }

    private func boolBinding(for key: TwelveMonthPainVisibilityKey) -> Binding<Bool> {
        Binding(
            get: {
                switch key {
                case .worstLeft: visibility.worstLeft
                case .averageLeft: visibility.averageLeft
                case .worstRight: visibility.worstRight
                case .averageRight: visibility.averageRight
                }
            },
            set: { newValue in
                var next = visibility
                switch key {
                case .worstLeft: next.worstLeft = newValue
                case .averageLeft: next.averageLeft = newValue
                case .worstRight: next.worstRight = newValue
                case .averageRight: next.averageRight = newValue
                }
                visibility = next
            }
        )
    }
}

private enum TwelveMonthPainVisibilityKey: Hashable {
    case worstLeft
    case averageLeft
    case worstRight
    case averageRight
}

private enum TwelveMonthUsageBarsAppStorage {
    static let showKeysKey = "HandTrack.mac.twelveMonthChartShowKeys"
    static let showClicksKey = "HandTrack.mac.twelveMonthChartShowClicks"
    static let showTravelKey = "HandTrack.mac.twelveMonthChartShowPointerTravel"

    static let worstLeftKey = "HandTrack.mac.twelveMonthPainWorstLeft"
    static let averageLeftKey = "HandTrack.mac.twelveMonthPainAverageLeft"
    static let worstRightKey = "HandTrack.mac.twelveMonthPainWorstRight"
    static let averageRightKey = "HandTrack.mac.twelveMonthPainAverageRight"
}

private struct TwelveMonthUsageBarsToggleStrip: View {
    @Binding var showKeys: Bool
    @Binding var showClicks: Bool
    @Binding var showTravel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage bars")
                .font(.caption.weight(.semibold))

            // Top → bottom matches bar stack: keys (top of column) → clicks → pointer (base).
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keys", isOn: $showKeys)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("Keystrokes segment (top of each column)")
                Toggle("Clicks", isOn: $showClicks)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("Mouse clicks segment (middle of each column)")
                Toggle("Pointer", isOn: $showTravel)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("Pointer travel / pixels (bottom of each column)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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

// MARK: - Public entry

/// Twelve trailing calendar months: stacked usage (same scaling idea as twelve‑hour chart) vs iPhone pain rollup.
struct MacTwelveMonthStackedUsagePainChart: View {
    @EnvironmentObject private var store: HandTrackStore

    @AppStorage(TwelveMonthUsageBarsAppStorage.showKeysKey) private var twelveMonthChartShowKeys = true
    @AppStorage(TwelveMonthUsageBarsAppStorage.showClicksKey) private var twelveMonthChartShowClicks = true
    @AppStorage(TwelveMonthUsageBarsAppStorage.showTravelKey) private var twelveMonthChartShowTravel = true

    @AppStorage(TwelveMonthUsageBarsAppStorage.worstLeftKey) private var painWorstLeft = true
    @AppStorage(TwelveMonthUsageBarsAppStorage.averageLeftKey) private var painAverageLeft = true
    @AppStorage(TwelveMonthUsageBarsAppStorage.worstRightKey) private var painWorstRight = false
    @AppStorage(TwelveMonthUsageBarsAppStorage.averageRightKey) private var painAverageRight = false

    private var painVisibilityBinding: Binding<TwelveMonthPainVisibility> {
        Binding(
            get: {
                TwelveMonthPainVisibility(
                    worstLeft: painWorstLeft,
                    averageLeft: painAverageLeft,
                    worstRight: painWorstRight,
                    averageRight: painAverageRight
                )
            },
            set: { newValue in
                painWorstLeft = newValue.worstLeft
                painAverageLeft = newValue.averageLeft
                painWorstRight = newValue.worstRight
                painAverageRight = newValue.averageRight
            }
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3600)) { timeline in
            chartContent(referenceDate: timeline.date)
        }
    }

    @ViewBuilder
    @MainActor
    private func chartContent(referenceDate: Date) -> some View {
        let usageBarsVisibility = TwelveMonthUsageModalityVisibility(
            showKeystrokes: twelveMonthChartShowKeys,
            showMouseClicks: twelveMonthChartShowClicks,
            showTravel: twelveMonthChartShowTravel
        )
        let painVisibility = TwelveMonthPainVisibility(
            worstLeft: painWorstLeft,
            averageLeft: painAverageLeft,
            worstRight: painWorstRight,
            averageRight: painAverageRight
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Past 12 months")
                    .font(.headline)
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 8) {
                    TwelveMonthUsageBarsToggleStrip(
                        showKeys: $twelveMonthChartShowKeys,
                        showClicks: $twelveMonthChartShowClicks,
                        showTravel: $twelveMonthChartShowTravel
                    )

                    TwelveMonthPainGraphsToggleMatrix(visibility: painVisibilityBinding)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            MacTwelveMonthChartPanelRender(
                store: store,
                referenceHour: MacChartEquatableBucket.hourStart(referenceDate),
                painLogsRevision: MacChartEquatableBucket.painLogsRevision(store),
                usageBarsVisibility: usageBarsVisibility,
                painVisibility: painVisibility
            )
            .equatable()
        }
        .padding(.top, 12)
        .onAppear {
            ensureUsageBarsInvariant()
        }
        .onChange(of: twelveMonthChartShowKeys) { _, _ in ensureUsageBarsInvariant() }
        .onChange(of: twelveMonthChartShowClicks) { _, _ in ensureUsageBarsInvariant() }
        .onChange(of: twelveMonthChartShowTravel) { _, _ in ensureUsageBarsInvariant() }
    }

    private func ensureUsageBarsInvariant() {
        if !twelveMonthChartShowKeys && !twelveMonthChartShowClicks && !twelveMonthChartShowTravel {
            twelveMonthChartShowKeys = true
        }
    }
}
