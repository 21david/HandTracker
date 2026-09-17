import SwiftUI

/// Lists every detected keyboard. Rename externals with the pencil.
/// A row flashing on a keystroke is the same device id just written into tracking.
struct MacExternalKeyboardsSettingsPopover: View {
    @ObservedObject var store: HandTrackStore
    let livePulse: HandTrackLivePulse

    @State private var editingID: String?
    @State private var draftName = ""
    @State private var flashingIDs: Set<String> = []
    @State private var lastSeenTickID: UInt64 = 0
    @State private var flashTasks: [String: Task<Void, Never>] = [:]
    @FocusState private var focusedField: String?

    private var profiles: [ExternalKeyboardProfile] {
        [ExternalKeyboardProfile(identity: .macbookBuiltin, at: .distantPast)]
            + store.allExternalKeyboardProfiles()
    }

    var body: some View {
        let _ = livePulse.externalKeyboardDebugTickID
        VStack(alignment: .leading, spacing: 12) {
            Text("Detected keyboards")
                .font(.headline)
            Text(
                "MacBook plus every external keyboard HandTrack has recorded. " +
                "A row lighting up is the keyboard just counted in tracking."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            keyboardList
        }
        .padding(14)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            HandTrackLivePulse.keyboardSettingsActive = true
            lastSeenTickID = livePulse.externalKeyboardDebugTickID
            editingID = nil
            focusedField = nil
        }
        .onDisappear {
            HandTrackLivePulse.keyboardSettingsActive = false
            for task in flashTasks.values { task.cancel() }
            flashTasks.removeAll()
            focusedField = nil
            editingID = nil
        }
        .onChange(of: livePulse.externalKeyboardDebugTickID) { _, newID in
            guard newID != lastSeenTickID,
                  let tick = livePulse.lastExternalKeyboardDebugTick,
                  tick.id == newID
            else { return }
            lastSeenTickID = newID
            flash(tick.keyboardId)
        }
    }

    @ViewBuilder
    private var keyboardList: some View {
        let rows = VStack(alignment: .leading, spacing: 8) {
            ForEach(profiles) { profile in
                keyboardRow(profile)
            }
        }
        if profiles.count > 7 {
            ScrollView {
                rows
            }
            .frame(maxHeight: 520)
        } else {
            rows
        }
    }

    private func keyboardRow(_ profile: ExternalKeyboardProfile) -> some View {
        let flashing = flashingIDs.contains(profile.id)
        let editing = editingID == profile.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                if editing {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: profile.id)
                        .onSubmit { commit(profile.id) }
                    Button("Save") { commit(profile.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Cancel") { cancelEdit() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                } else {
                    Text(profile.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if profile.id != ExternalKeyboardIdentity.macbookBuiltin.id {
                        Button {
                            beginEdit(profile)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rename this keyboard")
                    }
                }
            }
            Text(hardwareCaption(profile))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(flashing
                    ? Color.accentColor.opacity(0.28)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(flashing ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: flashing ? 2 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: flashing)
    }

    private func hardwareCaption(_ profile: ExternalKeyboardProfile) -> String {
        if profile.id == ExternalKeyboardIdentity.macbookBuiltin.id {
            return "Built-in"
        }
        var parts: [String] = []
        if !profile.manufacturer.isEmpty { parts.append(profile.manufacturer) }
        if !profile.product.isEmpty { parts.append(profile.product) }
        if profile.vendorID > 0, profile.productID > 0 {
            parts.append(String(format: "VID %04X PID %04X", profile.vendorID, profile.productID))
        }
        if parts.isEmpty { return profile.id }
        return parts.joined(separator: " · ")
    }

    private func beginEdit(_ profile: ExternalKeyboardProfile) {
        editingID = profile.id
        draftName = profile.displayName
        DispatchQueue.main.async {
            focusedField = profile.id
        }
    }

    private func cancelEdit() {
        focusedField = nil
        editingID = nil
        draftName = ""
    }

    private func commit(_ id: String) {
        guard id != ExternalKeyboardIdentity.macbookBuiltin.id else {
            cancelEdit()
            return
        }
        store.setExternalKeyboardCustomName(id: id, name: draftName)
        cancelEdit()
    }

    private func flash(_ id: String) {
        flashingIDs.insert(id)
        flashTasks[id]?.cancel()
        flashTasks[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            flashingIDs.remove(id)
            flashTasks[id] = nil
        }
    }
}
