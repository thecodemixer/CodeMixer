import SwiftUI

/// Motion + structural primitives shared across the conversation surface.
///
/// These keep the "craft" affordances (arriving rows, the turn spine, the
/// streaming caret) in one place so the conversation reads as a single,
/// coherent motion language. Every animation here resolves through a
/// `Theme.motion` token and degrades to a still state under reduced motion.

extension AnyTransition {
    /// A row easing in from 4pt below with a fade. Paired with
    /// `Theme.motion.arriving` at the call site; reduced motion substitutes a
    /// plain `.opacity` so nothing slides.
    static var arriving: AnyTransition {
        .opacity.combined(with: .offset(y: 4))
    }
}

extension View {
    /// Draws a hairline "turn spine" in the leading gutter of agent-side rows.
    /// Adjacent agent rows share the gutter so the rule fuses into one
    /// continuous line, signalling that thinking + prose + tool cards belong to
    /// a single turn. User rows pass `false` and render nothing.
    func turnSpine(_ active: Bool) -> some View {
        overlay(alignment: .leading) {
            if active {
                Rectangle()
                    .fill(Theme.surface.divider)
                    .frame(width: Theme.stroke.standard)
                    .offset(x: -Theme.spacing.s8)
                    .accessibilityHidden(true)
            }
        }
    }
}

private enum SessionSwitchEmptyTiming {
    static let loadingCopyDelay: Duration = .seconds(20)
}

/// First-impression hero shown in the conversation pane before any turn has
/// landed. Two faces: no workspace loaded yet, or a workspace ready and
/// waiting for the first prompt. Transport-neutral — it only reads view-model
/// state, never the agent.
///
/// While switching to a saved session the pane stays visually blank; copy
/// appears only if replay is still in flight after `loadingCopyDelay`.
struct ConversationEmptyState: View {
    let workspace: URL?
    let isSwitchingSession: Bool

    @State private var showSwitchingCopy = false

    var body: some View {
        Group {
            if isSwitchingSession && !showSwitchingCopy {
                Color.clear
                    .accessibilityLabel("Loading session")
            } else {
                hero
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .task(id: isSwitchingSession) {
            showSwitchingCopy = false
            guard isSwitchingSession else { return }
            try? await Task.sleep(for: SessionSwitchEmptyTiming.loadingCopyDelay)
            if isSwitchingSession {
                showSwitchingCopy = true
            }
        }
    }

    private var hero: some View {
        VStack(spacing: Theme.spacing.s16) {
            Image(systemName: icon)
                .font(Theme.typography.heroIcon)
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: Theme.spacing.s8) {
                Text(title)
                    .font(Theme.typography.title)
                    .foregroundStyle(Theme.text.primary)

                Text(subtitle)
                    .font(Theme.typography.body)
                    .foregroundStyle(Theme.text.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.spacing.s32)
        .frame(maxWidth: Theme.layout.messageMaxWidth)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        if isSwitchingSession { return "clock.arrow.circlepath" }
        return workspace == nil ? "folder.badge.questionmark" : "sparkles"
    }

    private var title: String {
        if isSwitchingSession { return "Loading selected chat" }
        return workspace == nil ? "No workspace open" : "Ready when you are"
    }

    private var subtitle: String {
        if isSwitchingSession {
            return "Replaying the saved session so prompts, responses, and tool calls appear in order."
        }
        if let workspace {
            return "Ask anything about \(workspace.lastPathComponent). Type a prompt below to begin."
        }
        return "Open a project from the sidebar to start a conversation."
    }
}

/// A thin blinking caret shown at the streaming footer once tokens begin to
/// arrive. Conveys "actively writing" without the busier shimmer. Under
/// reduced motion the caret holds steady rather than blinking.
struct StreamingCaret: View {
    let reduceMotion: Bool

    @State private var dim = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(Theme.text.secondary)
            .frame(width: 2, height: 14)
            .opacity(dim ? Theme.opacity.medium : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Theme.motion.pulse.repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
            .accessibilityHidden(true)
    }
}
