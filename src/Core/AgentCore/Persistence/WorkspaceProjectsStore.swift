import Foundation
import OSLog

import AgentProtocol

/// Agent-agnostic Workspace → Projects model and its persistence.
///
/// One store, one source of truth — no facade. The nested types, state, and
/// core queries live here; three same-file-scoped extensions in this
/// directory carry the rest by concern: `+Codec` (`workspaces.json` load /
/// persist, including the legacy-schema tolerant decode), `+Mutation`
/// (create / add / rename / remove / restore / repair a project), and
/// `+AdapterCache` (per-adapter model catalog pass-through to
/// `WorkspaceAdapterLocalStateStore`).
///
/// A *workspace* is the loaded folder (one per window). Each workspace owns an
/// ordered list of `ProjectRef`s: the workspace root is seeded as the default
/// project; further projects are either created as subfolders of the workspace
/// or added from anywhere on disk. Sessions are not modelled here —
/// `SessionTranscriptRepository` owns their project-local index, so this store
/// stays agent-agnostic and contains no Claude (or terminal) specifics.
///
/// Persisted at `<appSupport>/workspaces.json` atomically through the
/// `FileSystem` seam (never `UserDefaults`, never `FileManager` directly). The
/// JSON root is versioned so older and newer builds never corrupt each other.
///
/// Each project's `projectType` is *also* written to
/// `<project>/.codemixer/project.json`, and each workspace writes its project
/// catalog to `<workspace>/.codemixer/workspace.json`. Per-adapter model
/// catalogs live in `workspace-<AgentID.rawValue>.json`. Opening restores the
/// last *active* workspace unless the user closed it.
public actor WorkspaceProjectsStore {

    /// A project within a workspace. `projectType` is required — set at creation
    /// and never silently defaulted.
    ///
    /// This is the persisted index row (`workspaces.json` / `.codemixer/project.json`),
    /// not the New/Open Project sheet draft. Sheet forms collect a separate
    /// draft type (optional `projectType`, optional folder URL); store mutations
    /// here are what produce a `ProjectRef`.
    public struct ProjectRef: Sendable, Codable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public var displayName: String
        public var projectType: ProjectType
        /// When true, opening this project replaces any parked agent slot.
        public var preferFreshAgentProcess: Bool
        /// `.shared` or `.dedicated(uuid)` for the live CLI slot identity.
        public var agentInstanceIdentity: AgentInstanceIdentity

        public init(path: String,
                    displayName: String,
                    projectType: ProjectType,
                    preferFreshAgentProcess: Bool = false,
                    agentInstanceIdentity: AgentInstanceIdentity = .shared) {
            self.path = path
            self.displayName = displayName
            self.projectType = projectType
            self.preferFreshAgentProcess = preferFreshAgentProcess
            self.agentInstanceIdentity = agentInstanceIdentity
        }

        enum CodingKeys: String, CodingKey {
            case path, displayName, projectType, preferFreshAgentProcess, agentInstanceIdentity
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            displayName = try c.decode(String.self, forKey: .displayName)
            projectType = try c.decode(ProjectType.self, forKey: .projectType)
            preferFreshAgentProcess = try c.decodeIfPresent(Bool.self, forKey: .preferFreshAgentProcess) ?? false
            agentInstanceIdentity = try c.decodeIfPresent(AgentInstanceIdentity.self,
                                                          forKey: .agentInstanceIdentity) ?? .shared
        }
    }

    /// Errors surfaced to the caller so the UI can show an inline message.
    public enum StoreError: Error, LocalizedError, Sendable, Equatable {
        case invalidProjectName(String)
        case projectFolderExists(path: String)
        case cannotRenameWorkspaceRoot(path: String)
        /// A stored project could not be decoded into the current schema
        /// (e.g. missing required `projectType`). Surfaced for repair — never
        /// silently reset or auto-assigned to Claude.
        case undecodableProject(path: String, detail: String)

        public var errorDescription: String? {
            switch self {
            case .invalidProjectName:
                "Project name is invalid."
            case .projectFolderExists(let path):
                "A folder already exists at \(path)."
            case .cannotRenameWorkspaceRoot:
                "The workspace root folder cannot be renamed from the project navigator."
            case .undecodableProject(let path, let detail):
                "Project at \(path) could not be decoded: \(detail)."
            }
        }
    }

    /// A project that was just removed, plus the index it occupied, so the UI
    /// can offer an undo that restores both the ref and its position.
    public struct RemovedProject: Sendable, Hashable {
        public let ref: ProjectRef
        public let index: Int
    }

    // MARK: - Persisted schema

    /// Current on-disk schema version. Bump when the shape changes; the decoder
    /// tolerates older versions and refuses to crash on newer ones.
    ///
    /// - v1: optional `agentID` per project (legacy)
    /// - v2: required `projectType` per project
    /// - v3: adds `activeWorkspacePath` (nil = closed / show picker on launch)
    /// - v4: `ProjectType.folder(...)` non-agent folder browser types
    /// - v5: `preferFreshAgentProcess` + `agentInstanceIdentity` on projects
    public static let currentSchemaVersion = 5

    struct WorkspaceEntry: Codable, Hashable {
        var workspacePath: String
        var projects: [ProjectRef]
    }

    struct Persisted: Codable {
        var schemaVersion: Int
        var activeWorkspacePath: String?
        var workspaces: [WorkspaceEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion, activeWorkspacePath, workspaces
        }

        init(schemaVersion: Int,
             activeWorkspacePath: String?,
             workspaces: [WorkspaceEntry]) {
            self.schemaVersion = schemaVersion
            self.activeWorkspacePath = activeWorkspacePath
            self.workspaces = workspaces
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            activeWorkspacePath = try c.decodeIfPresent(String.self, forKey: .activeWorkspacePath)
            workspaces = try c.decode([WorkspaceEntry].self, forKey: .workspaces)
        }
    }

    // MARK: - State

    /// Non-private: read/written by the `+Codec`/`+Mutation` extensions in
    /// this directory.
    let log = Logger(subsystem: AppIdentity.logSubsystem, category: "WorkspaceProjectsStore")
    let fileSystem: any FileSystem
    let url: URL
    var workspaces: [String: [ProjectRef]] = [:]
    /// Absolute path of the workspace that should reopen on next launch.
    /// `nil` means the user closed the workspace (or never opened one).
    var activeWorkspacePath: String?
    /// Projects that failed to decode. Surfaced so the UI can prompt for repair.
    /// Setter is internal, not private, so `+Codec`/`+Mutation` can update it.
    public internal(set) var decodeFailures: [StoreError] = []

    public init(environment: any AgentEnvironment, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.url = AppSupportPaths.workspacesURL(in: environment.appSupportDirectory)
    }

    // MARK: - Active workspace (launch restore)

    /// The workspace that should reopen on launch, or `nil` when closed / missing.
    public func activeWorkspaceURL() -> URL? {
        guard let path = activeWorkspacePath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard fileSystem.isDirectory(at: url) else { return nil }
        return url
    }

    /// Marks `workspace` as the open session so the next launch restores it.
    ///
    /// Does not rewrite `.codemixer/workspace.json` — that catalog is owned by
    /// create/add/remove and by `projects(for:)`. Writing it here from an
    /// unloaded empty in-memory cache would wipe child projects on Open Workspace.
    public func markActiveWorkspace(_ workspace: URL) async throws {
        activeWorkspacePath = workspace.path
        try await persist()
    }

    /// Clears the active workspace (Close Workspace). Next launch shows the landing screen.
    public func clearActiveWorkspace() async throws {
        activeWorkspacePath = nil
        try await persist()
    }

    // MARK: - Queries

    /// The projects for a workspace. Pass `rootProjectType` only when you intentionally
    /// want to seed the workspace folder itself as the first project (Open
    /// Project on a folder). Empty workspace shells created via New Workspace
    /// stay empty until New Project / Add Existing registers a project.
    public func projects(for workspace: URL,
                         rootProjectType: ProjectType? = nil) async -> [ProjectRef] {
        let key = Self.key(for: workspace)
        if let existing = workspaces[key], !existing.isEmpty {
            let reconciled = await reconcileLocalState(existing, workspaceKey: key)
            try? await persistWorkspaceLocal(projects: reconciled, for: workspace)
            return reconciled
        }

        // Prefer the workspace-local catalog when the app-support index is empty.
        if let local = WorkspaceLocalStateStore.load(from: workspace, fileSystem: fileSystem),
           !local.projects.isEmpty {
            let reconciled = await reconcileLocalState(local.projects, workspaceKey: key)
            workspaces[key] = reconciled
            try? await persist()
            return reconciled
        }

        // Prefer on-disk project state when seeding so reopening a folder that
        // already carries `.codemixer/project.json` does not require a mode pick.
        let resolvedMode = rootProjectType
            ?? ProjectLocalStateStore.load(from: workspace, fileSystem: fileSystem)?.projectType
        guard let resolvedMode else { return [] }
        let root = Self.rootProject(for: workspace, mode: resolvedMode)
        workspaces[key] = [root]
        try? await persist()
        try? ProjectLocalStateStore.save(ref: root, fileSystem: fileSystem)
        try? await persistWorkspaceLocal(projects: [root], for: workspace)
        return [root]
    }

    /// Find a project by absolute path across all loaded workspaces. This is
    /// used by engine-side `.openProject` handling so remote callers can resolve
    /// the same persisted project type as the GUI.
    public func project(path: String) async -> ProjectRef? {
        if let stored = workspaces.values.lazy
            .flatMap({ $0 })
            .first(where: { $0.path == path }) {
            return await reconcileLocalState([stored], workspaceKey: nil).first
        }
        let url = URL(fileURLWithPath: path)
        guard let local = ProjectLocalStateStore.load(from: url, fileSystem: fileSystem) else {
            return nil
        }
        return ProjectRef(path: path,
                          displayName: local.displayName,
                          projectType: local.projectType,
                          preferFreshAgentProcess: local.preferFreshAgentProcess,
                          agentInstanceIdentity: local.agentInstanceIdentity)
    }

    /// Resolves project type for a folder: project-local file first, then the
    /// in-memory / app-support index. Returns `nil` when neither knows — the
    /// UI must collect a mode before opening.
    public func resolveProjectType(for projectRoot: URL) async -> ProjectType? {
        if let local = ProjectLocalStateStore.load(from: projectRoot, fileSystem: fileSystem) {
            return local.projectType
        }
        return await project(path: projectRoot.path)?.projectType
    }

    // MARK: - Private

    /// Keeps only catalog rows whose folder carries a readable
    /// `.codemixer/project.json`, overlays that file as authoritative, and
    /// prunes stale index rows from app-support + `workspace.json` on full
    /// workspace loads.
    private func reconcileLocalState(_ refs: [ProjectRef],
                                     workspaceKey: String?) async -> [ProjectRef] {
        guard !refs.isEmpty else { return refs }
        let validated = refs.compactMap { validatedProjectRef(from: $0) }
        guard let workspaceKey else { return validated }

        let pruned = validated.count < refs.count
        let fieldsChanged = !pruned && zip(refs, validated).contains { $0 != $1 }
        guard pruned || fieldsChanged else { return validated }

        workspaces[workspaceKey] = validated
        try? await persist()
        try? await persistWorkspaceLocal(
            projects: validated,
            for: URL(fileURLWithPath: workspaceKey)
        )
        return validated
    }

    /// Returns a catalog row backed by on-disk project state, or `nil` when the
    /// folder has no readable `.codemixer/project.json`.
    private func validatedProjectRef(from catalogRef: ProjectRef) -> ProjectRef? {
        let root = URL(fileURLWithPath: catalogRef.path)
        guard let local = ProjectLocalStateStore.load(from: root, fileSystem: fileSystem) else {
            return nil
        }
        return ProjectRef(path: catalogRef.path,
                        displayName: local.displayName,
                        projectType: local.projectType,
                        preferFreshAgentProcess: local.preferFreshAgentProcess,
                        agentInstanceIdentity: local.agentInstanceIdentity)
    }

    /// Non-private: called from `+Mutation` as well as the query/reconcile
    /// paths above.
    func persistWorkspaceLocal(for workspace: URL) async throws {
        let key = Self.key(for: workspace)
        let list = workspaces[key] ?? []
        try await persistWorkspaceLocal(projects: list, for: workspace)
    }

    func persistWorkspaceLocal(projects: [ProjectRef], for workspace: URL) async throws {
        try WorkspaceLocalStateStore.save(projects: projects,
                                          to: workspace,
                                          fileSystem: fileSystem)
    }

    static func key(for workspace: URL) -> String { workspace.path }

    static func rootProject(for workspace: URL, mode: ProjectType) -> ProjectRef {
        ProjectRef(path: workspace.path,
                   displayName: workspace.lastPathComponent.isEmpty
                       ? workspace.path
                       : workspace.lastPathComponent,
                   projectType: mode)
    }
}
