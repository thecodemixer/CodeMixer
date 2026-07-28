import Foundation

/// A Codemixer-owned, human-readable history marker for an agent-affecting
/// client intent (mode change, slash command, permission decision, …).
///
/// Distinct from `.userTurn`: actions are *not* injected as prompts into the
/// agent CLI, and they are *not* written into Claude/Codex/Cursor session
/// stores. They live on the event bus and in Codemixer's project-local
/// `SessionTranscript`, so reopen/resume and conversation snapshots preserve
/// them without mutating vendor history.
public struct ClientAction: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case mode
        case model
        case slashCommand
        case permissionMode
        case permissionResponse
        case sessionLifecycle
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let detail: String?

    public init(id: UUID,
                kind: Kind,
                title: String,
                detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}
