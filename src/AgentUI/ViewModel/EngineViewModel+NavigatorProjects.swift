import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {
    // MARK: - Session navigator actions

    /// Awaitable variant for startup restore and other flows that must not flash
    /// an empty navigator before the project list is ready.
    public func reloadProjects(rootProjectType: ProjectType? = nil) async {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        let refs = await store.projects(for: workspaceRoot, rootProjectType: rootProjectType)
        await applyProjectList(refs)
    }

    func projectRef(at path: String) -> WorkspaceProjectsStore.ProjectRef? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return projects.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardized
        }
    }

    /// Bind the active project and arm the adapter's session-handshake composer
    /// gate before engine spawn so an early send cannot race protocol bootstrap.
    public func prepareProjectOpen(url: URL, projectType: ProjectType) async {
        let target = url.standardizedFileURL
        workspaceRoot = target
        workspace = target
        let needsGate = await Self.adapterRequiresSessionHandshakeGate(projectType)
        let supportsOverview = await Self.adapterSupportsOverviewDashboard(projectType)
        if var caps = projectCapabilities[target.path] {
            caps.requiresSessionHandshakeGate = needsGate
            caps.supportsOverviewDashboard = supportsOverview
            projectCapabilities[target.path] = caps
        } else {
            projectCapabilities[target.path] = .init(
                supportsResumableSessions: false,
                requiresSessionHandshakeGate: needsGate,
                supportsOverviewDashboard: supportsOverview
            )
        }
        if needsGate {
            lockComposerForSessionHandshake()
        }
    }

    /// Create a new project (subfolder of the workspace) and switch to it.
    /// Blocks until the project is registered and its model catalog is ready.
    public func createProject(name: String, projectType: ProjectType) async {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        do {
            let ref = try await store.createProject(name: name, projectType: projectType, in: workspaceRoot)
            if !projectType.isFolderBacked {
                try await WorkspaceLifecycle(model: self).ensureModels(for: projectType)
            }
            let refs = await store.projects(for: workspaceRoot, rootProjectType: projectType)
            await applyProjectList(refs)
            if projectType.isFolderBacked {
                openFolderProject(ref, relativePath: nil)
            } else {
                applyAdapterCapabilities(for: projectType, projectURL: URL(fileURLWithPath: ref.path))
                newChat(in: ref.path)
            }
        } catch {
            recordProjectError(error)
        }
    }

    /// Register an existing folder as a project of the workspace.
    /// Blocks until the project is registered and its model catalog is ready.
    public func addExistingProject(url: URL,
                                   projectType: ProjectType,
                                   displayName: String? = nil) async {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        do {
            let ref = try await store.addExistingProject(
                url: url,
                projectType: projectType,
                displayName: displayName,
                in: workspaceRoot
            )
            if !projectType.isFolderBacked {
                try await WorkspaceLifecycle(model: self).ensureModels(for: projectType)
            }
            let refs = await store.projects(for: workspaceRoot, rootProjectType: projectType)
            await applyProjectList(refs)
            if projectType.isFolderBacked {
                openFolderProject(ref, relativePath: nil)
            } else {
                applyAdapterCapabilities(for: projectType, projectURL: URL(fileURLWithPath: ref.path))
                newChat(in: ref.path)
            }
        } catch {
            recordProjectError(error)
        }
    }

    /// Rename a project and its folder on disk.
    public func renameProject(path: String, newName: String) {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        let renamesActiveProject = workspace?.path == path
        guard activity == .idle else {
            diagnostics.append(diagnostic(
                level: .error,
                message: "Wait for the current turn to finish before renaming a project."
            ))
            return
        }
        let resumeSessionID = sessionID.flatMap { $0.isEmpty ? nil : $0 }
        Task { [weak self] in
            do {
                let renamed = try await store.renameProject(path: path, to: newName, in: workspaceRoot)
                let refs = await store.projects(for: workspaceRoot)
                let capabilities = await Self.projectCapabilityIndex(for: refs)
                await MainActor.run {
                    self?.projects = refs
                    self?.projectCapabilities = capabilities
                    self?.applyRenamedProjectPath(from: path, to: renamed.path)
                    if renamesActiveProject {
                        self?.send(.openProject(path: renamed.path, resumeSessionID: resumeSessionID))
                    }
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Remove a project from the navigator (never deletes the folder) and arm an
    /// undo toast. The seeded root cannot be removed.
    public func removeProject(path: String) {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let removed = try await store.removeProject(path: path, in: workspaceRoot)
                let refs = await store.projects(for: workspaceRoot)
                let capabilities = await Self.projectCapabilityIndex(for: refs)
                await MainActor.run {
                    self?.projects = refs
                    self?.projectCapabilities = capabilities
                    if let removed { self?.armRemovedProjectUndo(removed) }
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Restore the most recently removed project at its former position.
    /// Blocks until the project is restored and its model catalog is ready.
    public func undoRemoveProject() async {
        guard let workspaceRoot, let store = workspaceProjects,
              let removed = removedProjectUndo else { return }
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        removedProjectUndo = nil
        do {
            try await store.restoreProject(removed, in: workspaceRoot)
            try await WorkspaceLifecycle(model: self).ensureModels(for: removed.ref.projectType)
            let refs = await store.projects(for: workspaceRoot)
            await applyProjectList(refs)
        } catch {
            recordProjectError(error)
        }
    }

    func armRemovedProjectUndo(_ removed: WorkspaceProjectsStore.RemovedProject) {
        removedProjectUndoTask?.cancel()
        removedProjectUndo = removed
        removedProjectUndoTask = Task { [weak self] in
            try? await self?.clock.sleep(for: ActivityTiming.undoToastWindow)
            await MainActor.run { self?.removedProjectUndo = nil }
        }
    }

    func applyRenamedProjectPath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        if workspace?.path == oldPath {
            workspace = URL(fileURLWithPath: newPath, isDirectory: true)
        }
        if let sessions = sessionsByProject.removeValue(forKey: oldPath) {
            sessionsByProject[newPath] = sessions
        }
        if loadingProjectPaths.remove(oldPath) != nil {
            loadingProjectPaths.insert(newPath)
        }
        projectCapabilities.rekey(from: oldPath, to: newPath)
    }

    func recordProjectError(_ error: any Error) {
        let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
        diagnostics.append(diagnostic(level: .error, message: message))
    }

    /// Opens a freshly created workspace folder without starting an agent.
    /// Project type is chosen later via File → New Project…
    /// Awaits model-catalog warm so callers can gate the UI until catalogs are ready.
    public func adoptEmptyWorkspace(_ url: URL) async throws {
        endSessionSwitch()
        workspaceRoot = url
        workspace = nil
        sessionID = nil
        projects = []
        sessionsByProject = [:]
        projectCapabilities.removeAll()
        loadingProjectPaths = []
        folderPinnedPathsByProject = [:]
        folderAutomaticShortcutsByProject = [:]
        clearFolderBrowserSurface()
        removedProjectUndo = nil
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        unlockComposerForSessionResume()
        clearConversationState()
        changedFiles = []
        clearAllPendingPermissions()
        status = .idle
        activity = .idle
        sessionTokens = 0
        sessionCostUSD = nil
        availableModels = []
        availableAgentModes = []
        selectedAgentModeID = ""
        slashCommands = []
        await reloadProjects()
        try await warmWorkspaceModelCatalogs()
    }

    /// Clears navigator + conversation chrome after File → Close Workspace.
    public func resetForClosedWorkspace() {
        endSessionSwitch()
        workspaceRoot = nil
        workspace = nil
        sessionID = nil
        projects = []
        sessionsByProject = [:]
        projectCapabilities.removeAll()
        loadingProjectPaths = []
        folderPinnedPathsByProject = [:]
        folderAutomaticShortcutsByProject = [:]
        clearFolderBrowserSurface()
        removedProjectUndo = nil
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        unlockComposerForSessionResume()
        clearConversationState()
        changedFiles = []
        clearAllPendingPermissions()
        status = .idle
        activity = .idle
        sessionTokens = 0
        sessionCostUSD = nil
        availableModels = []
        availableAgentModes = []
        selectedAgentModeID = ""
        workspaceModelCatalogRows = []
        slashCommands = []
    }

    func applyProjectList(_ refs: [WorkspaceProjectsStore.ProjectRef]) async {
        projects = refs
        projectCapabilities = await Self.projectCapabilityIndex(for: refs)
        for ref in refs where ref.projectType.isFolderBacked {
            refreshFolderSidebarShortcuts(for: ref)
        }
    }

    private static func projectCapabilityIndex(
        for refs: [WorkspaceProjectsStore.ProjectRef]
    ) async -> ProjectCapabilityIndex {
        var index = ProjectCapabilityIndex()
        for ref in refs {
            index[ref.path] = ProjectCapabilities(
                supportsResumableSessions: await projectTypeSupportsResumableSessions(ref.projectType),
                requiresSessionHandshakeGate: await adapterRequiresSessionHandshakeGate(ref.projectType),
                supportsOverviewDashboard: await adapterSupportsOverviewDashboard(ref.projectType)
            )
        }
        return index
    }

    private static func projectTypeSupportsResumableSessions(_ projectType: ProjectType) async -> Bool {
        if projectType.isFolderBacked { return false }
        if case .mixed = projectType {
            let adapters = await AdapterRegistry.shared.all()
            return adapters.contains { $0.capabilities.contains(.resumableSessions) }
        }
        guard let adapter = await ProjectAgentRouter.resolveAdapter(projectType: projectType) else {
            return false
        }
        return adapter.capabilities.contains(.resumableSessions)
    }

    private static func adapterRequiresSessionHandshakeGate(_ projectType: ProjectType) async -> Bool {
        if projectType.isFolderBacked { return false }
        // Mixed with a default: ask that agent. Mixed without a default: gate if
        // any registered adapter declares the capability (safer than false-open).
        // Custom ACP refs resolve through `CustomAgentAdapterFactories` → `ACPAdapter`.
        if case .mixed(let defaultAgent) = projectType {
            if let defaultAgent,
               let adapter = await AdapterRegistry.shared.adapter(for: defaultAgent) {
                return adapter.capabilities.contains(.sessionHandshakeGate)
            }
            let adapters = await AdapterRegistry.shared.all()
            return adapters.contains { $0.capabilities.contains(.sessionHandshakeGate) }
        }
        guard let adapter = await ProjectAgentRouter.resolveAdapter(projectType: projectType) else {
            return false
        }
        return adapter.capabilities.contains(.sessionHandshakeGate)
    }

    private static func adapterSupportsOverviewDashboard(_ projectType: ProjectType) async -> Bool {
        if projectType.isFolderBacked { return false }
        if case .mixed(let defaultAgent) = projectType {
            if let defaultAgent,
               let adapter = await AdapterRegistry.shared.adapter(for: defaultAgent) {
                return adapter.capabilities.contains(.overviewDashboard)
            }
            let adapters = await AdapterRegistry.shared.all()
            return adapters.contains { $0.capabilities.contains(.overviewDashboard) }
        }
        guard let adapter = await ProjectAgentRouter.resolveAdapter(projectType: projectType) else {
            return false
        }
        return adapter.capabilities.contains(.overviewDashboard)
    }
}
