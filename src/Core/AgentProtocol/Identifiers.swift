import Foundation

/// Codemixer's identifier vocabulary.
///
/// Every id below is a distinct domain, even where two of them are backed by
/// the same scalar. They are separate types so the compiler rejects passing
/// one where another belongs, and so that the places where one *is*
/// deliberately derived from another have to say so out loud.

// MARK: - User turns

/// Vendor-minted id for a user turn.
///
/// Taken from the adapter's CLI: a Claude transcript record uuid, a Codex
/// rollout key (`<timestamp>-<index>`), an ACP message id. The journal stores
/// it and transcript truncation matches on it. Only some of these happen to
/// parse as UUIDs.
public struct AdapterTurnID:
    RawRepresentable,
    Sendable,
    Codable,
    Hashable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Codemixer's id for the same user turn the adapter named with
/// `AdapterTurnID`.
///
/// How the engine, clients, and the typed command surface address a turn
/// (`AgentCommand.editAndResubmitLast(targetEntryID:)`). Derived from the
/// adapter turn id — see `InternalEntryID.derive(fromAdapterTurnID:)`.
public struct InternalEntryID: RawRepresentable, Sendable, Codable, Hashable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension InternalEntryID {
    /// Deterministic map from an adapter turn id to Codemixer's entry id.
    ///
    /// The engine and every attached client compute this independently, so a
    /// random fallback would fork a new identity on each replay of the same
    /// turn.
    public static func derive(fromAdapterTurnID id: AdapterTurnID) -> InternalEntryID {
        InternalEntryID(
            rawValue: UUID(uuidString: id.rawValue) ?? StableID.uuid(from: id.rawValue)
        )
    }
}

// MARK: - Tool calls

/// Vendor-minted id for one tool call.
///
/// A Claude `tool_use` id (`toolu_…`), a Codex item id (`item_…`), an ACP tool
/// call id. `toolStart`, `toolProgress`, and `toolEnd` all carry this same id
/// so a progress or completion event folds onto the call it belongs to; that
/// is why it is one string type rather than a per-event shape. Vendors do not
/// mint UUIDs here, so this must not be narrowed to `UUID`.
public struct ToolCallID:
    RawRepresentable,
    Sendable,
    Codable,
    Hashable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Permission prompts

/// Identity of one permission prompt, from the moment an adapter raises it to
/// the moment a client answers it.
///
/// Travels out on `AgentEvent.permissionRequest` and comes back on
/// `AgentCommand.respondToPermission(id:)`, so it crosses the client trust
/// boundary and must stay stable across reconnects and replay.
public struct PermissionPromptID: RawRepresentable, Sendable, Codable, Hashable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
