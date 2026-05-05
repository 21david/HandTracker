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
        }
    }
}

private struct TwelveDayUsageModalityVisibility: Equatable {
    var showKeystrokes: Bool
    var showMouseClicks: Bool
    var showTravel: Bool

    static let allVisible = TwelveDayUsageModalityVisibility(
        showKeystrokes: true,
        showMouseClicks: true,
        showTravel: true
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
    usageVisibility: TwelveDayUsageModalityVisibility
) -> [DayStackLayer] {
    /// Fixed **10 ÷ 3** band per modality (same height meaning as toggling overlays off in the twelve‑hour chart).
    let bandSlice = TwelveDayCombinedChart.usageBandThird
    let maxComposite = 10.0
    guard usageVisibility.showKeystrokes || usageVisibility.showMouseClicks || usageVisibility.showTravel else {
        return []
    }

    var rows: [DayStackLayer] = []

    for (i, slot) in slots.enumerated() {
        let keysFrac = dayCappedFraction(Double(slot.keystrokeCount), cap: TwelveDayCombinedChart.keystrokesDayCap)
        let clickFrac = dayCappedFraction(Double(slot.mouseClickCount), cap: TwelveDayCombinedChart.clicksDayCap)
        let travelFrac = dayCappedFraction(slot.travelPixels, cap: TwelveDayCombinedChart.travelDayCap)

        let sKeys = MacFiveMinuteBarStyle.stressAmount(
            from: Double(slot.keystrokeCount),
            cap: TwelveDayCombinedChart.keystrokesDayCap,
            excessWidth: TwelveDayCombinedChart.keystrokesDayExcess
        )
        let sClicks = MacFiveMinuteBarStyle.stressAmount(
            from: Double(slot.mouseClickCount),
            cap: TwelveDayCombinedChart.clicksDayCap,
            excessWidth: TwelveDayCombinedChart.clicksDayExcess
        )
        let sTravel = MacFiveMinuteBarStyle.stressAmount(
            from: slot.travelPixels,
            cap: TwelveDayCombinedChart.travelDayCap,
            excessWidth: TwelveDayCombinedChart.travelDayExcess
        )

        // Stack bottom → top: pointer travel → clicks → keys (same order as twelve‑hour chart).
        var stages: [BuiltDayMetricStage] = []
        if usageVisibility.showTravel {
            let h = travelFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltDayMetricStage(unscaledHeight: h, stress: sTravel, metric: .travel(slot.travelPixels)))
            }
        }
        if usageVisibility.showMouseClicks {
            let h = clickFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltDayMetricStage(unscaledHeight: h, stress: sClicks, metric: .mouseClicks(slot.mouseClickCount)))
            }
        }
        if usageVisibility.showKeystrokes {
            let h = keysFrac * bandSlice
            if h > 0.000_1 {
                stages.append(BuiltDayMetricStage(unscaledHeight: h, stress: sKeys, metric: .keystrokes(slot.keystrokeCount)))
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

// MARK: - Synthetic 12‑day preview (offline; not written to SQLite)

private struct TwelveDayRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xD1CE_F00D_DEAD_BEEF : seed
    }

    mutating func nextWord() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unitInterval01() -> Double {
        Double(nextWord() >> 11) / Double(1 << 53)
    }

    mutating func uniformOpen(_ low: Double, _ high: Double) -> Double {
        guard low < high else { return low }
        return low + (high - low) * unitInterval01()
    }

    mutating func intBelow(_ upperExclusive: Int) -> Int {
        guard upperExclusive > 0 else { return 0 }
        return Int(nextWord() % UInt64(upperExclusive))
    }

    /// Inclusive of both bounds.
    mutating func intInclusive(lower: Int, upper: Int) -> Int {
        guard upper >= lower else { return lower }
        return lower + intBelow(upper - lower + 1)
    }

    /// Fisher–Yates (deterministic seed stream).
    mutating func shuffle<A>(_ xs: inout [A]) {
        guard xs.count > 1 else { return }
        for idx in stride(from: xs.count - 1, through: 1, by: -1) {
            let j = intInclusive(lower: 0, upper: idx)
            xs.swapAt(idx, j)
        }
    }
}

private enum TwelveDaySyntheticSeries {
    private static func snapHalfStep(_ raw: Double) -> Double {
        let c = max(0, min(10, raw))
        return (c * 2).rounded(.toNearestOrAwayFromZero) / 2
    }

    private enum SyntheticUsageTier {
        case zero
        case slight
        case medium
        case heavy
        case overflow
    }

    /// **1 ×** idle • **2 ×** very light • **4 ×** medium • **4 ×** heavy • **1 ×** clipped overflow — shuffled onto columns.
    private static func syntheticUsageTierColumnOrder(count: Int, rng: inout TwelveDayRNG) -> [SyntheticUsageTier] {
        precondition(count == 12)
        var tiers: [SyntheticUsageTier] = []
        tiers.append(.zero)
        tiers.append(contentsOf: Array(repeating: .slight, count: 2))
        tiers.append(contentsOf: Array(repeating: .medium, count: 4))
        tiers.append(contentsOf: Array(repeating: .heavy, count: 4))
        tiers.append(.overflow)
        precondition(tiers.count == count)
        rng.shuffle(&tiers)
        return tiers
    }

    private static func hoursEquivalent(for tier: SyntheticUsageTier, rng: inout TwelveDayRNG) -> Double {
        switch tier {
        case .zero:
            return 0
        case .slight:
            return rng.uniformOpen(0.10, 0.58)
        case .medium:
            return rng.uniformOpen(2.15, 3.92)
        case .heavy:
            return rng.uniformOpen(5.05, min(6.42, TwelveDayCombinedChart.hoursShownAtPlotTop * 1.03))
        case .overflow:
            return rng.uniformOpen(7.05, 9.15)
        }
    }

    /// 0 … 1 aggregated load (**keyboard‑heavy**) for correlations.
    private static func dayUsageIntensity(for slot: ComputerUsageDaySlot) -> Double {
        let k = dayCappedFraction(Double(slot.keystrokeCount), cap: TwelveDayCombinedChart.keystrokesDayCap)
        let c = dayCappedFraction(Double(slot.mouseClickCount), cap: TwelveDayCombinedChart.clicksDayCap)
        let t = dayCappedFraction(slot.travelPixels, cap: TwelveDayCombinedChart.travelDayCap)
        return min(1, max(0, 0.52 * k + 0.28 * c + 0.20 * t))
    }

    private static func daySlot(dayStart: Date, totalPlotHeight: Double, rng: inout TwelveDayRNG) -> ComputerUsageDaySlot {
        let band = TwelveDayCombinedChart.usageBandThird
        var w1 = rng.uniformOpen(0.18, 0.72)
        var w2 = rng.uniformOpen(0.14, 0.68)
        var w3 = rng.uniformOpen(0.14, 0.68)
        let wSum = w1 + w2 + w3
        w1 /= wSum
        w2 /= wSum
        w3 /= wSum

        func count(forPlotHeightShare h: Double, cap: Double) -> Int {
            guard cap > 0, band > 0 else { return 0 }
            let frac = min(1, max(0, h / band))
            return max(0, Int((frac * cap).rounded(.toNearestOrAwayFromZero)))
        }

        let hk = max(0, totalPlotHeight * w1)
        let hc = max(0, totalPlotHeight * w2)
        let ht = max(0, totalPlotHeight * w3)

        return ComputerUsageDaySlot(
            dayStart: dayStart,
            keystrokeCount: count(forPlotHeightShare: hk, cap: TwelveDayCombinedChart.keystrokesDayCap),
            mouseClickCount: count(forPlotHeightShare: hc, cap: TwelveDayCombinedChart.clicksDayCap),
            travelPixels: Double(count(forPlotHeightShare: ht, cap: TwelveDayCombinedChart.travelDayCap))
        )
    }

    private static func oneDecimalPainInRange(low: Double, high: Double, rng: inout TwelveDayRNG) -> Double {
        let loIdx = Int(ceil(low * 10 - 1e-6))
        let hiIdx = Int(floor(high * 10 + 1e-6))
        guard hiIdx >= loIdx else {
            return clamp(round((low + high) * 5) / 10, low: low, high: high)
        }
        let pick = rng.intInclusive(lower: loIdx, upper: hiIdx)
        return Double(pick) / 10
    }

    /// Max‑hand pain climbs with usage; **never above 7.0**.
    private static func worstPainCorrelatedIntensity(_ uToday: Double, rng: inout TwelveDayRNG) -> Double {
        let u = clamp(uToday, low: 0, high: 1)
        let center = 1.95 + u * 5.05
        let spreadLeft = rng.uniformOpen(0.35, 1.35)
        let spanRight = rng.uniformOpen(0.05, spreadLeft * 0.72)
        let raw = rng.uniformOpen(max(2, center - spreadLeft), min(7, center + spanRight))
        return snapHalfStep(raw)
    }

    /// Realistic fractional averages beneath the same‑day peak; overlaps match when requested.
    private static func decimalAveragePainLeft(
        cappedWorst: Double,
        overlapMaxWithAvg: Bool,
        rng: inout TwelveDayRNG
    ) -> Double {
        let wm = min(7.0, cappedWorst)
        if overlapMaxWithAvg {
            return Double(Int((wm * 10).rounded(.toNearestOrAwayFromZero))) / 10
        }
        let tentativeHi = wm - rng.uniformOpen(0.08, max(0.95, wm * 0.2))
        let hi =
            clamp(
                Double(Int(floor(min(4.94, tentativeHi) * 10 + 1e-9))) / 10,
                low: 1.1,
                high: min(4.94, wm - 0.04)
            )
        let looseLo = rng.uniformOpen(1.05, hi - rng.uniformOpen(0.15, max(0.95, wm * 0.32)))
        var lo =
            clamp(
                Double(Int(ceil(looseLo * 10 + 1e-9))) / 10,
                low: 1.05,
                high: hi - 0.1
            )
        if hi <= lo + 1e-3 {
            lo = clamp(hi - 0.1, low: 1.05, high: hi)
        }
        return oneDecimalPainInRange(low: lo, high: max(lo, hi), rng: &rng)
    }

    /// Morning pain on calendar day **D + 1** tracks **prior** day workload (**1 … 4**, half‑steps).
    private static func morningPainFromPreviousIntensity(_ prevIntensity: Double, rng: inout TwelveDayRNG) -> Double {
        let p = clamp(prevIntensity, low: 0, high: 1)
        let t = p * p * (3 - 2 * p)
        let lowAnchor = rng.uniformOpen(1.06, 1.98)
        let highSpanLo = lowAnchor + 1.92
        let highSpanHi = min(4.0, lowAnchor + 2.94)
        let hiPick1 = rng.uniformOpen(highSpanLo, highSpanHi)
        let hiPick2 = rng.uniformOpen(highSpanLo, highSpanHi)
        let highAnchor = min(4.0, max(highSpanLo + 0.06, hiPick1, hiPick2))
        let core = lowAnchor + (highAnchor - lowAnchor) * t
        let jitter = rng.uniformOpen(-0.32 + 0.18 * (1 - t), 0.12 + 0.22 * t)
        let raw = clamp(core + jitter, low: 1, high: 4)
        return snapHalfStep(raw)
    }

    static func randomizedTestPreview(referenceDate: Date, seed: UInt64)
        -> ([ComputerUsageDaySlot], [TwelveDayPainCurve: [Double?]]) {
        let calendar = Calendar.current
        let anchor = referenceDate.startOfHandTrackingDay
        let count = 12
        var rng = TwelveDayRNG(seed: seed)
        let columnTiers = syntheticUsageTierColumnOrder(count: count, rng: &rng)

        var slots: [ComputerUsageDaySlot] = []
        slots.reserveCapacity(count)

        for i in 0..<count {
            let daysBack = count - 1 - i
            guard let dayStart = calendar.date(byAdding: .day, value: -daysBack, to: anchor) else { continue }

            let hoursEqu = hoursEquivalent(for: columnTiers[i], rng: &rng)
            let targetPlotY = hoursEqu / TwelveDayCombinedChart.hoursShownAtPlotTop * 10

            slots.append(daySlot(dayStart: dayStart, totalPlotHeight: targetPlotY, rng: &rng))
        }

        var worstL = [Double?](repeating: nil, count: count)
        var worstR = [Double?](repeating: nil, count: count)
        var avgL = [Double?](repeating: nil, count: count)
        var avgR = [Double?](repeating: nil, count: count)
        var morningL = [Double?](repeating: nil, count: count)
        var morningR = [Double?](repeating: nil, count: count)

        for i in slots.indices {
            let uToday = dayUsageIntensity(for: slots[i])
            let overlap = rng.unitInterval01() < 0.12

            let wl = worstPainCorrelatedIntensity(uToday, rng: &rng)
            worstL[i] = wl

            var avgLo = decimalAveragePainLeft(cappedWorst: wl, overlapMaxWithAvg: overlap, rng: &rng)
            avgLo = min(avgLo, wl - 2e-3)
            avgL[i] = avgLo

            let jitterRWorst =
                rng.uniformOpen(
                    max(-0.65, -(wl - 2) * rng.uniformOpen(0.06, 0.28)),
                    min(0.75, rng.uniformOpen(0.06, max(1, (7 - wl) * 0.52)))
                )
            let wrSnap = snapHalfStep(clamp(wl + jitterRWorst, low: max(avgLo, wl - 0.75), high: min(7, wl + 0.55)))
            worstR[i] = wrSnap

            let avgHiR =
                clamp(
                    Double(Int(floor(min(4.92, wrSnap - 0.05) * 10 + 1e-9))) / 10,
                    low: 1.08,
                    high: min(4.92, wrSnap - 0.05)
                )
            let loSeed =
                clamp(
                    avgLo + rng.uniformOpen(-0.55, 0.72),
                    low: 1.05,
                    high: avgHiR - 0.1
                )
            let avgLoR =
                clamp(
                    Double(Int(ceil(loSeed * 10 - 1e-9))) / 10,
                    low: 1.05,
                    high: avgHiR - 0.06
                )
            if overlap && rng.unitInterval01() < 0.24 {
                avgR[i] = clamp(avgLo, low: 1.05, high: avgHiR)
            } else if avgHiR <= avgLoR + 1e-6 {
                avgR[i] =
                    min(
                        wrSnap - 3e-3,
                        oneDecimalPainInRange(low: max(1.05, avgHiR - rng.uniformOpen(0.12, max(avgHiR * 0.32, 0.45))), high: avgHiR, rng: &rng)
                    )
            } else {
                avgR[i] = min(wrSnap - 3e-3, oneDecimalPainInRange(low: avgLoR, high: avgHiR, rng: &rng))
            }

            let prevU = i == 0 ? rng.uniformOpen(0.06, 0.38) : dayUsageIntensity(for: slots[i - 1])
            let mL = morningPainFromPreviousIntensity(prevU, rng: &rng)
            morningL[i] = mL

            let mrRaw =
                clamp(
                    mL + rng.uniformOpen(-0.85, max(0.35, wl * rng.uniformOpen(0.035, 0.12))),
                    low: 1,
                    high: 4
                )
            morningR[i] = snapHalfStep(mrRaw)
        }

        let pains: [TwelveDayPainCurve: [Double?]] = [
            .worstLeft: worstL,
            .averageLeft: avgL,
            .firstLeft: morningL,
            .worstRight: worstR,
            .averageRight: avgR,
            .firstRight: morningR,
        ]
        return (slots, pains)
    }

    private static func clamp(_ x: Double, low: Double, high: Double) -> Double {
        min(high, max(low, x))
    }
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
        stackLayers = buildDayStackLayers(slots: slots, usageVisibility: usageVisibility)

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

    @MainActor
    static func randomizedTestPreview(
        referenceDate: Date,
        seed: UInt64,
        usageVisibility: TwelveDayUsageModalityVisibility = .allVisible
    ) -> TwelveDayPainPrepared {
        let (slots, pains) = TwelveDaySyntheticSeries.randomizedTestPreview(referenceDate: referenceDate, seed: seed)
        return TwelveDayPainPrepared(slots: slots, painsByCurve: pains, usageVisibility: usageVisibility)
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
    let segmentInteriorLabelOffsetXByLayerID: [String: CGFloat]

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
        let plotBounds = geometry[chartProxy.plotAreaFrame]
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

/// Owns `Chart { … }` plus axis/scales — keeps ``TwelveDayPainChartPanel`` from inheriting giant `some View` composition.
private struct TwelveDayPainChartSurface: View {
    let slots: [ComputerUsageDaySlot]
    let stackLayers: [DayStackLayer]
    let painSamplesByCurve: [TwelveDayPainCurve: [DayPainSample]]
    let activeCurves: [TwelveDayPainCurve]
    let gap: Double
    let segmentInteriorLabelOffsetXByLayerID: [String: CGFloat]

    var body: some View {
        Chart {
            TwelveDayBaselineRuleChartContent()
            TwelveDayStackedUsageRectanglesChartContent(
                layers: stackLayers,
                gap: gap,
                slots: slots,
                segmentInteriorLabelOffsetXByLayerID: segmentInteriorLabelOffsetXByLayerID
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
                TwelveDayBarCenterDayLabelsOverlay(slots: slots, chartProxy: proxy, geometry: geometry)
            }
        }
    }
}

// MARK: - Chart panel

private struct TwelveDayPainChartPanel: View {
    let prepared: TwelveDayPainPrepared
    var painVisibility: TwelveDayPainVisibility

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
}

private struct TwelveDayUsageBarsToggleStrip: View {
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

/// Twelve trailing calendar days: stacked usage (same scaling idea as twelve‑hour chart) vs iPhone pain rollup.
struct MacTwelveDayStackedUsagePainChart: View {
    @EnvironmentObject private var store: HandTrackStore

    @AppStorage(TwelveDayUsageBarsAppStorage.showKeysKey) private var twelveDayChartShowKeys = true
    @AppStorage(TwelveDayUsageBarsAppStorage.showClicksKey) private var twelveDayChartShowClicks = true
    @AppStorage(TwelveDayUsageBarsAppStorage.showTravelKey) private var twelveDayChartShowTravel = true

    /// Seeded deterministic sample charts (not persisted); flipping **Test data** bumps the seed once.
    @State private var useTwelveDayTestData = false
    @State private var twelveDayTestDataSeed: UInt64 = 0x6D61635F3132DD17

    /// Default: **left‑hand** pain series only (`Max`/`Avg`/morning); enable right‑hand boxes as needed.
    @State private var painVisibility = TwelveDayPainVisibility(
        worstLeft: true,
        averageLeft: true,
        firstLeft: true,
        worstRight: false,
        averageRight: false,
        firstRight: false
    )

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3600)) { timeline in
            chartContent(referenceDate: timeline.date)
        }
    }

    @ViewBuilder
    @MainActor
    private func chartContent(referenceDate: Date) -> some View {
        let usageBarsVisibility = TwelveDayUsageModalityVisibility(
            showKeystrokes: twelveDayChartShowKeys,
            showMouseClicks: twelveDayChartShowClicks,
            showTravel: twelveDayChartShowTravel
        )
        let prepared: TwelveDayPainPrepared = useTwelveDayTestData
            ? TwelveDayPainPrepared.randomizedTestPreview(
                referenceDate: referenceDate,
                seed: twelveDayTestDataSeed,
                usageVisibility: usageBarsVisibility
            )
            : TwelveDayPainPrepared(store: store, referenceDate: referenceDate, usageVisibility: usageBarsVisibility)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Past 12 days")
                    .font(.headline)
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 8) {
                    Toggle(isOn: $useTwelveDayTestData) {
                        Text("Test data")
                            .font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: useTwelveDayTestData) { _, isOn in
                        guard isOn else { return }
                        twelveDayTestDataSeed ^= 0x9E3779B97F4A7C15
                    }

                    TwelveDayUsageBarsToggleStrip(
                        showKeys: $twelveDayChartShowKeys,
                        showClicks: $twelveDayChartShowClicks,
                        showTravel: $twelveDayChartShowTravel
                    )

                    TwelveDayPainGraphsToggleMatrix(visibility: $painVisibility)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            TwelveDayPainChartPanel(prepared: prepared, painVisibility: painVisibility)
        }
        .onAppear {
            ensureUsageBarsInvariant()
        }
        .onChange(of: twelveDayChartShowKeys) { _, _ in ensureUsageBarsInvariant() }
        .onChange(of: twelveDayChartShowClicks) { _, _ in ensureUsageBarsInvariant() }
        .onChange(of: twelveDayChartShowTravel) { _, _ in ensureUsageBarsInvariant() }
    }

    private func ensureUsageBarsInvariant() {
        if !twelveDayChartShowKeys && !twelveDayChartShowClicks && !twelveDayChartShowTravel {
            twelveDayChartShowKeys = true
        }
    }
}
