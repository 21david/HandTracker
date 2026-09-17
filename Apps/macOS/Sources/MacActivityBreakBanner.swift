import SwiftUI

/// Compact banner above the dashboard rows. One pill per active break timer showing the activity
/// name and remaining `mm:ss`. Hidden entirely when no breaks are running.
struct MacActivityBreakBanner: View {
    @ObservedObject var controller: MacActivityLimitController

    var body: some View {
        if controller.activeBreaks.isEmpty {
            EmptyView()
        } else {
            // Only tick while a break is visible — avoid a half-second TimelineView when idle.
            // Re-read activeBreaks each tick so timer extensions apply without a store-wide publish.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let now = context.date
                let sorted = controller.activeBreaks.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Break in progress — each new event extends the timer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        ForEach(sorted) { brk in
                            breakChip(for: brk, now: now)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func breakChip(for brk: ActiveActivityBreak, now: Date) -> some View {
        let remaining = brk.remainingSeconds(now: now)
        HStack(spacing: 8) {
            Image(systemName: icon(for: brk.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(brk.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(formatRemaining(seconds: remaining))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1)
        )
    }

    private func icon(for kind: HandTrackActivityKind) -> String {
        switch kind {
        case .keystrokes: return "keyboard"
        case .mouseClicks: return "computermouse"
        case .pointerTravel: return "cursorarrow.motionlines"
        }
    }

    private func formatRemaining(seconds: Int) -> String {
        let s = max(0, seconds)
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}
