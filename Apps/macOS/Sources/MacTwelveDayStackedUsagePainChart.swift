import AppKit
import Charts
import SwiftUI

private enum TwelveDayCombinedChart {
    /// Comfort caps use this “reference day” extrapolation (`×12` five‑minute blocks → one hour‑wide slice).
    static let typicalWorkHours = 3.0
    static let scaleFactor = 12.0 * typicalWorkHours

    /// Leading axis speaks in **hours 0 … ~5**, while plot Y stays `0 … 10` so pain stays on a 0–10 scale beside it.
    /// Calibrate modality caps (~legacy **three** heavy‑hour tiers) down so the **stack visually reaches the top nearer ~five aggregated hours**.
    static let hoursShownAtPlotTop = 5.0
    static let referenceHeavyHourBaseline = 3.0
    private static let usageCapEaseVersusDisplayedHours =
        referenceHeavyHourBaseline / hoursShownAtPlotTop

    /// Nudges plotted bars (+ pain line) slightly right (~20 % of a nominal day‑column) so x‑axis cues line up cleanly on device.
    static let horizontalBarShift = 0.2

    static func dayBarBucketCenter(plotIndex: Int) -> Double { Double(plotIndex) + 0.5 + horizontalBarShift }

    static func dayBarXStart(plotIndex: Int, gap: Double) -> Double { Double(plotIndex) + gap + horizontalBarShift }

    static func dayBarXEnd(plotIndex: Int, gap: Double) -> Double { Double(plotIndex + 1) - gap + horizontalBarShift }

    /// Integers **`1 … count−1`** (plus horizontal shift): vertical ticks sit **between** adjacent calendar‑day bars.
    static func dayBoundaryTickPositions(barCount: Int) -> [Double] {
        guard barCount > 1 else { return [] }
        return Array(1..<barCount).map { Double($0) + horizontalBarShift }
    }

    /// Pad from the **first / last bar edges** by the same amount so trailing vs leading margins match the stacked hour charts.
    static let chartXPlotSideInset: Double = 0.058

    static func chartXDomainLower(barCount _: Int) -> Double {
        dayBarXStart(plotIndex: 0, gap: xSlotGap) - chartXPlotSideInset
    }

    static func chartXDomainUpper(barCount: Int) -> Double {
        guard barCount > 0 else { return 1 }
        return dayBarXEnd(plotIndex: barCount - 1, gap: xSlotGap) + chartXPlotSideInset
    }

    static let keystrokesDayCap = 275.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let keystrokesDayExcess = 40.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let clicksDayCap = 120.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let clicksDayExcess = 17.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let travelDayCap = 125_000.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let travelDayExcess = 37_500.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    /// Matches live scroll five‑minute cap × same day scale factor as other modalities.
    static let scrollsDayCap = 200.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let scrollsDayExcess = 40.0 * scaleFactor * usageCapEaseVersusDisplayedHours

    static let usageBandThird = 10.0 / 3.0

    static let xSlotGap = 0.04

    static let minimumStackHeightForInteriorLabel = 0.38

    static let axisBaseline = Color(.sRGB, white: 0.55, opacity: 1.0)

    static let axisLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE M/d"
        return formatter
    }()
}

// MARK: - Types & prep

private enum StackDayMetric: Hashable {
    case keystrokes(Int)
    case mouseClicks(Int)
    case travel(Double)
    case scrollBumps(Int)

    var gradientKind: MacFiveMinuteBarStyle.StackedHourInputKind {
        switch self {
        case .keystrokes: return .keystrokes
        case .mouseClicks: return .mouseClicks
        case .travel: return .pixelTravel
        case .scrollBumps: return .scrollBumps
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
        case .scrollBumps(let n):
            return "\(Self.siInteger(n)) scrolls"
        }
    }

    func tooltipText(plotIndex: Int, slots: [ComputerUsageDaySlot]) -> String {
        let bucket = slots.indices.contains(plotIndex)
            ? TwelveDayCombinedChart.axisLabelFormatter.string(from: slots[plotIndex].dayStart)
            : "?"

        switch self {
        case .keystrokes(let n):
            return "\(bucket): \(Self.siInteger(n)) keys"
        case .mouseClicks(let n):
            return "\(bucket): \(Self.siInteger(n)) clicks"
        case .travel(let px):
            return "\(bucket): \(Self.siTravelPixels(px)) px traveled"
        case .scrollBumps(let n):
            return "\(bucket): \(Self.siInteger(n)) scrolls"
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

private struct DayStackLayer: Identifiable {
    let plotIndex: Int
    let metric: StackDayMetric
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
        }
    }
}

private struct TwelveDayUsageModalityVisibility: Equatable {
    var showKeystrokes: Bool
    var showMouseClicks: Bool
    var showTravel: Bool
    var showScrolls: Bool

    static let allVisible = TwelveDayUsageModalityVisibility(
        showKeystrokes: true,
        showMouseClicks: true,
        showTravel: true,
        showScrolls: true
    )
}

/// One Mac‑friendly pain statistic on the 12‑day chart (**per hand** × **metric**).
private enum TwelveDayPainCurve: String, CaseIterable, Identifiable {
    case worstLeft
    case averageLeft
    case firstLeft
    case worstRight
    case averageRight
    case firstRight

    var id: String { rawValue }

    /// Horizontally across each day column: **max / avg** at centre; **morning** sits **⅙** (~17 %) across from the leading edge.
    var fractionAlongBar: Double {
        switch self {
        case .worstLeft, .worstRight, .averageLeft, .averageRight:
            return 0.5
        case .firstLeft, .firstRight:
            return 1.0 / 6.0
        }
    }

    /// Flat fill for rectangles / line colour (morning dots use a separate gradient overlay).
    var dotFill: Color {
        switch self {
        case .worstLeft: return Color(red: 0.96, green: 0.40, blue: 0.36)
        case .worstRight: return Color(red: 0.82, green: 0.22, blue: 0.20)
        case .averageLeft: return Color(red: 1.0, green: 0.90, blue: 0.28)
        case .averageRight: return Color(red: 0.85, green: 0.70, blue: 0.12)
        case .firstLeft: return Color(red: 0.16, green: 0.48, blue: 1.00)
        case .firstRight: return Color(red: 0.14, green: 0.44, blue: 0.98)
        }
    }

    /// Solid tint for translucent connectors (readable next to gradients).
    var connectorLineTint: Color {
        switch self {
        case .firstLeft, .firstRight:
            return Color(red: 0.18, green: 0.50, blue: 1.00)
        default:
            return dotFill
        }
    }

    var dotInk: Color {
        switch self {
        case .worstLeft, .worstRight: return Color(red: 0.22, green: 0.05, blue: 0.04)
        case .averageLeft, .averageRight: return Color(red: 0.18, green: 0.12, blue: 0.02)
        case .firstLeft, .firstRight: return Color(red: 0.02, green: 0.16, blue: 0.38)
        }
    }

    func helpLine(dayHeading: String, compactPain: String) -> String {
        let handLetter: String
        switch self {
        case .worstLeft, .averageLeft, .firstLeft: handLetter = "L"
        default: handLetter = "R"
        }
        switch self {
        case .worstLeft, .worstRight:
            return "\(dayHeading): \(handLetter) max \(compactPain)"
        case .averageLeft, .averageRight:
            return "\(dayHeading): \(handLetter) avg \(compactPain)"
        case .firstLeft, .firstRight:
            return "\(dayHeading): \(handLetter) morning \(compactPain)"
        }
    }
}

/// One decimal chip for averages: `3.3`, drops trailing `.0` → `5`.
private func twelveDayAveragePainChipString(_ pain: Double) -> String {
    let t = round(pain * 10) / 10
    let frac = abs(t.truncatingRemainder(dividingBy: 1))
    guard frac >= 1e-4 else {
        return String(format: "%.0f", t.rounded(.toNearestOrAwayFromZero))
    }
    return String(format: "%.1f", t)
}

private struct DayPainSample: Identifiable {
    let plotIndex: Int
    let pain: Double
    let curve: TwelveDayPainCurve

    var id: String { "\(curve.rawValue)-\(plotIndex)" }

    func plotX(gap: Double) -> Double {
        let frac = curve.fractionAlongBar
        let leading = TwelveDayCombinedChart.dayBarXStart(plotIndex: plotIndex, gap: gap)
        let trailing = TwelveDayCombinedChart.dayBarXEnd(plotIndex: plotIndex, gap: gap)
        return leading + frac * (trailing - leading)
    }
}

/// Extracted so `PointMark` annotations don't participate in huge `some View` inference inside `Chart`.
private struct TwelveDayPainDotOverlay: View {
    let sample: DayPainSample
    let curve: TwelveDayPainCurve
    let slots: [ComputerUsageDaySlot]

    private var compactPainLabel: String {
        switch curve {
        case .averageLeft, .averageRight:
            return twelveDayAveragePainChipString(sample.pain)
        default:
            return sample.pain.handTrackPainCompactLabel
        }
    }

    private var hoverTip: String {
        let dayHeading = slots.indices.contains(sample.plotIndex)
            ? TwelveDayCombinedChart.axisLabelFormatter.string(from: slots[sample.plotIndex].dayStart)
            : "?"
        return curve.helpLine(dayHeading: dayHeading, compactPain: compactPainLabel)
    }

    private var dotInk: Color { curve.dotInk }

    private var numericLabelInk: Color {
        switch curve {
        case .firstLeft, .firstRight:
            return Color(red: 0.92, green: 0.97, blue: 1.0).opacity(0.97)
        default:
            return dotInk
        }
    }

    private var morningNumericLabelShadow: Color {
        switch curve {
        case .firstLeft, .firstRight: return Color.black.opacity(0.42)
        default: return .clear
        }
    }
    @ViewBuilder
    private var dotFace: some View {
        switch curve {
        case .firstLeft, .firstRight:
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.40, blue: 1.00),
                            Color(red: 0.07, green: 0.60, blue: 1.00),
                            Color(red: 0.005, green: 0.18, blue: 0.85),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.62),
                                    Color.white.opacity(0.06),
                                    Color.clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1.05
                        )
                )
                .overlay(
                    Circle()
                        .strokeBorder(dotInk.opacity(0.5), lineWidth: 0.55)
                )
        default:
            Circle()
                .fill(curve.dotFill)
                .overlay(
                    Circle()
                        .strokeBorder(dotInk.opacity(0.42), lineWidth: 0.65)
                )
        }
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
                .foregroundStyle(numericLabelInk)
                .shadow(color: morningNumericLabelShadow, radius: 1.1, x: 0, y: 0.6)
        }
        .frame(width: 24, height: 24)
        .help(hoverTip)
    }
}

private func dayCappedFraction(_ value: Double, cap: Double) -> Double {
    guard cap > 0 else { return 0 }
    return min(1, value / cap)
}

private struct BuiltDayMetricStage {
    let unscaledHeight: Double
    let stress: Double
    let metric: StackDayMetric
}

private func buildDayStackLayers(
    slots: [ComputerUsageDaySlot],
    usageVisibility: TwelveDayUsageModalityVisibility,
    rates: MacEstimatedWorkloadMinutes.Rates = .fromUserDefaults()
) -> [DayStackLayer] {
    /// Fixed **10 ÷ 3** band per modality (same height meaning as toggling overlays off in the twelve‑hour chart).
    let bandSlice = TwelveDayCombinedChart.usageBandThird
    let maxComposite = 10.0
    guard usageVisibility.showKeystrokes || usageVisibility.showMouseClicks || usageVisibility.showTravel || usageVisibility.showScrolls else {
        return []
    }

    var rows: [DayStackLayer] = []

    for (i, slot) in slots.enumerated() {
        let keysTotal = slot.keystrokeCount + slot.builtinKeystrokeCount
        let clicksTotal = slot.mouseClickCount + slot.builtinTrackpadClickCount
        let travelTotal =
            slot.travelPixels
            + MacEstimatedWorkloadMinutes.equivalentTravelPixels(
                fromTrackpadTravelPixels: slot.builtinTrackpadTravelPixels,
                rates: rates
            )
        let scrollsTotal = Int(
            (
                Double(slot.scrollBumpCount)
                    + MacEstimatedWorkloadMinutes.equivalentScrollBumps(
                        fromTrackpadScrollPixels: slot.builtinTrackpadScrollPixels,
                        rates: rates
                    )
            ).rounded(.toNearestOrAwayFromZero)
        )

        let keysFrac = dayCappedFraction(Double(keysTotal), cap: TwelveDayCombinedChart.keystrokesDayCap)
        let clickFrac = dayCappedFraction(Double(clicksTotal), cap: TwelveDayCombinedChart.clicksDayCap)
        let travelFrac = dayCappedFraction(travelTotal, cap: TwelveDayCombinedChart.travelDayCap)
        let scrollFrac = dayCappedFraction(Double(scrollsTotal), cap: TwelveDayCombinedChart.scrollsDayCap)

        let sKeys = MacFiveMinuteBarStyle.stressAmount(
            from: Double(keysTotal),
            cap: TwelveDayCombinedChart.keystrokesDayCap,
            excessWidth: TwelveDayCombinedChart.keystrokesDayExcess
        )
        let sClicks = MacFiveMinuteBarStyle.stressAmount(
            from: Double(clicksTotal),
            cap: TwelveDayCombinedChart.clicksDayCap,
            excessWidth: TwelveDayCombinedChart.clicksDayExcess
        )
        let sTravel = MacFiveMinuteBarStyle.stressAmount(
            from: travelTotal,
            cap: TwelveDayCombinedChart.travelDayCap,
            excessWidth: TwelveDayCombinedChart.travelDayExcess
        )
        let sScrolls = MacFiveMinuteBarStyle.stressAmount(
            from: Double(scrollsTotal),
            cap: TwelveDayCombinedChart.scrollsDayCap,
            excessWidth: TwelveDayCombinedChart.scrollsDayExcess
        )

        // Stack bottom → top: pointer travel → scrolls → clicks → keys.
        // Keep 10÷3 band size so columns with no scrolls match prior heights.
        var stages: [BuiltDayMetricStage] = []
        if usageVisibility.showTravel {
            let h = travelFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltDayMetricStage(unscaledHeight: h, stress: sTravel, metric: .travel(travelTotal)))
            }
        }
        if usageVisibility.showScrolls {
            let h = scrollFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltDayMetricStage(unscaledHeight: h, stress: sScrolls, metric: .scrollBumps(scrollsTotal)))
            }
        }
        if usageVisibility.showMouseClicks {
            let h = clickFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltDayMetricStage(unscaledHeight: h, stress: sClicks, metric: .mouseClicks(clicksTotal)))
            }
        }
        if usageVisibility.showKeystrokes {
            let h = keysFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltDayMetricStage(unscaledHeight: h, stress: sKeys, metric: .keystrokes(keysTotal)))
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
            rows.append(DayStackLayer(
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

private struct TwelveDayPainPrepared {
    let slots: [ComputerUsageDaySlot]
    let stackLayers: [DayStackLayer]
    /// One array per ``TwelveDayPainCurve`` (possibly empty when all days lack data).
    let painSamplesByCurve: [TwelveDayPainCurve: [DayPainSample]]

    @MainActor
    init(
        slots: [ComputerUsageDaySlot],
        painsByCurve: [TwelveDayPainCurve: [Double?]],
        usageVisibility: TwelveDayUsageModalityVisibility = .allVisible
    ) {
        for curve in TwelveDayPainCurve.allCases {
            precondition(painsByCurve[curve]?.count == slots.count, "pain array length must match day slots")
        }
        self.slots = slots
        stackLayers = buildDayStackLayers(slots: slots, usageVisibility: usageVisibility, rates: .fromUserDefaults())

        var byCurve: [TwelveDayPainCurve: [DayPainSample]] = [:]
        for curve in TwelveDayPainCurve.allCases {
            byCurve[curve] = TwelveDayPainPrepared.curveSamples(
                slots: slots,
                vals: painsByCurve[curve]!,
                curve: curve
            )
        }
        painSamplesByCurve = byCurve
    }

    @MainActor
    init(store: HandTrackStore, referenceDate: Date, usageVisibility: TwelveDayUsageModalityVisibility) {
        let s = store.computerUsageByTrailingCalendarDays(reference: referenceDate, count: 12)
        let ds = s.map(\.dayStart)
        let pains: [TwelveDayPainCurve: [Double?]] = [
            .worstLeft: store.dailyPainWorstLoggedLeftHand(forOrderedCalendarDayStarts: ds),
            .worstRight: store.dailyPainWorstLoggedRightHand(forOrderedCalendarDayStarts: ds),
            .averageLeft: store.dailyPainMeanLoggedLeftHand(forOrderedCalendarDayStarts: ds),
            .averageRight: store.dailyPainMeanLoggedRightHand(forOrderedCalendarDayStarts: ds),
            .firstLeft: store.dailyPainFirstLoggedLeftHand(forOrderedCalendarDayStarts: ds),
            .firstRight: store.dailyPainFirstLoggedRightHand(forOrderedCalendarDayStarts: ds),
        ]
        self.init(slots: s, painsByCurve: pains, usageVisibility: usageVisibility)
    }

    private static func curveSamples(
        slots: [ComputerUsageDaySlot],
        vals: [Double?],
        curve: TwelveDayPainCurve
    ) -> [DayPainSample] {
        zip(slots.indices, vals).compactMap { idx, optionalPain -> DayPainSample? in
            guard let p = optionalPain else { return nil }
            return DayPainSample(plotIndex: idx, pain: p, curve: curve)
        }
        .sorted { $0.plotIndex < $1.plotIndex }
    }
}

// MARK: - Pain visibility (6 lightweight toggles)

private struct TwelveDayPainVisibility: Equatable {
    var worstLeft = false
    var averageLeft = false
    var firstLeft = false
    var worstRight = false
    var averageRight = false
    var firstRight = false

    func samplesActive(for curve: TwelveDayPainCurve) -> Bool {
        switch curve {
        case .worstLeft: worstLeft
        case .averageLeft: averageLeft
        case .firstLeft: firstLeft
        case .worstRight: worstRight
        case .averageRight: averageRight
        case .firstRight: firstRight
        }
    }
}

// MARK: - Chart content slices (keeps Swift type-check feasible)

private struct TwelveDayBaselineRuleChartContent: ChartContent {
    var body: some ChartContent {
        RuleMark(y: .value("Baseline", 0.0))
            .foregroundStyle(TwelveDayCombinedChart.axisBaseline)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }
}

private struct TwelveDayStackedUsageSegmentOverlay: View {
    let layer: DayStackLayer
    let slots: [ComputerUsageDaySlot]
    let labelOffsetX: CGFloat

    private var showsInteriorCaption: Bool {
        layer.yHigh - layer.yLow >= TwelveDayCombinedChart.minimumStackHeightForInteriorLabel
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

private struct TwelveDayStackedUsageRectanglesChartContent: ChartContent {
    let layers: [DayStackLayer]
    let gap: Double
    let slots: [ComputerUsageDaySlot]
    let workloadRates: MacEstimatedWorkloadMinutes.Rates
    let segmentInteriorLabelOffsetXByLayerID: [String: CGFloat]
    let topmostLayerIDByPlotIndex: [Int: String]

    var body: some ChartContent {
        ForEach(layers) { layer in
            rectangle(for: layer)
        }
    }

    @ChartContentBuilder
    private func rectangle(for layer: DayStackLayer) -> some ChartContent {
        RectangleMark(
            xStart: .value(
                "Start",
                TwelveDayCombinedChart.dayBarXStart(plotIndex: layer.plotIndex, gap: gap)
            ),
            xEnd: .value(
                "End",
                TwelveDayCombinedChart.dayBarXEnd(plotIndex: layer.plotIndex, gap: gap)
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
            TwelveDayStackedUsageSegmentOverlay(
                layer: layer,
                slots: slots,
                labelOffsetX: segmentInteriorLabelOffsetXByLayerID[layer.id] ?? 0
            )
        }
        .annotation(position: .top, alignment: .center, spacing: 5) {
            if topmostLayerIDByPlotIndex[layer.plotIndex] == layer.id,
               slots.indices.contains(layer.plotIndex)
            {
                Text(twelveDayEstimatedTimeLabel(slot: slots[layer.plotIndex], rates: workloadRates))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
    }
}

/// Day totals from raw counts ÷ Average‑minute rates (same settings as the 12‑hour slider).
private func twelveDayEstimatedTimeLabel(slot: ComputerUsageDaySlot, rates: MacEstimatedWorkloadMinutes.Rates) -> String {
    let total = MacEstimatedWorkloadMinutes.totalMinutes(
        keystrokes: slot.keystrokeCount,
        clicks: slot.mouseClickCount,
        travelPixels: slot.travelPixels,
        scrollBumps: slot.scrollBumpCount,
        builtinKeystrokes: slot.builtinKeystrokeCount,
        builtinTrackpadClicks: slot.builtinTrackpadClickCount,
        builtinTrackpadTravelPixels: slot.builtinTrackpadTravelPixels,
        builtinTrackpadScrollPixels: slot.builtinTrackpadScrollPixels,
        rates: rates
    )
    return MacEstimatedWorkloadMinutes.compactDurationLabel(totalMinutes: total)
}


private func twelveDayColumnUsageMinutes(
    slot: ComputerUsageDaySlot,
    rates: MacEstimatedWorkloadMinutes.Rates
) -> (keyboard: Int, mouse: Int, macbookKeyboard: Int, macbookTrackpad: Int) {
    MacEstimatedWorkloadMinutes.columnBreakdown(
        keystrokes: slot.keystrokeCount,
        clicks: slot.mouseClickCount,
        travelPixels: slot.travelPixels,
        scrollBumps: slot.scrollBumpCount,
        builtinKeystrokes: slot.builtinKeystrokeCount,
        builtinTrackpadClicks: slot.builtinTrackpadClickCount,
        builtinTrackpadTravelPixels: slot.builtinTrackpadTravelPixels,
        builtinTrackpadScrollPixels: slot.builtinTrackpadScrollPixels,
        rates: rates
    )
}

private struct TwelveDayColumnContextMenuOverlay: View {
    let slots: [ComputerUsageDaySlot]
    let workloadRates: MacEstimatedWorkloadMinutes.Rates
    let gap: Double
    let chartProxy: ChartProxy
    let geometry: GeometryProxy

    var body: some View {
        if let plotFrameAnchor = chartProxy.plotFrame {
            let plotBounds = geometry[plotFrameAnchor]
            let regions = Array(slots.enumerated()).compactMap { idx, slot -> MacUsageBreakdownHitRegion? in
                let centerXData = TwelveDayCombinedChart.dayBarBucketCenter(plotIndex: idx)
                let xStartData = TwelveDayCombinedChart.dayBarXStart(plotIndex: idx, gap: gap)
                let xEndData = TwelveDayCombinedChart.dayBarXEnd(plotIndex: idx, gap: gap)
                guard let xStart = chartProxy.position(for: (x: xStartData, y: 0.0)),
                      let xEnd = chartProxy.position(for: (x: xEndData, y: 0.0)),
                      let yBottom = chartProxy.position(for: (x: centerXData, y: 0.0)),
                      let yTop = chartProxy.position(for: (x: centerXData, y: 10.0))
                else { return nil }
                let minutes = twelveDayColumnUsageMinutes(slot: slot, rates: workloadRates)
                return MacUsageBreakdownHitRegion(
                    frame: CGRect(
                        x: plotBounds.origin.x + min(xStart.x, xEnd.x),
                        y: plotBounds.origin.y + min(yBottom.y, yTop.y),
                        width: max(8, abs(xEnd.x - xStart.x)),
                        height: max(8, abs(yTop.y - yBottom.y))
                    ),
                    keyboardMinutes: minutes.keyboard,
                    mouseMinutes: minutes.mouse,
                    macbookKeyboardMinutes: minutes.macbookKeyboard,
                    macbookTrackpadMinutes: minutes.macbookTrackpad,
                    handTrackingDayStart: slot.dayStart
                )
            }
            MacUsageBreakdownRightClickLayer(regions: regions)
        }
    }
}

private struct TwelveDayPainConnectorLinesChartContent: ChartContent {
    let curves: [TwelveDayPainCurve]
    let samplesByCurve: [TwelveDayPainCurve: [DayPainSample]]
    let gap: Double

    var body: some ChartContent {
        ForEach(curves, id: \.rawValue) { curve in
            lines(for: curve, samples: samplesByCurve[curve] ?? [])
        }
    }

    @ChartContentBuilder
    private func lines(for curve: TwelveDayPainCurve, samples: [DayPainSample]) -> some ChartContent {
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

/// One visible pain dot — isolates ``PointMark`` + annotation typing (see ``TwelveDayPainDotsChartContent``).
private struct TwelveDayPainOneDotChartContent: ChartContent, Identifiable {
    let curve: TwelveDayPainCurve
    let sample: DayPainSample
    let gap: Double
    let slots: [ComputerUsageDaySlot]

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
            TwelveDayPainDotOverlay(sample: sample, curve: curve, slots: slots)
        }
    }
}

private struct TwelveDayPainDotsChartContent: ChartContent {
    let curves: [TwelveDayPainCurve]
    let samplesByCurve: [TwelveDayPainCurve: [DayPainSample]]
    let gap: Double
    let slots: [ComputerUsageDaySlot]

    private var flattenedDots: [TwelveDayPainOneDotChartContent] {
        curves.flatMap { curve in
            (samplesByCurve[curve] ?? []).map { sample in
                TwelveDayPainOneDotChartContent(curve: curve, sample: sample, gap: gap, slots: slots)
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
private func twelveDayChartDualXAxisMarks(slots: [ComputerUsageDaySlot]) -> some AxisContent {
    AxisMarks(values: TwelveDayCombinedChart.dayBoundaryTickPositions(barCount: slots.count)) { _ in
        AxisTick(length: 6, stroke: StrokeStyle(lineWidth: 1))
            .foregroundStyle(TwelveDayCombinedChart.axisBaseline)
    }
}

/// Same numeric ladder on left + right bar edges; captions distinguish **bars usage** vs **pain** interpretations.
@AxisContentBuilder
private func twelveDayDualPainYAxes() -> some AxisContent {
    let tickValues = stride(from: 0.0, through: 10.0, by: 2.0).map { $0 }

    AxisMarks(position: .leading, values: tickValues) { value in
        AxisTick().foregroundStyle(.secondary.opacity(0.55))
        AxisValueLabel {
            if let y = value.as(Double.self) {
                Text(twelveDayLeadingUsageHoursTickLabel(chartY: y))
            }
        }
    }

    AxisMarks(position: .trailing, values: tickValues) { value in
        AxisTick().foregroundStyle(.secondary.opacity(0.55))
        AxisValueLabel {
            if let y = value.as(Double.self) {
                Text(twelveDayYAxisNumericTickLabel(y))
            }
        }
    }
}

/// Maps plot Y `0…10` ↔ **0…5 h** on the bars side (ticks every 2 Y → 1 h).
private func twelveDayLeadingUsageHoursTickLabel(chartY: Double) -> String {
    guard chartY.isFinite else { return "—" }
    let h = Int((chartY / 2.0).rounded(.toNearestOrAwayFromZero))
    return "\(h) h"
}

private func twelveDayYAxisNumericTickLabel(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    let r = round(value)
    guard abs(value - r) >= 1e-3 else {
        return String(format: "%.0f", r)
    }
    return String(format: "%g", value)
}

/// Uses ``ChartProxy`` so `EEE M/d` aligns with geometric bar centres (Charts’ built‑in markers sit on boundary ticks).
private struct TwelveDayBarCenterDayLabelsOverlay: View {
    let slots: [ComputerUsageDaySlot]
    let chartProxy: ChartProxy
    let geometry: GeometryProxy

    var body: some View {
        if let plotFrameAnchor = chartProxy.plotFrame {
            let plotBounds = geometry[plotFrameAnchor]
            ForEach(Array(slots.enumerated()), id: \.offset) { pair in
                let idx = pair.offset
                let slot = pair.element
                let centerXData = TwelveDayCombinedChart.dayBarBucketCenter(plotIndex: idx)
                if let plotted = chartProxy.position(for: (x: centerXData, y: 0.0)) {
                    Text(TwelveDayCombinedChart.axisLabelFormatter.string(from: slot.dayStart))
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

/// Owns `Chart { … }` plus axis/scales — keeps ``TwelveDayPainChartPanel`` from inheriting giant `some View` composition.
private struct TwelveDayPainChartSurface: View {
    let slots: [ComputerUsageDaySlot]
    let stackLayers: [DayStackLayer]
    let workloadRates: MacEstimatedWorkloadMinutes.Rates
    let painSamplesByCurve: [TwelveDayPainCurve: [DayPainSample]]
    let activeCurves: [TwelveDayPainCurve]
    let gap: Double
    let segmentInteriorLabelOffsetXByLayerID: [String: CGFloat]

    private var topmostLayerIDByPlotIndex: [Int: String] {
        var byIndex: [Int: DayStackLayer] = [:]
        for layer in stackLayers {
            if (byIndex[layer.plotIndex]?.yHigh ?? -.infinity) < layer.yHigh {
                byIndex[layer.plotIndex] = layer
            }
        }
        return byIndex.mapValues(\.id)
    }

    var body: some View {
        Chart {
            TwelveDayBaselineRuleChartContent()
            TwelveDayStackedUsageRectanglesChartContent(
                layers: stackLayers,
                gap: gap,
                slots: slots,
                workloadRates: workloadRates,
                segmentInteriorLabelOffsetXByLayerID: segmentInteriorLabelOffsetXByLayerID,
                topmostLayerIDByPlotIndex: topmostLayerIDByPlotIndex
            )
            TwelveDayPainConnectorLinesChartContent(
                curves: activeCurves,
                samplesByCurve: painSamplesByCurve,
                gap: gap
            )
            TwelveDayPainDotsChartContent(
                curves: activeCurves,
                samplesByCurve: painSamplesByCurve,
                gap: gap,
                slots: slots
            )
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...10)
        .chartYAxis {
            twelveDayDualPainYAxes()
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
            domain: TwelveDayCombinedChart.chartXDomainLower(barCount: slots.count)
                ... TwelveDayCombinedChart.chartXDomainUpper(barCount: slots.count)
        )
        .chartXAxis {
            twelveDayChartDualXAxisMarks(slots: slots)
        }
        .frame(height: 276)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    TwelveDayBarCenterDayLabelsOverlay(slots: slots, chartProxy: proxy, geometry: geometry)
                    TwelveDayColumnContextMenuOverlay(
                        slots: slots,
                        workloadRates: workloadRates,
                        gap: gap,
                        chartProxy: proxy,
                        geometry: geometry
                    )
                }
            }
        }
    }
}

// MARK: - Chart panel

private struct TwelveDayPainChartPanel: View {
    let prepared: TwelveDayPainPrepared
    var painVisibility: TwelveDayPainVisibility
    let workloadRates: MacEstimatedWorkloadMinutes.Rates

    private var slots: [ComputerUsageDaySlot] { prepared.slots }

    private var gap: Double { TwelveDayCombinedChart.xSlotGap }

    private var activeCurves: [TwelveDayPainCurve] {
        TwelveDayPainCurve.allCases.filter { painVisibility.samplesActive(for: $0) }
    }

    private var segmentInteriorLabelOffsetXByLayerID: [String: CGFloat] { [:] }

    var body: some View {
        chartBody
    }

    private var chartBody: some View {
        TwelveDayPainChartSurface(
            slots: slots,
            stackLayers: prepared.stackLayers,
            workloadRates: workloadRates,
            painSamplesByCurve: prepared.painSamplesByCurve,
            activeCurves: activeCurves,
            gap: gap,
            segmentInteriorLabelOffsetXByLayerID: segmentInteriorLabelOffsetXByLayerID
        )
    }
}

// MARK: - Pain graph toggles

private struct TwelveDayPainGraphsToggleMatrix: View {
    @Binding var visibility: TwelveDayPainVisibility

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pain level graphs")
                .font(.caption.weight(.semibold))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(" ")
                    .frame(width: 38, alignment: .leading)
                columnHeader("Max")
                columnHeader("Avg")
                columnHeader("Morning")
            }
            .foregroundStyle(.secondary)

            toggleRow(sideLabel: "Left", keys: [.worstLeft, .averageLeft, .firstLeft])
            toggleRow(sideLabel: "Right", keys: [.worstRight, .averageRight, .firstRight])
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

    private func toggleRow(sideLabel: String, keys: [TwelveDayPainVisibilityKey]) -> some View {
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

    private func bool(for key: TwelveDayPainVisibilityKey) -> Bool {
        switch key {
        case .worstLeft: visibility.worstLeft
        case .averageLeft: visibility.averageLeft
        case .firstLeft: visibility.firstLeft
        case .worstRight: visibility.worstRight
        case .averageRight: visibility.averageRight
        case .firstRight: visibility.firstRight
        }
    }

    private func flipRow(keys: [TwelveDayPainVisibilityKey], isOn: Bool) {
        var next = visibility
        for key in keys {
            switch key {
            case .worstLeft: next.worstLeft = isOn
            case .averageLeft: next.averageLeft = isOn
            case .firstLeft: next.firstLeft = isOn
            case .worstRight: next.worstRight = isOn
            case .averageRight: next.averageRight = isOn
            case .firstRight: next.firstRight = isOn
            }
        }
        visibility = next
    }

    private func boolBinding(for key: TwelveDayPainVisibilityKey) -> Binding<Bool> {
        Binding(
            get: {
                switch key {
                case .worstLeft: visibility.worstLeft
                case .averageLeft: visibility.averageLeft
                case .firstLeft: visibility.firstLeft
                case .worstRight: visibility.worstRight
                case .averageRight: visibility.averageRight
                case .firstRight: visibility.firstRight
                }
            },
            set: { newValue in
                var next = visibility
                switch key {
                case .worstLeft: next.worstLeft = newValue
                case .averageLeft: next.averageLeft = newValue
                case .firstLeft: next.firstLeft = newValue
                case .worstRight: next.worstRight = newValue
                case .averageRight: next.averageRight = newValue
                case .firstRight: next.firstRight = newValue
                }
                visibility = next
            }
        )
    }
}

private enum TwelveDayPainVisibilityKey: Hashable {
    case worstLeft
    case averageLeft
    case firstLeft
    case worstRight
    case averageRight
    case firstRight
}

private enum TwelveDayUsageBarsAppStorage {
    static let showKeysKey = "HandTrack.mac.twelveDayChartShowKeys"
    static let showClicksKey = "HandTrack.mac.twelveDayChartShowClicks"
    static let showTravelKey = "HandTrack.mac.twelveDayChartShowPointerTravel"
    static let showScrollsKey = "HandTrack.mac.twelveDayChartShowScrolls"

    static let worstLeftKey = "HandTrack.mac.twelveDayPainWorstLeft"
    static let averageLeftKey = "HandTrack.mac.twelveDayPainAverageLeft"
    static let firstLeftKey = "HandTrack.mac.twelveDayPainFirstLeft"
    static let worstRightKey = "HandTrack.mac.twelveDayPainWorstRight"
    static let averageRightKey = "HandTrack.mac.twelveDayPainAverageRight"
    static let firstRightKey = "HandTrack.mac.twelveDayPainFirstRight"
}

private struct TwelveDayUsageBarsToggleStrip: View {
    @Binding var showKeys: Bool
    @Binding var showClicks: Bool
    @Binding var showTravel: Bool
    @Binding var showScrolls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage bars")
                .font(.caption.weight(.semibold))

            // Top → bottom matches bar stack: keys → clicks → scrolls → pointer (base).
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keys", isOn: $showKeys)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("Keystrokes segment (top of each column)")
                Toggle("Clicks", isOn: $showClicks)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("Mouse clicks segment")
                Toggle("Scrolls", isOn: $showScrolls)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("Mouse-wheel scroll bumps")
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

/// Twelve trailing calendar days: stacked usage (same scaling idea as twelve‑hour chart) vs iPhone pain rollup.
struct MacTwelveDayStackedUsagePainChart: View {
    @EnvironmentObject private var store: HandTrackStore

    @AppStorage(MacEstimatedWorkloadMinutes.keysPerMinuteKey) private var avgKeysPerMinute = MacEstimatedWorkloadMinutes.defaultKeysPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.clicksPerMinuteKey) private var avgClicksPerMinute = MacEstimatedWorkloadMinutes.defaultClicksPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.pixelThousandsPerMinuteKey) private var avgPixelThousandsPerMinute = MacEstimatedWorkloadMinutes.defaultPixelThousandsPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.scrollsPerMinuteKey) private var avgScrollsPerMinute = MacEstimatedWorkloadMinutes.defaultScrollsPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.trackpadTravelPixelThousandsPerMinuteKey)
    private var avgTrackpadTravelPixelThousandsPerMinute =
        MacEstimatedWorkloadMinutes.defaultTrackpadTravelPixelThousandsPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.trackpadScrollPixelThousandsPerMinuteKey)
    private var avgTrackpadScrollPixelThousandsPerMinute =
        MacEstimatedWorkloadMinutes.defaultTrackpadScrollPixelThousandsPerMinute

    @AppStorage(TwelveDayUsageBarsAppStorage.showKeysKey) private var twelveDayChartShowKeys = true
    @AppStorage(TwelveDayUsageBarsAppStorage.showClicksKey) private var twelveDayChartShowClicks = true
    @AppStorage(TwelveDayUsageBarsAppStorage.showTravelKey) private var twelveDayChartShowTravel = true
    @AppStorage(TwelveDayUsageBarsAppStorage.showScrollsKey) private var twelveDayChartShowScrolls = true

    @AppStorage(TwelveDayUsageBarsAppStorage.worstLeftKey) private var painWorstLeft = true
    @AppStorage(TwelveDayUsageBarsAppStorage.averageLeftKey) private var painAverageLeft = true
    @AppStorage(TwelveDayUsageBarsAppStorage.firstLeftKey) private var painFirstLeft = true
    @AppStorage(TwelveDayUsageBarsAppStorage.worstRightKey) private var painWorstRight = false
    @AppStorage(TwelveDayUsageBarsAppStorage.averageRightKey) private var painAverageRight = false
    @AppStorage(TwelveDayUsageBarsAppStorage.firstRightKey) private var painFirstRight = false

    private var painVisibilityBinding: Binding<TwelveDayPainVisibility> {
        Binding(
            get: {
                TwelveDayPainVisibility(
                    worstLeft: painWorstLeft,
                    averageLeft: painAverageLeft,
                    firstLeft: painFirstLeft,
                    worstRight: painWorstRight,
                    averageRight: painAverageRight,
                    firstRight: painFirstRight
                )
            },
            set: { newValue in
                painWorstLeft = newValue.worstLeft
                painAverageLeft = newValue.averageLeft
                painFirstLeft = newValue.firstLeft
                painWorstRight = newValue.worstRight
                painAverageRight = newValue.averageRight
                painFirstRight = newValue.firstRight
            }
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            MacTwelveDayStackedUsagePainChartFrame(
                store: store,
                referenceDate: timeline.date,
                refreshBucket: MacChartEquatableBucket.stackedChartClockBucket(timeline.date),
                painRevision: MacChartEquatableBucket.painLogsRevision(store),
                capsFingerprint: dayCapsFingerprint,
                usageVisibility: TwelveDayUsageModalityVisibility(
                    showKeystrokes: twelveDayChartShowKeys,
                    showMouseClicks: twelveDayChartShowClicks,
                    showTravel: twelveDayChartShowTravel,
                    showScrolls: twelveDayChartShowScrolls
                ),
                painVisibility: TwelveDayPainVisibility(
                    worstLeft: painWorstLeft,
                    averageLeft: painAverageLeft,
                    firstLeft: painFirstLeft,
                    worstRight: painWorstRight,
                    averageRight: painAverageRight,
                    firstRight: painFirstRight
                ),
                avgKeysPerMinute: avgKeysPerMinute,
                avgClicksPerMinute: avgClicksPerMinute,
                avgPixelThousandsPerMinute: avgPixelThousandsPerMinute,
                showKeys: $twelveDayChartShowKeys,
                showClicks: $twelveDayChartShowClicks,
                showTravel: $twelveDayChartShowTravel,
                showScrolls: $twelveDayChartShowScrolls,
                painVisibilityBinding: painVisibilityBinding
            )
            .equatable()
            .onAppear { ensureUsageBarsInvariant() }
            .onChange(of: twelveDayChartShowKeys) { _, _ in ensureUsageBarsInvariant() }
            .onChange(of: twelveDayChartShowClicks) { _, _ in ensureUsageBarsInvariant() }
            .onChange(of: twelveDayChartShowTravel) { _, _ in ensureUsageBarsInvariant() }
            .onChange(of: twelveDayChartShowScrolls) { _, _ in ensureUsageBarsInvariant() }
        }
    }

    private var dayCapsFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(avgKeysPerMinute)
        hasher.combine(avgClicksPerMinute)
        hasher.combine(avgPixelThousandsPerMinute)
        hasher.combine(avgScrollsPerMinute)
        hasher.combine(avgTrackpadTravelPixelThousandsPerMinute)
        hasher.combine(avgTrackpadScrollPixelThousandsPerMinute)
        return hasher.finalize()
    }

    private func ensureUsageBarsInvariant() {
        if !twelveDayChartShowKeys && !twelveDayChartShowClicks && !twelveDayChartShowTravel && !twelveDayChartShowScrolls {
            twelveDayChartShowKeys = true
        }
    }
}

private struct MacTwelveDayStackedUsagePainChartFrame: View, Equatable {
    let store: HandTrackStore
    let referenceDate: Date
    let refreshBucket: Int
    let painRevision: UInt64
    let capsFingerprint: Int
    let usageVisibility: TwelveDayUsageModalityVisibility
    let painVisibility: TwelveDayPainVisibility
    let avgKeysPerMinute: Int
    let avgClicksPerMinute: Int
    let avgPixelThousandsPerMinute: Int
    @Binding var showKeys: Bool
    @Binding var showClicks: Bool
    @Binding var showTravel: Bool
    @Binding var showScrolls: Bool
    var painVisibilityBinding: Binding<TwelveDayPainVisibility>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.refreshBucket == rhs.refreshBucket
            && lhs.painRevision == rhs.painRevision
            && lhs.capsFingerprint == rhs.capsFingerprint
            && lhs.usageVisibility == rhs.usageVisibility
            && lhs.painVisibility == rhs.painVisibility
    }

    var body: some View {
        let prepared = TwelveDayPainPrepared(store: store, referenceDate: referenceDate, usageVisibility: usageVisibility)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Past 12 days")
                    .font(.headline)
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 8) {
                    TwelveDayUsageBarsToggleStrip(
                        showKeys: $showKeys,
                        showClicks: $showClicks,
                        showTravel: $showTravel,
                        showScrolls: $showScrolls
                    )

                    TwelveDayPainGraphsToggleMatrix(visibility: painVisibilityBinding)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            TwelveDayPainChartPanel(
                prepared: prepared,
                painVisibility: painVisibility,
                workloadRates: .fromUserDefaults()
            )
        }
    }
}
