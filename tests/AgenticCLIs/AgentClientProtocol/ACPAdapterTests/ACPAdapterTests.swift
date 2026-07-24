@testable import AgentClientProtocol
@testable import AgentCore
import AgentProtocol
import AgentTestSupport
import Foundation
import Testing

@Suite("ACPAdapter")
struct ACPAdapterTests {

    @Test("transportDescriptor is agentClientProtocol")
    func transportDescriptor() {
        let adapter = makeAdapter()
        #expect(adapter.transportDescriptor == .agentClientProtocol)
    }

    @Test("ACP adapter declares sessionHandshakeGate")
    func sessionHandshakeGateCapability() {
        let adapter = makeAdapter()
        #expect(adapter.capabilities.contains(.sessionHandshakeGate))
        #expect(adapter.capabilities.contains(.resumableSessions))
    }

    @Test("bootstrap emits initialize only")
    func bootstrapInitializeOnly() throws {
        let adapter = makeAdapter()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        let data = adapter.sessionBootstrapBytes(context: context)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"method\":\"initialize\""))
        #expect(text.contains("\"jsonrpc\":\"2.0\""))
        #expect(!text.contains("session/new"))
    }

    @Test("framing splits newline delimited frames")
    func framing() throws {
        var framing = ACPFraming()
        let frames = try framing.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        #expect(frames.count == 2)
    }

    @Test("cancel emits session/cancel notification")
    func cancel() {
        let adapter = makeAdapter()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = adapter.sessionBootstrapBytes(context: context)
        // No session yet → empty cancel
        #expect(adapter.cancelSequence().isEmpty)
    }

    @Test("permission mapping prefers allow_always for allowAlways")
    func permissionMapping() {
        let options = [
            "allow_once": "o1",
            "allow_always": "o2",
            "reject_once": "o3",
        ]
        #expect(ACPPermissionMapping.optionID(for: .allowAlways, options: options) == "o2")
        #expect(ACPPermissionMapping.optionID(for: .allow, options: options) == "o1")
        #expect(ACPPermissionMapping.optionID(for: .deny, options: options) == "o3")
    }

    @Test("factory builds adapter for ACP custom refs only")
    func factory() async {
        await CustomAgentAdapterFactories.shared.resetForTests()
        await CustomAgentAdapterFactories.shared.register(TestACPAdapterFactory())
        let acp = CustomAgentRef(
            id: "gemini",
            displayName: "Gemini",
            transport: .agentClientProtocol,
            executablePath: SystemPaths.trueBinary.path,
            arguments: []
        )
        let stdio = CustomAgentRef(
            id: "other",
            displayName: "Other",
            transport: .stdioJSONRPC,
            executablePath: SystemPaths.trueBinary.path,
            arguments: []
        )
        #expect(await CustomAgentAdapterFactories.shared.makeAdapter(for: acp) != nil)
        #expect(await CustomAgentAdapterFactories.shared.makeAdapter(for: stdio) == nil)
        await CustomAgentAdapterFactories.shared.resetForTests()
    }

    @Test("decode initialize authMethods queues authenticate")
    func initializeAuthMethodsQueuesAuthenticate() async throws {
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let state = ACPClientState()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = ACPInputEncoding.bootstrap(
            context: context,
            state: state,
            customAgentID: "x",
            displayName: "Test Agent"
        )
        let id = JSONValue.number(1)
        let decoder = ACPEventDecoder(
            state: state,
            sessionIndex: ACPSessionIndex(
                environment: FakeEnvironment(),
                fileSystem: fs,
                clock: clock
            ),
            fileAccess: ACPFileAccess(
                workspace: TestPaths.underTemporary("acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: TestPaths.underTemporary("acp-ws"),
                random: SystemRandomSource()
            ),
            clock: clock,
            random: SystemRandomSource()
        )
        let batch = await decoder.decode(.response(
            id: id,
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([:]),
                "authMethods": .array([
                    .object(["id": .string("token"), "name": .string("Token")]),
                ]),
            ]),
            error: nil
        ))
        #expect(batch.events.isEmpty)
        let replyText = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(replyText.contains("\"method\":\"authenticate\""))
        #expect(replyText.contains("\"methodId\":\"token\""))
        #expect(!replyText.contains("session/new"))
    }

    @Test("authenticate error emits authenticationRequired")
    func authenticateErrorEmitsAuthenticationRequired() async throws {
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let state = ACPClientState()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = ACPInputEncoding.bootstrap(
            context: context,
            state: state,
            customAgentID: "x",
            displayName: "Test Agent"
        )
        let decoder = ACPEventDecoder(
            state: state,
            sessionIndex: ACPSessionIndex(
                environment: FakeEnvironment(),
                fileSystem: fs,
                clock: clock
            ),
            fileAccess: ACPFileAccess(
                workspace: TestPaths.underTemporary("acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: TestPaths.underTemporary("acp-ws"),
                random: SystemRandomSource()
            ),
            clock: clock,
            random: SystemRandomSource()
        )
        _ = await decoder.decode(.response(
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
        let batch = await decoder.decode(.response(
            id: .number(2),
            result: nil,
            error: .init(code: -32_000, message: "Authentication required", data: nil)
        ))
        #expect(batch.events.contains {
            if case .error(.authenticationRequired(let id)) = $0 { return id == .other }
            return false
        })
        #expect(batch.replies.isEmpty)
    }

    @Test("initialize without authMethods queues initialized and session/new")
    func initializeProceedsWithoutAuth() async throws {
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let state = ACPClientState()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = ACPInputEncoding.bootstrap(
            context: context,
            state: state,
            customAgentID: "x",
            displayName: "Test Agent"
        )
        let decoder = ACPEventDecoder(
            state: state,
            sessionIndex: ACPSessionIndex(
                environment: FakeEnvironment(),
                fileSystem: fs,
                clock: clock
            ),
            fileAccess: ACPFileAccess(
                workspace: TestPaths.underTemporary("acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: TestPaths.underTemporary("acp-ws"),
                random: SystemRandomSource()
            ),
            clock: clock,
            random: SystemRandomSource()
        )
        let batch = await decoder.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([:]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        #expect(batch.events.isEmpty)
        let replyText = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(replyText.contains("initialized") || replyText.contains("session/new"))
    }

    @Test("session prompt response finalizes streamed assistant text")
    func sessionPromptFinalizesAssistantText() async throws {
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let random = SystemRandomSource()
        let state = ACPClientState()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = ACPInputEncoding.bootstrap(
            context: context,
            state: state,
            customAgentID: "x",
            displayName: "Test Agent"
        )
        let decoder = ACPEventDecoder(
            state: state,
            sessionIndex: ACPSessionIndex(
                environment: FakeEnvironment(),
                fileSystem: fs,
                clock: clock
            ),
            fileAccess: ACPFileAccess(
                workspace: TestPaths.underTemporary("acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: TestPaths.underTemporary("acp-ws"),
                random: random
            ),
            clock: clock,
            random: random
        )
        let promptID = state.nextRequestID(for: .sessionPrompt)
        _ = await decoder.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("codemixer-acp-pong"),
                    ]),
                ]),
            ])
        ))
        let batch = await decoder.decode(.response(
            id: promptID,
            result: .object(["stopReason": .string("end_turn")]),
            error: nil
        ))
        #expect(batch.events.contains {
            if case .assistantText(_, _, let text, true) = $0 {
                return text == "codemixer-acp-pong"
            }
            return false
        })
        #expect(batch.events.contains {
            if case .activityStateChanged(.idle) = $0 { return true }
            return false
        })
    }

    @Test("consecutive session prompts finalize with distinct assistant ids")
    func consecutiveSessionPromptsUseDistinctAssistantIDs() async throws {
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let random = FakeRandomSource(uuids: [firstID, secondID])
        let state = ACPClientState()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = ACPInputEncoding.bootstrap(
            context: context,
            state: state,
            customAgentID: "x",
            displayName: "Test Agent"
        )
        let decoder = ACPEventDecoder(
            state: state,
            sessionIndex: ACPSessionIndex(
                environment: FakeEnvironment(),
                fileSystem: fs,
                clock: clock
            ),
            fileAccess: ACPFileAccess(
                workspace: TestPaths.underTemporary("acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: TestPaths.underTemporary("acp-ws"),
                random: random
            ),
            clock: clock,
            random: random
        )

        let firstPromptID = state.nextRequestID(for: .sessionPrompt)
        _ = await decoder.decode(agentMessageChunk("first response"))
        let firstFinal = await decoder.decode(.response(
            id: firstPromptID,
            result: .object(["stopReason": .string("end_turn")]),
            error: nil
        ))

        let secondPromptID = state.nextRequestID(for: .sessionPrompt)
        _ = await decoder.decode(agentMessageChunk("second response"))
        let secondFinal = await decoder.decode(.response(
            id: secondPromptID,
            result: .object(["stopReason": .string("end_turn")]),
            error: nil
        ))

        let firstAssistant = finalizedAssistant(in: firstFinal.events)
        let secondAssistant = finalizedAssistant(in: secondFinal.events)
        #expect(firstAssistant?.id == firstID.uuidString)
        #expect(firstAssistant?.text == "first response")
        #expect(secondAssistant?.id == secondID.uuidString)
        #expect(secondAssistant?.text == "second response")
    }

    @Test("consecutive session prompts allocate distinct thinking block ids")
    func consecutiveSessionPromptsUseDistinctThinkingIDs() async throws {
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let random = FakeRandomSource(uuids: [firstID, secondID])
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(
                workspace: TestPaths.underTemporary("acp-ws"),
                permissionMode: .default
            ),
            state: state,
            customAgentID: "x",
            displayName: "Test Agent"
        )
        let decoder = ACPEventDecoder(
            state: state,
            sessionIndex: ACPSessionIndex(
                environment: FakeEnvironment(),
                fileSystem: fs,
                clock: clock
            ),
            fileAccess: ACPFileAccess(
                workspace: TestPaths.underTemporary("acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: TestPaths.underTemporary("acp-ws"),
                random: random
            ),
            clock: clock,
            random: random
        )

        let firstPromptID = state.nextRequestID(for: .sessionPrompt)
        let firstThought = await decoder.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("think-1")]),
                ]),
            ])
        ))
        _ = await decoder.decode(.response(
            id: firstPromptID,
            result: .object(["stopReason": .string("end_turn")]),
            error: nil
        ))

        let secondPromptID = state.nextRequestID(for: .sessionPrompt)
        let secondThought = await decoder.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("think-2")]),
                ]),
            ])
        ))
        _ = await decoder.decode(.response(
            id: secondPromptID,
            result: .object(["stopReason": .string("end_turn")]),
            error: nil
        ))

        let firstBlock = thinkingBlockID(in: firstThought.events)
        let secondBlock = thinkingBlockID(in: secondThought.events)
        #expect(firstBlock == firstID)
        #expect(secondBlock == secondID)
    }

    @Test("fs read rejects paths outside workspace")
    func fsSandbox() async {
        let fs = InMemoryFileSystem()
        let access = ACPFileAccess(
            workspace: TestPaths.underTemporary("acp-ws"),
            fileSystem: fs
        )
        let batch = await access.read(
            id: .number(9),
            params: .object(["path": .string("/etc/passwd")])
        )
        let text = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(text.contains("path-outside-workspace") || text.contains("error"))
    }

    @Test("session index records and lists summaries")
    func sessionIndex() async {
        let env = FakeEnvironment()
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let index = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        let workspace = TestPaths.underTemporary("acp-ws")
        await index.recordSession(
            id: "s1",
            customAgentID: "gemini",
            workspace: workspace,
            title: "Hello"
        )
        let summaries = await index.summaries(workspace: workspace, customAgentID: "gemini")
        #expect(summaries.count == 1)
        #expect(summaries.first?.id == "s1")
        #expect(summaries.first?.title == "Hello")

        await index.appendConversationTurn(
            sessionID: "s1",
            customAgentID: "gemini",
            role: "user",
            text: "hi"
        )
        await index.appendConversationTurn(
            sessionID: "s1",
            customAgentID: "gemini",
            role: "thinking",
            text: "hmm"
        )
        await index.appendToolTurn(
            sessionID: "s1",
            customAgentID: "gemini",
            toolCallID: "t-1",
            name: "Read",
            success: true,
            outputSummary: "ok",
            inputJSON: #"{"path":"a.swift"}"#
        )
        await index.appendConversationTurn(
            sessionID: "s1",
            customAgentID: "gemini",
            role: "assistant",
            text: "hello"
        )
        let replay = await index.localHistoryEvents(
            sessionID: "s1",
            customAgentID: "gemini",
            random: FakeRandomSource()
        )
        #expect(replay.contains {
            if case .thinkingChunk(_, let delta) = $0 { return delta == "hmm" }
            return false
        })
        #expect(replay.contains {
            if case .thinkingComplete = $0 { return true }
            return false
        })
        #expect(replay.contains {
            if case .toolStart(let id, let name, _, _) = $0 {
                return id == "t-1" && name == "Read"
            }
            return false
        })
        #expect(replay.contains {
            if case .toolEnd(let id, true, let output, _) = $0 {
                return id == "t-1" && output.summary == "ok"
            }
            return false
        })
        let after = await index.summaries(workspace: workspace, customAgentID: "gemini")
        #expect(after.first?.messageCount == 2)
    }

    @Test("permission mapping prefers reject_always for deny when available")
    func permissionMappingDeny() {
        let options = [
            "reject_once": "r1",
            "reject_always": "r2",
        ]
        #expect(ACPPermissionMapping.optionID(for: .deny, options: options) == "r1")
    }

    @Test("encodeCommand runCustomCommand encodes prompt text after twin bootstrap")
    func encodeCustomCommand() {
        let twin = ACPTwin()
        _ = twin.sessionBootstrapBytes(context: LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        ))
        let text = String(decoding: twin.encodeUserPrompt("/review src"), as: UTF8.self)
        #expect(text.contains("/review"))
        #expect(text.contains("session/prompt"))
    }

    @Test("LiveAgentTransportFactory accepts agentClientProtocol")
    func transportFactory() async throws {
        #expect(AgentTransportDescriptor.agentClientProtocol.kind == .agentClientProtocol)
        let launch = AgentTransportLaunchSpec(
            executable: SystemPaths.trueBinary,
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: TestPaths.temporaryRoot
        )
        let transport = try LiveAgentTransportFactory.make(
            descriptor: .agentClientProtocol,
            launch: launch
        )
        #expect(transport.terminalSnapshot == nil)
        await transport.close()
    }

    @Test("locateBinary throws binaryNotFound when executable is missing")
    func locateBinaryMissing() async {
        let adapter = acpAdapter(executablePath: "/tmp/missing-acp-agent")
        do {
            _ = try await adapter.locateBinary(
                env: ResolvedEnvironment(variables: [:], shell: SystemPaths.zsh)
            )
            Issue.record("expected binaryNotFound")
        } catch let error as AgentError {
            if case .binaryNotFound(let agentID, _) = error {
                #expect(agentID == .other)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("defaultEnvOverrides disables color output")
    func defaultEnvOverrides() {
        let adapter = makeAdapter()
        #expect(adapter.defaultEnvOverrides()["NO_COLOR"] == "1")
    }

    @Test("encodeCommand newSession emits session/new")
    func encodeNewSession() {
        let adapter = makeAdapter()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = adapter.sessionBootstrapBytes(context: context)
        let text = String(decoding: adapter.encodeCommand(.newSession)!, as: UTF8.self)
        #expect(text.contains("\"method\":\"session/new\""))
    }

    @Test("encodeCommand selectModel emits session/set_model")
    func encodeSelectModel() {
        let state = ACPClientState()
        let workspace = TestPaths.underTemporary("acp-ws")
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(workspace: workspace, permissionMode: .default),
            state: state,
            customAgentID: "cursor",
            displayName: "Cursor"
        )
        state.setSessionID("sess-1")
        let text = String(decoding: ACPInputEncoding.setModel(modelID: "gpt-5.4", state: state)!, as: UTF8.self)
        #expect(text.contains("\"method\":\"session/set_model\""))
        #expect(text.contains("\"modelId\":\"gpt-5.4\""))
    }

    @Test("buildLaunchArgv prefixes executable name and appends configured args")
    func buildLaunchArgv() {
        let adapter = ACPAdapter(ref: CustomAgentRef(
            id: "cursor",
            displayName: "Cursor",
            transport: .agentClientProtocol,
            executablePath: TestPaths.fakeHome.appendingPathComponent(".local/bin/cursor-agent").path,
            arguments: ["acp"]
        ))
        let argv = adapter.buildLaunchArgv(context: LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        ))
        #expect(argv == ["cursor-agent", "acp"])
    }

    @Test("encodeCommand runSlashCommand queues prompt before session opens")
    func encodeSlashCommand() {
        let adapter = makeAdapter()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = adapter.sessionBootstrapBytes(context: context)
        let text = String(
            decoding: adapter.encodeCommand(.runSlashCommand(target: .builtin(name: "/help"), args: []))!,
            as: UTF8.self
        )
        #expect(text.isEmpty)
    }

    @Test("listResumableSessions is empty before any session is recorded")
    func listResumableSessionsEmpty() async {
        let adapter = makeAdapter()
        let sessions = await adapter.listResumableSessions(workspace: TestPaths.underTemporary("acp-ws"))
        #expect(sessions.isEmpty)
    }

    @Test("encodePermissionResponse maps allow decision to ACP option id")
    func encodePermissionResponse() {
        let adapter = makeAdapter()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("acp-ws"),
            permissionMode: .default
        )
        _ = adapter.sessionBootstrapBytes(context: context)
        let prompt = PermissionPrompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            toolName: "Shell",
            summary: "Run command",
            argumentsSummary: "{}",
            requestedAt: Date(timeIntervalSince1970: 0)
        )
        // Without a registered approval, adapter returns empty write.
        if case .writePTY(let data) = adapter.encodePermissionResponse(.allow, for: prompt) {
            #expect(data.isEmpty)
        } else {
            Issue.record("expected writePTY delivery")
        }
    }

    private func agentMessageChunk(_ text: String) -> ACPIncoming {
        .notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ])
        )
    }

    private func finalizedAssistant(in events: [AgentEvent]) -> (id: String, text: String)? {
        for event in events {
            if case .assistantText(let id, _, let text, true) = event {
                return (id, text)
            }
        }
        return nil
    }

    private func thinkingBlockID(in events: [AgentEvent]) -> UUID? {
        for event in events {
            if case .thinkingChunk(let id, _) = event {
                return id
            }
        }
        return nil
    }

    private func makeAdapter() -> ACPAdapter {
        ACPAdapter(ref: CustomAgentRef(
            id: "test",
            displayName: "Test ACP",
            transport: .agentClientProtocol,
            executablePath: SystemPaths.trueBinary.path,
            arguments: ["--acp"]
        ))
    }
}

private struct TestACPAdapterFactory: CustomAgentAdapterFactory {
    func makeAdapter(for ref: CustomAgentRef) -> (any AgentAdapter)? {
        guard ref.transport.kind == .agentClientProtocol else { return nil }
        return ACPAdapter(ref: ref)
    }
}
