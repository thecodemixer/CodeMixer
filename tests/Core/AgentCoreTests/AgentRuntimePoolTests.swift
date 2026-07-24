import Foundation
import Testing
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("AgentEngine — sticky runtime pool")
struct AgentRuntimePoolTests {

    @Test("cross-project round trip reuses the first project transport")
    func crossProjectRoundTripReusesTransport() async throws {
        let clock = FakeClock()
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-a-\(UUID().uuidString)", isDirectory: true)
        let b = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let t1 = ScriptedTransport()
        let t2 = ScriptedTransport()
        let t3 = ScriptedTransport()
        let factory = ScriptedTransportFactory([t1, t2, t3])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: a)
        let seams = Seams.fake(environment: env, fileSystem: fs).with(clock: clock)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let adapterA = RecordingMockAdapter()
        try await engine.start(adapter: adapterA, workspace: a, resumeSessionID: "s-a")
        #expect(factory.spawnCount == 1)

        let adapterB = RecordingMockAdapter()
        try await engine.start(adapter: adapterB, workspace: b, resumeSessionID: "s-b")
        #expect(factory.spawnCount == 2)
        #expect(await engine.liveProjectPaths().count == 2)

        let activated = await engine.activate(
            key: AgentRuntimeKey(projectPath: a.path, agentID: adapterA.id),
            resumeSessionID: "s-a"
        )
        #expect(activated)
        #expect(factory.spawnCount == 2)
        #expect(await t1.isClosed() == false)

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("closeSession kills only the active slot")
    func closeSessionKeepsSibling() async throws {
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-close-a-\(UUID().uuidString)", isDirectory: true)
        let b = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-close-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let t1 = ScriptedTransport()
        let t2 = ScriptedTransport()
        let factory = ScriptedTransportFactory([t1, t2])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: a)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        try await engine.start(adapter: RecordingMockAdapter(), workspace: a, resumeSessionID: "a")
        try await engine.start(adapter: RecordingMockAdapter(), workspace: b, resumeSessionID: "b")
        try await engine.send(.closeSession)
        #expect(await engine.liveProjectPaths().count == 1)
        let c1 = await t1.isClosed()
        let c2 = await t2.isClosed()
        #expect((c1 && c2) == false)

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("parked assistant deltas do not append to active transcript")
    func parkedEventsDoNotPolluteTranscript() async throws {
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-demux-a-\(UUID().uuidString)", isDirectory: true)
        let b = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-demux-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let factory = ScriptedTransportFactory([ScriptedTransport(), ScriptedTransport()])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: a)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let adapterA = RecordingMockAdapter()
        try await engine.start(adapter: adapterA, workspace: a)
        let keyA = AgentRuntimeKey(projectPath: a.path, agentID: adapterA.id)

        try await engine.start(adapter: RecordingMockAdapter(), workspace: b)

        await engine.ingest(
            .assistantText(id: "x", blockID: "b", text: "parked", isFinal: true),
            from: keyA
        )
        let snap = await engine.transcript
        #expect(!snap.contains(where: { $0.text == "parked" }))

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("claude session switch reuses the single project PTY")
    func claudeSessionSwitchReusesProcess() async throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transport = ScriptedTransport()
        let factory = ScriptedTransportFactory([transport, ScriptedTransport()])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: project)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let root = project.deletingLastPathComponent()
        _ = try await store.addExistingProject(url: project, projectType: .claudeCode, in: root)
        await AdapterRegistry.shared.register(id: .claudeCode) { ClaudePoolWarmAdapter() }

        try await engine.send(.openProject(path: project.path, resumeSessionID: "s1"))
        #expect(factory.spawnCount == 1)
        try await engine.send(.openProject(path: project.path, resumeSessionID: "s2"))
        #expect(factory.spawnCount == 1, "Claude session switch must reuse the parked PTY")
        #expect(await engine.liveProjectPaths().count == 1)
        let writes = await transport.writtenTexts()
        #expect(writes.contains { $0.contains("/resume s2") })

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("claude new chat reuses the project PTY and writes /clear")
    func claudeNewChatReusesProcess() async throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-claude-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transport = ScriptedTransport()
        let factory = ScriptedTransportFactory([transport, ScriptedTransport()])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: project)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let root = project.deletingLastPathComponent()
        _ = try await store.addExistingProject(url: project, projectType: .claudeCode, in: root)
        await AdapterRegistry.shared.register(id: .claudeCode) { ClaudePoolWarmAdapter() }

        try await engine.send(.openProject(path: project.path, resumeSessionID: "s1"))
        #expect(factory.spawnCount == 1)
        try await engine.send(.openProject(path: project.path, resumeSessionID: nil))
        #expect(factory.spawnCount == 1)
        let writes = await transport.writtenTexts()
        #expect(writes.contains { $0.contains("/clear") })

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("preferFresh replaces the project slot on every open")
    func preferFreshRespawns() async throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let factory = ScriptedTransportFactory([ScriptedTransport(), ScriptedTransport(), ScriptedTransport()])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: project)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let root = project.deletingLastPathComponent()
        _ = try await store.addExistingProject(
            url: project,
            projectType: .claudeCode,
            preferFreshAgentProcess: true,
            in: root
        )
        await AdapterRegistry.shared.register(id: .claudeCode) { RecordingMockAdapter() }

        try await engine.send(.openProject(path: project.path, resumeSessionID: "a"))
        try await engine.send(.openProject(path: project.path, resumeSessionID: "a"))
        #expect(factory.spawnCount == 2)

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("liveProjectPaths shrinks after closeSession")
    func livePathsShrinkOnClose() async throws {
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-paths-a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let factory = ScriptedTransportFactory([ScriptedTransport()])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: a)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()
        try await engine.start(adapter: RecordingMockAdapter(), workspace: a)
        #expect(await engine.liveProjectPaths().contains(a.standardizedFileURL.path))
        try await engine.send(.closeSession)
        #expect(await engine.liveProjectPaths().isEmpty)

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("codex encodeResumeSession writes thread/resume on activate")
    func codexWarmResumeOnActivate() async throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transport = ScriptedTransport()
        let factory = ScriptedTransportFactory([transport])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: project)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let adapter = WarmHandshakeAdapter() // records resume calls; treat as pool activate path
        try await engine.start(adapter: adapter, workspace: project, resumeSessionID: "thread-1")
        let key = AgentRuntimeKey(projectPath: project.path, agentID: adapter.id)
        let ok = await engine.activate(key: key, resumeSessionID: "thread-2")
        #expect(ok)
        #expect(adapter.resumeCalls.contains("thread-2"))
        #expect(factory.spawnCount == 1)

        await engine.shutdown(reason: .naturalExit)
    }
}

/// Claude-shaped adapter for pool tests: interactive terminal + `/resume` / `/clear`.
final class ClaudePoolWarmAdapter: AgentAdapter, @unchecked Sendable {
    let id: AgentID = .claudeCode
    let displayName = "Claude Pool Warm"
    let iconSymbol = "sparkles"
    let capabilities: AgentCapabilities = [.resumableSessions]
    let transportDescriptor: AgentTransportDescriptor = .interactiveTerminal
    let slashCommandCatalog: [SlashCommand] = []

    func locateBinary(env: ResolvedEnvironment) async throws -> URL { SystemPaths.cat }
    func defaultEnvOverrides() -> [String: String] { [:] }
    func buildLaunchArgv(context: LaunchContext) -> [String] { ["cat"] }
    func authStatus(env: ResolvedEnvironment) async -> AuthStatus { .authenticated(account: nil) }
    func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
    func encodeUserPrompt(_ text: String) -> Data { Data((text.hasSuffix("\n") ? text : text + "\n").utf8) }
    func cancelSequence() -> Data { Data() }
    func encodeResumeSession(sessionID: String) -> Data? {
        Data("/resume \(sessionID)\n".utf8)
    }
    func encodePermissionResponse(_ decision: PermissionDecision,
                                  for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        .writePTY(Data())
    }
    func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }
    func listResumableSessions(workspace: URL) async -> [SessionSummary] { [] }
    func resumeArgvAddition(sessionID: String) -> [String] { ["--resume", sessionID] }
}
