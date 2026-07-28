import Foundation

/// Well-known ACP `modeId` values shared by Cursor and many Custom ACP agents.
///
/// Agent-specific modes (for example `migrate`, `document`) stay dynamic on
/// ``ACPSessionMode``; only cross-agent defaults live here.
public enum ACPStandardModeID: String, Sendable, CaseIterable, Hashable {
    case agent
    case plan
    case ask

    public var displayName: String {
        switch self {
        case .agent: return "Agent"
        case .plan: return "Plan"
        case .ask: return "Ask"
        }
    }

    public var catalogSummary: String {
        switch self {
        case .agent:
            return "Full agent capabilities with tool access"
        case .plan:
            return "Read-only planning before implementation"
        case .ask:
            return "Q&A mode — no edits or command execution"
        }
    }
}
