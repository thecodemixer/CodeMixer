import Foundation

/// Stable identifier for an agent CLI. Used to look up adapters in the
/// `AdapterRegistry` and to tag persisted sessions with their origin.
public enum AgentID: String, Sendable, Hashable, Codable {
    case claudeCode
    case codex
    case cursorCLI
    case geminiCLI
    case openCode
    case copilot
    case other
}

/// Capabilities an adapter declares. The engine wires up only the matching
/// signal sources.
public struct AgentCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let hooksOverUDS         = AgentCapabilities(rawValue: 1 << 0)
    public static let transcriptJSONL      = AgentCapabilities(rawValue: 1 << 1)
    public static let streamJSONStdio      = AgentCapabilities(rawValue: 1 << 2)
    public static let ptyTUIFallback       = AgentCapabilities(rawValue: 1 << 3)
    public static let permissionPrompts    = AgentCapabilities(rawValue: 1 << 5)
    public static let resumableSessions    = AgentCapabilities(rawValue: 1 << 6)
}
