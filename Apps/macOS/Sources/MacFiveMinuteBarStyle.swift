import Charts
import SwiftUI

/// Shared blue vertical gradient for Mac five-minute histogram bars; ramps toward warm red when `stressAmount` rises.
enum MacFiveMinuteBarStyle {

    private static let stressTop = (r: 0.96, g: 0.14, b: 0.12)
    private static let stressBottom = (r: 0.58, g: 0.05, b: 0.08)

    /// Keystrokes (default histogram).
    private static let keystrokeBlueTop = (r: 0.20, g: 0.60, b: 1.00)
    private static let keystrokeBlueBottom = (r: 0.05, g: 0.22, b: 0.62)

    /// Mouse clicks (teal‑green stacked hour band).
    private static let clicksTealTop = (r: 0.14, g: 0.78, b: 0.58)
    private static let clicksTealBottom = (r: 0.04, g: 0.42, b: 0.36)

    /// Pointer travel (violet stacked hour band).
    private static let travelPurpleTop = (r: 0.46, g: 0.36, b: 0.98)
    private static let travelPurpleBottom = (r: 0.22, g: 0.08, b: 0.52)

    /// Scroll bumps (amber stacked hour band).
    private static let scrollAmberTop = (r: 0.98, g: 0.72, b: 0.22)
    private static let scrollAmberBottom = (r: 0.62, g: 0.34, b: 0.04)

    /// `stressAmount` in `0...1`: 0 = saturated theme only; 1 = strong stress red.
    static func barGradient(stressAmount: Double) -> LinearGradient {
        stackedHourBandGradient(metric: .keystrokes, stressAmount: stressAmount)
    }

    /// Twelve‑hour stacked column segment (distinct hue per modality; reds when past hourly cap bands).
    static func stackedHourBandGradient(metric: StackedHourInputKind, stressAmount: Double) -> LinearGradient {
        let top: (Double, Double, Double)
        let bot: (Double, Double, Double)
        switch metric {
        case .keystrokes:
            top = keystrokeBlueTop
            bot = keystrokeBlueBottom
        case .mouseClicks:
            top = clicksTealTop
            bot = clicksTealBottom
        case .pixelTravel:
            top = travelPurpleTop
            bot = travelPurpleBottom
        case .scrollBumps:
            top = scrollAmberTop
            bot = scrollAmberBottom
        }
        return blendedGradient(lightTopRGB: top, darkBottomRGB: bot, stressAmount: stressAmount)
    }

    private static func blendedGradient(
        lightTopRGB: (Double, Double, Double),
        darkBottomRGB: (Double, Double, Double),
        stressAmount: Double
    ) -> LinearGradient {
        let t = min(max(stressAmount, 0), 1)
        func blend(_ light: Double, _ dark: Double) -> Double {
            light + (dark - light) * t
        }

        let top = (
            blend(lightTopRGB.0, stressTop.r),
            blend(lightTopRGB.1, stressTop.g),
            blend(lightTopRGB.2, stressTop.b)
        )
        let bottom = (
            blend(darkBottomRGB.0, stressBottom.r),
            blend(darkBottomRGB.1, stressBottom.g),
            blend(darkBottomRGB.2, stressBottom.b)
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

    enum StackedHourInputKind {
        case keystrokes
        case mouseClicks
        case pixelTravel
        case scrollBumps
    }
}

// MARK: - Y axis marks (Charts)

enum MacFiveMinuteChartLeadingYAxis {
    /// Y ticks + labels (no horizontal grid strokes).
    @AxisContentBuilder
    static func marksNoGridGeneral() -> some AxisContent {
        AxisMarks(position: .leading) { axisValue in
            AxisTick()
            AxisValueLabel {
                if let magnitude = axisValue.as(Double.self) {
                    Text(Self.generalTickLabel(magnitude))
                }
            }
        }
    }

    /// Leading axis ticks for pixel‑travel charts (uses `125k`-style labeling when ≥ 1000 px).
    @AxisContentBuilder
    static func marksNoGridPixelThousands() -> some AxisContent {
        AxisMarks(position: .leading) { axisValue in
            AxisTick()
            AxisValueLabel {
                if let magnitude = axisValue.as(Double.self) {
                    Text(Self.pixelThousandsTickLabel(magnitude))
                }
            }
        }
    }

    private static func generalTickLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let r = round(value)
        guard abs(value - r) >= 1e-3 else {
            return String(format: "%.0f", r)
        }
        return String(format: "%g", value)
    }

    private static func pixelThousandsTickLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if abs(value) < 500 {
            return String(format: "%.0f", value)
        }
        let k = value / 1000
        guard abs(k - k.rounded()) >= 1e-2 else {
            return String(format: "%.0fk", k)
        }
        return String(format: "%.1fk", k)
    }
}

// MARK: - Leading descriptive Y captions (Charts)

enum MacFiveMinuteChartLeadingCaption {
    /// Swaps upside-down stacking on the macOS leading edge. Numeric ticks from ``marksNoGridGeneral()`` / ``marksNoGridPixelThousands()`` stay horizontal.
    @ViewBuilder
    static func rotated180Degrees(_ caption: String) -> some View {
        Text(caption)
            .rotationEffect(.degrees(180))
    }

    /// Title plus a small device note, e.g. `Scrolls` / `(external mouse)`.
    @ViewBuilder
    static func rotated180Degrees(_ title: String, deviceNote: String) -> some View {
        rotated180Degrees {
            VStack(alignment: .center, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text("(\(deviceNote))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Same convention for multi‑line captions (12‑day chart bar/pain subtitles, etc.).
    @ViewBuilder
    static func rotated180Degrees<V: View>(@ViewBuilder content: () -> V) -> some View {
        content()
            .rotationEffect(.degrees(180))
    }
}
