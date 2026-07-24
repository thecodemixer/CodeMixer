import Foundation
import OSLog

/// Versioned workspace catalog stored inside the workspace folder.
///
/// Lists the projects belonging to this workspace so the membership travels
/// with the folder. Per-project type still lives in each project's
/// `.codemixer/project.json`; this file is the ordered index.
///
/// Provider-specific state (model catalogs, …) lives in
/// `workspace-<AgentID.rawValue>.json` — see `WorkspaceAdapterLocalState`.
public struct WorkspaceLocalState: Sendable, Codable, Hashable {
    /// Bumped when `ProjectType` gained `.folder(...)` so older builds refuse
    /// newer catalogs rather than mis-decode them.
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var projects: [WorkspaceProjectsStore.ProjectRef]

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                projects: [WorkspaceProjectsStore.ProjectRef]) {
        self.schemaVersion = schemaVersion
        self.projects = projects
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
            let schemaVersion = try PersistenceJSON.schemaVersion(in: data)
            guard schemaVersion <= WorkspaceLocalState.currentSchemaVersion else {
                log.warning("""
                    \(url.path, privacy: .public) schemaVersion \
                    \(schemaVersion, privacy: .public) is newer than \
                    \(WorkspaceLocalState.currentSchemaVersion, privacy: .public); ignoring
                    """)
                return nil
            }
            var state = try PersistenceJSON.decode(WorkspaceLocalState.self, from: data)
            state.schemaVersion = WorkspaceLocalState.currentSchemaVersion
            if schemaVersion < WorkspaceLocalState.currentSchemaVersion {
                try save(state, to: workspaceRoot, fileSystem: fileSystem)
            }
            return state
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
        let data = try PersistenceJSON.encode(normalized, withoutEscapingSlashes: true)
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

}
