import Foundation
import Testing
@testable import AgentCore
import AgentProtocol
import AgentTestSupport
import ClaudeCode

/// One test per `AgentCommand` case (plus the permission auto-deny timeout).
/// We use `RecordingMockAdapter` to capture adapter-level effects without
/// spawning a real CLI binary. The adapter declares `/bin/cat` as the agent
/// so the PTY child stays alive while the engine writes bytes to it.
@Suite("AgentEngine — command matrix", .serialized)
struct AgentEngineCommandTests {

    // MARK: Conversation

    @Test("start strips billing-poison env before PTY spawn")
    func startStripsBillingPoisonEnv() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-billing-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let env = FakeEnvironment(
            processEnv: [
                "SHELL": "/codemixer-test/missing-shell",
                "PATH": "/usr/bin:/bin",
                "CLAUDE_CODE_ENTRYPOINT": "sdk",
                "ANTHROPIC_API_KEY": "sk-test",
            ],
            home: workspace
        )
        let capture = CapturingTransportFactory()
        let h = try await EngineHarness.make(workspace: workspace,
                                             environment: env,
                                             transportFactory: capture.makeTransport)
        guard let spec = capture.lastSpec else {
            Issue.record("expected PTY spawn spec")
            await h.shutdown()
            return
        }
        #expect(spec.environment["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(spec.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(spec.environment["PATH"] == "/usr/bin:/bin")
        await h.shutdown()
    }

    @Test("sendPrompt encodes via adapter and publishes userTurn")
    func sendPrompt() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.sendPrompt(text: "hello", attachments: []))
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.adapter.recorded.contains(.userPrompt("hello")))
        let userEvents = await h.collectedSoFar().filter {
            if case .userTurn = $0 { return true }; return false
        }
        #expect(userEvents.count >= 1)
        await h.shutdown()
    }

    @Test("sendPrompt fans the userTurn out to every subscriber (GUI + remote parity)")
    func sendPromptFansOutToAllSubscribers() async throws {
        let h = try await EngineHarness.make()
        // A second independent bus subscriber stands in for a remote
        // ClientConnection. The engine publishes `.userTurn` before the awaited
        // PTY write, so both the GUI collector and this one must see the same
        // turn — proving the reorder is transport-agnostic and reaches every
        // surface uniformly (no GUI-only fast path).
        let remoteSub = await h.engine.bus.subscribe()
        let remoteCollector = EventCollector()
        let remoteTask = Task { await remoteCollector.ingest(remoteSub.stream) }

        try await h.engine.send(.sendPrompt(text: "parity", attachments: []))
        try await Task.sleep(for: .milliseconds(40))

        func sawUserTurn(_ events: [AgentEvent]) -> Bool {
            events.contains {
                if case .userTurn(_, let text) = $0 { return text == "parity" }
                return false
            }
        }
        #expect(sawUserTurn(await h.collectedSoFar()))
        #expect(sawUserTurn(await remoteCollector.snapshot()))

        await h.engine.bus.unsubscribe(remoteSub.id)
        remoteTask.cancel()
        await h.shutdown()
    }

    @Test("openProject resolves the stored project type and switches adapters")
    func openProjectUsesStoredProjectMode() async throws {
        let capture = CapturingTransportFactory()
        let h = try await EngineHarness.make(transportFactory: capture.makeTransport)
        let codex = RoutingTestAdapter(id: .codex, descriptor: .stdioJSONRPC)
        await AdapterRegistry.shared.register(codex)

        let store = WorkspaceProjectsStore(environment: h.environment,
                                           fileSystem: h.fileSystem)
        let ref = try await store.createProject(name: "codex",
                                                projectType: .codex,
                                                in: h.workspace)

        try await h.engine.send(.openProject(path: ref.path, resumeSessionID: nil))

        #expect(capture.descriptors.last == .stdioJSONRPC)
        await h.shutdown()
    }

    @Test("openProject with working-directory override launches in the source folder")
    func openProjectUsesWorkingDirectoryOverride() async throws {
        let capture = CapturingTransportFactory()
        let h = try await EngineHarness.make(transportFactory: capture.makeTransport)
        let codex = RoutingTestAdapter(id: .codex, descriptor: .stdioJSONRPC)
        await AdapterRegistry.shared.register(codex)

        let source = h.workspace.appendingPathComponent("source-tree", isDirectory: true)
        try h.fileSystem.createDirectory(at: source, withIntermediates: true)
        let store = WorkspaceProjectsStore(environment: h.environment,
                                           fileSystem: h.fileSystem)
        let ref = try await store.createProject(
            name: "api",
            projectType: .codex,
            workingDirectory: source,
            in: h.workspace
        )
        try await h.engine.send(.openProject(path: ref.path, resumeSessionID: nil))
        try await Task.sleep(for: .milliseconds(40))

        guard let spec = capture.lastSpec else {
            Issue.record("expected launch spec after openProject")
            await h.shutdown()
            return
        }
        #expect(spec.workingDirectory?.path == source.path)
        #expect(spec.environment["PWD"] == source.path)
        // Protocol adapters put LaunchContext.workspace into `session/new` /
        // `startThread` `cwd`, so the CLI's own notion of cwd follows the override.
        #expect(codex.launchContextWorkspaces.map(\.path) == [source.path])
        let livePaths = await h.engine.liveProjectPaths()
        #expect(livePaths.contains(ref.path))
        await h.shutdown()
    }

    @Test("editing the working directory cold-starts instead of reusing the pooled agent")
    func workingDirectoryChangeDropsStalePooledRuntime() async throws {
        let capture = CapturingTransportFactory()
        let h = try await EngineHarness.make(transportFactory: capture.makeTransport)
        let codex = RoutingTestAdapter(id: .codex, descriptor: .stdioJSONRPC)
        await AdapterRegistry.shared.register(codex)

        let first = h.workspace.appendingPathComponent("source-a", isDirectory: true)
        let second = h.workspace.appendingPathComponent("source-b", isDirectory: true)
        try h.fileSystem.createDirectory(at: first, withIntermediates: true)
        try h.fileSystem.createDirectory(at: second, withIntermediates: true)
        let store = WorkspaceProjectsStore(environment: h.environment,
                                           fileSystem: h.fileSystem)
        let ref = try await store.createProject(
            name: "api",
            projectType: .codex,
            workingDirectory: first,
            in: h.workspace
        )
        try await h.engine.send(.openProject(path: ref.path, resumeSessionID: nil))
        try await Task.sleep(for: .milliseconds(40))
        #expect(capture.lastSpec?.workingDirectory?.path == first.path)

        _ = try await store.setWorkingDirectory(path: ref.path, to: second, in: h.workspace)
        try await h.engine.send(.openProject(path: ref.path, resumeSessionID: nil))
        try await Task.sleep(for: .milliseconds(40))

        // A warm New Chat on the pooled child would have kept the old cwd.
        #expect(capture.lastSpec?.workingDirectory?.path == second.path)
        #expect(capture.lastSpec?.environment["PWD"] == second.path)
        await h.shutdown()
    }

    @Test("openProject fails when the working-directory override is missing")
    func openProjectMissingWorkingDirectoryFails() async throws {
        let h = try await EngineHarness.make()
        let codex = RoutingTestAdapter(id: .codex, descriptor: .stdioJSONRPC)
        await AdapterRegistry.shared.register(codex)

        let missing = h.workspace.appendingPathComponent("missing-source", isDirectory: true)
        let store = WorkspaceProjectsStore(environment: h.environment,
                                           fileSystem: h.fileSystem)
        try h.fileSystem.createDirectory(at: missing, withIntermediates: true)
        let ref = try await store.createProject(
            name: "api",
            projectType: .codex,
            workingDirectory: missing,
            in: h.workspace
        )
        try h.fileSystem.remove(at: missing)
        await #expect(throws: AgentError.self) {
            try await h.engine.send(.openProject(path: ref.path, resumeSessionID: nil))
        }
        await h.shutdown()
    }

    @Test("openProject in mixed mode resumes with the session's agent")
    func openProjectMixedResumeUsesSessionAgent() async throws {
        let capture = CapturingTransportFactory()
        let h = try await EngineHarness.make(transportFactory: capture.makeTransport)
        let store = WorkspaceProjectsStore(environment: h.environment,
                                           fileSystem: h.fileSystem)
        let ref = try await store.createProject(name: "mixed",
                                                projectType: .mixed(defaultAgent: .claudeCode),
                                                in: h.workspace)
        let codex = RoutingTestAdapter(
            id: .codex,
            descriptor: .stdioJSONRPC
        )
        await AdapterRegistry.shared.register(codex)
        try await h.engine.transcriptRepository.registerSession(
            "thread-1",
            namespace: AgentID.codex.rawValue,
            agentID: .codex,
            in: URL(fileURLWithPath: ref.path),
            title: "Codex thread"
        )

        try await h.engine.send(.openProject(path: ref.path, resumeSessionID: "thread-1"))

        #expect(capture.descriptors.last == .stdioJSONRPC)
        await h.shutdown()
    }

    @Test("openProject for custom mode fails explicitly when no custom adapter is registered")
    func openProjectCustomWithoutAdapterFails() async throws {
        let capture = CapturingTransportFactory()
        let h = try await EngineHarness.make(transportFactory: capture.makeTransport)
        let store = WorkspaceProjectsStore(environment: h.environment,
                                           fileSystem: h.fileSystem)
        let custom = CustomAgentRef(id: "local-custom",
                                    displayName: "Local Custom",
                                    transport: .stdioJSONRPC,
                                    executablePath: "/custom/agent",
                                    arguments: ["serve"])
        let ref = try await store.createProject(name: "custom",
                                                projectType: .custom(custom),
                                                in: h.workspace)

        await #expect(throws: AgentError.self) {
            try await h.engine.send(.openProject(path: ref.path, resumeSessionID: nil))
        }

        #expect(capture.descriptors.count == 1)
        await h.shutdown()
    }

    @Test("openProject resumes on the live process without respawn")
    func openProjectResumeUsesWarmProcess() async throws {
        let capture = CapturingTransportFactory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-warm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: root)
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        let adapter = WarmHandshakeAdapter()
        await AdapterRegistry.shared.register(adapter)
        let ref = try await store.createProject(name: "acp",
                                                projectType: .cursorCLI,
                                                in: root)

        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: capture.makeTransport)
        await engine.bootstrap()
        try await engine.start(adapter: adapter,
                               workspace: URL(fileURLWithPath: ref.path))
        #expect(capture.descriptors.count == 1)

        try await engine.send(.openProject(path: ref.path, resumeSessionID: "sess-B"))
        #expect(capture.descriptors.count == 1)
        #expect(adapter.resumeCalls == ["sess-B"])

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("openProject pool resume failure does not cold-respawn")
    func openProjectPoolResumeFailureDoesNotRespawn() async throws {
        let capture = CapturingTransportFactory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-pool-resume-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment(home: root)
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        let adapter = NoResumeHandshakeAdapter()
        await AdapterRegistry.shared.register(adapter)
        let ref = try await store.createProject(name: "acp",
                                                projectType: .cursorCLI,
                                                in: root)

        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: capture.makeTransport)
        await engine.bootstrap()
        try await engine.start(adapter: adapter,
                               workspace: URL(fileURLWithPath: ref.path))
        #expect(capture.descriptors.count == 1)

        await #expect(throws: AgentError.self) {
            try await engine.send(.openProject(path: ref.path, resumeSessionID: "sess-B"))
        }
        #expect(capture.descriptors.count == 1)

        await engine.shutdown(reason: .naturalExit)
    }

    @Test("sendPrompt publishes userTurn before a PTY write failure is thrown")
    func sendPromptPublishesBeforeWriteFailure() async throws {
        let transport = ScriptedTransport(writeSteps: [.fail(.writeFailed(errno: 5))])
        let h = try await EngineHarness.make(transport: transport)
        let bus = h.engine.bus
        await transport.setWriteProbe { _ in
            await bus.historySnapshot.contains {
                if case .userTurn(_, let text) = $0.event { return text == "will fail" }
                return false
            }
        }

        do {
            try await h.engine.send(.sendPrompt(text: "will fail", attachments: []))
            Issue.record("expected PTY write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await transport.writeProbeResults() == [true])
        #expect(await transport.writtenTexts() == ["will fail"])
        let history = await h.engine.bus.historySnapshot
        #expect(history.contains {
            if case .userTurn(_, let text) = $0.event { return text == "will fail" }
            return false
        })
        await h.shutdown()
    }

    @Test("sendPrompt write failure still fans userTurn out to remote-like subscribers")
    func sendPromptWriteFailureFansOutToRemoteSubscriber() async throws {
        let transport = ScriptedTransport(writeSteps: [.fail(.writeFailed(errno: 5))])
        let h = try await EngineHarness.make(transport: transport)
        let remoteSub = await h.engine.bus.subscribe()
        let remoteCollector = EventCollector()
        let remoteTask = Task { await remoteCollector.ingest(remoteSub.stream) }

        do {
            try await h.engine.send(.sendPrompt(text: "remote fail", attachments: []))
            Issue.record("expected PTY write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        try await Task.sleep(for: .milliseconds(40))
        let remoteEvents = await remoteCollector.snapshot()
        #expect(remoteEvents.contains {
            if case .userTurn(_, let text) = $0 { return text == "remote fail" }
            return false
        })

        await h.engine.bus.unsubscribe(remoteSub.id)
        remoteTask.cancel()
        await h.shutdown()
    }

    @Test("sendPrompt appends resolved attachment refs as local @ paths")
    func sendPromptWithAttachments() async throws {
        let h = try await EngineHarness.make()
        let ref = AttachmentRef(id: "upload-1",
                                filename: "spec.md",
                                byteCount: 4,
                                mimeType: "text/markdown")
        let uploaded = AppSupportPaths.attachmentsDirectory(in: h.environment.appSupportDirectory)
            .appendingPathComponent("upload-1-spec.md")
        try h.fileSystem.writeAtomically(Data("body".utf8), to: uploaded)

        try await h.engine.send(.sendPrompt(text: "review this", attachments: [ref]))
        try await Task.sleep(for: .milliseconds(20))

        let prompts = h.adapter.recorded.compactMap { entry -> String? in
            if case .userPrompt(let s) = entry { return s }; return nil
        }
        #expect(prompts.contains { $0 == "review this\n@\(uploaded.path)" })
        await h.shutdown()
    }

    @Test("sendPrompt writes encoded prompt bytes to the PTY")
    func sendPromptWritesPromptBytesToPTY() async throws {
        try await assertPTYWrite(.init("sendPrompt",
                                       .sendPrompt(text: "hello pty", attachments: []),
                                       "hello pty"))
    }

    @Test("cancelCurrentTurn calls adapter.cancelSequence")
    func cancelCurrentTurn() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await h.engine.send(.cancelCurrentTurn)
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.adapter.recorded.contains(.cancel))
        await h.shutdown()
    }

    @Test("cancelCurrentTurn writes Ctrl-C bytes then interrupts the PTY")
    func cancelCurrentTurnWritesAndInterruptsPTY() async throws {
        try await assertPTYWrite(.init("cancelCurrentTurn",
                                       .cancelCurrentTurn,
                                       bytes: Data([0x03])),
                                 interrupts: true)
    }

    @Test("cancelCurrentTurn write failure propagates and skips interrupt")
    func cancelCurrentTurnWriteFailureSkipsInterrupt() async throws {
        try await assertPTYWriteFailure(.init("cancelCurrentTurn",
                                              .cancelCurrentTurn,
                                              bytes: Data([0x03])))
    }

    @Test("editAndResubmitLast rewrites the last user bubble")
    func editAndResubmit() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await Task.sleep(for: .milliseconds(10))
        // Recover the bubble id from the published userTurn event.
        let events = await h.collectedSoFar()
        guard case .userTurn(let idString, _)? = events.first(where: {
            if case .userTurn = $0 { return true }; return false
        }) else {
            Issue.record("no userTurn event captured"); return
        }
        let targetID = InternalEntryID.derive(fromAdapterTurnID: idString)
        try await h.engine.send(.editAndResubmitLast(targetEntryID: targetID,
                                                    text: "edited",
                                                    attachments: []))
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.adapter.recorded.contains(.cancel))
        #expect(h.adapter.recorded.contains(.userPrompt("edited")))
        await h.shutdown()
    }

    @Test("editAndResubmitLast propagates cancel write failure before restart")
    func editAndResubmitCancelWriteFailurePropagates() async throws {
        let transport = ScriptedTransport(writeSteps: [.succeed, .fail(.writeFailed(errno: 5))])
        let h = try await EngineHarness.make(transport: transport)
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await Task.sleep(for: .milliseconds(20))
        let targetID = try await requireLastUserEntryID(h)

        do {
            try await h.engine.send(.editAndResubmitLast(targetEntryID: targetID,
                                                        text: "edited",
                                                        attachments: []))
            Issue.record("editAndResubmitLast should propagate cancel write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await transport.writtenData() == [Data("first".utf8), Data([0x03])])
        await h.shutdown()
    }

    @Test("editAndResubmitLast propagates revised prompt write failure after restart")
    func editAndResubmitRevisedPromptWriteFailurePropagates() async throws {
        let firstPTY = ScriptedTransport()
        let restartedPTY = ScriptedTransport(writeSteps: [.fail(.writeFailed(errno: 5))])
        let factory = ScriptedTransportFactory([firstPTY, restartedPTY])
        let h = try await EngineHarness.make(transportFactory: factory.makeTransport)
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await Task.sleep(for: .milliseconds(20))
        let targetID = try await requireLastUserEntryID(h)

        do {
            try await h.engine.send(.editAndResubmitLast(targetEntryID: targetID,
                                                        text: "edited fail",
                                                        attachments: []))
            Issue.record("editAndResubmitLast should propagate revised prompt write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await firstPTY.writtenData() == [Data("first".utf8), Data([0x03])])
        #expect(await restartedPTY.writtenData() == [Data("edited fail".utf8)])
        await h.shutdown()
    }

    @Test("editAndResubmitLast accepts the last user turn restored from history")
    func editAndResubmitAfterHistoryRestore() async throws {
        let sessionID = "resumed-session"
        let h = try await EngineHarness.make(resumeSessionID: sessionID)
        // A reopened session never minted its bubble ids in this engine run:
        // the ids clients hold come from the journal replay.
        let key = SessionTranscriptKey(projectRoot: h.workspace.standardizedFileURL,
                                       namespace: h.adapter.historyNamespace,
                                       sessionID: sessionID)
        let restoredTurnID = UUID()
        try await h.engine.transcriptRepository.record(
            .userTurn(id: AdapterTurnID(rawValue: restoredTurnID.uuidString), text: "first"),
            for: key
        )
        await h.engine.restoreHistory(for: key)

        try await h.engine.send(.editAndResubmitLast(
            targetEntryID: InternalEntryID(rawValue: restoredTurnID),
                                                     text: "edited",
                                                     attachments: []))
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.adapter.recorded.contains(.userPrompt("edited")))
        await h.shutdown()
    }

    @Test("editAndResubmitLast accepts a restored turn whose journal id is not a UUID")
    func editAndResubmitAfterRestoringAdapterMintedID() async throws {
        let sessionID = "resumed-adapter-session"
        let h = try await EngineHarness.make(resumeSessionID: sessionID)
        let key = SessionTranscriptKey(projectRoot: h.workspace.standardizedFileURL,
                                       namespace: h.adapter.historyNamespace,
                                       sessionID: sessionID)
        // Codex rollout keys, Cursor message ids and the Claude tailer fallback
        // are not UUIDs — clients derive the bubble id instead of parsing it.
        let journalTurnID = "2026-08-07T09:15:00Z-12"
        try await h.engine.transcriptRepository.record(
            .userTurn(id: AdapterTurnID(rawValue: journalTurnID), text: "first"),
            for: key
        )
        await h.engine.restoreHistory(for: key)

        try await h.engine.send(
            .editAndResubmitLast(targetEntryID: InternalEntryID.derive(fromAdapterTurnID: AdapterTurnID(rawValue: journalTurnID)),
                                 text: "edited",
                                 attachments: [])
        )
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.adapter.recorded.contains(.userPrompt("edited")))

        // Truncation has to address the journal by its raw id, so the revised
        // text lands on the existing turn rather than forking a second one.
        let restored = try await h.engine.transcriptRepository.transcript(for: key)
        #expect(restored.lastUserAdapterTurnID?.rawValue == journalTurnID)
        #expect(restored.snapshotMessages().filter { $0.role == .user }.map(\.text) == ["edited"])
        await h.shutdown()
    }

    @Test("editAndResubmitLast reports an unusable session when the respawn fails")
    func editAndResubmitRespawnFailurePublishesReadinessError() async throws {
        let firstPTY = ScriptedTransport()
        let factory = ScriptedTransportFactory([firstPTY])
        let h = try await EngineHarness.make(transportFactory: factory.makeTransport)
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await Task.sleep(for: .milliseconds(20))
        let targetID = try await requireLastUserEntryID(h)

        await #expect(throws: (any Error).self) {
            try await h.engine.send(.editAndResubmitLast(targetEntryID: targetID,
                                                         text: "edited",
                                                         attachments: []))
        }
        try await Task.sleep(for: .milliseconds(20))

        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .error(.sessionReadinessFailed) = $0 { return true }
            return false
        })
        await h.shutdown()
    }

    @Test("editAndResubmitLast throws staleEditTarget for unknown id")
    func editAndResubmitStaleThrows() async throws {
        let h = try await EngineHarness.make()
        let bogus = InternalEntryID(rawValue: UUID())
        await #expect(throws: AgentError.self) {
            try await h.engine.send(.editAndResubmitLast(targetEntryID: bogus,
                                                        text: "x",
                                                        attachments: []))
        }
        await h.shutdown()
    }

    // MARK: Slash commands

    @Test("newSession writes /clear via adapter encoder")
    func newSession() async throws { try await assertSlash(.newSession, contains: "/clear") }

    @Test("compact writes /compact")
    func compact() async throws { try await assertSlash(.compact, contains: "/compact") }

    @Test("selectModel writes /model with id")
    func selectModel() async throws {
        try await assertSlash(.selectModel(id: "sonnet"), contains: "sonnet")
    }

    @Test("setPermissionMode writes /permission with mode")
    func setPermissionMode() async throws {
        try await assertSlash(.setPermissionMode(.acceptEdits), contains: "acceptEdits")
    }

    @Test("setAgentMode think ids write /think bytes")
    func setThinkMode() async throws {
        try await assertSlash(.setAgentMode(id: AgentModeCommandID.think), contains: "/think")
        try await assertSlash(.setAgentMode(id: AgentModeCommandID.thinkOff), contains: "off")
    }

    @Test("setAgentMode review ids write /review bytes")
    func setReviewMode() async throws {
        try await assertSlash(.setAgentMode(id: AgentModeCommandID.review), contains: "/review")
        try await assertSlash(.setAgentMode(id: AgentModeCommandID.reviewOff), contains: "off")
    }

    @Test("runSlashCommand concatenates name + args")
    func runSlash() async throws {
        try await assertSlash(.runSlashCommand(target: .builtin(name: "/foo"), args: ["a", "b"]), contains: "/foo a b")
    }

    @Test("runCustomCommand writes path + args")
    func runCustom() async throws {
        try await assertSlash(.runSlashCommand(target: .custom(path: "/proj/review.md"), args: ["x"]),
                              contains: "/proj/review.md x")
    }

    @Test("typed slash commands write exact PTY bytes")
    func slashCommandsWriteExactPTYBytes() async throws {
        for testCase in slashPTYWriteCases() {
            try await assertPTYWrite(testCase)
        }
    }

    @Test("typed slash command write failures propagate")
    func slashCommandWriteFailuresPropagate() async throws {
        for testCase in slashPTYWriteCases() {
            try await assertPTYWriteFailure(testCase)
        }
    }

    // MARK: Permission

    @Test("respondToPermission asks adapter to encode response")
    func respondToPermission() async throws {
        let h = try await EngineHarness.make()
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "ls",
                                      argumentsSummary: "{}",
                                      requestedAt: Date())
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))
        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allow))
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.adapter.recorded.contains(.permissionResponse(.allow, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission writePTY delivery writes exact PTY bytes")
    func respondToPermissionWritePTYWritesBytes() async throws {
        let transport = ScriptedTransport()
        let adapter = RecordingMockAdapter(permissionDelivery: .writePTY(Data("allow\n".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, transport: transport)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allow))

        #expect(await transport.writtenData() == [Data("allow\n".utf8)])
        #expect(h.adapter.recorded.contains(.permissionResponse(.allow, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("adapter auto-allow permission is applied without surfacing to the UI")
    func adapterAutoAllowPermission() async throws {
        let transport = ScriptedTransport()
        let toolName = "WorkspaceTrust"
        let adapter = RecordingMockAdapter(
            permissionDelivery: .writePTY(Data("1\r".utf8)),
            autoAllowToolNames: [toolName]
        )
        let h = try await EngineHarness.make(adapter: adapter, transport: transport)
        let prompt = PermissionPrompt(
            toolName: toolName,
            summary: "Trust this workspace?",
            argumentsSummary: h.workspace.path,
            requestedAt: Date()
        )
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(80))

        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .permissionAlreadyResolved(let id, let by) = $0 {
                return id == prompt.id && by == "adapter-auto"
            }
            return false
        })
        #expect(!events.contains {
            if case .permissionRequest = $0 { return true }
            return false
        })
        #expect(await transport.writtenData() == [Data("1\r".utf8)])
        #expect(h.adapter.recorded.contains(.permissionResponse(.allow, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission writePTY delivery propagates PTY write failure")
    func respondToPermissionWritePTYFailurePropagates() async throws {
        let transport = ScriptedTransport(writeSteps: [.fail(.writeFailed(errno: 5))])
        let adapter = RecordingMockAdapter(permissionDelivery: .writePTY(Data("allow\n".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, transport: transport)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        do {
            try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allow))
            Issue.record("respondToPermission should propagate writePTY failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await transport.writtenData() == [Data("allow\n".utf8)])
        await h.shutdown()
    }

    @Test("respondToPermission both delivery writes PTY bytes")
    func respondToPermissionBothWritesPTYBytes() async throws {
        let transport = ScriptedTransport()
        let adapter = RecordingMockAdapter(permissionDelivery: .both(ptyBytes: Data("both\n".utf8),
                                                                     hookStdout: Data("{}".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, transport: transport)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allowAlways))

        #expect(await transport.writtenData() == [Data("both\n".utf8)])
        #expect(h.adapter.recorded.contains(.permissionResponse(.allowAlways, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission both delivery propagates PTY write failure")
    func respondToPermissionBothFailurePropagates() async throws {
        let transport = ScriptedTransport(writeSteps: [.fail(.writeFailed(errno: 5))])
        let adapter = RecordingMockAdapter(permissionDelivery: .both(ptyBytes: Data("both\n".utf8),
                                                                     hookStdout: Data("{}".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, transport: transport)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        do {
            try await h.engine.send(.respondToPermission(id: prompt.id, decision: .deny))
            Issue.record("respondToPermission should propagate both-delivery PTY failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await transport.writtenData() == [Data("both\n".utf8)])
        await h.shutdown()
    }

    @Test("respondToPermission hook-only delivery does not touch the PTY")
    func respondToPermissionHookOnlyDoesNotWritePTY() async throws {
        let transport = ScriptedTransport()
        let adapter = RecordingMockAdapter(permissionDelivery: .respondToHookProcess(jsonStdout: Data("{}".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, transport: transport)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .deny))

        #expect(await transport.writtenData().isEmpty)
        #expect(h.adapter.recorded.contains(.permissionResponse(.deny, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission for unknown id is a no-op")
    func respondToPermissionUnknown() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.respondToPermission(id: PermissionPromptID(rawValue: UUID()),
                                                     decision: .deny))
        await h.shutdown()
    }

    // MARK: Lifecycle

    @Test("closeSession transitions engine to stopped")
    func closeSession() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.closeSession)
        try await Task.sleep(for: .milliseconds(50))
        let state = await h.engine.currentState
        #expect(state == .stopped)
    }

    // MARK: Out-of-band

    @Test("speakAssistantBubble publishes speakBubbleRequested")
    func speakBubble() async throws {
        let h = try await EngineHarness.make()
        let id = UUID()
        try await h.engine.send(.speakAssistantBubble(eventID: id, action: .play))
        try await Task.sleep(for: .milliseconds(20))
        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .speakBubbleRequested(eventID: id, action: .play) = $0 { return true }
            return false
        })
        await h.shutdown()
    }

    @Test("revertFile publishes fileReverted")
    func revertFile() async throws {
        let workspace = try await makeGitWorkspace(initial: "original\n")
        let file = workspace.appendingPathComponent("foo.txt")
        try "changed\n".write(to: file, atomically: true, encoding: .utf8)

        let h = try await EngineHarness.make(workspace: workspace)
        try await h.engine.send(.revertFile(file: ChangedFile(relativePath: "foo.txt")))
        try await Task.sleep(for: .milliseconds(20))

        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .fileReverted(let f) = $0 { return f.relativePath == "foo.txt" }; return false
        })
        let restored = try String(contentsOf: file, encoding: .utf8)
        #expect(restored == "original\n")
        await h.shutdown()
    }

    @Test("revertHunk reverts only the selected hunk")
    func revertHunk() async throws {
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let workspace = try await makeGitWorkspace(initial: original)
        let file = workspace.appendingPathComponent("foo.txt")
        let changed = (1...20)
            .map { line -> String in
                if line == 2 { return "two changed" }
                if line == 18 { return "eighteen changed" }
                return "line \(line)"
            }
            .joined(separator: "\n") + "\n"
        try changed.write(to: file, atomically: true, encoding: .utf8)

        let diff = try await GitDiffEngine(workspace: workspace).diff(for: "foo.txt")
        let firstHunkID = try #require(diff.hunks.first?.id)

        let h = try await EngineHarness.make(workspace: workspace)
        try await h.engine.send(.revertHunk(file: ChangedFile(relativePath: "foo.txt"), hunkID: firstHunkID))
        try await Task.sleep(for: .milliseconds(20))

        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .fileReverted(let f) = $0 { return f.relativePath == "foo.txt" }; return false
        })
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.contains("line 2\n"))
        #expect(content.contains("eighteen changed"))
        await h.shutdown()
    }

    @Test("updateAutoApprovalRules publishes prefsChanged and persists")
    func updateRules() async throws {
        let h = try await EngineHarness.make()
        let rules = [AutoApprovalRule(match: "Bash ls *", decision: .allow)]
        try await h.engine.send(.updateAutoApprovalRules(rules))
        try await Task.sleep(for: .milliseconds(20))
        let state = await h.engine.prefs.state()
        #expect(state.autoApprovalRules.count == 1)
        await h.shutdown()
    }

    @Test("updateAppearancePref publishes appearancePrefChanged and persists")
    func updateAppearance() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.updateAppearancePref(.theme("dark")))
        try await Task.sleep(for: .milliseconds(20))
        let state = await h.engine.prefs.state()
        #expect(state.appearance.theme == .dark)
        await h.shutdown()
    }

    @Test("requestSnapshot publishes snapshotReady with payload")
    func requestSnapshot() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.requestSnapshot(.prefs))
        try await Task.sleep(for: .milliseconds(20))
        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .snapshotReady(let k, _) = $0 { return k == .prefs }; return false
        })
        await h.shutdown()
    }

    @Test("recordClientAction publishes clientAction and appears in conversation snapshot")
    func recordClientActionPublishesAndSnapshots() async throws {
        let h = try await EngineHarness.make()
        let action = ClientAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            kind: .slashCommand,
            title: "Slash command",
            detail: "/help"
        )
        try await h.engine.send(.recordClientAction(action))
        try await Task.sleep(for: .milliseconds(20))
        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .clientAction(let published) = $0 { return published == action }
            return false
        })

        try await h.engine.send(.requestSnapshot(.conversation))
        try await Task.sleep(for: .milliseconds(20))
        let snapEvents = await h.collectedSoFar()
        guard case .snapshotReady(.conversation, let payload)? = snapEvents.last(where: {
            if case .snapshotReady(.conversation, _) = $0 { return true }
            return false
        }) else {
            Issue.record("expected conversation snapshot"); return
        }
        let json = try #require(String(data: payload, encoding: .utf8))
        #expect(json.contains("\"role\":\"action\""))
        #expect(json.contains("Slash command"))
        #expect(json.contains("\\/help") || json.contains("/help"))
        await h.shutdown()
    }

    @Test("ready prompt detector accepts current and guarded fallback prompts")
    func readyPromptDetectorAcceptsKnownPrompts() {
        #expect(ClaudeTerminalInputClassification.classify([
            "● high · /effort",
            "────────────────",
            "❯\u{00A0}",
            "? for shortcuts · ← for agents"
        ]) == .ready)
        #expect(ClaudeTerminalInputClassification.classify([
            ">",
            "? for shortcuts"
        ]) == .ready)
        // History paints prior prompts; only the last empty ❯ is "ready".
        #expect(ClaudeTerminalInputClassification.classify([
            "❯ Reply with exactly: pong",
            "⏺ pong",
            "❯",
            "⏸ manual mode on · ? for shortcuts · ← 1 agent"
        ]) == .ready)
        #expect(ClaudeTerminalInputClassification.classify([
            "❯",
            "⏸manualmodeon·?forshortcuts·←1 agent"
        ]) == .ready)
    }

    @Test("ready prompt detector rejects replayed prompt text and stray arrows")
    func readyPromptDetectorRejectsFalsePositives() {
        #expect(ClaudeTerminalInputClassification.classify([
            "❯ good day",
            "⏺ Good day, Alice!"
        ]) == .unsubmitted)
        #expect(ClaudeTerminalInputClassification.classify([
            ">",
            "some shell transcript without Claude footer"
        ]) == .unknown)
        // Last row still carries text — not ready, even if an earlier ❯ is empty.
        #expect(ClaudeTerminalInputClassification.classify([
            "❯",
            "❯ still typing",
            "? for shortcuts"
        ]) == .unsubmitted)
    }

    @Test("unsubmitted-prompt detector matches input rows still carrying text")
    func unsubmittedPromptDetectorMatchesPendingText() {
        #expect(ClaudeTerminalInputClassification.classify([
            "❯ still here",
            "? for shortcuts"
        ]) == .unsubmitted)
        #expect(ClaudeTerminalInputClassification.classify([
            "> pending text",
            "? for shortcuts"
        ]) == .unsubmitted)
        // History + live unsubmitted input: last prompt row wins.
        #expect(ClaudeTerminalInputClassification.classify([
            "❯ Reply with exactly: pong",
            "⏺ pong",
            "❯ resume-pong",
            "? for shortcuts"
        ]) == .unsubmitted)
    }

    @Test("unsubmitted-prompt detector ignores empty input rows and arrows")
    func unsubmittedPromptDetectorIgnoresEmptyInput() {
        #expect(ClaudeTerminalInputClassification.classify([
            "❯\u{00A0}",
            "? for shortcuts"
        ]) == .ready)
        #expect(ClaudeTerminalInputClassification.classify([
            "> pending text without footer"
        ]) == .unknown)
        // Historical prompt text must not look like a live unsubmitted row.
        #expect(ClaudeTerminalInputClassification.classify([
            "❯ Reply with exactly: pong",
            "⏺ pong",
            "❯",
            "? for shortcuts"
        ]) == .ready)
    }

    // MARK: Permission auto-deny timeout

    @Test("Pending permission auto-denies after permissionTimeout elapses")
    func permissionAutoDenies() async throws {
        let clock = FakeClock()
        let h = try await EngineHarness.make(clock: clock, permissionTimeout: .seconds(60))
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "rm -rf /",
                                      argumentsSummary: "{}",
                                      requestedAt: clock.now())
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        clock.advance(by: .seconds(61))
        try await Task.sleep(for: .milliseconds(80))
        let events = await h.collectedSoFar()
        let sawResolved = events.contains {
            if case .permissionAlreadyResolved(let id, let by) = $0 {
                return id == prompt.id && by == "timeout"
            }
            return false
        }
        #expect(sawResolved)
        #expect(h.adapter.recorded.contains(.permissionResponse(.deny, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("permissionAlreadyResolved cancels auto-deny without delivering a second response")
    func permissionAlreadyResolvedCancelsTimeout() async throws {
        let clock = FakeClock()
        let h = try await EngineHarness.make(clock: clock, permissionTimeout: .seconds(60))
        let prompt = PermissionPrompt(toolName: "Review",
                                      summary: "Human review",
                                      argumentsSummary: "{}",
                                      requestedAt: clock.now())
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))

        h.adapter.emit(.permissionAlreadyResolved(id: prompt.id, byDevice: "session-archived"))
        try await spinUntil(clock: clock, target: 2, timeout: .seconds(2))

        clock.advance(by: .seconds(61))
        try await Task.sleep(for: .milliseconds(80))
        let events = await h.collectedSoFar()
        let timeoutDeny = events.contains {
            if case .permissionAlreadyResolved(_, let by) = $0 { return by == "timeout" }
            return false
        }
        #expect(!timeoutDeny)
        #expect(!h.adapter.recorded.contains(.permissionResponse(.deny, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission before timeout cancels the auto-deny")
    func respondCancelsTimeout() async throws {
        let clock = FakeClock()
        let h = try await EngineHarness.make(clock: clock, permissionTimeout: .seconds(60))
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "x",
                                      argumentsSummary: "{}",
                                      requestedAt: clock.now())
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allow))
        try await Task.sleep(for: .milliseconds(20))
        clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(50))
        let events = await h.collectedSoFar()
        let sawTimeoutResolution = events.contains {
            if case .permissionAlreadyResolved(_, let by) = $0 { return by == "timeout" }
            return false
        }
        #expect(!sawTimeoutResolution)
        await h.shutdown()
    }

    // MARK: Helpers

    private struct PTYWriteCase {
        let name: String
        let command: AgentCommand
        let expectedBytes: Data

        init(_ name: String, _ command: AgentCommand, _ expectedText: String) {
            self.name = name
            self.command = command
            self.expectedBytes = Data(expectedText.utf8)
        }

        init(_ name: String, _ command: AgentCommand, bytes: Data) {
            self.name = name
            self.command = command
            self.expectedBytes = bytes
        }
    }

    private func slashPTYWriteCases() -> [PTYWriteCase] {
        [
            .init("newSession", .newSession, "/clear\n"),
            .init("compact", .compact, "/compact\n"),
            .init("selectModel", .selectModel(id: "sonnet"), "/model sonnet\n"),
            .init("setPermissionMode", .setPermissionMode(.acceptEdits), "/permission acceptEdits\n"),
            .init("setAgentMode think", .setAgentMode(id: AgentModeCommandID.think), "/think\n"),
            .init("setAgentMode think off", .setAgentMode(id: AgentModeCommandID.thinkOff), "/think off\n"),
            .init("setAgentMode review", .setAgentMode(id: AgentModeCommandID.review), "/review\n"),
            .init("setAgentMode review off", .setAgentMode(id: AgentModeCommandID.reviewOff), "/review off\n"),
            .init("runSlashCommand", .runSlashCommand(target: .builtin(name: "/foo"), args: ["a", "b"]), "/foo a b\n"),
            .init("runCustomCommand",
                  .runSlashCommand(target: .custom(path: "/proj/review.md"), args: ["x"]),
                  "/proj/review.md x\n")
        ]
    }

    private func assertPTYWrite(_ testCase: PTYWriteCase,
                                interrupts: Bool = false) async throws {
        let transport = ScriptedTransport()
        let h = try await EngineHarness.make(transport: transport)

        try await h.engine.send(testCase.command)

        #expect(await transport.writtenData() == [testCase.expectedBytes],
                "\(testCase.name) wrote unexpected PTY bytes")
        #expect(await transport.wasInterrupted() == interrupts,
                "\(testCase.name) interrupt state mismatch")
        await h.shutdown()
    }

    private func assertPTYWriteFailure(_ testCase: PTYWriteCase) async throws {
        let transport = ScriptedTransport(writeSteps: [.fail(.writeFailed(errno: 5))])
        let h = try await EngineHarness.make(transport: transport)

        do {
            try await h.engine.send(testCase.command)
            Issue.record("\(testCase.name) should propagate PTY write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("\(testCase.name) threw unexpected error: \(error)")
        }

        #expect(await transport.writtenData() == [testCase.expectedBytes],
                "\(testCase.name) failed after writing unexpected bytes")
        #expect(await transport.wasInterrupted() == false,
                "\(testCase.name) should not interrupt after a failed write")
        await h.shutdown()
    }

    private func requireLastUserEntryID(_ h: EngineHarness) async throws -> InternalEntryID {
        let events = await h.collectedSoFar()
        guard case .userTurn(let turnID, _)? = events.last(where: {
            if case .userTurn = $0 { return true }
            return false
        }) else {
            Issue.record("no userTurn event captured")
            throw AgentError.internalInvariant(detail: "missing userTurn in test harness")
        }
        return InternalEntryID.derive(fromAdapterTurnID: turnID)
    }

    private func permissionPrompt() -> PermissionPrompt {
        PermissionPrompt(toolName: "Bash",
                         summary: "ls",
                         argumentsSummary: "{}",
                         requestedAt: Date())
    }

    private func assertSlash(_ command: AgentCommand, contains substring: String) async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(command)
        try await Task.sleep(for: .milliseconds(20))
        let prompts = h.adapter.recorded.compactMap { entry -> String? in
            if case .userPrompt(let s) = entry { return s }; return nil
        }
        #expect(prompts.contains { $0.contains(substring) },
                "no slash text matched '\(substring)' in \(prompts)")
        await h.shutdown()
    }

    private func spinUntil(clock: FakeClock, target: Int, timeout: Duration) async throws {
        let start = ContinuousClock.now
        while clock.pendingSleepCount < target {
            if start.duration(to: .now) > timeout { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitUntil(timeout: Duration,
                           predicate: () async -> Bool) async throws {
        let start = ContinuousClock.now
        while !(await predicate()) {
            if start.duration(to: .now) > timeout {
                Issue.record("timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeGitWorkspace(initial: String) async throws -> URL {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-git-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("foo.txt")
        try initial.write(to: file, atomically: true, encoding: .utf8)
        try await runGit(["init"], cwd: workspace)
        try await runGit(["add", "foo.txt"], cwd: workspace)
        try await runGit([
            "-c", "user.name=Codemixer Tests",
            "-c", "user.email=codemixer@example.invalid",
            "commit", "-m", "baseline"
        ], cwd: workspace)
        return workspace
    }

    private func runGit(_ arguments: [String], cwd: URL) async throws {
        _ = try await ProcessRunner().run(executable: SystemPaths.env,
                                          arguments: ["git"] + arguments,
                                          cwd: cwd)
    }
}

// MARK: - Test harness

actor EventCollector {
    private(set) var events: [AgentEvent] = []
    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream { events.append(entry.event) }
    }
    func snapshot() -> [AgentEvent] { events }
}

struct EngineHarness {
    let engine: AgentEngine
    let adapter: RecordingMockAdapter
    let collector: EventCollector
    let subID: UUID
    let workspace: URL
    let environment: FakeEnvironment
    let fileSystem: InMemoryFileSystem
    let transport: ScriptedTransport?

    static func make(clock: any AgentClock = SystemClock(),
                     workspace: URL? = nil,
                     environment: FakeEnvironment? = nil,
                     permissionTimeout: Duration = .seconds(300),
                     // The mock adapter never republishes SessionStart after a
                     // respawn, so keep the readiness wait short in tests.
                     promptReadinessTimeout: Duration = .milliseconds(200),
                     adapter: RecordingMockAdapter? = nil,
                     resumeSessionID: String? = nil,
                     transport: ScriptedTransport? = nil,
                     transportFactory: AgentTransportFactory? = nil) async throws -> EngineHarness {
        let fs = InMemoryFileSystem()
        let workspace = workspace ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-engine-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let env = environment ?? FakeEnvironment(home: workspace)
        let seams = Seams.fake(environment: env, fileSystem: fs).with(clock: clock)
        let factory: AgentTransportFactory
        if let transportFactory {
            factory = transportFactory
        } else if let transport {
            factory = { _, _ in transport }
        } else {
            factory = LiveAgentTransportFactory.make
        }
        let engine = AgentEngine(seams: seams,
                                 permissionTimeout: permissionTimeout,
                                 promptReadinessTimeout: promptReadinessTimeout,
                                 transportFactory: factory)
        await engine.bootstrap()
        let adapter = adapter ?? RecordingMockAdapter()
        try await engine.start(adapter: adapter,
                               workspace: workspace,
                               resumeSessionID: resumeSessionID)
        #expect(adapter.emit(.sessionStarted(
            sessionID: resumeSessionID ?? "test-session",
            model: nil,
            cwd: workspace
        )))
        try await Task.sleep(for: .milliseconds(20))
        let sub = await engine.bus.subscribe()
        let collector = EventCollector()
        Task { await collector.ingest(sub.stream) }
        return EngineHarness(engine: engine,
                             adapter: adapter,
                             collector: collector,
                             subID: sub.id,
                             workspace: workspace,
                             environment: env,
                             fileSystem: fs,
                             transport: transport)
    }

    func collectedSoFar() async -> [AgentEvent] { await collector.snapshot() }

    func shutdown() async {
        await engine.bus.unsubscribe(subID)
        await engine.shutdown(reason: .naturalExit)
    }
}

final class CapturingTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lastSpec: AgentTransportLaunchSpec?
    private(set) var lastDescriptor: AgentTransportDescriptor?
    private(set) var descriptors: [AgentTransportDescriptor] = []

    func makeTransport(_ descriptor: AgentTransportDescriptor,
                       _ launch: AgentTransportLaunchSpec) throws -> any AgentTransport {
        lock.lock()
        lastSpec = launch
        lastDescriptor = descriptor
        descriptors.append(descriptor)
        lock.unlock()
        return ScriptedTransport()
    }
}

final class RoutingTestAdapter: AgentAdapter, @unchecked Sendable {
    let id: AgentID
    let displayName: String
    let iconSymbol = "ant"
    let capabilities: AgentCapabilities = [.resumableSessions]
    let transportDescriptor: AgentTransportDescriptor
    let slashCommandCatalog: [SlashCommand] = []
    private let lock = NSLock()
    /// `LaunchContext.workspace` is the cwd every protocol adapter puts in
    /// `session/new` / `startThread`, so recording it here proves what the CLI sees.
    private(set) var launchContextWorkspaces: [URL] = []

    init(id: AgentID, descriptor: AgentTransportDescriptor) {
        self.id = id
        self.displayName = id.rawValue
        self.transportDescriptor = descriptor
    }

    func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        SystemPaths.cat
    }

    func defaultEnvOverrides() -> [String: String] { [:] }

    func buildLaunchArgv(context: LaunchContext) -> [String] {
        lock.lock()
        launchContextWorkspaces.append(context.workspace)
        lock.unlock()
        return ["cat"]
    }

    func authStatus(env: ResolvedEnvironment) async -> AuthStatus {
        .authenticated(account: nil)
    }

    func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }

    func encodeUserPrompt(_ text: String) -> Data { Data(text.utf8) }

    func cancelSequence() -> Data { Data() }

    func encodePermissionResponse(_ decision: PermissionDecision,
                                  for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        .writePTY(Data())
    }

    func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }

    func resumeArgvAddition(sessionID: String) -> [String] { [] }
}

/// Handshake-gated adapter that can warm-encode `session/load` bytes.
final class WarmHandshakeAdapter: AgentAdapter, @unchecked Sendable {
    let id: AgentID = .cursorCLI
    let displayName = "Warm Handshake"
    let iconSymbol = "ant"
    let capabilities: AgentCapabilities = [.resumableSessions]
    let transportDescriptor: AgentTransportDescriptor = .agentClientProtocol
    let slashCommandCatalog: [SlashCommand] = []
    private let lock = NSLock()
    private(set) var resumeCalls: [String] = []

    func locateBinary(env: ResolvedEnvironment) async throws -> URL { SystemPaths.cat }
    func defaultEnvOverrides() -> [String: String] { [:] }
    func buildLaunchArgv(context: LaunchContext) -> [String] { ["cat"] }
    func authStatus(env: ResolvedEnvironment) async -> AuthStatus { .authenticated(account: nil) }
    func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
    func encodeUserPrompt(_ text: String) -> Data { Data(text.utf8) }
    func cancelSequence() -> Data { Data() }
    func encodeCommand(_ command: AgentCommand) -> Data? {
        switch command {
        case .newSession:
            return Data("session/new".utf8)
        default:
            return nil
        }
    }
    func encodeResumeSession(sessionID: String) -> Data? {
        lock.lock(); resumeCalls.append(sessionID); lock.unlock()
        return Data("session/load:\(sessionID)".utf8)
    }
    func encodePermissionResponse(_ decision: PermissionDecision,
                                  for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        .writePTY(Data())
    }
    func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }
    func resumeArgvAddition(sessionID: String) -> [String] { [] }
}

/// Cursor-shaped adapter that cannot encode in-process resume (activate must fail).
final class NoResumeHandshakeAdapter: AgentAdapter, @unchecked Sendable {
    let id: AgentID = .cursorCLI
    let displayName = "No Resume Handshake"
    let iconSymbol = "ant"
    let capabilities: AgentCapabilities = [.resumableSessions]
    let transportDescriptor: AgentTransportDescriptor = .agentClientProtocol
    let slashCommandCatalog: [SlashCommand] = []

    func locateBinary(env: ResolvedEnvironment) async throws -> URL { SystemPaths.cat }
    func defaultEnvOverrides() -> [String: String] { [:] }
    func buildLaunchArgv(context: LaunchContext) -> [String] { ["cat"] }
    func authStatus(env: ResolvedEnvironment) async -> AuthStatus { .authenticated(account: nil) }
    func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
    func encodeUserPrompt(_ text: String) -> Data { Data(text.utf8) }
    func cancelSequence() -> Data { Data() }
    func encodeResumeSession(sessionID: String) -> Data? { nil }
    func encodePermissionResponse(_ decision: PermissionDecision,
                                  for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        .writePTY(Data())
    }
    func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }
    func resumeArgvAddition(sessionID: String) -> [String] { [] }
}

final class ScriptedTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [ScriptedTransport]
    private(set) var spawnCount = 0

    init(_ transports: [ScriptedTransport]) {
        self.transports = transports
    }

    func makeTransport(_ descriptor: AgentTransportDescriptor,
                       _ launch: AgentTransportLaunchSpec) throws -> any AgentTransport {
        lock.lock()
        defer { lock.unlock() }
        spawnCount += 1
        guard !transports.isEmpty else {
            throw AgentError.internalInvariant(detail: "scripted transport factory exhausted")
        }
        return transports.removeFirst()
    }
}

actor ScriptedTransport: AgentTransport {
    enum WriteStep: Sendable {
        case succeed
        case fail(PTYError)
    }

    nonisolated let outboundBytes: AsyncStream<Data>
    nonisolated let bellEvents: AsyncStream<Void>
    nonisolated var terminalSnapshot: (any TerminalSnapshotting)? { terminal }

    private nonisolated let terminal = TerminalEngine()
    private let outboundContinuation: AsyncStream<Data>.Continuation
    private let writeSteps: [WriteStep]
    private var nextWriteIndex = 0
    private var writes: [Data] = []
    private var probes: [Bool] = []
    private var writeProbe: (@Sendable (Data) async -> Bool)?
    private var closed = false
    private var interrupted = false

    init(writeSteps: [WriteStep] = []) {
        var continuation: AsyncStream<Data>.Continuation!
        self.outboundBytes = AsyncStream(bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)) { c in
            continuation = c
        }
        self.outboundContinuation = continuation
        self.writeSteps = writeSteps

        var bellCont: AsyncStream<Void>.Continuation!
        self.bellEvents = AsyncStream { bellCont = $0 }
        bellCont.finish()
    }

    func setWriteProbe(_ probe: @escaping @Sendable (Data) async -> Bool) {
        writeProbe = probe
    }

    func write(_ data: Data) async throws {
        guard !closed else { throw PTYError.alreadyClosed }
        writes.append(data)
        if let writeProbe {
            probes.append(await writeProbe(data))
        }

        let step = nextWriteIndex < writeSteps.count ? writeSteps[nextWriteIndex] : .succeed
        nextWriteIndex += 1
        switch step {
        case .succeed:
            return
        case .fail(let error):
            throw error
        }
    }

    func interrupt() async {
        interrupted = true
    }

    func close() async {
        closed = true
        outboundContinuation.finish()
    }

    func isClosed() -> Bool { closed }

    func emit(_ text: String) async {
        let data = Data(text.utf8)
        await terminal.feed(data)
        outboundContinuation.yield(data)
    }

    func writtenTexts() -> [String] {
        writes.map { String(decoding: $0, as: UTF8.self) }
    }

    func writtenData() -> [Data] {
        writes
    }

    func writeProbeResults() -> [Bool] {
        probes
    }

    func wasInterrupted() -> Bool {
        interrupted
    }
}

// MARK: - Seams extension

extension Seams {
    /// Return a copy of the seams with `clock` replaced.
    func with(clock: any AgentClock) -> Seams {
        Seams(clock: clock,
              random: self.random,
              environment: self.environment,
              fileSystem: self.fileSystem)
    }
}

// MARK: - Default encodeCommand (Claude slash text)

@Suite("AgentAdapter — default encodeCommand")
struct EncodeCommandDefaultTests {
    private let adapter = MockAdapter()

    @Test("newSession produces /clear with newline")
    func newSession() {
        let data = adapter.encodeCommand(.newSession)
        #expect(String(data: data ?? Data(), encoding: .utf8) == "/clear\n")
    }

    @Test("compact produces /compact with newline")
    func compact() {
        let data = adapter.encodeCommand(.compact)
        #expect(String(data: data ?? Data(), encoding: .utf8) == "/compact\n")
    }

    @Test("selectModel encodes model id")
    func selectModel() {
        let data = adapter.encodeCommand(.selectModel(id: "claude-opus-4"))
        #expect(String(data: data ?? Data(), encoding: .utf8) == "/model claude-opus-4\n")
    }

    @Test("setAgentMode think produces /think")
    func thinkOn() {
        let data = adapter.encodeCommand(.setAgentMode(id: AgentModeCommandID.think))
        #expect(String(data: data ?? Data(), encoding: .utf8) == "/think\n")
    }

    @Test("setAgentMode think-off produces /think off")
    func thinkOff() {
        let data = adapter.encodeCommand(.setAgentMode(id: AgentModeCommandID.thinkOff))
        #expect(String(data: data ?? Data(), encoding: .utf8) == "/think off\n")
    }

    @Test("runSlashCommand joins name and args with spaces")
    func runSlashCommand() {
        let data = adapter.encodeCommand(.runSlashCommand(target: .builtin(name: "/memory"), args: ["add", "note"]))
        #expect(String(data: data ?? Data(), encoding: .utf8) == "/memory add note\n")
    }

    @Test("sendPrompt is unsupported (nil)")
    func sendPromptIsNil() {
        #expect(adapter.encodeCommand(.sendPrompt(text: "hello", attachments: [])) == nil)
    }
}
