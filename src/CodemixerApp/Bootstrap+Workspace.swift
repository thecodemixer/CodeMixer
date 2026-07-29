import Foundation
import AgentCore
import AgentUI
import AgentProtocol

extension Bootstrap {

    // MARK: - Workspace picker affordances

    /// File → Open Workspace: lets the user choose a workspace folder from disk.
    func presentProjectPicker() {
        clearPendingProjectConfiguration()
        showProjectPicker = true
    }

    /// File → Add Existing Project: pick a folder to register in the open workspace.
    func presentOpenProject() {
        clearPendingProjectConfiguration()
        showOpenProject = true
    }

    /// File → New Workspace: dedicated sheet for name + parent folder + project type.
    func presentNewWorkspaceSheet() {
        showNewWorkspaceSheet = true
    }

    /// File → New Project: create a subfolder project in the open workspace.
    func presentNewProjectSheet() {
        guard workspace != nil else { return }
        showNewProjectSheet = true
    }

    // MARK: - Workspace lifecycle

    /// Creates `<parent>/<name>/`, tears down any open workspace without
    /// bouncing through the Open Project picker, then adopts the folder as an
    /// empty workspace shell. Project type is chosen later via New Project.
    func createWorkspace(name: String, parentDirectory: URL) async {
        showNewWorkspaceSheet = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            startupError = "Enter a valid workspace name."
            return
        }
        let folder = parentDirectory.appendingPathComponent(trimmed, isDirectory: true)
        let fs = Seams.live.fileSystem
        if fs.isDirectory(at: folder) || fs.fileExists(at: folder) {
            startupError = "A folder named “\(trimmed)” already exists in that location."
            return
        }
        do {
            try fs.createDirectory(at: folder, withIntermediates: true)
        } catch {
            startupError = error.localizedDescription
            return
        }
        await leaveWorkspaceWithoutPicker()
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }
        guard let lifecycle = workspaceLifecycle else { return }
        await lifecycle.openEmptyWorkspace(folder)
        workspace = folder
    }

    /// File → Close Workspace: clear the active-workspace restore flag, shut
    /// down the agent, and return to the landing screen.
    func closeWorkspace() async {
        await leaveWorkspaceWithoutPicker()
    }

    /// Tears down the open workspace without presenting the Open Project picker.
    private func leaveWorkspaceWithoutPicker() async {
        showProjectPicker = false
        showNewProjectSheet = false
        showNewWorkspaceSheet = false
        clearPendingProjectConfiguration()
        startupError = nil
        try? await viewModel?.workspaceProjects?.clearActiveWorkspace()
        if let engine {
            await engine.shutdown(reason: .userCancel)
        }
        workspace = nil
        isPreparingWorkspace = false
        viewModel?.resetForClosedWorkspace()
    }

    /// File → Add Existing Project sheet result: register the folder into the
    /// current workspace. Resolves type from project-local state / index; when
    /// unknown, presents Configure Project then adds into the open workspace.
    func openProject(_ info: ProjectDraft, resumeSessionID: String? = nil) async {
        _ = resumeSessionID
        guard let url = info.existingFolderURL else { return }
        guard workspace != nil, let model = viewModel else { return }

        let resolved: ProjectType?
        if let store = model.workspaceProjects {
            resolved = await store.resolveProjectType(for: url)
        } else {
            resolved = ProjectLocalStateStore.load(from: url, fileSystem: Seams.live.fileSystem)?.projectType
        }

        if let mode = resolved {
            await model.addExistingProject(
                info.withProjectType(mode),
                url: url,
                projectType: mode
            )
            return
        }

        pendingConfigure = .addExisting(info)
    }

    /// Opens a folder as a workspace.
    ///
    /// When the folder itself carries a project type (`.codemixer/project.json`
    /// or an app-support index hit), treat it as a single-project workspace and
    /// seed the root. Otherwise adopt a workspace shell — including workspaces
    /// that already list child projects in `.codemixer/workspace.json`. Never
    /// ask for a project type on Open Workspace; Add Existing still configures
    /// untyped folders.
    func openWorkspace(_ url: URL,
                       resumeSessionID: String?,
                       preferFreshAgentProcess: Bool = false) async {
        showProjectPicker = false
        let resolved: ProjectType?
        if let store = viewModel?.workspaceProjects {
            resolved = await store.resolveProjectType(for: url)
        } else {
            resolved = ProjectLocalStateStore.load(from: url, fileSystem: Seams.live.fileSystem)?.projectType
        }
        if let mode = resolved {
            await openWorkspace(url,
                                resumeSessionID: resumeSessionID,
                                projectType: mode,
                                preferFreshAgentProcess: preferFreshAgentProcess)
            return
        }
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }
        guard let lifecycle = workspaceLifecycle else { return }
        await lifecycle.openEmptyWorkspace(url)
        workspace = url
    }

    func confirmPendingProjectConfiguration(_ info: ProjectDraft) async {
        guard let pending = pendingConfigure else { return }
        guard let mode = info.projectType else { return }
        let preferFresh = info.preferFreshAgentProcess || pending.draft.preferFreshAgentProcess
        let url = pending.folderURL ?? info.existingFolderURL
        guard let url else { return }
        clearPendingProjectConfiguration()

        switch pending {
        case .addExisting:
            guard let model = viewModel else { return }
            var draft = info.withProjectType(mode)
            draft.preferFreshAgentProcess = preferFresh
            draft.existingFolderURL = url
            await model.addExistingProject(draft, url: url, projectType: mode)
        case .openWorkspace(_, let resume):
            await openWorkspace(url,
                                resumeSessionID: resume,
                                projectType: mode,
                                preferFreshAgentProcess: preferFresh)
        }
    }

    func confirmPendingProjectConfiguration(mode: ProjectType,
                                            preferFreshAgentProcess: Bool = false) async {
        guard let pending = pendingConfigure else { return }
        var draft = pending.draft.withProjectType(mode)
        if preferFreshAgentProcess {
            draft.preferFreshAgentProcess = true
        }
        await confirmPendingProjectConfiguration(draft)
    }

    func cancelPendingProjectConfiguration() {
        clearPendingProjectConfiguration()
    }

    private func clearPendingProjectConfiguration() {
        pendingConfigure = nil
    }

    func openWorkspace(_ url: URL,
                       resumeSessionID: String?,
                       projectType: ProjectType,
                       preferFreshAgentProcess: Bool = false) async {
        showProjectPicker = false
        clearPendingProjectConfiguration()
        startupError = nil
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }

        // Folder projects are non-agent: register membership and open the browser.
        if projectType.isFolderBacked {
            guard let lifecycle = workspaceLifecycle else { return }
            await lifecycle.loadModelCatalogs(at: url, rootProjectType: projectType)
            let projectsStore = viewModel?.workspaceProjects
            if let store = projectsStore {
                _ = await store.projects(for: url, rootProjectType: projectType)
                _ = try? await store.setProjectType(path: url.path, projectType: projectType, in: url)
            }
            await viewModel?.reloadProjects(rootProjectType: projectType)
            if let ref = await viewModel?.workspaceProjects?.project(path: url.path)
                ?? viewModel?.projects.first(where: {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path
                        == url.standardizedFileURL.path
                }) {
                viewModel?.openFolderProject(ref, relativePath: nil)
            } else if let kind = projectType.folderKind {
                let ref = WorkspaceProjectsStore.ProjectRef(
                    path: url.path,
                    displayName: url.lastPathComponent,
                    projectType: .folder(kind)
                )
                viewModel?.openFolderProject(ref, relativePath: nil)
            }
            viewModel?.workspaceRoot = url
            try? await viewModel?.workspaceProjects?.markActiveWorkspace(url)
            workspace = url
            return
        }

        guard let engine = engine else {
            guard let lifecycle = workspaceLifecycle else { return }
            await lifecycle.loadModelCatalogs(at: url, rootProjectType: projectType)
            await viewModel?.reloadProjects(rootProjectType: projectType)
            if isTargetProjectModelCatalogReady(url: url, projectType: projectType) {
                await viewModel?.prepareProjectOpen(url: url, projectType: projectType)
                if let resumeSessionID {
                    viewModel?.beginSessionSwitch(projectPath: url.path,
                                                  sessionID: resumeSessionID)
                }
                viewModel?.openProject(path: url.path, resumeSessionID: resumeSessionID)
            } else {
                viewModel?.activateDefaultProjectIfNeeded()
            }
            try? await viewModel?.workspaceProjects?.markActiveWorkspace(url)
            Task { await configureSlashCommands(for: url, mode: projectType) }
            workspace = url
            return
        }
        await engine.shutdown(reason: .userCancel)
        let projectsStore = viewModel?.workspaceProjects
        if let store = projectsStore {
            _ = await store.projects(for: url, rootProjectType: projectType)
            _ = try? await store.setProjectType(path: url.path, projectType: projectType, in: url)
            if preferFreshAgentProcess {
                _ = try? await store.setAgentLaunchPreference(
                    path: url.path,
                    preferFreshAgentProcess: true,
                    in: url
                )
            }
        }

        guard let adapter = await Self.adapter(for: projectType) else {
            startupError = "Select a concrete agent for this mixed or custom project before starting a session."
            workspace = nil
            workspaceLifecycle?.abortOpen()
            try? await projectsStore?.clearActiveWorkspace()
            return
        }

        // Warm catalogs for adapters used in this workspace. Failures land
        // under Not loaded — sibling projects stay usable.
        guard let lifecycle = workspaceLifecycle else { return }
        await lifecycle.loadModelCatalogs(at: url, rootProjectType: projectType)
        await viewModel?.reloadProjects(rootProjectType: projectType)

        guard isTargetProjectModelCatalogReady(url: url, projectType: projectType) else {
            viewModel?.activateDefaultProjectIfNeeded()
            try? await projectsStore?.markActiveWorkspace(url)
            workspace = url
            return
        }

        do {
            // Gate the composer before spawn so Cursor ACP's ~20s
            // initialize/auth/session-new cannot race an early send.
            await viewModel?.prepareProjectOpen(url: url, projectType: projectType)
            if let resumeSessionID {
                viewModel?.beginSessionSwitch(projectPath: url.path,
                                              sessionID: resumeSessionID)
            }
            try await engine.send(.openProject(path: url.path,
                                               resumeSessionID: resumeSessionID))
            viewModel?.supportsResumableSessions = adapter.capabilities.contains(.resumableSessions)
            viewModel?.availableModels = adapter.availableModels()
            viewModel?.availableAgentModes = adapter.availableAgentModes()
            viewModel?.selectedAgentModeID = adapter.availableAgentModes().first?.id ?? ""
            try? await projectsStore?.markActiveWorkspace(url)
            workspace = url
        } catch let err as AgentError {
            startupError = err.userMessage
            workspace = nil
            workspaceLifecycle?.abortOpen()
            try? await projectsStore?.clearActiveWorkspace()
        } catch {
            startupError = error.localizedDescription
            workspace = nil
            workspaceLifecycle?.abortOpen()
            try? await projectsStore?.clearActiveWorkspace()
        }
        if workspace != nil {
            await configureSlashCommands(for: url, mode: projectType)
        }
    }

    /// Whether the project being opened has a usable model catalog. Custom /
    /// folder projects never require a shipping catalog.
    private func isTargetProjectModelCatalogReady(url: URL, projectType: ProjectType) -> Bool {
        guard !projectType.isFolderBacked else { return true }
        if case .custom = projectType { return true }
        if let ref = viewModel?.projects.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == url.standardizedFileURL.path
        }) {
            return viewModel?.isProjectModelCatalogReady(ref) ?? false
        }
        // Root not yet listed as a ProjectRef — gate on the type's adapters.
        return viewModel?.isProjectTypeModelCatalogReady(projectType) ?? false
    }

    func configureSlashCommands(for url: URL, mode: ProjectType) async {
        guard let adapter = await Self.adapter(for: mode) else {
            viewModel?.slashCommands = []
            return
        }
        let projectCommands = await adapter.enumerateProjectCommands(workspace: url)
        viewModel?.slashCommands = adapter.slashCommandCatalog + projectCommands
    }
}
