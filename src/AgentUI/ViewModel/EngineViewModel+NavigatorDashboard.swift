import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {
    /// Open the project-owned overview/dashboard entry. This is intentionally
    /// separate from project-title expand/collapse in the sidebar.
    public func openOverview(projectPath: String) {
        guard !projectPath.isEmpty else { return }
        if let project = projectRef(at: projectPath), project.projectType.isFolderBacked {
            openFolderProject(project, relativePath: nil)
            return
        }
        applyAdapterCapabilities(forProjectPath: projectPath)
        clearFolderBrowserSurface()
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
        detailPane = .dashboard
        restoreDashboardURLIfNeeded(projectPath: projectPath)
        send(.openProject(path: projectPath, resumeSessionID: nil))
    }

    /// Overview is a dashboard surface, not a resumable session.
    func selectDashboardOverview(projectPath: String) {
        let wasShowingOverview = showsOverviewDashboard
        workspace = URL(fileURLWithPath: projectPath).standardizedFileURL
        sessionID = nil
        clearConversationState()
        refreshPermissionActivity()
        endSessionSwitch()
        unlockComposerForSessionResume()
        status = .idle
        activity = .idle
        clearFolderBrowserSurface()
        detailPane = .dashboard
        restoreDashboardURLIfNeeded(projectPath: projectPath)
        // WKWebView is torn down while a file chat is selected; bump so the
        // representable reloads instead of painting a dead process page.
        // Skip when overview is already visible — remounting only flashes white.
        if !wasShowingOverview {
            dashboardLoadGeneration += 1
        }
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
        customACPRestartPhase = .tearingDown
        applyAdapterCapabilities(forProjectPath: target.path)
        detailPane = supportsOverviewDashboard(forProjectPath: target.path) ? .dashboard : .conversation
        if projectNeedsSessionHandshakeGate(path: target.path) {
            lockComposerForSessionHandshake()
        }

        Task { @MainActor [weak self] in
            await self?.performCustomACPCLIRestart(projectPath: target.path)
        }
    }

    /// Close → brief settle → cold open. Completes when commands are accepted;
    /// `customACPRestartPhase` returns to `.idle` on the next `agentDashboard` event.
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
            customACPRestartPhase = .awaitingDashboard
            try await engine.send(.openProject(path: projectPath, resumeSessionID: nil))
        } catch {
            customACPRestartPhase = .idle
            status = .idle
            let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
            diagnostics.append(diagnostic(level: .error, message: message))
        }
    }
}
