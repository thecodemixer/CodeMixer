import A2UICore
import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {

    // MARK: - Event reduction

    func apply(_ event: AgentEvent) {
        switch event {
        case .sessionStarted(let id, _, let cwd):
            let selectedPath = workspace.map {
                URL(fileURLWithPath: $0.path).standardizedFileURL
            }
            let expectedCwd = (activeWorkingDirectory ?? workspace).map {
                URL(fileURLWithPath: $0.path).standardizedFileURL
            }
            let eventURL = cwd.standardizedFileURL
            // Project selection is owned by the navigator (`newChat` /
            // `openSession`). A late SessionStart from a project the user
            // already left must never yank the sidebar / composer back.
            // Compare against the agent working directory (may differ from
            // `ProjectRef.path` when a cwd override is set).
            if let expectedCwd,
               expectedCwd.path != eventURL.path,
               expectedCwd.resolvingSymlinksInPath().path != eventURL.resolvingSymlinksInPath().path {
                return
            }
            let projectChanged = selectedPath == nil
            let previousSessionID = sessionID
            // Overview is not a chat session — a control SessionStart from
            // cold `openProject` must not bind `sessionID` or wipe the pane
            // the navigator already selected.
            let bindChatSession = !showsOverviewDashboard
            let sessionChanged = bindChatSession && previousSessionID != id
            let shouldResetConversation = projectChanged || (sessionChanged && activity == .idle)
            // Engine bootstrap may publish an empty id for handshake-gated
            // adapters; do not clobber a resume id the navigator already set.
            if bindChatSession {
                if !id.isEmpty {
                    sessionID = id
                } else if previousSessionID == nil {
                    sessionID = id
                }
            }
            Task { await self.refreshLivePooledProjectPaths() }
            if sessionChanged {
                // Re-bind the permission card / waiting state to the new chat.
                refreshPermissionActivity()
            }
            // First session with no explicit workspace shell: treat cwd as the root.
            if workspaceRoot == nil {
                workspaceRoot = cwd
            }
            if projectChanged {
                // Prefer a known project whose working directory matches the
                // event cwd so identity stays on `ProjectRef.path`.
                if let match = projects.first(where: {
                    $0.workingDirectoryURL.standardizedFileURL.path == eventURL.path
                        || $0.workingDirectoryURL.resolvingSymlinksInPath().path
                        == eventURL.resolvingSymlinksInPath().path
                }) {
                    bindActiveProject(match)
                } else {
                    workspace = cwd
                    activeWorkingDirectory = cwd
                }
            }
            // `beginSessionSwitch` already cleared the pane and may have applied
            // `session/load` history before this SessionStart. Do not wipe that
            // replay when the navigator owns the switch (session id already set,
            // or `isSwitchingSession` still true).
            if shouldResetConversation,
               !isSwitchingSession,
               !showsOverviewDashboard,
               !id.isEmpty || previousSessionID == nil {
                clearConversationState()
            }
            if bindChatSession, !id.isEmpty {
                promotePendingPhases(for: id, projectPath: (workspace ?? cwd).path)
            }
            if projectChanged {
                onActiveProjectChanged()
            } else if sessionChanged, !id.isEmpty {
                // Codex (and similar adapters) record the resumable thread only
                // after `thread/start` succeeds — after the engine's empty
                // bootstrap `sessionStarted`. Refresh so New Chat / first open
                // appear in the sidebar. ACP agents (Cursor) publish their model
                // catalog on the same live session-open response.
                loadSessions(for: (workspace ?? cwd).path)
                applyAdapterCapabilities(forProjectPath: (workspace ?? cwd).path)
            }
        case .userTurn(let id, let text):
            applyUserTurn(id: id, text: text)
        case .assistantText(let msgID, _, let text, let isFinal):
            noteAgentReplyObserved()
            // Prefer the open streaming bubble with this id — even when a tool
            // card was appended after it — so interleaved tools don't fork a
            // second assistant row or delay updates until finalize.
            let parsedID = UUID(uuidString: msgID)
            if let idx = messages.lastIndex(where: {
                guard case .assistantStreaming(let existingID, _) = $0 else { return false }
                if let parsedID { return existingID == parsedID }
                return true
            }), case .assistantStreaming(let existingID, _) = messages[idx] {
                messages[idx] = isFinal
                    ? .assistant(bubbleID: existingID, text: text)
                    : .assistantStreaming(bubbleID: existingID, text: text)
            } else {
                let id = parsedID ?? random.uuid()
                messages.append(isFinal
                    ? .assistant(bubbleID: id, text: text)
                    : .assistantStreaming(bubbleID: id, text: text))
            }
            if isFinal {
                settleTurnIdle()
            }
        case .textDelta(let messageID, let delta):
            noteAgentReplyObserved()
            if let lastIdx = messages.indices.last,
               case .assistantStreaming(let existingID, let existingText) = messages[lastIdx] {
                // Preserve the stable bubbleID; only the text grows.
                messages[lastIdx] = .assistantStreaming(bubbleID: existingID,
                                                        text: existingText + delta)
            } else {
                messages.append(.assistantStreaming(bubbleID: messageID, text: delta))
                streamingStartedAt = clock.now()
                deltaTimestamps.removeAll()
            }
            updateTokenRate()
        case .thinkingChunk(let blockID, let delta):
            noteAgentReplyObserved()
            // Accumulate chunks into a single message rather than appending one per chunk.
            let accumulated = (thinkingBlockTexts[blockID] ?? "") + delta
            thinkingBlockTexts[blockID] = accumulated
            if let idx = messages.lastIndex(where: {
                if case .thinkingChunk(let id, _) = $0 { return id == blockID }; return false
            }) {
                messages[idx] = .thinkingChunk(blockID: blockID, delta: accumulated)
            } else {
                messages.append(.thinkingChunk(blockID: blockID, delta: accumulated))
            }
        case .thinkingComplete(let blockID, let duration):
            noteAgentReplyObserved()
            let text = thinkingBlockTexts.removeValue(forKey: blockID) ?? ""
            if let idx = messages.lastIndex(where: {
                if case .thinkingChunk(let id, _) = $0 { return id == blockID }; return false
            }) {
                messages[idx] = .thinkingComplete(blockID: blockID, text: text, duration: duration)
            } else {
                messages.append(.thinkingComplete(blockID: blockID, text: text, duration: duration))
            }
        case .toolStart(let id, let name, let input, _):
            noteAgentReplyObserved()
            activeToolCalls.append(ToolCallEntry(id: id, name: name, input: input, finished: false))
            // Drop an ordering marker into the message stream so the card renders
            // inline at the point the tool actually ran, between assistant prose.
            if !messages.contains(where: { if case .toolCall(let c) = $0 { return c == id }; return false }) {
                messages.append(.toolCall(callID: id))
            }
        case .toolEnd(let id, let success, let output, _):
            if let idx = activeToolCalls.firstIndex(where: { $0.id == id }) {
                activeToolCalls[idx].finished = true
                activeToolCalls[idx].success = success
                activeToolCalls[idx].output = output
            }
        case .permissionRequest(let prompt):
            noteAgentReplyObserved()
            storePendingPermission(prompt, for: sessionID)
        case .permissionAlreadyResolved(let id, _):
            clearPendingPermission(id: id)
        case .statusPhraseChanged(_, let phrase):
            status = .working(phrase: phrase)
            if phrase.hasPrefix("Mode: ") {
                let modeID = String(phrase.dropFirst("Mode: ".count))
                if availableAgentModes.contains(where: { $0.id == modeID }) {
                    selectedAgentModeID = modeID
                }
            }
        case .activityStateChanged(let substate):
            activity = substate
            if substate == .idle { settleTurnIdle() }
        case .noEventGap(let turnID, let elapsed):
            // Only escalate from gaps that belong to the in-flight send. Resume
            // startup publishes a synthetic >90s gap with its own watchdog id —
            // matching here prevents that from looking like a stalled turn the
            // moment the user sends into a still-gating resume.
            let gapBelongsToCurrentTurn = turnID == lastUserEntryID?.rawValue
                || turnID == pendingOptimisticBubbleID
            if activity != .idle, gapBelongsToCurrentTurn {
                if elapsed > ActivityTiming.stillWorkingThreshold,
                   isAwaitingFirstReplyForPrompt {
                    status = .working(phrase: ActivityTiming.stillWorkingPhrase)
                }
                if elapsed > ActivityTiming.probablyStuckThreshold,
                   isAwaitingFirstReplyForPrompt,
                   !stalledToastFiredThisTurn {
                    stalledToastFiredThisTurn = true
                    stalledToastVisible = true
                    stalledToastTask?.cancel()
                    stalledToastTask = nil
                }
            }
        case .fileTouched(let url, _):
            let file = ChangedFile(url: url, workspace: activeWorkingDirectory ?? workspace)
            if !changedFiles.contains(file) { changedFiles.append(file) }
        case .stopped:
            settleTurnIdle()
            Task { await self.refreshLivePooledProjectPaths() }
        case .error(let error):
            isAwaitingFirstReplyForPrompt = false
            stalledToastVisible = false
            if case .sessionReadinessFailed(let id, let detail) = error {
                sessionActivation = .failed(sessionID: id, message: detail)
            }
            diagnostics.append(diagnostic(level: .error, message: error.userMessage))
        case .authURL:
            break
        case .bell, .engineRestarted:
            break
        case .usage(let tokens, let cost):
            sessionTokens = tokens
            sessionCostUSD = cost
        case .toolProgress(let callID, let progress):
            noteAgentReplyObserved()
            if let idx = activeToolCalls.firstIndex(where: { $0.id == callID }) {
                activeToolCalls[idx].progress = progress
                // Subagent text surfaces as .generic — accumulate it as nested lines.
                if case .generic(let msg) = progress {
                    activeToolCalls[idx].subagentLines.append(msg)
                }
            }
        case .speakBubbleRequested:
            break
        case .fileReverted(let file):
            changedFiles.removeAll { $0 == file }
        case .prefsChanged(let count):
            diagnostics.append(diagnostic(level: .info, message: "Auto-approval rules updated (\(count))."))
        case .appearancePrefChanged(let key, let value):
            if let patch = AppearancePrefPatch(key: key, value: value) {
                appearancePrefs.update(patch)
            }
            if key == .sidebarVisible, case .bool(let visible) = value {
                sidebarVisible = visible
            }
        case .snapshotReady(let kind, let payload):
            if let waiter = snapshotWaiters.removeValue(forKey: kind) {
                waiter.resume(returning: payload)
            } else {
                pendingExport = PendingExport(kind: kind, payload: payload)
            }
        case .clientAction(let action):
            messages.append(.clientAction(action))
        case .agentDashboard(let url, let title):
            if customACPRestartPhase != .idle {
                // Drop ads that arrive during close/teardown; only accept after
                // cold openProject has completed.
                guard customACPRestartPhase == .awaitingDashboard else { return }
                customACPRestartPhase = .idle
                status = .idle
                dashboardLoadGeneration += 1
            }
            dashboardURL = url
            if let title, !title.isEmpty {
                dashboardTitle = title
            }
            // Navigator owns chat vs overview. An advertisement must never
            // steal focus from a file chat or New Chat (`sessionID` still nil).
        case .sessionAttentionChanged(let sessionID, _, let needsAttention):
            updateSessionAttention(sessionID: sessionID, needsAttention: needsAttention)
        case .sessionHistoryRestored(let id):
            noteHistoryRestored(sessionID: id)
        case .sessionPromptReady(let id):
            notePromptReady(sessionID: id)
        case .sessionsListed(let projectPath, let sessions):
            let path = projectPath.standardizedFileURL.path
            let filtered = SessionNavigatorFiltering.preferringSingleOverview(sessions)
            sessionsByProject[path] = filtered
            loadingProjectPaths.remove(path)
            let liveIDs = Set(filtered.map(\.id))
            pendingPermissionsBySession = pendingPermissionsBySession.filter { key, _ in
                key == Self.unscopedPermissionSessionKey || liveIDs.contains(key)
            }
            refreshPermissionActivity()
        case .historyImportProgress:
            break
        case .historyImportFinished(let projectPath, _, _):
            loadSessions(for: projectPath.path)
        case .sessionPhaseChanged(let phaseSessionID, let phase):
            recordSessionPhase(sessionID: phaseSessionID, phase: phase)
        case .a2uiBatch(let batch):
            applyA2UIBatch(batch)
        }
    }

    /// Live counterpart to `SessionTranscript.applyA2UIBatch`: folds a batch
    /// into `a2uiSurfaces` through the one shared `A2UISurfaceReducer`, then
    /// creates/updates/removes the corresponding `.a2uiSurface` ordering
    /// marker in `messages` exactly like `.toolCall` does for tool calls.
    func applyA2UIBatch(_ batch: A2UIServerBatch) {
        noteAgentReplyObserved()
        let result = A2UISurfaceReducer.apply(batch,
                                              to: a2uiSurfaces,
                                              retiredGenerations: a2uiRetiredGenerations,
                                              at: clock.now())
        a2uiRetiredGenerations = result.retiredGenerations
        let appliedIndexes = Set(result.outcomes.filter(\.applied).map(\.index))
        guard !appliedIndexes.isEmpty else { return }

        var deletedIDs: Set<String> = []
        var touchedIDs: [String] = []
        for item in batch.items where appliedIndexes.contains(item.index) {
            guard let message = item.message else { continue }
            if case .deleteSurface(let surfaceID) = message {
                deletedIDs.insert(surfaceID)
            } else {
                touchedIDs.append(message.surfaceID)
            }
        }

        a2uiSurfaces = result.surfaces
        if !deletedIDs.isEmpty {
            messages.removeAll {
                if case .a2uiSurface(let surfaceID) = $0 { return deletedIDs.contains(surfaceID) }
                return false
            }
        }
        for surfaceID in touchedIDs where !deletedIDs.contains(surfaceID) {
            guard a2uiSurfaces[surfaceID] != nil else { continue }
            if !messages.contains(where: {
                if case .a2uiSurface(let existing) = $0 { return existing == surfaceID }
                return false
            }) {
                messages.append(.a2uiSurface(surfaceID: surfaceID))
            }
        }
    }

    /// Anchors a file-level phase marker to the current tail of `messages` so
    /// `conversationTurns` can tag every turn from this point forward. Only
    /// tags the foreground session. Markers for background file sessions are
    /// parked by session id and promoted when that file chat is selected.
    func recordSessionPhase(sessionID phaseSessionID: String, phase: SessionPhase) {
        let marker = PhaseMarker(messageIndex: messages.count, phase: phase, at: clock.now())
        guard phaseSessionID == sessionID else {
            let key = pendingPhaseKey(sessionID: phaseSessionID, projectPath: workspace?.path)
            var pending = pendingPhaseMarkersBySession[key] ?? []
            if pending.last?.phase.id != phase.id {
                pending.append(marker)
            }
            pendingPhaseMarkersBySession[key] = pending
            return
        }
        appendPhaseMarker(marker)
    }

    func promotePendingPhases(for sessionID: String, projectPath: String? = nil) {
        let key = pendingPhaseKey(sessionID: sessionID, projectPath: projectPath ?? workspace?.path)
        guard let pending = pendingPhaseMarkersBySession.removeValue(forKey: key),
              !pending.isEmpty else { return }
        for marker in pending {
            appendPhaseMarker(PhaseMarker(messageIndex: messages.count,
                                          phase: marker.phase,
                                          at: marker.at))
        }
    }

    func appendPhaseMarker(_ marker: PhaseMarker) {
        if let cursor = phaseReplayDedupCursor {
            if cursor < phaseMarkers.count,
               phaseMarkers[cursor].phase.id == marker.phase.id {
                phaseReplayDedupCursor = cursor + 1
                return
            }
            phaseReplayDedupCursor = nil
        }
        guard phaseMarkers.last?.phase.id != marker.phase.id else { return }
        if phaseMarkers.count > 1,
           let first = phaseMarkers.first,
           first.phase.id == marker.phase.id,
           marker.messageIndex <= first.messageIndex {
            phaseReplayDedupCursor = 1
            return
        }
        phaseMarkers.append(marker)
    }

    func pendingPhaseKey(sessionID: String, projectPath: String?) -> String {
        guard let projectPath, !projectPath.isEmpty else { return sessionID }
        return "\(projectPath)::\(sessionID)"
    }

    /// Compute a rolling tok/s estimate from the last 5 delta timestamps.
    /// Shown only when ≥ 5 deltas and ≥ 1s of streaming have elapsed.
    func updateTokenRate() {
        let now = clock.now()
        deltaTimestamps.append(now)
        if deltaTimestamps.count > 5 { deltaTimestamps.removeFirst() }

        guard deltaTimestamps.count >= 5,
              let start = streamingStartedAt,
              now.timeIntervalSince(start) >= 1.0,
              let first = deltaTimestamps.first else {
            tokenRatePerSecond = nil
            return
        }
        let windowSeconds = now.timeIntervalSince(first)
        if windowSeconds > 0 {
            tokenRatePerSecond = Double(deltaTimestamps.count - 1) / windowSeconds
        }
    }

    func diagnostic(level: DiagnosticEntry.Level,
                    message: String) -> DiagnosticEntry {
        DiagnosticEntry(id: random.uuid(), level: level, message: message)
    }

    func settleTurnIdle() {
        activity = .idle
        status = .idle
        tokenRatePerSecond = nil
        deltaTimestamps.removeAll()
        streamingStartedAt = nil
        isAwaitingFirstReplyForPrompt = false
        stalledToastFiredThisTurn = false
        stalledToastTask?.cancel()
        stalledToastTask = nil
        stalledToastVisible = false
    }

    func clearConversationState() {
        messages = []
        activeToolCalls = []
        changedFiles = []
        a2uiSurfaces = [:]
        a2uiRetiredGenerations = [:]
        lastUserEntryID = nil
        selectedTurnID = nil
        selectedPhaseID = nil
        phaseMarkers = []
        phaseReplayDedupCursor = nil
        thinkingBlockTexts.removeAll()
        deltaTimestamps.removeAll()
        streamingStartedAt = nil
        tokenRatePerSecond = nil
        isAwaitingFirstReplyForPrompt = false
        stalledToastFiredThisTurn = false
        stalledToastTask?.cancel()
        stalledToastTask = nil
        stalledToastVisible = false
        pendingOptimisticBubbleID = nil
        dedupUserText = nil
        dedupArmedAt = nil
        dedupDropsRemaining = 0
    }

    func displayPath(forTouchedFile url: URL) -> String {
        ChangedFile.relativePath(for: url, workspace: activeWorkingDirectory ?? workspace)
    }

    func noteAgentReplyObserved() {
        isAwaitingFirstReplyForPrompt = false
        stalledToastVisible = false
    }

    // MARK: - Session-scoped permissions

    func permissionOwnerKey(for sessionID: String?) -> String {
        sessionID ?? Self.unscopedPermissionSessionKey
    }

    /// ACP only emits a live `permissionRequest` for the foreground session;
    /// background reviews park and use the sidebar attention dot instead.
    func storePendingPermission(_ prompt: PermissionPrompt, for sessionID: String?) {
        let key = permissionOwnerKey(for: sessionID)
        // One live prompt per session — a newer request supersedes the older.
        pendingPermissionsBySession[key] = prompt
        refreshPermissionActivity()
    }

    func clearPendingPermission(id: PermissionPromptID) {
        pendingPermissionsBySession = pendingPermissionsBySession.filter { $0.value.id != id }
        refreshPermissionActivity()
    }

    func clearAllPendingPermissions() {
        pendingPermissionsBySession.removeAll()
        refreshPermissionActivity()
    }

    /// Keep `.waitingPermission` tied to the *active* chat only. Other sessions
    /// retain their prompts in the map and surface via the orange attention dot.
    func refreshPermissionActivity() {
        if activePendingPermission != nil {
            activity = .waitingPermission
        } else if activity == .waitingPermission {
            activity = .idle
        }
    }
}
