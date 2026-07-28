import Foundation
import AgentProtocol

extension AgentEngine {
    /// Project paths that currently have a live (active or parked) agent process.
    public func liveProjectPaths() async -> Set<String> {
        Set(runtimes.keys.map(\.projectPath))
    }

    func publishRuntimePoolChanged() async {
        log.notice("runtime pool size=\(self.runtimes.count, privacy: .public) active=\(self.activeKey?.projectPath ?? "none", privacy: .public)")
    }

    /// Park the active runtime without killing its transport.
    func parkActive() async {
        guard let key = activeKey, var runtime = runtimes[key] else { return }
        await stopFSWatcher()
        await heartbeat?.endTurn()
        heartbeat = nil
        currentTurnID = nil
        runtime.boundSessionID = currentSessionID
        runtime.lastActivatedAt = seams.clock.now()
        // Keep forwarding/bell tasks on the runtime; clear engine mirrors so
        // activate can rebind without closing the child.
        runtime.forwardingTask = eventForwardingTask ?? runtime.forwardingTask
        runtime.bellTask = bellTask ?? runtime.bellTask
        runtime.sessionIDContinuation = sessionIDContinuation ?? runtime.sessionIDContinuation
        runtime.hookServer = hookServer ?? runtime.hookServer
        runtimes[key] = runtime

        eventForwardingTask = nil
        bellTask = nil
        sessionIDContinuation = nil
        transport = nil
        hookServer = nil
        adapter = nil
        workspace = nil
        currentSessionID = nil
        activeKey = nil
        // Engine stays conceptually "running" while any runtime is parked.
        if !runtimes.isEmpty {
            state = .running(sessionID: nil)
        }
        await publishRuntimePoolChanged()
    }

    /// Make an existing pooled runtime the active UI target.
    @discardableResult
    func activate(key: AgentRuntimeKey, resumeSessionID: String?) async -> Bool {
        guard var runtime = runtimes[key] else { return false }
        if activeKey == key {
            // Already active — may still need in-process session switch.
            return await applyInProcessSessionSwitch(resumeSessionID: resumeSessionID)
        }
        if activeKey != nil {
            await parkActive()
        }

        activeKey = key
        adapter = runtime.adapter
        transport = runtime.transport
        hookServer = runtime.hookServer
        workspace = runtime.workspace
        sessionIDContinuation = runtime.sessionIDContinuation
        eventForwardingTask = runtime.forwardingTask
        bellTask = runtime.bellTask
        currentTurnID = nil

        let monitor = HeartbeatActivityMonitor(clock: seams.clock) { [weak self] tick in
            await self?.onHeartbeat(tick)
        }
        heartbeat = monitor

        let targetSession = resumeSessionID ?? runtime.boundSessionID
        let reactivatingSameSession = targetSession == runtime.boundSessionID
        transcript = []
        changedFiles = []
        currentSessionID = targetSession
        state = .running(sessionID: targetSession)
        runtime.lastActivatedAt = seams.clock.now()
        runtimes[key] = runtime

        await startFSWatcher(workspace: runtime.workspace)

        if let targetSession {
            await restoreHistory(for: SessionTranscriptKey(
                projectRoot: runtime.workspace,
                namespace: runtime.adapter.historyNamespace,
                sessionID: targetSession
            ))
        }
        if let resumeSessionID,
           resumeSessionID != runtime.boundSessionID {
            guard let bytes = runtime.adapter.encodeResumeSession(sessionID: resumeSessionID),
                  !bytes.isEmpty else {
                log.warning("pool activate missing encodeResumeSession; refusing warm path")
                return false
            }
            currentSessionID = resumeSessionID
            if var updated = runtimes[key] {
                updated.boundSessionID = resumeSessionID
                runtimes[key] = updated
            }
            do {
                try await runtime.transport.write(bytes)
                log.notice("pool activate + in-process resume session=\(resumeSessionID, privacy: .public)")
                // Interactive PTYs (Claude `/resume`) often do not re-emit
                // SessionStart; unlock from the resume write. ACP/Codex still
                // publish sessionStarted → sessionPromptReady after load/resume.
                if case .interactiveTerminal = runtime.adapter.transportDescriptor {
                    await markSessionPromptReady(resumeSessionID)
                }
            } catch {
                log.warning("pool activate resume write failed: \(String(describing: error), privacy: .public)")
                return false
            }
        } else if reactivatingSameSession, let targetSession {
            await markSessionPromptReady(targetSession)
        }
        await publishRuntimePoolChanged()
        return true
    }

    /// New Chat on a live pooled process (`session/new`, Codex thread start,
    /// Claude `/clear`). Never used to decide cold spawn — that only happens
    /// when the project has no pool slot yet.
    func applyWarmNewSession() async -> Bool {
        guard let key = activeKey, var runtime = runtimes[key] else { return false }
        guard let bytes = runtime.adapter.encodeCommand(.newSession), !bytes.isEmpty else {
            return false
        }
        transcript = []
        changedFiles = []
        currentTurnID = nil
        await heartbeat?.endTurn()
        currentSessionID = nil
        runtime.boundSessionID = nil
        runtimes[key] = runtime
        state = .running(sessionID: nil)
        do {
            try await runtime.transport.write(bytes)
            // Interactive PTYs (Claude `/clear`) typically do not re-emit
            // SessionStart; mint a local session id and unlock. ACP/Codex
            // publish sessionStarted → sessionPromptReady for the new thread.
            if case .interactiveTerminal = runtime.adapter.transportDescriptor {
                let localID = seams.random.uuid().uuidString
                currentSessionID = localID
                if var updated = runtimes[key] {
                    updated.boundSessionID = localID
                    runtimes[key] = updated
                }
                state = .running(sessionID: localID)
                await markSessionPromptReady(localID)
            }
            return true
        } catch {
            return false
        }
    }

    private func applyInProcessSessionSwitch(resumeSessionID: String?) async -> Bool {
        guard let key = activeKey, var runtime = runtimes[key] else { return false }
        guard let resumeSessionID else { return true }
        await restoreHistory(for: SessionTranscriptKey(
            projectRoot: runtime.workspace,
            namespace: runtime.adapter.historyNamespace,
            sessionID: resumeSessionID
        ))
        if runtime.boundSessionID == resumeSessionID {
            await markSessionPromptReady(resumeSessionID)
            return true
        }
        guard let bytes = runtime.adapter.encodeResumeSession(sessionID: resumeSessionID),
              !bytes.isEmpty else {
            return false
        }
        transcript = []
        changedFiles = []
        currentTurnID = nil
        await heartbeat?.endTurn()
        currentSessionID = resumeSessionID
        runtime.boundSessionID = resumeSessionID
        runtimes[key] = runtime
        state = .running(sessionID: resumeSessionID)
        do {
            try await runtime.transport.write(bytes)
            if case .interactiveTerminal = runtime.adapter.transportDescriptor {
                await markSessionPromptReady(resumeSessionID)
            }
            return true
        } catch {
            return false
        }
    }

    func shutdownAll(reason: AgentProtocol.StopReason) async {
        state = .stopping
        let keys = Array(runtimes.keys)
        for key in keys {
            await shutdownSlot(key, publishStopped: false, reason: reason)
        }
        activeKey = nil
        await teardownActiveMirror(.shutdown(reason: reason))
        runtimes.removeAll()
        await publishRuntimePoolChanged()
    }

    /// Tear down one pooled runtime. When it was active, clears the active mirror.
    func shutdownSlot(_ key: AgentRuntimeKey,
                      publishStopped: Bool,
                      reason: AgentProtocol.StopReason = .userCancel) async {
        guard let runtime = runtimes.removeValue(forKey: key) else {
            if activeKey == key {
                await clearActiveMirrorKeepingPool()
            }
            return
        }
        runtime.forwardingTask?.cancel()
        runtime.bellTask?.cancel()
        runtime.sessionIDContinuation?.finish()
        await runtime.transport.close()
        await runtime.hookServer?.stop()

        if activeKey == key {
            activeKey = nil
            eventForwardingTask = nil
            bellTask = nil
            sessionIDContinuation = nil
            transport = nil
            hookServer = nil
            adapter = nil
            workspace = nil
            currentSessionID = nil
            currentTurnID = nil
            await stopFSWatcher()
            await heartbeat?.endTurn()
            heartbeat = nil
            if publishStopped {
                await bus.publish(.stopped(reason: reason))
            }
        }

        if runtimes.isEmpty {
            state = .stopped
            sessionTeardownState = .idle
        } else if activeKey == nil {
            state = .running(sessionID: nil)
        }
        await publishRuntimePoolChanged()
    }

    func shutdownActiveSlot(reason: AgentProtocol.StopReason = .userCancel) async {
        guard let key = activeKey else {
            if state != .stopped {
                await teardownActiveMirror(.shutdown(reason: reason))
            }
            return
        }
        await shutdownSlot(key, publishStopped: true, reason: reason)
    }

    private func clearActiveMirrorKeepingPool() async {
        eventForwardingTask = nil
        bellTask = nil
        sessionIDContinuation = nil
        transport = nil
        hookServer = nil
        adapter = nil
        workspace = nil
        currentSessionID = nil
        activeKey = nil
        await stopFSWatcher()
        await heartbeat?.endTurn()
        heartbeat = nil
    }

    /// Resolve pool key for a project open, applying prefer-fresh identity.
    func runtimeKey(for project: WorkspaceProjectsStore.ProjectRef,
                    agentID: AgentID) -> AgentRuntimeKey {
        let instance: AgentInstanceIdentity
        if project.preferFreshAgentProcess {
            if case .dedicated(let id) = project.agentInstanceIdentity {
                instance = .dedicated(id)
            } else {
                instance = .dedicated(seams.random.uuid())
            }
        } else {
            instance = .shared
        }
        return AgentRuntimeKey(projectPath: project.path, agentID: agentID, instance: instance)
    }

    func findRuntime(projectPath: String, agentID: AgentID) -> AgentRuntimeKey? {
        let path = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        return runtimes.keys.first { $0.projectPath == path && $0.agentID == agentID }
    }
}
