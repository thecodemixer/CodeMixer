import Foundation

import AgentProtocol

/// Per-adapter model catalog pass-through to `WorkspaceAdapterLocalStateStore`
/// (`workspace-<AgentID>.json`). Kept separate from the project-list
/// mutations above: this cache is adapter-scoped, not project-scoped, and has
/// its own TTL/staleness rules documented on `WorkspaceAdapterLocalState`.
extension WorkspaceProjectsStore {
    public func cachedModels(for agentID: AgentID,
                             in workspace: URL) -> WorkspaceAdapterLocalState.CachedAdapterModels? {
        WorkspaceAdapterLocalStateStore.cachedModels(
            for: agentID,
            in: workspace,
            fileSystem: fileSystem
        )
    }

    public func saveModels(_ models: [AgentModelOption],
                           for agentID: AgentID,
                           refreshedAt: Date,
                           in workspace: URL) throws {
        try WorkspaceAdapterLocalStateStore.saveModels(
            models,
            for: agentID,
            refreshedAt: refreshedAt,
            in: workspace,
            fileSystem: fileSystem
        )
    }
}
