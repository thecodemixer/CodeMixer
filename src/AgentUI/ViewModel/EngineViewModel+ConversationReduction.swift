import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {

    // MARK: - Event reduction

    func apply(_ event: AgentEvent) {
        switch event {
        case .sessionStarted(let id, let model, let cwd):
            let projectChanged = workspace?.path != cwd.path
            let previousSessionID = sessionID
            let sessionChanged = previousSessionID != id
            let shouldResetConversation = projectChanged || (sessionChanged && activity == .idle)
            sessionID = id
            // First session with no explicit workspace shell: treat cwd as the root.
            if workspaceRoot == nil {
                workspaceRoot = cwd
            }
            workspace = cwd
            if shouldResetConversation {
                clearConversationState()
            }
            // SessionStart with a model is the first live signal from the
            // resumed agent process. For Claude Code, that matters because the
            // visible history may already be on screen from JSONL replay; wait
            // one engine-aligned settle window before enabling GUI sends. Other
            // agents do not have this JSONL-vs-live-PTY split, so they can
            // unlock immediately on their real SessionStart.
            if isComposerLockedForSessionResume, id == previousSessionID, model != nil {
                if isComposerWaitingForClaudeCodeResume {
                    scheduleComposerResumeUnlock(after: SessionSwitchingTiming.claudeCodeComposerHookUnlock)
                } else {
                    unlockComposerForSessionResume()
                }
            }
            if projectChanged {
                onActiveProjectChanged()
            } else if sessionChanged, !id.isEmpty {
                // Codex (and similar adapters) record the resumable thread only
                // after `thread/start` succeeds — after the engine's empty
                // bootstrap `sessionStarted`. Refresh so New Chat / first open
                // appear in the sidebar.
                loadSessions(for: cwd.path)
            }
        case .userTurn(let id, let text):
            finishSessionSwitchIfNeeded()
            applyUserTurn(id: id, text: text)
        case .assistantText(let msgID, _, let text, let isFinal):
            finishSessionSwitchIfNeeded()
            noteAgentReplyObserved()
            // If there is an in-progress streaming bubble, update or promote it.
            // Promoting (isFinal = true) replaces the .assistantStreaming with
            // .assistant so the bubble ID stays the same and SwiftUI keeps the view.
            if let lastIdx = messages.indices.last,
               case .assistantStreaming(let existingID, _) = messages[lastIdx] {
                messages[lastIdx] = isFinal
                    ? .assistant(bubbleID: existingID, text: text)
                    : .assistantStreaming(bubbleID: existingID, text: text)
            } else {
                let id = UUID(uuidString: msgID) ?? random.uuid()
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
