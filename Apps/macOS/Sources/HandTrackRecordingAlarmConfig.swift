import Foundation

/// **Edit thresholds here** — alarms use totals in the **current five-minute calendar slot**
/// (:00–:05, :05–:10, …), same window as the rightmost histogram bar.
///
/// When a metric is **≥** its threshold inside that slot, each further key / click / movement batch
/// can play sound (unless muted in the app header). Thresholds reset when the clock rolls into the next slot.
enum HandTrackRecordingAlarmConfig {

    // MARK: - Developer / quick disable

    /// Master switch compiled into the app — turn off builds without ripping out callers.
    static var isGloballyEnabled: Bool = true

    /// `NSSound(named:)` base name (`/System/Library/Sounds`).
    static var systemSoundName: String = "Tink"

    /// NSSound playback level `0 … 1` (relative to system output). Main volume still applies system-wide.
    static var dingPlaybackVolume: Float = 0.35

    // MARK: - Keystrokes

    static var keystrokesAlarmEnabled: Bool = true
    /// Keys summed in the **current five-minute** window; default matches keystroke chart Y cap.
    static var keystrokesPerFiveMinuteThreshold: Int = 275

    // MARK: - Mouse clicks

    static var mouseClicksAlarmEnabled: Bool = true
    /// Matches mouse-click histogram Y cap by default.
    static var mouseClicksPerFiveMinuteThreshold: Int = 120

    // MARK: - Pointer travel

    static var pointerTravelAlarmEnabled: Bool = true
    /// Points/pixels in the **current five-minute** window; matches pointer travel chart Y cap by default.
    static var pointerTravelPixelsPerFiveMinuteThreshold: Double = 125_000
}
