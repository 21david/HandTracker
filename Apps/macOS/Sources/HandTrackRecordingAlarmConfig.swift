import Foundation

/// **Change thresholds and behavior here** — used by `MacRecordingAlarmFeedback` after each input event.
///
/// Totals are computed for the **current calendar hour**, same as the stat cards.
enum HandTrackRecordingAlarmConfig {

    // MARK: - Master

    /// Turns off all threshold dings without deleting call sites elsewhere.
    static var isGloballyEnabled: Bool = true

    /// `NSSound(named:)` base name (see `/System/Library/Sounds`).
    static var systemSoundName: String = "Tink"

    // MARK: - Keystrokes

    static var keystrokesAlarmEnabled: Bool = true
    /// After this many keys in the **current hour**, **each additional** key plays the sound.
    static var keystrokesPerHourThreshold: Int = 4_000

    // MARK: - Mouse clicks

    static var mouseClicksAlarmEnabled: Bool = true
    static var mouseClicksPerHourThreshold: Int = 800

    // MARK: - Pointer travel

    static var pointerTravelAlarmEnabled: Bool = true
    /// Planar distance in points/pixels for the **current hour** (matches the stat card).
    static var pointerTravelPixelsPerHourThreshold: Double = 500_000
}
