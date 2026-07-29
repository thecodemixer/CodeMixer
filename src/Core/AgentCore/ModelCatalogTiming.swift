import Foundation

/// Timing for workspace-persisted adapter model catalogs.
public enum ModelCatalogTiming {
    /// Maximum age of an `.automatic` catalog before the next warm re-probes.
    public static let automaticCatalogMaxAge: TimeInterval = 24 * 60 * 60

    /// Bound live catalog probes (`claude -p`, `cursor-agent models`, …).
    /// Large provider catalogs can take tens of seconds; this is a hang
    /// ceiling, not a target latency. Workspace warm and create/add soft-fail
    /// paths (`ensureModelsRecordingFailures`) await the probe under this
    /// bound so a hung CLI cannot freeze open / New Project.
    public static let probeTimeout: Duration = .seconds(60)

    /// Diagnostic reason when a live probe returns no models but a cached
    /// workspace catalog is retained.
    public static let retainedEmptyCatalogReason = "empty catalog"

    /// Fallback when a project is Not loaded but no per-adapter failure text exists.
    public static let unavailableProjectMessage = "Model catalog unavailable."
}
