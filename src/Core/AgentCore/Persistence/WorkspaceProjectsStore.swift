import Foundation
import OSLog

/// Agent-agnostic Workspace → Projects model and its persistence.
///
/// A *workspace* is the loaded folder (one per window). Each workspace owns an
/// ordered list of `ProjectRef`s: the workspace root is seeded as the default
/// project; further projects are either created as subfolders of the workspace
/// or added from anywhere on disk. Sessions are not modelled here — they flow
/// through the `AgentAdapter` (`listResumableSessions`) so this store stays
/// agent-agnostic and contains no Claude (or terminal) specifics.
///
/// Persisted at `<appSupport>/workspaces.json` atomically through the
/// `FileSystem` seam (never `UserDefaults`, never `FileManager` directly). The
/// JSON root is versioned so older and newer builds never corrupt each other.
///
/// Each project's `agentMode` is *also* written to
/// `<project>/.codemixer/project.json`, and each workspace writes its project
/// catalog to `<workspace>/.codemixer/workspace.json`. Opening restores the
/// last *active* workspace unless the user closed it.
public actor WorkspaceProjectsStore {

    /// A project within a workspace. `agentMode` is required — set at creation
    /// and never silently defaulted.
    public struct ProjectRef: Sendable, Codable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public var displayName: String
        public var agentMode: ProjectAgentMode

        public init(path: String, displayName: String, agentMode: ProjectAgentMode) {
            self.path = path
            self.displayName = displayName
            self.agentMode = agentMode
        }
    }

    /// Errors surfaced to the caller so the UI can show an inline message.
    public enum StoreError: Error, Sendable, Equatable {
        case invalidProjectName(String)
        case projectFolderExists(path: String)
        /// A stored project could not be decoded into the current schema
        /// (e.g. missing required `agentMode`). Surfaced for repair — never
        /// silently reset or auto-assigned to Claude.
        case undecodableProject(path: String, detail: String)
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
    /// - v2: required `agentMode` per project
    /// - v3: adds `activeWorkspacePath` (nil = closed / show picker on launch)
    public static let currentSchemaVersion = 3

    private struct WorkspaceEntry: Codable, Hashable {
        var workspacePath: String
        var projects: [ProjectRef]
    }

    private struct Persisted: Codable {
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

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "WorkspaceProjectsStore")
    private let fileSystem: any FileSystem
    private let url: URL
    private var workspaces: [String: [ProjectRef]] = [:]
    /// Absolute path of the workspace that should reopen on next launch.
    /// `nil` means the user closed the workspace (or never opened one).
    private var activeWorkspacePath: String?
    /// Projects that failed to decode. Surfaced so the UI can prompt for repair.
    private(set) public var decodeFailures: [StoreError] = []

    public init(environment: any AgentEnvironment, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.url = AppSupportPaths.workspacesURL(in: environment.appSupportDirectory)
    }

    // MARK: - Loading

    public func load() async {
        decodeFailures = []
        do {
            try fileSystem.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediates: true)
            guard fileSystem.fileExists(at: url) else { return }
            let data = try fileSystem.readData(at: url)
            let persisted = try JSONDecoder().decode(Persisted.self, from: data)
            guard persisted.schemaVersion <= Self.currentSchemaVersion else {
                log.warning("""
                    workspaces.json schemaVersion \(persisted.schemaVersion, privacy: .public) \
                    is newer than \(Self.currentSchemaVersion, privacy: .public); ignoring to \
                    avoid corrupting a newer build's data.
                    """)
                await SilentDiagnostics.shared.record(kind: .workspacesSchemaTooNew,
                                                      owner: "WorkspaceProjectsStore",
                                                      summary: "workspaces.json schema too new; keeping in-memory model",
                                                      details: "schemaVersion=\(persisted.schemaVersion)")
                return
            }

            // Schema v1 used optional `agentID` instead of required `agentMode`.
            // We do not migrate: decode each project strictly and surface failures.
            if persisted.schemaVersion < 2 {
                let failures = try await decodeLegacyOrStrict(data: data)
                if !failures.isEmpty {
                    decodeFailures = failures
                    await SilentDiagnostics.shared.record(
                        kind: .other,
                        owner: "WorkspaceProjectsStore",
                        summary: "workspaces.json has undecodable projects; surfaced for repair",
                        details: failures.map { String(describing: $0) }.joined(separator: "; ")
                    )
                }
                return
            }

            var merged: [String: [ProjectRef]] = [:]
            var duplicatePaths: [String] = []
            for entry in persisted.workspaces {
                if merged[entry.workspacePath] != nil {
                    duplicatePaths.append(entry.workspacePath)
                }
                merged[entry.workspacePath] = entry.projects
            }
            workspaces = merged
            activeWorkspacePath = persisted.activeWorkspacePath
            if !duplicatePaths.isEmpty {
                let paths = duplicatePaths.joined(separator: ", ")
                log.warning("workspaces.json duplicate workspacePath(s); last entry wins: \(paths, privacy: .public)")
                await SilentDiagnostics.shared.record(kind: .other,
                                                      owner: "WorkspaceProjectsStore",
                                                      summary: "duplicate workspacePath in workspaces.json; last entry wins",
                                                      details: paths)
            }
        } catch {
            // Whole-file failure: surface via diagnostics and keep empty model,
            // but do not invent agent modes for any recovered project.
            log.warning("workspaces load failed: \(String(describing: error), privacy: .public). Using empty model.")
            decodeFailures = [.undecodableProject(path: url.path, detail: String(describing: error))]
            await SilentDiagnostics.shared.record(kind: .workspacesQuietReset,
                                                  owner: "WorkspaceProjectsStore",
                                                  summary: "workspaces.json unreadable; using empty model",
                                                  details: String(describing: error))
        }
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
    public func markActiveWorkspace(_ workspace: URL) async throws {
        activeWorkspacePath = workspace.path
        try await persist()
        try await persistWorkspaceLocal(for: workspace)
    }

    /// Clears the active workspace (Close Workspace). Next launch shows the landing screen.
    public func clearActiveWorkspace() async throws {
        activeWorkspacePath = nil
        try await persist()
    }

    // MARK: - Queries

    /// The projects for a workspace. Pass `rootMode` only when you intentionally
    /// want to seed the workspace folder itself as the first project (Open
    /// Project on a folder). Empty workspace shells created via New Workspace
    /// stay empty until New Project / Add Existing registers a project.
    public func projects(for workspace: URL,
                         rootMode: ProjectAgentMode? = nil) async -> [ProjectRef] {
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
        let resolvedMode = rootMode
            ?? ProjectLocalStateStore.load(from: workspace, fileSystem: fileSystem)?.agentMode
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
    /// the same persisted project mode as the GUI.
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
        return ProjectRef(path: path, displayName: local.displayName, agentMode: local.agentMode)
    }

    /// Resolves agent mode for a folder: project-local file first, then the
    /// in-memory / app-support index. Returns `nil` when neither knows — the
    /// UI must collect a mode before opening.
    public func resolveAgentMode(for projectRoot: URL) async -> ProjectAgentMode? {
        if let local = ProjectLocalStateStore.load(from: projectRoot, fileSystem: fileSystem) {
            return local.agentMode
        }
        return await project(path: projectRoot.path)?.agentMode
    }

    // MARK: - Mutations

    /// Create a new project as `<workspace>/<name>/` and register it.
    @discardableResult
    public func createProject(name: String,
                              agentMode: ProjectAgentMode,
                              in workspace: URL) async throws -> ProjectRef {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidProjectName(trimmed) else {
            throw StoreError.invalidProjectName(name)
        }
        let folder = workspace.appendingPathComponent(trimmed, isDirectory: true)
        let key = Self.key(for: workspace)

        if fileSystem.isDirectory(at: folder) {
            if let existing = workspaces[key]?.first(where: { $0.path == folder.path }) {
                return existing
            }
            throw StoreError.projectFolderExists(path: folder.path)
        }

        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        let ref = ProjectRef(path: folder.path, displayName: trimmed, agentMode: agentMode)
        try await register(ref, in: workspace, rootMode: agentMode)
        try ProjectLocalStateStore.save(ref: ref, fileSystem: fileSystem)
        return ref
    }

    /// Register an existing folder as a project of the workspace.
    @discardableResult
    public func addExistingProject(url projectURL: URL,
                                   agentMode: ProjectAgentMode,
                                   in workspace: URL) async throws -> ProjectRef {
        let key = Self.key(for: workspace)
        if let existing = workspaces[key]?.first(where: { $0.path == projectURL.path }) {
            try ProjectLocalStateStore.save(ref: existing, fileSystem: fileSystem)
            return existing
        }
        let displayName = ProjectLocalStateStore.load(from: projectURL, fileSystem: fileSystem)?.displayName
            ?? projectURL.lastPathComponent
        let ref = ProjectRef(path: projectURL.path,
                             displayName: displayName,
                             agentMode: agentMode)
        try await register(ref, in: workspace, rootMode: agentMode)
        try ProjectLocalStateStore.save(ref: ref, fileSystem: fileSystem)
        return ref
    }

    /// Repair an undecodable / mode-less project by writing a chosen mode.
    @discardableResult
    public func setAgentMode(path: String,
                             mode: ProjectAgentMode,
                             in workspace: URL) async throws -> ProjectRef {
        let key = Self.key(for: workspace)
        var list = await projects(for: workspace, rootMode: mode)
        if let idx = list.firstIndex(where: { $0.path == path }) {
            list[idx].agentMode = mode
            workspaces[key] = list
            try await persist()
            try ProjectLocalStateStore.save(ref: list[idx], fileSystem: fileSystem)
            try await persistWorkspaceLocal(projects: list, for: workspace)
            decodeFailures.removeAll {
                if case .undecodableProject(let p, _) = $0 { return p == path }
                return false
            }
            return list[idx]
        }
        let ref = ProjectRef(path: path,
                             displayName: URL(fileURLWithPath: path).lastPathComponent,
                             agentMode: mode)
        try await register(ref, in: workspace, rootMode: mode)
        try ProjectLocalStateStore.save(ref: ref, fileSystem: fileSystem)
        return ref
    }

    @discardableResult
    public func renameProject(path: String, to newName: String, in workspace: URL) async throws -> ProjectRef {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidProjectName(newName) }
        let key = Self.key(for: workspace)
        var list = workspaces[key] ?? []
        guard let idx = list.firstIndex(where: { $0.path == path }) else {
            throw StoreError.invalidProjectName(newName)
        }
        list[idx].displayName = trimmed
        workspaces[key] = list
        try await persist()
        try ProjectLocalStateStore.save(ref: list[idx], fileSystem: fileSystem)
        try await persistWorkspaceLocal(projects: list, for: workspace)
        return list[idx]
    }

    @discardableResult
    public func removeProject(path: String, in workspace: URL) async throws -> RemovedProject? {
        let key = Self.key(for: workspace)
        guard var list = workspaces[key] else { return nil }
        guard path != workspace.path else { return nil }
        guard let idx = list.firstIndex(where: { $0.path == path }) else { return nil }
        let removed = list.remove(at: idx)
        workspaces[key] = list
        try await persist()
        try await persistWorkspaceLocal(projects: list, for: workspace)
        return RemovedProject(ref: removed, index: idx)
    }

    public func restoreProject(_ removed: RemovedProject, in workspace: URL) async throws {
        let key = Self.key(for: workspace)
        var list = workspaces[key] ?? []
        guard !list.contains(where: { $0.path == removed.ref.path }) else { return }
        let clamped = min(max(removed.index, 0), list.count)
        list.insert(removed.ref, at: clamped)
        workspaces[key] = list
        try await persist()
        try await persistWorkspaceLocal(projects: list, for: workspace)
    }

    // MARK: - Private

    private func register(_ ref: ProjectRef,
                          in workspace: URL,
                          rootMode: ProjectAgentMode) async throws {
        let key = Self.key(for: workspace)
        // Do not pass `rootMode` here — that would seed the workspace folder as
        // a synthetic root project. Empty workspace shells stay empty until the
        // caller registers an explicit project (New Project / Add Existing).
        _ = rootMode
        var list = await projects(for: workspace)
        if let idx = list.firstIndex(where: { $0.path == ref.path }) {
            list[idx] = ref
        } else {
            list.append(ref)
        }
        workspaces[key] = list
        try await persist()
        try await persistWorkspaceLocal(projects: list, for: workspace)
    }

    /// Overlay project-local `.codemixer/project.json` onto in-memory refs so
    /// the folder remains authoritative for mode + display name.
    private func reconcileLocalState(_ refs: [ProjectRef],
                                     workspaceKey: String?) async -> [ProjectRef] {
        guard !refs.isEmpty else { return refs }
        var changed = false
        let updated: [ProjectRef] = refs.map { ref in
            guard let local = ProjectLocalStateStore.load(
                from: URL(fileURLWithPath: ref.path),
                fileSystem: fileSystem
            ) else { return ref }
            var next = ref
            if next.agentMode != local.agentMode {
                next.agentMode = local.agentMode
                changed = true
            }
            if next.displayName != local.displayName {
                next.displayName = local.displayName
                changed = true
            }
            return next
        }
        guard changed else { return updated }
        let key = workspaceKey ?? workspaces.first(where: { entry in
            refs.allSatisfy { ref in entry.value.contains { $0.path == ref.path } }
        })?.key
        if let key {
            // Replace only the paths we reconciled; keep sibling projects intact
            // when reconciling a single lookup.
            if let existing = workspaces[key], existing.count > updated.count {
                var merged = existing
                for ref in updated {
                    if let idx = merged.firstIndex(where: { $0.path == ref.path }) {
                        merged[idx] = ref
                    }
                }
                workspaces[key] = merged
            } else {
                workspaces[key] = updated
            }
            try? await persist()
            try? await persistWorkspaceLocal(
                projects: workspaces[key] ?? updated,
                for: URL(fileURLWithPath: key)
            )
        }
        return updated
    }

    private func persist() async throws {
        let entries = workspaces
            .map { WorkspaceEntry(workspacePath: $0.key, projects: $0.value) }
            .sorted { $0.workspacePath < $1.workspacePath }
        let persisted = Persisted(schemaVersion: Self.currentSchemaVersion,
                                  activeWorkspacePath: activeWorkspacePath,
                                  workspaces: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persisted)
        try fileSystem.writeAtomically(data, to: url)
    }

    private func persistWorkspaceLocal(for workspace: URL) async throws {
        let key = Self.key(for: workspace)
        let list = workspaces[key] ?? []
        try await persistWorkspaceLocal(projects: list, for: workspace)
    }

    private func persistWorkspaceLocal(projects: [ProjectRef], for workspace: URL) async throws {
        try WorkspaceLocalStateStore.save(projects: projects,
                                          to: workspace,
                                          fileSystem: fileSystem)
    }

    /// Attempt a strict v2 decode of each project object. Legacy v1 entries
    /// without `agentMode` become `undecodableProject` failures — never
    /// auto-migrated to Claude.
    private func decodeLegacyOrStrict(data: Data) async throws -> [StoreError] {
        struct LoosePersisted: Decodable {
            var schemaVersion: Int
            var workspaces: [LooseWorkspace]
        }
        struct LooseWorkspace: Decodable {
            var workspacePath: String
            var projects: [LooseProject]
        }
        struct LooseProject: Decodable {
            var path: String
            var displayName: String
            var agentMode: ProjectAgentMode?
            var agentID: AgentID?
        }

        let loose = try JSONDecoder().decode(LoosePersisted.self, from: data)
        var failures: [StoreError] = []
        var merged: [String: [ProjectRef]] = [:]
        for entry in loose.workspaces {
            var refs: [ProjectRef] = []
            for project in entry.projects {
                if let mode = project.agentMode {
                    refs.append(ProjectRef(path: project.path,
                                           displayName: project.displayName,
                                           agentMode: mode))
                } else {
                    failures.append(.undecodableProject(
                        path: project.path,
                        detail: "missing required agentMode (legacy agentID=\(project.agentID?.rawValue ?? "nil"))"
                    ))
                }
            }
            if !refs.isEmpty {
                merged[entry.workspacePath] = refs
            }
        }
        workspaces = merged
        return failures
    }

    private static func key(for workspace: URL) -> String { workspace.path }

    private static func rootProject(for workspace: URL, mode: ProjectAgentMode) -> ProjectRef {
        ProjectRef(path: workspace.path,
                   displayName: workspace.lastPathComponent.isEmpty
                       ? workspace.path
                       : workspace.lastPathComponent,
                   agentMode: mode)
    }

    private static func isValidProjectName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }
}
