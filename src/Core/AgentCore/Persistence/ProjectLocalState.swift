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
/// projects (`files` / `docs` / `modelhike` / `folderTree`).
/// Schema v4 adds `FolderProjectKind.folderTree`.
/// Schema v5 adds `FolderProjectKind.dualFolderTree` and
/// `FolderViewState.secondaryRootPath`.
/// Schema v6 adds optional `workingDirectoryPath` for agent projects whose
/// CLI cwd differs from the project folder (`ProjectRef.path`).
public struct ProjectLocalState: Sendable, Codable, Hashable {
    public static let currentSchemaVersion = 6

    public var schemaVersion: Int
    public var displayName: String
    public var projectType: ProjectType
    /// Pinned sidebar shortcuts for pin-capable folder kinds. Ignored for
    /// agent projects and `logs` (automatic shortcuts).
    public var folderView: FolderViewState?
    public var preferFreshAgentProcess: Bool
    public var agentInstanceIdentity: AgentInstanceIdentity
    /// Absolute agent working directory when it differs from the project folder.
    /// `nil` means cwd is the project folder itself. Always `nil` for folder projects.
    public var workingDirectoryPath: String?

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                displayName: String,
                projectType: ProjectType,
                folderView: FolderViewState? = nil,
                preferFreshAgentProcess: Bool = false,
                agentInstanceIdentity: AgentInstanceIdentity = .shared,
                workingDirectoryPath: String? = nil,
                projectRootPath: String? = nil) {
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.projectType = projectType
        self.folderView = Self.normalizedFolderView(folderView, for: projectType)
        self.preferFreshAgentProcess = preferFreshAgentProcess
        self.agentInstanceIdentity = agentInstanceIdentity
        self.workingDirectoryPath = Self.normalizedWorkingDirectoryPath(
            workingDirectoryPath,
            projectRootPath: projectRootPath,
            projectType: projectType
        )
    }

    public init(ref: WorkspaceProjectsStore.ProjectRef,
                folderView: FolderViewState? = nil) {
        self.init(displayName: ref.displayName,
                  projectType: ref.projectType,
                  folderView: folderView,
                  preferFreshAgentProcess: ref.preferFreshAgentProcess,
                  agentInstanceIdentity: ref.agentInstanceIdentity,
                  workingDirectoryPath: ref.workingDirectoryPath,
                  projectRootPath: ref.path)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, displayName, folderView
        case projectType = "agentMode"
        case preferFreshAgentProcess, agentInstanceIdentity, workingDirectoryPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        displayName = try c.decode(String.self, forKey: .displayName)
        projectType = try c.decode(ProjectType.self, forKey: .projectType)
        folderView = try c.decodeIfPresent(FolderViewState.self, forKey: .folderView)
        preferFreshAgentProcess = try c.decodeIfPresent(Bool.self, forKey: .preferFreshAgentProcess) ?? false
        agentInstanceIdentity = try c.decodeIfPresent(AgentInstanceIdentity.self,
                                                      forKey: .agentInstanceIdentity) ?? .shared
        // Project root is not stored in project.json; equal-to-root collapse
        // happens when overlaying onto a `ProjectRef` that knows `path`.
        workingDirectoryPath = Self.normalizedWorkingDirectoryPath(
            try c.decodeIfPresent(String.self, forKey: .workingDirectoryPath),
            projectRootPath: nil,
            projectType: projectType
        )
    }

    public static func normalizedFolderView(_ state: FolderViewState?,
                                            for projectType: ProjectType) -> FolderViewState? {
        guard let kind = projectType.folderKind else { return nil }
        let secondary = kind.usesDualTreeNavigation
            ? Self.normalizedSecondaryRootPath(state?.secondaryRootPath)
            : nil
        if kind.supportsPinnedSidebarEntries {
            let pins = FolderViewState.normalized(state?.pinnedRelativePaths ?? [])
            return FolderViewState(pinnedRelativePaths: pins, secondaryRootPath: nil)
        }
        if kind.usesDualTreeNavigation {
            // Dual trees keep only the absolute secondary root; pins are never stored.
            return FolderViewState(pinnedRelativePaths: [], secondaryRootPath: secondary)
        }
        return nil
    }

    /// Trims and keeps absolute secondary roots; relative / empty values become nil.
    public static func normalizedSecondaryRootPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    /// Absolute working-directory override for agent projects. Relative / empty
    /// values, folder-backed types, and paths equal to the project root become nil.
    public static func normalizedWorkingDirectoryPath(_ path: String?,
                                                      projectRootPath: String?,
                                                      projectType: ProjectType) -> String? {
        guard projectType.isAgentBacked else { return nil }
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
        if let projectRootPath {
            let root = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL.path
            if standardized == root { return nil }
        }
        return standardized
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
            state.workingDirectoryPath = ProjectLocalState.normalizedWorkingDirectoryPath(
                state.workingDirectoryPath,
                projectRootPath: projectRoot.path,
                projectType: state.projectType
            )
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
        normalized.workingDirectoryPath = ProjectLocalState.normalizedWorkingDirectoryPath(
            normalized.workingDirectoryPath,
            projectRootPath: projectRoot.path,
            projectType: normalized.projectType
        )
        let dir = ProjectPaths.directoryURL(in: projectRoot)
        try fileSystem.createDirectory(at: dir, withIntermediates: true)
        let data = try PersistenceJSON.encode(normalized, withoutEscapingSlashes: true)
        try fileSystem.writeAtomically(data, to: ProjectPaths.projectStateURL(in: projectRoot))
    }

    /// Writes membership metadata while preserving any existing pin list /
    /// dual secondary root when the project type still carries that state.
    ///
    /// An explicit `folderView` is caller-supplied input (project creation), so a
    /// dual compare root is validated here and rejected before it reaches disk.
    /// State already on disk is passed through untouched: a compare folder on an
    /// unmounted volume must not make rename or reconcile fail.
    public static func save(ref: WorkspaceProjectsStore.ProjectRef,
                            fileSystem: any FileSystem,
                            folderView: FolderViewState? = nil) throws {
        let root = URL(fileURLWithPath: ref.path)
        let existing = folderView ?? load(from: root, fileSystem: fileSystem)?.folderView
        var preserved = ProjectLocalState.normalizedFolderView(existing, for: ref.projectType)
        if folderView != nil, ref.projectType.folderKind?.usesDualTreeNavigation == true {
            preserved = try validatedDualFolderView(preserved,
                                                    primaryRoot: root,
                                                    fileSystem: fileSystem)
        }
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
            // Keep dual secondary roots; only clear when the kind stores neither.
            if state.projectType.folderKind?.usesDualTreeNavigation != true {
                state.folderView = nil
                try save(state, to: projectRoot, fileSystem: fileSystem)
            }
            return state.folderView
        }
        let contained = paths.compactMap { relative -> String? in
            canonicalizeRelativePath(relative, in: projectRoot, fileSystem: fileSystem)
        }
        state.folderView = FolderViewState(
            pinnedRelativePaths: FolderViewState.normalized(contained),
            secondaryRootPath: nil
        )
        try save(state, to: projectRoot, fileSystem: fileSystem)
        return state.folderView
    }

    /// Merge-safe secondary-root update for dual folder trees.
    /// Validates absolute, existing directory distinct from the primary root.
    @discardableResult
    public static func updateSecondaryRootPath(_ secondaryRoot: URL?,
                                               in projectRoot: URL,
                                               fileSystem: any FileSystem) throws -> FolderViewState? {
        guard var state = load(from: projectRoot, fileSystem: fileSystem) else {
            throw FileSystemError.notFound(path: ProjectPaths.projectStateURL(in: projectRoot).path)
        }
        guard let kind = state.projectType.folderKind, kind.usesDualTreeNavigation else {
            state.folderView = ProjectLocalState.normalizedFolderView(state.folderView,
                                                                      for: state.projectType)
            try save(state, to: projectRoot, fileSystem: fileSystem)
            return state.folderView
        }
        let validated = try secondaryRoot.map {
            try validateSecondaryRoot($0, primaryRoot: projectRoot, fileSystem: fileSystem)
        }
        state.folderView = FolderViewState(
            pinnedRelativePaths: [],
            secondaryRootPath: validated?.path
        )
        try save(state, to: projectRoot, fileSystem: fileSystem)
        return state.folderView
    }

    /// Validates a caller-supplied dual folder view. Callers that mutate other
    /// state (project registration, folder creation) run this *before* their
    /// first side effect so a bad compare folder cannot leave a half-made project.
    public static func validatedDualFolderView(_ folderView: FolderViewState?,
                                               primaryRoot: URL,
                                               fileSystem: any FileSystem) throws -> FolderViewState {
        guard let candidate = ProjectLocalState
            .normalizedSecondaryRootPath(folderView?.secondaryRootPath) else {
            throw StoreSecondaryRootError.missing
        }
        let validated = try validateSecondaryRoot(
            URL(fileURLWithPath: candidate, isDirectory: true),
            primaryRoot: primaryRoot,
            fileSystem: fileSystem
        )
        return FolderViewState(pinnedRelativePaths: [], secondaryRootPath: validated.path)
    }

    /// Returns a standardized secondary root when it is an absolute existing
    /// directory distinct from `primaryRoot`.
    public static func validateSecondaryRoot(_ secondaryRoot: URL,
                                             primaryRoot: URL,
                                             fileSystem: any FileSystem) throws -> URL {
        let secondary = secondaryRoot.standardizedFileURL
        let primary = primaryRoot.standardizedFileURL
        guard secondary.path.hasPrefix("/") else {
            throw FileSystemError.notFound(path: secondary.path)
        }
        // Collision is checked before existence: when a project folder is about to
        // be created, "same folder" is the actionable reason, not "not found".
        guard secondary.path != primary.path else {
            throw StoreSecondaryRootError.sameAsPrimary(path: secondary.path)
        }
        guard fileSystem.isDirectory(at: secondary) else {
            throw FileSystemError.notFound(path: secondary.path)
        }
        return secondary
    }

    /// Typed failure when the compare folder is missing or collides with the primary root.
    public enum StoreSecondaryRootError: Error, LocalizedError, Sendable, Equatable {
        case missing
        case sameAsPrimary(path: String)

        public var errorDescription: String? {
            switch self {
            case .missing:
                "Choose a compare folder for the dual folder tree."
            case .sameAsPrimary:
                "The compare folder must be different from the project folder."
            }
        }
    }

    /// Returns a standardized working directory when it is an absolute existing
    /// directory. Paths equal to `projectRoot` normalize to `nil` (no override).
    public static func validateWorkingDirectory(_ workingDirectory: URL?,
                                                projectRoot: URL,
                                                projectType: ProjectType,
                                                fileSystem: any FileSystem) throws -> String? {
        guard projectType.isAgentBacked else { return nil }
        guard let workingDirectory else { return nil }
        let cwd = workingDirectory.standardizedFileURL
        let root = projectRoot.standardizedFileURL
        guard cwd.path.hasPrefix("/") else {
            throw FileSystemError.notFound(path: cwd.path)
        }
        if cwd.path == root.path { return nil }
        guard fileSystem.isDirectory(at: cwd) else {
            throw FileSystemError.notFound(path: cwd.path)
        }
        return cwd.path
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
