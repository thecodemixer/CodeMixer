import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {
    /// (or an empty result) is a first-class empty state, not an error.
    /// Subsequent refreshes update the list silently (no skeleton) so the
    /// navigator doesn't flash on every session switch.
    public func loadSessions(for projectPath: String) {
        guard supportsResumableSessions(forProjectPath: projectPath) else {
            sessionsByProject[projectPath] = []
            return
        }
        if sessionsByProject[projectPath] == nil {
            loadingProjectPaths.insert(projectPath)
        }
        send(.listSessions(path: projectPath))
    }

    /// Awaitable session list used by overview open paths so we do not mint a
    /// second control chat before the persisted overview row is known.
    @discardableResult
    public func reloadSessions(for projectPath: String) async -> [SessionSummary] {
        guard supportsResumableSessions(forProjectPath: projectPath) else {
            sessionsByProject[projectPath] = []
            return []
        }
        loadSessions(for: projectPath)
        return sessionsByProject[projectPath] ?? []
    }

    /// Open a specific resumable session of a project. Makes that project the
    /// current one immediately so the top bar title updates before resume finishes.
    ///
    /// Cursor / ACP: when the agent process is already live on this project,
    /// the engine warm-loads via `session/load` (~seconds) instead of respawning
    /// `cursor-agent` (~20s initialize/auth).
    public func openSession(projectPath: String, id: String) {
        // Overview is a dashboard surface, not a resumable chat. Legacy control
        // rows in the index must never `session/load` — route them to Overview.
        if supportsOverviewDashboard(forProjectPath: projectPath),
           sessionsByProject[projectPath]?.first(where: { $0.id == id })?.isOverview == true {
            openOverview(projectPath: projectPath)
            return
        }
        if let project = projectRef(at: projectPath), project.projectType.isFolderBacked {
            openFolderProject(project, relativePath: nil)
            return
        }
        if isCurrentSession(projectPath: projectPath, sessionID: id) {
            detailPane = .conversation
            return
        }
        applyAdapterCapabilities(forProjectPath: projectPath)
        // File / chat sessions always leave the dashboard WebView.
        detailPane = .conversation
        beginSessionSwitch(projectPath: projectPath, sessionID: id)
        send(.openProject(path: projectPath, resumeSessionID: id))
        Task { await self.refreshLivePooledProjectPaths() }
    }

    /// Sync sidebar warm-hints with the engine process pool (active + parked).
    func refreshLivePooledProjectPaths() async {
        livePooledProjectPaths = await engine.liveProjectPaths()
    }

    /// Prefer the live `dashboardURL`; fall back to any persisted overview URL
    /// so chat→overview never lands on the empty placeholder.
    func restoreDashboardURLIfNeeded(projectPath: String) {
        guard dashboardURL == nil, !isRestartingCustomACPCLI else { return }
        let sessions = sessionsByProject[projectPath] ?? []
        if let url = sessions.first(where: { $0.isOverview })?.overviewURL
            ?? sessions.compactMap(\.overviewURL).first {
            dashboardURL = url
        }
    }

    /// Make `projectPath` the current project. For overview-capable agents,
    /// shows the dashboard by default. Folder projects open the browser.
    /// Otherwise opens the most recent session when known; single-agent
    /// projects with no listed sessions start a new chat.
    public func selectProject(path projectPath: String) {
        guard !projectPath.isEmpty else { return }
        if let project = projectRef(at: projectPath), project.projectType.isFolderBacked {
            openFolderProject(project, relativePath: nil)
            return
        }
        guard projectPath != workspace?.path else {
            // Re-clicking the active overview project re-focuses the dashboard.
            if supportsOverviewDashboard(forProjectPath: projectPath) {
                selectDashboardOverview(projectPath: projectPath)
            }
            return
        }
        applyAdapterCapabilities(forProjectPath: projectPath)
        clearFolderBrowserSurface()
        if supportsOverviewDashboard(forProjectPath: projectPath) {
            openOverview(projectPath: projectPath)
            return
        }
        if let recent = sessionsByProject[projectPath]?.first(where: { !$0.isOverview })
            ?? sessionsByProject[projectPath]?.first {
            openSession(projectPath: projectPath, id: recent.id)
            return
        }
        loadSessions(for: projectPath)
        newChat(in: projectPath)
    }

    /// After adopting a workspace shell with projects but no active project,
    /// open the first concrete agent project (else first folder project) so the
    /// workbench is not stuck on "No workspace open".
    public func activateDefaultProjectIfNeeded() {
        guard workspace == nil, !projects.isEmpty else { return }
        if let agent = projects.first(where: { !$0.projectType.isFolderBacked }) {
            selectProject(path: agent.path)
            return
        }
        if let folder = projects.first {
            selectProject(path: folder.path)
        }
    }

    public func newChatInCurrentProject() {
        guard let path = workspace?.path, !path.isEmpty else { return }
        if let project = projectRef(at: path), project.projectType.isFolderBacked {
            return
        }
        newChat(in: path)
    }

    /// Start a fresh chat in `projectPath`.
    ///
    /// Cold-starts only when this project has no live pooled agent. When the
    /// agent is already pooled, the engine keeps the process and runs
    /// `.newSession` in-process (Cursor `session/new`, Codex thread start,
    /// Claude `/clear`).
    public func newChat(in projectPath: String) {
        guard !projectPath.isEmpty else { return }
        if let project = projectRef(at: projectPath), project.projectType.isFolderBacked {
            openFolderProject(project, relativePath: nil)
            return
        }
        let target = URL(fileURLWithPath: projectPath).standardizedFileURL
        workspace = target
        sessionID = nil
        clearConversationState()
        clearAllPendingPermissions()
        status = .idle
        activity = .idle
        // New Chat is always the conversation surface — never the folder
        // browser or overview WebView.
        detailPane = .conversation
        applyAdapterCapabilities(forProjectPath: target.path)
        sessionActivation = .awaitingAdapter(sessionID: "")
        // Cold only on the first spawn for this project; later New Chat reuses
        // the pooled agent (Cursor session/new, etc.).
        let handshake: SessionHandshakeKind =
            livePooledProjectPaths.contains(target.path) ? .warm : .coldStart
        armSessionHandshakeTimeout(handshake)
        send(.openProject(path: target.path, resumeSessionID: nil))
    }

    /// True when `session` is the one currently displayed in the conversation.
    public func isCurrentSession(projectPath: String, sessionID id: String) -> Bool {
        workspace?.path == projectPath && sessionID == id
    }

    public var hasResumableSessionProjects: Bool {
        supportsResumableSessions || projectCapabilities.anySupportsResumableSessions
    }

    public func supportsResumableSessions(for project: WorkspaceProjectsStore.ProjectRef) -> Bool {
        supportsResumableSessions(forProjectPath: project.path)
    }

    func supportsResumableSessions(forProjectPath path: String) -> Bool {
        projectCapabilities.supportsResumableSessions(for: path) ?? supportsResumableSessions
    }

    func supportsOverviewDashboard(forProjectPath path: String) -> Bool {
        projectCapabilities[path]?.supportsOverviewDashboard ?? false
    }

    /// Active project cwd changed: keep the workspace project list, reload
    /// sessions for the new project, and refresh adapter-facing catalogs.
    func onActiveProjectChanged() {
        dashboardURL = nil
        dashboardTitle = nil
        detailPane = .conversation
        Task { await reloadProjects() }
        if let workspace {
            loadSessions(for: workspace.path)
            applyAdapterCapabilities(forProjectPath: workspace.path)
        }
    }

    func updateSessionAttention(sessionID: String, needsAttention: Bool) {
        // Migration Restart / resolved reviews clear attention — drop the live
        // composer card even if the sidebar row was already archived away.
        if !needsAttention {
            pendingPermissionsBySession.removeValue(forKey: sessionID)
            refreshPermissionActivity()
        }
        guard let workspace else { return }
        let path = workspace.path
        guard var sessions = sessionsByProject[path] else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let existing = sessions[idx]
        sessions[idx] = SessionSummary(
            id: existing.id,
            agentID: existing.agentID,
            workspace: existing.workspace,
            title: existing.title,
            lastActivity: existing.lastActivity,
            messageCount: existing.messageCount,
            gitBranch: existing.gitBranch,
            needsAttention: needsAttention,
            isOverview: existing.isOverview,
            overviewURL: existing.overviewURL,
            archived: existing.archived,
            supersededAt: existing.supersededAt,
            historyImportState: existing.historyImportState
        )
        sessionsByProject[path] = sessions
    }

    /// Wipe orange attention dots for every chat in a project (Restart ACP CLI).
    func clearAllSessionAttention(for projectPath: String) {
        guard var sessions = sessionsByProject[projectPath] else { return }
        sessions = sessions.map { existing in
            SessionSummary(
                id: existing.id,
                agentID: existing.agentID,
                workspace: existing.workspace,
                title: existing.title,
                lastActivity: existing.lastActivity,
                messageCount: existing.messageCount,
                gitBranch: existing.gitBranch,
                needsAttention: false,
                isOverview: existing.isOverview,
                overviewURL: existing.overviewURL,
                archived: existing.archived,
                supersededAt: existing.supersededAt,
                historyImportState: existing.historyImportState
            )
        }
        sessionsByProject[projectPath] = sessions
    }
}
