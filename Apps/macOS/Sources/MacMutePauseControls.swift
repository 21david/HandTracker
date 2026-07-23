import SwiftUI

enum MacAlarmControlMode: String {
    case mute
    case pause

    var title: String {
        switch self {
        case .mute: "Mute"
        case .pause: "Pause"
        }
    }
}

/// Horizontal two-sided cylinder: click or drag vertically to roll between Mute and Pause.
struct MacMutePauseCylinderPicker: View {
    @Binding var selection: MacAlarmControlMode
    @GestureState private var dragY: CGFloat = 0

    private var rollAngle: Double {
        (selection == .mute ? 0 : -180) + Double(dragY) * 2.2
    }

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: selection == .pause
                            ? [
                                Color.blue.opacity(0.62),
                                Color.cyan.opacity(0.95),
                                Color.blue.opacity(0.92),
                                Color.blue.opacity(0.55),
                            ]
                            : [
                                Color.black.opacity(0.72),
                                Color.gray.opacity(0.92),
                                Color.gray.opacity(0.70),
                                Color.black.opacity(0.64),
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            cylinderFace("Mute", angle: rollAngle)
            cylinderFace("Pause", angle: rollAngle + 180)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .clear, .black.opacity(0.20)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        }
        .frame(width: 76, height: 32)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
                selection = selection == .mute ? .pause : .mute
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .updating($dragY) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    guard abs(value.translation.height) > 12 else { return }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
                        selection = value.translation.height < 0 ? .pause : .mute
                    }
                }
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: selection)
        .accessibilityLabel("Activity limit control mode")
        .accessibilityValue(selection.title)
        .help("Click or drag vertically to roll between Mute sounds and Pause Activity Limits")
    }

    private func cylinderFace(_ title: String, angle: Double) -> some View {
        let radians = angle * .pi / 180
        let visibility = max(0, cos(radians))
        let verticalTravel = sin(radians) * 10

        return Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .opacity(visibility)
            .offset(y: verticalTravel)
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.58
            )
            .allowsHitTesting(false)
    }
}

/// Blue status strip shown while Activity Limits are paused; normal usage recording continues.
struct MacActivityLimitsPauseBanner: View {
    @ObservedObject var viewModel: MacDashboardViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let expiry = viewModel.activityLimitsPauseExpiresAt, expiry > context.date {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(pauseTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Tracking continues; this activity is excluded from Activity Limits.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Text(remaining(until: expiry, now: context.date))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)

                    Button("Resume") {
                        viewModel.clearActivityLimitsPause()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.55), lineWidth: 1)
                )
            }
        }
    }

    private var pauseTitle: String {
        if let minutes = viewModel.activityLimitsPauseChosenMinutes {
            return "Activity Limits paused for \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        return "Activity Limits paused"
    }

    private func remaining(until expiry: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(expiry.timeIntervalSince(now))))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
