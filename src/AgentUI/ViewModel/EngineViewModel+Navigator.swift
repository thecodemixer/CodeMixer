import Foundation
import AgentCore
import AgentProtocol

private enum SessionSwitchingTiming {
    static let emptySessionFallback: Duration = .seconds(2)
}

extension EngineViewModel {

    // MARK: - Session navigator actions

    /// Reload the projects for the current workspace. Pass `rootMode` only when
    /// seeding a brand-new workspace that has no stored projects yet.
    public func refreshProjects(rootMode: ProjectAgentMode? = nil) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            let refs = await store.projects(for: workspace, rootMode: rootMode)
            await MainActor.run { self?.projects = refs }
        }
    }

    /// Lazily list the resumable sessions for a project. A non-resumable agent
    /// (or an empty result) is a first-class empty state, not an error.
    /// Subsequent refreshes update the list silently (no skeleton) so the
    /// navigator doesn't flash on every session switch.
    public func loadSessions(for projectPath: String) {
        guard supportsResumableSessions, let lister = sessionLister else {
            sessionsByProject[projectPath] = []
            return
        }
        // Only show the skeleton placeholder on the very first load.
        // Re-loads keep the stale list visible until fresh data arrives.
        if sessionsByProject[projectPath] == nil {
            loadingProjectPaths.insert(projectPath)
        }
        let url = URL(fileURLWithPath: projectPath)
        Task { [weak self] in
            let sessions = await lister(url)
            await MainActor.run {
                self?.sessionsByProject[projectPath] = sessions
                self?.loadingProjectPaths.remove(projectPath)
            }
        }
    }

    /// Open a specific resumable session of a project.
    public func openSession(projectPath: String, id: String) {
        guard !isCurrentSession(projectPath: projectPath, sessionID: id) else { return }
        beginSessionSwitch(projectPath: projectPath, sessionID: id)
        send(.openProject(path: projectPath, resumeSessionID: id))
    }

    /// Start a fresh chat. For the active project this is `.newSession`; for
    /// another project it reopens that project with no resume id. Both reuse
    /// existing wire commands, so remote clients reach the same behavior.
    public func newChat(in projectPath: String) {
        endSessionSwitch()
        if projectPath == workspace?.path {
            send(.newSession)
        } else {
            send(.openProject(path: projectPath, resumeSessionID: nil))
        }
    }

    /// Create a new project (subfolder of the workspace) and switch to it.
    public func createProject(name: String, agentMode: ProjectAgentMode) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let ref = try await store.createProject(name: name, agentMode: agentMode, in: workspace)
                let refs = await store.projects(for: workspace, rootMode: agentMode)
                await MainActor.run {
                    self?.projects = refs
                    self?.newChat(in: ref.path)
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Register an existing folder as a project of the workspace.
    public func addExistingProject(url: URL, agentMode: ProjectAgentMode) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let ref = try await store.addExistingProject(url: url, agentMode: agentMode, in: workspace)
                let refs = await store.projects(for: workspace, rootMode: agentMode)
                await MainActor.run {
                    self?.projects = refs
                    self?.newChat(in: ref.path)
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Rename a project's display label (folder on disk is untouched).
    public func renameProject(path: String, newName: String) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                try await store.renameProject(path: path, to: newName, in: workspace)
                let refs = await store.projects(for: workspace)
                await MainActor.run { self?.projects = refs }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Remove a project from the navigator (never deletes the folder) and arm an
    /// undo toast. The seeded root cannot be removed.
    public func removeProject(path: String) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let removed = try await store.removeProject(path: path, in: workspace)
                let refs = await store.projects(for: workspace)
                await MainActor.run {
                    self?.projects = refs
                    if let removed { self?.armRemovedProjectUndo(removed) }
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Restore the most recently removed project at its former position.
    public func undoRemoveProject() {
        guard let workspace, let store = workspaceProjects,
              let removed = removedProjectUndo else { return }
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        removedProjectUndo = nil
        Task { [weak self] in
            do {
                try await store.restoreProject(removed, in: workspace)
                let refs = await store.projects(for: workspace)
                await MainActor.run { self?.projects = refs }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// True when `session` is the one currently displayed in the conversation.
    public func isCurrentSession(projectPath: String, sessionID id: String) -> Bool {
        workspace?.path == projectPath && sessionID == id
    }

    func armRemovedProjectUndo(_ removed: WorkspaceProjectsStore.RemovedProject) {
        removedProjectUndoTask?.cancel()
        removedProjectUndo = removed
        removedProjectUndoTask = Task { [weak self] in
            try? await self?.clock.sleep(for: ActivityTiming.undoToastWindow)
            await MainActor.run { self?.removedProjectUndo = nil }
        }
    }

    func beginSessionSwitch(projectPath: String, sessionID id: String) {
        workspace = URL(fileURLWithPath: projectPath)
        sessionID = id
        clearConversationState()
        isSwitchingSession = true
        sessionSwitchingTask?.cancel()
        sessionSwitchingTask = Task { [weak self] in
            try? await self?.clock.sleep(for: SessionSwitchingTiming.emptySessionFallback)
            await MainActor.run {
                guard let self,
                      self.messages.isEmpty,
                      self.activeToolCalls.isEmpty else { return }
                self.isSwitchingSession = false
                self.sessionSwitchingTask = nil
            }
        }
    }

    func endSessionSwitch() {
        isSwitchingSession = false
        sessionSwitchingTask?.cancel()
        sessionSwitchingTask = nil
    }

    func finishSessionSwitchIfNeeded() {
        if isSwitchingSession {
            endSessionSwitch()
        }
    }

    func recordProjectError(_ error: any Error) {
        let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
        diagnostics.append(diagnostic(level: .error, message: message))
    }

    /// Called when the active workspace changes: refresh projects + load the
    /// active project's sessions so the navigator reflects the new state.
    func onWorkspaceChanged() {
        refreshProjects()
        if let workspace { loadSessions(for: workspace.path) }
    }

    /// Clears navigator + conversation chrome after File → Close Workspace.
    public func resetForClosedWorkspace() {
        endSessionSwitch()
        workspace = nil
        sessionID = nil
        projects = []
        sessionsByProject = [:]
        loadingProjectPaths = []
        removedProjectUndo = nil
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        clearConversationState()
        changedFiles = []
        pendingPermission = nil
        status = .idle
        activity = .idle
        sessionTokens = 0
        sessionCostUSD = nil
        availableModels = []
        slashCommands = []
    }
}
