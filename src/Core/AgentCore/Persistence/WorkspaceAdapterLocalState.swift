import Foundation
import OSLog

import AgentProtocol

/// Per-adapter workspace state under `.codemixer/workspace-<AgentID>.json`.
///
/// Today this holds the composer model catalog. Future provider-specific
/// fields are additive optional properties on this same struct (bump
/// `schemaVersion` when needed). Common membership stays in `workspace.json`.
public struct WorkspaceAdapterLocalState: Sendable, Codable, Hashable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var models: [AgentModelOption]
    public var refreshedAt: Date?

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                models: [AgentModelOption],
                refreshedAt: Date? = nil) {
        self.schemaVersion = schemaVersion
        self.models = models
        self.refreshedAt = refreshedAt
    }

    /// Snapshot shape returned by cache lookups (models + stamp).
    public struct CachedAdapterModels: Sendable, Codable, Hashable {
        public var models: [AgentModelOption]
        public var refreshedAt: Date?

        public init(models: [AgentModelOption], refreshedAt: Date? = nil) {
            self.models = models
            self.refreshedAt = refreshedAt
        }
    }
}

/// Read/write helpers for `ProjectPaths.workspaceAdapterStateURL`.
public enum WorkspaceAdapterLocalStateStore {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "WorkspaceAdapterLocalState")

    public static func load(for agentID: AgentID,
                            in workspaceRoot: URL,
                            fileSystem: any FileSystem) -> WorkspaceAdapterLocalState? {
        let url = ProjectPaths.workspaceAdapterStateURL(in: workspaceRoot, agentID: agentID)
        guard fileSystem.fileExists(at: url) else { return nil }
        do {
            let data = try fileSystem.readData(at: url)
            let schemaVersion = try PersistenceJSON.schemaVersion(in: data)
            guard schemaVersion <= WorkspaceAdapterLocalState.currentSchemaVersion else {
                log.warning("""
                    \(url.path, privacy: .public) schemaVersion \
                    \(schemaVersion, privacy: .public) is newer than \
                    \(WorkspaceAdapterLocalState.currentSchemaVersion, privacy: .public); ignoring
                    """)
                return nil
            }
            return try PersistenceJSON.decode(WorkspaceAdapterLocalState.self, from: data)
        } catch {
            log.warning("workspace adapter state load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public static func save(_ state: WorkspaceAdapterLocalState,
                            for agentID: AgentID,
                            in workspaceRoot: URL,
                            fileSystem: any FileSystem) throws {
        var normalized = state
        normalized.schemaVersion = WorkspaceAdapterLocalState.currentSchemaVersion
        let dir = ProjectPaths.directoryURL(in: workspaceRoot)
        try fileSystem.createDirectory(at: dir, withIntermediates: true)
        let data = try PersistenceJSON.encode(normalized, withoutEscapingSlashes: true)
        try fileSystem.writeAtomically(
            data,
            to: ProjectPaths.workspaceAdapterStateURL(in: workspaceRoot, agentID: agentID)
        )
    }

    public static func cachedModels(for agentID: AgentID,
                                    in workspaceRoot: URL,
                                    fileSystem: any FileSystem) -> WorkspaceAdapterLocalState.CachedAdapterModels? {
        guard let state = load(for: agentID, in: workspaceRoot, fileSystem: fileSystem) else {
            return nil
        }
        return .init(models: state.models, refreshedAt: state.refreshedAt)
    }

    public static func saveModels(_ models: [AgentModelOption],
                                  for agentID: AgentID,
                                  refreshedAt: Date,
                                  in workspaceRoot: URL,
                                  fileSystem: any FileSystem) throws {
        try save(
            WorkspaceAdapterLocalState(models: models, refreshedAt: refreshedAt),
            for: agentID,
            in: workspaceRoot,
            fileSystem: fileSystem
        )
    }

}
