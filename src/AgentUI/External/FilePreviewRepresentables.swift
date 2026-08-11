import AppKit
import PDFKit
import SwiftUI
import WebKit

/// Framework wrappers for folder file previews: PDFKit and a project-scoped
/// local-file web view. Kept here so `PDFView` / `WKWebView` construction lives
/// at one boundary, like the other `External/` wrappers.

/// Navigation containment for locally previewed documents.
///
/// A previewed HTML or SVG file is untrusted content from the user's project.
/// Without this, a document could navigate the embedded view to a remote origin
/// or to a file outside the project root.
enum LocalFilePreviewNavigationPolicy {
    static func allowsNavigation(to url: URL?, projectRoot: URL) -> Bool {
        guard let url else { return false }
        if url.scheme == "about" { return true }
        guard url.isFileURL else { return false }
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Renders a PDF page-by-page with the system viewer.
struct FolderPDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.setAccessibilityLabel("PDF preview of \(url.lastPathComponent)")
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        guard nsView.document?.documentURL != url else { return }
        nsView.setAccessibilityLabel("PDF preview of \(url.lastPathComponent)")
        nsView.document = PDFDocument(url: url)
    }
}

/// Renders a local HTML/SVG file, confined to the project root.
struct FolderLocalFileWebView: NSViewRepresentable {
    let url: URL
    let projectRoot: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(projectRoot: projectRoot)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Previewed markup is project content, not an app surface: no scripts.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("Document preview of \(url.lastPathComponent)")
        context.coordinator.load(url, in: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.projectRoot = projectRoot
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.load(url, in: nsView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var projectRoot: URL
        private(set) var loadedURL: URL?

        init(projectRoot: URL) {
            self.projectRoot = projectRoot
        }

        func load(_ url: URL, in webView: WKWebView) {
            guard LocalFilePreviewNavigationPolicy
                .allowsNavigation(to: url, projectRoot: projectRoot) else { return }
            loadedURL = url
            webView.loadFileURL(url, allowingReadAccessTo: projectRoot)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            if let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                // Hand external links to the browser rather than loading them here.
                DesktopActions.openURL(url)
                decisionHandler(.cancel)
                return
            }
            let allowed = LocalFilePreviewNavigationPolicy
                .allowsNavigation(to: url, projectRoot: projectRoot)
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
