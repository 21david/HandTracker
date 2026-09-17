import Foundation

/// Estimated minutes from the Average‑minute comfort settings (12‑hour chart slider).
///
/// Uncapped, linear:
/// `keys/kpm + clicks/cpm + pixels/ppm + scrolls/spm`
/// plus MacBook trackpad travel/scroll via their own rates.
enum MacEstimatedWorkloadMinutes {
    static let keysPerMinuteKey = "HandTrack.mac.twelveHourAvgKeysPerMinute"
    static let clicksPerMinuteKey = "HandTrack.mac.twelveHourAvgClicksPerMinute"
    static let pixelThousandsPerMinuteKey = "HandTrack.mac.twelveHourAvgPixelThousandsPerMinute"
    static let scrollsPerMinuteKey = "HandTrack.mac.twelveHourAvgScrollsPerMinute"
    static let trackpadTravelPixelThousandsPerMinuteKey =
        "HandTrack.mac.twelveHourAvgTrackpadTravelPixelThousandsPerMinute"
    static let trackpadScrollPixelThousandsPerMinuteKey =
        "HandTrack.mac.twelveHourAvgTrackpadScrollPixelThousandsPerMinute"
    /// One-time bump away from the old bar-calibration defaults (15 / 5 / 7).
    private static let defaultsMigrationKey = "HandTrack.mac.comfortRatesMigratedFromBarDefaultsV1"
    private static let trackpadRatesMigrationKey = "HandTrack.mac.comfortTrackpadRatesSeededV1"

    static let defaultKeysPerMinute = 120
    static let defaultClicksPerMinute = 20
    static let defaultPixelThousandsPerMinute = 15
    /// Active scrolling ~one wheel notch every 1.5s.
    static let defaultScrollsPerMinute = 40
    /// Trackpad pointer travel (thousands of px / min); same ballpark as mouse travel.
    static let defaultTrackpadTravelPixelThousandsPerMinute = 15
    /// Trackpad two-finger scroll travel (thousands of px / min).
    static let defaultTrackpadScrollPixelThousandsPerMinute = 12

    struct Rates: Equatable {
        var keysPerMinute: Double
        var clicksPerMinute: Double
        var pixelsPerMinute: Double
        var scrollsPerMinute: Double
        var trackpadTravelPixelsPerMinute: Double
        var trackpadScrollPixelsPerMinute: Double

        static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> Rates {
            migrateLegacyBarDefaultsIfNeeded(defaults)
            seedTrackpadRatesIfNeeded(defaults)
            let keys = defaults.object(forKey: keysPerMinuteKey) as? Int ?? defaultKeysPerMinute
            let clicks = defaults.object(forKey: clicksPerMinuteKey) as? Int ?? defaultClicksPerMinute
            let thousands = defaults.object(forKey: pixelThousandsPerMinuteKey) as? Int
                ?? defaultPixelThousandsPerMinute
            let scrolls = defaults.object(forKey: scrollsPerMinuteKey) as? Int ?? defaultScrollsPerMinute
            let tpTravelK = defaults.object(forKey: trackpadTravelPixelThousandsPerMinuteKey) as? Int
                ?? defaultTrackpadTravelPixelThousandsPerMinute
            let tpScrollK = defaults.object(forKey: trackpadScrollPixelThousandsPerMinuteKey) as? Int
                ?? defaultTrackpadScrollPixelThousandsPerMinute
            return from(
                keysPerMinute: keys,
                clicksPerMinute: clicks,
                pixelThousandsPerMinute: thousands,
                scrollsPerMinute: scrolls,
                trackpadTravelPixelThousandsPerMinute: tpTravelK,
                trackpadScrollPixelThousandsPerMinute: tpScrollK
            )
        }

        static func from(
            keysPerMinute: Int,
            clicksPerMinute: Int,
            pixelThousandsPerMinute: Int,
            scrollsPerMinute: Int = defaultScrollsPerMinute,
            trackpadTravelPixelThousandsPerMinute: Int = defaultTrackpadTravelPixelThousandsPerMinute,
            trackpadScrollPixelThousandsPerMinute: Int = defaultTrackpadScrollPixelThousandsPerMinute
        ) -> Rates {
            let rawKeys = max(0, keysPerMinute)
            let kpm = Double((rawKeys / 5) * 5)
            let cpm = Double(max(0, clicksPerMinute))
            let ppm = Double(max(1, pixelThousandsPerMinute)) * 1000
            let spm = Double(max(0, scrollsPerMinute))
            let tppm = Double(max(1, trackpadTravelPixelThousandsPerMinute)) * 1000
            let tspm = Double(max(1, trackpadScrollPixelThousandsPerMinute)) * 1000
            return Rates(
                keysPerMinute: kpm > 1e-9 ? kpm : Double(defaultKeysPerMinute),
                clicksPerMinute: cpm > 1e-9 ? cpm : Double(defaultClicksPerMinute),
                pixelsPerMinute: ppm > 1e-9 ? ppm : Double(defaultPixelThousandsPerMinute) * 1000,
                scrollsPerMinute: spm > 1e-9 ? spm : Double(defaultScrollsPerMinute),
                trackpadTravelPixelsPerMinute: tppm > 1e-9
                    ? tppm
                    : Double(defaultTrackpadTravelPixelThousandsPerMinute) * 1000,
                trackpadScrollPixelsPerMinute: tspm > 1e-9
                    ? tspm
                    : Double(defaultTrackpadScrollPixelThousandsPerMinute) * 1000
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

    private static func seedTrackpadRatesIfNeeded(_ defaults: UserDefaults) {
        guard defaults.object(forKey: trackpadRatesMigrationKey) == nil else { return }
        if defaults.object(forKey: trackpadTravelPixelThousandsPerMinuteKey) == nil {
            defaults.set(
                defaultTrackpadTravelPixelThousandsPerMinute,
                forKey: trackpadTravelPixelThousandsPerMinuteKey
            )
        }
        if defaults.object(forKey: trackpadScrollPixelThousandsPerMinuteKey) == nil {
            defaults.set(
                defaultTrackpadScrollPixelThousandsPerMinute,
                forKey: trackpadScrollPixelThousandsPerMinuteKey
            )
        }
        defaults.set(true, forKey: trackpadRatesMigrationKey)
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

    /// MacBook keyboard only (built-in keystrokes ÷ keys/min).
    static func macbookKeyboardMinutes(builtinKeystrokes: Int, rates: Rates) -> Int {
        keyboardMinutes(keystrokes: builtinKeystrokes, rates: rates)
    }

    /// MacBook trackpad: clicks + travel + scroll, each ÷ its rate.
    static func macbookTrackpadMinutes(
        clicks: Int,
        travelPixels: Double,
        scrollPixels: Double,
        rates: Rates
    ) -> Int {
        minutes(amount: Double(max(0, clicks)), perMinute: rates.clicksPerMinute)
            + minutes(amount: max(0, travelPixels), perMinute: rates.trackpadTravelPixelsPerMinute)
            + minutes(amount: max(0, scrollPixels), perMinute: rates.trackpadScrollPixelsPerMinute)
    }

    static func totalMinutes(
        keystrokes: Int,
        clicks: Int,
        travelPixels: Double,
        scrollBumps: Int = 0,
        builtinKeystrokes: Int = 0,
        builtinTrackpadClicks: Int = 0,
        builtinTrackpadTravelPixels: Double = 0,
        builtinTrackpadScrollPixels: Double = 0,
        rates: Rates
    ) -> Int {
        keyboardMinutes(keystrokes: keystrokes, rates: rates)
            + mouseMinutes(
                clicks: clicks,
                travelPixels: travelPixels,
                scrollBumps: scrollBumps,
                rates: rates
            )
            + macbookKeyboardMinutes(builtinKeystrokes: builtinKeystrokes, rates: rates)
            + macbookTrackpadMinutes(
                clicks: builtinTrackpadClicks,
                travelPixels: builtinTrackpadTravelPixels,
                scrollPixels: builtinTrackpadScrollPixels,
                rates: rates
            )
    }

    static func columnBreakdown(
        keystrokes: Int,
        clicks: Int,
        travelPixels: Double,
        scrollBumps: Int = 0,
        builtinKeystrokes: Int = 0,
        builtinTrackpadClicks: Int = 0,
        builtinTrackpadTravelPixels: Double = 0,
        builtinTrackpadScrollPixels: Double = 0,
        rates: Rates
    ) -> (keyboard: Int, mouse: Int, macbookKeyboard: Int, macbookTrackpad: Int) {
        (
            keyboardMinutes(keystrokes: keystrokes, rates: rates),
            mouseMinutes(
                clicks: clicks,
                travelPixels: travelPixels,
                scrollBumps: scrollBumps,
                rates: rates
            ),
            macbookKeyboardMinutes(builtinKeystrokes: builtinKeystrokes, rates: rates),
            macbookTrackpadMinutes(
                clicks: builtinTrackpadClicks,
                travelPixels: builtinTrackpadTravelPixels,
                scrollPixels: builtinTrackpadScrollPixels,
                rates: rates
            )
        )
    }

    /// Convert trackpad scroll pixels into mouse-scroll-bump equivalents for day/week/month count caps.
    static func equivalentScrollBumps(
        fromTrackpadScrollPixels pixels: Double,
        rates: Rates
    ) -> Double {
        guard pixels.isFinite, pixels > 0,
              rates.trackpadScrollPixelsPerMinute > 1e-9,
              rates.scrollsPerMinute > 1e-9
        else { return 0 }
        let minutes = pixels / rates.trackpadScrollPixelsPerMinute
        return minutes * rates.scrollsPerMinute
    }

    /// Scale trackpad travel into mouse-travel pixel equivalents for day/week/month count caps.
    static func equivalentTravelPixels(
        fromTrackpadTravelPixels pixels: Double,
        rates: Rates
    ) -> Double {
        guard pixels.isFinite, pixels > 0,
              rates.trackpadTravelPixelsPerMinute > 1e-9,
              rates.pixelsPerMinute > 1e-9
        else { return 0 }
        let minutes = pixels / rates.trackpadTravelPixelsPerMinute
        return minutes * rates.pixelsPerMinute
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
