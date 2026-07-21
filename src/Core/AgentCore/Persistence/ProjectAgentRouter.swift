import Foundation

/// Resolves which `AgentAdapter` should drive a project given its type and
/// (for mixed/resume) an optional session agent id.
public enum ProjectAgentRouter {
    public static func resolveAdapterID(projectType: ProjectType,
                                        sessionAgentID: AgentID? = nil,
                                        preferredForNewChat: AgentID? = nil) -> AgentID? {
        switch projectType {
        case .mixed(let defaultAgent):
            return sessionAgentID ?? preferredForNewChat ?? defaultAgent
        case .custom:
            return sessionAgentID ?? .other
        case .folder:
            return nil
        case .claudeCode, .codex, .cursorCLI:
            // Pinned types are identity lookups via `SupportedBuiltInAgent` —
            // not a second hand-maintained AgentID map.
            return projectType.primaryAgentID
        }
    }

    public static func resolveAdapter(projectType: ProjectType,
                                      sessionAgentID: AgentID? = nil,
                                      preferredForNewChat: AgentID? = nil,
                                      registry: AdapterRegistry = .shared) async -> (any AgentAdapter)? {
        if projectType.isFolderBacked { return nil }
        if case .custom(let ref) = projectType {
            if let custom = await CustomAgentAdapterFactories.shared.makeAdapter(for: ref) {
                return custom
            }
            // Fall through to registry `.other` only when no factory matched.
        }
        guard let id = resolveAdapterID(projectType: projectType,
                                        sessionAgentID: sessionAgentID,
                                        preferredForNewChat: preferredForNewChat) else {
            return nil
        }
        return await registry.adapter(for: id)
    }
}
