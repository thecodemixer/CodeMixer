import Foundation

import AgentCore
import AgentProtocol

/// Converts ACP responses, notifications, and server requests into Codemixer
/// events plus protocol replies that must be written back.
public actor ACPEventDecoder {
    private static let sessionNotFoundCode = -32_004

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
        var events: [AgentEvent] = []
        if let meta = result?["_meta"]?.objectValue ?? result?["agentInfo"]?.objectValue?["_meta"]?.objectValue,
           let dashboard = meta["codemixer.dev/dashboardUrl"]?.stringValue,
           let url = URL(string: dashboard) {
            let title = meta["codemixer.dev/dashboardTitle"]?.stringValue
            events.append(.agentDashboard(url: url, title: title))
        }
        let authMethods = result?["authMethods"]?.arrayValue ?? []
        if let methodID = authMethods.compactMap({ $0["id"]?.stringValue }).first {
            return Batch(
                events: events,
                replies: [
                    ACPInputEncoding.authenticate(methodID: methodID, state: state),
                ]
            )
        }
        let post = postInitializeBatch()
        return Batch(events: events + post.events, replies: post.replies)
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

    private func mergeListedSessions(_ result: JSONValue?) async {
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

    private func isForeignStreamingSession(params: JSONValue, kind: String?) -> Bool {
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
    private func cacheForeignStreaming(params: JSONValue,
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

    private func streamingText(from update: JSONValue) -> String {
        let content = update["content"]
        return content?["text"]?.stringValue
            ?? content?["content"]?.stringValue
            ?? update["text"]?.stringValue
            ?? ""
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
        var events: [AgentEvent] = []
        var replies: [Data] = []
        let meta = update["_meta"]?.objectValue ?? params["_meta"]?.objectValue
        var didMutateIndex = false
        if let archived = meta?["archived"]?.boolValue {
            await sessionIndex.setArchived(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                archived: archived
            )
            if archived {
                // Migration Restart archives file sessions — drop parked reviews
                // and cancel any open permission RPCs so timeouts cannot auto-deny
                // into a restarted pipeline.
                let dropped = state.clearParkedPermissions(sessionID: sessionID)
                for parked in dropped {
                    events.append(.permissionAlreadyResolved(
                        id: parked.prompt.id,
                        byDevice: "session-archived"
                    ))
                    replies.append(ACPInputEncoding.permissionResponse(
                        id: parked.requestID,
                        optionID: nil,
                        cancelled: true
                    ))
                }
                if sessionID == state.sessionID() {
                    for pending in state.takeAllPendingApprovals() {
                        events.append(.permissionAlreadyResolved(
                            id: pending.promptID,
                            byDevice: "session-archived"
                        ))
                        replies.append(ACPInputEncoding.permissionResponse(
                            id: pending.approval.requestID,
                            optionID: nil,
                            cancelled: true
                        ))
                    }
                }
            }
            didMutateIndex = true
        }
        if let needsAttention = meta?["needsAttention"]?.boolValue {
            await sessionIndex.setNeedsAttention(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                needsAttention: needsAttention
            )
            let resolvedTitle: String
            if let title, !title.isEmpty {
                resolvedTitle = title
            } else {
                resolvedTitle = await sessionTitle(
                    sessionID: sessionID,
                    customAgentID: context.customAgentID,
                    workspace: context.workspace
                ) ?? sessionID
            }
            events.append(.sessionAttentionChanged(
                sessionID: sessionID,
                title: resolvedTitle,
                needsAttention: needsAttention
            ))
            didMutateIndex = true
        }
        if let isOverview = meta?["codemixer.dev/overviewSession"]?.boolValue
            ?? meta?["overviewSession"]?.boolValue {
            let overviewURL = meta?["codemixer.dev/dashboardUrl"]?.stringValue
                .flatMap(URL.init(string:))
            await sessionIndex.setIsOverview(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                isOverview: isOverview,
                overviewURL: overviewURL
            )
            didMutateIndex = true
        }
        if didMutateIndex || title != nil {
            events.append(.sessionIndexChanged(projectPath: context.workspace))
        }
        return Batch(events: events, replies: replies)
    }

    private func reverseSessionNew(id: JSONValue, params: JSONValue) async -> Batch {
        guard let context = state.currentContext() else {
            return Batch(
                replies: [
                    ACPRPCCodec.errorResponse(
                        id: id,
                        code: -32_602,
                        message: "Missing session context"
                    ),
                ]
            )
        }
        guard let sessionID = params["sessionId"]?.stringValue, !sessionID.isEmpty else {
            return Batch(
                replies: [
                    ACPRPCCodec.errorResponse(
                        id: id,
                        code: -32_602,
                        message: "Missing sessionId"
                    ),
                ]
            )
        }
        let cwdPath = params["cwd"]?.stringValue ?? context.workspace.path
        let workspace = URL(fileURLWithPath: cwdPath)
        let title = params["title"]?.stringValue
        let meta = params["_meta"]?.objectValue
        await sessionIndex.recordSession(
            id: sessionID,
            customAgentID: context.customAgentID,
            workspace: workspace,
            title: title
        )
        if let isOverview = meta?["codemixer.dev/overviewSession"]?.boolValue
            ?? meta?["overviewSession"]?.boolValue {
            let overviewURL = meta?["codemixer.dev/dashboardUrl"]?.stringValue
                .flatMap(URL.init(string:))
            await sessionIndex.setIsOverview(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                isOverview: isOverview,
                overviewURL: overviewURL
            )
        }
        if let archived = meta?["archived"]?.boolValue {
            await sessionIndex.setArchived(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                archived: archived
            )
        }
        if let needsAttention = meta?["needsAttention"]?.boolValue {
            await sessionIndex.setNeedsAttention(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                needsAttention: needsAttention
            )
        }
        return Batch(
            events: [.sessionIndexChanged(projectPath: workspace)],
            replies: [ACPRPCCodec.response(id: id, result: .object([:]))]
        )
    }

    private func serverRequest(id: JSONValue,
                               method: String,
                               params: JSONValue) async -> Batch {
        switch method {
        case "session/new":
            return await reverseSessionNew(id: id, params: params)
        case "request_permission", "session/request_permission":
            return await permissionRequest(id: id, params: params)
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

    private func permissionRequest(id: JSONValue, params: JSONValue) async -> Batch {
        let parsed = parsePermissionOptions(params["options"]?.arrayValue ?? [])
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
            requestedAt: clock.now(),
            options: parsed.options.isEmpty ? nil : parsed.options
        )
        let signature = "\(prompt.toolName)|\(prompt.summary)"
        if state.shouldAutoApprove(signature: signature),
           let optionID = parsed.optionIDs["allow_always"] ?? parsed.optionIDs["allow_once"] {
            return Batch(replies: [
                ACPInputEncoding.permissionResponse(id: id, optionID: optionID, cancelled: false),
            ])
        }
        let requestSessionID = params["sessionId"]?.stringValue ?? state.sessionID()
        let foregroundSessionID = state.sessionID()
        if let requestSessionID,
           let foregroundSessionID,
           requestSessionID != foregroundSessionID {
            state.parkPermission(
                sessionID: requestSessionID,
                parked: ACPClientState.ParkedPermission(
                    prompt: prompt,
                    requestID: id,
                    optionIDs: parsed.optionIDs
                )
            )
            guard let context = state.currentContext() else { return Batch() }
            await sessionIndex.setNeedsAttention(
                sessionID: requestSessionID,
                customAgentID: context.customAgentID,
                needsAttention: true
            )
            let title = await sessionTitle(
                sessionID: requestSessionID,
                customAgentID: context.customAgentID,
                workspace: context.workspace
            ) ?? requestSessionID
            return Batch(events: [
                .sessionIndexChanged(projectPath: context.workspace),
                .sessionAttentionChanged(
                    sessionID: requestSessionID,
                    title: title,
                    needsAttention: true
                ),
            ])
        }
        state.registerApproval(id: prompt.id, requestID: id, optionIDs: parsed.optionIDs)
        return Batch(events: [.permissionRequest(prompt: prompt)])
    }

    private func parsePermissionOptions(_ options: [JSONValue])
        -> (options: [PermissionOption], optionIDs: [String: String]) {
        var optionIDs: [String: String] = [:]
        var customOptions: [PermissionOption] = []
        for option in options {
            guard let optionID = option["optionId"]?.stringValue else { continue }
            if let kind = option["kind"]?.stringValue {
                optionIDs[kind] = optionID
            }
            let label = option["name"]?.stringValue
                ?? option["label"]?.stringValue
                ?? optionID
            customOptions.append(PermissionOption(optionId: optionID, label: label))
        }
        return (customOptions, optionIDs)
    }

    private func sessionTitle(sessionID: String,
                              customAgentID: String,
                              workspace: URL) async -> String? {
        let summaries = await sessionIndex.summaries(
            workspace: workspace,
            customAgentID: customAgentID
        )
        return summaries.first(where: { $0.id == sessionID })?.title
    }

    private func stringified(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
