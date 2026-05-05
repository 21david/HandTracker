import SwiftUI

// MARK: - Hours math (Past 12 h “Average minute” calibration)

/// Interprets Mac-recorded aggregates as **reference posture hours**, matching the keystrokes‑/min, clicks‑/min,
/// and thousand‑px‑/min sliders on the Past 12 hours chart.
enum MacComfortCalibrationWorkload {

    struct Breakdown {
        var keysHours: Double
        var clicksHours: Double
        var pointerHours: Double
        /// Typing/mousing/movement overlap; headline uses **max** channel as a readable single number.
        var approximateComputerHoursMaxChannel: Double
    }

    private static func normalizedKeysPerMinute(_ raw: Int) -> Double {
        Double((max(0, raw) / 5) * 5)
    }

    static func workloadHours(
        keystrokes: Int,
        clicks: Int,
        travelPixels: Double,
        keysPerMinuteRaw: Int,
        clicksPerMinuteRaw: Int,
        pixelThousandsPerMinuteRaw: Int
    ) -> Breakdown {
        let kpm = normalizedKeysPerMinute(keysPerMinuteRaw)
        let cpm = Double(max(0, clicksPerMinuteRaw))
        let ppm = Double(max(1, pixelThousandsPerMinuteRaw)) * 1000

        let hKeys = kpm > 1e-9 ? Double(keystrokes) / (kpm * 60) : 0
        let hClicks = cpm > 1e-9 ? Double(clicks) / (cpm * 60) : 0
        let hPointer = ppm > 1e-9 ? travelPixels / (ppm * 60) : 0

        return Breakdown(
            keysHours: hKeys,
            clicksHours: hClicks,
            pointerHours: hPointer,
            approximateComputerHoursMaxChannel: max(hKeys, max(hClicks, hPointer))
        )
    }

    static func formatHoursHours(_ hours: Double) -> String {
        guard hours.isFinite, hours >= 0 else { return "—" }
        if hours >= 100 {
            return String(format: "%.0f h", hours)
        }
        if hours >= 10 {
            return String(format: "%.1f h", hours)
        }
        return String(format: "%.2f h", hours)
    }

    static func formatHoursSubtitle(_ bd: Breakdown) -> String {
        let kh = Self.formatHoursHours(bd.keysHours)
        let ch = Self.formatHoursHours(bd.clicksHours)
        let ph = Self.formatHoursHours(bd.pointerHours)
        let mx = Self.formatHoursHours(bd.approximateComputerHoursMaxChannel)
        return "Keys ≈ \(kh) · Clicks ≈ \(ch) · Pointer ≈ \(ph); max modality \(mx)"
    }
}

private enum MacUsageSummaryFormatters {

    static let compactMonthDayYear: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func pixelSummary(_ pixels: Double) -> String {
        guard pixels.isFinite else { return "—" }
        let p = pixels
        if p >= 1_000_000 {
            return String(format: "%.2f M px", p / 1_000_000)
        }
        if p >= 10_000 {
            return String(format: "%.0f k px", p / 1_000)
        }
        if p >= 1_000 {
            return String(format: "%.1f k px", p / 1_000)
        }
        return String(format: "%.0f px", p)
    }
}

// MARK: - Dashboard panels

private struct MetricBlock: View {

    enum Kind {
        case hour
        case day

        var title: String {
            switch self {
            case .hour: return "This calendar hour"
            case .day: return "Calendar day so far"
            }
        }

        var subtitle: String {
            switch self {
            case .hour:
                return "Counts since top of hour on the clocks below."
            case .day:
                return "Local midnight → midnight; pointer travel summed by minute buckets."
            }
        }
    }

    let kind: Kind
    let keystrokes: Int
    let clicks: Int
    let travelPx: Double
    let bd: MacComfortCalibrationWorkload.Breakdown
    let averageWPM: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title)
                .font(.subheadline.weight(.semibold))
            Text(kind.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(Self.intString(keystrokes)) keys · \(Self.intString(clicks)) clicks · \(MacUsageSummaryFormatters.pixelSummary(travelPx))")
                    .font(.body.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)

                Text("Approx. reference hours \(MacComfortCalibrationWorkload.formatHoursHours(bd.approximateComputerHoursMaxChannel)) (max modality)")
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(MacComfortCalibrationWorkload.formatHoursSubtitle(bd))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let avg = averageWPM, kind == .hour {
                Text("Average typing WPM \(String(format: "%.1f", avg)) · (keys ÷ 5 · min⁻¹)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func intString(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

struct MacUsageDashboardSummary: View {

    private enum ComfortKeys {
        static let keys = "HandTrack.mac.twelveHourAvgKeysPerMinute"
        static let clicks = "HandTrack.mac.twelveHourAvgClicksPerMinute"
        static let pxK = "HandTrack.mac.twelveHourAvgPixelThousandsPerMinute"
    }

    @EnvironmentObject private var store: HandTrackStore
    @AppStorage(ComfortKeys.keys) private var avgKeysPM = 15
    @AppStorage(ComfortKeys.clicks) private var avgClicksPM = 5
    @AppStorage(ComfortKeys.pxK) private var avgPixelThousandsPM = 7

    /// Tick from wrapping `TimelineView` so aggregates track the advancing clock minute/hour rolls.
    let now: Date

    @State private var showYesterday = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Estimated usage totals")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 16) {
                MetricBlock(
                    kind: .hour,
                    keystrokes: store.keysSinceStartOfCurrentHour(reference: now),
                    clicks: store.clicksSinceStartOfCurrentHour(reference: now),
                    travelPx: store.mouseTravelPixelsSinceStartOfCurrentHour(reference: now),
                    bd: MacComfortCalibrationWorkload.workloadHours(
                        keystrokes: store.keysSinceStartOfCurrentHour(reference: now),
                        clicks: store.clicksSinceStartOfCurrentHour(reference: now),
                        travelPixels: store.mouseTravelPixelsSinceStartOfCurrentHour(reference: now),
                        keysPerMinuteRaw: avgKeysPM,
                        clicksPerMinuteRaw: avgClicksPM,
                        pixelThousandsPerMinuteRaw: avgPixelThousandsPM
                    ),
                    averageWPM: store.averageWordsPerMinuteForCurrentHour(reference: now)
                )

                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 1)

                MetricBlock(
                    kind: .day,
                    keystrokes: todayTotals?.keystrokeCount ?? 0,
                    clicks: todayTotals?.mouseClickCount ?? 0,
                    travelPx: todayTotals?.travelPixels ?? 0,
                    bd: {
                        guard let slot = todayTotals else {
                            return MacComfortCalibrationWorkload.Breakdown(
                                keysHours: 0,
                                clicksHours: 0,
                                pointerHours: 0,
                                approximateComputerHoursMaxChannel: 0
                            )
                        }
                        return MacComfortCalibrationWorkload.workloadHours(
                            keystrokes: slot.keystrokeCount,
                            clicks: slot.mouseClickCount,
                            travelPixels: slot.travelPixels,
                            keysPerMinuteRaw: avgKeysPM,
                            clicksPerMinuteRaw: avgClicksPM,
                            pixelThousandsPerMinuteRaw: avgPixelThousandsPM
                        )
                    }(),
                    averageWPM: nil
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    """
                    Interpreted with Past 12 hours → Average minute keys / min, clicks / min, and thousand px / min (popover sliders).
                    Hours are fractions of sustained reference pace per modality; overlaps in real typing/mousing aren’t modeled—‘max modality’ summarizes the busiest channel conservatively.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    showYesterday = true
                } label: {
                    Text("Yesterday’s totals…")
                        .font(.footnote.weight(.semibold))
                        .underline()
                }
                .buttonStyle(.plain)
                .keyboardShortcut("y", modifiers: [.command, .shift])
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .sheet(isPresented: $showYesterday) {
            MacYesterdayUsageTotalsSheet(reference: now)
                .environmentObject(store)
                .presentationBackground(.thinMaterial)
        }
    }

    private var todayTotals: ComputerUsageDaySlot? {
        store.computerUsageOnCalendarDayContaining(reference: now)
    }
}

private struct MacYesterdayUsageTotalsSheet: View {

    private enum ComfortKeys {
        static let keys = "HandTrack.mac.twelveHourAvgKeysPerMinute"
        static let clicks = "HandTrack.mac.twelveHourAvgClicksPerMinute"
        static let pxK = "HandTrack.mac.twelveHourAvgPixelThousandsPerMinute"
    }

    @EnvironmentObject private var store: HandTrackStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ComfortKeys.keys) private var avgKeysPM = 15
    @AppStorage(ComfortKeys.clicks) private var avgClicksPM = 5
    @AppStorage(ComfortKeys.pxK) private var avgPixelThousandsPM = 7

    let reference: Date

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let yesterday = yesterdaySlot {
                        Text(MacUsageSummaryFormatters.compactMonthDayYear.string(from: yesterday.dayStart))
                            .font(.title2.weight(.semibold))

                        Text(Self.intGrouped(yesterday.keystrokeCount) + " keys · " + Self.intGrouped(yesterday.mouseClickCount)
                            + " clicks · " + MacUsageSummaryFormatters.pixelSummary(yesterday.travelPixels))
                            .font(.body.monospacedDigit())
                            .fixedSize(horizontal: false, vertical: true)

                        let bd = MacComfortCalibrationWorkload.workloadHours(
                            keystrokes: yesterday.keystrokeCount,
                            clicks: yesterday.mouseClickCount,
                            travelPixels: yesterday.travelPixels,
                            keysPerMinuteRaw: avgKeysPM,
                            clicksPerMinuteRaw: avgClicksPM,
                            pixelThousandsPerMinuteRaw: avgPixelThousandsPM
                        )

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Approx. reference computer hours \(MacComfortCalibrationWorkload.formatHoursHours(bd.approximateComputerHoursMaxChannel)) (max modality)")
                                .font(.headline.weight(.semibold))

                            Text(MacComfortCalibrationWorkload.formatHoursSubtitle(bd))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        Text("Same interpretation as dashboard “Estimated usage totals”: each channel divides Mac-recorded aggregates by calibrated **steady** keys / min, clicks / min, and thousand px / minute from the slider popover beside Past 12 hours.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ContentUnavailableView(
                            "No yesterday rollup",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("Recorded minute buckets weren’t consolidated for the prior calendar day yet.")
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: 520, alignment: .leading)
            }
            .frame(minWidth: 420, idealWidth: 480, maxWidth: 560, minHeight: 320)
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

    private static func intGrouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
