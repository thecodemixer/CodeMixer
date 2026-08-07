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
    /// Moves identifiers onto the typed vocabulary in `Identifiers.swift`.
    ///
    /// Two changes are wire-breaking. `AgentCommand.editAndResubmitLast`'s
    /// first label goes from `targetBubbleID` to `targetEntryID`, and
    /// synthesized `Codable` keys off the label. `AgentEvent.toolProgress`'s
    /// `callID` changes from a `UUID` to a `ToolCallID`, which is a bare
    /// string, because vendors do not mint UUIDs for tool calls; a v4 client
    /// would fail to decode `"toolu_01ABC"` as a UUID.
    ///
    /// Every other identifier (`AdapterTurnID`, `InternalEntryID`,
    /// `PermissionPromptID`) encodes as the same scalar it did before, so
    /// those are type-level changes only. `WireFrameRoundTripTests`
    /// pins the encodings.
    case v5 = 5

    public static let current: WireVersion = .v5
}
