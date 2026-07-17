import Foundation

/// Catalog entry for a shipping built-in agent CLI.
///
/// UI surfaces (New Project, Configure Project, mixed-mode defaults) consume
/// this catalog instead of hardcoding per-agent picker cases. Adding a new
/// supported CLI means extending `shipping` here and registering its adapter.
public struct SupportedBuiltInAgent: Sendable, Hashable, Identifiable {
    public let id: AgentID
    public let displayLabel: String
    public let shortLabel: String
    public let projectType: ProjectType

    public init(id: AgentID,
                displayLabel: String,
                shortLabel: String,
                projectType: ProjectType) {
        self.id = id
        self.displayLabel = displayLabel
        self.shortLabel = shortLabel
        self.projectType = projectType
    }

    /// Built-in agents available for project creation and mixed-mode defaults.
    public static let shipping: [SupportedBuiltInAgent] = [
        .init(id: .claudeCode,
              displayLabel: "Claude Code",
              shortLabel: "Claude",
              projectType: .claudeCode),
        .init(id: .codex,
              displayLabel: "Codex",
              shortLabel: "Codex",
              projectType: .codex),
        .init(id: .cursorCLI,
              displayLabel: "Cursor",
              shortLabel: "Cursor",
              projectType: .cursorCLI),
    ]

    public static func shippingIDs() -> [AgentID] {
        shipping.map(\.id)
    }

    public static func entry(for id: AgentID) -> SupportedBuiltInAgent? {
        shipping.first { $0.id == id }
    }
}
