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

    @Test("reactivating an already-bound pooled session restores durable local history")
    func reactivatingSameSessionRestoresLocalHistory() async throws {
        let clock = FakeClock()
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-replay-a-\(UUID().uuidString)", isDirectory: true)
        let b = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-replay-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let t1 = ScriptedTransport()
        let t2 = ScriptedTransport()
        let factory = ScriptedTransportFactory([t1, t2])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: a)
        let seams = Seams.fake(environment: env, fileSystem: fs).with(clock: clock)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let adapterA = RecordingMockAdapter()
        try await engine.start(adapter: adapterA, workspace: a, resumeSessionID: "s-a")
        let keyA = AgentRuntimeKey(projectPath: a.path, agentID: adapterA.id)
        let phase = SessionPhase(id: "review",
                                 label: "Review",
                                 ordinal: 2,
                                 group: .review)
        await engine.ingest(.sessionPhaseChanged(sessionID: "s-a", phase: phase),
                            from: keyA)
        await engine.ingest(.userTurn(id: AdapterTurnID(rawValue: "u-a"), text: "restore me"), from: keyA)
        let thinkingID = UUID()
        await engine.ingest(.thinkingChunk(blockID: thinkingID, delta: "I need to inspect files."),
                            from: keyA)
        await engine.ingest(.thinkingComplete(blockID: thinkingID,
                                              duration: .seconds(1)),
                            from: keyA)
        await engine.ingest(.toolStart(id: "tool-a",
                                       name: "Bash",
                                       input: ToolInput(summary: "Run: pwd"),
                                       startedAt: clock.now()),
                            from: keyA)
        await engine.ingest(.toolProgress(callID: "tool-a",
                                          progress: .generic(message: "checking files")),
                            from: keyA)
        await engine.ingest(.toolEnd(id: "tool-a",
                                     success: true,
                                     output: ToolOutput(summary: "/tmp/ws"),
                                     durationMS: 12),
                            from: keyA)
        await engine.ingest(.assistantText(id: "m-a",
                                           blockID: "b-a",
                                           text: "history reply",
                                           isFinal: true),
                            from: keyA)

        try await engine.start(adapter: RecordingMockAdapter(), workspace: b, resumeSessionID: "s-b")
        let beforeReactivate = await engine.bus.historySnapshot.count

        let activated = await engine.activate(key: keyA, resumeSessionID: "s-a")
        #expect(activated)
        #expect(factory.spawnCount == 2)
        #expect(await t1.isClosed() == false)

        let replayed = await engine.bus.historySnapshot.dropFirst(beforeReactivate).map(\.event)
        #expect(replayed.contains {
            if case .userTurn(_, let text) = $0 { return text == "restore me" }
            return false
        })
        #expect(replayed.contains {
            if case .sessionPhaseChanged(let id, let replayedPhase) = $0 {
                return id == "s-a" && replayedPhase == phase
            }
            return false
        })
        #expect(replayed.contains {
            if case .thinkingChunk(let id, let text) = $0 {
                return id == thinkingID && text == "I need to inspect files."
            }
            return false
        })
        #expect(replayed.contains {
            if case .thinkingComplete(let id, let duration) = $0 {
                return id == thinkingID && duration == .seconds(1)
            }
            return false
        })
        #expect(!replayed.contains { if case .textDelta = $0 { return true }; return false })
        #expect(replayed.contains {
            if case .toolStart("tool-a", "Bash", let input, _) = $0 {
                return input.summary == "Run: pwd"
            }
            return false
        })
        // Progress folds onto the call it names, so it survives replay. Before
        // `ToolCallID`, `callID` was a `UUID` while `toolStart(id:)` was a
        // `String`, so a vendor id like "tool-a" could never be matched and
        // progress was silently dropped.
        #expect(replayed.contains {
            if case .toolProgress("tool-a", .generic(let message)) = $0 {
                return message == "checking files"
            }
            return false
        })
        #expect(replayed.contains {
            if case .toolEnd("tool-a", true, let output, 12) = $0 {
                return output.summary == "/tmp/ws"
            }
            return false
        })
        #expect(replayed.contains {
            if case .assistantText(_, _, let text, let isFinal) = $0 {
                return text == "history reply" && isFinal
            }
            return false
        })

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("engine-sent prompts persist for pooled session restoration")
    func optimisticPromptEchoPersistsForRestoration() async throws {
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-prompt-a-\(UUID().uuidString)", isDirectory: true)
        let b = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-prompt-b-\(UUID().uuidString)", isDirectory: true)
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

        let adapterA = RecordingMockAdapter()
        try await engine.start(adapter: adapterA, workspace: a, resumeSessionID: "s-a")
        let keyA = AgentRuntimeKey(projectPath: a.path, agentID: adapterA.id)
        await engine.ingest(.sessionStarted(sessionID: "s-a", model: nil, cwd: a),
                            from: keyA)
        try await engine.send(.sendPrompt(text: "show current files", attachments: []))

        let adapterB = RecordingMockAdapter()
        try await engine.start(adapter: adapterB, workspace: b, resumeSessionID: "s-b")
        let beforeReactivate = await engine.bus.historySnapshot.count

        let activated = await engine.activate(key: keyA, resumeSessionID: "s-a")
        #expect(activated)
        #expect(await t1.writtenTexts().contains { $0.contains("show current files") })

        let replayed = await engine.bus.historySnapshot.dropFirst(beforeReactivate).map(\.event)
        #expect(replayed.contains {
            if case .userTurn(_, let text) = $0 {
                return text == "show current files"
            }
            return false
        })

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

    @Test("claude session switch resumes in-process without a new PTY")
    func claudeSessionSwitchResumesInProcess() async throws {
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
        #expect(factory.spawnCount == 1)
        #expect(await engine.liveProjectPaths().count == 1)
        let writes = await transport.writtenTexts()
        #expect(writes.contains { $0.contains("/resume s2") })

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("claude new chat reuses the live PTY via /clear")
    func claudeNewChatReusesLiveProcess() async throws {
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

    @Test("same-session activate does not request vendor replay")
    func sameSessionActivationSkipsVendorReplay() async throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-same-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transport = ScriptedTransport()
        let factory = ScriptedTransportFactory([transport])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: project)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let adapter = WarmHandshakeAdapter()
        try await engine.start(adapter: adapter, workspace: project, resumeSessionID: "thread-1")
        let key = AgentRuntimeKey(projectPath: project.path, agentID: adapter.id)

        let ok = await engine.activate(key: key, resumeSessionID: "thread-1")
        #expect(ok)
        #expect(adapter.resumeCalls.isEmpty)
        #expect(!(await transport.writtenTexts().contains("session/load:thread-1")))
        #expect(factory.spawnCount == 1)

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("openProject same-session resume stays on the live pool slot")
    func openProjectSameSessionResumeIsPoolOnly() async throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-same-open-\(UUID().uuidString)", isDirectory: true)
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
        _ = try await store.addExistingProject(url: project, projectType: .cursorCLI, in: root)
        let adapter = WarmHandshakeAdapter()
        await AdapterRegistry.shared.register(adapter)

        try await engine.send(.openProject(path: project.path, resumeSessionID: "sess-1"))
        #expect(factory.spawnCount == 1)
        try await engine.send(.openProject(path: project.path, resumeSessionID: "sess-1"))
        #expect(factory.spawnCount == 1)
        #expect(adapter.resumeCalls.isEmpty)

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("openProject resumes a parked project without respawn")
    func openProjectResumeOnParkedSlot() async throws {
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-park-a-\(UUID().uuidString)", isDirectory: true)
        let b = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-park-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let tA = ScriptedTransport()
        let factory = ScriptedTransportFactory([tA, ScriptedTransport(), ScriptedTransport()])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: a)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let root = a.deletingLastPathComponent()
        _ = try await store.addExistingProject(url: a, projectType: .cursorCLI, in: root)
        _ = try await store.addExistingProject(url: b, projectType: .cursorCLI, in: root)
        await AdapterRegistry.shared.register(id: .cursorCLI) { WarmHandshakeAdapter() }

        try await engine.send(.openProject(path: a.path, resumeSessionID: "a-1"))
        try await engine.send(.openProject(path: b.path, resumeSessionID: "b-1"))
        #expect(factory.spawnCount == 2)
        #expect(await engine.liveProjectPaths().count == 2)

        try await engine.send(.openProject(path: a.path, resumeSessionID: "a-2"))
        #expect(factory.spawnCount == 2)
        let writes = await tA.writtenTexts()
        #expect(writes.contains { $0.contains("session/load:a-2") })

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("openProject Cursor new chat reuses the ACP process")
    func openProjectCursorNewChatIsWarm() async throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-cursor-new-\(UUID().uuidString)", isDirectory: true)
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
        _ = try await store.addExistingProject(url: project, projectType: .cursorCLI, in: root)
        await AdapterRegistry.shared.register(id: .cursorCLI) { WarmHandshakeAdapter() }

        try await engine.send(.openProject(path: project.path, resumeSessionID: nil))
        #expect(factory.spawnCount == 1)
        try await engine.send(.openProject(path: project.path, resumeSessionID: nil))
        #expect(factory.spawnCount == 1)
        let writes = await transport.writtenTexts()
        #expect(writes.contains { $0.contains("session/new") })

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("openProject park return without resume id does not respawn")
    func openProjectParkReturnWithoutResume() async throws {
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-return-a-\(UUID().uuidString)", isDirectory: true)
        let b = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pool-return-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let factory = ScriptedTransportFactory([ScriptedTransport(), ScriptedTransport(), ScriptedTransport()])
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: a)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let root = a.deletingLastPathComponent()
        _ = try await store.addExistingProject(url: a, projectType: .claudeCode, in: root)
        _ = try await store.addExistingProject(url: b, projectType: .claudeCode, in: root)
        await AdapterRegistry.shared.register(id: .claudeCode) { ClaudePoolWarmAdapter() }

        try await engine.send(.openProject(path: a.path, resumeSessionID: nil))
        try await engine.send(.openProject(path: b.path, resumeSessionID: nil))
        #expect(factory.spawnCount == 2)
        try await engine.send(.openProject(path: a.path, resumeSessionID: nil))
        #expect(factory.spawnCount == 2)

        await engine.shutdown(reason: .naturalExit)
    }
}

/// Claude-shaped adapter for fresh-process pool tests.
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
    func resumeArgvAddition(sessionID: String) -> [String] { ["--resume", sessionID] }
}
