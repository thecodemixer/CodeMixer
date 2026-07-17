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
    private let sessionIndex: ACPSessionIndex
    private let fileAccess: ACPFileAccess
    private let terminals: ACPTerminalSession
    private let clock: any AgentClock
    private let random: any RandomSource

    public init(state: ACPClientState,
                sessionIndex: ACPSessionIndex,
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
            return Batch(events: [
                .error(ACPAgentError.rpc(code: error.code, message: error.message).agentError),
            ])
        }
        guard let purpose else { return Batch() }

        switch purpose {
        case .initialize:
            return await handleInitialize(result: result)
        case .authenticate:
            return Batch(replies: [ACPInputEncoding.postInitialize(state: state)])
        case .sessionNew, .sessionLoad, .sessionResume:
            return await handleSessionOpen(purpose: purpose, result: result)
        case .sessionPrompt:
            return finalizePromptTurn()
        case .sessionList:
            await mergeListedSessions(result)
            return Batch()
        case .sessionSetMode:
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
        let replies = [ACPInputEncoding.postInitialize(state: state)]
        return Batch(replies: replies)
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
        state.setSessionID(sessionID)
        let modes = result?["modes"]
        let available = (modes?["availableModes"]?.arrayValue ?? []).compactMap {
            $0["id"]?.stringValue
        }
        state.setSessionModes(
            currentModeID: modes?["currentModeId"]?.stringValue,
            availableModeIDs: available
        )
        await sessionIndex.recordSession(
            id: sessionID,
            customAgentID: context.customAgentID,
            workspace: context.workspace,
            title: nil
        )
        var replies = [ACPInputEncoding.queuedPrompts(state: state)]
        if let list = ACPInputEncoding.listSessions(state: state) {
            replies.append(list)
        }
        return Batch(
            events: [.sessionStarted(sessionID: sessionID, model: nil, cwd: context.workspace)],
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
            return agentMessageChunk(update)
        case "agent_thought_chunk":
            return agentThoughtChunk(update)
        case "tool_call":
            return toolCall(update)
        case "tool_call_update":
            return toolCallUpdate(update)
        case "user_message_chunk":
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

    private func finalizePromptTurn() -> Batch {
        var events: [AgentEvent] = []
        if let finalized = state.finalizedAssistantMessage() {
            events.append(.assistantText(
                id: finalized.id.uuidString,
                blockID: "agent-message",
                text: finalized.text,
                isFinal: true
            ))
        }
        events.append(.activityStateChanged(.idle))
        return Batch(events: events)
    }

    private func agentMessageChunk(_ update: JSONValue) -> Batch {
        let content = update["content"]
        let text = content?["text"]?.stringValue
            ?? content?["content"]?.stringValue
            ?? ""
        guard !text.isEmpty else { return Batch() }
        let itemID = "agent-message"
        let id = state.itemUUID(for: itemID, random: random)
        return Batch(events: [
            .assistantText(
                id: id.uuidString,
                blockID: itemID,
                text: state.appendAssistantDelta(text, itemID: itemID),
                isFinal: false
            ),
        ])
    }

    private func agentThoughtChunk(_ update: JSONValue) -> Batch {
        let content = update["content"]
        let text = content?["text"]?.stringValue ?? ""
        guard !text.isEmpty else { return Batch() }
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
        return Batch(events: [
            .toolStart(
                id: toolCallID,
                name: title,
                input: ToolInput(
                    summary: title,
                    jsonPayload: stringified(update)
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
            return Batch(events: [
                .toolEnd(
                    id: toolCallID,
                    success: success,
                    output: ToolOutput(summary: update["content"]?.stringValue
                        ?? stringified(update["rawOutput"])
                        ?? status
                        ?? ""),
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
