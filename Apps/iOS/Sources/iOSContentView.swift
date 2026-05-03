import SwiftUI
import UIKit

struct iOSContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @AppStorage("macSyncHost") private var macSyncHost = ""
    @AppStorage("hourlyReminderQuietStop") private var quietStopRaw: Int =
        HourlyReminderManager.QuietStopChoice.elevenPM.rawValue
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
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Remind until:")
                        HStack(spacing: 6) {
                            ForEach(HourlyReminderManager.QuietStopChoice.allCases) { choice in
                                eveningStopChip(choice)
                            }
                        }
                        Button("Enable") {
                            Task {
                                await enableReminder()
                            }
                        }
                    }
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

                Section("Recent Logs") {
                    if store.hourlyLogs.isEmpty {
                        Text("No logs yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.hourlyLogs.prefix(5)) { log in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(log.createdAt.displayTime) · \(log.hourStart.displayHourBucket)")
                                    .font(.headline)
                                Text(
                                    "L \(log.painLevelLeft.handTrackPainCompactLabel), R \(log.painLevelRight.handTrackPainCompactLabel) · \(log.minutesHandsUsed) min · \(log.syncStatus.rawValue)"
                                )
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if !log.journalEntry.isEmpty {
                                    Text(log.journalEntry)
                                        .font(.body)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                reconcilePainAnchoredHour(now: Date())
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
        let minuteMarks = Array(stride(from: 10, through: 60, by: 10))

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
        HStack(spacing: 8) {
            ForEach(markers, id: \.self) { m in
                Button {
                    minutesHandsUsed = m
                } label: {
                    let selected = minutesHandsUsed == m
                    ZStack {
                        Circle()
                            .fill(hourlyChipFill)
                        Circle()
                            .strokeBorder(
                                Color(UIColor.separator).opacity(selected ? 0.22 : 0.38),
                                lineWidth: hairlineDividerWidth
                            )
                        Text("\(m)")
                            .font(.body.monospacedDigit().weight(.regular))
                            .foregroundStyle(hourlyChipDigitColor)
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                            .padding(4)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
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
        } label: {
            Text(choice.pickerTitle)
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
    }

    private func enableReminder() async {
        do {
            let choice = HourlyReminderManager.QuietStopChoice(rawValue: quietStopRaw)
                ?? HourlyReminderManager.QuietStopChoice.elevenPM
            try await HourlyReminderManager.requestPermissionAndSchedule(
                quietChoice: choice,
                wakeHour: HourlyReminderManager.morningResumeHour
            )
            statusMessage = "Reminder on"
        } catch {
            statusMessage = "Reminder failed: \(error.localizedDescription)"
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

// MARK: - Pain digit circles (half-step feedback)

private enum PainHalfStepFeedback {
    private static let impact = UIImpactFeedbackGenerator(style: .medium)

    static func pulse() {
        impact.prepare()
        impact.impactOccurred(intensity: 1)
    }
}

private struct PainDigitCircle: View {
    /// 20% of a second — snappy half-step gesture.
    private static let halfStepLongPressSeconds: Double = 0.2

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
                "Tap for whole step, or hold \(String(format: "%.1f", Self.halfStepLongPressSeconds)) seconds for half step."
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
        LongPressGesture(minimumDuration: Self.halfStepLongPressSeconds, maximumDistance: 24)
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
