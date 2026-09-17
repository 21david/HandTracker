import AppKit
import Charts
import SwiftUI

private enum TwelveWeekCombinedChart {
    /// Comfort caps use this “reference day” extrapolation (`×12` five‑minute blocks → one hour‑wide slice).
    static let typicalWorkHours = 3.0
    static let scaleFactor = 12.0 * typicalWorkHours * 7.0

    /// Leading axis speaks in **hours 0 … ~5**, while plot Y stays `0 … 10` so pain stays on a 0–10 scale beside it.
    /// Calibrate modality caps (~legacy **three** heavy‑hour tiers) down so the **stack visually reaches the top nearer ~five aggregated hours**.
    static let hoursShownAtPlotTop = 30.0
    static let referenceHeavyHourBaseline = 30.0
    private static let usageCapEaseVersusDisplayedHours =
        referenceHeavyHourBaseline / hoursShownAtPlotTop

    /// Nudges plotted bars (+ pain line) slightly right (~20 % of a nominal day‑column) so x‑axis cues line up cleanly on device.
    static let horizontalBarShift = 0.2

    static func weekBarBucketCenter(plotIndex: Int) -> Double { Double(plotIndex) + 0.5 + horizontalBarShift }

    static func weekBarXStart(plotIndex: Int, gap: Double) -> Double { Double(plotIndex) + gap + horizontalBarShift }

    static func weekBarXEnd(plotIndex: Int, gap: Double) -> Double { Double(plotIndex + 1) - gap + horizontalBarShift }

    /// Integers **`1 … count−1`** (plus horizontal shift): vertical ticks sit **between** adjacent calendar‑day bars.
    static func weekBoundaryTickPositions(barCount: Int) -> [Double] {
        guard barCount > 1 else { return [] }
        return Array(1..<barCount).map { Double($0) + horizontalBarShift }
    }

    /// Pad from the **first / last bar edges** by the same amount so trailing vs leading margins match the stacked hour charts.
    static let chartXPlotSideInset: Double = 0.058

    static func chartXDomainLower(barCount _: Int) -> Double {
        weekBarXStart(plotIndex: 0, gap: xSlotGap) - chartXPlotSideInset
    }

    static func chartXDomainUpper(barCount: Int) -> Double {
        guard barCount > 0 else { return 1 }
        return weekBarXEnd(plotIndex: barCount - 1, gap: xSlotGap) + chartXPlotSideInset
    }

    static let keystrokesWeekCap = 275.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let keystrokesWeekExcess = 40.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let clicksWeekCap = 120.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let clicksWeekExcess = 17.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let travelWeekCap = 125_000.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let travelWeekExcess = 37_500.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    /// Matches live scroll five‑minute cap × same week scale factor as other modalities.
    static let scrollsWeekCap = 200.0 * scaleFactor * usageCapEaseVersusDisplayedHours
    static let scrollsWeekExcess = 40.0 * scaleFactor * usageCapEaseVersusDisplayedHours

    static let usageBandThird = 10.0 / 3.0

    static let xSlotGap = 0.04

    static let minimumStackHeightForInteriorLabel = 0.38

    static let axisBaseline = Color(.sRGB, white: 0.55, opacity: 1.0)

    static let weekAxisDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    /// Monday-based ``ComputerUsageWeekSlot.weekStart`` → preceding Sunday (Sun–Sat label span).
    static func sundayStart(forMondayWeekStart weekStart: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: weekStart) ?? weekStart
    }

    static func saturdayEnd(forMondayWeekStart weekStart: Date) -> Date {
        let sunday = sundayStart(forMondayWeekStart: weekStart)
        return Calendar.current.date(byAdding: .day, value: 6, to: sunday) ?? weekStart
    }

    static func weekOfYearNumber(forMondayWeekStart weekStart: Date) -> Int {
        Calendar.current.component(.weekOfYear, from: weekStart)
    }

    static func weekAxisCompactHeading(forMondayWeekStart weekStart: Date) -> String {
        let start = weekAxisDayFormatter.string(from: sundayStart(forMondayWeekStart: weekStart))
        let end = weekAxisDayFormatter.string(from: saturdayEnd(forMondayWeekStart: weekStart))
        return "\(start) - \(end)"
    }
}

// MARK: - Types & prep

private enum StackWeekMetric: Hashable {
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

    func tooltipText(plotIndex: Int, slots: [ComputerUsageWeekSlot]) -> String {
        let bucket = slots.indices.contains(plotIndex)
            ? TwelveWeekCombinedChart.weekAxisCompactHeading(forMondayWeekStart: slots[plotIndex].weekStart)
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

private struct WeekStackLayer: Identifiable {
    let plotIndex: Int
    let metric: StackWeekMetric
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

private struct TwelveWeekUsageModalityVisibility: Equatable {
    var showKeystrokes: Bool
    var showMouseClicks: Bool
    var showTravel: Bool
    var showScrolls: Bool

    static let allVisible = TwelveWeekUsageModalityVisibility(
        showKeystrokes: true,
        showMouseClicks: true,
        showTravel: true,
        showScrolls: true
    )
}

/// One Mac‑friendly pain statistic on the 12‑day chart (**per hand** × **metric**).
private enum TwelveWeekPainCurve: String, CaseIterable, Identifiable {
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

    func helpLine(weekHeading: String, compactPain: String) -> String {
        let handLetter: String
        switch self {
        case .worstLeft, .averageLeft: handLetter = "L"
        default: handLetter = "R"
        }
        switch self {
        case .worstLeft, .worstRight:
            return "\(weekHeading): \(handLetter) max \(compactPain)"
        case .averageLeft, .averageRight:
            return "\(weekHeading): \(handLetter) avg \(compactPain)"
        }
    }
}

/// One decimal chip for averages: `3.3`, drops trailing `.0` → `5`.
private func twelveWeekAveragePainChipString(_ pain: Double) -> String {
    let t = round(pain * 10) / 10
    let frac = abs(t.truncatingRemainder(dividingBy: 1))
    guard frac >= 1e-4 else {
        return String(format: "%.0f", t.rounded(.toNearestOrAwayFromZero))
    }
    return String(format: "%.1f", t)
}

private struct WeekPainSample: Identifiable {
    let plotIndex: Int
    let pain: Double
    let curve: TwelveWeekPainCurve

    var id: String { "\(curve.rawValue)-\(plotIndex)" }

    func plotX(gap: Double) -> Double {
        let frac = curve.fractionAlongBar
        let leading = TwelveWeekCombinedChart.weekBarXStart(plotIndex: plotIndex, gap: gap)
        let trailing = TwelveWeekCombinedChart.weekBarXEnd(plotIndex: plotIndex, gap: gap)
        return leading + frac * (trailing - leading)
    }
}

/// Extracted so `PointMark` annotations don't participate in huge `some View` inference inside `Chart`.
private struct TwelveWeekPainDotOverlay: View {
    let sample: WeekPainSample
    let curve: TwelveWeekPainCurve
    let slots: [ComputerUsageWeekSlot]

    private var compactPainLabel: String {
        switch curve {
        case .averageLeft, .averageRight:
            return twelveWeekAveragePainChipString(sample.pain)
        default:
            return sample.pain.handTrackPainCompactLabel
        }
    }

    private var hoverTip: String {
        let weekHeading = slots.indices.contains(sample.plotIndex)
            ? TwelveWeekCombinedChart.weekAxisCompactHeading(forMondayWeekStart: slots[sample.plotIndex].weekStart)
            : "?"
        return curve.helpLine(weekHeading: weekHeading, compactPain: compactPainLabel)
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

private func weekCappedFraction(_ value: Double, cap: Double) -> Double {
    guard cap > 0 else { return 0 }
    return min(1, value / cap)
}

/// Same workload ladder as the twelve-day chart: `plotY / 2` → hours.
private func twelveWeekEstimatedMinutes(plotY: Double) -> Int {
    guard plotY.isFinite, plotY > 0 else { return 0 }
    let hours = max(0, plotY / 2.0)
    return Int((hours * 60.0).rounded(.toNearestOrAwayFromZero))
}

private func twelveWeekEstimatedTimeLabel(plotY: Double) -> String {
    let totalMinutes = twelveWeekEstimatedMinutes(plotY: plotY)
    guard totalMinutes > 0 else { return "" }
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}

private func twelveWeekColumnUsageMinutes(
    plotIndex: Int,
    plotY: Double,
    stackLayers: [WeekStackLayer]
) -> (keyboard: Int, mouse: Int) {
    let total = twelveWeekEstimatedMinutes(plotY: plotY)
    guard total > 0 else { return (0, 0) }
    var keysY = 0.0
    var mouseY = 0.0
    for layer in stackLayers where layer.plotIndex == plotIndex {
        let h = layer.yHigh - layer.yLow
        switch layer.metric {
        case .keystrokes:
            keysY += h
        case .mouseClicks, .travel, .scrollBumps:
            mouseY += h
        }
    }
    let sum = keysY + mouseY
    guard sum > 1e-9 else { return (0, total) }
    let keyboard = Int((Double(total) * keysY / sum).rounded(.toNearestOrAwayFromZero))
    return (keyboard, max(0, total - keyboard))
}

private struct TwelveWeekColumnContextMenuOverlay: View {
    let slots: [ComputerUsageWeekSlot]
    let stackLayers: [WeekStackLayer]
    let topPlotYByIndex: [Int: Double]
    let gap: Double
    let chartProxy: ChartProxy
    let geometry: GeometryProxy

    var body: some View {
        if let plotFrameAnchor = chartProxy.plotFrame {
            let plotBounds = geometry[plotFrameAnchor]
            let regions = Array(slots.enumerated()).compactMap { idx, slot -> MacUsageBreakdownHitRegion? in
                let centerXData = TwelveWeekCombinedChart.weekBarBucketCenter(plotIndex: idx)
                let xStartData = TwelveWeekCombinedChart.weekBarXStart(plotIndex: idx, gap: gap)
                let xEndData = TwelveWeekCombinedChart.weekBarXEnd(plotIndex: idx, gap: gap)
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
                    builtinKeystrokes: slot.builtinKeystrokeCount,
                    builtinTrackpadClicks: slot.builtinTrackpadClickCount,
                    builtinTrackpadTravelPixels: slot.builtinTrackpadTravelPixels,
                    builtinTrackpadScrollPixels: slot.builtinTrackpadScrollPixels,
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
                    mouseMinutes: minutes.mouse,
                    macbookKeyboardMinutes: minutes.macbookKeyboard,
                    macbookTrackpadMinutes: minutes.macbookTrackpad
                )
            }
            MacUsageBreakdownRightClickLayer(regions: regions)
        }
    }
}

private struct BuiltWeekMetricStage {
    let unscaledHeight: Double
    let stress: Double
    let metric: StackWeekMetric
}

private func buildWeekStackLayers(
    slots: [ComputerUsageWeekSlot],
    usageVisibility: TwelveWeekUsageModalityVisibility,
    rates: MacEstimatedWorkloadMinutes.Rates = .fromUserDefaults()
) -> [WeekStackLayer] {
    /// Fixed **10 ÷ 3** band per modality (same height meaning as toggling overlays off in the twelve‑hour chart).
    let bandSlice = TwelveWeekCombinedChart.usageBandThird
    let maxComposite = 10.0
    guard usageVisibility.showKeystrokes || usageVisibility.showMouseClicks || usageVisibility.showTravel || usageVisibility.showScrolls else {
        return []
    }

    var rows: [WeekStackLayer] = []

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

        let keysFrac = weekCappedFraction(Double(keysTotal), cap: TwelveWeekCombinedChart.keystrokesWeekCap)
        let clickFrac = weekCappedFraction(Double(clicksTotal), cap: TwelveWeekCombinedChart.clicksWeekCap)
        let travelFrac = weekCappedFraction(travelTotal, cap: TwelveWeekCombinedChart.travelWeekCap)
        let scrollFrac = weekCappedFraction(Double(scrollsTotal), cap: TwelveWeekCombinedChart.scrollsWeekCap)

        let sKeys = MacFiveMinuteBarStyle.stressAmount(
            from: Double(keysTotal),
            cap: TwelveWeekCombinedChart.keystrokesWeekCap,
            excessWidth: TwelveWeekCombinedChart.keystrokesWeekExcess
        )
        let sClicks = MacFiveMinuteBarStyle.stressAmount(
            from: Double(clicksTotal),
            cap: TwelveWeekCombinedChart.clicksWeekCap,
            excessWidth: TwelveWeekCombinedChart.clicksWeekExcess
        )
        let sTravel = MacFiveMinuteBarStyle.stressAmount(
            from: travelTotal,
            cap: TwelveWeekCombinedChart.travelWeekCap,
            excessWidth: TwelveWeekCombinedChart.travelWeekExcess
        )
        let sScrolls = MacFiveMinuteBarStyle.stressAmount(
            from: Double(scrollsTotal),
            cap: TwelveWeekCombinedChart.scrollsWeekCap,
            excessWidth: TwelveWeekCombinedChart.scrollsWeekExcess
        )

        // Stack bottom → top: pointer travel → scrolls → clicks → keys.
        // Keep 10÷3 band size so columns with no scrolls match prior heights.
        var stages: [BuiltWeekMetricStage] = []
        if usageVisibility.showTravel {
            let h = travelFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltWeekMetricStage(unscaledHeight: h, stress: sTravel, metric: .travel(travelTotal)))
            }
        }
        if usageVisibility.showScrolls {
            let h = scrollFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltWeekMetricStage(unscaledHeight: h, stress: sScrolls, metric: .scrollBumps(scrollsTotal)))
            }
        }
        if usageVisibility.showMouseClicks {
            let h = clickFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltWeekMetricStage(unscaledHeight: h, stress: sClicks, metric: .mouseClicks(clicksTotal)))
            }
        }
        if usageVisibility.showKeystrokes {
            let h = keysFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltWeekMetricStage(unscaledHeight: h, stress: sKeys, metric: .keystrokes(keysTotal)))
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
            rows.append(WeekStackLayer(
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

private struct TwelveWeekPainPrepared {
    let slots: [ComputerUsageWeekSlot]
    let stackLayers: [WeekStackLayer]
    /// One array per ``TwelveWeekPainCurve`` (possibly empty when all days lack data).
    let painSamplesByCurve: [TwelveWeekPainCurve: [WeekPainSample]]

    @MainActor
    init(
        slots: [ComputerUsageWeekSlot],
        painsByCurve: [TwelveWeekPainCurve: [Double?]],
        usageVisibility: TwelveWeekUsageModalityVisibility = .allVisible
    ) {
        for curve in TwelveWeekPainCurve.allCases {
            precondition(painsByCurve[curve]?.count == slots.count, "pain array length must match day slots")
        }
        self.slots = slots
        stackLayers = buildWeekStackLayers(slots: slots, usageVisibility: usageVisibility, rates: .fromUserDefaults())

        var byCurve: [TwelveWeekPainCurve: [WeekPainSample]] = [:]
        for curve in TwelveWeekPainCurve.allCases {
            byCurve[curve] = TwelveWeekPainPrepared.curveSamples(
                slots: slots,
                vals: painsByCurve[curve]!,
                curve: curve
            )
        }
        painSamplesByCurve = byCurve
    }

    @MainActor
    init(store: HandTrackStore, referenceDate: Date, usageVisibility: TwelveWeekUsageModalityVisibility) {
        let s = store.computerUsageByTrailingCalendarWeeks(reference: referenceDate, count: 12)
        let ds = s.map(\.weekStart)
        let pains: [TwelveWeekPainCurve: [Double?]] = [
            .worstLeft: store.weeklyPainWorstLoggedLeftHand(forOrderedWeekStarts: ds),
            .worstRight: store.weeklyPainWorstLoggedRightHand(forOrderedWeekStarts: ds),
            .averageLeft: store.weeklyPainMeanLoggedLeftHand(forOrderedWeekStarts: ds),
            .averageRight: store.weeklyPainMeanLoggedRightHand(forOrderedWeekStarts: ds),
        ]
        self.init(slots: s, painsByCurve: pains, usageVisibility: usageVisibility)
    }

    private static func curveSamples(
        slots: [ComputerUsageWeekSlot],
        vals: [Double?],
        curve: TwelveWeekPainCurve
    ) -> [WeekPainSample] {
        zip(slots.indices, vals).compactMap { idx, optionalPain -> WeekPainSample? in
            guard let p = optionalPain else { return nil }
            return WeekPainSample(plotIndex: idx, pain: p, curve: curve)
        }
        .sorted { $0.plotIndex < $1.plotIndex }
    }
}

// MARK: - Pain visibility (6 lightweight toggles)

private struct TwelveWeekPainVisibility: Equatable {
    var worstLeft = false
    var averageLeft = false
    var worstRight = false
    var averageRight = false

    func samplesActive(for curve: TwelveWeekPainCurve) -> Bool {
        switch curve {
        case .worstLeft: worstLeft
        case .averageLeft: averageLeft
        case .worstRight: worstRight
        case .averageRight: averageRight
        }
    }
}

// MARK: - Chart content slices (keeps Swift type-check feasible)

private struct TwelveWeekBaselineRuleChartContent: ChartContent {
    var body: some ChartContent {
        RuleMark(y: .value("Baseline", 0.0))
            .foregroundStyle(TwelveWeekCombinedChart.axisBaseline)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }
}

private struct TwelveWeekStackedUsageSegmentOverlay: View {
    let layer: WeekStackLayer
    let slots: [ComputerUsageWeekSlot]
    let labelOffsetX: CGFloat

    private var showsInteriorCaption: Bool {
        layer.yHigh - layer.yLow >= TwelveWeekCombinedChart.minimumStackHeightForInteriorLabel
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

private struct TwelveWeekStackedUsageRectanglesChartContent: ChartContent {
    let layers: [WeekStackLayer]
    let gap: Double
    let slots: [ComputerUsageWeekSlot]
    let segmentInteriorLabelOffsetXByLayerID: [String: CGFloat]
    let topmostLayerIDByPlotIndex: [Int: String]

    var body: some ChartContent {
        ForEach(layers) { layer in
            rectangle(for: layer)
        }
    }

    @ChartContentBuilder
    private func rectangle(for layer: WeekStackLayer) -> some ChartContent {
        RectangleMark(
            xStart: .value(
                "Start",
                TwelveWeekCombinedChart.weekBarXStart(plotIndex: layer.plotIndex, gap: gap)
            ),
            xEnd: .value(
                "End",
                TwelveWeekCombinedChart.weekBarXEnd(plotIndex: layer.plotIndex, gap: gap)
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
            TwelveWeekStackedUsageSegmentOverlay(
                layer: layer,
                slots: slots,
                labelOffsetX: segmentInteriorLabelOffsetXByLayerID[layer.id] ?? 0
            )
        }
        .annotation(position: .top, alignment: .center, spacing: 5) {
            if topmostLayerIDByPlotIndex[layer.plotIndex] == layer.id {
                Text(twelveWeekEstimatedTimeLabel(plotY: layer.yHigh))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
    }
}

private struct TwelveWeekPainConnectorLinesChartContent: ChartContent {
    let curves: [TwelveWeekPainCurve]
    let samplesByCurve: [TwelveWeekPainCurve: [WeekPainSample]]
    let gap: Double

    var body: some ChartContent {
        ForEach(curves, id: \.rawValue) { curve in
            lines(for: curve, samples: samplesByCurve[curve] ?? [])
        }
    }

    @ChartContentBuilder
    private func lines(for curve: TwelveWeekPainCurve, samples: [WeekPainSample]) -> some ChartContent {
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

/// One visible pain dot — isolates ``PointMark`` + annotation typing (see ``TwelveWeekPainDotsChartContent``).
private struct TwelveWeekPainOneDotChartContent: ChartContent, Identifiable {
    let curve: TwelveWeekPainCurve
    let sample: WeekPainSample
    let gap: Double
    let slots: [ComputerUsageWeekSlot]

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
            TwelveWeekPainDotOverlay(sample: sample, curve: curve, slots: slots)
        }
    }
}

private struct TwelveWeekPainDotsChartContent: ChartContent {
    let curves: [TwelveWeekPainCurve]
    let samplesByCurve: [TwelveWeekPainCurve: [WeekPainSample]]
    let gap: Double
    let slots: [ComputerUsageWeekSlot]

    private var flattenedDots: [TwelveWeekPainOneDotChartContent] {
        curves.flatMap { curve in
            (samplesByCurve[curve] ?? []).map { sample in
                TwelveWeekPainOneDotChartContent(curve: curve, sample: sample, gap: gap, slots: slots)
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
private func twelveWeekChartDualXAxisMarks(slots: [ComputerUsageWeekSlot]) -> some AxisContent {
    AxisMarks(values: TwelveWeekCombinedChart.weekBoundaryTickPositions(barCount: slots.count)) { _ in
        AxisTick(length: 6, stroke: StrokeStyle(lineWidth: 1))
            .foregroundStyle(TwelveWeekCombinedChart.axisBaseline)
    }
}

/// Same numeric ladder on left + right bar edges; captions distinguish **bars usage** vs **pain** interpretations.
@AxisContentBuilder
private func twelveWeekDualPainYAxes() -> some AxisContent {
    let tickValues = stride(from: 0.0, through: 10.0, by: 2.0).map { $0 }

    AxisMarks(position: .leading, values: tickValues) { value in
        AxisTick().foregroundStyle(.secondary.opacity(0.55))
        AxisValueLabel {
            if let y = value.as(Double.self) {
                Text(twelveWeekLeadingUsageHoursTickLabel(chartY: y))
            }
        }
    }

    AxisMarks(position: .trailing, values: tickValues) { value in
        AxisTick().foregroundStyle(.secondary.opacity(0.55))
        AxisValueLabel {
            if let y = value.as(Double.self) {
                Text(twelveWeekYAxisNumericTickLabel(y))
            }
        }
    }
}

/// Maps plot Y `0…10` ↔ **0…5 h** on the bars side (ticks every 2 Y → 1 h).
private func twelveWeekLeadingUsageHoursTickLabel(chartY: Double) -> String {
    guard chartY.isFinite else { return "—" }
    let h = Int((chartY * 3.0).rounded(.toNearestOrAwayFromZero))
    return "\(h) h"
}

private func twelveWeekYAxisNumericTickLabel(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    let r = round(value)
    guard abs(value - r) >= 1e-3 else {
        return String(format: "%.0f", r)
    }
    return String(format: "%g", value)
}

/// Uses ``ChartProxy`` so Sun–Sat range labels align with geometric bar centres.
private struct TwelveWeekBarCenterWeekLabelsOverlay: View {
    let slots: [ComputerUsageWeekSlot]
    let chartProxy: ChartProxy
    let geometry: GeometryProxy

    var body: some View {
        if let plotFrameAnchor = chartProxy.plotFrame {
            let plotBounds = geometry[plotFrameAnchor]
            ForEach(Array(slots.enumerated()), id: \.offset) { pair in
                let idx = pair.offset
                let slot = pair.element
                let centerXData = TwelveWeekCombinedChart.weekBarBucketCenter(plotIndex: idx)
                if let plotted = chartProxy.position(for: (x: centerXData, y: 0.0)) {
                    let rangeStart = TwelveWeekCombinedChart.sundayStart(forMondayWeekStart: slot.weekStart)
                    let rangeEnd = TwelveWeekCombinedChart.saturdayEnd(forMondayWeekStart: slot.weekStart)
                    let startLabel = TwelveWeekCombinedChart.weekAxisDayFormatter.string(from: rangeStart)
                    let endLabel = TwelveWeekCombinedChart.weekAxisDayFormatter.string(from: rangeEnd)
                    Text("\(startLabel) - \(endLabel)")
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

/// Owns `Chart { … }` plus axis/scales — keeps ``TwelveWeekPainChartPanel`` from inheriting giant `some View` composition.
private struct TwelveWeekPainChartSurface: View {
    let slots: [ComputerUsageWeekSlot]
    let stackLayers: [WeekStackLayer]
    let painSamplesByCurve: [TwelveWeekPainCurve: [WeekPainSample]]
    let activeCurves: [TwelveWeekPainCurve]
    let gap: Double
    let segmentInteriorLabelOffsetXByLayerID: [String: CGFloat]

    private var topmostLayerIDByPlotIndex: [Int: String] {
        var byIndex: [Int: WeekStackLayer] = [:]
        for layer in stackLayers {
            if (byIndex[layer.plotIndex]?.yHigh ?? -.infinity) < layer.yHigh {
                byIndex[layer.plotIndex] = layer
            }
        }
        return byIndex.mapValues(\.id)
    }

    private var topPlotYByIndex: [Int: Double] {
        var byIndex: [Int: WeekStackLayer] = [:]
        for layer in stackLayers {
            if (byIndex[layer.plotIndex]?.yHigh ?? -.infinity) < layer.yHigh {
                byIndex[layer.plotIndex] = layer
            }
        }
        return byIndex.mapValues(\.yHigh)
    }

    var body: some View {
        Chart {
            TwelveWeekBaselineRuleChartContent()
            TwelveWeekStackedUsageRectanglesChartContent(
                layers: stackLayers,
                gap: gap,
                slots: slots,
                segmentInteriorLabelOffsetXByLayerID: segmentInteriorLabelOffsetXByLayerID,
                topmostLayerIDByPlotIndex: topmostLayerIDByPlotIndex
            )
            TwelveWeekPainConnectorLinesChartContent(
                curves: activeCurves,
                samplesByCurve: painSamplesByCurve,
                gap: gap
            )
            TwelveWeekPainDotsChartContent(
                curves: activeCurves,
                samplesByCurve: painSamplesByCurve,
                gap: gap,
                slots: slots
            )
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...10)
        .chartYAxis {
            twelveWeekDualPainYAxes()
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
            domain: TwelveWeekCombinedChart.chartXDomainLower(barCount: slots.count)
                ... TwelveWeekCombinedChart.chartXDomainUpper(barCount: slots.count)
        )
        .chartXAxis {
            twelveWeekChartDualXAxisMarks(slots: slots)
        }
        .frame(height: 320)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    TwelveWeekBarCenterWeekLabelsOverlay(slots: slots, chartProxy: proxy, geometry: geometry)
                    TwelveWeekColumnContextMenuOverlay(
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
private struct MacTwelveWeekChartPanelRender: View, Equatable {
    let store: HandTrackStore
    let referenceHour: Date
    let painLogsRevision: UInt64
    let usageBarsVisibility: TwelveWeekUsageModalityVisibility
    let painVisibility: TwelveWeekPainVisibility

    var body: some View {
        let prepared = TwelveWeekPainPrepared(
            store: store,
            referenceDate: referenceHour,
            usageVisibility: usageBarsVisibility
        )
        TwelveWeekPainChartPanel(prepared: prepared, painVisibility: painVisibility)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.referenceHour == rhs.referenceHour
            && lhs.painLogsRevision == rhs.painLogsRevision
            && lhs.usageBarsVisibility == rhs.usageBarsVisibility
            && lhs.painVisibility == rhs.painVisibility
    }
}

// MARK: - Chart panel

private struct TwelveWeekPainChartPanel: View {
    let prepared: TwelveWeekPainPrepared
    var painVisibility: TwelveWeekPainVisibility

    private var slots: [ComputerUsageWeekSlot] { prepared.slots }

    private var gap: Double { TwelveWeekCombinedChart.xSlotGap }

    private var activeCurves: [TwelveWeekPainCurve] {
        TwelveWeekPainCurve.allCases.filter { painVisibility.samplesActive(for: $0) }
    }

    private var segmentInteriorLabelOffsetXByLayerID: [String: CGFloat] { [:] }

    var body: some View {
        chartBody
    }

    private var chartBody: some View {
        TwelveWeekPainChartSurface(
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

private struct TwelveWeekPainGraphsToggleMatrix: View {
    @Binding var visibility: TwelveWeekPainVisibility

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

    private func toggleRow(sideLabel: String, keys: [TwelveWeekPainVisibilityKey]) -> some View {
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

    private func bool(for key: TwelveWeekPainVisibilityKey) -> Bool {
        switch key {
        case .worstLeft: visibility.worstLeft
        case .averageLeft: visibility.averageLeft
        case .worstRight: visibility.worstRight
        case .averageRight: visibility.averageRight
        }
    }

    private func flipRow(keys: [TwelveWeekPainVisibilityKey], isOn: Bool) {
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

    private func boolBinding(for key: TwelveWeekPainVisibilityKey) -> Binding<Bool> {
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

private enum TwelveWeekPainVisibilityKey: Hashable {
    case worstLeft
    case averageLeft
    case worstRight
    case averageRight
}

private enum TwelveWeekUsageBarsAppStorage {
    static let showKeysKey = "HandTrack.mac.twelveWeekChartShowKeys"
    static let showClicksKey = "HandTrack.mac.twelveWeekChartShowClicks"
    static let showTravelKey = "HandTrack.mac.twelveWeekChartShowPointerTravel"
    static let showScrollsKey = "HandTrack.mac.twelveWeekChartShowScrolls"

    static let worstLeftKey = "HandTrack.mac.twelveWeekPainWorstLeft"
    static let averageLeftKey = "HandTrack.mac.twelveWeekPainAverageLeft"
    static let worstRightKey = "HandTrack.mac.twelveWeekPainWorstRight"
    static let averageRightKey = "HandTrack.mac.twelveWeekPainAverageRight"
}

private struct TwelveWeekUsageBarsToggleStrip: View {
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

/// Twelve trailing calendar weeks: stacked usage (same scaling idea as twelve‑hour chart) vs iPhone pain rollup.
struct MacTwelveWeekStackedUsagePainChart: View {
    @EnvironmentObject private var store: HandTrackStore

    @AppStorage(TwelveWeekUsageBarsAppStorage.showKeysKey) private var twelveWeekChartShowKeys = true
    @AppStorage(TwelveWeekUsageBarsAppStorage.showClicksKey) private var twelveWeekChartShowClicks = true
    @AppStorage(TwelveWeekUsageBarsAppStorage.showTravelKey) private var twelveWeekChartShowTravel = true
    @AppStorage(TwelveWeekUsageBarsAppStorage.showScrollsKey) private var twelveWeekChartShowScrolls = true

    @AppStorage(TwelveWeekUsageBarsAppStorage.worstLeftKey) private var painWorstLeft = true
    @AppStorage(TwelveWeekUsageBarsAppStorage.averageLeftKey) private var painAverageLeft = true
    @AppStorage(TwelveWeekUsageBarsAppStorage.worstRightKey) private var painWorstRight = false
    @AppStorage(TwelveWeekUsageBarsAppStorage.averageRightKey) private var painAverageRight = false

    private var painVisibilityBinding: Binding<TwelveWeekPainVisibility> {
        Binding(
            get: {
                TwelveWeekPainVisibility(
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
        let usageBarsVisibility = TwelveWeekUsageModalityVisibility(
            showKeystrokes: twelveWeekChartShowKeys,
            showMouseClicks: twelveWeekChartShowClicks,
            showTravel: twelveWeekChartShowTravel,
            showScrolls: twelveWeekChartShowScrolls
        )
        let painVisibility = TwelveWeekPainVisibility(
            worstLeft: painWorstLeft,
            averageLeft: painAverageLeft,
            worstRight: painWorstRight,
            averageRight: painAverageRight
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Past 12 weeks")
                    .font(.headline)
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 8) {
                    TwelveWeekUsageBarsToggleStrip(
                        showKeys: $twelveWeekChartShowKeys,
                        showClicks: $twelveWeekChartShowClicks,
                        showTravel: $twelveWeekChartShowTravel,
                        showScrolls: $twelveWeekChartShowScrolls
                    )

                    TwelveWeekPainGraphsToggleMatrix(visibility: painVisibilityBinding)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            MacTwelveWeekChartPanelRender(
                store: store,
                referenceHour: MacChartEquatableBucket.hourStart(referenceDate),
                painLogsRevision: MacChartEquatableBucket.painLogsRevision(store),
                usageBarsVisibility: usageBarsVisibility,
                painVisibility: painVisibility
            )
            .equatable()
        }
        .padding(.bottom, 44)
        .onAppear {
            ensureUsageBarsInvariant()
        }
        .onChange(of: twelveWeekChartShowKeys) { _, _ in ensureUsageBarsInvariant() }
        .onChange(of: twelveWeekChartShowClicks) { _, _ in ensureUsageBarsInvariant() }
        .onChange(of: twelveWeekChartShowTravel) { _, _ in ensureUsageBarsInvariant() }
        .onChange(of: twelveWeekChartShowScrolls) { _, _ in ensureUsageBarsInvariant() }
    }

    private func ensureUsageBarsInvariant() {
        if !twelveWeekChartShowKeys && !twelveWeekChartShowClicks && !twelveWeekChartShowTravel && !twelveWeekChartShowScrolls {
            twelveWeekChartShowKeys = true
        }
    }
}
