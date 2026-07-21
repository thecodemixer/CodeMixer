import AppKit
import SwiftUI
import WebKit
import AgentCore

/// Local markdown preview for folder docs / modelhike. Separate from the
/// loopback-only dashboard `WebViewRepresentable`.
struct LocalMarkdownPreviewView: View {
    let markdown: String
    let projectRoot: URL
    let documentDirectory: URL
    var scrollToAnchor: String?

    var body: some View {
        LocalMarkdownWebViewRepresentable(
            htmlBody: MarkdownHTMLRenderer.render(
                markdown,
                projectRoot: projectRoot,
                documentDirectory: documentDirectory,
                imageData: { relative in
                    let url = projectRoot.appendingPathComponent(relative)
                    return try? SystemFileSystem().readData(at: url)
                }
            ),
            projectRoot: projectRoot,
            scrollToAnchor: scrollToAnchor
        )
    }
}

struct LocalMarkdownWebViewRepresentable: NSViewRepresentable {
    let htmlBody: String
    let projectRoot: URL
    var scrollToAnchor: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(projectRoot: projectRoot)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "copyCode")
        configuration.userContentController = userContent
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.loadShell(in: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.projectRoot = projectRoot
        context.coordinator.setContent(htmlBody, in: nsView)
        if let scrollToAnchor {
            context.coordinator.scroll(to: scrollToAnchor, in: nsView)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var projectRoot: URL
        private var shellLoaded = false
        private var pendingHTML: String?

        init(projectRoot: URL) {
            self.projectRoot = projectRoot
        }

        func loadShell(in webView: WKWebView) {
            shellLoaded = false
            // `loadFileURL` requires the HTML file to live under `allowingReadAccessTo`.
            // Our shell is in the AgentUI bundle while images live under the project
            // root, so load the shell as a string with `baseURL` = projectRoot.
            if let url = Bundle.module.url(forResource: "MarkdownPreview", withExtension: "html"),
               let shell = try? String(contentsOf: url, encoding: .utf8) {
                webView.loadHTMLString(shell, baseURL: projectRoot)
            } else {
                let fallback = """
                <!DOCTYPE html><html><body><article id="content"></article>
                <script>
                window.__setMarkdownHTML=function(html){
                  document.getElementById('content').innerHTML=html||'';
                };
                window.__scrollToAnchor=function(id){
                  const el=document.getElementById(id); if(el) el.scrollIntoView();
                };
                </script></body></html>
                """
                webView.loadHTMLString(fallback, baseURL: projectRoot)
            }
        }

        func setContent(_ html: String, in webView: WKWebView) {
            pendingHTML = html
            guard shellLoaded else { return }
            inject(html, into: webView)
        }

        func scroll(to anchor: String, in webView: WKWebView) {
            guard shellLoaded else { return }
            let payload: String
            if let data = try? JSONSerialization.data(withJSONObject: [anchor]),
               let encoded = String(data: data, encoding: .utf8) {
                payload = String(encoded.dropFirst().dropLast())
            } else {
                payload = "\"\""
            }
            webView.evaluateJavaScript("window.__scrollToAnchor && window.__scrollToAnchor(\(payload));")
        }

        private func inject(_ html: String, into webView: WKWebView) {
            let payload: String
            if let data = try? JSONSerialization.data(withJSONObject: [html]),
               let encoded = String(data: data, encoding: .utf8) {
                payload = String(encoded.dropFirst().dropLast())
            } else {
                payload = "\"\""
            }
            webView.evaluateJavaScript("window.__setMarkdownHTML && window.__setMarkdownHTML(\(payload));")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shellLoaded = true
            if let pendingHTML {
                inject(pendingHTML, into: webView)
            }
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "copyCode",
                  let text = message.body as? String else { return }
            DesktopActions.copyToPasteboard(text)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .other
                || (url.isFileURL && url.path.contains("MarkdownPreview")) {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if let fragment = url.fragment, !fragment.isEmpty, (url.path.isEmpty || url.isFileURL) {
                decisionHandler(.allow)
                return
            }
            if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                DesktopActions.openURL(url)
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL {
                let standardized = url.standardizedFileURL.path
                let root = projectRoot.standardizedFileURL.path
                if standardized == root || standardized.hasPrefix(root + "/") {
                    decisionHandler(.allow)
                    return
                }
            }
            decisionHandler(.cancel)
        }
    }
}
