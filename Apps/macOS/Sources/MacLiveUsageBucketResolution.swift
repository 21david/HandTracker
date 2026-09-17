import SwiftUI

/// Shared bucket size for the live keystroke / click / travel charts. Always shows **one hour**.
enum MacLiveUsageBucketResolution: String, CaseIterable, Identifiable {
    case fiveMinutes
    case oneMinute

    var id: String { rawValue }

    static let storageKey = "HandTrack.mac.liveUsageBucketResolution"

    /// Bars across one hour.
    var barCount: Int {
        switch self {
        case .fiveMinutes: return 12
        case .oneMinute: return 60
        }
    }

    var minutesPerBar: Int {
        switch self {
        case .fiveMinutes: return 5
        case .oneMinute: return 1
        }
    }

    var shortLabel: String {
        switch self {
        case .fiveMinutes: return "5 min"
        case .oneMinute: return "1 min"
        }
    }

    /// Scale five-minute visual caps down for one-minute bars.
    func scaledCap(fiveMinuteCap: Double) -> Double {
        fiveMinuteCap * Double(minutesPerBar) / 5.0
    }

    func scaledExcess(fiveMinuteExcess: Double) -> Double {
        fiveMinuteExcess * Double(minutesPerBar) / 5.0
    }
}

struct MacLiveUsageBucketResolutionPicker: View {
    @Binding var resolution: MacLiveUsageBucketResolution

    var body: some View {
        Picker("Bucket", selection: $resolution) {
            ForEach(MacLiveUsageBucketResolution.allCases) { mode in
                Text(mode.shortLabel).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 160)
        .labelsHidden()
        .help("Bar width: always one hour of history")
    }
}

/// Which live five‑minute chart family is shown on the dashboard.
enum MacLiveGraphDeviceSource: String, CaseIterable, Identifiable {
    case external
    case macbook

    var id: String { rawValue }

    static let storageKey = "HandTrack.mac.liveGraphDeviceSource"

    var shortLabel: String {
        switch self {
        case .external: return "External"
        case .macbook: return "MacBook"
        }
    }
}

struct MacLiveGraphDeviceSourcePicker: View {
    @Binding var source: MacLiveGraphDeviceSource

    var body: some View {
        Picker("Device", selection: $source) {
            ForEach(MacLiveGraphDeviceSource.allCases) { mode in
                Text(mode.shortLabel).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 180)
        .labelsHidden()
        .help("Show external mouse/keyboard charts or MacBook built‑in charts")
    }
}
