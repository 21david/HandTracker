import SwiftUI

/// Edits the Activity Limits feature: per-activity threshold + window + break + extension seconds.
/// Persisted via `@AppStorage`; consumers refresh `MacActivityLimitController` on dismiss so timers
/// pick up new values immediately.
struct MacActivityLimitsPopover: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(HandTrackActivityLimitsStorage.masterEnabledKey)
    private var masterEnabled = HandTrackActivityLimitsStorage.Defaults.masterEnabled

    @AppStorage(HandTrackActivityLimitsStorage.keysEnabledKey)
    private var keysEnabled = HandTrackActivityLimitsStorage.Defaults.keysEnabled
    @AppStorage(HandTrackActivityLimitsStorage.keysThresholdKey)
    private var keysThreshold = HandTrackActivityLimitsStorage.Defaults.keysThreshold
    @AppStorage(HandTrackActivityLimitsStorage.keysWindowMinutesKey)
    private var keysWindow = HandTrackActivityLimitsStorage.Defaults.keysWindowMinutes
    @AppStorage(HandTrackActivityLimitsStorage.keysBreakMinutesKey)
    private var keysBreak = HandTrackActivityLimitsStorage.Defaults.keysBreakMinutes
    @AppStorage(HandTrackActivityLimitsStorage.keysExtensionSecondsKey)
    private var keysExtension = HandTrackActivityLimitsStorage.Defaults.keysExtensionSeconds

    @AppStorage(HandTrackActivityLimitsStorage.clicksEnabledKey)
    private var clicksEnabled = HandTrackActivityLimitsStorage.Defaults.clicksEnabled
    @AppStorage(HandTrackActivityLimitsStorage.clicksThresholdKey)
    private var clicksThreshold = HandTrackActivityLimitsStorage.Defaults.clicksThreshold
    @AppStorage(HandTrackActivityLimitsStorage.clicksWindowMinutesKey)
    private var clicksWindow = HandTrackActivityLimitsStorage.Defaults.clicksWindowMinutes
    @AppStorage(HandTrackActivityLimitsStorage.clicksBreakMinutesKey)
    private var clicksBreak = HandTrackActivityLimitsStorage.Defaults.clicksBreakMinutes
    @AppStorage(HandTrackActivityLimitsStorage.clicksExtensionSecondsKey)
    private var clicksExtension = HandTrackActivityLimitsStorage.Defaults.clicksExtensionSeconds

    @AppStorage(HandTrackActivityLimitsStorage.travelEnabledKey)
    private var travelEnabled = HandTrackActivityLimitsStorage.Defaults.travelEnabled
    @AppStorage(HandTrackActivityLimitsStorage.travelThresholdKey)
    private var travelThreshold = HandTrackActivityLimitsStorage.Defaults.travelThreshold
    @AppStorage(HandTrackActivityLimitsStorage.travelWindowMinutesKey)
    private var travelWindow = HandTrackActivityLimitsStorage.Defaults.travelWindowMinutes
    @AppStorage(HandTrackActivityLimitsStorage.travelBreakMinutesKey)
    private var travelBreak = HandTrackActivityLimitsStorage.Defaults.travelBreakMinutes
    @AppStorage(HandTrackActivityLimitsStorage.travelExtensionSecondsKey)
    private var travelExtension = HandTrackActivityLimitsStorage.Defaults.travelExtensionSeconds

    let onChange: () -> Void

    /// Pointer travel is stored as raw pixels but presented to the user in thousands so the input
    /// stays a manageable 3-digit number (e.g. 500 means 500,000 px).
    private var travelThresholdKThousands: Binding<Int> {
        Binding(
            get: { max(1, travelThreshold / 1000) },
            set: { travelThreshold = max(1, $0) * 1000 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enable activity limits", isOn: $masterEnabled)
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
                enabled: $keysEnabled,
                threshold: $keysThreshold,
                thresholdRange: 1...100_000,
                thresholdStep: 50,
                thresholdUnit: "keys",
                window: $keysWindow,
                breakMinutes: $keysBreak,
                extensionSeconds: $keysExtension
            )

            activitySection(
                title: "Mouse clicks",
                enabled: $clicksEnabled,
                threshold: $clicksThreshold,
                thresholdRange: 1...50_000,
                thresholdStep: 10,
                thresholdUnit: "clicks",
                window: $clicksWindow,
                breakMinutes: $clicksBreak,
                extensionSeconds: $clicksExtension
            )

            activitySection(
                title: "Pointer travel",
                enabled: $travelEnabled,
                threshold: travelThresholdKThousands,
                thresholdRange: 1...100_000,
                thresholdStep: 10,
                thresholdUnit: "thousand px",
                window: $travelWindow,
                breakMinutes: $travelBreak,
                extensionSeconds: $travelExtension
            )

            HStack {
                Spacer(minLength: 0)
                Button("Done") {
                    onChange()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 520)
        .onDisappear { onChange() }
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
        let sectionDisabled = !enabled.wrappedValue || !masterEnabled

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
