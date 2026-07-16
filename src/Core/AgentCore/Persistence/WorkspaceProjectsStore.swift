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
public actor WorkspaceProjectsStore {

    /// A project within a workspace. `agentID` is forward-compatible: today
    /// everything resolves to the single registered adapter, but a future
    /// project could pin a different agent.
    public struct ProjectRef: Sendable, Codable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public var displayName: String
        public var agentID: AgentID?

        public init(path: String, displayName: String, agentID: AgentID? = nil) {
            self.path = path
            self.displayName = displayName
            self.agentID = agentID
        }
    }

    /// Errors surfaced to the caller so the UI can show an inline message.
    public enum StoreError: Error, Sendable, Equatable {
        case invalidProjectName(String)
        case projectFolderExists(path: String)
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
    public static let currentSchemaVersion = 1

    private struct WorkspaceEntry: Codable, Hashable {
        var workspacePath: String
        var projects: [ProjectRef]
    }

    private struct Persisted: Codable {
        var schemaVersion: Int
        var workspaces: [WorkspaceEntry]
    }

    // MARK: - State

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "WorkspaceProjectsStore")
    private let fileSystem: any FileSystem
    private let url: URL
    private var workspaces: [String: [ProjectRef]] = [:]

    public init(environment: any AgentEnvironment, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.url = AppSupportPaths.workspacesURL(in: environment.appSupportDirectory)
    }

    // MARK: - Loading

    public func load() async {
        do {
            try fileSystem.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediates: true)
            guard fileSystem.fileExists(at: url) else { return }
            let data = try fileSystem.readData(at: url)
            // Forgiving decode: unknown future fields are ignored by JSONDecoder.
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
            var merged: [String: [ProjectRef]] = [:]
            var duplicatePaths: [String] = []
            for entry in persisted.workspaces {
                if merged[entry.workspacePath] != nil {
                    duplicatePaths.append(entry.workspacePath)
                }
                merged[entry.workspacePath] = entry.projects
            }
            workspaces = merged
            if !duplicatePaths.isEmpty {
                let paths = duplicatePaths.joined(separator: ", ")
                log.warning("workspaces.json duplicate workspacePath(s); last entry wins: \(paths, privacy: .public)")
                await SilentDiagnostics.shared.record(kind: .other,
                                                      owner: "WorkspaceProjectsStore",
                                                      summary: "duplicate workspacePath in workspaces.json; last entry wins",
                                                      details: paths)
            }
        } catch {
            log.warning("workspaces load failed: \(String(describing: error), privacy: .public). Using empty model.")
            await SilentDiagnostics.shared.record(kind: .workspacesQuietReset,
                                                  owner: "WorkspaceProjectsStore",
                                                  summary: "workspaces.json unreadable; using empty model",
                                                  details: String(describing: error))
        }
    }

    // MARK: - Queries

    /// The projects for a workspace, seeding the workspace root as the default
    /// project the first time the workspace is seen. Always returns at least
    /// the root project.
    public func projects(for workspace: URL) async -> [ProjectRef] {
        let key = Self.key(for: workspace)
        if let existing = workspaces[key], !existing.isEmpty { return existing }
        let root = Self.rootProject(for: workspace)
        workspaces[key] = [root]
        try? await persist()
        return [root]
    }

    // MARK: - Mutations

    /// Create a new project as `<workspace>/<name>/` and register it.
    ///
    /// - If the name is empty/`.`/`..`/contains a path separator, throws
    ///   `.invalidProjectName`.
    /// - If the folder already exists: when it's already registered, this is a
    ///   no-op that returns the existing ref; otherwise it throws
    ///   `.projectFolderExists` so the caller can confirm before adopting it.
    /// - If directory creation fails, the typed `FileSystemError` propagates and
    ///   nothing is registered.
    @discardableResult
    public func createProject(name: String, in workspace: URL) async throws -> ProjectRef {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidProjectName(trimmed) else {
            throw StoreError.invalidProjectName(name)
        }
        let folder = workspace.appendingPathComponent(trimmed, isDirectory: true)
        let key = Self.key(for: workspace)

        if fileSystem.isDirectory(at: folder) {
            if let existing = workspaces[key]?.first(where: { $0.path == folder.path }) {
                return existing  // already registered — select it.
            }
            throw StoreError.projectFolderExists(path: folder.path)
        }

        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        let ref = ProjectRef(path: folder.path, displayName: trimmed)
        try await register(ref, in: workspace)
        return ref
    }

    /// Register an existing folder (anywhere on disk) as a project of the
    /// workspace. Idempotent: re-adding returns the existing ref.
    @discardableResult
    public func addExistingProject(url projectURL: URL, in workspace: URL) async throws -> ProjectRef {
        let key = Self.key(for: workspace)
        if let existing = workspaces[key]?.first(where: { $0.path == projectURL.path }) {
            return existing
        }
        let ref = ProjectRef(path: projectURL.path,
                             displayName: projectURL.lastPathComponent)
        try await register(ref, in: workspace)
        return ref
    }

    /// Rename a project's display label. Never touches the folder on disk — the
    /// `path` (and thus the project identity) is unchanged. Returns the updated
    /// ref, or throws `.invalidProjectName` for an empty name.
    @discardableResult
    public func renameProject(path: String, to newName: String, in workspace: URL) async throws -> ProjectRef {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidProjectName(newName) }
        let key = Self.key(for: workspace)
        var list = await projects(for: workspace)
        guard let idx = list.firstIndex(where: { $0.path == path }) else {
            throw StoreError.invalidProjectName(newName)
        }
        list[idx].displayName = trimmed
        workspaces[key] = list
        try await persist()
        return list[idx]
    }

    /// Remove a project from a workspace. Never removes the folder on disk and
    /// never removes the seeded root project. Returns the removed ref (with its
    /// former index) so the caller can offer undo; returns `nil` if nothing was
    /// removed.
    @discardableResult
    public func removeProject(path: String, in workspace: URL) async throws -> RemovedProject? {
        let key = Self.key(for: workspace)
        guard var list = workspaces[key] else { return nil }
        guard path != workspace.path else { return nil }  // never drop the root.
        guard let idx = list.firstIndex(where: { $0.path == path }) else { return nil }
        let removed = list.remove(at: idx)
        workspaces[key] = list
        try await persist()
        return RemovedProject(ref: removed, index: idx)
    }

    /// Re-insert a previously removed project at its former position (undo).
    /// Idempotent: a project that is already present is left untouched.
    public func restoreProject(_ removed: RemovedProject, in workspace: URL) async throws {
        let key = Self.key(for: workspace)
        var list = await projects(for: workspace)
        guard !list.contains(where: { $0.path == removed.ref.path }) else { return }
        let clamped = min(max(removed.index, 0), list.count)
        list.insert(removed.ref, at: clamped)
        workspaces[key] = list
        try await persist()
    }

    // MARK: - Private

    private func register(_ ref: ProjectRef, in workspace: URL) async throws {
        let key = Self.key(for: workspace)
        var list = await projects(for: workspace)
        if !list.contains(where: { $0.path == ref.path }) {
            list.append(ref)
        }
        workspaces[key] = list
        try await persist()
    }

    private func persist() async throws {
        let entries = workspaces
            .map { WorkspaceEntry(workspacePath: $0.key, projects: $0.value) }
            .sorted { $0.workspacePath < $1.workspacePath }
        let persisted = Persisted(schemaVersion: Self.currentSchemaVersion, workspaces: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persisted)
        try fileSystem.writeAtomically(data, to: url)
    }

    private static func key(for workspace: URL) -> String { workspace.path }

    private static func rootProject(for workspace: URL) -> ProjectRef {
        ProjectRef(path: workspace.path,
                   displayName: workspace.lastPathComponent.isEmpty
                       ? workspace.path
                       : workspace.lastPathComponent)
    }

    private static func isValidProjectName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }
}
