import SwiftUI

/// Quiet, dismissible "while you were away" summary shown on returning to a
/// session that grew since it was last foregrounded. Never blocks —
/// dismissing simply advances the last-seen marker via `onSeen`, which makes
/// `EngineViewModel.recapSinceLastSeen` return `nil` again until more
/// activity lands.
struct AwayRecapBanner: View {
    let recap: EngineViewModel.AwayRecap
    let onSeen: () -> Void

    var body: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityHidden(true)
            Text(summary)
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            Spacer(minLength: 0)
            Button("Dismiss", action: onSeen)
                .buttonStyle(.plain)
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityLabel("Dismiss recap")
        }
        .infoBannerChrome()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("While you were away: \(summary)")
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(recap.turnsCompleted == 1 ? "1 turn completed" : "\(recap.turnsCompleted) turns completed")
        if recap.filesChanged > 0 {
            parts.append(recap.filesChanged == 1 ? "1 file changed" : "\(recap.filesChanged) files changed")
        }
        if let phase = recap.latestPhase {
            parts.append("now \(phase.label)")
        }
        return "While you were away — " + parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview("Away recap – Light") {
    AwayRecapBanner(
        recap: EngineViewModel.AwayRecap(turnsCompleted: 3, filesChanged: 2, latestPhase: nil),
        onSeen: {}
    )
    .frame(width: 480)
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Away recap – Dark") {
    AwayRecapBanner(
        recap: EngineViewModel.AwayRecap(turnsCompleted: 3, filesChanged: 2, latestPhase: nil),
        onSeen: {}
    )
    .frame(width: 480)
    .padding()
    .preferredColorScheme(.dark)
}

#endif
