import Foundation
import AgentProtocol
import AgentCore

/// Handles Codex App Server notifications: streaming deltas (assistant
/// message, reasoning, command output), item lifecycle (`item/started`,
/// `item/completed`), and turn completion. Everything else either has no
/// event mapping or is logged once via `SilentDiagnostics` and dropped.
extension CodexEventDecoder {
    func notification(method: String, params: JSONValue) async -> Batch {
        switch method {
        case "item/agentMessage/delta":
            return agentMessageDelta(params)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return reasoningDelta(params)
        case "item/commandExecution/outputDelta":
            return commandOutputDelta(params)
        case "item/started":
            return itemStarted(params)
        case "item/completed":
            return itemCompleted(params)
        case "turn/completed":
            return turnCompleted(params)
        case "error":
            return Batch(events: [.error(notificationError(params).agentError)])
        case "thread/started", "turn/started", "thread/status/changed",
             "serverRequest/resolved", "thread/tokenUsage/updated",
             "turn/diff/updated", "turn/plan/updated",
             "item/reasoning/summaryPartAdded":
            return Batch()
        default:
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "CodexEventDecoder",
                summary: "Unknown Codex notification",
                details: method
            )
            return Batch()
        }
    }

    private func itemStarted(_ params: JSONValue) -> Batch {
        guard let item = params["item"],
              let itemID = item["id"]?.stringValue,
              let type = item["type"]?.stringValue else { return Batch() }
        state.markItemStarted(itemID, at: clock.now())
        guard Self.toolTypes.contains(type) else { return Batch() }

        // ASSUMPTION: tool lifecycle items always provide `item.id`,
        // `item.type`, and either a type-specific tool field or `item.name`.
        // The checked-in schema fixture pins that minimum until a generated
        // schema from the user's installed Codex version replaces it.
        return Batch(events: [
            .toolStart(
                id: itemID,
                name: toolName(type: type, item: item),
                input: ToolInput(
                    summary: toolSummary(type: type, item: item),
                    jsonPayload: jsonString(item)
                ),
                startedAt: clock.now()
            ),
        ])
    }

    private func itemCompleted(_ params: JSONValue) -> Batch {
        guard let item = params["item"],
              let itemID = item["id"]?.stringValue,
              let type = item["type"]?.stringValue else { return Batch() }

        switch type {
        case "agentMessage":
            let text = item["text"]?.stringValue ?? ""
            let id = state.itemUUID(for: itemID, random: random)
            state.clearAssistantText(itemID: itemID)
            return Batch(events: [
                .assistantText(
                    id: id.uuidString,
                    blockID: itemID,
                    text: text,
                    isFinal: true
                ),
            ])
        case "plan":
            let text = item["text"]?.stringValue ?? ""
            return Batch(events: [
                .assistantText(id: itemID, blockID: itemID, text: text, isFinal: true),
            ])
        case "reasoning":
            let id = state.itemUUID(for: itemID, random: random)
            return Batch(events: [
                .thinkingComplete(blockID: id, duration: itemDuration(itemID: itemID, item: item)),
            ])
        default:
            guard Self.toolTypes.contains(type) else { return Batch() }
            var events: [AgentEvent] = [
                .toolEnd(
                    id: itemID,
                    success: toolSucceeded(item),
                    output: toolOutput(type: type, item: item),
                    durationMS: durationMilliseconds(itemID: itemID, item: item)
                ),
            ]
            if type == "fileChange", let changes = item["changes"]?.arrayValue {
                events.append(contentsOf: changes.compactMap(fileTouchedEvent))
            }
            return Batch(events: events)
        }
    }

    private func agentMessageDelta(_ params: JSONValue) -> Batch {
        guard let delta = params["delta"]?.stringValue else { return Batch() }
        let itemID = params["itemId"]?.stringValue
            ?? params["item"]?["id"]?.stringValue
            ?? "agent-message"
        let id = state.itemUUID(for: itemID, random: random)
        return Batch(events: [
            .assistantText(
                id: id.uuidString,
                blockID: itemID,
                text: state.appendAssistantDelta(delta, itemID: itemID),
                isFinal: false
            ),
        ])
    }

    private func reasoningDelta(_ params: JSONValue) -> Batch {
        guard let delta = params["delta"]?.stringValue else { return Batch() }
        let itemID = params["itemId"]?.stringValue ?? "reasoning"
        return Batch(events: [
            .thinkingChunk(
                blockID: state.itemUUID(for: itemID, random: random),
                delta: delta
            ),
        ])
    }

    private func commandOutputDelta(_ params: JSONValue) -> Batch {
        guard let delta = params["delta"]?.stringValue,
              let itemID = params["itemId"]?.stringValue else { return Batch() }
        let id = state.itemUUID(for: itemID, random: random)
        let events = delta.split(separator: "\n", omittingEmptySubsequences: true)
            .map { AgentEvent.toolProgress(callID: id, progress: .bashLine(String($0))) }
        return Batch(events: events)
    }

    private func turnCompleted(_ params: JSONValue) -> Batch {
        let turn = params["turn"]
        let turnID = turn?["id"]?.stringValue
        state.completeTurn(turnID)
        guard turn?["status"]?.stringValue == "failed" else {
            return Batch(events: [.activityStateChanged(.idle)])
        }
        let message = turn?["error"]?["message"]?.stringValue ?? "turn failed"
        return Batch(events: [
            .error(CodexAgentError.rpc(code: -1, message: message).agentError),
            .activityStateChanged(.idle),
        ])
    }

    private func notificationError(_ params: JSONValue) -> CodexAgentError {
        let message = params["error"]?["message"]?.stringValue
            ?? params["message"]?.stringValue
            ?? "unknown notification error"
        return .rpc(code: -1, message: message)
    }
}
