import Foundation

/// Stable identifier for an agent CLI. Used to look up adapters in the
/// `AdapterRegistry` and to tag persisted sessions with their origin.
///
/// Shipping cases appear in UI pickers only after their adapter registers.
/// Other cases remain reserved for wire/session compatibility.
public enum AgentID: String, Sendable, Hashable, Codable {
    /// v1 shipping adapter.
    case claudeCode
    /// Codex App Server adapter.
    case codex
    /// Roadmap — no adapter registered.
    case cursorCLI
    /// Roadmap — no adapter registered.
    case geminiCLI
    /// Roadmap — no adapter registered.
    case openCode
    /// Roadmap — no adapter registered.
    case copilot
    /// Test harness and unknown wire values.
    case other

    /// Adapters with a registered implementation in this build.
    public static let shipping: Set<AgentID> = [.claudeCode, .codex]
}

/// Capabilities an adapter declares. The engine wires up only the matching
/// signal sources.
public struct AgentCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let hooksOverUDS         = AgentCapabilities(rawValue: 1 << 0)
    public static let transcriptJSONL      = AgentCapabilities(rawValue: 1 << 1)
    public static let ptyTUIFallback       = AgentCapabilities(rawValue: 1 << 3)
    public static let permissionPrompts    = AgentCapabilities(rawValue: 1 << 5)
    public static let resumableSessions    = AgentCapabilities(rawValue: 1 << 6)
}
