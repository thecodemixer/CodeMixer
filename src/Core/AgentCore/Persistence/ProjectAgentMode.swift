import Foundation

/// How sessions inside a project are routed to adapters.
///
/// Required at project creation — there is no unset/nil mode and no silent
/// default to Claude.
public enum ProjectAgentMode: Sendable, Codable, Hashable {
    case claudeCode
    case codex
    case mixed(defaultAgent: AgentID?)
    case custom(CustomAgentRef)

    /// Primary agent used for a new chat when the mode does not require a
    /// fresh choice. Mixed modes return their default (or nil). Custom
    /// returns `.other` because custom adapters are not in `AgentID.shipping`.
    public var primaryAgentID: AgentID? {
        switch self {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        case .mixed(let defaultAgent): return defaultAgent
        case .custom: return .other
        }
    }

    public var shortLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .mixed: return "Mixed"
        case .custom(let ref): return ref.displayName
        }
    }
}

/// User-defined agent configuration for a `ProjectAgentMode.custom` project.
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
