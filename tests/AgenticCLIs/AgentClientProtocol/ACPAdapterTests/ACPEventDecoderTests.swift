@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport
import Foundation
import Testing

@Suite("ACP event decoder")
struct ACPEventDecoderTests {

    @Test("authenticate success continues into initialized and session/new")
    func authenticateSuccess() async {
        let fixture = ACPDecoderFixture()
        let initBatch = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([:]),
                "authMethods": .array([
                    .object(["id": .string("token"), "name": .string("Token")]),
                ]),
            ]),
            error: nil
        ))
        #expect(initBatch.replies.count == 1)
        #expect(String(decoding: initBatch.replies[0], as: UTF8.self).contains("authenticate"))

        let authBatch = await fixture.decode(.response(id: .number(2), result: .object([:]), error: nil))
        let joined = authBatch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(joined.contains("initialized"))
        #expect(joined.contains("session/new"))
    }

    @Test("session new response emits sessionStarted and records session index")
    func sessionNew() async {
        let fixture = ACPDecoderFixture(customAgentID: "cursor")
        let batch = await fixture.openSession(id: "abc-123")
        #expect(batch.events.contains {
            if case .sessionStarted(let id, _, let cwd) = $0 {
                return id == "abc-123" && cwd == fixture.workspace
            }
            return false
        })
        let summaries = await fixture.sessionIndex.summaries(
            workspace: fixture.workspace,
            customAgentID: "cursor"
        )
        #expect(summaries.contains { $0.id == "abc-123" })
    }

    @Test("session new response records advertised modes with name and description")
    func sessionNewModes() async {
        let fixture = ACPDecoderFixture(customAgentID: "custom")
        _ = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([:]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        _ = await fixture.decode(.response(
            id: .number(2),
            result: .object([
                "sessionId": .string("mode-sess"),
                "modes": .object([
                    "currentModeId": .string("migrate"),
                    "availableModes": .array([
                        .object([
                            "id": .string("migrate"),
                            "name": .string("Migrate"),
                            "description": .string("Run migrations"),
                        ]),
                        .object([
                            "id": .string("document"),
                            "name": .string("Document"),
                        ]),
                    ]),
                ]),
            ]),
            error: nil
        ))
        let modes = fixture.state.availableModes()
        #expect(modes.map(\.id) == ["migrate", "document"])
        #expect(modes[0].name == "Migrate")
        #expect(modes[0].description == "Run migrations")
        #expect(modes[1].name == "Document")
        #expect(modes[1].description == nil)
        #expect(fixture.state.currentModeID() == "migrate")
    }

    @Test("session new falls back to mode id when name is missing")
    func sessionNewModeNameFallback() async {
        let fixture = ACPDecoderFixture()
        _ = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([:]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        _ = await fixture.decode(.response(
            id: .number(2),
            result: .object([
                "sessionId": .string("s1"),
                "modes": .object([
                    "availableModes": .array([
                        .object(["id": .string("agent")]),
                    ]),
                ]),
            ]),
            error: nil
        ))
        let modes = fixture.state.availableModes()
        #expect(modes.count == 1)
        #expect(modes[0].id == "agent")
        #expect(modes[0].name == "agent")
    }

    @Test("session new response records advertised models for the composer")
    func sessionNewModels() async {
        let fixture = ACPDecoderFixture(customAgentID: "cursor")
        _ = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([:]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        let batch = await fixture.decode(.response(
            id: .number(2),
            result: .object([
                "sessionId": .string("abc-123"),
                "models": .object([
                    "currentModelId": .string("auto"),
                    "availableModels": .array([
                        .object([
                            "modelId": .string("auto"),
                            "name": .string("Auto"),
                        ]),
                        .object([
                            "modelId": .string("gpt-5.4"),
                            "name": .string("GPT-5.4"),
                        ]),
                    ]),
                ]),
            ]),
            error: nil
        ))
        #expect(batch.events.contains {
            if case .sessionStarted(let id, let model, _) = $0 {
                return id == "abc-123" && model == "auto"
            }
            return false
        })
        #expect(fixture.state.availableModels().map(\.id) == ["auto", "gpt-5.4"])
    }

    @Test("session new falls back to model configOptions when models object is empty")
    func sessionNewModelConfigOptions() async {
        let fixture = ACPDecoderFixture(customAgentID: "cursor")
        _ = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([:]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        _ = await fixture.decode(.response(
            id: .number(2),
            result: .object([
                "sessionId": .string("abc-123"),
                "configOptions": .array([
                    .object([
                        "id": .string("model"),
                        "category": .string("model"),
                        "currentValue": .string("sonnet-4.6"),
                        "options": .array([
                            .object([
                                "value": .string("auto"),
                                "name": .string("Auto"),
                            ]),
                            .object([
                                "value": .string("sonnet-4.6"),
                                "name": .string("Sonnet 4.6"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            error: nil
        ))
        #expect(fixture.state.availableModels().map(\.label) == ["Auto", "Sonnet 4.6"])
        #expect(fixture.state.currentModelID() == "sonnet-4.6")
    }

    @Test("session load falls back to resume id when result omits sessionId")
    func sessionLoadFallback() async {
        let fixture = ACPDecoderFixture(
            customAgentID: "cursor",
            resumeSessionID: "resume-99"
        )
        _ = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object(["loadSession": .bool(true)]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        let batch = await fixture.decode(.response(id: .number(2), result: .object([:]), error: nil))
        #expect(batch.events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return id == "resume-99" }
            return false
        })
    }

    @Test("session list merge records remote sessions")
    func sessionListMerge() async {
        let fixture = ACPDecoderFixture(customAgentID: "cursor")
        _ = await fixture.openSession(
            capabilities: .object([
                "loadSession": .bool(true),
                "sessionCapabilities": .object(["list": .object([:])]),
            ])
        )
        _ = await fixture.decode(.response(
            id: .number(3),
            result: .object([
                "sessions": .array([
                    .object([
                        "sessionId": .string("remote-1"),
                        "title": .string("Earlier chat"),
                    ]),
                ]),
            ]),
            error: nil
        ))
        let summaries = await fixture.sessionIndex.summaries(
            workspace: fixture.workspace,
            customAgentID: "cursor"
        )
        #expect(summaries.contains { $0.id == "remote-1" && $0.title == "Earlier chat" })
    }

    @Test("agent message chunks accumulate before prompt completion")
    func streamingChunks() async {
        let fixture = ACPDecoderFixture()
        _ = await fixture.openSession()
        let promptID = fixture.state.nextRequestID(for: .sessionPrompt)
        _ = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["text": .string("code")]),
                ]),
            ])
        ))
        _ = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["text": .string("mixer")]),
                ]),
            ])
        ))
        let batch = await fixture.decode(.response(
            id: promptID,
            result: .object(["stopReason": .string("end_turn")]),
            error: nil
        ))
        #expect(batch.events.contains {
            if case .assistantText(_, _, let text, true) = $0 { return text == "codemixer" }
            return false
        })
    }

    @Test("agent thought chunk maps to thinkingChunk")
    func thoughtChunk() async {
        let fixture = ACPDecoderFixture()
        let batch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object(["text": .string("hmm")]),
                ]),
            ])
        ))
        #expect(batch.events.contains {
            if case .thinkingChunk(_, let delta) = $0 { return delta == "hmm" }
            return false
        })
    }

    @Test("first assistant chunk completes open thinking; finalize persists thought for replay")
    func thinkingPersistedForLocalReplay() async {
        let fixture = ACPDecoderFixture(customAgentID: "cursor")
        _ = await fixture.openSession(id: "s-think")
        _ = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object(["text": .string("reason")]),
                ]),
            ])
        ))
        let firstAssistant = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["text": .string("answer")]),
                ]),
            ])
        ))
        #expect(firstAssistant.events.contains {
            if case .thinkingComplete = $0 { return true }
            return false
        })
        let promptID = fixture.state.nextRequestID(for: .sessionPrompt)
        _ = await fixture.decode(.response(
            id: promptID,
            result: .object(["stopReason": .string("end_turn")]),
            error: nil
        ))
        try? await Task.sleep(for: .milliseconds(50))
        let replay = await fixture.sessionIndex.localHistoryEvents(
            sessionID: "s-think",
            customAgentID: "cursor",
            random: FakeRandomSource()
        )
        #expect(replay.contains {
            if case .thinkingChunk(_, let delta) = $0 { return delta == "reason" }
            return false
        })
        #expect(replay.contains {
            if case .thinkingComplete = $0 { return true }
            return false
        })
        #expect(replay.contains {
            if case .assistantText(_, _, let text, true) = $0 { return text == "answer" }
            return false
        })
    }

    @Test("tool call start and completion map to toolStart and toolEnd")
    func toolLifecycle() async {
        let fixture = ACPDecoderFixture()
        let start = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("t1"),
                    "title": .string("Read"),
                    "status": .string("running"),
                ]),
            ])
        ))
        #expect(start.events.contains {
            if case .toolStart(let id, let name, _, _) = $0 {
                return id == "t1" && name == "Read"
            }
            return false
        })

        let end = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("t1"),
                    "status": .string("completed"),
                    "content": .string("done"),
                ]),
            ])
        ))
        #expect(end.events.contains {
            if case .toolEnd(let id, let success, let output, _) = $0 {
                return id == "t1" && success && output.summary == "done"
            }
            return false
        })
    }

    @Test("completed tool calls persist into local history replay")
    func toolPersistedForLocalReplay() async {
        let fixture = ACPDecoderFixture(customAgentID: "cursor")
        _ = await fixture.openSession(id: "s-tool")
        _ = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("read-1"),
                    "title": .string("Read"),
                    "status": .string("running"),
                ]),
            ])
        ))
        _ = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("read-1"),
                    "status": .string("completed"),
                    "content": .string("file contents"),
                ]),
            ])
        ))
        try? await Task.sleep(for: .milliseconds(50))
        let replay = await fixture.sessionIndex.localHistoryEvents(
            sessionID: "s-tool",
            customAgentID: "cursor",
            random: FakeRandomSource()
        )
        #expect(replay.contains {
            if case .toolStart(let id, let name, _, _) = $0 {
                return id == "read-1" && name == "Read"
            }
            return false
        })
        #expect(replay.contains {
            if case .toolEnd(let id, let success, let output, _) = $0 {
                return id == "read-1" && success && output.summary == "file contents"
            }
            return false
        })
    }

    @Test("tool call update with progress content maps to toolProgress")
    func toolProgress() async {
        let fixture = ACPDecoderFixture()
        let batch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("t2"),
                    "content": .string("running ls"),
                ]),
            ])
        ))
        #expect(batch.events.contains {
            if case .toolProgress(_, .bashLine(let line)) = $0 { return line == "running ls" }
            return false
        })
    }

    @Test("session info update records title in session index")
    func sessionInfoUpdate() async {
        let fixture = ACPDecoderFixture(customAgentID: "cursor")
        _ = await fixture.openSession(id: "sess-title")
        _ = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("sess-title"),
                "update": .object([
                    "sessionUpdate": .string("session_info_update"),
                    "title": .string("Renamed chat"),
                ]),
            ])
        ))
        let summaries = await fixture.sessionIndex.summaries(
            workspace: fixture.workspace,
            customAgentID: "cursor"
        )
        #expect(summaries.contains { $0.id == "sess-title" && $0.title == "Renamed chat" })
    }

    @Test("permission request emits permissionRequest event")
    func permissionRequest() async {
        let fixture = ACPDecoderFixture()
        let batch = await fixture.decode(.serverRequest(
            id: .number(50),
            method: "session/request_permission",
            params: .object([
                "options": .array([
                    .object(["kind": .string("allow_once"), "optionId": .string("o1")]),
                    .object(["kind": .string("reject_once"), "optionId": .string("o2")]),
                ]),
                "toolCall": .object([
                    "title": .string("Shell"),
                    "kind": .string("execute"),
                ]),
            ])
        ))
        #expect(batch.events.contains {
            if case .permissionRequest(let prompt) = $0 {
                return prompt.toolName == "Shell"
            }
            return false
        })
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(reply.isEmpty)
    }

    @Test("permission request auto-approves when signature was remembered")
    func permissionAutoApprove() async {
        let fixture = ACPDecoderFixture()
        fixture.state.rememberAutoApproval(signature: "Shell|Shell")
        let batch = await fixture.decode(.serverRequest(
            id: .number(51),
            method: "request_permission",
            params: .object([
                "options": .array([
                    .object(["kind": .string("allow_always"), "optionId": .string("always")]),
                ]),
                "toolCall": .object(["title": .string("Shell")]),
            ])
        ))
        #expect(batch.events.isEmpty)
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(reply.contains("\"optionId\":\"always\""))
    }

    @Test("unknown server request returns unsupported error reply")
    func unknownServerRequest() async {
        let fixture = ACPDecoderFixture()
        let batch = await fixture.decode(.serverRequest(
            id: .number(88),
            method: "experimental/method",
            params: .object([:])
        ))
        #expect(batch.events.contains {
            if case .error(.unsupportedOperation(let detail)) = $0 {
                return detail.contains("unknown-server-request")
            }
            return false
        })
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(reply.contains("-32601"))
    }

    @Test("session resume response emits sessionStarted with resume id")
    func sessionResumeDecode() async {
        let fixture = ACPDecoderFixture(
            customAgentID: "cursor",
            resumeSessionID: "resume-55"
        )
        _ = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "sessionCapabilities": .object(["resume": .object([:])]),
                ]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        let batch = await fixture.decode(.response(id: .number(2), result: .object([:]), error: nil))
        #expect(batch.events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return id == "resume-55" }
            return false
        })
    }

    @Test("session open flushes queued prompts after session id is assigned")
    func queuedPromptFlush() async {
        let fixture = ACPDecoderFixture()
        fixture.state.enqueuePrompt("queued hello")
        let batch = await fixture.openSession(id: "open-1")
        let replyText = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(replyText.contains("queued hello"))
        #expect(replyText.contains("session/prompt"))
    }

    @Test("tool call with completed status maps directly to toolEnd")
    func toolImmediateComplete() async {
        let fixture = ACPDecoderFixture()
        let batch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("t9"),
                    "title": .string("Done"),
                    "status": .string("completed"),
                    "content": .string("ok"),
                ]),
            ])
        ))
        #expect(batch.events.contains {
            if case .toolEnd(let id, true, let output, _) = $0 {
                return id == "t9" && output.summary == "ok"
            }
            return false
        })
    }

    @Test("rpc errors map to AgentError unsupportedOperation")
    func rpcError() async {
        let fixture = ACPDecoderFixture()
        let id = fixture.state.nextRequestID(for: .sessionNew)
        let batch = await fixture.decode(.response(
            id: id,
            result: nil,
            error: .init(code: -32_602, message: "bad params", data: nil)
        ))
        #expect(batch.events.contains {
            if case .error(.unsupportedOperation(let detail)) = $0 {
                return detail.contains("rpc:-32602:bad params")
            }
            return false
        })
    }

    @Test("session/load history chunks become user and assistant turns before SessionStart")
    func sessionLoadHistoryReplay() async {
        let fixture = ACPDecoderFixture(resumeSessionID: "resume-hist")
        _ = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object(["loadSession": .bool(true)]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        fixture.state.setPhase(.awaitingSession)

        let userBatch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("resume-hist"),
                "update": .object([
                    "sessionUpdate": .string("user_message_chunk"),
                    "messageId": .string("u1"),
                    "content": .object(["type": .string("text"), "text": .string("hello")]),
                ]),
            ])
        ))
        #expect(userBatch.events.isEmpty)

        let agentBatch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("resume-hist"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("a1"),
                    "content": .object(["type": .string("text"), "text": .string("hi there")]),
                ]),
            ])
        ))
        #expect(agentBatch.events.contains {
            if case .userTurn(_, let text) = $0 { return text == "hello" }
            return false
        })

        let loadID = fixture.state.nextRequestID(for: .sessionLoad)
        let openBatch = await fixture.decode(.response(
            id: loadID,
            result: .object(["modes": .object([:]), "models": .object([:])]),
            error: nil
        ))
        #expect(openBatch.events.contains {
            if case .assistantText(_, _, let text, true) = $0 { return text == "hi there" }
            return false
        })
        #expect(openBatch.events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return id == "resume-hist" }
            return false
        })
        let sessionIdx = openBatch.events.firstIndex {
            if case .sessionStarted = $0 { return true }
            return false
        }
        let assistantIdx = openBatch.events.firstIndex {
            if case .assistantText(_, _, _, true) = $0 { return true }
            return false
        }
        if let sessionIdx, let assistantIdx {
            #expect(assistantIdx < sessionIdx)
        }
    }

    @Test("session/load thought chunks become thinkingComplete before SessionStart")
    func sessionLoadThoughtReplay() async {
        let fixture = ACPDecoderFixture(resumeSessionID: "resume-think")
        _ = await fixture.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object(["loadSession": .bool(true)]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        fixture.state.setPhase(.awaitingSession)

        _ = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("resume-think"),
                "update": .object([
                    "sessionUpdate": .string("user_message_chunk"),
                    "messageId": .string("u1"),
                    "content": .object(["type": .string("text"), "text": .string("why?")]),
                ]),
            ])
        ))
        let thoughtBatch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("resume-think"),
                "update": .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "messageId": .string("t1"),
                    "content": .object(["type": .string("text"), "text": .string("pondering")]),
                ]),
            ])
        ))
        #expect(thoughtBatch.events.contains {
            if case .userTurn(_, let text) = $0 { return text == "why?" }
            return false
        })
        let agentBatch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("resume-think"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("a1"),
                    "content": .object(["type": .string("text"), "text": .string("because")]),
                ]),
            ])
        ))
        #expect(agentBatch.events.contains {
            if case .thinkingChunk(_, let delta) = $0 { return delta == "pondering" }
            return false
        })
        #expect(agentBatch.events.contains {
            if case .thinkingComplete = $0 { return true }
            return false
        })

        let loadID = fixture.state.nextRequestID(for: .sessionLoad)
        let openBatch = await fixture.decode(.response(
            id: loadID,
            result: .object(["modes": .object([:]), "models": .object([:])]),
            error: nil
        ))
        #expect(openBatch.events.contains {
            if case .assistantText(_, _, let text, true) = $0 { return text == "because" }
            return false
        })
        let thinkIdx = agentBatch.events.firstIndex {
            if case .thinkingComplete = $0 { return true }
            return false
        }
        let assistantIdx = openBatch.events.firstIndex {
            if case .assistantText(_, _, _, true) = $0 { return true }
            return false
        }
        #expect(thinkIdx != nil)
        #expect(assistantIdx != nil)
    }

    @Test("session/load RPC error surfaces session-load-failed")
    func sessionLoadRPCError() async {
        let fixture = ACPDecoderFixture(resumeSessionID: "resume-fail")
        let id = fixture.state.nextRequestID(for: .sessionLoad)
        let batch = await fixture.decode(.response(
            id: id,
            result: nil,
            error: .init(code: -32_000, message: "not found", data: nil)
        ))
        #expect(batch.events.contains {
            if case .error(.unsupportedOperation(let detail)) = $0 {
                return detail.contains("session-load-failed:resume-fail:not found")
            }
            return false
        })
    }
}
