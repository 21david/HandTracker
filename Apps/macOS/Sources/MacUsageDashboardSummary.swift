import SwiftUI

// MARK: - Same stack-height geometry as charts (minutes / hours derived from composite plot Y)

/// Mirrors [`MacTwelveHourStackedUsagePainChart`](MacTwelveHourStackedUsagePainChart.swift) `HourComfortCaps` + `buildStackLayers` totals.
private enum MacDashboardTwelveHourMath {
    static let chartYAxisMax = 10.0
    static let usageBandThird = chartYAxisMax / 3.0
    static let leadingMinutesPerPlotYUnit = 6.0

    struct ComfortCaps {
        let keysHeightDenom: Double
        let clicksHeightDenom: Double
        let travelHeightDenom: Double

        static func fromModerateMinuteAverages(
            keysPerMinute: Int,
            clicksPerMinute: Int,
            pixelThousandsPerMinute: Int
        ) -> ComfortCaps {
            let rawKeys = max(0, keysPerMinute)
            let kpm = Double((rawKeys / 5) * 5)
            let cpm = Double(max(0, clicksPerMinute))
            let thousands = max(1, pixelThousandsPerMinute)
            let ppm = Double(thousands) * 1000

            func heightDenom(_ rate: Double) -> Double {
                guard rate.isFinite else { return .infinity }
                return rate > 1e-9 ? rate * 120 : .infinity
            }

            return ComfortCaps(
                keysHeightDenom: heightDenom(kpm),
                clicksHeightDenom: heightDenom(cpm),
                travelHeightDenom: heightDenom(ppm)
            )
        }
    }

    /// Total stacked **`chart Y`** height for one bucket (travel → clicks → keys), after squeeze toward `0…10`.
    static func compositeStackPlotY(
        keystrokes: Int,
        mouseClicks: Int,
        travelPixels: Double,
        caps: ComfortCaps
    ) -> Double {
        let band = usageBandThird
        let fracKeys = caps.keysHeightDenom.isFinite && caps.keysHeightDenom > 1e-9
            ? max(0, Double(keystrokes) / caps.keysHeightDenom) : 0
        let fracClicks = caps.clicksHeightDenom.isFinite && caps.clicksHeightDenom > 1e-9
            ? max(0, Double(mouseClicks) / caps.clicksHeightDenom) : 0
        let fracTravel = caps.travelHeightDenom.isFinite && caps.travelHeightDenom > 1e-9
            ? max(0, travelPixels / caps.travelHeightDenom) : 0

        let baseKeys = band * fracKeys
        let baseClicks = band * fracClicks
        let baseTravel = band * fracTravel
        let sumBase = baseKeys + baseClicks + baseTravel
        guard sumBase > 1e-6 else { return 0 }
        let squeeze = sumBase <= chartYAxisMax ? 1.0 : chartYAxisMax / sumBase
        return sumBase * squeeze
    }

    static func approximateWorkloadMinutes(totalPlotY: Double) -> Double {
        totalPlotY * leadingMinutesPerPlotYUnit
    }
}

/// Mirrors [`TwelveDayCombinedChart`](MacTwelveDayStackedUsagePainChart.swift) + `buildDayStackLayers` totals.
private enum MacDashboardTwelveDayMath {

    private static let typicalWorkHours = 3.0
    private static let scaleFactor = 12.0 * typicalWorkHours
    private static let usageCapEase = 3.0 / 5.0

    private static let keystrokesDayCap = 275.0 * scaleFactor * usageCapEase
    private static let clicksDayCap = 120.0 * scaleFactor * usageCapEase
    private static let travelDayCap = 125_000.0 * scaleFactor * usageCapEase

    private static let usageBandThird = 10.0 / 3.0
    private static let chartYAxisMax = 10.0

    struct DayBarsVisibility {
        var showKeys: Bool
        var showClicks: Bool
        var showTravel: Bool
    }

    private static func dayCappedFraction(_ value: Double, cap: Double) -> Double {
        guard cap > 0 else { return 0 }
        return min(1, value / cap)
    }

    /// Total stacked **`chart Y`** for the current hand-tracking day bar (respects twelve‑day “Usage bars” toggles).
    static func compositeStackPlotY(slot: ComputerUsageDaySlot, vis: DayBarsVisibility) -> Double {
        guard vis.showKeys || vis.showClicks || vis.showTravel else { return 0 }

        let bandSlice = usageBandThird
        let keysFrac = dayCappedFraction(Double(slot.keystrokeCount), cap: keystrokesDayCap)
        let clickFrac = dayCappedFraction(Double(slot.mouseClickCount), cap: clicksDayCap)
        let travelFrac = dayCappedFraction(slot.travelPixels, cap: travelDayCap)

        struct Stage {
            var unscaled: Double
        }
        var stages: [Stage] = []
        if vis.showTravel {
            let h = travelFrac * bandSlice
            if h > 1e-4 { stages.append(Stage(unscaled: h)) }
        }
        if vis.showClicks {
            let h = clickFrac * bandSlice
            if h > 1e-4 { stages.append(Stage(unscaled: h)) }
        }
        if vis.showKeys {
            let h = keysFrac * bandSlice
            if h > 1e-4 { stages.append(Stage(unscaled: h)) }
        }
        guard !stages.isEmpty else { return 0 }

        let sumUnscaled = stages.reduce(0.0) { $0 + $1.unscaled }
        guard sumUnscaled > 0 else { return 0 }
        let squeeze = sumUnscaled <= chartYAxisMax ? 1.0 : chartYAxisMax / sumUnscaled
        var yCursor = 0.0
        for s in stages {
            yCursor += s.unscaled * squeeze
        }
        return yCursor
    }

    /// Same ladder as **`twelveDayLeadingUsageHoursTickLabel`**: `chartY / 2` → hours (`0…10 Y ↔ 0…5 h`).
    static func approximateWorkloadHours(totalPlotY: Double) -> Double {
        totalPlotY / 2.0
    }
}

private enum MacDashFormat {

    static func integers(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    static func travel(_ pixels: Double) -> String {
        guard pixels.isFinite else { return "—" }
        let p = pixels
        if p >= 1_000_000 {
            return String(format: "%.1f M px", p / 1_000_000)
        }
        if p >= 10_000 {
            return String(format: "%.0f k px", p / 1_000)
        }
        if p >= 1_000 {
            return String(format: "%.1f k px", p / 1_000)
        }
        return String(format: "%.0f px", p)
    }

    /// Chart-derived minutes ceiling; title already conveys “estimated”.
    static func minutesWorkload(_ raw: Double) -> String {
        guard raw.isFinite, raw >= 0 else { return "—" }
        let ceiling = Int(ceil(max(0, raw) - 1e-12))
        return englishMinuteCount(ceiling)
    }

    /// Converts fractional workload **hours** to whole hours + minutes (minutes from remainder, ceiling totals).
    static func hoursWorkload(_ rawHours: Double) -> String {
        guard rawHours.isFinite, rawHours >= 0 else { return "—" }
        let totalMinutes = Int(ceil(max(0, rawHours) * 60.0 - 1e-12))
        return englishHoursAndMinutes(totalMinutes)
    }

    private static func englishMinuteCount(_ n: Int) -> String {
        switch n {
        case 0: return "0 minutes"
        case 1: return "1 minute"
        default: return "\(n) minutes"
        }
    }

    private static func englishHourWord(_ hours: Int) -> String {
        switch hours {
        case 1: return "1 hour"
        default: return "\(hours) hours"
        }
    }

    private static func englishHoursAndMinutes(_ totalMinutes: Int) -> String {
        guard totalMinutes > 0 else { return englishMinuteCount(0) }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h == 0 { return englishMinuteCount(m) }
        if m == 0 { return englishHourWord(h) }
        return "\(englishHourWord(h)) \(englishMinuteCount(m))"
    }
}

// MARK: - Tiles

private struct DashValueTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.62)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(.quaternary.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Compact hour / today strips; workload chips match twelve‑hour (minutes ladder) & twelve‑day (hours ladder) charts.
struct MacUsageDashboardSummary: View {

    private enum ComfortKeys {
        static let keysPM = "HandTrack.mac.twelveHourAvgKeysPerMinute"
        static let clicksPM = "HandTrack.mac.twelveHourAvgClicksPerMinute"
        static let pxK = "HandTrack.mac.twelveHourAvgPixelThousandsPerMinute"
        static let dayShowKeys = "HandTrack.mac.twelveDayChartShowKeys"
        static let dayShowClicks = "HandTrack.mac.twelveDayChartShowClicks"
        static let dayShowTravel = "HandTrack.mac.twelveDayChartShowPointerTravel"
    }

    @EnvironmentObject private var store: HandTrackStore
    @AppStorage(ComfortKeys.keysPM) private var avgKeysPM = 15
    @AppStorage(ComfortKeys.clicksPM) private var avgClicksPM = 5
    @AppStorage(ComfortKeys.pxK) private var avgPixelThousandsPM = 7
    @AppStorage(ComfortKeys.dayShowKeys) private var dayShowKeys = true
    @AppStorage(ComfortKeys.dayShowClicks) private var dayShowClicks = true
    @AppStorage(ComfortKeys.dayShowTravel) private var dayShowTravel = true

    let now: Date

    @State private var showYesterday = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {

            metricRowHeading("This hour")
            hourRowOfTiles

            metricRowHeading("Today")
            todayRowOfTiles

            Button {
                showYesterday = true
            } label: {
                Text("Yesterday’s totals…")
                    .font(.footnote.weight(.medium))
                    .underline()
            }
            .buttonStyle(.plain)
            .keyboardShortcut("y", modifiers: [.command, .shift])
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showYesterday) {
            MacYesterdayUsageTotalsSheet(reference: now)
                .environmentObject(store)
                .presentationBackground(.thinMaterial)
        }
    }

    private func metricRowHeading(_ s: String) -> some View {
        Text(s)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var twelveHourCaps: MacDashboardTwelveHourMath.ComfortCaps {
        MacDashboardTwelveHourMath.ComfortCaps.fromModerateMinuteAverages(
            keysPerMinute: avgKeysPM,
            clicksPerMinute: avgClicksPM,
            pixelThousandsPerMinute: avgPixelThousandsPM
        )
    }

    private var dayVisibility: MacDashboardTwelveDayMath.DayBarsVisibility {
        MacDashboardTwelveDayMath.DayBarsVisibility(
            showKeys: dayShowKeys,
            showClicks: dayShowClicks,
            showTravel: dayShowTravel
        )
    }

    private var hourKeys: Int { store.keysSinceStartOfCurrentHour(reference: now) }
    private var hourClicks: Int { store.clicksSinceStartOfCurrentHour(reference: now) }
    private var hourTravel: Double { store.mouseTravelPixelsSinceStartOfCurrentHour(reference: now) }

    private var hourPlotY: Double {
        MacDashboardTwelveHourMath.compositeStackPlotY(
            keystrokes: hourKeys,
            mouseClicks: hourClicks,
            travelPixels: hourTravel,
            caps: twelveHourCaps
        )
    }

    private var hourWorkloadMinutes: Double {
        MacDashboardTwelveHourMath.approximateWorkloadMinutes(totalPlotY: hourPlotY)
    }

    private var hourRowOfTiles: some View {
        HStack(spacing: 16) {
            DashValueTile(title: "Keys", value: MacDashFormat.integers(hourKeys))
            DashValueTile(title: "Clicks", value: MacDashFormat.integers(hourClicks))
            DashValueTile(title: "Pointer travel", value: MacDashFormat.travel(hourTravel))
            DashValueTile(title: "Estimated minutes", value: MacDashFormat.minutesWorkload(hourWorkloadMinutes))
        }
    }

    private var todayTotals: ComputerUsageDaySlot? {
        store.computerUsageOnCalendarDayContaining(reference: now)
    }

    private var todayKeys: Int { todayTotals?.keystrokeCount ?? 0 }
    private var todayClicks: Int { todayTotals?.mouseClickCount ?? 0 }
    private var todayTravel: Double { todayTotals?.travelPixels ?? 0 }

    private var todayPlotY: Double {
        guard let slot = todayTotals else { return 0 }
        return MacDashboardTwelveDayMath.compositeStackPlotY(slot: slot, vis: dayVisibility)
    }

    private var todayWorkloadHours: Double {
        MacDashboardTwelveDayMath.approximateWorkloadHours(totalPlotY: todayPlotY)
    }

    private var todayRowOfTiles: some View {
        HStack(spacing: 16) {
            DashValueTile(title: "Keys", value: MacDashFormat.integers(todayKeys))
            DashValueTile(title: "Clicks", value: MacDashFormat.integers(todayClicks))
            DashValueTile(title: "Pointer travel", value: MacDashFormat.travel(todayTravel))
            DashValueTile(title: "Estimated time", value: MacDashFormat.hoursWorkload(todayWorkloadHours))
        }
    }
}

private struct MacYesterdayUsageTotalsSheet: View {

    private enum ComfortKeys {
        static let keysPM = "HandTrack.mac.twelveHourAvgKeysPerMinute"
        static let clicksPM = "HandTrack.mac.twelveHourAvgClicksPerMinute"
        static let pxK = "HandTrack.mac.twelveHourAvgPixelThousandsPerMinute"
        static let dayShowKeys = "HandTrack.mac.twelveDayChartShowKeys"
        static let dayShowClicks = "HandTrack.mac.twelveDayChartShowClicks"
        static let dayShowTravel = "HandTrack.mac.twelveDayChartShowPointerTravel"
    }

    @EnvironmentObject private var store: HandTrackStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ComfortKeys.dayShowKeys) private var dayShowKeys = true
    @AppStorage(ComfortKeys.dayShowClicks) private var dayShowClicks = true
    @AppStorage(ComfortKeys.dayShowTravel) private var dayShowTravel = true

    let reference: Date

    var body: some View {
        NavigationStack {
            Group {
                if let day = yesterdaySlot {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(DateFormatter.localizedString(
                                from: day.dayStart,
                                dateStyle: .medium,
                                timeStyle: .none
                            ))
                                .font(.title2.weight(.semibold))

                            HStack(spacing: 12) {
                                DashValueTile(title: "Keys", value: MacDashFormat.integers(day.keystrokeCount))
                                DashValueTile(title: "Clicks", value: MacDashFormat.integers(day.mouseClickCount))
                            }
                            HStack(spacing: 12) {
                                DashValueTile(title: "Pointer travel", value: MacDashFormat.travel(day.travelPixels))
                                DashValueTile(
                                    title: "Estimated time",
                                    value: MacDashFormat.hoursWorkload(yesterdayHours(day))
                                )
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 420, idealWidth: 480, maxWidth: 520, minHeight: 280)
                } else {
                    Text("Nothing recorded for that day yet.")
                        .foregroundStyle(.secondary)
                        .padding(26)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Yesterday")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var yesterdaySlot: ComputerUsageDaySlot? {
        store.computerUsageOnPreviousCalendarDay(reference: reference)
    }

    private var dayVisibility: MacDashboardTwelveDayMath.DayBarsVisibility {
        MacDashboardTwelveDayMath.DayBarsVisibility(
            showKeys: dayShowKeys,
            showClicks: dayShowClicks,
            showTravel: dayShowTravel
        )
    }

    private func yesterdayHours(_ slot: ComputerUsageDaySlot) -> Double {
        let y = MacDashboardTwelveDayMath.compositeStackPlotY(slot: slot, vis: dayVisibility)
        return MacDashboardTwelveDayMath.approximateWorkloadHours(totalPlotY: y)
    }
}
