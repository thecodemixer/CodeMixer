import Foundation
import AgentCore
import AgentProtocol

enum SessionSwitchingTiming {
    static let emptySessionFallback: Duration = .seconds(2)

    /// Adapters that declare `.sessionHandshakeGate` can spend their first
    /// seconds in protocol bootstrap before they accept a prompt. Keep the
    /// composer honest during that cold start, but never indefinitely.
    static let sessionHandshakeHardUnlock: Duration = .seconds(45)

    /// Same-project ACP/Cursor switch on an already-live process (`session/load`).
    /// Still waits for SessionStart, but must not look like a 45s cold spawn.
    static let warmSessionSwitchHardUnlock: Duration = .seconds(12)

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
        await applyProjectList(refs)
    }

    /// Lazily list the resumable sessions for a project. A non-resumable agent
    /// (or an empty result) is a first-class empty state, not an error.
    /// Subsequent refreshes update the list silently (no skeleton) so the
    /// navigator doesn't flash on every session switch.
    public func loadSessions(for projectPath: String) {
        guard supportsResumableSessions(forProjectPath: projectPath), sessionLister != nil else {
            sessionsByProject[projectPath] = []
            return
        }
        Task { @MainActor [weak self] in
            await self?.reloadSessions(for: projectPath)
        }
    }

    /// Awaitable session list used by overview open paths so we do not mint a
    /// second control chat before the persisted overview row is known.
    @discardableResult
    public func reloadSessions(for projectPath: String) async -> [SessionSummary] {
        guard supportsResumableSessions(forProjectPath: projectPath), let lister = sessionLister else {
            sessionsByProject[projectPath] = []
            return []
        }
        if sessionsByProject[projectPath] == nil {
            loadingProjectPaths.insert(projectPath)
        }
        let url = URL(fileURLWithPath: projectPath)
        let sessions = SessionNavigatorFiltering.preferringSingleOverview(await lister(url))
        sessionsByProject[projectPath] = sessions
        loadingProjectPaths.remove(projectPath)
        // After migration Restart, archived chats disappear from the list — drop
        // any leftover permission cards that belonged to those session ids.
        let liveIDs = Set(sessions.map(\.id))
        pendingPermissionsBySession = pendingPermissionsBySession.filter { key, _ in
            key == Self.unscopedPermissionSessionKey || liveIDs.contains(key)
        }
        refreshPermissionActivity()
        return sessions
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
        if isCurrentSession(projectPath: projectPath, sessionID: id) {
            showsOverviewDashboard = false
            return
        }
        // Capabilities must be known before arming the composer lock — Cursor /
        // ACP need the longer handshake gate, not the 3s resume unlock.
        applyAdapterCapabilities(forProjectPath: projectPath)
        // File / chat sessions always leave the dashboard WebView.
        showsOverviewDashboard = false
        // The session list carries the concrete agent for mixed projects. Use it
        // to decide whether history replay is enough to unlock the composer.
        // Claude Code is special because replayed history comes from JSONL,
        // while the live `claude --resume` PTY can still be restoring.
        let alreadyLiveOnProject = isLiveOnProject(projectPath)
        beginSessionSwitch(projectPath: projectPath,
                           sessionID: id,
                           waitsForClaudeCodeResume: sessionResumeNeedsClaudeCodeReadiness(projectPath: projectPath,
                                                                                           sessionID: id),
                           isWarmACPSwitch: alreadyLiveOnProject)
        send(.openProject(path: projectPath, resumeSessionID: id))
    }

    /// True when this project already has a live agent process we can warm-switch
    /// (dashboard up or a session already bound) — not a cold binary spawn.
    private func isLiveOnProject(_ projectPath: String) -> Bool {
        let target = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let current = workspace.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        }
        guard current == target else { return false }
        return sessionID != nil || dashboardURL != nil
    }

    /// Prefer the live `dashboardURL`; fall back to any persisted overview URL
    /// so chat→overview never lands on the empty placeholder.
    private func restoreDashboardURLIfNeeded(projectPath: String) {
        guard dashboardURL == nil, !isRestartingCustomACPCLI else { return }
        let sessions = sessionsByProject[projectPath] ?? []
        if let url = sessions.first(where: { $0.isOverview })?.overviewURL
            ?? sessions.compactMap(\.overviewURL).first {
            dashboardURL = url
        }
    }

    /// Make `projectPath` the current project. For overview-capable agents,
    /// shows the dashboard by default. Otherwise opens the most recent session when known.
    public func selectProject(path projectPath: String) {
        guard !projectPath.isEmpty else { return }
        guard projectPath != workspace?.path else {
            // Re-clicking the active overview project re-focuses the dashboard.
            if supportsOverviewDashboard(forProjectPath: projectPath) {
                selectDashboardOverview(projectPath: projectPath)
            }
            return
        }
        applyAdapterCapabilities(forProjectPath: projectPath)
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

    /// Open the project-owned overview/dashboard entry. This is intentionally
    /// separate from project-title expand/collapse in the sidebar.
    public func openOverview(projectPath: String) {
        guard !projectPath.isEmpty else { return }
        applyAdapterCapabilities(forProjectPath: projectPath)
        let sameProject = workspace.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        } == URL(fileURLWithPath: projectPath).standardizedFileURL.path

        if sameProject {
            selectDashboardOverview(projectPath: projectPath)
            return
        }

        let target = URL(fileURLWithPath: projectPath).standardizedFileURL
        workspace = target
        clearConversationState()
        sessionID = nil
        showsOverviewDashboard = true
        restoreDashboardURLIfNeeded(projectPath: projectPath)
        send(.openProject(path: projectPath, resumeSessionID: nil))
    }

    /// Overview is a dashboard surface, not a resumable session.
    private func selectDashboardOverview(projectPath: String) {
        workspace = URL(fileURLWithPath: projectPath).standardizedFileURL
        sessionID = nil
        clearConversationState()
        refreshPermissionActivity()
        endSessionSwitch()
        unlockComposerForSessionResume()
        status = .idle
        activity = .idle
        showsOverviewDashboard = true
        restoreDashboardURLIfNeeded(projectPath: projectPath)
        // WKWebView is torn down while a file chat is selected; bump so the
        // representable reloads instead of painting a dead process page.
        dashboardLoadGeneration += 1
    }

    /// Start a fresh chat in the current project (toolbar / palette New Chat).
    public func newChatInCurrentProject() {
        guard let path = workspace?.path, !path.isEmpty else { return }
        newChat(in: path)
    }

    /// Whether the project is a user-configured Custom ACP agent (not Cursor/Claude/Codex).
    public func isCustomACPProject(_ project: WorkspaceProjectsStore.ProjectRef) -> Bool {
        if case .custom(let ref) = project.projectType {
            return ref.transport == .agentClientProtocol
        }
        return false
    }

    /// Kill and respawn the Custom ACP CLI for `projectPath`.
    ///
    /// Sequentially closes the live process, waits for teardown, then cold-opens
    /// the project. The overview WebView stays hidden until the new agent
    /// advertises `agentDashboard` so a stale page from the old port cannot stick.
    public func restartCustomACPCLI(projectPath: String) {
        guard !projectPath.isEmpty,
              let project = projects.first(where: {
                  URL(fileURLWithPath: $0.path).standardizedFileURL.path
                      == URL(fileURLWithPath: projectPath).standardizedFileURL.path
              }),
              isCustomACPProject(project) else { return }
        guard !isRestartingCustomACPCLI else { return }

        let target = URL(fileURLWithPath: projectPath).standardizedFileURL
        endSessionSwitch()
        workspace = target
        sessionID = nil
        clearConversationState()
        clearAllPendingPermissions()
        clearAllSessionAttention(for: target.path)
        status = .working(phrase: "Restarting ACP CLI…")
        activity = .idle
        dashboardURL = nil
        dashboardTitle = nil
        dashboardLoadGeneration += 1
        isRestartingCustomACPCLI = true
        customACPRestartAwaitingDashboard = false
        applyAdapterCapabilities(forProjectPath: target.path)
        showsOverviewDashboard = supportsOverviewDashboard(forProjectPath: target.path)
        if projectNeedsSessionHandshakeGate(path: target.path) {
            lockComposerForSessionHandshake()
        }

        Task { @MainActor [weak self] in
            await self?.performCustomACPCLIRestart(projectPath: target.path)
        }
    }

    /// Close → brief settle → cold open. Completes when commands are accepted;
    /// `isRestartingCustomACPCLI` clears on the next `agentDashboard` event.
    private func performCustomACPCLIRestart(projectPath: String) async {
        let action = ClientAction(
            id: random.uuid(),
            kind: .sessionLifecycle,
            title: "Session",
            detail: "Restart ACP CLI"
        )
        do {
            try await engine.send(.recordClientAction(action))
            // Explicit teardown first so openProject cannot warm-resume a zombie.
            try await engine.send(.closeSession)
            try await clock.sleep(for: .milliseconds(300))
            // From this point on, the next dashboard advertisement should come
            // from the respawned process. Set this before `openProject` because
            // ACP initialize can emit `agentDashboard` before send(_:) returns.
            customACPRestartAwaitingDashboard = true
            try await engine.send(.openProject(path: projectPath, resumeSessionID: nil))
        } catch {
            isRestartingCustomACPCLI = false
            customACPRestartAwaitingDashboard = false
            status = .idle
            let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
            diagnostics.append(diagnostic(level: .error, message: message))
        }
    }

    /// Start a fresh chat in `projectPath`.
    ///
    /// Claude / Codex always reopen with no resume id so the local conversation
    /// and agent session stay aligned (Codex `.newSession` can no-op; Claude
    /// `/clear` does not reliably clear Codemixer history).
    ///
    /// Cursor / ACP already have a live `cursor-agent acp` process after the
    /// first open — reuse it via `.newSession` (`session/new`, ~3s) instead of
    /// respawning the binary (~20s initialize/auth handshake).
    public func newChat(in projectPath: String) {
        guard !projectPath.isEmpty else { return }
        endSessionSwitch()
        let target = URL(fileURLWithPath: projectPath).standardizedFileURL
        let alreadyOnProject = workspace.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        } == target.path
        workspace = target
        sessionID = nil
        clearConversationState()
        clearAllPendingPermissions()
        status = .idle
        activity = .idle
        applyAdapterCapabilities(forProjectPath: target.path)
        // New Chat is always the conversation surface — never the overview WebView.
        showsOverviewDashboard = false
        if projectNeedsSessionHandshakeGate(path: target.path) {
            lockComposerForSessionHandshake()
            if alreadyOnProject {
                startNewSession()
                return
            }
        }
        send(.openProject(path: target.path, resumeSessionID: nil))
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
            try await WorkspaceLifecycle(model: self).ensureModels(for: projectType)
            let refs = await store.projects(for: workspaceRoot, rootProjectType: projectType)
            await applyProjectList(refs)
            applyAdapterCapabilities(for: projectType, projectURL: URL(fileURLWithPath: ref.path))
            newChat(in: ref.path)
        } catch {
            recordProjectError(error)
        }
    }

    /// Register an existing folder as a project of the workspace.
    /// Blocks until the project is registered and its model catalog is ready.
    public func addExistingProject(url: URL, projectType: ProjectType) async {
        guard let workspaceRoot, let store = workspaceProjects else { return }
        do {
            let ref = try await store.addExistingProject(url: url, projectType: projectType, in: workspaceRoot)
            try await WorkspaceLifecycle(model: self).ensureModels(for: projectType)
            let refs = await store.projects(for: workspaceRoot, rootProjectType: projectType)
            await applyProjectList(refs)
            applyAdapterCapabilities(for: projectType, projectURL: URL(fileURLWithPath: ref.path))
            newChat(in: ref.path)
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
            let models: [AgentModelOption]
            do {
                models = try await self.loadModels(for: adapter)
            } catch {
                await MainActor.run {
                    guard self.shouldApplyAdapterCapabilities(
                        generation: generation,
                        expectedPath: expectedPath
                    ) else { return }
                    self.diagnostics.append(self.diagnostic(
                        level: .error,
                        message: error.localizedDescription
                    ))
                    self.availableModels = []
                }
                return
            }
            let agentModes = adapter.availableAgentModes()
            let resumable = adapter.capabilities.contains(.resumableSessions)
            let builtIn = adapter.slashCommandCatalog
            let projectCommands: [SlashCommand]
            if let url {
                projectCommands = await adapter.enumerateProjectCommands(workspace: url)
            } else {
                projectCommands = []
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

    /// Loads model catalogs for every shipping adapter used by projects in this
    /// workspace. Catalogs are read from per-adapter workspace files when
    /// fresh enough; otherwise adapters are probed and the result is persisted.
    /// Throws if any required catalog cannot be populated.
    public func warmWorkspaceModelCatalogs() async throws {
        guard workspaceRoot != nil, workspaceProjects != nil else {
            workspaceModelCatalogRows = []
            return
        }
        let agentIDs = Self.modelCatalogAgentIDs(in: projects)
        for agentID in agentIDs {
            try await ensureModelsLoaded(for: agentID)
        }
        await reloadWorkspaceModelCatalogStatus()
    }

    /// Ensures every shipping adapter required by `projectType` has a
    /// non-empty model catalog. Mixed projects require all shipping adapters.
    public func ensureModelsLoaded(for projectType: ProjectType) async throws {
        for agentID in Self.modelCatalogAgentIDs(for: projectType) {
            try await ensureModelsLoaded(for: agentID)
        }
    }

    /// Ensures `agentID` has a non-empty in-memory catalog, warming from the
    /// per-adapter workspace file or a live probe as needed.
    public func ensureModelsLoaded(for agentID: AgentID) async throws {
        guard AgentID.shipping.contains(agentID) else { return }
        guard let adapter = await AdapterRegistry.shared.adapter(for: agentID) else {
            throw ModelCatalogLoadError.adapterUnavailable(agentID)
        }
        let models = try await loadModels(for: adapter)
        guard !models.isEmpty else {
            throw ModelCatalogLoadError.emptyCatalog(adapter.displayName)
        }
    }

    /// Manual adapters (Claude) use the workspace cache with no TTL. Automatic
    /// adapters reuse a disk cache for at most
    /// `ModelCatalogTiming.automaticCatalogMaxAge`, then re-probe. A flaky
    /// empty/failed probe keeps the previous on-disk catalog when one exists
    /// and records a warning diagnostic. Freshness is decided from the
    /// workspace adapter file — not process-local `availableModels()` — so
    /// background probes (e.g. Cursor binary locate) cannot skip a due daily
    /// refresh.
    func loadModels(for adapter: any AgentAdapter) async throws -> [AgentModelOption] {
        let kind = adapter.modelCatalogRefreshKind()
        guard let workspaceRoot, let store = workspaceProjects else {
            return try await probeAndSeed(adapter)
        }

        let cached = await store.cachedModels(for: adapter.id, in: workspaceRoot)
        if let cached, !cached.models.isEmpty, Self.shouldUseCachedModels(cached, kind: kind, now: clock.now()) {
            adapter.seedModelCatalog(cached.models)
            return cached.models
        }

        do {
            let models = try await adapter.refreshModelCatalog()
            guard !models.isEmpty else {
                if let cached, !cached.models.isEmpty {
                    adapter.seedModelCatalog(cached.models)
                    noteRetainedModelCatalog(
                        for: adapter,
                        reason: "empty catalog"
                    )
                    return cached.models
                }
                return models
            }
            try await store.saveModels(
                models,
                for: adapter.id,
                refreshedAt: clock.now(),
                in: workspaceRoot
            )
            adapter.seedModelCatalog(models)
            return models
        } catch {
            if let cached, !cached.models.isEmpty {
                adapter.seedModelCatalog(cached.models)
                noteRetainedModelCatalog(
                    for: adapter,
                    reason: error.localizedDescription
                )
                return cached.models
            }
            throw error
        }
    }

    /// User-triggered model refresh from Workspace settings (manual and automatic).
    public func refreshAdapterModels(for agentID: AgentID) async {
        guard let workspaceRoot, let store = workspaceProjects else {
            diagnostics.append(diagnostic(
                level: .error,
                message: "Open a workspace before refreshing models."
            ))
            return
        }
        guard let adapter = await AdapterRegistry.shared.adapter(for: agentID) else {
            diagnostics.append(diagnostic(
                level: .error,
                message: "Adapter unavailable for model refresh."
            ))
            return
        }
        let previous = await store.cachedModels(for: agentID, in: workspaceRoot)
        modelCatalogRefreshInFlight = agentID
        defer { modelCatalogRefreshInFlight = nil }
        do {
            let models = try await adapter.refreshModelCatalog()
            guard !models.isEmpty else {
                if let previous, !previous.models.isEmpty {
                    adapter.seedModelCatalog(previous.models)
                }
                throw ModelCatalogLoadError.emptyCatalog(adapter.displayName)
            }
            try await store.saveModels(
                models,
                for: agentID,
                refreshedAt: clock.now(),
                in: workspaceRoot
            )
            adapter.seedModelCatalog(models)
            await reloadWorkspaceModelCatalogStatus()
            if let activePath = workspace?.path,
               let activeType = projects.first(where: { $0.path == activePath })?.projectType,
               activeType.primaryAgentID == agentID {
                availableModels = models
            }
        } catch {
            if let previous, !previous.models.isEmpty {
                adapter.seedModelCatalog(previous.models)
            }
            diagnostics.append(diagnostic(
                level: .error,
                message: "Model refresh failed: \(error.localizedDescription)"
            ))
        }
    }

    public func reloadWorkspaceModelCatalogStatus() async {
        guard let workspaceRoot, let store = workspaceProjects else {
            workspaceModelCatalogRows = []
            return
        }
        var rows: [WorkspaceModelCatalogRow] = []
        for agentID in Self.modelCatalogAgentIDs(in: projects) {
            guard let entry = SupportedBuiltInAgent.entry(for: agentID) else { continue }
            let adapter = await AdapterRegistry.shared.adapter(for: agentID)
            let kind = adapter?.modelCatalogRefreshKind() ?? .automatic
            let cached = await store.cachedModels(for: agentID, in: workspaceRoot)
            let modelCount: Int
            if let cached, !cached.models.isEmpty {
                modelCount = cached.models.count
            } else {
                modelCount = adapter?.availableModels().count ?? 0
            }
            rows.append(WorkspaceModelCatalogRow(
                agentID: entry.id,
                displayName: entry.displayLabel,
                refreshKind: kind,
                modelCount: modelCount,
                refreshedAt: cached?.refreshedAt
            ))
        }
        workspaceModelCatalogRows = rows
    }

    private static func shouldUseCachedModels(
        _ cached: WorkspaceAdapterLocalState.CachedAdapterModels,
        kind: ModelCatalogRefreshKind,
        now: Date
    ) -> Bool {
        switch kind {
        case .manual:
            return !cached.models.isEmpty
        case .automatic:
            guard !cached.models.isEmpty, let refreshedAt = cached.refreshedAt else {
                return false
            }
            return now.timeIntervalSince(refreshedAt) < ModelCatalogTiming.automaticCatalogMaxAge
        }
    }

    private func noteRetainedModelCatalog(for adapter: any AgentAdapter, reason: String) {
        diagnostics.append(diagnostic(
            level: .warning,
            message: """
                \(adapter.displayName) model refresh failed (\(reason)); \
                using cached models.
                """
        ))
    }

    private func probeAndSeed(_ adapter: any AgentAdapter) async throws -> [AgentModelOption] {
        let models = try await adapter.refreshModelCatalog()
        if !models.isEmpty {
            adapter.seedModelCatalog(models)
        }
        return models.isEmpty ? adapter.availableModels() : models
    }

    /// Shipping agents whose model catalogs are required for `projectType`.
    /// Mixed projects can switch among all shipping CLIs, so every shipping
    /// adapter is required. Custom projects have no shipping catalog.
    static func modelCatalogAgentIDs(for projectType: ProjectType) -> [AgentID] {
        switch projectType {
        case .claudeCode, .codex, .cursorCLI:
            if let id = projectType.primaryAgentID { return [id] }
            return []
        case .mixed:
            return SupportedBuiltInAgent.shippingIDs()
        case .custom:
            return []
        }
    }

    /// Deduped shipping agent IDs required by the current workspace projects.
    static func modelCatalogAgentIDs(
        in projects: [WorkspaceProjectsStore.ProjectRef]
    ) -> [AgentID] {
        var ordered: [AgentID] = []
        var seen: Set<AgentID> = []
        for project in projects {
            for id in modelCatalogAgentIDs(for: project.projectType) where seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
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

    func beginSessionSwitch(projectPath: String,
                            sessionID id: String,
                            waitsForClaudeCodeResume: Bool = false,
                            isWarmACPSwitch: Bool = false) {
        workspace = URL(fileURLWithPath: projectPath).standardizedFileURL
        sessionID = id
        clearConversationState()
        // Activity follows the newly selected session — unrelated parked reviews
        // stay in `pendingPermissionsBySession` and only show their orange dots.
        refreshPermissionActivity()
        status = .idle
        isSwitchingSession = true
        // Cursor / ACP cold start (~20s) needs the handshake gate. A 3s unlock
        // lets the first prompt race `session/load` and vanish into the queue.
        // Same-project switches on a live process only wait for `session/load`.
        if !waitsForClaudeCodeResume, projectNeedsSessionHandshakeGate(path: projectPath) {
            if isWarmACPSwitch {
                lockComposerForWarmSessionSwitch()
            } else {
                lockComposerForSessionHandshake()
            }
        } else {
            lockComposerForSessionResume(waitsForClaudeCodeResume: waitsForClaudeCodeResume)
        }
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
        // Handshake-gated agents (Cursor / ACP) stream history during
        // `session/load` *before* the session is prompt-ready — keep locked.
        if isComposerLockedForSessionResume, !isComposerWaitingForClaudeCodeResume {
            if isComposerLockedForSessionHandshake {
                return
            }
            unlockComposerForSessionResume()
        }
    }

    func lockComposerForSessionResume(waitsForClaudeCodeResume: Bool = false) {
        isComposerLockedForSessionResume = true
        isComposerWaitingForClaudeCodeResume = waitsForClaudeCodeResume
        isComposerLockedForSessionHandshake = false
        isWarmSessionSwitch = false
        scheduleComposerResumeUnlock(after: waitsForClaudeCodeResume
            ? SessionSwitchingTiming.claudeCodeComposerHardUnlock
            : SessionSwitchingTiming.composerHardUnlock)
    }

    func lockComposerForSessionHandshake() {
        isComposerLockedForSessionResume = true
        isComposerWaitingForClaudeCodeResume = false
        isComposerLockedForSessionHandshake = true
        isWarmSessionSwitch = false
        scheduleComposerResumeUnlock(after: SessionSwitchingTiming.sessionHandshakeHardUnlock)
    }

    /// Same-project `session/load` on a live ACP/Cursor process — still gated
    /// until SessionStart, but not the cold-spawn 45s / "Starting session…" path.
    func lockComposerForWarmSessionSwitch() {
        isComposerLockedForSessionResume = true
        isComposerWaitingForClaudeCodeResume = false
        isComposerLockedForSessionHandshake = true
        isWarmSessionSwitch = true
        scheduleComposerResumeUnlock(after: SessionSwitchingTiming.warmSessionSwitchHardUnlock)
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
        isComposerLockedForSessionHandshake = false
        isWarmSessionSwitch = false
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

    func projectNeedsSessionHandshakeGate(path projectPath: String) -> Bool {
        if projectCapabilities.requiresSessionHandshakeGate(for: projectPath) {
            return true
        }
        // `applyAdapterCapabilities` is async; when the index is not warm yet,
        // fall back to project types that always ship with handshake-gated adapters.
        let standardized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let project = projects.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardized
        }) else { return false }
        switch project.projectType {
        case .cursorCLI, .custom:
            return true
        default:
            return false
        }
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

    func recordProjectError(_ error: any Error) {
        let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
        diagnostics.append(diagnostic(level: .error, message: message))
    }

    /// Active project cwd changed: keep the workspace project list, reload
    /// sessions for the new project, and refresh adapter-facing catalogs.
    func onActiveProjectChanged() {
        dashboardURL = nil
        dashboardTitle = nil
        showsOverviewDashboard = false
        refreshProjects()
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
            overviewURL: existing.overviewURL
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
                overviewURL: existing.overviewURL
            )
        }
        sessionsByProject[projectPath] = sessions
    }

    /// Called when the active workspace changes: refresh projects + load the
    /// active project's sessions so the navigator reflects the new state.
    func onWorkspaceChanged() {
        refreshProjects()
        if let workspace { loadSessions(for: workspace.path) }
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
