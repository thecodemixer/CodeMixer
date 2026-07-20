import Foundation

import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Maps ACP session modes into composer / slash / permission commands.
public enum CustomACPModeMapping {
    /// Composer modes with current mode first when known.
    public static func agentModes(from modes: [ACPSessionMode],
                                  currentModeID: String?) -> [AgentModeOption] {
        let options = modes.map { mode in
            AgentModeOption(
                id: mode.id,
                label: mode.name,
                selectCommands: [.runSlashCommand(name: "/\(mode.id)", args: [])]
            )
        }
        guard let currentModeID,
              let idx = options.firstIndex(where: { $0.id == currentModeID }),
              idx > 0 else {
            return options
        }
        var ordered = options
        let current = ordered.remove(at: idx)
        ordered.insert(current, at: 0)
        return ordered
    }

    public static func slashCatalog(from modes: [ACPSessionMode]) -> [SlashCommand] {
        modes.map { mode in
            SlashCommand(
                id: "/\(mode.id)",
                name: "/\(mode.id)",
                summary: mode.description ?? mode.name,
                sendsAsPrompt: false
            )
        }
    }

    public static func modeID(forSlash name: String, available: [ACPSessionMode]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let needle = bare.lowercased()
        return available.first { $0.id.lowercased() == needle }?.id
    }

    public static func modeID(forPermissionMode mode: PermissionMode,
                              available: [ACPSessionMode]) -> String? {
        let ids = Set(available.map(\.id))
        switch mode {
        case .plan:
            return ids.contains("plan") ? "plan" : nil
        case .default:
            if ids.contains("agent") { return "agent" }
            return available.first?.id
        case .acceptEdits, .bypassPermissions:
            return nil
        }
    }
}
