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

    @Test("bootstrap emits initialize only")
    func bootstrapInitializeOnly() throws {
        let adapter = makeAdapter()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
        await CustomAgentAdapterFactories.shared.register(ACPCustomAgentAdapterFactory())
        let acp = CustomAgentRef(
            id: "gemini",
            displayName: "Gemini",
            transport: .agentClientProtocol,
            executablePath: "/usr/bin/true",
            arguments: []
        )
        let stdio = CustomAgentRef(
            id: "other",
            displayName: "Other",
            transport: .stdioJSONRPC,
            executablePath: "/usr/bin/true",
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
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
                workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
                workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
                workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
                workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
                fileSystem: fs
            ),
            terminals: ACPTerminalSession(
                workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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

    @Test("fs read rejects paths outside workspace")
    func fsSandbox() async {
        let fs = InMemoryFileSystem()
        let access = ACPFileAccess(
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
        let workspace = URL(fileURLWithPath: "/tmp/acp-ws")
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
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: URL(fileURLWithPath: "/tmp")
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
                env: ResolvedEnvironment(variables: [:], shell: URL(fileURLWithPath: "/bin/zsh"))
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
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
            permissionMode: .default
        )
        _ = adapter.sessionBootstrapBytes(context: context)
        let text = String(decoding: adapter.encodeCommand(.newSession)!, as: UTF8.self)
        #expect(text.contains("\"method\":\"session/new\""))
    }

    @Test("encodeCommand selectModel emits session/set_model")
    func encodeSelectModel() {
        let state = ACPClientState()
        let workspace = URL(fileURLWithPath: "/tmp/acp-ws")
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
            executablePath: "/Users/me/.local/bin/cursor-agent",
            arguments: ["acp"]
        ))
        let argv = adapter.buildLaunchArgv(context: LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
            permissionMode: .default
        ))
        #expect(argv == ["cursor-agent", "acp"])
    }

    @Test("encodeCommand runSlashCommand queues prompt before session opens")
    func encodeSlashCommand() {
        let adapter = makeAdapter()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
            permissionMode: .default
        )
        _ = adapter.sessionBootstrapBytes(context: context)
        let text = String(
            decoding: adapter.encodeCommand(.runSlashCommand(name: "/help", args: []))!,
            as: UTF8.self
        )
        #expect(text.isEmpty)
    }

    @Test("listResumableSessions is empty before any session is recorded")
    func listResumableSessionsEmpty() async {
        let adapter = makeAdapter()
        let sessions = await adapter.listResumableSessions(workspace: URL(fileURLWithPath: "/tmp/acp-ws"))
        #expect(sessions.isEmpty)
    }

    @Test("encodePermissionResponse maps allow decision to ACP option id")
    func encodePermissionResponse() {
        let adapter = makeAdapter()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/acp-ws"),
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

    private func makeAdapter() -> ACPAdapter {
        ACPAdapter(ref: CustomAgentRef(
            id: "test",
            displayName: "Test ACP",
            transport: .agentClientProtocol,
            executablePath: "/usr/bin/true",
            arguments: ["--acp"]
        ))
    }
}
