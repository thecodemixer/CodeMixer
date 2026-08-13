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
                              folderView: FolderViewState? = nil,
                              webPages: WebPagesProjectConfig? = nil,
                              workingDirectory: URL? = nil,
                              in workspace: URL) async throws -> ProjectRef {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidProjectName(trimmed) else {
            throw StoreError.invalidProjectName(name)
        }
        let folder = workspace.appendingPathComponent(trimmed, isDirectory: true)
        let key = Self.key(for: workspace)

        // Validate before creating the folder so a rejected compare root leaves
        // nothing behind.
        if projectType.folderKind?.usesDualTreeNavigation == true {
            _ = try ProjectLocalStateStore.validatedDualFolderView(folderView,
                                                                   primaryRoot: folder,
                                                                   fileSystem: fileSystem)
        }
        let resolvedWebPages: WebPagesProjectConfig?
        if projectType.isWebPagesBacked {
            guard let webPages else {
                throw StoreError.missingWebPagesConfiguration(name: trimmed)
            }
            resolvedWebPages = webPages
        } else {
            resolvedWebPages = nil
        }
        let cwdPath = try ProjectLocalStateStore.validateWorkingDirectory(
            workingDirectory,
            projectRoot: folder,
            projectType: projectType,
            fileSystem: fileSystem
        )

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
                             agentInstanceIdentity: identity,
                             workingDirectoryPath: cwdPath)
        try await register(ref, in: workspace, rootProjectType: projectType)
        try ProjectLocalStateStore.save(ref: ref,
                                        fileSystem: fileSystem,
                                        folderView: folderView,
                                        webPages: resolvedWebPages)
        return ref
    }

    /// Register an existing folder as a project of the workspace.
    @discardableResult
    public func addExistingProject(url projectURL: URL,
                                   projectType: ProjectType,
                                   displayName: String? = nil,
                                   preferFreshAgentProcess: Bool = false,
                                   folderView: FolderViewState? = nil,
                                   webPages: WebPagesProjectConfig? = nil,
                                   workingDirectory: URL? = nil,
                                   in workspace: URL) async throws -> ProjectRef {
        let key = Self.key(for: workspace)
        if projectType.folderKind?.usesDualTreeNavigation == true {
            _ = try ProjectLocalStateStore.validatedDualFolderView(folderView,
                                                                   primaryRoot: projectURL,
                                                                   fileSystem: fileSystem)
        }
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String = {
            if let trimmedName, !trimmedName.isEmpty { return trimmedName }
            return ProjectLocalStateStore.load(from: projectURL, fileSystem: fileSystem)?.displayName
                ?? projectURL.lastPathComponent
        }()
        let identity: AgentInstanceIdentity = preferFreshAgentProcess
            ? .dedicated(UUID())
            : .shared
        // Preserve on-disk session store when re-adding a web-pages project.
        let resolvedWebPages: WebPagesProjectConfig?
        if projectType.isWebPagesBacked {
            if let webPages {
                resolvedWebPages = webPages
            } else if let existing = ProjectLocalStateStore.load(from: projectURL,
                                                                 fileSystem: fileSystem)?.webPages {
                resolvedWebPages = existing
            } else {
                throw StoreError.missingWebPagesConfiguration(name: resolvedName)
            }
        } else {
            resolvedWebPages = nil
        }
        if let existing = workspaces[key]?.first(where: { $0.path == projectURL.path }) {
            let cwdPath: String?
            if workingDirectory != nil {
                cwdPath = try ProjectLocalStateStore.validateWorkingDirectory(
                    workingDirectory,
                    projectRoot: projectURL,
                    projectType: projectType,
                    fileSystem: fileSystem
                )
            } else {
                cwdPath = existing.workingDirectoryPath
            }
            let updated = ProjectRef(path: existing.path,
                                     displayName: resolvedName,
                                     projectType: projectType,
                                     preferFreshAgentProcess: preferFreshAgentProcess,
                                     agentInstanceIdentity: identity,
                                     workingDirectoryPath: cwdPath)
            try await register(updated, in: workspace, rootProjectType: projectType)
            try ProjectLocalStateStore.save(ref: updated,
                                            fileSystem: fileSystem,
                                            folderView: folderView,
                                            webPages: resolvedWebPages)
            return updated
        }
        let cwdPath = try ProjectLocalStateStore.validateWorkingDirectory(
            workingDirectory,
            projectRoot: projectURL,
            projectType: projectType,
            fileSystem: fileSystem
        )
        let ref = ProjectRef(path: projectURL.path,
                             displayName: resolvedName,
                             projectType: projectType,
                             preferFreshAgentProcess: preferFreshAgentProcess,
                             agentInstanceIdentity: identity,
                             workingDirectoryPath: cwdPath)
        try await register(ref, in: workspace, rootProjectType: projectType)
        try ProjectLocalStateStore.save(ref: ref,
                                        fileSystem: fileSystem,
                                        folderView: folderView,
                                        webPages: resolvedWebPages)
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
            let previous = list[idx]
            list[idx] = ProjectRef(
                path: previous.path,
                displayName: previous.displayName,
                projectType: projectType,
                preferFreshAgentProcess: previous.preferFreshAgentProcess,
                agentInstanceIdentity: previous.agentInstanceIdentity,
                workingDirectoryPath: previous.workingDirectoryPath
            )
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
        let previous = list[idx]
        list[idx] = ProjectRef(
            path: previous.path,
            displayName: previous.displayName,
            projectType: previous.projectType,
            preferFreshAgentProcess: preferFreshAgentProcess,
            agentInstanceIdentity: identity,
            workingDirectoryPath: previous.workingDirectoryPath
        )
        workspaces[key] = list
        try await persist()
        try ProjectLocalStateStore.save(ref: list[idx], fileSystem: fileSystem)
        try await persistWorkspaceLocal(projects: list, for: workspace)
        return list[idx]
    }

    /// Persist an optional agent working-directory override for an existing project.
    ///
    /// Takes effect the next time that project's agent starts. Pass `nil` (or
    /// the project folder itself) to clear the override.
    @discardableResult
    public func setWorkingDirectory(path: String,
                                    to workingDirectory: URL?,
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
        let previous = list[idx]
        let projectRoot = URL(fileURLWithPath: previous.path, isDirectory: true)
        let cwdPath = try ProjectLocalStateStore.validateWorkingDirectory(
            workingDirectory,
            projectRoot: projectRoot,
            projectType: previous.projectType,
            fileSystem: fileSystem
        )
        list[idx] = ProjectRef(
            path: previous.path,
            displayName: previous.displayName,
            projectType: previous.projectType,
            preferFreshAgentProcess: previous.preferFreshAgentProcess,
            agentInstanceIdentity: previous.agentInstanceIdentity,
            workingDirectoryPath: cwdPath
        )
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

        let previous = list[idx]
        let projectType = Self.projectTypeUpdatingCustomDisplayName(
            previous.projectType,
            displayName: trimmed
        )
        let renamed = ProjectRef(
            path: renamedFolder.path,
            displayName: trimmed,
            projectType: projectType,
            preferFreshAgentProcess: previous.preferFreshAgentProcess,
            agentInstanceIdentity: previous.agentInstanceIdentity,
            workingDirectoryPath: previous.workingDirectoryPath
        )
        list[idx] = renamed
        workspaces[key] = list
        try await persist()
        try ProjectLocalStateStore.save(ref: renamed, fileSystem: fileSystem)
        try await persistWorkspaceLocal(projects: list, for: workspace)
        return renamed
    }

    /// Custom agent nickname tracks the project display name (there is no
    /// separate Custom "Display name" field in New Project).
    private static func projectTypeUpdatingCustomDisplayName(_ type: ProjectType,
                                                             displayName: String) -> ProjectType {
        guard case .custom(let ref) = type else { return type }
        return .custom(CustomAgentRef(
            id: ref.id,
            displayName: displayName,
            transport: ref.transport,
            executablePath: ref.executablePath,
            arguments: ref.arguments
        ))
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
