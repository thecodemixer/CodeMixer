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

    /// Bind sidebar/session identity to `path` and sync `activeWorkingDirectory`
    /// from the stored project ref (override or project folder).
    func bindActiveProject(path: String) {
        let projectURL = URL(fileURLWithPath: path).standardizedFileURL
        workspace = projectURL
        if let ref = projectRef(at: projectURL.path) {
            activeWorkingDirectory = ref.workingDirectoryURL
        } else {
            activeWorkingDirectory = projectURL
        }
    }

    /// Bind sidebar/session identity from a known project ref.
    func bindActiveProject(_ project: WorkspaceProjectsStore.ProjectRef) {
        workspace = URL(fileURLWithPath: project.path).standardizedFileURL
        activeWorkingDirectory = project.workingDirectoryURL
    }

    /// Bind the active project and arm the adapter's session-handshake composer
    /// gate before engine spawn so an early send cannot race protocol bootstrap.
    public func prepareProjectOpen(url: URL, projectType: ProjectType) async {
        let target = url.standardizedFileURL
        // Keep an existing workspace shell root (multi-project). Only seed the
        // root when opening a single-folder / typed workspace.
        if workspaceRoot == nil {
            workspaceRoot = target
        }
        bindActiveProject(path: target.path)
        let supportsOverview = await Self.adapterSupportsOverviewDashboard(projectType)
        if var caps = projectCapabilities[target.path] {
            caps.supportsOverviewDashboard = supportsOverview
            projectCapabilities[target.path] = caps
        } else {
            projectCapabilities[target.path] = .init(
                supportsResumableSessions: false,
                supportsOverviewDashboard: supportsOverview
            )
        }
        noteAdapterPending()
    }

    /// Create or adopt a project from sheet-collected `ProjectDraft`.
    /// Returns `nil` on success; otherwise a user-facing error (dialog should stay open).
    @discardableResult
    public func createOrAddProject(_ info: ProjectDraft) async -> String? {
        guard let projectType = info.projectType else { return "Project type is required." }
        if let folderURL = info.existingFolderURL {
            return await addExistingProject(info, url: folderURL, projectType: projectType)
        }
        return await createProject(info, projectType: projectType)
    }

    /// Create a new project (subfolder of the workspace) and switch to it.
    /// Returns once the project is listed; when its model catalog cannot be
    /// populated it stays under Not loaded and is not opened.
    @discardableResult
    public func createProject(_ info: ProjectDraft, projectType: ProjectType) async -> String? {
        guard let workspaceRoot, let store = workspaceProjects else {
            return "No workspace is open."
        }
        do {
            let primaryRoot = workspaceRoot.appendingPathComponent(info.name, isDirectory: true)
            let folderView = try Self.folderViewState(for: info, primaryRoot: primaryRoot)
            let ref = try await store.createProject(
                name: info.name,
                projectType: projectType,
                preferFreshAgentProcess: info.preferFreshAgentProcess,
                folderView: folderView,
                workingDirectory: info.workingDirectoryURL,
                in: workspaceRoot
            )
            await finishProjectRegistration(ref, projectType: projectType)
            return nil
        } catch {
            recordProjectError(error)
            return projectMutationMessage(error)
        }
    }

    /// Register an existing folder as a project of the workspace.
    /// Returns once the project is listed. Vendor history import continues in
    /// the background. When its model catalog cannot be populated the project
    /// stays under Not loaded and is not opened.
    @discardableResult
    public func addExistingProject(_ info: ProjectDraft,
                                   url: URL,
                                   projectType: ProjectType) async -> String? {
        guard let workspaceRoot, let store = workspaceProjects else {
            return "No workspace is open."
        }
        do {
            let folderView = try Self.folderViewState(for: info, primaryRoot: url)
            let ref = try await store.addExistingProject(
                url: url,
                projectType: projectType,
                displayName: info.name,
                preferFreshAgentProcess: info.preferFreshAgentProcess,
                folderView: folderView,
                workingDirectory: info.workingDirectoryURL,
                in: workspaceRoot
            )
            await finishProjectRegistration(ref, projectType: projectType)
            let path = ref.path
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.engine.send(.importProjectHistory(path: path))
                } catch {
                    await MainActor.run { self.recordProjectError(error) }
                }
            }
            return nil
        } catch {
            recordProjectError(error)
            return projectMutationMessage(error)
        }
    }

    /// Builds persisted folder-view state for dual trees. The store owns the
    /// validation rules; failing here keeps the sheet open with the reason
    /// instead of surfacing a half-created project.
    private static func folderViewState(for info: ProjectDraft,
                                        primaryRoot: URL) throws -> FolderViewState? {
        guard info.projectType?.folderKind?.usesDualTreeNavigation == true else { return nil }
        guard let secondary = info.secondaryFolderURL else {
            throw ProjectLocalStateStore.StoreSecondaryRootError.missing
        }
        return try ProjectLocalStateStore.validatedDualFolderView(
            FolderViewState(pinnedRelativePaths: [],
                            secondaryRootPath: secondary.standardizedFileURL.path),
            primaryRoot: primaryRoot,
            fileSystem: SystemFileSystem()
        )
    }

    /// Update the agent working-directory override for an existing project.
    /// Takes effect the next time that project's agent starts.
    @discardableResult
    public func setProjectWorkingDirectory(path: String, to workingDirectory: URL?) async -> String? {
        guard let workspaceRoot, let store = workspaceProjects else {
            return "No workspace is open."
        }
        do {
            let updated = try await store.setWorkingDirectory(
                path: path,
                to: workingDirectory,
                in: workspaceRoot
            )
            let refs = await store.projects(for: workspaceRoot)
            await applyProjectList(refs)
            if workspace?.path == updated.path {
                bindActiveProject(updated)
            }
            return nil
        } catch {
            recordProjectError(error)
            return projectMutationMessage(error)
        }
    }

    /// Create a new project (subfolder of the workspace) and switch to it.
    public func createProject(name: String,
                              projectType: ProjectType,
                              preferFreshAgentProcess: Bool = false) async {
        await createProject(
            ProjectDraft(
                name: name,
                projectType: projectType,
                preferFreshAgentProcess: preferFreshAgentProcess
            ),
            projectType: projectType
        )
    }

    /// Register an existing folder as a project of the workspace.
    public func addExistingProject(url: URL,
                                   projectType: ProjectType,
                                   displayName: String? = nil,
                                   preferFreshAgentProcess: Bool = false) async {
        await addExistingProject(
            ProjectDraft(
                name: displayName ?? url.lastPathComponent,
                projectType: projectType,
                preferFreshAgentProcess: preferFreshAgentProcess,
                existingFolderURL: url
            ),
            url: url,
            projectType: projectType
        )
    }

    private func finishProjectRegistration(_ ref: WorkspaceProjectsStore.ProjectRef,
                                           projectType: ProjectType) async {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        // Do not pass `rootProjectType` — that seeds the workspace folder as a
        // synthetic root project when the in-memory list is momentarily empty.
        let refs = await store.projects(for: workspaceRoot)
        await applyProjectList(refs)
        if projectType.isFolderBacked {
            openFolderProject(ref, relativePath: nil)
            return
        }
        // Soft-warm: record per-adapter failures so a broken CLI lands under
        // Not loaded instead of opening with an empty model picker. Probe is
        // still bounded by `ModelCatalogTiming.probeTimeout`.
        let ready = await ensureModelsRecordingFailures(for: projectType)
        guard ready else { return }
        applyAdapterCapabilities(for: projectType, projectURL: URL(fileURLWithPath: ref.path))
        newChat(in: ref.path)
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
    /// Soft-warms its model catalog; if the catalog cannot be populated the
    /// project is restored under Not loaded instead of aborting undo.
    public func undoRemoveProject() async {
        guard let workspaceRoot, let store = workspaceProjects,
              let removed = removedProjectUndo else { return }
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        removedProjectUndo = nil
        do {
            try await store.restoreProject(removed, in: workspaceRoot)
            let refs = await store.projects(for: workspaceRoot)
            await applyProjectList(refs)
            _ = await ensureModelsRecordingFailures(for: removed.ref.projectType)
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
            bindActiveProject(path: newPath)
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
        diagnostics.append(diagnostic(level: .error, message: projectMutationMessage(error)))
    }

    private func projectMutationMessage(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription
            ?? (error as? AgentError)?.userMessage
            ?? error.localizedDescription
    }

    /// Opens a freshly created workspace folder without starting an agent.
    /// Project type is chosen later via File → New Project…
    /// Awaits model-catalog warm so callers can gate the UI until ready
    /// catalogs are known (failures land under Not loaded).
    public func adoptEmptyWorkspace(_ url: URL) async {
        workspaceRoot = url
        workspace = nil
        activeWorkingDirectory = nil
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
        clearSessionActivation()
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
        modelCatalogLoadFailures = [:]
        await reloadProjects()
        await warmWorkspaceModelCatalogs()
    }

    /// Clears navigator + conversation chrome after File → Close Workspace.
    public func resetForClosedWorkspace() {
        workspaceRoot = nil
        workspace = nil
        activeWorkingDirectory = nil
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
        clearSessionActivation()
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
        modelCatalogLoadFailures = [:]
        slashCommands = []
        livePooledProjectPaths = []
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
