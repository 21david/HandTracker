import SwiftUI

/// Edits the Activity Limits feature: per-activity threshold + window + break + extension seconds.
/// Edits are held in a local draft and only written to `UserDefaults` when the user taps Done,
/// so partial text-field values cannot trip the live limit/timer mid-edit.
struct MacActivityLimitsPopover: View {
    @Environment(\.dismiss) private var dismiss

    /// Working copy loaded on appear; discarded if the popover closes without Done.
    @State private var draft = HandTrackActivityLimitsSnapshot.loadFromUserDefaults()

    let onChange: () -> Void

    /// Pointer travel is stored as raw pixels but presented to the user in thousands so the input
    /// stays a manageable 3-digit number (e.g. 500 means 500,000 px).
    private var travelThresholdKThousands: Binding<Int> {
        Binding(
            get: { max(1, Int(draft.travel.threshold.rounded()) / 1000) },
            set: { draft.travel.threshold = Double(max(1, $0) * 1000) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enable activity limits", isOn: $draft.masterEnabled)
                .toggleStyle(.switch)
                .font(.headline)

            Text(
                "When the limit is reached in the rolling window, a break begins. " +
                "During the break each event plays the alarm sound and adds the " +
                "extension seconds to that activity's remaining time."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            activitySection(
                title: "Keystrokes",
                enabled: $draft.keys.enabled,
                threshold: intThresholdBinding(\.keys),
                thresholdRange: 1...100_000,
                thresholdStep: 50,
                thresholdUnit: "keys",
                window: intBinding(\.keys, \.windowMinutes),
                breakMinutes: intBinding(\.keys, \.breakMinutes),
                extensionSeconds: intBinding(\.keys, \.extensionSeconds)
            )

            activitySection(
                title: "Mouse clicks",
                enabled: $draft.clicks.enabled,
                threshold: intThresholdBinding(\.clicks),
                thresholdRange: 1...50_000,
                thresholdStep: 10,
                thresholdUnit: "clicks",
                window: intBinding(\.clicks, \.windowMinutes),
                breakMinutes: intBinding(\.clicks, \.breakMinutes),
                extensionSeconds: intBinding(\.clicks, \.extensionSeconds)
            )

            activitySection(
                title: "Pointer travel",
                enabled: $draft.travel.enabled,
                threshold: travelThresholdKThousands,
                thresholdRange: 1...100_000,
                thresholdStep: 10,
                thresholdUnit: "thousand px",
                window: intBinding(\.travel, \.windowMinutes),
                breakMinutes: intBinding(\.travel, \.breakMinutes),
                extensionSeconds: intBinding(\.travel, \.extensionSeconds)
            )

            HStack {
                Spacer(minLength: 0)
                Button("Done") {
                    commitAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 520)
        .onAppear {
            draft = HandTrackActivityLimitsSnapshot.loadFromUserDefaults()
        }
    }

    private func commitAndDismiss() {
        draft.saveToUserDefaults()
        onChange()
        dismiss()
    }

    private func intThresholdBinding(
        _ activity: WritableKeyPath<HandTrackActivityLimitsSnapshot, HandTrackActivityLimitsSnapshot.PerActivity>
    ) -> Binding<Int> {
        Binding(
            get: { Int(draft[keyPath: activity].threshold.rounded()) },
            set: { newValue in
                var copy = draft[keyPath: activity]
                copy.threshold = Double(newValue)
                draft[keyPath: activity] = copy
            }
        )
    }

    private func intBinding(
        _ activity: WritableKeyPath<HandTrackActivityLimitsSnapshot, HandTrackActivityLimitsSnapshot.PerActivity>,
        _ field: WritableKeyPath<HandTrackActivityLimitsSnapshot.PerActivity, Int>
    ) -> Binding<Int> {
        Binding(
            get: { draft[keyPath: activity][keyPath: field] },
            set: { newValue in
                var copy = draft[keyPath: activity]
                copy[keyPath: field] = newValue
                draft[keyPath: activity] = copy
            }
        )
    }

    @ViewBuilder
    private func activitySection(
        title: String,
        enabled: Binding<Bool>,
        threshold: Binding<Int>,
        thresholdRange: ClosedRange<Int>,
        thresholdStep: Int,
        thresholdUnit: String,
        window: Binding<Int>,
        breakMinutes: Binding<Int>,
        extensionSeconds: Binding<Int>
    ) -> some View {
        let sectionDisabled = !enabled.wrappedValue || !draft.masterEnabled

        VStack(alignment: .leading, spacing: 10) {
            Toggle(title, isOn: enabled)
                .toggleStyle(.checkbox)
                .font(.subheadline.weight(.semibold))

            settingRow(label: "Limit", trailingUnit: thresholdUnit) {
                editableIntField(
                    value: threshold,
                    range: thresholdRange,
                    step: thresholdStep,
                    disabled: sectionDisabled
                )
            }

            settingRow(label: "Window", trailingUnit: "minutes") {
                editableIntField(
                    value: window,
                    range: 1...240,
                    step: 1,
                    disabled: sectionDisabled
                )
            }

            settingRow(label: "Break", trailingUnit: "minutes") {
                editableIntField(
                    value: breakMinutes,
                    range: 1...60,
                    step: 1,
                    disabled: sectionDisabled
                )
            }

            settingRow(label: "Each event adds", trailingUnit: "seconds") {
                editableIntField(
                    value: extensionSeconds,
                    range: 0...120,
                    step: 1,
                    disabled: sectionDisabled
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .opacity(sectionDisabled ? 0.55 : 1)
    }

    @ViewBuilder
    private func editableIntField(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        disabled: Bool
    ) -> some View {
        HStack(spacing: 6) {
            TextField(
                "",
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                        value.wrappedValue = clamped
                    }
                ),
                format: .number.grouping(.automatic)
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 90)
            .disabled(disabled)

            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .disabled(disabled)
        }
    }

    private func settingRow<Content: View>(
        label: String,
        trailingUnit: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout)
                .frame(width: 124, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
            Text(trailingUnit)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
