import SwiftUI

/// Embedded loopback agent dashboard surfaced beside the conversation.
struct AgentDashboardView: View {
    let url: URL
    /// Bumped by Restart ACP CLI so WKWebView reloads even when the URL string matches.
    var reloadGeneration: Int = 0

    var body: some View {
        if LoopbackDashboardURLPolicy.allowsNavigation(to: url) {
            WebViewRepresentable(url: url, reloadGeneration: reloadGeneration)
                // Stable chrome under the transparent WKWebView so overview
                // open does not flash white while the SPA boots.
                .background(Theme.surface.canvas)
                .accessibilityLabel("Agent dashboard")
                .id(reloadGeneration)
        } else {
            ContentUnavailableView(
                "Dashboard unavailable",
                systemImage: "lock.shield",
                description: Text("Only loopback dashboard URLs are allowed.")
            )
        }
    }
}
