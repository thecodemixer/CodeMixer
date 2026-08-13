import Foundation

/// One named URL under a `ProjectType.webPages` project.
public struct WebPageEntry: Sendable, Codable, Hashable, Identifiable {
    /// Maximum pages stored for a single web-pages project.
    public static let maxPages = 20

    public let id: UUID
    public var displayName: String
    /// Canonical absolute http(s) string after normalization.
    public var urlString: String

    public init(id: UUID = UUID(), displayName: String, urlString: String) {
        self.id = id
        self.displayName = displayName
        self.urlString = urlString
    }

    /// Parsed URL when `urlString` is a valid http(s) absolute URL.
    public var url: URL? { Self.validatedURL(urlString) }

    /// Trims, prepends `https://` when the scheme is missing, rejects non-http(s),
    /// fills empty display names from the host, dedupes by case-insensitive URL,
    /// and caps at `maxPages`.
    public static func normalized(_ entries: [WebPageEntry]) -> [WebPageEntry] {
        var seen = Set<String>()
        var result: [WebPageEntry] = []
        for entry in entries {
            let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = validatedURL(entry.urlString) else { continue }
            let canonical = url.absoluteString
            let key = canonical.lowercased()
            guard seen.insert(key).inserted else { continue }
            let resolvedName: String = {
                if !name.isEmpty { return name }
                if let host = url.host, !host.isEmpty { return host }
                return "Page"
            }()
            result.append(WebPageEntry(id: entry.id, displayName: resolvedName, urlString: canonical))
            if result.count == maxPages { break }
        }
        return result
    }

    /// Returns a validated http(s) URL, prepending `https://` when the scheme is absent.
    public static func validatedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String = {
            if let scheme = URL(string: trimmed)?.scheme, !scheme.isEmpty {
                return trimmed
            }
            return "https://\(trimmed)"
        }()
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// True when a draft row's URL text would survive normalization.
    public static func isValidDraftURL(_ raw: String) -> Bool {
        validatedURL(raw) != nil
    }
}

/// Durable config for `ProjectType.webPages`, stored in `.codemixer/project.json`.
public struct WebPagesProjectConfig: Sendable, Codable, Hashable {
    public var pages: [WebPageEntry]
    /// Identifier for the project's persistent `WKWebsiteDataStore`.
    public let sessionStoreIdentifier: UUID

    public init(pages: [WebPageEntry] = [], sessionStoreIdentifier: UUID = UUID()) {
        self.pages = WebPageEntry.normalized(pages)
        self.sessionStoreIdentifier = sessionStoreIdentifier
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = WebPageEntry.normalized(try c.decodeIfPresent([WebPageEntry].self, forKey: .pages) ?? [])
        sessionStoreIdentifier = try c.decode(UUID.self, forKey: .sessionStoreIdentifier)
    }

    enum CodingKeys: String, CodingKey {
        case pages, sessionStoreIdentifier
    }
}
