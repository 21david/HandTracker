import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @StateObject private var viewModel = MacDashboardViewModel()
    @State private var showSyncInfo = false
    @State private var showIosLogsSheet = false
    @State private var showActivityLimits = false
    @State private var showingMoreCharts = false
    @State private var expandedSyncedLogJournalIDs: Set<UUID> = []
    @AppStorage("HandTrack.mac.alarmControlMode") private var alarmControlModeRaw = MacAlarmControlMode.mute.rawValue

    private static let muteTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        Group {
            if showingMoreCharts {
                moreChartsView
            } else {
                mainDashboardView
            }
        }
        .frame(minWidth: 900, idealWidth: 960, maxWidth: .infinity)
        .frame(minHeight: 940, idealHeight: 980, maxHeight: .infinity)
        .onAppear {
            print("MacContentView appeared")
            viewModel.start(store: store)
        }
        .onDisappear {
            viewModel.stop()
        }
        .sheet(isPresented: $showIosLogsSheet) {
            iosLogsSheet
        }
    }

    private var mainDashboardView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                headerBar

                MacActivityLimitsPauseBanner(viewModel: viewModel)

                MacActivityBreakBanner(controller: viewModel.activityLimits)

                let summaryPulse =
                    MacChartEquatableBucket.keystrokeRevision(store)
                    &+ MacChartEquatableBucket.mouseClickRevision(store)
                    &+ MacChartEquatableBucket.mouseTravelRevision(store)
                    &+ MacChartEquatableBucket.scrollBumpRevision(store)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    MacUsageDashboardSummary(now: ctx.date)
                        .id(summaryPulse)
                }

                MacKeystrokeFiveMinuteChart()
                MacMouseClickFiveMinuteChart()
                MacMouseTravelFiveMinuteChart()
                MacScrollBumpFiveMinuteChart()
                MacTwelveHourStackedUsagePainChart()
                MacTwelveDayStackedUsagePainChart()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var moreChartsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                HStack(alignment: .center, spacing: 12) {
                    Button {
                        showingMoreCharts = false
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .help("Return to the main dashboard")

                    Spacer(minLength: 8)

                    Text("More Charts")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)
                }

                MacTwelveWeekStackedUsagePainChart()
                MacTwelveMonthStackedUsagePainChart()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerBar: some View {
        TimelineView(.periodic(from: .now, by: 10)) { timeline in
            HStack(alignment: .center, spacing: 12) {
                Image("HandLogo")
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("HandTrack")

                Button {
                    showSyncInfo.toggle()
                } label: {
                    Label("Sync & iPhone", systemImage: "info.circle")
                }
                .buttonStyle(.bordered)
                .help("Wi‑Fi sync details and HandTrack mobile setup")
                .popover(isPresented: $showSyncInfo, attachmentAnchor: .point(.bottom), arrowEdge: .bottom) {
                    syncInfoPopover
                }

                Spacer(minLength: 8)

                muteControls(now: timeline.date)

                Button {
                    showIosLogsSheet = true
                } label: {
                    Text("Logs")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(0.2)
                }
                .buttonStyle(GrayAccessoryPillButtonStyle())
                .help("View hourly entries synced from HandTrack iOS")

                Button {
                    store.openStorageDirectory()
                } label: {
                    Text("Open Data Folder")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(0.15)
                }
                .buttonStyle(GrayAccessoryPillButtonStyle())
                .help("Reveal HandTrack’s SQLite folder in Finder")
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button {
                    showActivityLimits.toggle()
                } label: {
                    Label("Activity Limits", systemImage: "timer")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(0.15)
                }
                .buttonStyle(OrangeAccessoryPillButtonStyle())
                .help("Set per-activity break-alarm thresholds")
                .popover(isPresented: $showActivityLimits, attachmentAnchor: .point(.bottom), arrowEdge: .bottom) {
                    MacActivityLimitsPopover {
                        viewModel.activityLimits.refreshAfterSettingsChange()
                    }
                }

                Button {
                    showingMoreCharts = true
                } label: {
                    Text("More Charts")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(0.15)
                }
                .buttonStyle(GrayAccessoryPillButtonStyle())
                .help("12-week and 12-month usage charts")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private enum MuteInterval: Int, CaseIterable, Identifiable {
        case five = 5
        case ten = 10
        case fifteen = 15
        case thirty = 30
        case oneHour = 60

        var id: Int { rawValue }

        var shortLabel: String {
            switch self {
            case .five: return "5m"
            case .ten: return "10m"
            case .fifteen: return "15m"
            case .thirty: return "30m"
            case .oneHour: return "1h"
            }
        }

        func help(for mode: MacAlarmControlMode) -> String {
            let action = mode == .mute ? "Silence break-alarm sounds" : "Pause Activity Limits"
            switch self {
            case .five: return "\(action) for 5 minutes."
            case .ten: return "\(action) for 10 minutes."
            case .fifteen: return "\(action) for 15 minutes."
            case .thirty: return "\(action) for 30 minutes."
            case .oneHour: return "\(action) for 1 hour."
            }
        }
    }

    private var alarmControlMode: MacAlarmControlMode {
        get { MacAlarmControlMode(rawValue: alarmControlModeRaw) ?? .mute }
        nonmutating set { alarmControlModeRaw = newValue.rawValue }
    }

    private var alarmControlModeBinding: Binding<MacAlarmControlMode> {
        Binding(
            get: { alarmControlMode },
            set: { alarmControlMode = $0 }
        )
    }

    /// Rotating Mute/Pause selector plus shared duration presets.
    @ViewBuilder
    private func muteControls(now: Date) -> some View {
        let _ = viewModel.refreshExpiredMuteIfNeeded(now: now)
        let _ = viewModel.refreshExpiredPauseIfNeeded(now: now)

        let mode = alarmControlMode
        let activeExpiry = mode == .mute
            ? viewModel.recordingAlarmMuteExpiresAt
            : viewModel.activityLimitsPauseExpiresAt
        let active = activeExpiry.map { $0 > now } ?? false
        let activeMinutes = mode == .mute
            ? viewModel.mutedBreakAlarmChosenMinutes
            : viewModel.activityLimitsPauseChosenMinutes
        let statusText: String? = {
            if let expiry = activeExpiry, expiry > now {
                let verb = mode == .mute ? "Muted" : "Paused"
                return "\(verb) until \(Self.muteTimeFormatter.string(from: expiry))"
            }
            return nil
        }()

        HStack(alignment: .center, spacing: 10) {
            MacMutePauseCylinderPicker(selection: alarmControlModeBinding)

            if let statusText {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mode == .pause ? Color.blue : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            HStack(spacing: 8) {
                ForEach(MuteInterval.allCases) { interval in
                    Button {
                        if mode == .mute {
                            viewModel.muteBreakAlarms(minutes: interval.rawValue)
                        } else {
                            viewModel.pauseActivityLimits(minutes: interval.rawValue)
                        }
                    } label: {
                        Text(interval.shortLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(MuteDurationPillStyle(selectionLockedIn: active
                            && activeMinutes == interval.rawValue))
                    .help(interval.help(for: mode))
                }

                Button {
                    if mode == .mute {
                        viewModel.clearBreakAlarmMute()
                    } else {
                        viewModel.clearActivityLimitsPause()
                    }
                } label: {
                    Text(mode == .mute ? "Unmute" : "Resume")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(0.2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(UnmutePillButtonStyle())
                .disabled(!active)
                .opacity(active ? 1 : 0.42)
                .help(active
                    ? (mode == .mute ? "Resume break-alarm sounds immediately." : "Resume Activity Limits immediately.")
                    : (mode == .mute ? "Sounds are not muted." : "Activity Limits are not paused."))
            }
            .layoutPriority(1)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var iosLogsSheet: some View {
        NavigationStack {
            Group {
                if store.hourlyLogs.isEmpty {
                    Text("No iPhone logs received yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.hourlyLogs.prefix(100)) { log in
                        MacHourlySyncedLogRow(
                            log: log,
                            expandedJournalLogIDs: $expandedSyncedLogJournalIDs
                        )
                    }
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showIosLogsSheet = false
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }

    private var syncInfoPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Wi‑Fi log sync setup")
                    .font(.title3.weight(.semibold))

                Text(
                    """
                    “Send Pending Logs” on iPhone connects to THIS HandTrack Mac app over Wi‑Fi. \
                    Your phone HTTP POST hits port 8787; this app merges JSON into local \
                    SQLite (no separate backend). Keep the Mac app open while syncing.
                    """
                )
                .font(.body)
                .foregroundStyle(.secondary)

                Text("On this Mac")
                    .font(.headline)

                numberedSyncStep(
                    1,
                    "Keep HandTrack for Mac running. The receiver only listens while this app stays open."
                )
                numberedSyncStep(
                    2,
                    """
                    Find IPv4 on Wi‑Fi: Apple menu  → System Settings → Network → Wi‑Fi → \
                    Details… → copy IPv4 Address (for example 192.168.1.24). \
                    On Ethernet-only Macs open Network → the active Ethernet/filter service → Details → IPv4 Address.
                    """
                )
                numberedSyncStep(
                    3,
                    """
                    Hostname shortcut (often works on home Wi‑Fi): System Settings → General → \
                    Sharing → read Local hostname (for example Dana-MacBook-Pro.local). Paste it on the phone \
                    if `.local` names resolve—otherwise use the IPv4 from step 2.
                    """
                )

                Text("Firewall")
                    .font(.headline)
                    .padding(.top, 4)

                Text(
                    """
                    Use System Settings’ search bar (near the top‑left corner), type Firewall, \
                    then open Firewall settings—temporarily toggle it off to test, or when prompted, \
                    allow incoming connections for Hand Helper / HandTrack. Privacy & Security also lists Firewall on newer macOS.
                    """
                )
                .font(.body)

                Text("On your iPhone")
                    .font(.headline)
                    .padding(.top, 4)

                numberedSyncStep(
                    4,
                    """
                    Confirm the phone is on the same Wi‑Fi as this Mac: Settings → Wi‑Fi → \
                    inspect the SSID/router you expect. Separate “Guest” networks often isolate devices.
                    """
                )
                numberedSyncStep(
                    5,
                    """
                    HandTrack → “Sync To Mac”. Paste ONLY the IPv4 (192.168.x.y) OR the `.local` name—leave out \
                    http:// and `:8787` (HandTrack app adds port 8787 automatically).
                    """
                )
                numberedSyncStep(
                    6,
                    "Tap Send Pending Logs—accepted uploads leave Pending on the phone and appear in this Mac app's Logs toolbar button.")

                Text("Still stuck?")
                    .font(.headline)
                    .padding(.top, 4)

                Text(
                    """
                    If sync fails silently, rerun after fixing firewall/VPN interference. Optionally use Terminal (`ping`) from \
                    Mac to router or vice versa—the goal is both devices being fully visible on LAN without VPN overriding Wi‑Fi.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Divider()
                    .padding(.vertical, 4)

                Text(viewModel.syncStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Done") {
                    showSyncInfo = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .frame(maxWidth: 440, alignment: .leading)
        }
        .frame(minWidth: 420, idealWidth: 440, maxWidth: 460, maxHeight: 520)
    }

    @ViewBuilder
    private func numberedSyncStep(_ n: Int, _ prose: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n).")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(prose)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

/// Logs sheet row (synced-from-iPhone): six-line journal preview with See more — matches iOS `TodaysJournalLogRow`.
private struct MacHourlySyncedLogRow: View {
    let log: HourlyHandLog
    @Binding var expandedJournalLogIDs: Set<UUID>

    private let previewLineLimit = 6

    private var expanded: Bool { expandedJournalLogIDs.contains(log.id) }

    private var journalTrimmed: String {
        log.journalEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var journalMaybeOverflows: Bool {
        guard !journalTrimmed.isEmpty else { return false }
        let explicitLines = journalTrimmed.split(whereSeparator: \.isNewline).count
        return journalTrimmed.count > 260 || explicitLines > previewLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(log.createdAt.displayTime) · \(log.hourStart.displayHourBucket)")
                .font(.headline)
            Text("\(log.handTrackPainLeftRightLogPhrase) • \(log.minutesHandsUsed) min")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !journalTrimmed.isEmpty {
                Text(log.journalEntry)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .lineLimit(expanded ? nil : previewLineLimit)

                if journalMaybeOverflows {
                    Button {
                        var ids = expandedJournalLogIDs
                        if expanded {
                            ids.remove(log.id)
                        } else {
                            ids.insert(log.id)
                        }
                        expandedJournalLogIDs = ids
                    } label: {
                        Text(expanded ? "See less" : "See more")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Mute controls + gray accessory pills

/// Warm-orange capsule for Activity Limits — uses the same geometry as the gray pill
/// to keep the header visually consistent while signaling the safety / break theme.
private struct OrangeAccessoryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.88 : 0.97))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.99, green: 0.62, blue: 0.20),
                                    Color(red: 0.85, green: 0.40, blue: 0.06),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.34), Color.clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.55)
                            )
                        )
                        .padding(1)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.45),
                                    Color.black.opacity(0.28),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.26), radius: configuration.isPressed ? 1 : 3, x: 0, y: configuration.isPressed ? 0 : 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Neutral metal capsule for Logs / Open Data Folder (muted blue‑pill geometry, gray alloy).
private struct GrayAccessoryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.88 : 0.97))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.62, green: 0.63, blue: 0.66),
                                    Color(red: 0.40, green: 0.41, blue: 0.44),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.34), Color.clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.55)
                            )
                        )
                        .padding(1)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.45),
                                    Color.black.opacity(0.28),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.26), radius: configuration.isPressed ? 1 : 3, x: 0, y: configuration.isPressed ? 0 : 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MuteDurationPillStyle: ButtonStyle {
    /// Darker navy “locked-in” styling for the mute duration the user tapped.
    var selectionLockedIn = false

    func makeBody(configuration: Configuration) -> some View {
        let topLight = Color.white.opacity(selectionLockedIn ? 0.26 : 0.38)

        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.88 : 0.98))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors:
                                    selectionLockedIn
                                        ? [
                                            Color(red: 0.09, green: 0.24, blue: 0.72),
                                            Color(red: 0.03, green: 0.10, blue: 0.48),
                                        ]
                                        : [
                                            Color(red: 0.38, green: 0.58, blue: 0.98),
                                            Color(red: 0.16, green: 0.35, blue: 0.78),
                                        ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [topLight, Color.clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.55)
                            )
                        )
                        .padding(1)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(selectionLockedIn ? 0.38 : 0.55),
                                    Color.black.opacity(selectionLockedIn ? 0.32 : 0.22),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: .black.opacity(selectionLockedIn ? 0.38 : 0.28),
                    radius: configuration.isPressed ? 1 : 3,
                    x: 0,
                    y: configuration.isPressed ? 0 : 2
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: selectionLockedIn)
    }
}

private struct UnmutePillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.88 : 0.98) : 0.55)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: isEnabled
                                    ? [
                                        Color(red: 0.22, green: 0.72, blue: 0.48),
                                        Color(red: 0.08, green: 0.48, blue: 0.32),
                                    ]
                                    : [
                                        Color(red: 0.28, green: 0.32, blue: 0.36),
                                        Color(red: 0.16, green: 0.18, blue: 0.22),
                                    ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(isEnabled ? 0.32 : 0.12), Color.clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.55)
                            )
                        )
                        .padding(1)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isEnabled ? 0.45 : 0.2),
                                    Color.black.opacity(0.2),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: .black.opacity(isEnabled ? 0.26 : 0.12),
                    radius: configuration.isPressed ? 1 : 3,
                    x: 0,
                    y: configuration.isPressed ? 0 : 2
                )
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
