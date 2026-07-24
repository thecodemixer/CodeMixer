import Foundation

import AgentCore
import AgentProtocol

/// Live `session/update` notifications: assistant message/thought chunks,
/// the tool-call lifecycle, and caching background (foreign) session
/// streams into the turn cache so a later `session/load` can restore them.
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
            // Background file sessions still update the Codemixer turn cache so
            // a later session/load can restore history if wire replay is empty.
            await cacheForeignStreaming(params: params, update: update, kind: kind)
            return Batch()
        }
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
            // Live user chunks for the foreground session are unusual; ignore.
            // Foreign user chunks are handled above via cacheForeignStreaming.
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

    func isForeignStreamingSession(params: JSONValue, kind: String?) -> Bool {
        let streamingKinds: Set<String> = [
            "agent_message_chunk",
            "agent_thought_chunk",
            "tool_call",
            "tool_call_update",
            "user_message_chunk",
        ]
        guard let kind, streamingKinds.contains(kind) else { return false }
        guard let incoming = params["sessionId"]?.stringValue,
              let foreground = state.sessionID(),
              !incoming.isEmpty else { return false }
        return incoming != foreground
    }

    /// Persist background-session stream chunks into the turn cache without UI events.
    func cacheForeignStreaming(params: JSONValue,
                               update: JSONValue,
                               kind: String?) async {
        guard let context = state.currentContext(),
              let sessionID = params["sessionId"]?.stringValue,
              !sessionID.isEmpty else { return }
        let customAgentID = context.customAgentID
        let index = sessionIndex

        func persist(_ role: String, _ text: String) async {
            guard !text.isEmpty else { return }
            let storedRole = role == "agent" ? "assistant" : role
            await index.appendConversationTurn(
                sessionID: sessionID,
                customAgentID: customAgentID,
                role: storedRole,
                text: text
            )
        }

        switch kind {
        case "user_message_chunk":
            if let flushed = state.appendForeignChunk(
                sessionID: sessionID,
                role: "user",
                delta: streamingText(from: update)
            ) {
                await persist(flushed.role, flushed.text)
            }
        case "agent_message_chunk":
            if let flushed = state.appendForeignChunk(
                sessionID: sessionID,
                role: "agent",
                delta: streamingText(from: update)
            ) {
                await persist(flushed.role, flushed.text)
            }
        case "agent_thought_chunk":
            if let flushed = state.appendForeignChunk(
                sessionID: sessionID,
                role: "thinking",
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
            await index.appendToolTurn(
                sessionID: sessionID,
                customAgentID: customAgentID,
                toolCallID: toolCallID,
                name: name,
                success: status != "failed",
                outputSummary: outputSummary,
                inputJSON: meta?.inputJSON ?? stringified(update)
            )
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

    func historyChunk(role: String, update: JSONValue) -> Batch {
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

    func agentMessageChunk(_ update: JSONValue) -> Batch {
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

    func agentThoughtChunk(_ update: JSONValue) -> Batch {
        let content = update["content"]
        let text = content?["text"]?.stringValue ?? ""
        guard !text.isEmpty else { return Batch() }
        state.appendThoughtDelta(text)
        let blockID = state.thinkingBlockID(for: "thought", random: random)
        return Batch(events: [.thinkingChunk(blockID: blockID, delta: text)])
    }

    func toolCall(_ update: JSONValue) -> Batch {
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

    func toolCallUpdate(_ update: JSONValue) -> Batch {
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

    func persistToolTurn(toolCallID: String,
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
}
