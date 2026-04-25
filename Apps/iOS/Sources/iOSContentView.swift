import SwiftUI

struct iOSContentView: View {
    @EnvironmentObject private var store: HandTrackStore
    @AppStorage("macSyncHost") private var macSyncHost = ""
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
                    Button("Enable Hourly Reminder") {
                        Task {
                            await enableReminder()
                        }
                    }
                    Text("iOS cannot auto-open the app from the lock screen. The reminder opens HandTrack when you tap it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .navigationTitle("HandTrack")
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
            try await HourlyReminderManager.requestPermissionAndSchedule()
            statusMessage = "Hourly reminder scheduled"
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
