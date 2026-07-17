import Foundation

/// How an adapter populates its composer model list.
public enum ModelCatalogRefreshKind: Sendable, Hashable, Codable {
    /// Catalog stays current without a user action (cache file, live protocol).
    case automatic
    /// Catalog is persisted and only refreshed when the user asks — used when
    /// discovery costs agent credits or otherwise should stay rare.
    case manual(detail: String)
}
