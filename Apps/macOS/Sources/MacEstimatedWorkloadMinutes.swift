import Foundation

/// Estimated minutes from the Average‑minute comfort settings (12‑hour chart slider).
///
/// Uncapped, linear:
/// `keys/kpm + clicks/cpm + pixels/ppm + scrolls/spm`
enum MacEstimatedWorkloadMinutes {
    static let keysPerMinuteKey = "HandTrack.mac.twelveHourAvgKeysPerMinute"
    static let clicksPerMinuteKey = "HandTrack.mac.twelveHourAvgClicksPerMinute"
    static let pixelThousandsPerMinuteKey = "HandTrack.mac.twelveHourAvgPixelThousandsPerMinute"
    static let scrollsPerMinuteKey = "HandTrack.mac.twelveHourAvgScrollsPerMinute"
    /// One-time bump away from the old bar-calibration defaults (15 / 5 / 7).
    private static let defaultsMigrationKey = "HandTrack.mac.comfortRatesMigratedFromBarDefaultsV1"

    static let defaultKeysPerMinute = 120
    static let defaultClicksPerMinute = 20
    static let defaultPixelThousandsPerMinute = 15
    /// Active scrolling ~one wheel notch every 1.5s.
    static let defaultScrollsPerMinute = 40

    struct Rates: Equatable {
        var keysPerMinute: Double
        var clicksPerMinute: Double
        var pixelsPerMinute: Double
        var scrollsPerMinute: Double

        static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> Rates {
            migrateLegacyBarDefaultsIfNeeded(defaults)
            let keys = defaults.object(forKey: keysPerMinuteKey) as? Int ?? defaultKeysPerMinute
            let clicks = defaults.object(forKey: clicksPerMinuteKey) as? Int ?? defaultClicksPerMinute
            let thousands = defaults.object(forKey: pixelThousandsPerMinuteKey) as? Int
                ?? defaultPixelThousandsPerMinute
            let scrolls = defaults.object(forKey: scrollsPerMinuteKey) as? Int ?? defaultScrollsPerMinute
            return from(
                keysPerMinute: keys,
                clicksPerMinute: clicks,
                pixelThousandsPerMinute: thousands,
                scrollsPerMinute: scrolls
            )
        }

        static func from(
            keysPerMinute: Int,
            clicksPerMinute: Int,
            pixelThousandsPerMinute: Int,
            scrollsPerMinute: Int = defaultScrollsPerMinute
        ) -> Rates {
            let rawKeys = max(0, keysPerMinute)
            let kpm = Double((rawKeys / 5) * 5)
            let cpm = Double(max(0, clicksPerMinute))
            let ppm = Double(max(1, pixelThousandsPerMinute)) * 1000
            let spm = Double(max(0, scrollsPerMinute))
            return Rates(
                keysPerMinute: kpm > 1e-9 ? kpm : Double(defaultKeysPerMinute),
                clicksPerMinute: cpm > 1e-9 ? cpm : Double(defaultClicksPerMinute),
                pixelsPerMinute: ppm > 1e-9 ? ppm : Double(defaultPixelThousandsPerMinute) * 1000,
                scrollsPerMinute: spm > 1e-9 ? spm : Double(defaultScrollsPerMinute)
            )
        }
    }

    private static func migrateLegacyBarDefaultsIfNeeded(_ defaults: UserDefaults) {
        guard defaults.object(forKey: defaultsMigrationKey) == nil else { return }
        let keys = defaults.object(forKey: keysPerMinuteKey) as? Int
        let clicks = defaults.object(forKey: clicksPerMinuteKey) as? Int
        let thousands = defaults.object(forKey: pixelThousandsPerMinuteKey) as? Int
        if keys == 15, clicks == 5, thousands == 7 {
            defaults.set(defaultKeysPerMinute, forKey: keysPerMinuteKey)
            defaults.set(defaultClicksPerMinute, forKey: clicksPerMinuteKey)
            defaults.set(defaultPixelThousandsPerMinute, forKey: pixelThousandsPerMinuteKey)
        }
        if defaults.object(forKey: scrollsPerMinuteKey) == nil {
            defaults.set(defaultScrollsPerMinute, forKey: scrollsPerMinuteKey)
        }
        defaults.set(true, forKey: defaultsMigrationKey)
    }

    static func keyboardMinutes(keystrokes: Int, rates: Rates) -> Int {
        minutes(amount: Double(max(0, keystrokes)), perMinute: rates.keysPerMinute)
    }

    static func mouseMinutes(
        clicks: Int,
        travelPixels: Double,
        scrollBumps: Int = 0,
        rates: Rates
    ) -> Int {
        minutes(amount: Double(max(0, clicks)), perMinute: rates.clicksPerMinute)
            + minutes(amount: max(0, travelPixels), perMinute: rates.pixelsPerMinute)
            + minutes(amount: Double(max(0, scrollBumps)), perMinute: rates.scrollsPerMinute)
    }

    static func totalMinutes(
        keystrokes: Int,
        clicks: Int,
        travelPixels: Double,
        scrollBumps: Int = 0,
        rates: Rates
    ) -> Int {
        keyboardMinutes(keystrokes: keystrokes, rates: rates)
            + mouseMinutes(
                clicks: clicks,
                travelPixels: travelPixels,
                scrollBumps: scrollBumps,
                rates: rates
            )
    }

    static func columnBreakdown(
        keystrokes: Int,
        clicks: Int,
        travelPixels: Double,
        scrollBumps: Int = 0,
        rates: Rates
    ) -> (keyboard: Int, mouse: Int) {
        (
            keyboardMinutes(keystrokes: keystrokes, rates: rates),
            mouseMinutes(
                clicks: clicks,
                travelPixels: travelPixels,
                scrollBumps: scrollBumps,
                rates: rates
            )
        )
    }

    static func compactDurationLabel(totalMinutes: Int) -> String {
        let clamped = max(0, totalMinutes)
        guard clamped > 0 else { return "" }
        let h = clamped / 60
        let m = clamped % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    private static func minutes(amount: Double, perMinute: Double) -> Int {
        guard amount.isFinite, amount > 0, perMinute.isFinite, perMinute > 1e-9 else { return 0 }
        return Int((amount / perMinute).rounded(.toNearestOrAwayFromZero))
    }
}
