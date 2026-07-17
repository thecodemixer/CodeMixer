import Foundation
import AgentCore
import AgentProtocol

enum SessionSwitchingTiming {
    static let emptySessionFallback: Duration = .seconds(2)

    /// Non-Claude agents can unlock as soon as replayed content proves the UI
    /// is showing the selected session. The engine remains the source of truth
    /// for whether a command can be written to the transport.
    static let composerHardUnlock: Duration = .seconds(3)

    /// Claude Code history is replayed from JSONL, not from the live
    /// `claude --resume` process. Keep the composer locked until the engine's
    /// longer "no live SessionStart arrived" gate would also have released a
    /// held write.
    static let claudeCodeComposerHardUnlock: Duration = ActivityTiming.resumedSessionStartupStallTimeout

    /// Once Claude Code's live hook SessionStart arrives, keep the composer
    /// locked for the same settle/fallback window the engine uses before
    /// writing a held prompt. This aligns GUI sends with API/remote sends while
    /// avoiding the JSONL-history false-ready state.
    static let claudeCodeComposerHookUnlock: Duration = ActivityTiming.resumedSessionPostSessionStartFallback
        + ActivityTiming.resumePromptReadySettleDelay
}

extension EngineViewModel {

    // MARK: - Session navigator actions

    /// Reload the projects for the current workspace. Pass `rootProjectType` only when
    /// seeding a brand-new workspace that has no stored projects yet.
    public func refreshProjects(rootProjectType: ProjectType? = nil) {
        Task { await reloadProjects(rootProjectType: rootProjectType) }
    }

    /// Awaitable variant for startup restore and other flows that must not flash
    /// an empty navigator before the project list is ready.
    public func reloadProjects(rootProjectType: ProjectType? = nil) async {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        let refs = await store.projects(for: workspaceRoot, rootProjectType: rootProjectType)
        projects = refs
        projectResumableSessionSupport = await Self.resumableSessionSupport(for: refs)
    }

    /// Lazily list the resumable sessions for a project. A non-resumable agent
    /// (or an empty result) is a first-class empty state, not an error.
    /// Subsequent refreshes update the list silently (no skeleton) so the
    /// navigator doesn't flash on every session switch.
    public func loadSessions(for projectPath: String) {
        guard supportsResumableSessions(forProjectPath: projectPath), let lister = sessionLister else {
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

    /// Open a specific resumable session of a project. Makes that project the
    /// current one immediately so the top bar title updates before resume finishes.
    public func openSession(projectPath: String, id: String) {
        guard !isCurrentSession(projectPath: projectPath, sessionID: id) else { return }
        // The session list carries the concrete agent for mixed projects. Use it
        // to decide whether history replay is enough to unlock the composer.
        // Claude Code is special because replayed history comes from JSONL,
        // while the live `claude --resume` PTY can still be restoring.
        beginSessionSwitch(projectPath: projectPath,
                           sessionID: id,
                           waitsForClaudeCodeResume: sessionResumeNeedsClaudeCodeReadiness(projectPath: projectPath,
                                                                                           sessionID: id))
        applyAdapterCapabilities(forProjectPath: projectPath)
        send(.openProject(path: projectPath, resumeSessionID: id))
    }

    /// Make `projectPath` the current project. Opens its most recent session when
    /// known; otherwise starts a fresh chat in that project.
    public func selectProject(path projectPath: String) {
        guard !projectPath.isEmpty else { return }
        guard projectPath != workspace?.path else { return }
        if let recent = sessionsByProject[projectPath]?.first {
            openSession(projectPath: projectPath, id: recent.id)
            return
        }
        loadSessions(for: projectPath)
        newChat(in: projectPath)
    }

    /// Start a fresh chat in the current project (toolbar / palette New Chat).
    public func newChatInCurrentProject() {
        guard let path = workspace?.path, !path.isEmpty else { return }
        newChat(in: path)
    }

    /// Start a fresh chat in `projectPath`. Always opens the project with no
    /// resume id so both Claude and Codex get a real new session (Codex
    /// `.newSession` encoding can no-op when session context isn't ready, and
    /// Claude `/clear` does not reliably clear the local conversation).
    public func newChat(in projectPath: String) {
        guard !projectPath.isEmpty else { return }
        endSessionSwitch()
        let target = URL(fileURLWithPath: projectPath).standardizedFileURL
        workspace = target
        sessionID = nil
        clearConversationState()
        pendingPermission = nil
        status = .idle
        activity = .idle
        applyAdapterCapabilities(forProjectPath: target.path)
        send(.openProject(path: target.path, resumeSessionID: nil))
    }

    /// Create a new project (subfolder of the workspace) and switch to it.
    public func createProject(name: String, projectType: ProjectType) {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let ref = try await store.createProject(name: name, projectType: projectType, in: workspaceRoot)
                let refs = await store.projects(for: workspaceRoot, rootProjectType: projectType)
                let support = await Self.resumableSessionSupport(for: refs)
                await MainActor.run {
                    self?.projects = refs
                    self?.projectResumableSessionSupport = support
                    self?.applyAdapterCapabilities(for: projectType, projectURL: URL(fileURLWithPath: ref.path))
                    self?.newChat(in: ref.path)
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Register an existing folder as a project of the workspace.
    public func addExistingProject(url: URL, projectType: ProjectType) {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let ref = try await store.addExistingProject(url: url, projectType: projectType, in: workspaceRoot)
                let refs = await store.projects(for: workspaceRoot, rootProjectType: projectType)
                let support = await Self.resumableSessionSupport(for: refs)
                await MainActor.run {
                    self?.projects = refs
                    self?.projectResumableSessionSupport = support
                    self?.applyAdapterCapabilities(for: projectType, projectURL: URL(fileURLWithPath: ref.path))
                    self?.newChat(in: ref.path)
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Rename a project's display label (folder on disk is untouched).
    public func renameProject(path: String, newName: String) {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                try await store.renameProject(path: path, to: newName, in: workspaceRoot)
                let refs = await store.projects(for: workspaceRoot)
                let support = await Self.resumableSessionSupport(for: refs)
                await MainActor.run {
                    self?.projects = refs
                    self?.projectResumableSessionSupport = support
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
                let support = await Self.resumableSessionSupport(for: refs)
                await MainActor.run {
                    self?.projects = refs
                    self?.projectResumableSessionSupport = support
                    if let removed { self?.armRemovedProjectUndo(removed) }
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Restore the most recently removed project at its former position.
    public func undoRemoveProject() {
        guard let workspaceRoot, let store = workspaceProjects,
              let removed = removedProjectUndo else { return }
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        removedProjectUndo = nil
        Task { [weak self] in
            do {
                try await store.restoreProject(removed, in: workspaceRoot)
                let refs = await store.projects(for: workspaceRoot)
                let support = await Self.resumableSessionSupport(for: refs)
                await MainActor.run {
                    self?.projects = refs
                    self?.projectResumableSessionSupport = support
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// True when `session` is the one currently displayed in the conversation.
    public func isCurrentSession(projectPath: String, sessionID id: String) -> Bool {
        workspace?.path == projectPath && sessionID == id
    }

    /// Resolves the adapter for `projectType` and refreshes model / agent-mode /
    /// slash / resumable capabilities used by the composer and sidebar.
    public func applyAdapterCapabilities(for projectType: ProjectType, projectURL: URL? = nil) {
        let url = projectURL ?? workspace
        let expectedPath = url.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        }
        adapterCapabilitiesGeneration += 1
        let generation = adapterCapabilitiesGeneration
        Task { [weak self] in
            guard let self else { return }
            guard let adapter = await ProjectAgentRouter.resolveAdapter(projectType: projectType) else {
                await MainActor.run {
                    guard self.shouldApplyAdapterCapabilities(
                        generation: generation,
                        expectedPath: expectedPath
                    ) else { return }
                    self.availableModels = []
                    self.availableAgentModes = []
                    self.selectedAgentModeID = ""
                    self.supportsResumableSessions = false
                    self.slashCommands = []
                }
                return
            }
            var models = adapter.availableModels()
            let agentModes = adapter.availableAgentModes()
            let resumable = adapter.capabilities.contains(.resumableSessions)
            let builtIn = adapter.slashCommandCatalog
            let projectCommands: [SlashCommand]
            if let url {
                projectCommands = await adapter.enumerateProjectCommands(workspace: url)
            } else {
                projectCommands = []
            }
            // Cursor fills its model cache asynchronously from `cursor-agent
            // models`. One short retry picks that up without blocking start.
            // Use wall-clock sleep so FakeClock-driven unit tests don't hang.
            if models.isEmpty {
                try? await Task.sleep(for: .milliseconds(750))
                models = adapter.availableModels()
            }
            await MainActor.run {
                guard self.shouldApplyAdapterCapabilities(
                    generation: generation,
                    expectedPath: expectedPath
                ) else { return }
                self.availableModels = models
                self.availableAgentModes = agentModes
                if agentModes.contains(where: { $0.id == self.selectedAgentModeID }) {
                    // Keep the user's selection when the adapter still offers it.
                } else {
                    self.selectedAgentModeID = agentModes.first?.id ?? ""
                }
                self.supportsResumableSessions = resumable
                self.slashCommands = builtIn + projectCommands
            }
        }
    }

    func applyAdapterCapabilities(forProjectPath path: String) {
        let expectedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        adapterCapabilitiesGeneration += 1
        let generation = adapterCapabilitiesGeneration
        Task { [weak self] in
            guard let self, let store = workspaceProjects else { return }
            let url = URL(fileURLWithPath: path)
            let projectType: ProjectType?
            if let project = await store.project(path: path) {
                projectType = project.projectType
            } else {
                projectType = await store.resolveProjectType(for: url)
            }
            guard let projectType else { return }
            await MainActor.run {
                guard self.shouldApplyAdapterCapabilities(
                    generation: generation,
                    expectedPath: expectedPath
                ) else { return }
                self.applyAdapterCapabilities(for: projectType, projectURL: url)
            }
        }
    }

    func shouldApplyAdapterCapabilities(generation: Int, expectedPath: String?) -> Bool {
        guard generation == adapterCapabilitiesGeneration else { return false }
        guard let expectedPath else { return true }
        guard let current = workspace?.path else { return false }
        return URL(fileURLWithPath: current).standardizedFileURL.path == expectedPath
    }

    func armRemovedProjectUndo(_ removed: WorkspaceProjectsStore.RemovedProject) {
        removedProjectUndoTask?.cancel()
        removedProjectUndo = removed
        removedProjectUndoTask = Task { [weak self] in
            try? await self?.clock.sleep(for: ActivityTiming.undoToastWindow)
            await MainActor.run { self?.removedProjectUndo = nil }
        }
    }

    func beginSessionSwitch(projectPath: String,
                            sessionID id: String,
                            waitsForClaudeCodeResume: Bool = false) {
        workspace = URL(fileURLWithPath: projectPath)
        sessionID = id
        clearConversationState()
        isSwitchingSession = true
        lockComposerForSessionResume(waitsForClaudeCodeResume: waitsForClaudeCodeResume)
        sessionSwitchingTask?.cancel()
        sessionSwitchingTask = Task { [weak self] in
            try? await self?.clock.sleep(for: SessionSwitchingTiming.emptySessionFallback)
            await MainActor.run {
                guard let self,
                      self.messages.isEmpty,
                      self.activeToolCalls.isEmpty else { return }
                // Keep the empty-state "restoring" face while the composer is
                // still gated — otherwise the hero flips to "Ready when you
                // are" with a locked chat box.
                guard !self.isComposerLockedForSessionResume else { return }
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
        // This is called when conversation content arrives. For Codex and other
        // non-Claude agents, that content means the selected session is ready
        // enough for the composer because command delivery is not racing a TUI
        // resume screen. For Claude Code, the same content may be JSONL replay
        // only; live input readiness is handled by SessionStart below.
        if isComposerLockedForSessionResume, !isComposerWaitingForClaudeCodeResume {
            unlockComposerForSessionResume()
        }
    }

    func lockComposerForSessionResume(waitsForClaudeCodeResume: Bool = false) {
        isComposerLockedForSessionResume = true
        isComposerWaitingForClaudeCodeResume = waitsForClaudeCodeResume
        scheduleComposerResumeUnlock(after: waitsForClaudeCodeResume
            ? SessionSwitchingTiming.claudeCodeComposerHardUnlock
            : SessionSwitchingTiming.composerHardUnlock)
    }

    func scheduleComposerResumeUnlock(after delay: Duration) {
        composerResumeUnlockTask?.cancel()
        let clock = clock
        composerResumeUnlockTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.unlockComposerForSessionResume()
            }
        }
    }

    func unlockComposerForSessionResume() {
        isComposerLockedForSessionResume = false
        isComposerWaitingForClaudeCodeResume = false
        composerResumeUnlockTask?.cancel()
        composerResumeUnlockTask = nil
        // Empty resumes never get replay content that would end the switch;
        // drop the restoring banner once input is allowed again.
        if isSwitchingSession, messages.isEmpty, activeToolCalls.isEmpty {
            endSessionSwitch()
        }
    }

    func sessionResumeNeedsClaudeCodeReadiness(projectPath: String, sessionID id: String) -> Bool {
        // Prefer the session row because mixed projects can contain both Claude
        // and Codex sessions. If the row is not loaded yet, fall back to the
        // project type; this is still correct for dedicated Claude projects.
        if let session = sessionsByProject[projectPath]?.first(where: { $0.id == id }) {
            return session.agentID == .claudeCode
        }
        if let project = projects.first(where: { $0.path == projectPath }) {
            return project.projectType == .claudeCode
        }
        return false
    }

    public var hasResumableSessionProjects: Bool {
        supportsResumableSessions || projectResumableSessionSupport.values.contains(true)
    }

    public func supportsResumableSessions(for project: WorkspaceProjectsStore.ProjectRef) -> Bool {
        supportsResumableSessions(forProjectPath: project.path)
    }

    func supportsResumableSessions(forProjectPath path: String) -> Bool {
        projectResumableSessionSupport[path] ?? supportsResumableSessions
    }

    func recordProjectError(_ error: any Error) {
        let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
        diagnostics.append(diagnostic(level: .error, message: message))
    }

    /// Active project cwd changed: keep the workspace project list, reload
    /// sessions for the new project, and refresh adapter-facing catalogs.
    func onActiveProjectChanged() {
        refreshProjects()
        if let workspace {
            loadSessions(for: workspace.path)
            applyAdapterCapabilities(forProjectPath: workspace.path)
        }
    }

    /// Called when the active workspace changes: refresh projects + load the
    /// active project's sessions so the navigator reflects the new state.
    func onWorkspaceChanged() {
        refreshProjects()
        if let workspace { loadSessions(for: workspace.path) }
    }

    /// Opens a freshly created workspace folder without starting an agent.
    /// Project type is chosen later via File → New Project…
    public func adoptEmptyWorkspace(_ url: URL) {
        endSessionSwitch()
        workspaceRoot = url
        workspace = nil
        sessionID = nil
        projects = []
        sessionsByProject = [:]
        projectResumableSessionSupport = [:]
        loadingProjectPaths = []
        removedProjectUndo = nil
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        unlockComposerForSessionResume()
        clearConversationState()
        changedFiles = []
        pendingPermission = nil
        status = .idle
        activity = .idle
        sessionTokens = 0
        sessionCostUSD = nil
        availableModels = []
        availableAgentModes = []
        selectedAgentModeID = ""
        slashCommands = []
        refreshProjects()
    }

    /// Clears navigator + conversation chrome after File → Close Workspace.
    public func resetForClosedWorkspace() {
        endSessionSwitch()
        workspaceRoot = nil
        workspace = nil
        sessionID = nil
        projects = []
        sessionsByProject = [:]
        projectResumableSessionSupport = [:]
        loadingProjectPaths = []
        removedProjectUndo = nil
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        unlockComposerForSessionResume()
        clearConversationState()
        changedFiles = []
        pendingPermission = nil
        status = .idle
        activity = .idle
        sessionTokens = 0
        sessionCostUSD = nil
        availableModels = []
        availableAgentModes = []
        selectedAgentModeID = ""
        slashCommands = []
    }

    private static func resumableSessionSupport(
        for refs: [WorkspaceProjectsStore.ProjectRef]
    ) async -> [String: Bool] {
        var support: [String: Bool] = [:]
        for ref in refs {
            support[ref.path] = await projectTypeSupportsResumableSessions(ref.projectType)
        }
        return support
    }

    private static func projectTypeSupportsResumableSessions(_ projectType: ProjectType) async -> Bool {
        if case .mixed = projectType {
            let adapters = await AdapterRegistry.shared.all()
            return adapters.contains { $0.capabilities.contains(.resumableSessions) }
        }
        guard let adapter = await ProjectAgentRouter.resolveAdapter(projectType: projectType) else {
            return false
        }
        return adapter.capabilities.contains(.resumableSessions)
    }
}
