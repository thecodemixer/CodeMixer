import Foundation
import OSLog

import AgentProtocol

/// Versioned workspace catalog stored inside the workspace folder.
///
/// Lists the projects belonging to this workspace so the membership travels
/// with the folder. Per-project type still lives in each project's
/// `.codemixer/project.json`; this file is the ordered index.
///
/// Also caches per-adapter model pickers. Claude Code's catalog is expensive
/// to refresh (print-mode probe), so it is stored here and only updated on
/// first empty load or an explicit user refresh.
public struct WorkspaceLocalState: Sendable, Codable, Hashable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var projects: [WorkspaceProjectsStore.ProjectRef]
    /// Keyed by `AgentID.rawValue`.
    public var adapterModelCaches: [String: CachedAdapterModels]

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                projects: [WorkspaceProjectsStore.ProjectRef],
                adapterModelCaches: [String: CachedAdapterModels] = [:]) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.adapterModelCaches = adapterModelCaches
    }

    public struct CachedAdapterModels: Sendable, Codable, Hashable {
        public var models: [AgentModelOption]
        public var refreshedAt: Date?

        public init(models: [AgentModelOption], refreshedAt: Date? = nil) {
            self.models = models
            self.refreshedAt = refreshedAt
        }
    }
}

/// Read/write helpers for `ProjectPaths.workspaceStateURL`.
public enum WorkspaceLocalStateStore {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "WorkspaceLocalState")

    public static func load(from workspaceRoot: URL,
                            fileSystem: any FileSystem) -> WorkspaceLocalState? {
        let url = ProjectPaths.workspaceStateURL(in: workspaceRoot)
        guard fileSystem.fileExists(at: url) else { return nil }
        do {
            let data = try fileSystem.readData(at: url)
            let probe = try JSONDecoder().decode(SchemaProbe.self, from: data)
            guard probe.schemaVersion <= WorkspaceLocalState.currentSchemaVersion else {
                log.warning("""
                    \(url.path, privacy: .public) schemaVersion \
                    \(probe.schemaVersion, privacy: .public) is newer than \
                    \(WorkspaceLocalState.currentSchemaVersion, privacy: .public); ignoring
                    """)
                return nil
            }
            return try JSONDecoder().decode(WorkspaceLocalState.self, from: data)
        } catch {
            log.warning("workspace local state load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public static func save(_ state: WorkspaceLocalState,
                            to workspaceRoot: URL,
                            fileSystem: any FileSystem) throws {
        var normalized = state
        normalized.schemaVersion = WorkspaceLocalState.currentSchemaVersion
        let dir = ProjectPaths.directoryURL(in: workspaceRoot)
        try fileSystem.createDirectory(at: dir, withIntermediates: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        try fileSystem.writeAtomically(data, to: ProjectPaths.workspaceStateURL(in: workspaceRoot))
    }

    public static func save(projects: [WorkspaceProjectsStore.ProjectRef],
                            to workspaceRoot: URL,
                            fileSystem: any FileSystem) throws {
        var state = load(from: workspaceRoot, fileSystem: fileSystem)
            ?? WorkspaceLocalState(projects: [])
        state.projects = projects
        try save(state, to: workspaceRoot, fileSystem: fileSystem)
    }

    public static func cachedModels(for agentID: AgentID,
                                    in workspaceRoot: URL,
                                    fileSystem: any FileSystem) -> WorkspaceLocalState.CachedAdapterModels? {
        load(from: workspaceRoot, fileSystem: fileSystem)?
            .adapterModelCaches[agentID.rawValue]
    }

    public static func saveModels(_ models: [AgentModelOption],
                                  for agentID: AgentID,
                                  refreshedAt: Date,
                                  in workspaceRoot: URL,
                                  fileSystem: any FileSystem) throws {
        var state = load(from: workspaceRoot, fileSystem: fileSystem)
            ?? WorkspaceLocalState(projects: [])
        state.adapterModelCaches[agentID.rawValue] = .init(
            models: models,
            refreshedAt: refreshedAt
        )
        try save(state, to: workspaceRoot, fileSystem: fileSystem)
    }

    private struct SchemaProbe: Decodable {
        var schemaVersion: Int
    }
}
