import SwiftUI
import AppKit

struct MacKeyboardsAnchorCatcher: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView) }
    }
}

@MainActor
final class MacKeyboardsSettingsPresenter: NSObject, NSPopoverDelegate {
    static let shared = MacKeyboardsSettingsPresenter()

    private var popover: NSPopover?
    private var dismissedAt: Date?

    func toggle(
        relativeTo anchor: NSView?,
        store: HandTrackStore,
        livePulse: HandTrackLivePulse,
        keyboardLimits: MacKeyboardLimitController
    ) {
        if let popover, popover.isShown {
            dismiss()
            return
        }
        if let dismissedAt, Date().timeIntervalSince(dismissedAt) < 0.3 {
            return
        }
        guard let anchor, anchor.window != nil else {
            return
        }
        show(relativeTo: anchor, store: store, livePulse: livePulse, keyboardLimits: keyboardLimits)
    }

    private func show(
        relativeTo anchor: NSView,
        store: HandTrackStore,
        livePulse: HandTrackLivePulse,
        keyboardLimits: MacKeyboardLimitController
    ) {
        let root = MacExternalKeyboardsSettingsPopover(
            store: store,
            livePulse: livePulse,
            keyboardLimits: keyboardLimits
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = hosting
        let rect = anchor.bounds.width > 1 ? anchor.bounds : (anchor.superview?.bounds ?? anchor.bounds)
        let positioning = anchor.bounds.width > 1 ? anchor : (anchor.superview ?? anchor)
        popover.show(relativeTo: rect, of: positioning, preferredEdge: .minY)
        self.popover = popover
        DispatchQueue.main.async {
            if let panel = hosting.view.window as? NSPanel {
                panel.becomesKeyOnlyIfNeeded = true
                panel.makeFirstResponder(nil)
            }
        }
    }

    func dismiss() {
        dismissedAt = Date()
        popover?.performClose(nil)
        popover = nil
        HandTrackLivePulse.keyboardSettingsActive = false
    }

    func popoverDidClose(_ notification: Notification) {
        dismissedAt = Date()
        popover = nil
        HandTrackLivePulse.keyboardSettingsActive = false
    }
}

/// Lists every detected keyboard. Rename externals with the pencil.
/// A row flashing on a keystroke is the same device id just written into tracking.
struct MacExternalKeyboardsSettingsPopover: View {
    @ObservedObject var store: HandTrackStore
    let livePulse: HandTrackLivePulse
    @ObservedObject var keyboardLimits: MacKeyboardLimitController

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
                "A row lighting up is the keyboard just counted in tracking. " +
                "Optional limits beep on each key of that board until the window resets."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            keyboardList
        }
        .padding(14)
        .frame(width: 480)
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
            .frame(maxHeight: 640)
        } else {
            rows
        }
    }

    private func keyboardRow(_ profile: ExternalKeyboardProfile) -> some View {
        let flashing = flashingIDs.contains(profile.id)
        let editing = editingID == profile.id
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
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

            KeyboardLimitEditor(keyboardId: profile.id, keyboardLimits: keyboardLimits)
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

private struct KeyboardLimitEditor: View {
    let keyboardId: String
    @ObservedObject var keyboardLimits: MacKeyboardLimitController
    @State private var thresholdText = ""

    var body: some View {
        let rule = keyboardLimits.rule(for: keyboardId)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Limit", isOn: enabledBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, weight: .semibold))
                Picker("Window", selection: windowBinding) {
                    ForEach(KeyboardLimitWindowHours.allCases) { window in
                        Text(window.menuTitle).tag(window.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 108)
                .disabled(!rule.enabled)
                TextField("Amount", text: $thresholdText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .disabled(!rule.enabled)
                    .onSubmit { commitThreshold(from: thresholdText) }
                Picker("Unit", selection: unitBinding) {
                    ForEach(KeyboardLimitUnit.allCases) { unit in
                        Text(unit.menuTitle).tag(unit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 108)
                .disabled(!rule.enabled)
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            if rule.enabled {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let status = keyboardLimits.status(for: keyboardId, at: timeline.date)
                    VStack(alignment: .leading, spacing: 2) {
                        if let status {
                            Text(status.usageCaption)
                                .font(.system(size: 11, weight: status.isOver ? .semibold : .regular))
                                .foregroundStyle(status.isOver ? Color.orange : Color.secondary)
                            if let resetCaption = status.resetCaption {
                                Text(resetCaption)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.orange)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            thresholdText = String(rule.threshold)
        }
        .onDisappear {
            if keyboardLimits.rule(for: keyboardId).enabled {
                commitThreshold(from: thresholdText)
            }
        }
        .onChange(of: rule.threshold) { _, value in
            let rendered = String(value)
            if thresholdText != rendered, Int(thresholdText) != value {
                thresholdText = rendered
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { keyboardLimits.rule(for: keyboardId).enabled },
            set: { value in
                if !value {
                    commitThreshold(from: thresholdText)
                }
                var rule = keyboardLimits.rule(for: keyboardId)
                rule.enabled = value
                keyboardLimits.setRule(rule, for: keyboardId)
            }
        )
    }

    private var windowBinding: Binding<Int> {
        Binding(
            get: { keyboardLimits.rule(for: keyboardId).resolvedWindowHours },
            set: { value in
                var rule = keyboardLimits.rule(for: keyboardId)
                rule.windowHours = value
                keyboardLimits.setRule(rule, for: keyboardId)
            }
        )
    }

    private var unitBinding: Binding<KeyboardLimitUnit> {
        Binding(
            get: { keyboardLimits.rule(for: keyboardId).unit },
            set: { value in
                var rule = keyboardLimits.rule(for: keyboardId)
                if rule.unit != value {
                    rule.unit = value
                    rule.threshold = value == .minutes ? 30 : 2000
                }
                keyboardLimits.setRule(rule, for: keyboardId)
            }
        )
    }

    private func commitThreshold(from raw: String) {
        let current = keyboardLimits.rule(for: keyboardId)
        let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? current.threshold
        let clamped = min(max(parsed, 1), 1_000_000)
        if clamped != current.threshold {
            var next = current
            next.threshold = clamped
            keyboardLimits.setRule(next, for: keyboardId)
        }
        thresholdText = String(clamped)
    }
}
