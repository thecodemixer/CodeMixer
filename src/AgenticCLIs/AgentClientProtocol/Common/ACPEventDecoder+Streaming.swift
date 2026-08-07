import Foundation

import AgentCore
import AgentProtocol

/// Live `session/update` notifications: assistant message/thought chunks,
/// tool-call lifecycle, and background-session persistence callbacks.
extension ACPEventDecoder {
    func notification(method: String, params: JSONValue) async -> Batch {
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

    func sessionUpdate(_ params: JSONValue) async -> Batch {
        let update = params["update"] ?? params
        let kind = update["sessionUpdate"]?.stringValue
            ?? update["type"]?.stringValue
        if isForeignStreamingSession(params: params, kind: kind) {
            await cacheForeignStreaming(params: params, update: update, kind: kind)
            return Batch()
        }
        if state.phase() == .awaitingSession,
           kind != "session_info_update",
           kind != "current_mode_update",
           kind != "current_model_update" {
            return Batch()
        }
        switch kind {
        case "agent_message_chunk":
            return agentMessageChunk(update, params: params)
        case "agent_thought_chunk":
            return agentThoughtChunk(update)
        case "tool_call":
            return toolCall(update, params: params)
        case "tool_call_update":
            return toolCallUpdate(update, params: params)
        case "user_message_chunk":
            // Live user chunks for the foreground session are unusual; ignore.
            // Foreign user chunks are handled above via cacheForeignStreaming.
            return Batch()
        case "session_info_update":
            return await sessionInfoUpdate(params: params, update: update)
        case "current_mode_update":
            return currentModeUpdate(params: params, update: update)
        case "current_model_update":
            return currentModelUpdate(params: params, update: update)
        case "available_commands_update":
            return Batch()
        case "codemixer.dev/phase_update":
            return phaseUpdate(params: params, update: update)
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

    /// A file-level pipeline phase advanced (Custom ACP only). Bridged
    /// agent-agnostically to `AgentEvent.sessionPhaseChanged` regardless of
    /// whether `sessionID` is the foreground session — the reduction step
    /// decides what to do with a background file's marker; dropping it here
    /// would leave that session with no phase history once selected.
    ///
    /// When the phase advances on the *foreground* session, finalize any open
    /// assistant / thinking stream first so planner → implementer → reviewer
    /// text becomes separate transcript bubbles instead of one concatenated wall.
    func phaseUpdate(params: JSONValue, update: JSONValue) -> Batch {
        guard let status = update["status"]?.stringValue else { return Batch() }
        let sessionID = params["sessionId"]?.stringValue ?? state.sessionID() ?? ""
        guard !sessionID.isEmpty else { return Batch() }
        let phase = ACPPipelinePhaseMapping.phase(forStatus: status)
        var events: [AgentEvent] = []

        let isForeground = sessionID == state.sessionID()
        if isForeground, state.phase() == .ready, state.foregroundPhaseID() != phase.id {
            if let thoughtID = state.takeOpenThinkingBlockID() {
                events.append(.thinkingComplete(blockID: thoughtID, duration: .zero))
            }
            if let finalized = state.finalizedAssistantMessage() {
                events.append(.assistantText(
                    id: finalized.id.uuidString,
                    blockID: "agent-message",
                    text: finalized.text,
                    isFinal: true
                ))
            }
            state.setForegroundPhaseID(phase.id)
        } else if isForeground {
            state.setForegroundPhaseID(phase.id)
        }

        events.append(.sessionPhaseChanged(sessionID: sessionID, phase: phase))
        return Batch(events: events)
    }

    /// Whether this `session/update` belongs to a session other than the one
    /// currently bound as foreground.
    ///
    /// New Chat / warm resume keep the ACP process; only `state.sessionID()`
    /// changes. Without this gate, a late chunk for the previous id would
    /// stream into the new chat's transcript lane.
    func isForeignStreamingSession(params: JSONValue, kind: String?) -> Bool {
        let streamingKinds: Set<String> = [
            "agent_message_chunk",
            "agent_thought_chunk",
            "tool_call",
            "tool_call_update",
            "user_message_chunk",
        ]
        guard let kind, streamingKinds.contains(kind) else { return false }
        return isForeignSession(params: params)
    }

    /// Whether `params` names a session other than the bound foreground one.
    ///
    /// An update that names no session, or that arrives before a session is
    /// bound, is not foreign: the agent is describing the session being opened.
    func isForeignSession(params: JSONValue) -> Bool {
        guard let incoming = params["sessionId"]?.stringValue,
              let foreground = state.sessionID(),
              !incoming.isEmpty else { return false }
        return incoming != foreground
    }

    /// Mode and model updates name the session they describe, and a background
    /// session keeps sending them. Applying one from another session would show
    /// its mode/model as the foreground chat's.
    func currentModeUpdate(params: JSONValue, update: JSONValue) -> Batch {
        guard !isForeignSession(params: params),
              let modeID = update["currentModeId"]?.stringValue
              ?? update["modeId"]?.stringValue else { return Batch() }
        state.setCurrentModeID(modeID)
        return Batch(events: [
            .statusPhraseChanged(source: .adapterPinned, phrase: "Mode: \(modeID)"),
        ])
    }

    func currentModelUpdate(params: JSONValue, update: JSONValue) -> Batch {
        guard !isForeignSession(params: params),
              let modelID = update["currentModelId"]?.stringValue
              ?? update["modelId"]?.stringValue else { return Batch() }
        state.setCurrentModelID(modelID)
        return Batch()
    }

    /// Persist background-session stream chunks without foreground UI events.
    func cacheForeignStreaming(params: JSONValue,
                               update: JSONValue,
                               kind: String?) async {
        guard let sessionID = params["sessionId"]?.stringValue,
              !sessionID.isEmpty else { return }

        if let resource = a2uiResource(in: update["content"]),
           let event = a2uiBatchEvent(uri: resource.uri, text: resource.text, sessionID: sessionID) {
            await recordBackgroundSessionEvents(.init(sessionID: sessionID, events: [event]))
            return
        }

        func persist(_ role: ACPTurnRole, _ text: String) async {
            guard !text.isEmpty else { return }
            let event: AgentEvent
            switch role.stored {
            case .user:
                event = .userTurn(id: AdapterTurnID(rawValue: random.uuid().uuidString), text: text)
            case .thinking:
                let id = random.uuid()
                await recordBackgroundSessionEvents(.init(
                    sessionID: sessionID,
                    events: [
                        .thinkingChunk(blockID: id, delta: text),
                        .thinkingComplete(blockID: id, duration: .zero),
                    ]
                ))
                return
            default:
                let id = random.uuid().uuidString
                event = .assistantText(id: id,
                                       blockID: id,
                                       text: text,
                                       isFinal: true)
            }
            await recordBackgroundSessionEvents(.init(sessionID: sessionID,
                                                      events: [event]))
        }

        switch kind {
        case "user_message_chunk":
            if let flushed = state.appendForeignChunk(
                sessionID: sessionID,
                role: .user,
                delta: streamingText(from: update)
            ) {
                await persist(flushed.role, flushed.text)
            }
        case "agent_message_chunk":
            if let flushed = state.appendForeignChunk(
                sessionID: sessionID,
                role: .agent,
                delta: streamingText(from: update)
            ) {
                await persist(flushed.role, flushed.text)
            }
        case "agent_thought_chunk":
            if let flushed = state.appendForeignChunk(
                sessionID: sessionID,
                role: .thinking,
                delta: streamingText(from: update)
            ) {
                await persist(flushed.role, flushed.text)
            }
        case "tool_call":
            if let flushed = state.flushForeignBuffer(sessionID: sessionID) {
                await persist(flushed.role, flushed.text)
            }
            let toolCallID = update["toolCallId"]?.stringValue
                ?? update["id"]?.stringValue
                ?? "tool"
            let name = update["title"]?.stringValue
                ?? update["kind"]?.stringValue
                ?? "Tool"
            state.rememberToolStart(id: toolCallID, name: name, inputJSON: stringified(update["rawInput"]))
        case "tool_call_update":
            if let flushed = state.flushForeignBuffer(sessionID: sessionID) {
                await persist(flushed.role, flushed.text)
            }
            let toolCallID = update["toolCallId"]?.stringValue
                ?? update["id"]?.stringValue
                ?? "tool"
            let status = update["status"]?.stringValue
            guard status == "completed" || status == "failed" || status == "cancelled" else { return }
            let meta = state.takeToolMeta(id: toolCallID)
            let name = meta?.name
                ?? update["title"]?.stringValue
                ?? update["kind"]?.stringValue
                ?? "Tool"
            let outputSummary = update["content"]?.stringValue
                ?? stringified(update["rawOutput"])
                ?? status
                ?? ""
            await recordBackgroundSessionEvents(.init(
                sessionID: sessionID,
                events: [
                    .toolStart(
                        id: ToolCallID(rawValue: toolCallID),
                        name: name,
                        input: ToolInput(summary: name,
                                         jsonPayload: meta?.inputJSON ?? stringified(update)),
                        startedAt: clock.now()
                    ),
                    .toolEnd(
                        id: ToolCallID(rawValue: toolCallID),
                        success: status != "failed",
                        output: ToolOutput(summary: outputSummary,
                                           errorMessage: status == "failed"
                                               ? outputSummary : nil),
                        durationMS: 0
                    ),
                ]
            ))
        default:
            break
        }
    }

    func streamingText(from update: JSONValue) -> String {
        let content = update["content"]
        return content?["text"]?.stringValue
            ?? content?["content"]?.stringValue
            ?? update["text"]?.stringValue
            ?? ""
    }

    func agentMessageChunk(_ update: JSONValue, params: JSONValue) -> Batch {
        let content = update["content"]
        if let resource = a2uiResource(in: content) {
            let sessionID = params["sessionId"]?.stringValue ?? state.sessionID() ?? ""
            guard let event = a2uiBatchEvent(uri: resource.uri, text: resource.text, sessionID: sessionID) else {
                return Batch()
            }
            return Batch(events: [event])
        }
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

    func agentThoughtChunk(_ update: JSONValue) -> Batch {
        let content = update["content"]
        let text = content?["text"]?.stringValue ?? ""
        guard !text.isEmpty else { return Batch() }
        state.appendThoughtDelta(text)
        let blockID = state.thinkingBlockID(for: "thought", random: random)
        return Batch(events: [.thinkingChunk(blockID: blockID, delta: text)])
    }

    func toolCall(_ update: JSONValue, params: JSONValue) -> Batch {
        if let resource = a2uiResource(in: update["content"]) {
            let sessionID = params["sessionId"]?.stringValue ?? state.sessionID() ?? ""
            guard let event = a2uiBatchEvent(uri: resource.uri, text: resource.text, sessionID: sessionID) else {
                return Batch()
            }
            return Batch(events: [event])
        }
        let toolCallID = update["toolCallId"]?.stringValue
            ?? update["id"]?.stringValue
            ?? random.uuid().uuidString
        let title = update["title"]?.stringValue
            ?? update["kind"]?.stringValue
            ?? "Tool"
        let status = update["status"]?.stringValue
        if status == "completed" || status == "failed" {
            return toolCallUpdate(update, params: params)
        }
        let inputJSON = stringified(update)
        state.rememberToolStart(id: toolCallID, name: title, inputJSON: inputJSON)
        return Batch(events: [
            .toolStart(
                id: ToolCallID(rawValue: toolCallID),
                name: title,
                input: ToolInput(
                    summary: title,
                    jsonPayload: inputJSON
                ),
                startedAt: clock.now()
            ),
        ])
    }

    func toolCallUpdate(_ update: JSONValue, params: JSONValue) -> Batch {
        if let resource = a2uiResource(in: update["content"]) {
            let sessionID = params["sessionId"]?.stringValue ?? state.sessionID() ?? ""
            guard let event = a2uiBatchEvent(uri: resource.uri, text: resource.text, sessionID: sessionID) else {
                return Batch()
            }
            return Batch(events: [event])
        }
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
            _ = state.takeToolMeta(id: toolCallID)
            return Batch(events: [
                .toolEnd(
                    id: ToolCallID(rawValue: toolCallID),
                    success: success,
                    output: ToolOutput(summary: outputSummary),
                    durationMS: 0
                ),
            ])
        }
        if let content = update["content"]?.stringValue, !content.isEmpty {
            // Keyed on the ACP tool call id so this folds onto its `toolStart`.
            // `itemUUID` mints a per-item UUID for block ids and would never
            // match a tool call.
            return Batch(events: [
                .toolProgress(callID: ToolCallID(rawValue: toolCallID),
                              progress: .bashLine(content)),
            ])
        }
        return Batch()
    }

}
