import AppKit
import Foundation

/// Plays audio when **current five-minute slot** totals meet `HandTrackRecordingAlarmConfig`,
/// unless the user muted alarms from the main window.
@MainActor
enum MacRecordingAlarmFeedback {

    static func afterKeystrokeRecorded(on store: HandTrackStore, userMutedAlarms: Bool) {
        guard !userMutedAlarms else { return }
        guard HandTrackRecordingAlarmConfig.isGloballyEnabled && HandTrackRecordingAlarmConfig.keystrokesAlarmEnabled else { return }
        if store.keysInCurrentFiveMinuteSlot() >= HandTrackRecordingAlarmConfig.keystrokesPerFiveMinuteThreshold {
            playConfiguredDing()
        }
    }

    static func afterMouseClickRecorded(on store: HandTrackStore, userMutedAlarms: Bool) {
        guard !userMutedAlarms else { return }
        guard HandTrackRecordingAlarmConfig.isGloballyEnabled && HandTrackRecordingAlarmConfig.mouseClicksAlarmEnabled else { return }
        if store.clicksInCurrentFiveMinuteSlot() >= HandTrackRecordingAlarmConfig.mouseClicksPerFiveMinuteThreshold {
            playConfiguredDing()
        }
    }

    /// `batchPixels` must be `> 0` so idle periods stay silent between flushes.
    static func afterPointerTravelBatchRecorded(on store: HandTrackStore, batchPixels: Double, userMutedAlarms: Bool) {
        guard batchPixels > 0 else { return }
        guard !userMutedAlarms else { return }
        guard HandTrackRecordingAlarmConfig.isGloballyEnabled && HandTrackRecordingAlarmConfig.pointerTravelAlarmEnabled else { return }
        if store.mouseTravelPixelsInCurrentFiveMinuteSlot()
            >= HandTrackRecordingAlarmConfig.pointerTravelPixelsPerFiveMinuteThreshold
        {
            playConfiguredDing()
        }
    }

    private static func playConfiguredDing() {
        let name = NSSound.Name(HandTrackRecordingAlarmConfig.systemSoundName)
        if let sound = NSSound(named: name) {
            let clamped = max(0, min(HandTrackRecordingAlarmConfig.dingPlaybackVolume, 1))
            sound.volume = clamped
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
