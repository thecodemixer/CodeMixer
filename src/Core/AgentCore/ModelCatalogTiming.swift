import Foundation

/// Timing for workspace-persisted adapter model catalogs.
public enum ModelCatalogTiming {
    /// Maximum age of an `.automatic` catalog before the next warm re-probes.
    public static let automaticCatalogMaxAge: TimeInterval = 24 * 60 * 60

    /// Bound live catalog probes (`claude -p`, `cursor-agent models`, …).
    /// Large provider catalogs can take tens of seconds; this is a hang
    /// ceiling, not a target latency. Create/add no longer await the probe on
    /// the sheet path — only background warm / Settings refresh do.
    public static let probeTimeout: Duration = .seconds(60)
}
