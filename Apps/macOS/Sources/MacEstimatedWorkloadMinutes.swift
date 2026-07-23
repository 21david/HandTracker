import Foundation

/// Estimated minutes from the Average‑minute comfort settings (12‑hour chart slider).
///
/// Uncapped, linear:
/// `keys/keysPerMin + clicks/clicksPerMin + pixels/pxPerMin`
enum MacEstimatedWorkloadMinutes {
    static let keysPerMinuteKey = "HandTrack.mac.twelveHourAvgKeysPerMinute"
    static let clicksPerMinuteKey = "HandTrack.mac.twelveHourAvgClicksPerMinute"
    static let pixelThousandsPerMinuteKey = "HandTrack.mac.twelveHourAvgPixelThousandsPerMinute"
    /// One-time bump away from the old bar-calibration defaults (15 / 5 / 7).
    private static let defaultsMigrationKey = "HandTrack.mac.comfortRatesMigratedFromBarDefaultsV1"

    /// Mixed active computer work (not peak burst typing).
    /// ~40 WPM continuous ≈ 200 keys/min; ~100–120 blends typing with reading/thinking.
    static let defaultKeysPerMinute = 120
    /// ~5–7K clicks/workday ≈ 10–15/min averaged; ~20 for active mouse minutes.
    static let defaultClicksPerMinute = 20
    /// Thousands of pointer pixels per active minute (less published; calibrated to typical desk use).
    static let defaultPixelThousandsPerMinute = 15

    struct Rates: Equatable {
        var keysPerMinute: Double
        var clicksPerMinute: Double
        var pixelsPerMinute: Double

        static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> Rates {
            migrateLegacyBarDefaultsIfNeeded(defaults)
            let keys = defaults.object(forKey: keysPerMinuteKey) as? Int ?? defaultKeysPerMinute
            let clicks = defaults.object(forKey: clicksPerMinuteKey) as? Int ?? defaultClicksPerMinute
            let thousands = defaults.object(forKey: pixelThousandsPerMinuteKey) as? Int
                ?? defaultPixelThousandsPerMinute
            return from(
                keysPerMinute: keys,
                clicksPerMinute: clicks,
                pixelThousandsPerMinute: thousands
            )
        }

        static func from(
            keysPerMinute: Int,
            clicksPerMinute: Int,
            pixelThousandsPerMinute: Int
        ) -> Rates {
            let rawKeys = max(0, keysPerMinute)
            let kpm = Double((rawKeys / 5) * 5)
            let cpm = Double(max(0, clicksPerMinute))
            let ppm = Double(max(1, pixelThousandsPerMinute)) * 1000
            return Rates(
                keysPerMinute: kpm > 1e-9 ? kpm : Double(defaultKeysPerMinute),
                clicksPerMinute: cpm > 1e-9 ? cpm : Double(defaultClicksPerMinute),
                pixelsPerMinute: ppm > 1e-9 ? ppm : Double(defaultPixelThousandsPerMinute) * 1000
            )
        }
    }

    /// Old 15/5/7 values were for stacked **bar height**, not realistic throughput — replace once.
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
        defaults.set(true, forKey: defaultsMigrationKey)
    }

    static func keyboardMinutes(keystrokes: Int, rates: Rates) -> Int {
        minutes(amount: Double(max(0, keystrokes)), perMinute: rates.keysPerMinute)
    }

    static func mouseMinutes(clicks: Int, travelPixels: Double, rates: Rates) -> Int {
        minutes(amount: Double(max(0, clicks)), perMinute: rates.clicksPerMinute)
            + minutes(amount: max(0, travelPixels), perMinute: rates.pixelsPerMinute)
    }

    static func totalMinutes(
        keystrokes: Int,
        clicks: Int,
        travelPixels: Double,
        rates: Rates
    ) -> Int {
        keyboardMinutes(keystrokes: keystrokes, rates: rates)
            + mouseMinutes(clicks: clicks, travelPixels: travelPixels, rates: rates)
    }

    static func columnBreakdown(
        keystrokes: Int,
        clicks: Int,
        travelPixels: Double,
        rates: Rates
    ) -> (keyboard: Int, mouse: Int) {
        (
            keyboardMinutes(keystrokes: keystrokes, rates: rates),
            mouseMinutes(clicks: clicks, travelPixels: travelPixels, rates: rates)
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
