import Foundation

import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Cursor ACP chat modes and slash-command mapping.
///
/// Contract (Cursor `2026.04.15-dccdccd`): modes are switched with ACP
/// `session/set_mode`, not slash prompts. Slash `/agent`/`/plan`/`/ask` are
/// ordinary prompts unless Codemixer remaps them to `session/set_mode`.
/// `/debug` is diagnostic-only — not in `availableModes`.
public enum CursorModeCommand: Sendable, CaseIterable {
    case agent
    case plan
    case ask

    public init?(standardModeID: ACPStandardModeID) {
        switch standardModeID {
        case .agent: self = .agent
        case .plan: self = .plan
        case .ask: self = .ask
        }
    }

    public var standardModeID: ACPStandardModeID {
        switch self {
        case .agent: return .agent
        case .plan: return .plan
        case .ask: return .ask
        }
    }

    /// ACP `modeId` value.
    public var modeID: String { standardModeID.rawValue }

    public var slashName: String { "/\(modeID)" }

    public var displayLabel: String { standardModeID.displayName }

    public var catalogSummary: String { standardModeID.catalogSummary }

    /// Composer bottom-bar modes. Activation writes ACP `session/set_mode`
    /// through `CursorACPAdapter.encodeCommand`.
    public static var agentModes: [AgentModeOption] {
        allCases.map {
            AgentModeOption(
                id: $0.modeID,
                label: $0.displayLabel,
                selectCommands: [.setAgentMode(id: $0.modeID)]
            )
        }
    }

    public static func chatMode(forSlash name: String) -> CursorModeCommand? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return ACPStandardModeID(rawValue: bare.lowercased()).flatMap(CursorModeCommand.init(standardModeID:))
    }

    public static func modeID(forPermissionMode mode: PermissionMode) -> String? {
        switch mode {
        case .plan:
            return CursorModeCommand.plan.modeID
        case .default:
            return CursorModeCommand.agent.modeID
        case .acceptEdits, .bypassPermissions:
            return nil
        }
    }

    /// Built-in slash catalog for Cursor. Includes a diagnostic-only `/debug`
    /// entry that is intentionally not a chat mode.
    public static var slashCatalog: [SlashCommand] {
        let modes = allCases.map {
            SlashCommand(id: $0.slashName,
                         name: $0.slashName,
                         summary: $0.catalogSummary,
                         sendsAsPrompt: false)
        }
        let debug = SlashCommand(
            id: "/debug",
            name: "/debug",
            summary: "Diagnostic help prompt only — not an ACP chat mode"
        )
        return modes + [debug]
    }
}
