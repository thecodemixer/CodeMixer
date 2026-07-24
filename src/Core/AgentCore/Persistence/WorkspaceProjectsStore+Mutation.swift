import Foundation

/// Create / add / rename / remove / restore / repair a project. Every
/// mutation that changes `workspaces` persists both the app-support index
/// (`persist()`) and the workspace-local catalog (`persistWorkspaceLocal`).
extension WorkspaceProjectsStore {
    /// Create a new project as `<workspace>/<name>/` and register it.
    @discardableResult
    public func createProject(name: String,
                              projectType: ProjectType,
                              preferFreshAgentProcess: Bool = false,
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
        let identity: AgentInstanceIdentity = preferFreshAgentProcess
            ? .dedicated(UUID())
            : .shared
        let ref = ProjectRef(path: folder.path,
                             displayName: trimmed,
                             projectType: projectType,
                             preferFreshAgentProcess: preferFreshAgentProcess,
                             agentInstanceIdentity: identity)
        try await register(ref, in: workspace, rootProjectType: projectType)
        try ProjectLocalStateStore.save(ref: ref, fileSystem: fileSystem)
        return ref
    }

    /// Register an existing folder as a project of the workspace.
    @discardableResult
    public func addExistingProject(url projectURL: URL,
                                   projectType: ProjectType,
                                   displayName: String? = nil,
                                   preferFreshAgentProcess: Bool = false,
                                   in workspace: URL) async throws -> ProjectRef {
        let key = Self.key(for: workspace)
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String = {
            if let trimmedName, !trimmedName.isEmpty { return trimmedName }
            return ProjectLocalStateStore.load(from: projectURL, fileSystem: fileSystem)?.displayName
                ?? projectURL.lastPathComponent
        }()
        let identity: AgentInstanceIdentity = preferFreshAgentProcess
            ? .dedicated(UUID())
            : .shared
        if let existing = workspaces[key]?.first(where: { $0.path == projectURL.path }) {
            let updated = ProjectRef(path: existing.path,
                                     displayName: resolvedName,
                                     projectType: projectType,
                                     preferFreshAgentProcess: preferFreshAgentProcess,
                                     agentInstanceIdentity: identity)
            try await register(updated, in: workspace, rootProjectType: projectType)
            try ProjectLocalStateStore.save(ref: updated, fileSystem: fileSystem)
            return updated
        }
        let ref = ProjectRef(path: projectURL.path,
                             displayName: resolvedName,
                             projectType: projectType,
                             preferFreshAgentProcess: preferFreshAgentProcess,
                             agentInstanceIdentity: identity)
        try await register(ref, in: workspace, rootProjectType: projectType)
        try ProjectLocalStateStore.save(ref: ref, fileSystem: fileSystem)
        return ref
    }

    /// Repair an undecodable / type-less project by writing a chosen project type.
    @discardableResult
    public func setProjectType(path: String,
                             projectType: ProjectType,
                             in workspace: URL) async throws -> ProjectRef {
        let key = Self.key(for: workspace)
        var list = await projects(for: workspace, rootProjectType: projectType)
        if let idx = list.firstIndex(where: { $0.path == path }) {
            list[idx].projectType = projectType
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
                             projectType: projectType)
        try await register(ref, in: workspace, rootProjectType: projectType)
        try ProjectLocalStateStore.save(ref: ref, fileSystem: fileSystem)
        return ref
    }

    /// Persist Advanced → Launch new agent instance for an existing project.
    @discardableResult
    public func setAgentLaunchPreference(path: String,
                                         preferFreshAgentProcess: Bool,
                                         agentInstanceIdentity: AgentInstanceIdentity = .shared,
                                         in workspace: URL) async throws -> ProjectRef {
        let key = Self.key(for: workspace)
        var list: [ProjectRef]
        if let existing = workspaces[key] {
            list = existing
        } else {
            list = await projects(for: workspace)
        }
        guard let idx = list.firstIndex(where: { $0.path == path }) else {
            throw StoreError.undecodableProject(path: path, detail: "project not in workspace index")
        }
        let identity: AgentInstanceIdentity
        if preferFreshAgentProcess {
            if case .dedicated = agentInstanceIdentity {
                identity = agentInstanceIdentity
            } else if case .dedicated = list[idx].agentInstanceIdentity {
                identity = list[idx].agentInstanceIdentity
            } else {
                identity = .dedicated(UUID())
            }
        } else {
            identity = .shared
        }
        list[idx].preferFreshAgentProcess = preferFreshAgentProcess
        list[idx].agentInstanceIdentity = identity
        workspaces[key] = list
        try await persist()
        try ProjectLocalStateStore.save(ref: list[idx], fileSystem: fileSystem)
        try await persistWorkspaceLocal(projects: list, for: workspace)
        return list[idx]
    }

    @discardableResult
    public func renameProject(path: String, to newName: String, in workspace: URL) async throws -> ProjectRef {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidProjectName(trimmed) else { throw StoreError.invalidProjectName(newName) }
        guard path != workspace.path else { throw StoreError.cannotRenameWorkspaceRoot(path: path) }
        let key = Self.key(for: workspace)
        var list = workspaces[key] ?? []
        guard let idx = list.firstIndex(where: { $0.path == path }) else {
            throw StoreError.invalidProjectName(newName)
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let renamedFolder = folder
            .deletingLastPathComponent()
            .appendingPathComponent(trimmed, isDirectory: true)
        if renamedFolder.path != folder.path {
            guard !fileSystem.fileExists(at: renamedFolder) else {
                throw StoreError.projectFolderExists(path: renamedFolder.path)
            }
            // Foundation exposes same-parent folder renames as `moveItem`.
            try fileSystem.move(from: folder, to: renamedFolder)
        }

        let renamed = ProjectRef(path: renamedFolder.path,
                                 displayName: trimmed,
                                 projectType: list[idx].projectType)
        list[idx] = renamed
        workspaces[key] = list
        try await persist()
        try ProjectLocalStateStore.save(ref: renamed, fileSystem: fileSystem)
        try await persistWorkspaceLocal(projects: list, for: workspace)
        return renamed
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

    private func register(_ ref: ProjectRef,
                          in workspace: URL,
                          rootProjectType: ProjectType) async throws {
        let key = Self.key(for: workspace)
        // Do not pass `rootProjectType` here — that would seed the workspace folder as
        // a synthetic root project. Empty workspace shells stay empty until the
        // caller registers an explicit project (New Project / Add Existing).
        _ = rootProjectType
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

    private static func isValidProjectName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }
}
