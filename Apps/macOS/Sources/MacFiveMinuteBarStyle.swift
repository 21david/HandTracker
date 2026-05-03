import SwiftUI

/// Shared blue vertical gradient for Mac five-minute histogram bars; ramps toward warm red when `stressAmount` rises.
enum MacFiveMinuteBarStyle {

    /// Lighter blue toward the bar top (annotation side).
    private static let blueTop = (r: 0.20, g: 0.60, b: 1.00)
    /// Deeper navy toward the bar bottom / baseline.
    private static let blueBottom = (r: 0.05, g: 0.22, b: 0.62)

    private static let stressTop = (r: 0.96, g: 0.14, b: 0.12)
    private static let stressBottom = (r: 0.58, g: 0.05, b: 0.08)

    /// `stressAmount` in `0...1`: 0 = blue gradient only; 1 = strong red (over-threshold).
    static func barGradient(stressAmount: Double) -> LinearGradient {
        let t = min(max(stressAmount, 0), 1)
        func blend(_ light: Double, _ dark: Double) -> Double {
            light + (dark - light) * t
        }

        let top = (
            blend(blueTop.r, stressTop.r),
            blend(blueTop.g, stressTop.g),
            blend(blueTop.b, stressTop.b)
        )
        let bottom = (
            blend(blueBottom.r, stressBottom.r),
            blend(blueBottom.g, stressBottom.g),
            blend(blueBottom.b, stressBottom.b)
        )

        return LinearGradient(
            colors: [
                Color(red: top.0, green: top.1, blue: top.2),
                Color(red: bottom.0, green: bottom.1, blue: bottom.2),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Maps how far past `cap` the value sits into a `0...1` stress blend.
    static func stressAmount(from value: Double, cap: Double, excessWidth: Double) -> Double {
        guard value > cap, excessWidth > 0 else { return 0 }
        return min((value - cap) / excessWidth, 1)
    }
}
