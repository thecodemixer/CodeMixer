import Foundation
import AgentProtocol

extension AgentEngine {
    // MARK: - AgentEngineCommandPort

    public func send(_ command: AgentCommand) async throws {
        // Out-of-band commands don't need a running session — handle them
        // first so prefs / snapshots / pairing-related work succeeds whether
        // or not an adapter has been bound.
        if let handled = try await handleOutOfBand(command) { _ = handled; return }

        if case .openProject(let path, let resume) = command {
            try await openProject(path: path, resumeSessionID: resume)
            return
        }

        guard let adapter else { throw AgentError.internalInvariant(detail: "no adapter bound") }

        switch command {
        case .sendPrompt(let text, let attachments):
            let bubbleID = seams.random.uuid()
            lastUserBubbleID = bubbleID
            let prompt = try await promptText(text, attachments: attachments)
            let bytes = adapter.encodeUserPrompt(prompt)
            // Echo the turn BEFORE the awaited write so every connected surface
            // reflects the turn instantly. If the write then fails, `send` still
            // throws so the caller surfaces the error.
            //
            // ACP may return empty bytes while session/open is still in flight —
            // the prompt is queued in adapter state and flushed on SessionStart.
            // Do not start the heartbeat or leave the turn "awaiting acceptance"
            // forever in that case.
            await bus.publish(.userTurn(id: bubbleID.uuidString, text: prompt))
            if bytes.isEmpty {
                currentTurnID = bubbleID
                promptAcceptance = .queued(prompt: prompt)
                await bus.publish(.statusPhraseChanged(
                    source: .adapterPinned,
                    phrase: "Waiting for session…"
                ))
                return
            }
            currentTurnID = bubbleID
            promptAcceptance = .awaiting(prompt: prompt)
            await heartbeat?.startTurn(bubbleID, baseline: .awaitingFirstChunk)
            do {
                try await writePromptBytes(bytes)
            } catch {
                promptAcceptance = .idle
                currentTurnID = nil
                cancelStartupSubmitRecovery()
                await heartbeat?.endTurn()
                throw error
            }

        case .cancelCurrentTurn:
            let cancelBytes = adapter.cancelSequence()
            try await transport?.write(cancelBytes)
            if adapter.transportDescriptor.supportsOutOfBandInterrupt {
                await transport?.interrupt()
            }
            promptAcceptance = .idle
            cancelStartupSubmitRecovery()
            currentTurnID = nil
            await heartbeat?.endTurn()

        case .editAndResubmitLast(let target, let text, let attachments):
            guard target == lastUserBubbleID else {
                throw AgentError.staleEditTarget(targetID: target)
            }
            guard let ws = workspace else {
                throw AgentError.internalInvariant(detail: "editAndResubmitLast: no workspace")
            }
            // Snapshot live state before shutdown clears it.
            // `adapter` is guaranteed non-optional here (the guard above enforced it).
            let savedAdapter = adapter
            let savedSessionID = currentSessionID

            // Step 1: graceful terminate — send cancel bytes and allow 50ms drain.
            let cancelBytes = adapter.cancelSequence()
            try await transport?.write(cancelBytes)
            try await seams.clock.sleep(for: .milliseconds(50))

            // Step 2: atomic transcript truncation — strip everything after the
            // user turn being edited so the resumed session looks clean.
            var resumeSessionID: String?
            if let sid = savedSessionID,
               await savedAdapter.truncateTranscript(afterUserTurnID: target.uuidString,
                                                     sessionID: sid,
                                                     workspace: ws) {
                resumeSessionID = sid
            }

            // Step 3: shut down the current session.
            await shutdown(reason: .userCancel)

            // Step 4: respawn — with --resume if we truncated cleanly, else fresh.
            do {
                try await start(adapter: savedAdapter, workspace: ws, resumeSessionID: resumeSessionID)
            } catch {
                // Respawn failed; surface the error and leave the engine stopped.
                log.error("editAndResubmit respawn failed: \(error, privacy: .public)")
                throw error
            }

            // Step 5: send the revised prompt.
            let prompt = try await promptText(text, attachments: attachments)
            let bytes = savedAdapter.encodeUserPrompt(prompt)
            try await writePromptBytes(bytes)
            await bus.publish(.userTurn(id: target.uuidString, text: prompt))
            lastUserBubbleID = target

        case .respondToPermission(let id, let decision):
            permissionTimeouts.removeValue(forKey: id)?.cancel()
            guard let prompt = pendingPermissions.removeValue(forKey: id) else { return }
            try await deliverPermissionResponse(decision, for: prompt, id: id)
            // Trust screens can outlive the first resume-startup watchdog tick.
            // Once the dialog is gone, make sure a ready-poll / watchdog is alive
            // so a held sendPrompt can still flush.
            resumePollingAfterPermissionIfNeeded()

        case .newSession,
             .compact,
             .selectModel,
             .setPermissionMode,
             .setAgentMode,
             .runSlashCommand:
            guard let bytes = adapter.encodeCommand(command) else {
                await bus.publish(.error(.unsupportedCommand(name: String(describing: command))))
                return
            }
            try await writePromptBytes(bytes)

        case .closeSession:
            await shutdown(reason: .userCancel)

        case .openProject,
             .speakAssistantBubble, .revertFile, .revertHunk,
             .updateAutoApprovalRules, .updateAppearancePref, .requestSnapshot,
             .recordClientAction:
            // Already handled in `handleOutOfBand`.
            break
        }
    }

    /// Handles commands that don't need a running adapter (prefs, snapshots,
    /// TTS, revert). Returns a non-nil placeholder when the command was
    /// recognised so the main switch can skip it.
    private func handleOutOfBand(_ command: AgentCommand) async throws -> Void? {
        switch command {
        case .speakAssistantBubble(let eventID, let action):
            await bus.publish(.speakBubbleRequested(eventID: eventID, action: action))
            return ()
        case .revertFile(let path):
            try await gitReverter.checkout(path: path, workspace: workspace)
            await bus.publish(.fileReverted(path: path))
            return ()
        case .revertHunk(let path, let hunkID):
            try await gitReverter.revertHunk(path: path,
                                             hunkID: hunkID,
                                             workspace: workspace)
            await bus.publish(.fileReverted(path: path))
            return ()
        case .updateAutoApprovalRules(let rules):
            try await prefs.updateRules(rules)
            let state = await prefs.state()
            await bus.publish(.prefsChanged(rulesCount: state.autoApprovalRules.count))
            return ()
        case .updateAppearancePref(let patch):
            try await prefs.updateAppearance(patch)
            await bus.publish(.appearancePrefChanged(key: patch.key, value: patch.value))
            return ()
        case .requestSnapshot(let kind):
            let data = await snapshots.snapshot(
                kind,
                conversation: transcript.map { ($0.role, $0.text, $0.timestamp) },
                sessionID: currentSessionID,
                changedFiles: changedFiles,
                workspace: workspace
            )
            await bus.publish(.snapshotReady(kind: kind, payload: data))
            return ()
        case .recordClientAction(let action):
            let text = action.detail.map { "\(action.title): \($0)" } ?? action.title
            transcript.append(.init(role: "action", text: text, timestamp: seams.clock.now()))
            await bus.publish(.clientAction(action))
            return ()
        default:
            return nil
        }
    }

    private func openProject(path: String, resumeSessionID: String?) async throws {
        let projectURL = URL(fileURLWithPath: path).standardizedFileURL
        let store = WorkspaceProjectsStore(environment: seams.environment,
                                           fileSystem: seams.fileSystem)
        await store.load()
        let project: WorkspaceProjectsStore.ProjectRef
        if let match = await store.project(path: projectURL.path) {
            project = match
        } else if let match = await store.project(path: path) {
            project = match
        } else {
            throw AgentError.unsupportedOperation(
                detail: "Project \(path) has no stored project type. Open it from the project picker and choose an agent first."
            )
        }

        let sessionAgentID = await sessionAgentID(for: resumeSessionID,
                                                  workspace: projectURL,
                                                  mode: project.projectType)
        guard let nextAdapter = await ProjectAgentRouter.resolveAdapter(projectType: project.projectType,
                                                                        sessionAgentID: sessionAgentID) else {
            if project.projectType.isFolderBacked {
                throw AgentError.unsupportedOperation(
                    detail: "Folder project \(path) is opened in the folder browser, not as an agent session."
                )
            }
            throw AgentError.unsupportedOperation(
                detail: "Project \(path) needs a concrete registered agent before it can be opened."
            )
        }

        // Warm ACP/Cursor path: same workspace + live process → `session/load`
        // (~1–3s) instead of respawning the binary (~20s initialize/auth).
        if let resumeSessionID,
           await tryWarmResume(
            projectURL: projectURL,
            resumeSessionID: resumeSessionID,
            nextAdapter: nextAdapter
           ) {
            return
        }

        if resumeSessionID != nil {
            log.notice("cold openProject after warm miss session=\(resumeSessionID ?? "", privacy: .public)")
        }
        await shutdown(reason: .userCancel)
        try await start(adapter: nextAdapter,
                        workspace: projectURL,
                        resumeSessionID: resumeSessionID,
                        permissionMode: .default)
    }

    /// Returns `true` when the live agent accepted a same-process session load.
    private func tryWarmResume(projectURL: URL,
                               resumeSessionID: String,
                               nextAdapter: any AgentAdapter) async -> Bool {
        guard case .running = state else {
            await recordWarmMiss(reason: "engine not running", sessionID: resumeSessionID)
            return false
        }
        guard let live = adapter else {
            await recordWarmMiss(reason: "no live adapter", sessionID: resumeSessionID)
            return false
        }
        // Custom ACP adapters all use AgentID.other — prefer instance identity when
        // both sides are class instances so a cache-miss adapter cannot block warm.
        let sameAdapter: Bool = {
            if let liveObj = live as AnyObject?, let nextObj = nextAdapter as AnyObject? {
                return liveObj === nextObj || live.id == nextAdapter.id
            }
            return live.id == nextAdapter.id
        }()
        guard sameAdapter else {
            await recordWarmMiss(reason: "adapter mismatch live=\(live.id.rawValue) next=\(nextAdapter.id.rawValue)",
                                 sessionID: resumeSessionID)
            return false
        }
        guard live.capabilities.contains(.sessionHandshakeGate) else {
            await recordWarmMiss(reason: "adapter lacks sessionHandshakeGate", sessionID: resumeSessionID)
            return false
        }
        guard let currentWorkspace = workspace,
              Self.sameWorkspacePath(currentWorkspace, projectURL) else {
            await recordWarmMiss(reason: "workspace path mismatch", sessionID: resumeSessionID)
            return false
        }
        guard let bytes = live.encodeResumeSession(sessionID: resumeSessionID),
              !bytes.isEmpty else {
            await recordWarmMiss(reason: "encodeResumeSession empty", sessionID: resumeSessionID)
            return false
        }
        transcript = []
        changedFiles = []
        currentTurnID = nil
        promptAcceptance = .idle
        cancelStartupSubmitRecovery()
        await heartbeat?.endTurn()
        // Preset so same-id SessionStart still publishes for UI unlock.
        currentSessionID = resumeSessionID
        state = .running(sessionID: resumeSessionID)
        do {
            try await transport?.write(bytes)
            log.notice("warm session/load session=\(resumeSessionID, privacy: .public)")
            return true
        } catch {
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "AgentEngine",
                summary: "warm session/load write failed; falling back to cold open",
                details: String(describing: error)
            )
            return false
        }
    }

    private func recordWarmMiss(reason: String, sessionID: String) async {
        await SilentDiagnostics.shared.record(
            kind: .other,
            owner: "AgentEngine",
            summary: "warm session/load skipped; cold open",
            details: "\(reason) session=\(sessionID)"
        )
    }

    /// `standardizedFileURL` does not resolve symlinks (`/var` vs `/private/var`).
    private static func sameWorkspacePath(_ a: URL, _ b: URL) -> Bool {
        let aStd = a.standardizedFileURL.path
        let bStd = b.standardizedFileURL.path
        if aStd == bStd { return true }
        return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    private func sessionAgentID(for resumeSessionID: String?,
                                workspace: URL,
                                mode: ProjectType) async -> AgentID? {
        guard let resumeSessionID else { return nil }
        guard case .mixed = mode else { return nil }
        let adapters = await AdapterRegistry.shared.all()
        for adapter in adapters where adapter.capabilities.contains(.resumableSessions) {
            let sessions = await adapter.listResumableSessions(workspace: workspace)
            if let match = sessions.first(where: { $0.id == resumeSessionID }) {
                return match.agentID
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func promptText(_ text: String, attachments: [AttachmentRef]) async throws -> String {
        let urls = try await attachmentResolver.resolve(attachments)
        guard !urls.isEmpty else { return text }
        let refs = urls.map { "@\($0.path)" }.joined(separator: "\n")
        return text.isEmpty ? refs : "\(text)\n\(refs)"
    }

    private func writePromptBytes(_ bytes: Data) async throws {
        await waitForResumeStartupIfNeeded()
        guard let transport else {
            throw AgentError.internalInvariant(detail: "transport closed before prompt write")
        }
        try await transport.write(bytes)
        // Independent safety net for the very first real prompt of a freshly
        // started TUI session: if the readiness heuristic was fooled and the
        // submit key or whole write was swallowed, recover based on the visible
        // input row. Hook/user echoes and assistant activity cancel this before
        // it can duplicate an accepted prompt.
        if startupSubmitRecoveryArmed, let turnID = currentTurnID {
            startupSubmitRecoveryArmed = false
            armStartupSubmitRecovery(turnID: turnID, promptBytes: bytes)
        }
    }
}
