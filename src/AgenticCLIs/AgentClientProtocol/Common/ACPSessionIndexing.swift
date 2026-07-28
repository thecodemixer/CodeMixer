import Foundation

import AgentCore

/// Role of one Codemixer-owned ACP conversation turn (local history / JSONL).
///
/// Wire replay uses `.agent` for assistant message chunks; persisted turns
/// normalize that to `.assistant` via ``stored``.
public enum ACPTurnRole: String, Sendable, Codable, Hashable {
    case user
    case assistant
    case agent
    case thinking
    case tool
    case phase
    case unknown

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ACPTurnRole(rawValue: raw) ?? .unknown
    }

    /// Role written to the turn cache (agent chunks become assistant rows).
    public var stored: ACPTurnRole {
        self == .agent ? .assistant : self
    }

    /// Whether this turn counts as a user-visible chat message in summaries.
    public var isChatMessage: Bool {
        self == .user || self == .assistant
    }

    /// Maps ACP `session/load` history-chunk role strings.
    public init(historyChunk raw: String) {
        switch raw {
        case ACPTurnRole.user.rawValue: self = .user
        case ACPTurnRole.thinking.rawValue: self = .thinking
        default: self = .agent
        }
    }
}

/// One Codemixer-owned ACP conversation turn (local history / JSONL).
public struct ACPConversationTurn: Sendable, Codable, Hashable {
    public let role: ACPTurnRole
    public let text: String
    public let toolCallID: String?
    public let toolSuccess: Bool?
    public let toolOutputSummary: String?
    public let toolInputJSON: String?
    /// Set only for ``ACPTurnRole/phase`` — a durable file-level pipeline phase
    /// marker (see `SessionPhase`), cached so `localHistoryEvents` can
    /// restore phase grouping even when the agent itself does not replay
    /// `session/update` chunks on `session/load` (Cursor's current behavior;
    /// Custom ACP replays live, so this is the belt-and-suspenders path).
    public let phase: SessionPhase?

    public init(role: ACPTurnRole,
                text: String,
                toolCallID: String? = nil,
                toolSuccess: Bool? = nil,
                toolOutputSummary: String? = nil,
                toolInputJSON: String? = nil,
                phase: SessionPhase? = nil) {
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
        self.toolSuccess = toolSuccess
        self.toolOutputSummary = toolOutputSummary
        self.toolInputJSON = toolInputJSON
        self.phase = phase
    }
}

/// Persistence surface for ACP resumable sessions and local turn cache.
public protocol ACPSessionIndexing: Sendable {
    func recordSession(id: String,
                       customAgentID: String,
                       workspace: URL,
                       title: String?) async

    func recordTurn(sessionID: String, customAgentID: String, title: String?) async

    func appendConversationTurn(sessionID: String,
                                customAgentID: String,
                                role: ACPTurnRole,
                                text: String) async

    func appendToolTurn(sessionID: String,
                        customAgentID: String,
                        toolCallID: String,
                        name: String,
                        success: Bool,
                        outputSummary: String,
                        inputJSON: String?) async

    /// Caches a durable file-level phase marker (Custom ACP only) so
    /// `localHistoryEvents` can restore phase grouping even without wire replay.
    func appendPhaseTurn(sessionID: String,
                         customAgentID: String,
                         phase: SessionPhase) async

    func localHistoryEvents(sessionID: String,
                            customAgentID: String,
                            random: any RandomSource) async -> [AgentEvent]

    func summaries(workspace: URL, customAgentID: String) async -> [SessionSummary]

    func setArchived(sessionID: String, customAgentID: String, archived: Bool) async

    func setNeedsAttention(sessionID: String, customAgentID: String, needsAttention: Bool) async

    /// Marks a session as the project overview / control session (hosted dashboard).
    func setIsOverview(sessionID: String,
                       customAgentID: String,
                       isOverview: Bool,
                       overviewURL: URL?) async
}
