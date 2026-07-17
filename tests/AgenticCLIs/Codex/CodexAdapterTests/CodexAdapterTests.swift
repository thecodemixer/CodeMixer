import Foundation
import Testing

import AgentCore
import AgentTestSupport
import Codex

@Suite("Codex adapter protocol contract")
struct CodexAdapterTests {
    @Test("Launch argv always selects app-server stdio")
    func launchArgv() {
        let adapter = CodexAdapter()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/project"),
            resumeSessionID: "thread-resume"
        )

        #expect(adapter.buildLaunchArgv(context: context) == [
            "codex", "app-server", "--stdio",
        ])
        #expect(adapter.resumeArgvAddition(sessionID: "thread-resume").isEmpty)
        #expect(adapter.transportDescriptor == .stdioJSONRPC)
    }

    @Test("Bootstrap initializes then starts one fresh thread")
    func bootstrapFreshThread() throws {
        let adapter = CodexAdapter()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/project"),
            permissionMode: .acceptEdits
        )
        var framing = CodexAppServerFraming()

        let frames = try framing.append(adapter.sessionBootstrapBytes(context: context))
        let objects = try frames.map {
            try JSONDecoder().decode(JSONValue.self, from: $0)
        }

        #expect(objects.count == 3)
        #expect(objects[0]["method"]?.stringValue == "initialize")
        #expect(objects[0]["params"]?["clientInfo"]?["name"]?.stringValue == "codemixer")
        #expect(objects[1]["method"]?.stringValue == "initialized")
        #expect(objects[1]["params"] == nil)
        #expect(objects[2]["method"]?.stringValue == "thread/start")
        #expect(objects[2]["params"]?["sandbox"]?.stringValue == "workspace-write")
        #expect(objects[2]["params"]?["permissions"] == nil)
    }

    @Test("Bootstrap resumes in protocol and never in argv")
    func bootstrapResume() throws {
        let adapter = CodexAdapter()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/project"),
            resumeSessionID: "thr_123"
        )
        var framing = CodexAppServerFraming()

        let frames = try framing.append(adapter.sessionBootstrapBytes(context: context))
        let resume = try JSONDecoder().decode(JSONValue.self, from: frames[2])

        #expect(resume["method"]?.stringValue == "thread/resume")
        #expect(resume["params"]?["threadId"]?.stringValue == "thr_123")
        #expect(!adapter.buildLaunchArgv(context: context).contains("thr_123"))
    }

    @Test("Thread resume replays reconstructed turn history into Codemixer events")
    func threadResumeReplaysHistory() async throws {
        let adapter = CodexAdapter(
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem(),
            clock: FakeClock(),
            random: FakeRandomSource()
        )
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/project"),
            resumeSessionID: "thread-1"
        )
        _ = adapter.sessionBootstrapBytes(context: context)
        var outputContinuation: AsyncStream<Data>.Continuation!
        let output = AsyncStream<Data> { outputContinuation = $0 }
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: output,
            writeBytes: { _ in },
            terminal: nil,
            hookSocket: nil,
            workspace: context.workspace,
            sessionID: AsyncStream { $0.finish() }
        ))
        var iterator = stream.makeAsyncIterator()

        outputContinuation.yield(Self.frame(
            #"{"id":2,"result":{"thread":{"id":"thread-1","turns":[{"id":"turn-1","items":[{"type":"userMessage","id":"u1","content":[{"type":"text","text":"hello"}]},{"type":"agentMessage","id":"a1","text":"hi there"}]}]}}}"#
        ))

        guard case .sessionStarted(let id, _, _) = await iterator.next() else {
            Issue.record("Expected sessionStarted")
            return
        }
        #expect(id == "thread-1")

        guard case .userTurn(_, let userText) = await iterator.next() else {
            Issue.record("Expected userTurn")
            return
        }
        #expect(userText == "hello")

        guard case .assistantText(_, _, let assistantText, let isFinal) = await iterator.next() else {
            Issue.record("Expected assistantText")
            return
        }
        #expect(assistantText == "hi there")
        #expect(isFinal)

        outputContinuation.finish()
    }

    @Test("Binary override wins over PATH and fallback directories")
    func binaryOverridePrecedence() throws {
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: URL(fileURLWithPath: "/Users/test"))
        let override = URL(fileURLWithPath: "/custom/codex")
        try fileSystem.writeAtomically(Data(), to: override)
        try fileSystem.writeAtomically(Data(), to: URL(fileURLWithPath: "/path/codex"))
        let resolved = ResolvedEnvironment(
            variables: ["CODEX_BIN": override.path, "PATH": "/path"],
            shell: URL(fileURLWithPath: "/bin/zsh")
        )
        let locator = CodexBinaryLocator(
            environment: environment,
            fileSystem: fileSystem
        )

        #expect(try locator.locate(env: resolved) == override)
    }

    @Test("PATH wins before fallback installation directories")
    func binaryPathPrecedence() throws {
        let fileSystem = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/Users/test")
        let pathCandidate = URL(fileURLWithPath: "/path/codex")
        let fallback = home.appendingPathComponent(".local/bin/codex")
        try fileSystem.writeAtomically(Data(), to: pathCandidate)
        try fileSystem.writeAtomically(Data(), to: fallback)
        let locator = CodexBinaryLocator(
            environment: FakeEnvironment(home: home),
            fileSystem: fileSystem
        )
        let resolved = ResolvedEnvironment(
            variables: ["PATH": "/path"],
            shell: URL(fileURLWithPath: "/bin/zsh")
        )

        #expect(try locator.locate(env: resolved) == pathCandidate)
    }

    @Test("Thread result unlocks queued turns and selected model")
    func threadResultUnlocksTurn() async throws {
        let adapter = CodexAdapter(
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem(),
            clock: FakeClock(),
            random: FakeRandomSource()
        )
        let context = LaunchContext(workspace: URL(fileURLWithPath: "/tmp/project"))
        _ = adapter.sessionBootstrapBytes(context: context)
        let recorder = DataRecorder()
        var outputContinuation: AsyncStream<Data>.Continuation!
        let output = AsyncStream<Data> { outputContinuation = $0 }
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: output,
            writeBytes: { await recorder.append($0) },
            terminal: nil,
            hookSocket: nil,
            workspace: context.workspace,
            sessionID: AsyncStream { $0.finish() }
        ))
        var iterator = stream.makeAsyncIterator()

        #expect(adapter.encodeCommand(.selectModel(id: "gpt-5.4"))?.isEmpty == true)
        #expect(adapter.encodeUserPrompt("queued prompt").isEmpty)
        outputContinuation.yield(Self.frame(
            #"{"id":2,"result":{"thread":{"id":"thread-1","model":"gpt-5.4"}}}"#
        ))

        guard case .sessionStarted(let id, _, _) = await iterator.next() else {
            Issue.record("Expected sessionStarted")
            return
        }
        #expect(id == "thread-1")
        let replies = await recorder.snapshot()
        #expect(replies.count == 1)
        let turn = try Self.decodeSingleFrame(replies[0])
        #expect(turn["method"]?.stringValue == "turn/start")
        #expect(turn["params"]?["threadId"]?.stringValue == "thread-1")
        #expect(turn["params"]?["model"]?.stringValue == "gpt-5.4")
        #expect(turn["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue == "queued prompt")
        outputContinuation.finish()
    }

    @Test("Full turn lifecycle starts, interrupts, completes, and returns idle")
    func fullTurnLifecycle() async throws {
        let adapter = CodexAdapter(
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem(),
            clock: FakeClock(),
            random: FakeRandomSource()
        )
        let context = LaunchContext(workspace: URL(fileURLWithPath: "/tmp/project"))
        _ = adapter.sessionBootstrapBytes(context: context)
        let recorder = DataRecorder()
        var outputContinuation: AsyncStream<Data>.Continuation!
        let output = AsyncStream<Data> { outputContinuation = $0 }
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: output,
            writeBytes: { await recorder.append($0) },
            terminal: nil,
            hookSocket: nil,
            workspace: context.workspace,
            sessionID: AsyncStream { $0.finish() }
        ))
        var iterator = stream.makeAsyncIterator()

        #expect(adapter.encodeUserPrompt("say ok").isEmpty)
        outputContinuation.yield(Self.frame(
            #"{"id":2,"result":{"thread":{"id":"thread-1","model":"gpt-5.6-terra"}}}"#
        ))
        guard case .sessionStarted(let sessionID, let model, _) = await iterator.next() else {
            Issue.record("Expected sessionStarted")
            return
        }
        #expect(sessionID == "thread-1")
        #expect(model == "gpt-5.6-terra")

        try await Self.waitUntil { await recorder.snapshot().count == 1 }
        let startedTurn = try Self.decodeSingleFrame(await recorder.snapshot()[0])
        #expect(startedTurn["id"]?.numberValue == 3)
        #expect(startedTurn["method"]?.stringValue == "turn/start")
        #expect(startedTurn["params"]?["threadId"]?.stringValue == "thread-1")
        #expect(startedTurn["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue == "say ok")

        outputContinuation.yield(Self.frame(
            #"{"id":3,"result":{"turn":{"id":"turn-1"}}}"#
        ))
        try await Task.sleep(for: .milliseconds(20))
        let interrupt = try Self.decodeSingleFrame(adapter.cancelSequence())
        #expect(interrupt["method"]?.stringValue == "turn/interrupt")
        #expect(interrupt["params"]?["threadId"]?.stringValue == "thread-1")
        #expect(interrupt["params"]?["turnId"]?.stringValue == "turn-1")

        outputContinuation.yield(Self.frame(
            #"{"method":"item/agentMessage/delta","params":{"itemId":"msg-1","delta":"OK"}}"#
        ))
        outputContinuation.yield(Self.frame(
            #"{"method":"item/completed","params":{"item":{"id":"msg-1","type":"agentMessage","text":"OK"}}}"#
        ))
        outputContinuation.yield(Self.frame(
            #"{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}"#
        ))
        outputContinuation.finish()

        guard case .assistantText(_, _, let delta, false) = await iterator.next(),
              case .assistantText(_, _, let final, true) = await iterator.next(),
              case .activityStateChanged(.idle) = await iterator.next() else {
            Issue.record("Expected assistant delta, final text, and idle state")
            return
        }
        #expect(delta == "OK")
        #expect(final == "OK")
        #expect(adapter.cancelSequence().isEmpty)
    }

    @Test("Agent message deltas become cumulative assistant text")
    func agentMessageDeltas() async {
        let adapter = CodexAdapter(
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem(),
            clock: FakeClock(),
            random: FakeRandomSource()
        )
        var outputContinuation: AsyncStream<Data>.Continuation!
        let output = AsyncStream<Data> { outputContinuation = $0 }
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: output,
            terminal: nil,
            hookSocket: nil,
            workspace: URL(fileURLWithPath: "/tmp/project"),
            sessionID: AsyncStream { $0.finish() }
        ))
        var iterator = stream.makeAsyncIterator()

        outputContinuation.yield(Self.frame(
            #"{"method":"item/agentMessage/delta","params":{"itemId":"msg-1","delta":"Hello"}}"#
        ))
        outputContinuation.yield(Self.frame(
            #"{"method":"item/agentMessage/delta","params":{"itemId":"msg-1","delta":" world"}}"#
        ))
        outputContinuation.yield(Self.frame(
            #"{"method":"item/completed","params":{"item":{"id":"msg-1","type":"agentMessage","text":"Hello world"}}}"#
        ))
        outputContinuation.finish()

        guard case .assistantText(let firstID, _, let first, false) = await iterator.next(),
              case .assistantText(let secondID, _, let second, false) = await iterator.next(),
              case .assistantText(let finalID, _, let final, true) = await iterator.next() else {
            Issue.record("Expected cumulative assistantText events")
            return
        }
        #expect(first == "Hello")
        #expect(second == "Hello world")
        #expect(final == "Hello world")
        #expect(firstID == secondID)
        #expect(secondID == finalID)
    }

    @Test("Allow always auto-approves the matching request for this session")
    func allowAlwaysAutoApproves() async throws {
        let adapter = CodexAdapter(
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem(),
            clock: FakeClock(),
            random: FakeRandomSource()
        )
        let recorder = DataRecorder()
        var outputContinuation: AsyncStream<Data>.Continuation!
        let output = AsyncStream<Data> { outputContinuation = $0 }
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: output,
            writeBytes: { await recorder.append($0) },
            terminal: nil,
            hookSocket: nil,
            workspace: URL(fileURLWithPath: "/tmp/project"),
            sessionID: AsyncStream { $0.finish() }
        ))
        var iterator = stream.makeAsyncIterator()
        let request = #"{"id":41,"method":"item/commandExecution/requestApproval","params":{"command":"swift test","reason":"Run tests"}}"#
        outputContinuation.yield(Self.frame(request))

        guard case .permissionRequest(let prompt) = await iterator.next() else {
            Issue.record("Expected permissionRequest")
            return
        }
        guard case .writePTY(let response) = adapter.encodePermissionResponse(
            .allowAlways,
            for: prompt
        ) else {
            Issue.record("Expected JSON-RPC permission response")
            return
        }
        let allowed = try Self.decodeSingleFrame(response)
        #expect(allowed["id"]?.numberValue == 41)
        #expect(allowed["result"]?["decision"]?.stringValue == "allow")

        outputContinuation.yield(Self.frame(request.replacingOccurrences(of: "41", with: "42")))
        try await Self.waitUntil { await recorder.snapshot().count == 1 }
        let automatic = try Self.decodeSingleFrame(await recorder.snapshot()[0])
        #expect(automatic["id"]?.numberValue == 42)
        #expect(automatic["result"]?["decision"]?.stringValue == "allow")
        outputContinuation.finish()
    }

    @Test("Thread index persists Codex sessions and supersedes them")
    func threadIndexPersistence() async {
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: URL(fileURLWithPath: "/Users/test"))
        let workspace = URL(fileURLWithPath: "/tmp/project")
        let first = CodexThreadIndex(
            environment: environment,
            fileSystem: fileSystem,
            clock: FakeClock()
        )
        await first.recordThread(id: "thread-1", workspace: workspace)
        await first.recordTurn(threadID: "thread-1", title: "Implement Codex support")

        let reloaded = CodexThreadIndex(
            environment: environment,
            fileSystem: fileSystem,
            clock: FakeClock()
        )
        let summaries = await reloaded.summaries(workspace: workspace)
        #expect(summaries.count == 1)
        #expect(summaries[0].agentID == .codex)
        #expect(summaries[0].title == "Implement Codex support")
        #expect(summaries[0].messageCount == 1)

        await reloaded.supersede(threadID: "thread-1")
        #expect(await reloaded.summaries(workspace: workspace).isEmpty)
    }

    @Test("Project and user markdown commands are enumerated")
    func commandEnumeration() async throws {
        let fileSystem = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/Users/test")
        let workspace = URL(fileURLWithPath: "/tmp/project")
        try fileSystem.createDirectory(
            at: workspace.appendingPathComponent(".codex/commands"),
            withIntermediates: true
        )
        try fileSystem.createDirectory(
            at: home.appendingPathComponent(".codex/commands"),
            withIntermediates: true
        )
        try fileSystem.writeAtomically(
            Data("---\ndescription: Review local changes\n---\n".utf8),
            to: workspace.appendingPathComponent(".codex/commands/review-local.md")
        )
        try fileSystem.writeAtomically(
            Data("# Explain\n".utf8),
            to: home.appendingPathComponent(".codex/commands/explain.md")
        )
        let adapter = CodexAdapter(
            environment: FakeEnvironment(home: home),
            fileSystem: fileSystem,
            clock: FakeClock(),
            random: FakeRandomSource()
        )

        let commands = await adapter.enumerateProjectCommands(workspace: workspace)
        #expect(commands.map(\.name) == ["/review-local", "/explain"])
        #expect(commands[0].summary == "Review local changes")
        #expect(commands[0].isProjectDefined)
        #expect(!commands[1].isProjectDefined)
    }

    @Test("Tool lifecycle notifications become tool events")
    func toolLifecycle() async throws {
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment()
        let random = FakeRandomSource()
        let adapter = CodexAdapter(
            environment: environment,
            fileSystem: fileSystem,
            clock: FakeClock(),
            random: random
        )
        var outputContinuation: AsyncStream<Data>.Continuation!
        let output = AsyncStream<Data> { outputContinuation = $0 }
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: output,
            terminal: nil,
            hookSocket: nil,
            workspace: URL(fileURLWithPath: "/tmp/project"),
            sessionID: AsyncStream { $0.finish() }
        ))
        var iterator = stream.makeAsyncIterator()

        outputContinuation.yield(Self.frame(
            #"{"method":"item/started","params":{"item":{"id":"tool-1","type":"commandExecution","command":"swift test","status":"inProgress"}}}"#
        ))
        outputContinuation.yield(Self.frame(
            #"{"method":"item/completed","params":{"item":{"id":"tool-1","type":"commandExecution","command":"swift test","status":"completed","aggregatedOutput":"ok","exitCode":0,"durationMs":4}}}"#
        ))
        outputContinuation.finish()

        guard case .toolStart(let startID, let name, _, _) = await iterator.next() else {
            Issue.record("Expected toolStart")
            return
        }
        guard case .toolEnd(let endID, let success, _, _) = await iterator.next() else {
            Issue.record("Expected toolEnd")
            return
        }
        #expect(startID == "tool-1")
        #expect(name == "Bash")
        #expect(endID == "tool-1")
        #expect(success)
    }

    @Test("agent modes expose agent and review for composer")
    func agentModes() {
        let modes = CodexAdapter().availableAgentModes()
        #expect(modes.map(\.id) == ["agent", "review"])
        #expect(modes.map(\.label) == ["Agent", "Review"])
    }

    private static func frame(_ json: String) -> Data {
        CodexAppServerFraming.frame(Data(json.utf8))
    }

    private static func decodeSingleFrame(_ data: Data) throws -> JSONValue {
        var framing = CodexAppServerFraming()
        let frames = try framing.append(data)
        return try JSONDecoder().decode(JSONValue.self, from: frames[0])
    }

    private static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for asynchronous condition")
    }
}

private actor DataRecorder {
    private var values: [Data] = []

    func append(_ data: Data) {
        values.append(data)
    }

    func snapshot() -> [Data] {
        values
    }
}
