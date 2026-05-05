import SwiftUI
import UIKit
import UserNotifications

struct iOSContentView: View {
    private static let hourlyReminderDesiredAppStorageKey = "HandTrack.hourlyReminderDesired"

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: HandTrackStore
    @AppStorage("macSyncHost") private var macSyncHost = ""
    @AppStorage("hourlyReminderQuietStop") private var quietStopRaw: Int =
        HourlyReminderManager.QuietStopChoice.elevenPM.rawValue
    @AppStorage("HandTrack.hourlyReminderDesired") private var hourlyReminderDesired = false
    @AppStorage("HandTrack.hourlyReminderMorningStartHour") private var reminderMorningStartHourRaw =
        HourlyReminderManager.fallbackMorningStartHour

    @FocusState private var focusedField: Field?

    @State private var painLevelLeft = 1.0
    @State private var painLevelRight = 1.0
    @State private var painAnchoredCalendarHourStart: Date?
    @State private var minutesHandsUsed = 0
    @State private var journalEntry = ""
    @State private var statusMessage = "Ready"
    @State private var isSyncing = false
    @State private var showHighPainSheet = false
    @State private var highPainPickSideLeft = true
    @State private var isTogglingHourlyReminder = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var nextReminderDisplayTime: String?
    @State private var expandedJournalLogIDs: Set<UUID> = []

    /// Readable “next reminder” line: today shows time only; otherwise includes date (“Tomorrow …” / short date).
    private static func nextReminderSubtitle(for date: Date) -> String {
        let calendar = Calendar.current
        let timeOnly: DateFormatter = {
            let f = DateFormatter()
            f.locale = .current
            f.timeStyle = .short
            f.dateStyle = .none
            return f
        }()
        let t = timeOnly.string(from: date)
        if calendar.isDateInToday(date) {
            return t
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow \(t)"
        }
        let full = DateFormatter()
        full.locale = .current
        full.dateStyle = .medium
        full.timeStyle = .short
        return full.string(from: date)
    }

    /// Effective “Reminders start” hour (stored **8 … 11** in App Storage).
    private var effectiveMorningStartHour: Int {
        HourlyReminderManager.clampedMorningStartHour(reminderMorningStartHourRaw)
    }

    private enum Field {
        case journal
        case macHost
        case minutesHands
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { minutesHandsUsed },
            set: { minutesHandsUsed = min(60, max(0, $0)) }
        )
    }

    /// Dull gray surface for hand‑usage presets only; selected pain chips use blue.
    private var hourlyChipFill: Color {
        Color(UIColor.systemGray5)
    }

    private var hourlyChipDigitColor: Color {
        Color(UIColor.label.withAlphaComponent(0.68))
    }

    /// Visible journal area height (before recovering nav‑bar chrome), ~5% taller than baseline.
    private let journalCollapsedMinHeight: CGFloat = (212 as CGFloat) * 1.05

    /// Approximate navigation bar + inline title chrome removed when hiding the nav bar (~varies slightly by device).
    private let journalHeightRecoveredFromHiddenNavChrome: CGFloat = (92 as CGFloat) * 1.05

    /// Slightly larger than Dynamic Type `.footnote` (about +1 pt vs base footnote).
    private var journalEntryFont: Font {
        Font.system(
            size: UIFont.preferredFont(forTextStyle: .footnote).pointSize + 1,
            weight: .regular
        )
    }

    private var journalTextMinHeight: CGFloat {
        journalCollapsedMinHeight + journalHeightRecoveredFromHiddenNavChrome
    }

    private var sheetHighPainBinding: Binding<Double> {
        Binding(
            get: { highPainPickSideLeft ? painLevelLeft : painLevelRight },
            set: { newValue in
                if highPainPickSideLeft {
                    painLevelLeft = newValue
                } else {
                    painLevelRight = newValue
                }
            }
        )
    }

    private var hourlyLogsLogicalToday: [HourlyHandLog] {
        let windowStart = Self.logicalHandTrackingDayStart()
        return store.hourlyLogs
            .filter { $0.createdAt >= windowStart }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// “Hand day” rolls at **3:00 AM** local — times before that belong to the previous day’s window.
    private static func logicalHandTrackingDayStart(reference: Date = Date()) -> Date {
        reference.startOfHandTrackingDay
    }

    private var savePillButton: some View {
        let empty = journalEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            focusedField = nil
            saveLog()
        } label: {
            Text("Save")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color(UIColor.systemBlue)))
        }
        .buttonStyle(.plain)
        .disabled(empty)
        .opacity(empty ? 0.45 : 1)
    }

    private var hourlyReminderEnablePillButton: some View {
        let busy = isTogglingHourlyReminder
        let showDisable = hourlyReminderDesired

        return Button {
            Task {
                await performHourlyReminderPrimaryAction()
            }
        } label: {
            Text(hourlyReminderPillTitle(showDisable: showDisable, busy: busy))
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(
                        showDisable ? Color(UIColor.systemOrange) : Color(UIColor.systemBlue)
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .disabled(busy)
        .opacity(busy ? 0.88 : 1)
    }

    /// Reads live state when tapped (avoids stale enable/disable branching in nested button actions).
    @MainActor
    private func performHourlyReminderPrimaryAction() async {
        focusedField = nil
        if hourlyReminderDesired {
            await disableHourlyReminders()
        } else {
            await enableReminder()
        }
    }

    private var hourlyReminderStatusCaption: String {
        if isTogglingHourlyReminder {
            return hourlyReminderDesired ? "Stopping…" : "Enabling…"
        }
        if notificationAuthorizationStatus == .denied {
            if hourlyReminderDesired {
                return "Reminders paused — allow HandTrack notifications in Settings, then open the app to rebuild the schedule."
            }
            return "Currently off — allow notifications in Settings, then tap Enable."
        }
        if hourlyReminderDesired {
            if let time = nextReminderDisplayTime {
                return "Currently on. Next reminder at \(time)."
            }
            return "Currently on."
        }
        return "Currently off — tap Enable to turn on."
    }

    private func hourlyReminderPillTitle(showDisable: Bool, busy: Bool) -> String {
        if busy {
            return showDisable ? "Stopping…" : "Enabling…"
        }
        return showDisable ? "Disable" : "Enable"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Hourly Entry") {
                    painBlock()

                    handsMinutesRow()

                    TextEditor(text: $journalEntry)
                        .focused($focusedField, equals: .journal)
                        .font(journalEntryFont)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: journalTextMinHeight)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 10))

                    HStack(alignment: .center) {
                        Spacer(minLength: 0)
                        savePillButton
                    }
                }

                Section("Hourly Reminder") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Reminders start")
                        HStack(spacing: 6) {
                            ForEach(HourlyReminderManager.reminderMorningStartChoices, id: \.self) { hour24 in
                                reminderMorningStartChip(hour24)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Remind until:")
                        HStack(spacing: 6) {
                            ForEach(HourlyReminderManager.QuietStopChoice.allCases) { choice in
                                eveningStopChip(choice)
                            }
                        }
                    }

                    HStack(alignment: .center, spacing: 10) {
                        Text(hourlyReminderStatusCaption)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        hourlyReminderEnablePillButton
                    }
                    .padding(.top, -8)
                    .listRowSeparator(.hidden, edges: .top)
                }

                Section("Sync To Mac") {
                    TextField("Mac IP or hostname", text: $macSyncHost)
                        .focused($focusedField, equals: .macHost)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    HStack {
                        Text("Pending logs")
                        Spacer()
                        Text("\(store.pendingLogs().count)")
                            .foregroundStyle(.secondary)
                    }

                    Button(isSyncing ? "Syncing..." : "Send Pending Logs") {
                        focusedField = nil
                        Task {
                            await syncPendingLogs()
                        }
                    }
                    .disabled(isSyncing || store.pendingLogs().isEmpty || macSyncHost.isEmpty)
                }

                Section {
                    if hourlyLogsLogicalToday.isEmpty {
                        Text(emptyTodayLogsBanner)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(hourlyLogsLogicalToday) { log in
                            TodaysJournalLogRow(
                                log: log,
                                expandedJournalLogIDs: $expandedJournalLogIDs,
                                previewLineLimit: 6
                            )
                        }
                    }
                } header: {
                    Text("Today's logs")
                } footer: {
                    Text("Entries since 3:00 AM. A new hand day starts at 3:00 AM.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                reconcilePainAnchoredHour(now: Date())
                Task {
                    await refreshHourlyReminderUIState()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await refreshHourlyReminderUIState()
                }
            }
            .onReceive(
                Timer.publish(every: 55, tolerance: 5, on: .main, in: .common).autoconnect()
            ) { date in
                reconcilePainAnchoredHour(now: date)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .sheet(isPresented: $showHighPainSheet) {
                PainHighRangeSheet(
                    painValue: sheetHighPainBinding,
                    chipFill: hourlyChipFill,
                    mutedLabelColor: hourlyChipDigitColor,
                    hairlineWidth: hairlineDividerWidth
                )
            }
        }
    }

    private func painBlock() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pain")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)

            painAlignedRow(sideLabel: "Left", opensHighPickWhenLeftSide: true, binding: $painLevelLeft)
            painAlignedRow(sideLabel: "Right", opensHighPickWhenLeftSide: false, binding: $painLevelRight)
        }
    }

    /// Label + chips; chip row stretches to fill remaining width so circles grow without trailing dead space.
    private func painAlignedRow(sideLabel: String, opensHighPickWhenLeftSide: Bool, binding: Binding<Double>)
        -> some View
    {
        HStack(alignment: .center, spacing: 8) {
            Text(sideLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)

            painDigitRow(opensHighPickWhenLeftSide: opensHighPickWhenLeftSide, binding: binding)
                .frame(maxWidth: .infinity)
        }
    }

    /// Seven equal slots (0 … 5 + `*`) share the row width.
    private func painDigitRow(opensHighPickWhenLeftSide: Bool, binding: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            ForEach(0...5, id: \.self) { n in
                PainDigitCircle(
                    digit: n,
                    value: binding,
                    unselectedChipFill: hourlyChipFill,
                    unselectedLabelColor: hourlyChipDigitColor,
                    hairlineWidth: hairlineDividerWidth
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
            }
            painCircleStarChip(opensPickForLeftSide: opensHighPickWhenLeftSide, binding: binding)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
        }
    }

    /// Opens a sheet mirroring digit chips for 6…10 — tap whole, hold briefly for 6½…10½.
    @ViewBuilder
    private func painCircleStarChip(opensPickForLeftSide: Bool, binding: Binding<Double>) -> some View {
        let value = binding.wrappedValue
        let hiSelected = value >= 6

        Button {
            focusedField = nil
            highPainPickSideLeft = opensPickForLeftSide
            showHighPainSheet = true
        } label: {
            Text(hiSelected ? value.handTrackPainCompactLabel : "*")
                .font(.callout.monospacedDigit())
                .fontWeight(.regular)
                .foregroundStyle(hiSelected ? Color.white : hourlyChipDigitColor)
                .minimumScaleFactor(0.38)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    ZStack {
                        Circle()
                            .fill(hiSelected ? Color(UIColor.systemBlue) : hourlyChipFill)
                        if !hiSelected {
                            Circle()
                                .strokeBorder(
                                    Color(UIColor.separator).opacity(0.38),
                                    lineWidth: hairlineDividerWidth
                                )
                        }
                    }
                )
                .clipShape(Circle())
                .contentShape(Circle())
                .accessibilityLabel(
                    hiSelected
                        ? "Pain \(value.handTrackPainCompactLabel), higher range 6–10½"
                        : "Higher pain, 6 through 10, tap chip to open picker"
                )
                .accessibilityHint("Opens a sheet—tap any number or briefly hold it for half, for example seven and one half.")
        }
        .buttonStyle(.plain)
    }

    private var hairlineDividerWidth: CGFloat { 0.5 }

    private func handsMinutesRow() -> some View {
        let minuteMarks = Array(stride(from: 0, through: 60, by: 10))

        return VStack(alignment: .leading, spacing: 16) {
            Text("Hand usage")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 12) {
                TextField("", value: minutesBinding, format: .number)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .minutesHands)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .frame(width: 48)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(UIColor.secondarySystemFill))
                    )
                Slider(
                    value: Binding(
                        get: { Double(minutesHandsUsed) },
                        set: { minutesHandsUsed = min(60, max(0, Int($0.rounded()))) }
                    ),
                    in: 0...60,
                    step: 1
                )
            }

            handsMinuteMarksRow(markers: minuteMarks)
        }
    }

    private func handsMinuteMarksRow(markers: [Int]) -> some View {
        HStack(spacing: 4) {
            ForEach(markers, id: \.self) { m in
                HandsMinutePresetChip(
                    marker: m,
                    minutes: $minutesHandsUsed,
                    chipFill: hourlyChipFill,
                    labelColor: hourlyChipDigitColor,
                    hairlineWidth: hairlineDividerWidth
                )
            }
        }
        .padding(.top, 2)
    }

    private func reconcilePainAnchoredHour(now: Date) {
        let anchor = now.startOfHour
        guard painAnchoredCalendarHourStart != anchor else { return }
        painAnchoredCalendarHourStart = anchor
        guard let sug = baselinePainPair(logs: store.hourlyLogs, now: now) else {
            painLevelLeft = 1.0
            painLevelRight = 1.0
            return
        }
        painLevelLeft = sug.left
        painLevelRight = sug.right
    }

    private func baselinePainPair(logs: [HourlyHandLog], now: Date) -> (left: Double, right: Double)? {
        guard !logs.isEmpty else { return nil }
        let anchor = now.startOfHour
        guard let prevHourStart = Calendar.current.date(byAdding: .hour, value: -1, to: anchor) else {
            return nil
        }
        let inPrevHourLogs = logs
            .filter { $0.hourStart == prevHourStart }
            .max(by: { $0.createdAt < $1.createdAt })
        if let pick = inPrevHourLogs {
            return (pick.painLevelLeft, pick.painLevelRight)
        }
        return logs
            .filter { $0.hourStart < anchor }
            .max(by: { a, b in
                (a.hourStart, a.createdAt) < (b.hourStart, b.createdAt)
            })
            .map { ($0.painLevelLeft, $0.painLevelRight) }
    }

    @ViewBuilder
    private func eveningStopChip(_ choice: HourlyReminderManager.QuietStopChoice) -> some View {
        let selected = quietStopRaw == choice.rawValue

        Group {
            if selected {
                eveningStopChipButton(choice)
                    .buttonStyle(BorderedProminentButtonStyle())
            } else {
                eveningStopChipButton(choice)
                    .buttonStyle(BorderedButtonStyle())
            }
        }
    }

    private func eveningStopChipButton(_ choice: HourlyReminderManager.QuietStopChoice) -> some View {
        Button {
            quietStopRaw = choice.rawValue
            Task {
                await rescheduleActiveHourlyRemindersIfNeeded()
            }
        } label: {
            Text(choice.pickerTitle)
                .font(.footnote.weight(.medium))
                .minimumScaleFactor(0.8)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }

    private func reminderMorningStartChipTitle(hour24: Int) -> String {
        switch hour24 {
        case 8: return "8 AM"
        case 9: return "9 AM"
        case 10: return "10 AM"
        case 11: return "11 AM"
        default: return "\(hour24) AM"
        }
    }

    @ViewBuilder
    private func reminderMorningStartChip(_ hour24: Int) -> some View {
        let selected = hour24 == effectiveMorningStartHour

        Group {
            if selected {
                reminderMorningStartChipButton(hour24)
                    .buttonStyle(BorderedProminentButtonStyle())
            } else {
                reminderMorningStartChipButton(hour24)
                    .buttonStyle(BorderedButtonStyle())
            }
        }
    }

    private func reminderMorningStartChipButton(_ hour24: Int) -> some View {
        Button {
            reminderMorningStartHourRaw = hour24
            Task {
                await rescheduleActiveHourlyRemindersIfNeeded()
            }
        } label: {
            Text(reminderMorningStartChipTitle(hour24: hour24))
                .font(.footnote.weight(.medium))
                .minimumScaleFactor(0.8)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }

    private func saveLog() {
        store.saveHourlyLog(
            painLevelLeft: painLevelLeft,
            painLevelRight: painLevelRight,
            minutesHandsUsed: minutesHandsUsed,
            journalEntry: journalEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        minutesHandsUsed = 0
        journalEntry = ""
        statusMessage = "Saved (\(Date().displayTime))"

        let host = macSyncHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !isSyncing else { return }
        Task { await syncPendingLogs() }
    }

    private var emptyTodayLogsBanner: String {
        store.hourlyLogs.isEmpty
            ? "No logs yet"
            : "No logs since 3:00 AM — your hand day resets at 3:00 AM."
    }

    private func rescheduleActiveHourlyRemindersIfNeeded() async {
        let wantsHourly = await MainActor.run { hourlyReminderDesired }
        guard wantsHourly else { return }
        let quietRaw = await MainActor.run { quietStopRaw }
        let wakeSnapshot = await MainActor.run { HourlyReminderManager.clampedMorningStartHour(reminderMorningStartHourRaw) }
        let choice = HourlyReminderManager.QuietStopChoice(rawValue: quietRaw)
            ?? HourlyReminderManager.QuietStopChoice.elevenPM

        do {
            try await HourlyReminderManager.rescheduleAllHourlySlots(
                quietChoice: choice,
                wakeHour: wakeSnapshot
            )
        } catch {}

        await refreshHourlyReminderUIState()
    }

    private func refreshHourlyReminderUIState() async {
        await migrateLegacyHourlyReminderPreferenceIfNeeded()
        await HourlyReminderManager.cancelLegacyDiagnosticNotifications()

        let (wantsNotifications, quietRawSnapshot, wakeRawSnapshot) = await MainActor.run {
            (hourlyReminderDesired, quietStopRaw, reminderMorningStartHourRaw)
        }
        let wakeHour = HourlyReminderManager.clampedMorningStartHour(wakeRawSnapshot)
        let choice = HourlyReminderManager.QuietStopChoice(rawValue: quietRawSnapshot)
            ?? HourlyReminderManager.QuietStopChoice.elevenPM

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authSnapshot = settings.authorizationStatus

        do {
            if wantsNotifications {
                try await HourlyReminderManager.replenishRollingIfDesired(
                    quietChoice: choice,
                    wakeHour: wakeHour,
                    userWantsNotifications: wantsNotifications
                )
            }
        } catch {}

        let nextLabel: String?
        if wantsNotifications, authSnapshot != .denied {
            let nextDate = await HourlyReminderManager.nextScheduledCanonicalReminderDate()
            nextLabel = nextDate.map { Self.nextReminderSubtitle(for: $0) }
        } else {
            nextLabel = nil
        }

        await MainActor.run {
            notificationAuthorizationStatus = authSnapshot
            nextReminderDisplayTime = nextLabel
        }
    }

    private func migrateLegacyHourlyReminderPreferenceIfNeeded() async {
        guard UserDefaults.standard.object(forKey: Self.hourlyReminderDesiredAppStorageKey) == nil else { return }
        guard await HourlyReminderManager.hasScheduledHourlyReminders() else { return }
        await MainActor.run {
            hourlyReminderDesired = true
        }
    }

    private func disableHourlyReminders() async {
        isTogglingHourlyReminder = true
        defer { isTogglingHourlyReminder = false }

        await MainActor.run {
            hourlyReminderDesired = false
        }

        await HourlyReminderManager.cancelAllScheduled()
        await refreshHourlyReminderUIState()
        await MainActor.run {
            statusMessage = "Hourly reminders off"
        }
    }

    private func enableReminder() async {
        isTogglingHourlyReminder = true
        defer { isTogglingHourlyReminder = false }

        let wakeSnapshot = await MainActor.run { HourlyReminderManager.clampedMorningStartHour(reminderMorningStartHourRaw) }

        do {
            let choice = HourlyReminderManager.QuietStopChoice(rawValue: quietStopRaw)
                ?? HourlyReminderManager.QuietStopChoice.elevenPM
            let scheduled = try await HourlyReminderManager.requestPermissionAndSchedule(
                quietChoice: choice,
                wakeHour: wakeSnapshot
            )
            await MainActor.run {
                if scheduled {
                    hourlyReminderDesired = true
                }
            }
        } catch {
            await MainActor.run {
                statusMessage = "Reminder failed: \(error.localizedDescription)"
            }
            await refreshHourlyReminderUIState()
            return
        }

        await refreshHourlyReminderUIState()
        await MainActor.run {
            if hourlyReminderDesired {
                statusMessage = "Hourly reminders on"
            } else if notificationAuthorizationStatus == .denied {
                statusMessage = "Notifications blocked — allow HandTrack in Settings, then tap Enable"
            } else {
                statusMessage = "Couldn’t schedule hourly reminders"
            }
        }
    }

    private func syncPendingLogs() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let pendingLogs = store.pendingLogs()
            let response = try await HandTrackSyncClient.send(logs: pendingLogs, to: macSyncHost)
            store.markLogsSynced(ids: response.acceptedIDs)
            statusMessage = "Synced \(response.acceptedIDs.count) log(s)"
        } catch {
            statusMessage = "Sync failed: \(error.localizedDescription)"
        }
    }
}

/// Hand-day scoped hourly log row (six-line journal preview; See more / See less).
private struct TodaysJournalLogRow: View {
    let log: HourlyHandLog
    @Binding var expandedJournalLogIDs: Set<UUID>
    let previewLineLimit: Int

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
        VStack(alignment: .leading, spacing: 4) {
            Text("\(log.createdAt.displayTime) · \(log.hourStart.displayHourBucket)")
                .font(.headline)
            Text(
                "\(log.handTrackPainLeftRightLogPhrase) · \(log.minutesHandsUsed) min · \(log.syncStatus.rawValue)"
            )
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
                            .foregroundStyle(Color(UIColor.systemBlue))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Pain digit circles (half-step feedback)

/// Shared “brief hold” duration for pain half‑steps and hand‑usage +5 minute presets.
private enum BriefHoldGestureTiming {
    static let seconds: Double = 0.2
}

private enum PainHalfStepFeedback {
    private static let impact = UIImpactFeedbackGenerator(style: .medium)

    static func pulse() {
        impact.prepare()
        impact.impactOccurred(intensity: 1)
    }
}

/// Preset minute ring (0 … 60 in tens): tap sets marker, brief hold sets `marker + 5` (capped at 60).
private struct HandsMinutePresetChip: View {
    let marker: Int
    @Binding var minutes: Int
    let chipFill: Color
    let labelColor: Color
    let hairlineWidth: CGFloat

    @State private var pulseScale: CGFloat = 1
    private let emphasisScale: CGFloat = 1.12

    private var bonusMinutes: Int { min(60, marker + 5) }

    private var selected: Bool {
        minutes == marker || minutes == marker + 5
    }

    var body: some View {
        Text("\(marker)")
            .font(.body.monospacedDigit().weight(.regular))
            .foregroundStyle(labelColor)
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack {
                    Circle()
                        .fill(chipFill)
                    Circle()
                        .strokeBorder(
                            Color(UIColor.separator).opacity(selected ? 0.22 : 0.38),
                            lineWidth: hairlineWidth
                        )
                }
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(Circle())
            .scaleEffect(pulseScale)
            .contentShape(Circle())
            .highPriorityGesture(bonusGesture)
            .onTapGesture {
                minutes = marker
            }
            .accessibilityLabel("\(marker) minutes preset")
            .accessibilityHint(accessibilityHintBody)
    }

    private var accessibilityHintBody: String {
        if bonusMinutes != marker {
            return "Tap for \(marker) minutes, or hold \(String(format: "%.1f", BriefHoldGestureTiming.seconds)) seconds for \(bonusMinutes) minutes."
        }
        return "Tap for \(marker) minutes. Holding here also keeps \(marker) minutes (already at cap)."
    }

    private var bonusGesture: some Gesture {
        LongPressGesture(minimumDuration: BriefHoldGestureTiming.seconds, maximumDistance: 24)
            .onEnded { _ in
                PainHalfStepFeedback.pulse()
                minutes = bonusMinutes
                withAnimation(.spring(response: 0.26, dampingFraction: 0.52)) {
                    pulseScale = emphasisScale
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 130_000_000)
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                        pulseScale = 1
                    }
                }
            }
    }
}

private struct PainDigitCircle: View {
    let digit: Int
    @Binding var value: Double
    let unselectedChipFill: Color
    let unselectedLabelColor: Color
    let hairlineWidth: CGFloat
    /// Called after assigning a tap or successful half‑step long‑press (e.g. to dismiss an overlay sheet).
    var onSelectionCommitted: () -> Void = {}

    @State private var pulseScale: CGFloat = 1

    private let emphasisScale: CGFloat = 1.12

    private var selected: Bool {
        Self.matchesWholeOrHalf(value: value, digit: digit)
    }

    var body: some View {
        let title = Self.chipTitle(value: value, digit: digit)

        Text(title)
            .font(.callout.monospacedDigit().weight(.regular))
            .foregroundStyle(selected ? Color.white : unselectedLabelColor)
            .minimumScaleFactor(digit >= 10 ? 0.38 : 0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(chipBackground)
            .clipShape(Circle())
            .scaleEffect(pulseScale)
            .contentShape(Circle())
            .highPriorityGesture(halfStepGesture)
            .onTapGesture {
                value = Double(digit)
                onSelectionCommitted()
            }
            .accessibilityLabel(Self.accessibilityTitle(displayTitle: title, value: value, digit: digit))
            .accessibilityHint(
                "Tap for whole step, or hold \(String(format: "%.1f", BriefHoldGestureTiming.seconds)) seconds for half step."
            )
    }

    private var chipBackground: some View {
        ZStack {
            Circle()
                .fill(selected ? Color(UIColor.systemBlue) : unselectedChipFill)
            if !selected {
                Circle()
                    .strokeBorder(
                        Color(UIColor.separator).opacity(0.38),
                        lineWidth: hairlineWidth
                    )
            }
        }
    }

    private var halfStepGesture: some Gesture {
        LongPressGesture(minimumDuration: BriefHoldGestureTiming.seconds, maximumDistance: 24)
            .onEnded { _ in
                PainHalfStepFeedback.pulse()
                value = Double(digit) + 0.5
                withAnimation(.spring(response: 0.26, dampingFraction: 0.52)) {
                    pulseScale = emphasisScale
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 130_000_000)
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                        pulseScale = 1
                    }
                }
                onSelectionCommitted()
            }
    }

    private static func matchesWholeOrHalf(value: Double, digit: Int) -> Bool {
        abs(value - Double(digit)) < 0.001 || abs(value - (Double(digit) + 0.5)) < 0.001
    }

    private static func chipTitle(value: Double, digit: Int) -> String {
        if matchesWholeOrHalf(value: value, digit: digit) {
            if abs(value - (Double(digit) + 0.5)) < 0.001 {
                return digit == 0 ? Double.handTrackPainHalfGlyph : "\(digit)\(Double.handTrackPainHalfGlyph)"
            }
            return "\(digit)"
        }
        return "\(digit)"
    }

    private static func accessibilityTitle(displayTitle: String, value: Double, digit: Int) -> String {
        if digit == 0, matchesWholeOrHalf(value: value, digit: digit),
           abs(value - 0.5) < 0.001 {
            return "One half"
        }
        return displayTitle
    }
}

/// Levels **6 … 10** with the same tap / brief‑hold‑for‑½ interaction as digits 0–5.
private struct PainHighRangeSheet: View {
    @Binding var painValue: Double
    let chipFill: Color
    let mutedLabelColor: Color
    let hairlineWidth: CGFloat

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Tap 6–10 for a whole step, or briefly hold a chip for a half step (e.g. 7½).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ForEach(6...10, id: \.self) { n in
                        PainDigitCircle(
                            digit: n,
                            value: $painValue,
                            unselectedChipFill: chipFill,
                            unselectedLabelColor: mutedLabelColor,
                            hairlineWidth: hairlineWidth,
                            onSelectionCommitted: { dismiss() }
                        )
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("6 – 10")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.36), .medium])
        .presentationDragIndicator(.visible)
    }
}
