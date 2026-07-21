import AppKit
import SwiftUI
import WebKit

/// Thin `WKWebView` wrapper for embedded agent dashboards.
struct WebViewRepresentable: NSViewRepresentable {
    let url: URL
    var reloadGeneration: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Default under-page fill is opaque white, which flashes before the
        // dashboard SPA paints. Transparent chrome lets Theme.surface.canvas
        // (behind the representable) show through during load.
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        // Without a UI delegate, `window.confirm` / `alert` return false / no-op —
        // dashboard Restart uses confirm and would silently do nothing.
        view.uiDelegate = context.coordinator
        context.coordinator.load(url, in: view)
        context.coordinator.loadedGeneration = reloadGeneration
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let generationChanged = context.coordinator.loadedGeneration != reloadGeneration
        if generationChanged || nsView.url != url {
            context.coordinator.loadedGeneration = reloadGeneration
            context.coordinator.load(url, in: nsView)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedGeneration: Int = -1

        func load(_ url: URL, in webView: WKWebView) {
            guard LoopbackDashboardURLPolicy.allowsNavigation(to: url) else { return }
            // Bypass WKWebView's HTTP cache so a respawned agent on a new port
            // (or same path) never paints a stale SPA from the previous process.
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(request)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let policy: WKNavigationActionPolicy = LoopbackDashboardURLPolicy
                .allowsNavigation(to: navigationAction.request.url)
                ? .allow
                : .cancel
            decisionHandler(policy)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            let accepted = alert.runModal() == .alertFirstButtonReturn
            completionHandler(accepted ? field.stringValue : nil)
        }
    }
}

/// Allows embedded dashboards to navigate only to an HTTP(S) loopback origin.
///
/// Dashboard URLs originate outside the app process. Keeping this check at the
/// WebKit navigation boundary prevents a trusted initial page from redirecting
/// the embedded view to a LAN or internet host.
enum LoopbackDashboardURLPolicy {
    static func allowsNavigation(to url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else {
            return false
        }
        return ["127.0.0.1", "::1", "localhost"].contains(host)
    }
}
