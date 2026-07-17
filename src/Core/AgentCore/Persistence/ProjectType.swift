import Foundation

/// How a project chooses which agent CLI(s) drive chats.
///
/// This is a *project type* (Claude-only, Codex-only, Cursor-only, mixed,
/// custom) — not an in-session agent mode. Agent modes (Cursor agent/plan/ask,
/// Claude Think/Review, …) come from `AgentAdapter.availableAgentModes()`.
///
/// Required at project creation — there is no unset/nil type and no silent
/// default to Claude.
public enum ProjectType: Sendable, Codable, Hashable {
    case claudeCode
    case codex
    case cursorCLI
    case mixed(defaultAgent: AgentID?)
    case custom(CustomAgentRef)

    /// Primary agent used for a new chat when the type does not require a
    /// fresh choice. Mixed types return their default (or nil). Custom
    /// returns `.other` because custom adapters are not in `AgentID.shipping`.
    ///
    /// Pinned built-ins resolve through `SupportedBuiltInAgent` so adding a
    /// shipping CLI does not require a third parallel switch here.
    public var primaryAgentID: AgentID? {
        switch self {
        case .mixed(let defaultAgent):
            return defaultAgent
        case .custom:
            return .other
        case .claudeCode, .codex, .cursorCLI:
            return SupportedBuiltInAgent.shipping.first { $0.projectType == self }?.id
        }
    }

    public var shortLabel: String {
        switch self {
        case .mixed:
            return "Mixed"
        case .custom(let ref):
            return ref.displayName
        case .claudeCode, .codex, .cursorCLI:
            return SupportedBuiltInAgent.shipping.first { $0.projectType == self }?.shortLabel
                ?? "Agent"
        }
    }
}

/// User-defined agent configuration for a `ProjectType.custom` project.
public struct CustomAgentRef: Sendable, Codable, Hashable {
    public let id: String
    public let displayName: String
    public let transport: AgentTransportDescriptor
    public let executablePath: String
    public let arguments: [String]

    public init(id: String,
                displayName: String,
                transport: AgentTransportDescriptor,
                executablePath: String,
                arguments: [String]) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.executablePath = executablePath
        self.arguments = arguments
    }
}
