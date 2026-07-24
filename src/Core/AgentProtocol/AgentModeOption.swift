import Foundation

/// One selectable agent mode for the composer bottom-bar menu.
///
/// Adapters publish these via `AgentAdapter.availableAgentModes()` so Claude,
/// Codex, Cursor, and custom agents each own their own mode list and activation
/// commands — the UI must not hardcode per-vendor modes.
///
/// Distinct from `ProjectType`, which chooses which agent CLI a project uses.
public struct AgentModeOption: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let label: String
    /// Commands sent (in order) when the user picks this mode.
    public let selectCommands: [AgentCommand]

    public init(id: String, label: String, selectCommands: [AgentCommand]) {
        self.id = id
        self.label = label
        self.selectCommands = selectCommands
    }
}

/// Built-in mode command identifiers used by slash-compatible adapters.
public struct AgentModeCommandID: Sendable, Hashable {
    private init() {}

    public static var think: String { "think" }
    public static var thinkOff: String { "think-off" }
    public static var review: String { "review" }
    public static var reviewOff: String { "review-off" }
}
