import SwiftUI

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

/// Compact hour / today strips; estimated time uses the same count÷rate math as the stacked charts.
struct MacUsageDashboardSummary: View {

    @EnvironmentObject private var store: HandTrackStore
    @Environment(HandTrackLivePulse.self) private var livePulse
    @AppStorage(MacEstimatedWorkloadMinutes.keysPerMinuteKey)
    private var avgKeysPM = MacEstimatedWorkloadMinutes.defaultKeysPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.clicksPerMinuteKey)
    private var avgClicksPM = MacEstimatedWorkloadMinutes.defaultClicksPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.pixelThousandsPerMinuteKey)
    private var avgPixelThousandsPM = MacEstimatedWorkloadMinutes.defaultPixelThousandsPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.scrollsPerMinuteKey)
    private var avgScrollsPM = MacEstimatedWorkloadMinutes.defaultScrollsPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.trackpadTravelPixelThousandsPerMinuteKey)
    private var avgTrackpadTravelKPM =
        MacEstimatedWorkloadMinutes.defaultTrackpadTravelPixelThousandsPerMinute
    @AppStorage(MacEstimatedWorkloadMinutes.trackpadScrollPixelThousandsPerMinuteKey)
    private var avgTrackpadScrollKPM =
        MacEstimatedWorkloadMinutes.defaultTrackpadScrollPixelThousandsPerMinute
    @AppStorage(HandTrackActivityLimitsStorage.dashboardRollingWindowMinutesKey)
    private var rollingWindowMinutes = HandTrackActivityLimitsStorage.Defaults.dashboardRollingWindowMinutes

    let now: Date

    @State private var showYesterday = false
    @State private var showRollingWindowEditor = false

    var body: some View {
        let _ = livePulse.summary
        VStack(alignment: .leading, spacing: 13) {

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                metricRowHeading("Last \(rollingWindowMinutes) minutes")
                Button {
                    showRollingWindowEditor.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Customize the rolling window length")
                .popover(isPresented: $showRollingWindowEditor, arrowEdge: .bottom) {
                    rollingWindowEditor
                }
            }
            rollingWindowRowOfTiles

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

    private var rollingWindowEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rolling window length")
                .font(.subheadline.weight(.semibold))
            Stepper(value: $rollingWindowMinutes, in: 1...240, step: 1) {
                Text("\(rollingWindowMinutes) minutes")
                    .monospacedDigit()
            }
            Text("Used for the dashboard row above “This hour”.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 240)
    }

    private var rollingKeys: Int { store.keysInLastMinutes(rollingWindowMinutes, reference: now) }
    private var rollingClicks: Int { store.clicksInLastMinutes(rollingWindowMinutes, reference: now) }
    private var rollingTravel: Double {
        store.mouseTravelPixelsInLastMinutes(rollingWindowMinutes, reference: now)
    }
    private var rollingScrolls: Int { store.scrollsInLastMinutes(rollingWindowMinutes, reference: now) }

    private var workloadRates: MacEstimatedWorkloadMinutes.Rates {
        MacEstimatedWorkloadMinutes.Rates.from(
            keysPerMinute: avgKeysPM,
            clicksPerMinute: avgClicksPM,
            pixelThousandsPerMinute: avgPixelThousandsPM,
            scrollsPerMinute: avgScrollsPM,
            trackpadTravelPixelThousandsPerMinute: avgTrackpadTravelKPM,
            trackpadScrollPixelThousandsPerMinute: avgTrackpadScrollKPM
        )
    }

    private var rollingWorkloadMinutes: Double {
        Double(
            MacEstimatedWorkloadMinutes.totalMinutes(
                keystrokes: rollingKeys,
                clicks: rollingClicks,
                travelPixels: rollingTravel,
                scrollBumps: rollingScrolls,
                rates: workloadRates
            )
        )
    }

    private var rollingWindowRowOfTiles: some View {
        HStack(spacing: 16) {
            DashValueTile(title: "Keys", value: MacDashFormat.integers(rollingKeys))
            DashValueTile(title: "Clicks", value: MacDashFormat.integers(rollingClicks))
            DashValueTile(title: "Pointer travel", value: MacDashFormat.travel(rollingTravel))
            DashValueTile(title: "Scrolls", value: MacDashFormat.integers(rollingScrolls))
            DashValueTile(title: "Estimated minutes", value: MacDashFormat.minutesWorkload(rollingWorkloadMinutes))
        }
    }

    private func metricRowHeading(_ s: String) -> some View {
        Text(s)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var hourKeys: Int { store.keysSinceStartOfCurrentHour(reference: now) }
    private var hourClicks: Int { store.clicksSinceStartOfCurrentHour(reference: now) }
    private var hourTravel: Double { store.mouseTravelPixelsSinceStartOfCurrentHour(reference: now) }
    private var hourScrolls: Int { store.scrollsSinceStartOfCurrentHour(reference: now) }

    private var hourWorkloadMinutes: Double {
        Double(
            MacEstimatedWorkloadMinutes.totalMinutes(
                keystrokes: hourKeys,
                clicks: hourClicks,
                travelPixels: hourTravel,
                scrollBumps: hourScrolls,
                rates: workloadRates
            )
        )
    }

    private var hourRowOfTiles: some View {
        HStack(spacing: 16) {
            DashValueTile(title: "Keys", value: MacDashFormat.integers(hourKeys))
            DashValueTile(title: "Clicks", value: MacDashFormat.integers(hourClicks))
            DashValueTile(title: "Pointer travel", value: MacDashFormat.travel(hourTravel))
            DashValueTile(title: "Scrolls", value: MacDashFormat.integers(hourScrolls))
            DashValueTile(title: "Estimated minutes", value: MacDashFormat.minutesWorkload(hourWorkloadMinutes))
        }
    }

    private var todayTotals: ComputerUsageDaySlot? {
        store.computerUsageOnCalendarDayContaining(reference: now)
    }

    private var todayKeys: Int { todayTotals?.keystrokeCount ?? 0 }
    private var todayClicks: Int { todayTotals?.mouseClickCount ?? 0 }
    private var todayTravel: Double { todayTotals?.travelPixels ?? 0 }
    private var todayScrolls: Int { todayTotals?.scrollBumpCount ?? 0 }

    private var todayWorkloadHours: Double {
        Double(
            MacEstimatedWorkloadMinutes.totalMinutes(
                keystrokes: todayKeys,
                clicks: todayClicks,
                travelPixels: todayTravel,
                scrollBumps: todayScrolls,
                builtinKeystrokes: todayTotals?.builtinKeystrokeCount ?? 0,
                builtinTrackpadClicks: todayTotals?.builtinTrackpadClickCount ?? 0,
                builtinTrackpadTravelPixels: todayTotals?.builtinTrackpadTravelPixels ?? 0,
                builtinTrackpadScrollPixels: todayTotals?.builtinTrackpadScrollPixels ?? 0,
                rates: workloadRates
            )
        ) / 60.0
    }

    private var todayRowOfTiles: some View {
        HStack(spacing: 16) {
            DashValueTile(title: "Keys", value: MacDashFormat.integers(todayKeys))
            DashValueTile(title: "Clicks", value: MacDashFormat.integers(todayClicks))
            DashValueTile(title: "Pointer travel", value: MacDashFormat.travel(todayTravel))
            DashValueTile(title: "Scrolls", value: MacDashFormat.integers(todayScrolls))
            DashValueTile(title: "Estimated time", value: MacDashFormat.hoursWorkload(todayWorkloadHours))
        }
    }
}

private struct MacYesterdayUsageTotalsSheet: View {

    @EnvironmentObject private var store: HandTrackStore
    @Environment(\.dismiss) private var dismiss

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

    private func yesterdayHours(_ slot: ComputerUsageDaySlot) -> Double {
        Double(
            MacEstimatedWorkloadMinutes.totalMinutes(
                keystrokes: slot.keystrokeCount,
                clicks: slot.mouseClickCount,
                travelPixels: slot.travelPixels,
                scrollBumps: slot.scrollBumpCount,
                builtinKeystrokes: slot.builtinKeystrokeCount,
                builtinTrackpadClicks: slot.builtinTrackpadClickCount,
                builtinTrackpadTravelPixels: slot.builtinTrackpadTravelPixels,
                builtinTrackpadScrollPixels: slot.builtinTrackpadScrollPixels,
                rates: MacEstimatedWorkloadMinutes.Rates.fromUserDefaults()
            )
        ) / 60.0
    }
}
