import AppKit
import SwiftUI
import WebKit

/// Hosts a store-owned `WKWebView` for a web-pages project entry.
///
/// The store keeps the live view across SwiftUI identity churn; this
/// representable only attaches it as a subview of a container `NSView`.
struct WebPageViewRepresentable: NSViewRepresentable {
    let projectPath: String
    let pageID: UUID
    let url: URL
    let sessionStoreIdentifier: UUID
    var reloadGeneration: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        attachWebView(in: container, context: context)
        context.coordinator.loadedGeneration = reloadGeneration
        context.coordinator.configuredURL = url
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = WebPageViewStore.shared.view(
            projectPath: projectPath,
            pageID: pageID,
            url: url,
            sessionStoreIdentifier: sessionStoreIdentifier
        )
        if webView.superview !== nsView {
            attachWebView(in: nsView, context: context)
        }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.hostWebView = webView

        let generationChanged = context.coordinator.loadedGeneration != reloadGeneration
        if generationChanged {
            context.coordinator.loadedGeneration = reloadGeneration
            webView.reload()
        } else if context.coordinator.configuredURL != url {
            context.coordinator.configuredURL = url
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(request)
        }
    }

    private func attachWebView(in container: NSView, context: Context) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let webView = WebPageViewStore.shared.view(
            projectPath: projectPath,
            pageID: pageID,
            url: url,
            sessionStoreIdentifier: sessionStoreIdentifier
        )
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.hostWebView = webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedGeneration: Int = -1
        var configuredURL: URL?
        weak var hostWebView: WKWebView?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            if ExternalWebPageURLPolicy.allowsNavigation(to: url) {
                decisionHandler(.allow)
                return
            }
            if ExternalWebPageURLPolicy.shouldOpenExternally(url), let url {
                DesktopActions.openURL(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // target=_blank / window.open — load real http(s) in the same view.
            // about:blank is a common popup bootstrap; ignore it (do not open
            // externally — that triggers macOS "no application set").
            let request = navigationAction.request
            if ExternalWebPageURLPolicy.allowsSameViewPopupLoad(to: request.url) {
                webView.load(request)
            } else if ExternalWebPageURLPolicy.shouldOpenExternally(request.url),
                      let url = request.url {
                DesktopActions.openURL(url)
            }
            return nil
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
