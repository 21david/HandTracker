import Charts
import SwiftUI

private enum FiveMinuteKeystrokeChart {
    /// Keystrokes per bucket that fills the vertical scale (~55/min if evenly spread). Tune freely.
    static let comfortableKeystrokeCap: Double = 275
    /// How many keystrokes above the cap it takes before the fill reads as strongly red (~20+ visibly warm per your note).
    static let keystrokesAboveCapTowardFullRed: Double = 40
}

struct MacKeystrokeFiveMinuteChart: View {
    @EnvironmentObject private var store: HandTrackStore

    private let cap = FiveMinuteKeystrokeChart.comfortableKeystrokeCap

    /// Solid bar color at and below the cap.
    private var baseBlue: Color { Color(red: 0.12, green: 0.52, blue: 1.0) }

    /// Red target when heavily over cap.
    private var stressRed: (Double, Double, Double) { (0.95, 0.08, 0.08) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let slots = store.keystrokesByFiveMinuteSlotsTrailing(reference: timeline.date, count: 12)
            let ordinals = Array(slots.indices)

            Chart {
                ForEach(ordinals, id: \.self) { index in
                    let slot = slots[index]
                    if slot.keyCount > 0 {
                        let displayedHeight = min(Double(slot.keyCount), cap)
                        BarMark(
                            x: .value("Slice", index),
                            y: .value("Keys", displayedHeight)
                        )
                        .foregroundStyle(barColor(keystrokes: slot.keyCount))
                        .cornerRadius(3)
                        .annotation(position: .top, alignment: .center, spacing: 4) {
                            Text("\(slot.keyCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...cap)
            .chartXScale(domain: -0.5...11.5)
            .chartXAxis {
                AxisMarks(preset: .aligned, values: ordinals) { value in
                    AxisTick()
                    if let idx = value.as(Int.self), slots.indices.contains(idx) {
                        AxisValueLabel {
                            Text(slots[idx].slotStart, format: .dateTime.hour().minute(.twoDigits))
                                .font(.caption2)
                        }
                    }
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

    /// At or below cap: steady blue; above cap, blend subtly toward red as excess grows.
    private func barColor(keystrokes: Int) -> Color {
        if Double(keystrokes) <= cap {
            return baseBlue.opacity(0.92)
        }
        let excess = Double(keystrokes) - cap
        let tint = min(
            excess / FiveMinuteKeystrokeChart.keystrokesAboveCapTowardFullRed,
            1.0
        )
        let b: (Double, Double, Double) = (0.12, 0.52, 1.0)
        let r = stressRed
        return Color(
            red: b.0 + (r.0 - b.0) * tint,
            green: b.1 + (r.1 - b.1) * tint,
            blue: b.2 + (r.2 - b.2) * tint
        )
    }
}
