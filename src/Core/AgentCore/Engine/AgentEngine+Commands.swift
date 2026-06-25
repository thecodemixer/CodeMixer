import Foundation
import AgentProtocol

extension AgentEngine {
    // MARK: - AgentEngineCommandPort

    public func send(_ command: AgentCommand) async throws {
        // Out-of-band commands don't need a running session — handle them
        // first so prefs / snapshots / pairing-related work succeeds whether
        // or not an adapter has been bound.
        if let handled = try await handleOutOfBand(command) { _ = handled; return }

        guard let adapter else { throw AgentError.internalInvariant(detail: "no adapter bound") }

        switch command {
        case .sendPrompt(let text, let attachments):
            let bubbleID = seams.random.uuid()
            lastUserBubbleID = bubbleID
            let prompt = try await promptText(text, attachments: attachments)
            let bytes = adapter.encodeUserPrompt(prompt)
            // Echo the turn + start the heartbeat BEFORE the awaited PTY write so
            // every connected surface (the GUI and remote API clients) reflects
            // the turn instantly rather than after the write + bus fan-out. If
            // the write then fails, `send` still throws so the caller surfaces
            // the error. Ordering is otherwise unchanged.
            await bus.publish(.userTurn(id: bubbleID.uuidString, text: prompt))
            currentTurnID = bubbleID
            await heartbeat?.startTurn(bubbleID, baseline: .awaitingFirstChunk)
            try await writePromptBytes(bytes)

        case .cancelCurrentTurn:
            let cancelBytes = adapter.cancelSequence()
            try await pty?.write(cancelBytes)
            await pty?.interrupt()

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

            // Step 1: graceful terminate — send Ctrl-C and allow 50ms drain.
            let cancelBytes = adapter.cancelSequence()
            try await pty?.write(cancelBytes)
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

        case .respondToInlinePrompt(_, let text):
            try await writePromptBytes(adapter.encodeUserPrompt(text))

        case .newSession,
             .compact,
             .selectModel,
             .setPermissionMode,
             .toggleThinkMode,
             .toggleReviewMode,
             .runSlashCommand,
             .runCustomCommand:
            try await writePromptBytes(adapter.encodeUserPrompt(slashLine(for: command)))

        case .openProject(let path, let resume):
            // The GUI layer normally owns lifecycle; over the wire we honour
            // it by restarting against the new workspace.
            await shutdown(reason: .userCancel)
            try await start(adapter: adapter,
                            workspace: URL(fileURLWithPath: path),
                            resumeSessionID: resume,
                            permissionMode: .default)

        case .closeSession:
            await shutdown(reason: .userCancel)

        case .speakAssistantBubble, .revertFile, .revertHunk,
             .updateAutoApprovalRules, .updateAppearancePref, .requestSnapshot:
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
            await bus.publish(.speakBubbleRequested(id: "\(eventID.uuidString):\(action.rawValue)"))
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
        case .updateAppearancePref(let key, let value):
            try await prefs.updateAppearance(key, value: value)
            await bus.publish(.appearancePrefChanged(key: key, value: value))
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
        default:
            return nil
        }
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
        try await pty?.write(bytes)
        // Independent safety net for the very first real prompt of a freshly
        // started TUI session: if the readiness heuristic was fooled and the
        // submit key was swallowed, the prompt text keeps sitting in the input
        // row with no `UserPromptSubmit`. After a short delay we re-send a
        // single Enter — but only if the terminal still shows the unsubmitted
        // prompt, so an already-accepted turn never receives a stray newline.
        if startupSubmitRecoveryArmed, let turnID = currentTurnID {
            startupSubmitRecoveryArmed = false
            scheduleStartupSubmitRecovery(turnID: turnID)
        }
    }

    func slashLine(for command: AgentCommand) -> String {
        switch command {
        case .newSession:          return "/clear\n"
        case .compact:             return "/compact\n"
        case .selectModel(let id): return "/model \(id)\n"
        case .setPermissionMode(let m): return "/permission \(m.rawValue)\n"
        case .toggleThinkMode(let enabled): return enabled ? "/think\n" : "/think off\n"
        case .toggleReviewMode(let enabled): return enabled ? "/review\n" : "/review off\n"
        case .runSlashCommand(let name, let args):
            return ([name] + args).joined(separator: " ") + "\n"
        case .runCustomCommand(let path, let args):
            return ([path] + args).joined(separator: " ") + "\n"
        default:
            return ""
        }
    }
}
