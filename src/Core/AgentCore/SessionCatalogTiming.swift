import Foundation

/// Timing policy for coalescing session-catalog projections after transcript mutations.
public enum SessionCatalogTiming {
    /// Delay applied to text/tool-driven catalog updates.
    public static let mutationRepublishDebounce: Duration = .milliseconds(250)
}
