import Foundation
import OSLog

/// Versioned workspace catalog stored inside the workspace folder.
///
/// Lists the projects belonging to this workspace so the membership travels
/// with the folder. Per-project type still lives in each project's
/// `.codemixer/project.json`; this file is the ordered index.
public struct WorkspaceLocalState: Sendable, Codable, Hashable {
    public static let currentSchemaVersion = 1

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
        let dir = ProjectPaths.directoryURL(in: workspaceRoot)
        try fileSystem.createDirectory(at: dir, withIntermediates: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try fileSystem.writeAtomically(data, to: ProjectPaths.workspaceStateURL(in: workspaceRoot))
    }

    public static func save(projects: [WorkspaceProjectsStore.ProjectRef],
                            to workspaceRoot: URL,
                            fileSystem: any FileSystem) throws {
        try save(WorkspaceLocalState(projects: projects),
                 to: workspaceRoot,
                 fileSystem: fileSystem)
    }

    private struct SchemaProbe: Decodable {
        var schemaVersion: Int
    }
}
