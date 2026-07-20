import Foundation

import AgentCore
import AgentProtocol

/// Converts ACP responses, notifications, and server requests into Codemixer
/// events plus protocol replies that must be written back.
public actor ACPEventDecoder {
    public struct Batch: Sendable {
        public let events: [AgentEvent]
        public let replies: [Data]

        public init(events: [AgentEvent] = [], replies: [Data] = []) {
            self.events = events
            self.replies = replies
        }
    }

    private let state: ACPClientState
    private let sessionIndex: any ACPSessionIndexing
    private let fileAccess: ACPFileAccess
    private let terminals: ACPTerminalSession
    private let clock: any AgentClock
    private let random: any RandomSource

    public init(state: ACPClientState,
                sessionIndex: any ACPSessionIndexing,
                fileAccess: ACPFileAccess,
                terminals: ACPTerminalSession,
                clock: any AgentClock,
                random: any RandomSource) {
        self.state = state
        self.sessionIndex = sessionIndex
        self.fileAccess = fileAccess
        self.terminals = terminals
        self.clock = clock
        self.random = random
    }

    public func decode(_ incoming: ACPIncoming) async -> Batch {
        switch incoming {
        case .response(let id, let result, let error):
            return await response(id: id, result: result, error: error)
        case .notification(let method, let params):
            return await notification(method: method, params: params)
        case .serverRequest(let id, let method, let params):
            return await serverRequest(id: id, method: method, params: params)
        }
    }

    private func response(id: JSONValue,
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
            return finalizePromptTurn()
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

    private func handleInitialize(result: JSONValue?) async -> Batch {
        state.setAgentCapabilities(result?["agentCapabilities"])
        let authMethods = result?["authMethods"]?.arrayValue ?? []
        if let methodID = authMethods.compactMap({ $0["id"]?.stringValue }).first {
            return Batch(replies: [
                ACPInputEncoding.authenticate(methodID: methodID, state: state),
            ])
        }
        return postInitializeBatch()
    }

    private func postInitializeBatch() -> Batch {
        var events: [AgentEvent] = []
        if let resume = ACPInputEncoding.resumeUnsupportedAfterInitialize(state: state) {
            events.append(.error(ACPAgentError.resumeUnsupported(sessionID: resume).agentError))
        }
        return Batch(
            events: events,
            replies: [ACPInputEncoding.postInitialize(state: state)]
        )
    }

    private func handleSessionOpen(purpose: ACPClientState.RequestPurpose,
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
        // Flush any open history buffers before marking the session ready.
        var events = state.flushHistoryReplay()
        // Cursor (and any agent that skips load replay) — restore from the
        // Codemixer-owned turn cache when the wire stream was empty.
        if events.isEmpty, purpose == .sessionLoad || purpose == .sessionResume {
            let local = await sessionIndex.localHistoryEvents(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                random: random
            )
            events.append(contentsOf: local)
        }
        state.setSessionID(sessionID)
        let modes = result?["modes"]
        let available = (modes?["availableModes"]?.arrayValue ?? []).compactMap { mode -> ACPSessionMode? in
            guard let id = mode["id"]?.stringValue, !id.isEmpty else { return nil }
            let name = mode["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id
            let description = mode["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return ACPSessionMode(id: id, name: name, description: description)
        }
        state.setSessionModes(
            currentModeID: modes?["currentModeId"]?.stringValue,
            available: available
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
        events.append(.sessionStarted(
            sessionID: sessionID,
            model: modelCatalog.currentModelID,
            cwd: context.workspace
        ))
        var replies = [ACPInputEncoding.queuedPrompts(state: state)]
        if let list = ACPInputEncoding.listSessions(state: state) {
            replies.append(list)
        }
        return Batch(
            events: events,
            replies: replies.filter { !$0.isEmpty }
        )
    }

    private func mergeListedSessions(_ result: JSONValue?) async {
        guard let context = state.currentContext(),
              let sessions = result?["sessions"]?.arrayValue else { return }
        for session in sessions {
            guard let id = session["sessionId"]?.stringValue else { continue }
            let title = session["title"]?.stringValue
            await sessionIndex.recordSession(
                id: id,
                customAgentID: context.customAgentID,
                workspace: context.workspace,
                title: title
            )
        }
    }

    private func notification(method: String, params: JSONValue) async -> Batch {
        switch method {
        case "session/update":
            return await sessionUpdate(params)
        default:
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "ACPEventDecoder",
                summary: "Unknown ACP notification",
                details: method
            )
            return Batch()
        }
    }

    private func sessionUpdate(_ params: JSONValue) async -> Batch {
        let update = params["update"] ?? params
        let kind = update["sessionUpdate"]?.stringValue
            ?? update["type"]?.stringValue
        switch kind {
        case "agent_message_chunk":
            if state.phase() == .awaitingSession {
                return historyChunk(role: "agent", update: update)
            }
            return agentMessageChunk(update)
        case "agent_thought_chunk":
            if state.phase() == .awaitingSession {
                return historyChunk(role: "thinking", update: update)
            }
            return agentThoughtChunk(update)
        case "tool_call":
            if state.phase() == .awaitingSession {
                // Flush open text history so tools stay in transcript order.
                let flushed = state.flushHistoryReplay()
                let tool = toolCall(update)
                return Batch(events: flushed + tool.events, replies: tool.replies)
            }
            return toolCall(update)
        case "tool_call_update":
            if state.phase() == .awaitingSession {
                let flushed = state.flushHistoryReplay()
                let tool = toolCallUpdate(update)
                return Batch(events: flushed + tool.events, replies: tool.replies)
            }
            return toolCallUpdate(update)
        case "user_message_chunk":
            if state.phase() == .awaitingSession {
                return historyChunk(role: "user", update: update)
            }
            return Batch()
        case "session_info_update":
            return await sessionInfoUpdate(params: params, update: update)
        case "current_mode_update":
            if let modeID = update["currentModeId"]?.stringValue
                ?? update["modeId"]?.stringValue {
                state.setCurrentModeID(modeID)
                return Batch(events: [
                    .statusPhraseChanged(source: .adapterPinned, phrase: "Mode: \(modeID)"),
                ])
            }
            return Batch()
        case "current_model_update":
            if let modelID = update["currentModelId"]?.stringValue
                ?? update["modelId"]?.stringValue {
                state.setCurrentModelID(modelID)
            }
            return Batch()
        case "available_commands_update":
            return Batch()
        default:
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "ACPEventDecoder",
                summary: "Unknown ACP session update",
                details: kind ?? "nil"
            )
            return Batch()
        }
    }

    private func historyChunk(role: String, update: JSONValue) -> Batch {
        let content = update["content"]
        let text = content?["text"]?.stringValue
            ?? content?["content"]?.stringValue
            ?? update["text"]?.stringValue
            ?? ""
        let messageID = update["messageId"]?.stringValue
            ?? update["message_id"]?.stringValue
        let events = state.appendHistoryChunk(
            role: role,
            messageID: messageID,
            delta: text,
            random: random
        )
        return Batch(events: events)
    }

    private func finalizePromptTurn() -> Batch {
        var events: [AgentEvent] = []
        if let thoughtID = state.takeOpenThinkingBlockID() {
            events.append(.thinkingComplete(blockID: thoughtID, duration: .zero))
        }
        if let thoughtText = state.takeThoughtText(),
           let context = state.currentContext(),
           let sessionID = state.sessionID() {
            let customAgentID = context.customAgentID
            let index = sessionIndex
            Task {
                await index.appendConversationTurn(
                    sessionID: sessionID,
                    customAgentID: customAgentID,
                    role: "thinking",
                    text: thoughtText
                )
            }
        }
        if let finalized = state.finalizedAssistantMessage() {
            events.append(.assistantText(
                id: finalized.id.uuidString,
                blockID: "agent-message",
                text: finalized.text,
                isFinal: true
            ))
            if let context = state.currentContext(), let sessionID = state.sessionID() {
                let customAgentID = context.customAgentID
                let text = finalized.text
                let index = sessionIndex
                Task {
                    await index.appendConversationTurn(
                        sessionID: sessionID,
                        customAgentID: customAgentID,
                        role: "assistant",
                        text: text
                    )
                }
            }
        }
        state.resetTurnScopedIDs()
        events.append(.activityStateChanged(.idle))
        return Batch(events: events)
    }

    private func agentMessageChunk(_ update: JSONValue) -> Batch {
        let content = update["content"]
        let text = content?["text"]?.stringValue
            ?? content?["content"]?.stringValue
            ?? ""
        guard !text.isEmpty else { return Batch() }
        var events: [AgentEvent] = []
        if let thoughtID = state.takeOpenThinkingBlockID() {
            events.append(.thinkingComplete(blockID: thoughtID, duration: .zero))
        }
        let itemID = "agent-message"
        let id = state.itemUUID(for: itemID, random: random)
        events.append(.assistantText(
            id: id.uuidString,
            blockID: itemID,
            text: state.appendAssistantDelta(text, itemID: itemID),
            isFinal: false
        ))
        return Batch(events: events)
    }

    private func agentThoughtChunk(_ update: JSONValue) -> Batch {
        let content = update["content"]
        let text = content?["text"]?.stringValue ?? ""
        guard !text.isEmpty else { return Batch() }
        state.appendThoughtDelta(text)
        let blockID = state.thinkingBlockID(for: "thought", random: random)
        return Batch(events: [.thinkingChunk(blockID: blockID, delta: text)])
    }

    private func toolCall(_ update: JSONValue) -> Batch {
        let toolCallID = update["toolCallId"]?.stringValue
            ?? update["id"]?.stringValue
            ?? random.uuid().uuidString
        let title = update["title"]?.stringValue
            ?? update["kind"]?.stringValue
            ?? "Tool"
        let status = update["status"]?.stringValue
        if status == "completed" || status == "failed" {
            return toolCallUpdate(update)
        }
        let inputJSON = stringified(update)
        state.rememberToolStart(id: toolCallID, name: title, inputJSON: inputJSON)
        return Batch(events: [
            .toolStart(
                id: toolCallID,
                name: title,
                input: ToolInput(
                    summary: title,
                    jsonPayload: inputJSON
                ),
                startedAt: clock.now()
            ),
        ])
    }

    private func toolCallUpdate(_ update: JSONValue) -> Batch {
        let toolCallID = update["toolCallId"]?.stringValue
            ?? update["id"]?.stringValue
            ?? "tool"
        let status = update["status"]?.stringValue
        let success = status != "failed"
        if status == "completed" || status == "failed" || status == "cancelled" {
            let outputSummary = update["content"]?.stringValue
                ?? stringified(update["rawOutput"])
                ?? status
                ?? ""
            let meta = state.takeToolMeta(id: toolCallID)
            let name = meta?.name
                ?? update["title"]?.stringValue
                ?? update["kind"]?.stringValue
                ?? "Tool"
            let inputJSON = meta?.inputJSON ?? stringified(update)
            persistToolTurn(
                toolCallID: toolCallID,
                name: name,
                success: success,
                outputSummary: outputSummary,
                inputJSON: inputJSON
            )
            return Batch(events: [
                .toolEnd(
                    id: toolCallID,
                    success: success,
                    output: ToolOutput(summary: outputSummary),
                    durationMS: 0
                ),
            ])
        }
        if let content = update["content"]?.stringValue, !content.isEmpty {
            let callID = state.itemUUID(for: toolCallID, random: random)
            return Batch(events: [
                .toolProgress(callID: callID, progress: .bashLine(content)),
            ])
        }
        return Batch()
    }

    private func persistToolTurn(toolCallID: String,
                                 name: String,
                                 success: Bool,
                                 outputSummary: String,
                                 inputJSON: String?) {
        // Only cache live turns — load-time wire replay must not rewrite the index.
        guard state.phase() == .ready,
              let context = state.currentContext(),
              let sessionID = state.sessionID() else { return }
        let customAgentID = context.customAgentID
        let index = sessionIndex
        Task {
            await index.appendToolTurn(
                sessionID: sessionID,
                customAgentID: customAgentID,
                toolCallID: toolCallID,
                name: name,
                success: success,
                outputSummary: outputSummary,
                inputJSON: inputJSON
            )
        }
    }

    private func sessionInfoUpdate(params: JSONValue, update: JSONValue) async -> Batch {
        guard let context = state.currentContext() else { return Batch() }
        let sessionID = params["sessionId"]?.stringValue ?? state.sessionID()
        guard let sessionID else { return Batch() }
        let title = update["title"]?.stringValue
        await sessionIndex.recordSession(
            id: sessionID,
            customAgentID: context.customAgentID,
            workspace: context.workspace,
            title: title
        )
        return Batch()
    }

    private func serverRequest(id: JSONValue,
                               method: String,
                               params: JSONValue) async -> Batch {
        switch method {
        case "request_permission", "session/request_permission":
            return permissionRequest(id: id, params: params)
        case "fs/read_text_file":
            return await fileAccess.read(id: id, params: params)
        case "fs/write_text_file":
            return await fileAccess.write(id: id, params: params)
        case "terminal/create":
            return await terminals.create(id: id, params: params)
        case "terminal/output":
            return await terminals.output(id: id, params: params)
        case "terminal/wait_for_exit":
            return await terminals.waitForExit(id: id, params: params)
        case "terminal/kill":
            return await terminals.kill(id: id, params: params)
        case "terminal/release":
            return await terminals.release(id: id, params: params)
        default:
            return Batch(
                events: [.error(ACPAgentError.unknownServerRequest(method: method).agentError)],
                replies: [
                    ACPRPCCodec.errorResponse(
                        id: id,
                        code: -32601,
                        message: "Unsupported server request: \(method)"
                    ),
                ]
            )
        }
    }

    private func permissionRequest(id: JSONValue, params: JSONValue) -> Batch {
        let options = params["options"]?.arrayValue ?? []
        var optionIDs: [String: String] = [:]
        for option in options {
            if let kind = option["kind"]?.stringValue,
               let optionID = option["optionId"]?.stringValue {
                optionIDs[kind] = optionID
            }
        }
        let toolCall = params["toolCall"]
        let toolName = toolCall?["title"]?.stringValue
            ?? toolCall?["kind"]?.stringValue
            ?? "Permissions"
        let summary = toolCall?["title"]?.stringValue
            ?? "Approve requested permissions"
        let prompt = PermissionPrompt(
            id: random.uuid(),
            toolName: toolName,
            summary: summary,
            argumentsSummary: stringified(params) ?? "{}",
            requestedAt: clock.now()
        )
        let signature = "\(prompt.toolName)|\(prompt.summary)"
        if state.shouldAutoApprove(signature: signature),
           let optionID = optionIDs["allow_always"] ?? optionIDs["allow_once"] {
            return Batch(replies: [
                ACPInputEncoding.permissionResponse(id: id, optionID: optionID, cancelled: false),
            ])
        }
        state.registerApproval(id: prompt.id, requestID: id, optionIDs: optionIDs)
        return Batch(events: [.permissionRequest(prompt: prompt)])
    }

    private func stringified(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
