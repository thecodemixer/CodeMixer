import SwiftUI
import AgentCore
import AgentProtocol

/// Slim card surfaced above the composer when the agent is asking for tool
/// permission. Three buttons; the entire card is keyboard- and voice-control
/// addressable.
struct PermissionPromptView: View {
    let prompt: PermissionPrompt
    let onDecision: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s12) {
            HStack(spacing: Theme.spacing.s8) {
                Image(systemName: "shield.lefthalf.filled")
                    .accessibilityLabel("Permission required")
                    .foregroundStyle(Theme.signal.warning)
                Text(prompt.summary)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                Spacer()
            }

            if !prompt.argumentsSummary.isEmpty {
                Text(prompt.argumentsSummary)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Theme.text.secondary)
                    .lineLimit(4)
            }

            HStack(spacing: Theme.spacing.s8) {
                Button("Allow") { onDecision(.allow) }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Allow this tool call")

                Button("Allow always") { onDecision(.allowAlways) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Allow this and similar tool calls in the future")

                Button("Deny") { onDecision(.deny) }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Deny this tool call")
            }
        }
        .padding(Theme.spacing.s16)
        .background(Theme.surface.card,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner.medium)
                    .stroke(Theme.signal.warning.opacity(Theme.opacity.medium), lineWidth: Theme.stroke.standard))
    }
}
