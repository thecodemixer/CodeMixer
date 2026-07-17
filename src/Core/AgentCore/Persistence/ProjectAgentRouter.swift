import Foundation

/// Resolves which `AgentAdapter` should drive a project given its mode and
/// (for mixed/resume) an optional session agent id.
public enum ProjectAgentRouter {
    public static func resolveAdapterID(mode: ProjectAgentMode,
                                        sessionAgentID: AgentID? = nil,
                                        preferredForNewChat: AgentID? = nil) -> AgentID? {
        switch mode {
        case .claudeCode:
            return .claudeCode
        case .codex:
            return .codex
        case .mixed(let defaultAgent):
            return sessionAgentID ?? preferredForNewChat ?? defaultAgent
        case .custom:
            return sessionAgentID ?? .other
        }
    }

    public static func resolveAdapter(mode: ProjectAgentMode,
                                      sessionAgentID: AgentID? = nil,
                                      preferredForNewChat: AgentID? = nil,
                                      registry: AdapterRegistry = .shared) async -> (any AgentAdapter)? {
        guard let id = resolveAdapterID(mode: mode,
                                        sessionAgentID: sessionAgentID,
                                        preferredForNewChat: preferredForNewChat) else {
            return nil
        }
        return await registry.adapter(for: id)
    }
}
