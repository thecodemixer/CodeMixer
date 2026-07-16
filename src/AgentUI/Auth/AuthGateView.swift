import SwiftUI
import AppKit
import AgentCore

/// Surfaces an authentication URL the adapter printed during launch. The
/// user clicks "Open browser" → the system browser handles the OAuth flow →
/// the engine observes the auth callback and emits a fresh `sessionStarted`
/// event, which dismisses this view.
public struct AuthGateView: View {
    public let url: URL
    public let onDismiss: () -> Void

    public init(url: URL, onDismiss: @escaping () -> Void) {
        self.url = url
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s16) {
            Image(systemName: "person.badge.key.fill")
                .accessibilityHidden(true)
                .font(Theme.typography.heroIcon)
                .foregroundStyle(Theme.signal.info)

            Text("Sign in required")
                .font(Theme.typography.title)

            Text("Your agent CLI needs you to complete an OAuth flow in your browser.")
                .font(Theme.typography.body)
                .foregroundStyle(Theme.text.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacing.s24)

            CodeBlock(text: url.absoluteString, language: nil)
                .frame(maxWidth: Theme.layout.authGateContentMaxWidth)

            HStack(spacing: Theme.spacing.s12) {
                Button("Open Browser") {
                    DesktopActions.openURL(url)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)

                Button("Copy URL") {
                    DesktopActions.copyToPasteboard(url.absoluteString)
                }

                Button("Cancel", role: .cancel, action: onDismiss)
            }
            .padding(.top, Theme.spacing.s8)
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.authGateMinWidth, minHeight: Theme.layout.authGateMinHeight)
        .background(Theme.surface.canvas)
    }
}

#if DEBUG
#Preview("Auth gate") {
    AuthGateView(url: PreviewFixtures.sampleAuthURL, onDismiss: {})
        .preferredColorScheme(.light)
}
#endif
