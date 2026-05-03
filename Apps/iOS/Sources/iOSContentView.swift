import SwiftUI

struct iOSContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @AppStorage("macSyncHost") private var macSyncHost = ""
    @AppStorage("hourlyReminderQuietStop") private var quietStopRaw: Int =
        HourlyReminderManager.QuietStopChoice.elevenPM.rawValue
    @FocusState private var focusedField: Field?

    @State private var painLevel = 0
    @State private var minutesHandsUsed = 0
    @State private var journalEntry = ""
    @State private var statusMessage = "Ready"
    @State private var isSyncing = false

    private enum Field {
        case journal
        case macHost
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current Hour") {
                    HStack {
                        Text("Hour")
                        Spacer()
                        Text(Date().startOfHour.displayHour)
                            .foregroundStyle(.secondary)
                    }

                    Stepper("Pain level: \(painLevel)", value: $painLevel, in: 0...10)
                    Stepper("Hands used: \(minutesHandsUsed) min", value: $minutesHandsUsed, in: 0...60)

                    TextEditor(text: $journalEntry)
                        .focused($focusedField, equals: .journal)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if journalEntry.isEmpty {
                                Text("Journal entry")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                            }
                        }

                    Button("Save Current Hour Log") {
                        focusedField = nil
                        saveLog()
                    }
                    .disabled(journalEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Hourly Reminder") {
                    Text(
                        "Alerts begin at the start of the next hour—for example, enabling at 1:49 p.m. waits until 2:00 p.m., then repeats every clock hour."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stop for the night")
                            .font(.subheadline.weight(.semibold))
                        Text("No hourly alerts from that time until \(HourlyReminderManager.morningResumeHour):00.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(HourlyReminderManager.QuietStopChoice.allCases) { choice in
                                eveningStopChip(choice)
                            }
                        }
                    }

                    Text(
                        """
                        Twelve a.m.: late evening pings can still arrive; midnight through morning silence. One a.m.: \
                        silent starting at 1:00 until \(HourlyReminderManager.morningResumeHour):00 (a midnight ding is still OK). Tap Enable again whenever you tweak these picks.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Button("Enable Hourly Reminder") {
                        Task {
                            await enableReminder()
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
                                Text(log.hourStart.displayHour)
                                    .font(.headline)
                                Text("Pain \(log.painLevel), \(log.minutesHandsUsed) min used, \(log.syncStatus.rawValue)")
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
            .navigationTitle("Hand Helper")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
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
            painLevel: painLevel,
            minutesHandsUsed: minutesHandsUsed,
            journalEntry: journalEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        painLevel = 0
        minutesHandsUsed = 0
        journalEntry = ""
        statusMessage = "Saved this hour's log"
    }

    private func enableReminder() async {
        do {
            let choice = HourlyReminderManager.QuietStopChoice(rawValue: quietStopRaw)
                ?? HourlyReminderManager.QuietStopChoice.elevenPM
            try await HourlyReminderManager.requestPermissionAndSchedule(
                quietChoice: choice,
                wakeHour: HourlyReminderManager.morningResumeHour
            )
            statusMessage = "Hourly reminder scheduled (respects your night stop)."
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
