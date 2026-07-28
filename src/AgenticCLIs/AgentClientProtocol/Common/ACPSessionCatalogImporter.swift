/// Reads the retired project-local ACP session format during the one-shot
/// existing-project import. Live ACP traffic is recorded by AgentCore instead.
import Foundation

import AgentCore

struct ACPSessionCatalogImporter: Sendable {
    let fileSystem: any FileSystem
    let clock: any AgentClock
    let random: any RandomSource

    func sessions(workspace: URL, customAgentID: String) throws -> [ImportedSession] {
        let root = workspace.standardizedFileURL
        let url = ACPProjectPaths.sessionsIndexURL(
            projectRoot: root,
            customAgentID: customAgentID
        )
        guard fileSystem.fileExists(at: url) else { return [] }
        let store = try ACPSessionStoreCodec.makeDecoder().decode(
            ACPSessionStoreCodec.Store.self,
            from: fileSystem.readData(at: url)
        )
        return store.entries
            .filter {
                $0.customAgentID == customAgentID
                    && $0.workspacePath == root.path
            }
            .map { entry in
                ImportedSession(
                    id: entry.id,
                    title: entry.title,
                    lastActivity: entry.lastActivity,
                    archived: entry.flags.archived,
                    isOverview: entry.flags.isOverview,
                    overviewURL: entry.flags.overviewURL,
                    events: ACPSessionStoreCodec.events(
                        from: entry.turns,
                        sessionID: entry.id,
                        clock: clock,
                        random: random
                    )
                )
            }
            .sorted {
                ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
    }
}
