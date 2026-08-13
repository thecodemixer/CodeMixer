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
            guard case .ready = sessionActivationState else {
                throw AgentError.sessionReadinessFailed(
                    sessionID: currentSessionID ?? "",
                    detail: "Wait for the adapter to finish connecting, then retry."
                )
            }
            let bubbleID = seams.random.uuid()
            let adapterTurnID = AdapterTurnID(rawValue: bubbleID.uuidString)
            lastUserAdapterTurnID = adapterTurnID
            let prompt = try await promptText(text, attachments: attachments)
            let bytes = adapter.encodeUserPrompt(prompt)
            guard !bytes.isEmpty else {
                throw AgentError.sessionReadinessFailed(
                    sessionID: currentSessionID ?? "",
                    detail: "The adapter reported readiness but did not encode the prompt."
                )
            }
            // Echo the turn BEFORE the awaited write so every connected surface
            // reflects the turn instantly. If the write then fails, `send` still
            // throws so the caller surfaces the error.
            await record(.userTurn(id: adapterTurnID, text: prompt))
            await bus.publish(.userTurn(id: adapterTurnID, text: prompt))
            currentTurnID = bubbleID
            await heartbeat?.startTurn(bubbleID, baseline: .awaitingFirstChunk)
            do {
                try await writePromptBytes(bytes)
            } catch {
                currentTurnID = nil
                await heartbeat?.endTurn()
                throw error
            }

        case .cancelCurrentTurn:
            let cancelBytes = adapter.cancelSequence()
            try await transport?.write(cancelBytes)
            if adapter.transportDescriptor.supportsOutOfBandInterrupt {
                await transport?.interrupt()
            }
            currentTurnID = nil
            await heartbeat?.endTurn()

        case .editAndResubmitLast(let target, let text, let attachments):
            guard target == lastUserEntryID, let adapterTurnID = lastUserAdapterTurnID else {
                throw AgentError.staleEditTarget(targetID: target)
            }
            guard let ws = workspace else {
                throw AgentError.internalInvariant(detail: "editAndResubmitLast: no workspace")
            }
            let savedWorkingDirectory = workingDirectory ?? ws
            let revisedPrompt = try await promptText(text, attachments: attachments)
            // Snapshot live state before shutdown clears it.
            // `adapter` is guaranteed non-optional here (the guard above enforced it).
            let savedAdapter = adapter
            let savedSessionID = currentSessionID

            // Step 1: graceful terminate — send cancel bytes and allow 50ms drain.
            let cancelBytes = adapter.cancelSequence()
            try await transport?.write(cancelBytes)
            try await seams.clock.sleep(for: .milliseconds(50))

            // Step 2: atomic transcript truncation — strip everything after the
            // user turn in Codemixer's domain history first. Vendor transcript
            // truncation is a separate adapter concern.
            var resumeSessionID: String?
            if let sid = savedSessionID {
                let key = SessionTranscriptKey(projectRoot: ws,
                                               namespace: savedAdapter.historyNamespace,
                                               sessionID: sid)
                do {
                    try await transcriptRepository.truncate(
                        afterUserTurnID: adapterTurnID,
                        for: key
                    )
                    try await transcriptRepository.replaceUserTurn(
                        id: adapterTurnID,
                        text: revisedPrompt,
                        for: key
                    )
                    // Republish the truncated domain transcript so every
                    // attached surface (GUI + remote) matches the journal
                    // before the adapter process is replaced.
                    await restoreHistory(for: key)
                } catch {
                    throw AgentError.historyWriteFailed(
                        path: ws.path,
                        detail: String(describing: error)
                    )
                }
                if await savedAdapter.truncateTranscript(
                    afterUserTurnID: adapterTurnID,
                    sessionID: sid,
                    workspace: savedWorkingDirectory
                ) {
                    resumeSessionID = sid
                } else {
                    try await transcriptRepository.markSuperseded(sid, in: ws)
                }
            }

            // Step 3: shut down the current session slot only.
            let key = activeKey
            await shutdownActiveSlot(reason: .userCancel)

            // Step 4: respawn — with --resume if we truncated cleanly, else fresh.
            do {
                let resumeKey = key ?? AgentRuntimeKey(projectPath: ws.path,
                                                       agentID: savedAdapter.id,
                                                       instance: .shared)
                try await start(adapter: savedAdapter,
                                workspace: ws,
                                resumeSessionID: resumeSessionID,
                                runtimeKey: resumeKey,
                                workingDirectory: savedWorkingDirectory)
            } catch {
                // The pre-edit process is already gone, so a failed respawn
                // leaves the session unusable. Every attached surface needs to
                // know that — not just the client that asked for the edit.
                log.error("editAndResubmit respawn failed: \(error, privacy: .public)")
                await bus.publish(.error(.sessionReadinessFailed(
                    sessionID: savedSessionID ?? "",
                    detail: "The agent could not be restarted after the edit. Reopen the session to continue."
                )))
                throw error
            }

            // Step 5: send the revised prompt once the fresh process can take
            // it. An interactive TUI silently drops bytes written before it has
            // painted its input row, which reads as "the edit vanished".
            if await !awaitPromptReadiness(timeout: promptReadinessTimeout) {
                await SilentDiagnostics.shared.record(
                    kind: .other,
                    owner: "AgentEngine",
                    summary: "Respawned session never reported prompt readiness",
                    details: "Writing the revised turn anyway for session \(currentSessionID ?? "")"
                )
            }
            try? await seams.clock.sleep(for: savedAdapter.promptWriteSettleDelay)
            let bytes = savedAdapter.encodeUserPrompt(revisedPrompt)
            await record(.userTurn(id: adapterTurnID, text: revisedPrompt))
            await bus.publish(.userTurn(id: adapterTurnID, text: revisedPrompt))
            try await writePromptBytes(bytes)
            lastUserAdapterTurnID = adapterTurnID

        case .respondToPermission(let id, let decision):
            permissionTimeouts.removeValue(forKey: id)?.cancel()
            guard let pending = pendingPermissions.removeValue(forKey: id) else { return }
            try await deliverPermissionResponse(decision,
                                                for: pending.prompt,
                                                id: id,
                                                owner: pending.owner)

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
            await shutdownActiveSlot(reason: .userCancel)

        case .submitA2UIInteraction(let intent):
            try await handleSubmitA2UIInteraction(intent, adapter: adapter)

        case .reportA2UIClientError(let envelope):
            try await handleReportA2UIClientError(envelope, adapter: adapter)

        case .openProject,
             .listSessions,
             .importProjectHistory,
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
        case .revertFile(let file):
            try await gitReverter.checkout(file: file, workspace: workingDirectory ?? workspace)
            await record(.fileReverted(file: file))
            await bus.publish(.fileReverted(file: file))
            return ()
        case .revertHunk(let file, let hunkID):
            try await gitReverter.revertHunk(file: file,
                                             hunkID: hunkID,
                                             workspace: workingDirectory ?? workspace)
            await record(.fileReverted(file: file))
            await bus.publish(.fileReverted(file: file))
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
            let snapshotMessages: [SnapshotService.SnapshotMessage]
            let snapshotFiles: [ChangedFile]
            if let key = activeTranscriptKey() {
                snapshotMessages = try await transcriptRepository.snapshotMessages(for: key)
                snapshotFiles = try await transcriptRepository.changedFiles(for: key)
            } else {
                snapshotMessages = transcript
                snapshotFiles = changedFiles
            }
            let data = await snapshots.snapshot(
                kind,
                conversation: snapshotMessages.map { ($0.role, $0.text, $0.timestamp) },
                sessionID: currentSessionID,
                changedFiles: snapshotFiles,
                workspace: workspace
            )
            await bus.publish(.snapshotReady(kind: kind, payload: data))
            return ()
        case .recordClientAction(let action):
            await record(.clientAction(action))
            await bus.publish(.clientAction(action))
            return ()
        case .listSessions(let path):
            try await publishStoredSessions(
                in: URL(fileURLWithPath: path).standardizedFileURL
            )
            return ()
        case .importProjectHistory(let path):
            try await importProjectHistory(
                at: URL(fileURLWithPath: path).standardizedFileURL
            )
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
        guard let agentID = ProjectAgentRouter.resolveAdapterID(projectType: project.projectType,
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

        // Prefer a fresh adapter instance for the spawn path; custom ACP uses factories.
        let nextAdapter: any AgentAdapter
        if case .custom(let ref) = project.projectType,
           let custom = await CustomAgentAdapterFactories.shared.makeAdapter(for: ref) {
            nextAdapter = custom
        } else if let made = await AdapterRegistry.shared.makeAdapter(for: agentID) {
            nextAdapter = made
        } else if let resolved = await ProjectAgentRouter.resolveAdapter(projectType: project.projectType,
                                                                         sessionAgentID: sessionAgentID) {
            nextAdapter = resolved
        } else {
            throw AgentError.unsupportedOperation(
                detail: "Project \(path) needs a concrete registered agent before it can be opened."
            )
        }

        if let resumeSessionID {
            let transcriptKey = SessionTranscriptKey(
                projectRoot: projectURL,
                namespace: nextAdapter.historyNamespace,
                sessionID: resumeSessionID
            )
            await restoreHistory(for: transcriptKey)
        }

        let agentWorkingDirectory = project.workingDirectoryURL.standardizedFileURL
        // Only an explicit override is validated: with none, cwd is the project
        // folder, and the open path already depends on that folder existing.
        if project.workingDirectoryPath != nil,
           !seams.fileSystem.isDirectory(at: agentWorkingDirectory) {
            throw AgentError.unsupportedOperation(
                detail: "Working directory \(agentWorkingDirectory.path) is missing or not a folder."
            )
        }

        // A pooled child already has its cwd; a working-directory edit can only
        // land on a cold spawn. Drop stale slots here so the warm resume / New
        // Chat paths below cannot silently keep running in the old directory.
        let staleSlots = runtimes.filter { key, runtime in
            key.projectPath == project.path
                && key.agentID == nextAdapter.id
                && runtime.workingDirectory.path != agentWorkingDirectory.path
        }.map(\.key)
        for stale in staleSlots {
            log.notice(
                "working directory changed; dropping stale slot project=\(project.path, privacy: .public)"
            )
            await shutdownSlot(stale, publishStopped: false)
        }

        var key = runtimeKey(for: project, agentID: nextAdapter.id)
        if project.preferFreshAgentProcess {
            // Always replace slots for this project+agent. Mint + persist a
            // dedicated identity when the stored ref still says `.shared`.
            if case .dedicated = key.instance {
                // Keep persisted dedicated id so reopen stays stable until toggled again.
            } else {
                key = AgentRuntimeKey(projectPath: project.path,
                                      agentID: nextAdapter.id,
                                      instance: .dedicated(seams.random.uuid()))
                _ = try? await store.setAgentLaunchPreference(
                    path: project.path,
                    preferFreshAgentProcess: true,
                    agentInstanceIdentity: key.instance,
                    in: projectURL
                )
            }
            for existing in runtimes.keys where existing.projectPath == key.projectPath
                && existing.agentID == key.agentID {
                await shutdownSlot(existing, publishStopped: false)
            }
            try await start(adapter: nextAdapter,
                            workspace: projectURL,
                            resumeSessionID: resumeSessionID,
                            permissionMode: .default,
                            runtimeKey: key,
                            workingDirectory: agentWorkingDirectory)
            return
        }

        // Session resume is pool-only for every adapter: if this project already
        // has a live (active or parked) slot, switch via encodeResumeSession —
        // never tear down and cold-spawn with --resume / bootstrap load.
        if let resumeSessionID,
           let existingKey = findRuntime(projectPath: project.path, agentID: nextAdapter.id),
           runtimes[existingKey] != nil {
            guard await activate(key: existingKey, resumeSessionID: resumeSessionID) else {
                throw AgentError.unsupportedOperation(
                    detail: "Could not resume session \(resumeSessionID) on the live agent process for \(project.path)."
                )
            }
            log.notice(
                "pool resume project=\(project.path, privacy: .public) session=\(resumeSessionID, privacy: .public)"
            )
            return
        }

        // No resume id: park return, or New Chat on the live pooled process.
        // Cold start only when this project+agent is not already in the pool.
        if let existingKey = findRuntime(projectPath: project.path, agentID: nextAdapter.id),
           runtimes[existingKey] != nil {
            if activeKey != existingKey {
                if await activate(key: existingKey, resumeSessionID: nil) {
                    log.notice("warm activate parked project=\(project.path, privacy: .public)")
                    return
                }
                log.warning("warm park activate failed; falling back to cold start")
                await shutdownSlot(existingKey, publishStopped: false)
            } else {
                guard await applyWarmNewSession() else {
                    throw AgentError.unsupportedOperation(
                        detail: "Could not start a new chat on the live agent process for \(project.path)."
                    )
                }
                log.notice("warm newSession project=\(project.path, privacy: .public)")
                return
            }
        }

        if resumeSessionID != nil {
            log.notice("cold-open session into pool=\(resumeSessionID ?? "", privacy: .public)")
        }
        try await start(adapter: nextAdapter,
                        workspace: projectURL,
                        resumeSessionID: resumeSessionID,
                        permissionMode: .default,
                        runtimeKey: key,
                        workingDirectory: agentWorkingDirectory)
    }

    private func importProjectHistory(at projectURL: URL) async throws {
        if case .completed = try await transcriptRepository.catalogImportState(in: projectURL) {
            try await publishStoredSessions(in: projectURL)
            await bus.publish(.historyImportFinished(projectPath: projectURL,
                                                     imported: 0,
                                                     failed: 0))
            return
        }
        let store = WorkspaceProjectsStore(environment: seams.environment,
                                           fileSystem: seams.fileSystem)
        await store.load()
        guard let project = await store.project(path: projectURL.path) else {
            throw AgentError.unsupportedOperation(
                detail: "Project \(projectURL.path) must be added before its history can be imported."
            )
        }
        let adapters = await importAdapters(for: project.projectType)
        guard !adapters.isEmpty else {
            try await transcriptRepository.setCatalogImportState(.notNeeded,
                                                                 in: projectURL)
            await bus.publish(.historyImportFinished(projectPath: projectURL,
                                                     imported: 0,
                                                     failed: 0))
            return
        }

        try await transcriptRepository.setCatalogImportState(.pending,
                                                             in: projectURL)
        let environment = await ShellEnvironmentResolver(
            environment: seams.environment
        ).resolve()
        var imported = 0
        var failed = 0
        for adapter in adapters {
            do {
                let sessions = try await adapter.importSessionCatalog(
                    workspace: project.workingDirectoryURL,
                    env: environment
                ) { [bus] completed, total in
                    await bus.publish(.historyImportProgress(
                        projectPath: projectURL,
                        completed: completed,
                        total: total
                    ))
                }
                try await transcriptRepository.importCatalog(
                    sessions,
                    namespace: adapter.historyNamespace,
                    agentID: adapter.id,
                    into: projectURL,
                    changedFileRoot: project.workingDirectoryURL
                )
                imported += sessions.count
            } catch is CancellationError {
                try await transcriptRepository.setCatalogImportState(
                    .partial(at: seams.clock.now()),
                    in: projectURL
                )
                throw CancellationError()
            } catch {
                failed += 1
                log.error(
                    "history import failed adapter=\(adapter.id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        try await transcriptRepository.setCatalogImportState(
            failed == 0 ? .completed(at: seams.clock.now())
                : .partial(at: seams.clock.now()),
            in: projectURL
        )
        try await publishStoredSessions(in: projectURL)
        await bus.publish(.historyImportFinished(projectPath: projectURL,
                                                 imported: imported,
                                                 failed: failed))
    }

    private func importAdapters(for projectType: ProjectType) async -> [any AgentAdapter] {
        switch projectType {
        case .mixed:
            return await AdapterRegistry.shared.all()
        case .custom(let ref):
            if let adapter = await CustomAgentAdapterFactories.shared.makeAdapter(for: ref) {
                return [adapter]
            }
            return []
        case .folder:
            return []
        case .claudeCode, .codex, .cursorCLI:
            guard let id = projectType.primaryAgentID,
                  let adapter = await AdapterRegistry.shared.adapter(for: id) else {
                return []
            }
            return [adapter]
        }
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
        return try? await transcriptRepository.records(
            forSessionID: resumeSessionID,
            inProject: workspace
        ).first?.agentID
    }

    // MARK: - Helpers

    private func promptText(_ text: String, attachments: [AttachmentRef]) async throws -> String {
        let urls = try await attachmentResolver.resolve(attachments)
        guard !urls.isEmpty else { return text }
        let refs = urls.map { "@\($0.path)" }.joined(separator: "\n")
        return text.isEmpty ? refs : "\(text)\n\(refs)"
    }

    func writePromptBytes(_ bytes: Data) async throws {
        guard let transport else {
            throw AgentError.internalInvariant(detail: "transport closed before prompt write")
        }
        try await transport.write(bytes)
    }
}
