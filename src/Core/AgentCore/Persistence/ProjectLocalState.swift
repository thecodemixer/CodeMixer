import Foundation
import OSLog

/// Versioned project metadata stored inside the project folder itself.
///
/// Source of truth for `projectType` when opening a folder: prefer this file
/// over app-support `workspaces.json` so the type survives moves and is
/// shareable with the repo. Schema bumps refuse newer files rather than
/// corrupt them.
///
/// On disk the field is still keyed `agentMode` (schema v1+) for compatibility.
/// Schema v2 adds optional `folderView` for pinned sidebar paths on folder
/// projects (`files` / `docs` / `modelhike`).
public struct ProjectLocalState: Sendable, Codable, Hashable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var displayName: String
    public var projectType: ProjectType
    /// Pinned sidebar shortcuts for pin-capable folder kinds. Ignored for
    /// agent projects and `logs` (automatic shortcuts).
    public var folderView: FolderViewState?

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                displayName: String,
                projectType: ProjectType,
                folderView: FolderViewState? = nil) {
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.projectType = projectType
        self.folderView = Self.normalizedFolderView(folderView, for: projectType)
    }

    public init(ref: WorkspaceProjectsStore.ProjectRef,
                folderView: FolderViewState? = nil) {
        self.init(displayName: ref.displayName,
                  projectType: ref.projectType,
                  folderView: folderView)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, displayName, folderView
        case projectType = "agentMode"
    }

    public static func normalizedFolderView(_ state: FolderViewState?,
                                            for projectType: ProjectType) -> FolderViewState? {
        guard let kind = projectType.folderKind, kind.supportsPinnedSidebarEntries else {
            return nil
        }
        guard let state else { return FolderViewState() }
        return FolderViewState(pinnedRelativePaths: FolderViewState.normalized(state.pinnedRelativePaths))
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
            let schemaVersion = try PersistenceJSON.schemaVersion(in: data)
            guard schemaVersion <= ProjectLocalState.currentSchemaVersion else {
                log.warning("""
                    \(url.path, privacy: .public) schemaVersion \
                    \(schemaVersion, privacy: .public) is newer than \
                    \(ProjectLocalState.currentSchemaVersion, privacy: .public); ignoring
                    """)
                return nil
            }
            var state = try PersistenceJSON.decode(ProjectLocalState.self, from: data)
            state.folderView = ProjectLocalState.normalizedFolderView(state.folderView,
                                                                      for: state.projectType)
            return state
        } catch {
            log.warning("project local state load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Atomically writes project state under `.codemixer/`.
    public static func save(_ state: ProjectLocalState,
                            to projectRoot: URL,
                            fileSystem: any FileSystem) throws {
        var normalized = state
        normalized.schemaVersion = ProjectLocalState.currentSchemaVersion
        normalized.folderView = ProjectLocalState.normalizedFolderView(normalized.folderView,
                                                                       for: normalized.projectType)
        let dir = ProjectPaths.directoryURL(in: projectRoot)
        try fileSystem.createDirectory(at: dir, withIntermediates: true)
        let data = try PersistenceJSON.encode(normalized, withoutEscapingSlashes: true)
        try fileSystem.writeAtomically(data, to: ProjectPaths.projectStateURL(in: projectRoot))
    }

    /// Writes membership metadata while preserving any existing pin list when
    /// the project remains a pin-capable folder kind.
    public static func save(ref: WorkspaceProjectsStore.ProjectRef,
                            fileSystem: any FileSystem) throws {
        let root = URL(fileURLWithPath: ref.path)
        let existing = load(from: root, fileSystem: fileSystem)?.folderView
        let preserved = ProjectLocalState.normalizedFolderView(existing, for: ref.projectType)
        try save(ProjectLocalState(ref: ref, folderView: preserved),
                 to: root,
                 fileSystem: fileSystem)
    }

    /// Merge-safe pin list update. Rejects absolute / empty / outside-root paths.
    @discardableResult
    public static func updatePinnedRelativePaths(_ paths: [String],
                                                 in projectRoot: URL,
                                                 fileSystem: any FileSystem) throws -> FolderViewState? {
        guard var state = load(from: projectRoot, fileSystem: fileSystem) else {
            throw FileSystemError.notFound(path: ProjectPaths.projectStateURL(in: projectRoot).path)
        }
        guard let kind = state.projectType.folderKind, kind.supportsPinnedSidebarEntries else {
            state.folderView = nil
            try save(state, to: projectRoot, fileSystem: fileSystem)
            return nil
        }
        let contained = paths.compactMap { relative -> String? in
            canonicalizeRelativePath(relative, in: projectRoot, fileSystem: fileSystem)
        }
        state.folderView = FolderViewState(pinnedRelativePaths: FolderViewState.normalized(contained))
        try save(state, to: projectRoot, fileSystem: fileSystem)
        return state.folderView
    }

    /// Returns a project-relative path when `relative` resolves inside `projectRoot`.
    public static func canonicalizeRelativePath(_ relative: String,
                                                in projectRoot: URL,
                                                fileSystem: any FileSystem) -> String? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let root = projectRoot.standardizedFileURL
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        // Prefer existing files; still allow a pin of a path that briefly vanishes.
        _ = fileSystem
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if candidatePath == rootPath { return nil }
        return String(candidatePath.dropFirst(prefix.count))
    }

}
