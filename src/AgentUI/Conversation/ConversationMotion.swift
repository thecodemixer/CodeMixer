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

/// First-impression hero shown in the conversation pane before any turn has
/// landed. Faces: no workspace, workspace ready for a prompt, or restoring a
/// saved session (including while the composer is still gated on resume).
/// Transport-neutral — it only reads view-model state, never the agent.
struct ConversationEmptyState: View {
    let workspace: URL?
    /// Workspace shell is loaded but no project is selected yet.
    let hasWorkspaceProjects: Bool
    let sessionActivation: SessionActivation
    let historyUnavailable: Bool

    var body: some View {
        hero
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
        switch sessionActivation {
        case .restoringHistory:
            return "clock.arrow.circlepath"
        case .awaitingAdapter:
            return "ellipsis.bubble"
        case .failed:
            return "exclamationmark.triangle"
        case .idle, .ready:
            if historyUnavailable { return "clock.badge.questionmark" }
            if workspace == nil {
                return hasWorkspaceProjects ? "sidebar.left" : "folder.badge.questionmark"
            }
            return "sparkles"
        }
    }

    private var title: String {
        switch sessionActivation {
        case .restoringHistory:
            return "Loading selected chat"
        case .awaitingAdapter:
            return "Starting chat"
        case .failed:
            return "Agent unavailable"
        case .idle, .ready:
            if historyUnavailable { return "History unavailable" }
            if workspace == nil {
                return hasWorkspaceProjects ? "Select a project" : "No workspace open"
            }
            return "Ready when you are"
        }
    }

    private var subtitle: String {
        switch sessionActivation {
        case .restoringHistory:
            return "Replaying the saved session so prompts, responses, and tool calls appear in order."
        case .awaitingAdapter:
            return "Connecting the agent for a new chat. You can type once it is ready."
        case .failed(_, let message):
            return message
        case .idle, .ready:
            if historyUnavailable {
                return "Cursor reported this session, but its stored message graph is not available through a stable public format. New work will appear here."
            }
            if let workspace {
                return "Ask anything about \(workspace.lastPathComponent). Type a prompt below to begin."
            }
            if hasWorkspaceProjects {
                return "Open a project from the sidebar to start a conversation."
            }
            return "Open a project from the sidebar to start a conversation."
        }
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
