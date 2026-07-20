import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {

    // MARK: - Event reduction

    func apply(_ event: AgentEvent) {
        switch event {
        case .sessionStarted(let id, let model, let cwd):
            let selectedPath = workspace.map {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
            }
            let eventPath = cwd.standardizedFileURL.path
            // Project selection is owned by the navigator (`newChat` /
            // `openSession`). A late SessionStart from a project the user
            // already left must never yank the sidebar / composer back.
            if let selectedPath, selectedPath != eventPath {
                return
            }
            let projectChanged = selectedPath == nil
            let previousSessionID = sessionID
            let sessionChanged = previousSessionID != id
            let shouldResetConversation = projectChanged || (sessionChanged && activity == .idle)
            // Engine bootstrap may publish an empty id for handshake-gated
            // adapters; do not clobber a resume id the navigator already set.
            if !id.isEmpty {
                sessionID = id
            } else if previousSessionID == nil {
                sessionID = id
            }
            // First session with no explicit workspace shell: treat cwd as the root.
            if workspaceRoot == nil {
                workspaceRoot = cwd
            }
            if projectChanged {
                workspace = cwd
            }
            if shouldResetConversation, !id.isEmpty || previousSessionID == nil {
                clearConversationState()
            }
            // SessionStart with a model is the first live signal from the
            // resumed agent process. For Claude Code, that matters because the
            // visible history may already be on screen from JSONL replay; wait
            // one engine-aligned settle window before enabling GUI sends.
            // Handshake-gated agents (Cursor / ACP) unlock on any non-empty
            // live SessionStart — including same-id resume without a model.
            if isComposerLockedForSessionResume, !id.isEmpty {
                let handshake = projectNeedsSessionHandshakeGate(path: cwd.path)
                    || projectNeedsSessionHandshakeGate(path: workspace?.path ?? "")
                let resumedSessionConfirmed = id == previousSessionID && (model != nil || handshake)
                let freshSessionConfirmed = previousSessionID?.isEmpty ?? true
                if resumedSessionConfirmed || freshSessionConfirmed {
                    if isComposerWaitingForClaudeCodeResume {
                        scheduleComposerResumeUnlock(after: SessionSwitchingTiming.claudeCodeComposerHookUnlock)
                    } else {
                        unlockComposerForSessionResume()
                    }
                }
            }
            if projectChanged {
                onActiveProjectChanged()
            } else if sessionChanged, !id.isEmpty {
                // Codex (and similar adapters) record the resumable thread only
                // after `thread/start` succeeds — after the engine's empty
                // bootstrap `sessionStarted`. Refresh so New Chat / first open
                // appear in the sidebar. ACP agents (Cursor) publish their model
                // catalog on the same live session-open response.
                loadSessions(for: cwd.path)
                applyAdapterCapabilities(forProjectPath: cwd.path)
            }
        case .userTurn(let id, let text):
            finishSessionSwitchIfNeeded()
            applyUserTurn(id: id, text: text)
        case .assistantText(let msgID, _, let text, let isFinal):
            finishSessionSwitchIfNeeded()
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
            finishSessionSwitchIfNeeded()
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
            finishSessionSwitchIfNeeded()
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
            finishSessionSwitchIfNeeded()
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
            finishSessionSwitchIfNeeded()
            noteAgentReplyObserved()
            activeToolCalls.append(ToolCallEntry(id: id, name: name, input: input, finished: false))
            // Drop an ordering marker into the message stream so the card renders
            // inline at the point the tool actually ran, between assistant prose.
            if !messages.contains(where: { if case .toolCall(let c) = $0 { return c == id }; return false }) {
                messages.append(.toolCall(callID: id))
            }
        case .toolEnd(let id, let success, let output, _):
            finishSessionSwitchIfNeeded()
            if let idx = activeToolCalls.firstIndex(where: { $0.id == id }) {
                activeToolCalls[idx].finished = true
                activeToolCalls[idx].success = success
                activeToolCalls[idx].output = output
            }
        case .permissionRequest(let prompt):
            noteAgentReplyObserved()
            pendingPermission = prompt
            activity = .waitingPermission
        case .permissionAlreadyResolved:
            pendingPermission = nil
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
            let gapBelongsToCurrentTurn = turnID == lastUserBubbleID
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
            let rel = displayPath(forTouchedFile: url)
            if !changedFiles.contains(rel) { changedFiles.append(rel) }
        case .stopped:
            if !isSwitchingSession {
                endSessionSwitch()
            }
            settleTurnIdle()
        case .error(let error):
            endSessionSwitch()
            isAwaitingFirstReplyForPrompt = false
            stalledToastVisible = false
            diagnostics.append(diagnostic(level: .error, message: error.userMessage))
        case .authURL:
            break
        case .bell, .engineRestarted:
            break
        case .usage(let tokens, let cost):
            sessionTokens = tokens
            sessionCostUSD = cost
        case .toolProgress(let callID, let progress):
            finishSessionSwitchIfNeeded()
            noteAgentReplyObserved()
            if let idx = activeToolCalls.firstIndex(where: { $0.id == callID.uuidString }) {
                activeToolCalls[idx].progress = progress
                // Subagent text surfaces as .generic — accumulate it as nested lines.
                if case .generic(let msg) = progress {
                    activeToolCalls[idx].subagentLines.append(msg)
                }
            }
        case .speakBubbleRequested:
            break
        case .fileReverted(let path):
            changedFiles.removeAll { $0 == path }
        case .prefsChanged(let count):
            diagnostics.append(diagnostic(level: .info, message: "Auto-approval rules updated (\(count))."))
        case .appearancePrefChanged(let key, let value):
            appearancePrefs.update(key, value)
            if key == .sidebarVisible, case .bool(let visible) = value {
                sidebarVisible = visible
            }
        case .snapshotReady(let kind, let payload):
            pendingExport = PendingExport(kind: kind, payload: payload)
        case .clientAction(let action):
            messages.append(.clientAction(action))
        }
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
        lastUserBubbleID = nil
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
        guard let workspace else { return url.path }
        let workspacePaths = [workspace, workspace.resolvingSymlinksInPath()]
            .map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        let filePath = url.path
        let resolvedFilePath = url.resolvingSymlinksInPath().path
        for root in workspacePaths {
            if filePath.hasPrefix(root) {
                return String(filePath.dropFirst(root.count))
            }
            if resolvedFilePath.hasPrefix(root) {
                return String(resolvedFilePath.dropFirst(root.count))
            }
        }
        return filePath
    }

    func noteAgentReplyObserved() {
        isAwaitingFirstReplyForPrompt = false
        stalledToastVisible = false
    }
}
