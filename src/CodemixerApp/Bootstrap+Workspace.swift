import Foundation
import AgentCore
import AgentUI
import AgentProtocol

extension Bootstrap {

    // MARK: - Workspace picker affordances

    /// File → Open Workspace: lets the user choose a workspace folder from disk.
    func presentProjectPicker() {
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        showProjectPicker = true
    }

    /// File → Open Project: lets the user add an existing project folder.
    func presentOpenProject() {
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
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
        do {
            guard let lifecycle = workspaceLifecycle else { return }
            try await lifecycle.openEmptyWorkspace(folder)
            workspace = folder
        } catch {
            startupError = error.localizedDescription
            workspace = nil
            workspaceLifecycle?.abortOpen()
        }
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
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        startupError = nil
        try? await viewModel?.workspaceProjects?.clearActiveWorkspace()
        if let engine {
            await engine.shutdown(reason: .userCancel)
        }
        workspace = nil
        isPreparingWorkspace = false
        viewModel?.resetForClosedWorkspace()
    }

    /// File → Add Existing Project / Open Project sheet result.
    func openProject(_ info: ProjectDraft, resumeSessionID: String? = nil) async {
        guard let url = info.existingFolderURL else { return }
        await openWorkspace(url,
                            resumeSessionID: resumeSessionID,
                            preferFreshAgentProcess: info.preferFreshAgentProcess)
    }

    /// Opens a folder after resolving its project type from project-local state
    /// or the workspace index. If neither knows the mode, presents the
    /// configure sheet instead of guessing.
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
        // Empty workspace shell: adopted via New Workspace with no projects yet.
        if let store = viewModel?.workspaceProjects {
            let existing = await store.projects(for: url)
            if existing.isEmpty {
                isPreparingWorkspace = true
                defer { isPreparingWorkspace = false }
                do {
                    guard let lifecycle = workspaceLifecycle else { return }
                    try await lifecycle.openEmptyWorkspace(url)
                    workspace = url
                } catch {
                    startupError = error.localizedDescription
                    workspace = nil
                    workspaceLifecycle?.abortOpen()
                    try? await store.clearActiveWorkspace()
                }
                return
            }
        }
        pendingConfigureURL = url
        pendingConfigureResumeSessionID = resumeSessionID
        pendingConfigurePreferFreshAgentProcess = preferFreshAgentProcess
    }

    func confirmPendingProjectConfiguration(_ info: ProjectDraft) async {
        guard let url = pendingConfigureURL ?? info.existingFolderURL else { return }
        let resume = pendingConfigureResumeSessionID
        let preferFresh = info.preferFreshAgentProcess || pendingConfigurePreferFreshAgentProcess
        guard let mode = info.projectType else { return }
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        pendingConfigurePreferFreshAgentProcess = false
        await openWorkspace(url,
                            resumeSessionID: resume,
                            projectType: mode,
                            preferFreshAgentProcess: preferFresh)
    }

    func confirmPendingProjectConfiguration(mode: ProjectType,
                                            preferFreshAgentProcess: Bool = false) async {
        await confirmPendingProjectConfiguration(ProjectDraft(
            name: pendingConfigureURL?.lastPathComponent ?? "",
            projectType: mode,
            preferFreshAgentProcess: preferFreshAgentProcess,
            existingFolderURL: pendingConfigureURL
        ))
    }

    func cancelPendingProjectConfiguration() {
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        pendingConfigurePreferFreshAgentProcess = false
    }

    func openWorkspace(_ url: URL,
                       resumeSessionID: String?,
                       projectType: ProjectType,
                       preferFreshAgentProcess: Bool = false) async {
        showProjectPicker = false
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        startupError = nil
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }

        // Folder projects are non-agent: register membership and open the browser.
        if projectType.isFolderBacked {
            do {
                guard let lifecycle = workspaceLifecycle else { return }
                try await lifecycle.loadModelCatalogs(at: url, rootProjectType: projectType)
            } catch {
                startupError = error.localizedDescription
                workspace = nil
                workspaceLifecycle?.abortOpen()
                return
            }
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
            do {
                guard let lifecycle = workspaceLifecycle else { return }
                try await lifecycle.loadModelCatalogs(at: url, rootProjectType: projectType)
            } catch {
                startupError = error.localizedDescription
                workspace = nil
                workspaceLifecycle?.abortOpen()
                return
            }
            await viewModel?.prepareProjectOpen(url: url, projectType: projectType)
            await viewModel?.reloadProjects(rootProjectType: projectType)
            viewModel?.openProject(path: url.path, resumeSessionID: resumeSessionID)
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

        // Model catalogs for adapters used in this workspace must be ready
        // before the workspace UI is shown — same path as create / empty open.
        do {
            guard let lifecycle = workspaceLifecycle else { return }
            try await lifecycle.loadModelCatalogs(at: url, rootProjectType: projectType)
        } catch {
            startupError = error.localizedDescription
            workspace = nil
            workspaceLifecycle?.abortOpen()
            try? await projectsStore?.clearActiveWorkspace()
            return
        }

        do {
            // Gate the composer before spawn so Cursor ACP's ~20s
            // initialize/auth/session-new cannot race an early send.
            await viewModel?.prepareProjectOpen(url: url, projectType: projectType)
            await viewModel?.reloadProjects(rootProjectType: projectType)
            try await engine.start(adapter: adapter,
                                   workspace: url,
                                   resumeSessionID: resumeSessionID)
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

    func configureSlashCommands(for url: URL, mode: ProjectType) async {
        guard let adapter = await Self.adapter(for: mode) else {
            viewModel?.slashCommands = []
            return
        }
        let projectCommands = await adapter.enumerateProjectCommands(workspace: url)
        viewModel?.slashCommands = adapter.slashCommandCatalog + projectCommands
    }
}
