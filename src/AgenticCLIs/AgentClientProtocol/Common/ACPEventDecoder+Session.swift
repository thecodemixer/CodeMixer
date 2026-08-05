import Foundation

import AgentCore
import AgentProtocol

/// Session lifecycle: opening a session (`session/new`, `session/load`,
/// `session/resume`), listing sessions, and finalizing a completed prompt
/// turn. Dashboard bootstrap and session-metadata bookkeeping live in
/// `+Dashboard`; live streaming updates live in `+Streaming`.
extension ACPEventDecoder {
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
                let sessionID = state.currentContext()?.resumeSessionID ?? "unknown"
                return Batch(events: [
                    .error(.sessionReadinessFailed(
                        sessionID: sessionID,
                        detail: error.message
                    )),
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
        case .a2uiFeedbackPrompt:
            // Never finalizes a turn or touches heartbeat/idle state — an A2UI
            // action/error Resource is host-to-agent feedback, not a chat turn.
            return Batch()
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
        await updateSessionMetadata(.registered(sessionID: sessionID,
                                                title: nil))
        var events: [AgentEvent] = []
        // Background work while the user watched another session (overview) may
        // still sit in the foreign buffer — persist it so local history below
        // includes the latest coalesced turn.
        if let pending = state.flushForeignBuffer(sessionID: sessionID),
           !pending.text.isEmpty {
            let bufferedEvents: [AgentEvent]
            switch pending.role.stored {
            case .user:
                bufferedEvents = [.userTurn(id: random.uuid().uuidString,
                                            text: pending.text)]
            case .thinking:
                let id = random.uuid()
                bufferedEvents = [
                    .thinkingChunk(blockID: id, delta: pending.text),
                    .thinkingComplete(blockID: id, duration: .zero),
                ]
            default:
                let id = random.uuid().uuidString
                bufferedEvents = [.assistantText(id: id,
                                                 blockID: id,
                                                 text: pending.text,
                                                 isFinal: true)]
            }
            await recordBackgroundSessionEvents(.init(sessionID: sessionID,
                                                      events: bufferedEvents))
        }
        events.insert(.sessionStarted(
            sessionID: sessionID,
            model: modelCatalog.currentModelID,
            cwd: context.workspace
        ), at: 0)
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
        guard state.currentContext() != nil,
              let sessions = result?["sessions"]?.arrayValue else { return }
        // Local transcript index is the only session-list authority. Never
        // register vendor-only chats from session/list — only refresh metadata
        // for sessions already present (overview / archived markers).
        for session in sessions {
            guard let id = session["sessionId"]?.stringValue else { continue }
            let meta = session["_meta"]?.objectValue
            if let isOverview = meta?["codemixer.dev/overviewSession"]?.boolValue
                ?? meta?["overviewSession"]?.boolValue {
                if isOverview {
                    let overviewURL = meta?["codemixer.dev/dashboardUrl"]?.stringValue
                        .flatMap(URL.init(string:))
                    await updateSessionMetadata(.markAsOverview(sessionID: id,
                                                                url: overviewURL))
                } else {
                    await updateSessionMetadata(.unmarkAsOverview(sessionID: id))
                }
            }
            if let archived = meta?["archived"]?.boolValue {
                if archived {
                    await updateSessionMetadata(.archived(sessionID: id))
                } else {
                    await updateSessionMetadata(.unarchived(sessionID: id))
                }
            }
        }
    }

    func finalizePromptTurn() async -> Batch {
        var events: [AgentEvent] = []
        if let thoughtID = state.takeOpenThinkingBlockID() {
            events.append(.thinkingComplete(blockID: thoughtID, duration: .zero))
        }
        _ = state.takeThoughtText()
        if let finalized = state.finalizedAssistantMessage() {
            events.append(.assistantText(
                id: finalized.id.uuidString,
                blockID: "agent-message",
                text: finalized.text,
                isFinal: true
            ))
        }
        state.resetTurnScopedIDs()
        events.append(.activityStateChanged(.idle))
        return Batch(events: events)
    }
}
