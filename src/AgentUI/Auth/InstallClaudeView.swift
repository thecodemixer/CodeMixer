import SwiftUI
import AppKit
import AgentCore

/// Shown as a sheet when `AgentEngine.start` throws `AgentError.binaryNotFound`.
///
/// Guides the user through installing Claude Code via `npm` without
/// leaving the app. The install command is displayed in a monospaced code
/// block and can be copied to the clipboard or opened in Terminal.
public struct InstallClaudeView: View {

    private static let installCommand = "npm install -g @anthropic-ai/claude-code"

    public let hint: String
    public let onDismiss: () -> Void

    public init(hint: String, onDismiss: @escaping () -> Void) {
        self.hint = hint
        self.onDismiss = onDismiss
    }

    @State private var copied = false

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {

            HStack(spacing: Theme.spacing.s12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityLabel("Claude Code not found")
                    .font(Theme.typography.iconLarge)
                    .foregroundStyle(Theme.signal.warning)
                VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                    Text("Claude Code not found")
                        .font(Theme.typography.title)
                    Text("The `claude` binary could not be located on this machine.")
                        .font(Theme.typography.body)
                        .foregroundStyle(Theme.text.secondary)
                }
            }

            if !hint.isEmpty {
                Text(hint)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }

            Divider()

            VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                Text("Install with npm:")
                    .font(Theme.typography.label)

                HStack(spacing: Theme.spacing.s8) {
                    Text(Self.installCommand)
                        .font(Theme.typography.monoSmall)
                        .foregroundStyle(Theme.text.primary)
                        .padding(.horizontal, Theme.spacing.s12)
                        .padding(.vertical, Theme.spacing.s8)
                        .background(Theme.surface.card)
                        .cornerRadius(Theme.corner.medium)
                        .textSelection(.enabled)
                        .accessibilityLabel("Install command: \(Self.installCommand)")

                    Button {
                        DesktopActions.copyToPasteboard(Self.installCommand)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Copy install command")
                }

                Text("Requires [Node.js](https://nodejs.org) ≥ 18. After installation, relaunch Codemixer and open a project.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }

            Divider()

            HStack {
                Button("Open Terminal") {
                    DesktopActions.openURL(SystemPaths.terminalApp)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open Terminal application")

                Spacer()

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Dismiss install Claude dialog")
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.installMinWidth, maxWidth: Theme.layout.installMaxWidth)
    }
}
