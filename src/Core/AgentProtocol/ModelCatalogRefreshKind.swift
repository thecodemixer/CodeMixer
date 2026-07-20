import Foundation

/// How an adapter populates its composer model list.
public enum ModelCatalogRefreshKind: Sendable, Hashable, Codable {
    /// Catalog is persisted in `workspace-<AgentID>.json` and re-probed when
    /// older than a day (or missing). Cheap/local discovery (Codex cache file,
    /// Cursor `models` CLI).
    case automatic
    /// Catalog is persisted and only refreshed when empty or the user asks —
    /// used when discovery costs agent credits or otherwise should stay rare.
    case manual(detail: String)
}
