import Foundation

/// Timing for workspace-persisted adapter model catalogs.
public enum ModelCatalogTiming {
    /// Maximum age of an `.automatic` catalog before the next warm re-probes.
    public static let automaticCatalogMaxAge: TimeInterval = 24 * 60 * 60
}
