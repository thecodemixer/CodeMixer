import Foundation
import OSLog

/// Versioned project metadata stored inside the project folder itself.
///
/// Source of truth for `agentMode` when opening a folder: prefer this file over
/// app-support `workspaces.json` so mode survives moves and is shareable with
/// the repo. Schema bumps refuse newer files rather than corrupt them.
public struct ProjectLocalState: Sendable, Codable, Hashable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var displayName: String
    public var agentMode: ProjectAgentMode

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                displayName: String,
                agentMode: ProjectAgentMode) {
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.agentMode = agentMode
    }

    public init(ref: WorkspaceProjectsStore.ProjectRef) {
        self.init(displayName: ref.displayName, agentMode: ref.agentMode)
    }
}

/// Read/write helpers for `ProjectPaths.projectStateURL`.
public enum ProjectLocalStateStore {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "ProjectLocalState")

    /// Loads project state when present and readable. Returns `nil` when the
    /// file is absent, newer than we understand, or undecodable.
    public static func load(from projectRoot: URL,
                            fileSystem: any FileSystem) -> ProjectLocalState? {
        let url = ProjectPaths.projectStateURL(in: projectRoot)
        guard fileSystem.fileExists(at: url) else { return nil }
        do {
            let data = try fileSystem.readData(at: url)
            let probe = try JSONDecoder().decode(SchemaProbe.self, from: data)
            guard probe.schemaVersion <= ProjectLocalState.currentSchemaVersion else {
                log.warning("""
                    \(url.path, privacy: .public) schemaVersion \
                    \(probe.schemaVersion, privacy: .public) is newer than \
                    \(ProjectLocalState.currentSchemaVersion, privacy: .public); ignoring
                    """)
                return nil
            }
            return try JSONDecoder().decode(ProjectLocalState.self, from: data)
        } catch {
            log.warning("project local state load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Atomically writes project state under `.codemixer/`.
    public static func save(_ state: ProjectLocalState,
                            to projectRoot: URL,
                            fileSystem: any FileSystem) throws {
        let dir = ProjectPaths.directoryURL(in: projectRoot)
        try fileSystem.createDirectory(at: dir, withIntermediates: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try fileSystem.writeAtomically(data, to: ProjectPaths.projectStateURL(in: projectRoot))
    }

    public static func save(ref: WorkspaceProjectsStore.ProjectRef,
                            fileSystem: any FileSystem) throws {
        try save(ProjectLocalState(ref: ref),
                 to: URL(fileURLWithPath: ref.path),
                 fileSystem: fileSystem)
    }

    private struct SchemaProbe: Decodable {
        var schemaVersion: Int
    }
}
