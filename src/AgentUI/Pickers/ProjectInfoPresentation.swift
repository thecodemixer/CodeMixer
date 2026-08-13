import Foundation
import AgentCore

/// Read-only projection of a stored project for the Project Info sheet.
///
/// Mirrors the fields collected by New / Configure Project so the view dialog
/// and the create dialog stay aligned — category, type-specific detail, and
/// the Advanced “Launch new agent instance” flag. Path is view-only (the
/// create dialog does not know it yet).
struct ProjectInfoPresentation: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    let projectName: String
    let path: String
    let workingDirectoryPath: String?
    let categoryLabel: String
    let detailRows: [Row]
    /// `nil` for folder projects — Advanced options are not shown there.
    let preferFreshAgentProcess: Bool?

    static func make(from project: WorkspaceProjectsStore.ProjectRef) -> ProjectInfoPresentation {
        make(
            displayName: project.displayName,
            path: project.path,
            workingDirectoryPath: project.workingDirectoryPath,
            projectType: project.projectType,
            preferFreshAgentProcess: project.preferFreshAgentProcess
        )
    }

    static func make(displayName: String,
                     path: String,
                     workingDirectoryPath: String? = nil,
                     projectType: ProjectType,
                     preferFreshAgentProcess: Bool) -> ProjectInfoPresentation {
        let kind = ProjectTypeKind.from(projectType: projectType)
        return ProjectInfoPresentation(
            projectName: displayName,
            path: path,
            workingDirectoryPath: projectType.isAgentBacked ? (workingDirectoryPath ?? path) : nil,
            categoryLabel: kind.category.label,
            detailRows: detailRows(for: projectType),
            preferFreshAgentProcess: projectType.isAgentBacked ? preferFreshAgentProcess : nil
        )
    }

    private static func detailRows(for projectType: ProjectType) -> [Row] {
        switch projectType {
        case .claudeCode, .codex, .cursorCLI:
            let label = SupportedBuiltInAgent.shipping
                .first { $0.projectType == projectType }?.displayLabel
                ?? projectType.shortLabel
            return [Row(label: "Agent", value: label)]
        case .mixed(let defaultAgent):
            let label = defaultAgent.flatMap { SupportedBuiltInAgent.entry(for: $0)?.displayLabel }
                ?? "None"
            return [Row(label: "Default agent for new chats", value: label)]
        case .folder(let kind):
            return [Row(label: "Folder view", value: kind.displayLabel)]
        case .custom(let ref):
            return [
                Row(label: "Executable path", value: ref.executablePath),
                Row(label: "Arguments", value: displayArguments(ref.arguments)),
                Row(label: "Transport", value: transportLabel(ref.transport.kind)),
            ]
        }
    }

    static func displayArguments(_ arguments: [String]) -> String {
        guard !arguments.isEmpty else { return "—" }
        return arguments.map(shellQuote).joined(separator: " ")
    }

    static func transportLabel(_ kind: AgentTransportKind) -> String {
        switch kind {
        case .interactiveTerminal: return "Interactive terminal"
        case .stdioJSONRPC: return "Stdio JSON-RPC"
        case .agentClientProtocol: return "Agent Client Protocol"
        }
    }

    private static func shellQuote(_ token: String) -> String {
        if token.isEmpty { return "\"\"" }
        if token.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            let escaped = token.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return token
    }
}

extension ProjectTypeKind {
    /// Reverse-maps a stored `ProjectType` into the same picker kind used by
    /// New / Configure Project.
    static func from(projectType: ProjectType) -> ProjectTypeKind {
        switch projectType {
        case .claudeCode: return .builtIn(.claudeCode)
        case .codex: return .builtIn(.codex)
        case .cursorCLI: return .builtIn(.cursorCLI)
        case .mixed: return .mixed
        case .folder(let kind): return .folder(kind)
        case .custom: return .custom
        }
    }
}
