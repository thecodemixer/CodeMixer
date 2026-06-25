import SwiftUI
import AgentProtocol

/// A subtle three-dot shimmer — the "we're working" baseline indicator.
public struct ShimmerDots: View {
    @State private var phase: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        HStack(spacing: Theme.spacing.s4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.text.tertiary)
                    .frame(width: Theme.layout.activityDotSize,
                           height: Theme.layout.activityDotSize)
                    // Under reduced motion the dots hold at a steady mid-opacity
                    // instead of pulsing; the phase-driven sine only runs when
                    // motion is permitted.
                    .opacity(reduceMotion
                             ? Theme.opacity.secondary
                             : Theme.opacity.pulseBase + Theme.opacity.pulseRange * sin((phase + Double(i) * Theme.motion.shimmerPhaseStep) * .pi))
            }
        }
        .frame(height: Theme.layout.activityDotsHeight)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Theme.motion.shimmer.repeatForever(autoreverses: false)) {
                phase = 2
            }
        }
        .accessibilityLabel("Working")
    }
}

/// One-line "what is the agent doing right now" status, hidden while idle.
///
/// Crossfades phrase changes in 200ms. Respects `accessibilityReduceMotion`:
/// phrase swaps become instant with a static ShimmerDot at 60% opacity.
public struct InlineStatusTicker: View {
    public let phrase: String
    public let substate: ActivitySubstate

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(phrase: String, substate: ActivitySubstate) {
        self.phrase = phrase
        self.substate = substate
    }

    public var body: some View {
        HStack(spacing: Theme.spacing.s8) {
            if reduceMotion {
                // Static dot at 60% opacity — no animation.
                Circle()
                    .fill(Theme.text.tertiary)
                    .frame(width: Theme.layout.activityDotSize,
                           height: Theme.layout.activityDotSize)
                    .opacity(Theme.opacity.secondary)
            } else {
                ShimmerDots()
            }
            Text(phrase)
                .font(Theme.typography.caption)
                .foregroundStyle(substate == .stillWorking || substate == .probablyStuck
                                 ? Theme.signal.warning
                                 : Theme.text.secondary)
                .lineLimit(1)
                .id(phrase)
                .transition(.opacity)
                .animation(
                    reduceMotion ? nil : Theme.motion.standard,
                    value: phrase
                )
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// Pill that escalates from a quiet status to an unmissable "Still working" /
/// "Probably stuck — try cancel" message.
public struct StatusPill: View {
    public let status: EngineViewModel.StatusLine
    public let substate: ActivitySubstate
    public let onCancel: () -> Void

    public init(status: EngineViewModel.StatusLine,
                substate: ActivitySubstate,
                onCancel: @escaping () -> Void) {
        self.status = status
        self.substate = substate
        self.onCancel = onCancel
    }

    public var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working(let phrase):
            HStack(spacing: Theme.spacing.s8) {
                InlineStatusTicker(phrase: phrase, substate: substate)
                if substate == .stillWorking || substate == .probablyStuck {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut(".", modifiers: .command)
                        .accessibilityLabel("Cancel current turn")
                }
            }
            .padding(.horizontal, Theme.spacing.s12)
            .padding(.vertical, Theme.spacing.s8)
            .background(Theme.surface.card, in: .capsule)
            .overlay(Capsule().stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline))
            .frame(maxWidth: Theme.layout.statusPillMaxWidth, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: true)
        }
    }
}
