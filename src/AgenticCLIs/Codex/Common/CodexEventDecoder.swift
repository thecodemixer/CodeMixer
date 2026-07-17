import Foundation

import AgentCore

/// Converts Codex App Server responses, notifications, and server requests
/// into Codemixer events plus protocol replies that must be written back.
public actor CodexEventDecoder {
    public struct Batch: Sendable {
        public let events: [AgentEvent]
        public let replies: [Data]

        public init(events: [AgentEvent] = [], replies: [Data] = []) {
            self.events = events
            self.replies = replies
        }
    }

    private let state: CodexSessionState
    private let threadIndex: CodexThreadIndex
    private let workspace: URL
    private let clock: any AgentClock
    private let random: any RandomSource

    public init(state: CodexSessionState,
                threadIndex: CodexThreadIndex,
                workspace: URL,
                clock: any AgentClock,
                random: any RandomSource) {
        self.state = state
        self.threadIndex = threadIndex
        self.workspace = workspace
        self.clock = clock
        self.random = random
    }

    public func decode(_ incoming: CodexAppServerIncoming) async -> Batch {
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
                          error: CodexAppServerIncoming.RPCError?) async -> Batch {
        let purpose = state.takePurpose(for: id)
        if let error {
            return Batch(events: [
                .error(CodexAgentError.rpc(code: error.code, message: error.message).agentError),
            ])
        }
        guard let purpose else { return Batch() }

        switch purpose {
        case .threadStart, .threadResume:
            guard let threadID = result?["thread"]?["id"]?.stringValue else {
                return Batch(events: [.error(CodexAgentError.missingThreadID.agentError)])
            }
            state.setThreadID(threadID)
            await threadIndex.recordThread(id: threadID, workspace: workspace)
            let queued = CodexInputEncoding.queuedTurns(state: state)
            let replies = queued.isEmpty ? [] : [queued]
            let model = result?["thread"]?["model"]?.stringValue
            var events: [AgentEvent] = [
                .sessionStarted(sessionID: threadID, model: model, cwd: workspace),
            ]
            if let turns = result?["thread"]?["turns"]?.arrayValue, !turns.isEmpty {
                events.append(contentsOf: CodexThreadHistoryReplay.events(from: turns, random: random))
            }
            return Batch(events: events, replies: replies)

        case .turnStart(let title):
            guard let turnID = result?["turn"]?["id"]?.stringValue else {
                return Batch(events: [.error(CodexAgentError.missingTurnID.agentError)])
            }
            state.beginTurn(turnID)
            if let threadID = state.threadID() {
                await threadIndex.recordTurn(threadID: threadID, title: title)
            }
            return Batch()

        case .initialize, .compact, .review, .other:
            return Batch()
        }
    }

    private func notification(method: String, params: JSONValue) async -> Batch {
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

    private func serverRequest(id: JSONValue,
                               method: String,
                               params: JSONValue) async -> Batch {
        guard Self.approvalMethods.contains(method) else {
            let error = CodexAgentError.unknownServerRequest(method: method)
            return Batch(
                events: [.error(error.agentError)],
                replies: [
                    CodexRPCCodec.errorResponse(
                        id: id,
                        code: -32601,
                        message: "Unsupported server request: \(method)"
                    ),
                ]
            )
        }

        let prompt = approvalPrompt(method: method, params: params)
        let signature = "\(prompt.toolName)|\(prompt.summary)|\(prompt.argumentsSummary)"
        if state.shouldAutoApprove(signature: signature) {
            return Batch(replies: [
                CodexInputEncoding.permissionResponse(id: id, allow: true),
            ])
        }
        state.registerApproval(id: prompt.id, requestID: id, signature: signature)
        return Batch(events: [.permissionRequest(prompt: prompt)])
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

    private func approvalPrompt(method: String, params: JSONValue) -> PermissionPrompt {
        let toolName: String
        let summary: String
        switch method {
        case "item/commandExecution/requestApproval":
            toolName = "Bash"
            summary = params["reason"]?.stringValue
                ?? params["command"]?.stringValue
                ?? "Approve command execution"
        case "item/fileChange/requestApproval":
            toolName = "Edit"
            summary = params["reason"]?.stringValue
                ?? params["grantRoot"]?.stringValue
                ?? "Approve file changes"
        default:
            toolName = "Permissions"
            summary = params["reason"]?.stringValue ?? "Approve requested permissions"
        }
        return PermissionPrompt(
            id: random.uuid(),
            toolName: toolName,
            summary: summary,
            argumentsSummary: jsonString(params) ?? "{}",
            requestedAt: clock.now()
        )
    }

    private func toolName(type: String, item: JSONValue) -> String {
        if let name = item["name"]?.stringValue { return name }
        switch type {
        case "commandExecution": return "Bash"
        case "fileChange": return "Edit"
        case "mcpToolCall": return item["tool"]?.stringValue ?? "MCP"
        case "dynamicToolCall": return item["tool"]?.stringValue ?? "Tool"
        case "webSearch": return "WebSearch"
        case "imageView": return "ImageView"
        case "collabAgentToolCall": return item["tool"]?.stringValue ?? "Subagent"
        default: return type
        }
    }

    private func toolSummary(type: String, item: JSONValue) -> String {
        switch type {
        case "commandExecution":
            return item["command"]?.stringValue ?? "Run command"
        case "fileChange":
            return item["changes"]?.arrayValue?
                .compactMap { $0["path"]?.stringValue }
                .joined(separator: ", ") ?? "Apply file changes"
        case "mcpToolCall", "dynamicToolCall":
            return item["tool"]?.stringValue ?? type
        case "webSearch":
            return item["query"]?.stringValue ?? "Search the web"
        case "imageView":
            return item["path"]?.stringValue ?? "View image"
        default:
            return item["name"]?.stringValue ?? type
        }
    }

    private func toolOutput(type: String, item: JSONValue) -> ToolOutput {
        let error = item["error"]?["message"]?.stringValue
            ?? item["error"]?.stringValue
        let summary: String
        switch type {
        case "commandExecution":
            summary = item["aggregatedOutput"]?.stringValue ?? item["status"]?.stringValue ?? ""
        case "fileChange":
            summary = toolSummary(type: type, item: item)
        case "mcpToolCall":
            summary = jsonString(item["result"] ?? .null) ?? item["status"]?.stringValue ?? ""
        default:
            summary = item["status"]?.stringValue ?? toolSummary(type: type, item: item)
        }
        return ToolOutput(summary: summary, jsonPayload: jsonString(item), errorMessage: error)
    }

    private func toolSucceeded(_ item: JSONValue) -> Bool {
        if let exitCode = item["exitCode"]?.numberValue {
            return Int(exitCode) == 0
        }
        if let success = item["success"]?.boolValue {
            return success
        }
        return ["completed", "success"].contains(item["status"]?.stringValue ?? "")
    }

    private func durationMilliseconds(itemID: String, item: JSONValue) -> Int {
        if let duration = item["durationMs"]?.numberValue {
            return max(0, Int(duration))
        }
        guard let start = state.takeItemStartedAt(itemID) else { return 0 }
        return max(0, Int(clock.now().timeIntervalSince(start) * 1_000))
    }

    private func itemDuration(itemID: String, item: JSONValue) -> Duration {
        .milliseconds(durationMilliseconds(itemID: itemID, item: item))
    }

    private func fileTouchedEvent(_ change: JSONValue) -> AgentEvent? {
        guard let path = change["path"]?.stringValue else { return nil }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : workspace.appendingPathComponent(path)
        return .fileTouched(url, kind: .hookReported)
    }

    private func notificationError(_ params: JSONValue) -> CodexAgentError {
        let message = params["error"]?["message"]?.stringValue
            ?? params["message"]?.stringValue
            ?? "unknown notification error"
        return .rpc(code: -1, message: message)
    }

    private func jsonString(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let toolTypes: Set<String> = [
        "commandExecution",
        "fileChange",
        "mcpToolCall",
        "dynamicToolCall",
        "collabAgentToolCall",
        "webSearch",
        "imageView",
    ]

    private static let approvalMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
    ]
}
