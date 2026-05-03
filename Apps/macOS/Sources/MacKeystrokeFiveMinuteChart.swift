import Charts
import SwiftUI

private enum FiveMinuteKeystrokeChart {
    /// Keystrokes per 5‑minute bucket that fills the vertical scale (~55/min if evenly spread across the slice). Recovery-oriented default alongside break schedules like 30 min typing / 10 min rest — change freely.
    static let comfortableKeystrokeCap: Double = 275
}

struct MacKeystrokeFiveMinuteChart: View {
    @EnvironmentObject private var store: HandTrackStore

    private let cap = FiveMinuteKeystrokeChart.comfortableKeystrokeCap

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let slots = store.keystrokesByFiveMinuteSlotsInHour(containing: timeline.date)
            Chart(slots) { slot in
                let displayedHeight = min(Double(slot.keyCount), cap)
                BarMark(
                    xStart: .value("From", slot.slotStart),
                    xEnd: .value("To", slot.slotEnd),
                    y: .value("Keys", displayedHeight)
                )
                .foregroundStyle(barColor(keystrokes: slot.keyCount))
                .cornerRadius(2)
            }
            .chartYScale(domain: 0...cap)
            .chartXAxis {
                AxisMarks(values: slots.map(\.slotStart)) {
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour().minute(.twoDigits))
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartYAxisLabel("Keystrokes", position: .leading)
            .frame(height: 200)
            .chartPlotStyle { plotArea in
                plotArea.padding(.leading, 4)
            }
        }
    }

    /// Blue at low load, shifting toward orange and red as usage exceeds the comfortable cap.
    private func barColor(keystrokes: Int) -> Color {
        let ratio = Double(keystrokes) / max(cap, 1)
        // Full deep red around ~2.5× the comfortable cap; below 1.0 stays mostly cool tones.
        let blend = min(ratio / 2.5, 1.0)
        let blue = (Double(0.12), Double(0.52), Double(1.0))
        let amber = (Double(1.0), Double(0.55), Double(0.06))
        let red = (Double(0.95), Double(0.06), Double(0.06))
        let mid = blend < 0.55
            ? interpolate(blue, amber, blend / 0.55)
            : interpolate(amber, red, (blend - 0.55) / 0.45)
        return Color(red: mid.0, green: mid.1, blue: mid.2)
    }

    private func interpolate(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double),
        _ t: Double
    ) -> (Double, Double, Double) {
        let clamped = min(max(t, 0), 1)
        return (
            a.0 + (b.0 - a.0) * clamped,
            a.1 + (b.1 - a.1) * clamped,
            a.2 + (b.2 - a.2) * clamped
        )
    }
}
