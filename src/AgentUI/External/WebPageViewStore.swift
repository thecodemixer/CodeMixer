import AppKit
import Foundation
import WebKit

/// Owns live `WKWebView` instances for web-pages projects so SwiftUI identity
/// churn does not recreate views (and wipe in-page scroll / SPA state).
///
/// Cookie / localStorage persistence is per project via
/// `WKWebsiteDataStore(forIdentifier:)`. All pages in one project share that
/// store intentionally (one SSO login covers sibling webapps).
@MainActor
public final class WebPageViewStore {
    public static let shared = WebPageViewStore()

    public static let maxCachedViews = 8

    private struct Key: Hashable {
        let projectPath: String
        let pageID: UUID
    }

    private struct Entry {
        let webView: WKWebView
        var configuredURL: URL
        var lastAccess: Date
    }

    private var entries: [Key: Entry] = [:]

    private init() {}

    /// Returns a cached or newly created web view for the page. Loads `url`
    /// only on first create or when the configured URL changes.
    public func view(projectPath: String,
                     pageID: UUID,
                     url: URL,
                     sessionStoreIdentifier: UUID) -> WKWebView {
        let key = Key(projectPath: projectPath, pageID: pageID)
        if var existing = entries[key] {
            existing.lastAccess = Date()
            if existing.configuredURL != url {
                existing.configuredURL = url
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                existing.webView.load(request)
            }
            entries[key] = existing
            return existing.webView
        }

        evictIfNeeded()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: sessionStoreIdentifier)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
        entries[key] = Entry(webView: webView, configuredURL: url, lastAccess: Date())
        return webView
    }

    public func evict(projectPath: String, pageID: UUID) {
        let key = Key(projectPath: projectPath, pageID: pageID)
        if let entry = entries.removeValue(forKey: key) {
            entry.webView.stopLoading()
            entry.webView.removeFromSuperview()
        }
    }

    public func evictAll(projectPath: String) {
        let doomed = entries.keys.filter { $0.projectPath == projectPath }
        for key in doomed {
            if let entry = entries.removeValue(forKey: key) {
                entry.webView.stopLoading()
                entry.webView.removeFromSuperview()
            }
        }
    }

    public func rekey(from oldPath: String, to newPath: String) {
        let matching = entries.filter { $0.key.projectPath == oldPath }
        for (oldKey, entry) in matching {
            entries.removeValue(forKey: oldKey)
            let newKey = Key(projectPath: newPath, pageID: oldKey.pageID)
            entries[newKey] = entry
        }
    }

    public func clearData(sessionStoreIdentifier: UUID) {
        let store = WKWebsiteDataStore(forIdentifier: sessionStoreIdentifier)
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             for: records) {}
        }
    }

    public func reload(projectPath: String, pageID: UUID) {
        let key = Key(projectPath: projectPath, pageID: pageID)
        entries[key]?.webView.reload()
    }

    public func webView(projectPath: String, pageID: UUID) -> WKWebView? {
        entries[Key(projectPath: projectPath, pageID: pageID)]?.webView
    }

    private func evictIfNeeded() {
        guard entries.count >= Self.maxCachedViews else { return }
        let oldest = entries.min { $0.value.lastAccess < $1.value.lastAccess }
        if let key = oldest?.key {
            if let entry = entries.removeValue(forKey: key) {
                entry.webView.stopLoading()
                entry.webView.removeFromSuperview()
            }
        }
    }
}

/// Navigation / popup policy for embedded external web pages.
///
/// - In-webview: http(s) with a host, plus `about:` (blank iframes and the
///   `window.open("about:blank")` bootstrap many sites fire on click).
/// - System open: only schemes users expect outside the browser (`mailto:`,
///   `tel:`, `sms:`). Never hand `about:blank` / `javascript:` / `data:` to
///   `NSWorkspace` — that surfaces the "no application set" dialog.
public enum ExternalWebPageURLPolicy {
    public static func allowsNavigation(to url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        return allowsHTTPNavigation(to: url)
    }

    /// `target=_blank` / `window.open` loads that may replace the current page
    /// in the same `WKWebView`. Only real http(s) destinations — never
    /// `about:blank`, which would wipe the visible page.
    public static func allowsSameViewPopupLoad(to url: URL?) -> Bool {
        guard let url else { return false }
        return allowsHTTPNavigation(to: url)
    }

    /// Schemes that should leave Codemixer via the system handler.
    public static func shouldOpenExternally(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        return ["mailto", "tel", "sms"].contains(scheme)
    }

    private static func allowsHTTPNavigation(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }
}
