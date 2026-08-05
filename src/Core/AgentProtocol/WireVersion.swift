import Foundation

/// Wire-protocol version carried on every frame.
///
/// Bump `current` whenever a breaking wire change ships (removed fields, renamed
/// tags, stricter decoding). Clients and servers must agree on the version —
/// mismatches are rejected with `ServerFrame.versionMismatch`; there is no
/// dual-speak or `unknown`-case fallback decoding across versions.
public enum WireVersion: Int, Sendable, Codable {
    case v1 = 1
    case v2 = 2
    case v3 = 3
    /// Adds `AgentEvent.a2uiBatch` / `AgentCommand.submitA2UIInteraction` /
    /// `AgentCommand.reportA2UIClientError`. Wire-breaking under this
    /// repository's strict decoder policy — older clients must reconnect
    /// against a matching daemon rather than silently drop the new cases.
    case v4 = 4

    public static let current: WireVersion = .v4
}
