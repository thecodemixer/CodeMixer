import Foundation

import AgentCore
import AgentProtocol

/// Session lifecycle: opening a session (`session/new`, `session/load`,
/// `session/resume`), listing sessions, and finalizing a completed prompt
/// turn. Dashboard bootstrap and session-metadata bookkeeping live in
/// `+Dashboard`; live streaming updates live in `+Streaming`.
extension ACPEventDecoder {
    private static let sessionNotFoundCode = -32_004

    func response(id: JSONValue,
                  result: JSONValue?,
                  error: ACPIncoming.RPCError?) async -> Batch {
        let purpose = state.takePurpose(for: id)
        if let error {
            if purpose == .authenticate || error.message.localizedCaseInsensitiveContains("authentication") {
                let displayName = state.currentContext()?.displayName ?? "ACP agent"
                return Batch(events: [
                    .error(ACPAgentError.authenticationRequired(displayName: displayName).agentError),
                ])
            }
            if purpose == .sessionLoad {
                if error.code == Self.sessionNotFoundCode,
                   let context = state.currentContext(),
                   let sessionID = context.resumeSessionID,
                   !sessionID.isEmpty {
                    state.setSessionID(sessionID)
                    let local = await sessionIndex.localHistoryEvents(
                        sessionID: sessionID,
                        customAgentID: context.customAgentID,
                        random: random
                    )
                    if !local.isEmpty {
                        return Batch(events: local + [
                            .sessionStarted(
                                sessionID: sessionID,
                                model: state.currentModelID(),
                                cwd: context.workspace
                            ),
                            .cachedTranscriptLoaded(sessionID: sessionID),
                        ])
                    }
                }
                let sessionID = state.currentContext()?.resumeSessionID ?? "unknown"
                return Batch(events: [
                    .error(ACPAgentError.sessionLoadFailed(
                        sessionID: sessionID,
                        message: error.message
                    ).agentError),
                ])
            }
            return Batch(events: [
                .error(ACPAgentError.rpc(code: error.code, message: error.message).agentError),
            ])
        }
        guard let purpose else { return Batch() }

        switch purpose {
        case .initialize:
            return await handleInitialize(result: result)
        case .authenticate:
            return postInitializeBatch()
        case .sessionNew, .sessionLoad, .sessionResume:
            return await handleSessionOpen(purpose: purpose, result: result)
        case .sessionPrompt:
            return await finalizePromptTurn()
        case .sessionList:
            await mergeListedSessions(result)
            return Batch()
        case .sessionSetMode:
            return Batch()
        case .sessionSetModel:
            if let modelID = result?["modelId"]?.stringValue
                ?? result?["currentModelId"]?.stringValue {
                state.setCurrentModelID(modelID)
            }
            return Batch()
        case .other:
            return Batch()
        }
    }

    func handleSessionOpen(purpose: ACPClientState.RequestPurpose,
                           result: JSONValue?) async -> Batch {
        guard let context = state.currentContext() else {
            return Batch(events: [.error(ACPAgentError.missingSessionID.agentError)])
        }
        let sessionID: String
        if let id = result?["sessionId"]?.stringValue {
            sessionID = id
        } else if purpose == .sessionLoad || purpose == .sessionResume,
                  let resume = context.resumeSessionID {
            sessionID = resume
        } else {
            return Batch(events: [.error(ACPAgentError.missingSessionID.agentError)])
        }
        state.setSessionID(sessionID)
        let modes = ACPSessionModes.parse(result?["modes"])
        state.setSessionModes(
            currentModeID: modes.currentModeID,
            available: modes.available
        )
        let modelCatalog = ACPModelCatalog.parse(
            models: result?["models"],
            configOptions: result?["configOptions"]?.arrayValue ?? []
        )
        state.setSessionModels(
            currentModelID: modelCatalog.currentModelID,
            available: modelCatalog.available
        )
        await sessionIndex.recordSession(
            id: sessionID,
            customAgentID: context.customAgentID,
            workspace: context.workspace,
            title: nil
        )
        // Wire replay first so the UI paints history while still gated, then
        // SessionStart unlocks. When the agent streams nothing on load (Cursor),
        // restore from the Codemixer turn cache before SessionStart as well.
        var events = state.flushHistoryReplay()
        // Background work while the user watched another session (overview) may
        // still sit in the foreign buffer — persist it so local history below
        // includes the latest coalesced turn.
        if let pending = state.flushForeignBuffer(sessionID: sessionID),
           !pending.text.isEmpty {
            let role = pending.role == "agent" ? "assistant" : pending.role
            await sessionIndex.appendConversationTurn(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                role: role,
                text: pending.text
            )
        }
        let hasWireReplay = events.contains {
            switch $0 {
            case .userTurn, .assistantText, .textDelta, .thinkingChunk, .toolStart:
                return true
            default:
                return false
            }
        }
        if !hasWireReplay, purpose == .sessionLoad || purpose == .sessionResume {
            let local = await sessionIndex.localHistoryEvents(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                random: random
            )
            events.append(contentsOf: local)
        }
        events.append(.sessionStarted(
            sessionID: sessionID,
            model: modelCatalog.currentModelID,
            cwd: context.workspace
        ))
        var replies = [ACPInputEncoding.queuedPrompts(state: state)]
        if let list = ACPInputEncoding.listSessions(state: state) {
            replies.append(list)
        }
        let parked = state.takeParkedPermissions(sessionID: sessionID)
        for parkedPermission in parked {
            state.registerApproval(
                id: parkedPermission.prompt.id,
                requestID: parkedPermission.requestID,
                optionIDs: parkedPermission.optionIDs
            )
            events.append(.permissionRequest(prompt: parkedPermission.prompt))
        }
        return Batch(
            events: events,
            replies: replies.filter { !$0.isEmpty }
        )
    }

    func mergeListedSessions(_ result: JSONValue?) async {
        guard let context = state.currentContext(),
              let sessions = result?["sessions"]?.arrayValue else { return }
        var didMutateIndex = false
        for session in sessions {
            guard let id = session["sessionId"]?.stringValue else { continue }
            let title = session["title"]?.stringValue
            await sessionIndex.recordSession(
                id: id,
                customAgentID: context.customAgentID,
                workspace: context.workspace,
                title: title
            )
            let meta = session["_meta"]?.objectValue
            if let isOverview = meta?["codemixer.dev/overviewSession"]?.boolValue
                ?? meta?["overviewSession"]?.boolValue {
                let overviewURL = meta?["codemixer.dev/dashboardUrl"]?.stringValue
                    .flatMap(URL.init(string:))
                await sessionIndex.setIsOverview(
                    sessionID: id,
                    customAgentID: context.customAgentID,
                    isOverview: isOverview,
                    overviewURL: overviewURL
                )
                didMutateIndex = true
            }
            if let archived = meta?["archived"]?.boolValue {
                await sessionIndex.setArchived(
                    sessionID: id,
                    customAgentID: context.customAgentID,
                    archived: archived
                )
                didMutateIndex = true
            }
            if let needsAttention = meta?["needsAttention"]?.boolValue {
                await sessionIndex.setNeedsAttention(
                    sessionID: id,
                    customAgentID: context.customAgentID,
                    needsAttention: needsAttention
                )
                didMutateIndex = true
            }
        }
        if didMutateIndex {
            // Caller (handleSessionOpen) already emits sessionIndexChanged when listing.
            _ = didMutateIndex
        }
    }

    func finalizePromptTurn() async -> Batch {
        var events: [AgentEvent] = []
        if let thoughtID = state.takeOpenThinkingBlockID() {
            events.append(.thinkingComplete(blockID: thoughtID, duration: .zero))
        }
        if let thoughtText = state.takeThoughtText(),
           let context = state.currentContext(),
           let sessionID = state.sessionID() {
            // Await the turn cache write — a detached Task was racing
            // engine shutdown / the next `session/load`, so Cursor history
            // often replayed user turns only.
            await sessionIndex.appendConversationTurn(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                role: "thinking",
                text: thoughtText
            )
        }
        if let finalized = state.finalizedAssistantMessage() {
            events.append(.assistantText(
                id: finalized.id.uuidString,
                blockID: "agent-message",
                text: finalized.text,
                isFinal: true
            ))
            if let context = state.currentContext(), let sessionID = state.sessionID() {
                await sessionIndex.appendConversationTurn(
                    sessionID: sessionID,
                    customAgentID: context.customAgentID,
                    role: "assistant",
                    text: finalized.text
                )
            }
        }
        state.resetTurnScopedIDs()
        events.append(.activityStateChanged(.idle))
        return Batch(events: events)
    }
}
