import AppKit
import Foundation

/// Plays audio when calendar-hour totals stay at or above thresholds in `HandTrackRecordingAlarmConfig`.
@MainActor
enum MacRecordingAlarmFeedback {

    static func afterKeystrokeRecorded(on store: HandTrackStore) {
        guard HandTrackRecordingAlarmConfig.isGloballyEnabled && HandTrackRecordingAlarmConfig.keystrokesAlarmEnabled else { return }
        if store.keysSinceStartOfCurrentHour() >= HandTrackRecordingAlarmConfig.keystrokesPerHourThreshold {
            playConfiguredDing()
        }
    }

    static func afterMouseClickRecorded(on store: HandTrackStore) {
        guard HandTrackRecordingAlarmConfig.isGloballyEnabled && HandTrackRecordingAlarmConfig.mouseClicksAlarmEnabled else { return }
        if store.clicksSinceStartOfCurrentHour() >= HandTrackRecordingAlarmConfig.mouseClicksPerHourThreshold {
            playConfiguredDing()
        }
    }

    /// Called after travel is written; `batchPixels` must be `> 0` so silent periods do not ding.
    static func afterPointerTravelBatchRecorded(on store: HandTrackStore, batchPixels: Double) {
        guard batchPixels > 0 else { return }
        guard HandTrackRecordingAlarmConfig.isGloballyEnabled && HandTrackRecordingAlarmConfig.pointerTravelAlarmEnabled else { return }
        if store.mouseTravelPixelsSinceStartOfCurrentHour() >= HandTrackRecordingAlarmConfig.pointerTravelPixelsPerHourThreshold {
            playConfiguredDing()
        }
    }

    private static func playConfiguredDing() {
        let name = NSSound.Name(HandTrackRecordingAlarmConfig.systemSoundName)
        if let sound = NSSound(named: name) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
