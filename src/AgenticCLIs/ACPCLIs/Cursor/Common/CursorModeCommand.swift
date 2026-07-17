import Foundation

import AgentCore
import AgentProtocol

/// Cursor ACP chat modes and slash-command mapping.
///
/// Contract (Cursor `2026.04.15-dccdccd`): modes are switched with ACP
/// `session/set_mode`, not slash prompts. Slash `/agent`/`/plan`/`/ask` are
/// ordinary prompts unless Codemixer remaps them to `session/set_mode`.
/// `/debug` is diagnostic-only — not in `availableModes`.
public enum CursorModeCommand: String, Sendable, CaseIterable {
    case agent
    case plan
    case ask

    /// ACP `modeId` value.
    public var modeID: String { rawValue }

    public var slashName: String { "/\(rawValue)" }

    public var displayLabel: String {
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

    /// Composer bottom-bar modes. Activation uses slash names so
    /// `CursorACPAdapter.encodeCommand` remaps them to ACP `session/set_mode`.
    public static var agentModes: [AgentModeOption] {
        allCases.map {
            AgentModeOption(
                id: $0.modeID,
                label: $0.displayLabel,
                selectCommands: [.runSlashCommand(name: $0.slashName, args: [])]
            )
        }
    }

    public static func chatMode(forSlash name: String) -> CursorModeCommand? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return Self(rawValue: bare.lowercased())
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
