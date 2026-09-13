import Foundation
import Testing

@testable import AgentCore
import AgentTestSupport

@Suite("AgentEngine project-local session restoration")
struct AgentEngineSessionHistoryTests {
    @Test("history is published before prompt readiness")
    func historyPrecedesPromptReadiness() async throws {
        let fileSystem = InMemoryFileSystem()
        let seams = Seams(
            clock: FakeClock(),
            random: FakeRandomSource(),
            environment: FakeEnvironment(),
            fileSystem: fileSystem
        )
        let engine = AgentEngine(seams: seams)
        let key = SessionTranscriptKey(
            projectRoot: TestPaths.underTemporary("engine-history-order"),
            namespace: AgentID.claudeCode.rawValue,
            sessionID: "session-1"
        )
        try await engine.transcriptRepository.record(
            .userTurn(id: AdapterTurnID(rawValue: "user-1"), text: "Restored prompt"),
            for: key
        )

        await engine.restoreHistory(for: key)
        await engine.bus.publish(.sessionPromptReady(sessionID: key.sessionID))

        let events = await engine.bus.historySnapshot.map(\.event)

        let chunkIndex = try #require(events.firstIndex {
            if case .sessionHistoryReplayChunk(_, 0, 1, let replay) = $0 {
                return replay.contains {
                    if case .userTurn(_, let text) = $0 { return text == "Restored prompt" }
                    return false
                }
            }
            return false
        })
        let restoredIndex = try #require(events.firstIndex {
            if case .sessionHistoryRestored(let id) = $0 { return id == key.sessionID }
            return false
        })
        let readyIndex = try #require(events.firstIndex {
            if case .sessionPromptReady(let id) = $0 { return id == key.sessionID }
            return false
        })
        #expect(chunkIndex < restoredIndex)
        #expect(restoredIndex < readyIndex)
        try await engine.transcriptRepository.shutdown()
    }

    @Test("restoration replaces engine changed files from the transcript")
    func restorationOwnsChangedFiles() async throws {
        let fileSystem = InMemoryFileSystem()
        let seams = Seams(
            clock: FakeClock(),
            random: FakeRandomSource(),
            environment: FakeEnvironment(),
            fileSystem: fileSystem
        )
        let engine = AgentEngine(seams: seams)
        let root = TestPaths.underTemporary("engine-history-files")
        let key = SessionTranscriptKey(
            projectRoot: root,
            namespace: AgentID.codex.rawValue,
            sessionID: "session-2"
        )
        let file = root.appendingPathComponent("Sources/App.swift")
        try await engine.transcriptRepository.record(
            AgentEvent.fileTouched(file, kind: .fsObserved),
            for: key
        )

        await engine.restoreHistory(for: key)

        #expect(await engine.changedFiles.map(\.relativePath) == ["Sources/App.swift"])
        try await engine.transcriptRepository.shutdown()
    }

    @Test("large history restoration publishes bounded contiguous chunks")
    func largeHistoryRestorationIsChunked() async throws {
        let engine = AgentEngine(seams: .fake())
        let key = SessionTranscriptKey(
            projectRoot: TestPaths.underTemporary("engine-history-chunks"),
            namespace: AgentID.claudeCode.rawValue,
            sessionID: "session-chunks"
        )
        let events = (0..<130).map {
            AgentEvent.userTurn(
                id: AdapterTurnID(rawValue: "user-\($0)"),
                text: "Prompt \($0)"
            )
        }
        try await engine.transcriptRepository.record(events, for: key)

        await engine.restoreHistory(for: key)

        let published = await engine.bus.historySnapshot.map(\.event)
        let chunks = published.compactMap { event -> (Int, Int, Int)? in
            if case .sessionHistoryReplayChunk(let id, let index, let total, let replay) = event,
               id == key.sessionID {
                return (index, total, replay.count)
            }
            return nil
        }
        #expect(chunks.map { $0.0 } == [0, 1, 2])
        #expect(chunks.map { $0.1 } == [3, 3, 3])
        #expect(chunks.map { $0.2 } == [64, 64, 2])
        if case .sessionHistoryRestored(let id) = published.last {
            #expect(id == key.sessionID)
        } else {
            Issue.record("Expected restoration marker after every chunk")
        }
        try await engine.transcriptRepository.shutdown()
    }

    @Test("prompt remains blocked until the adapter binds the restored session")
    func restoredSessionWaitsForAdapter() async throws {
        let workspace = TestPaths.underTemporary("engine-history-readiness")
        let transport = ScriptedTransport()
        let engine = AgentEngine(seams: .fake()) { _, _ in transport }
        let adapter = RecordingMockAdapter()
        await engine.bootstrap()
        try await engine.start(
            adapter: adapter,
            workspace: workspace,
            resumeSessionID: "session-3"
        )

        await #expect(throws: AgentError.self) {
            try await engine.send(.sendPrompt(text: "too early", attachments: []))
        }

        #expect(adapter.emit(.sessionStarted(
            sessionID: "session-3",
            model: nil,
            cwd: workspace
        )))
        try await Task.sleep(for: .milliseconds(20))
        try await engine.send(.sendPrompt(text: "ready", attachments: []))

        #expect(await transport.writtenTexts() == ["ready"])
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("warm activation flushes parked work before restoring history")
    func warmActivationFlushesParkedWork() async throws {
        let workspace = TestPaths.underTemporary("engine-history-flush")
        let engine = AgentEngine(seams: .fake()) { _, _ in ScriptedTransport() }
        let adapter = RecordingMockAdapter(capabilities: [.resumableSessions])
        await engine.bootstrap()
        try await engine.start(adapter: adapter, workspace: workspace)

        #expect(adapter.emit(.sessionStarted(
            sessionID: "session-4",
            model: nil,
            cwd: workspace
        )))
        try await Task.sleep(for: .milliseconds(20))

        let activated = await engine.activate(
            key: AgentRuntimeKey(projectPath: workspace.path, agentID: adapter.id),
            resumeSessionID: "session-4"
        )

        #expect(activated)
        #expect(adapter.recorded.contains(
            .persistedParkedSessionWork(sessionID: "session-4")
        ))
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("session catalog mutations publish once after the debounce window")
    func sessionCatalogPublishingIsDebounced() async throws {
        let clock = FakeClock()
        let engine = AgentEngine(seams: Seams(
            clock: clock,
            random: FakeRandomSource(),
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem()
        ))
        let root = TestPaths.underTemporary("engine-session-catalog-debounce")
        try await engine.transcriptRepository.registerSession(
            "session-5",
            namespace: AgentID.claudeCode.rawValue,
            agentID: .claudeCode,
            in: root
        )

        await engine.scheduleStoredSessionsPublish(in: root)
        await engine.scheduleStoredSessionsPublish(in: root)
        for _ in 0..<20 where clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        #expect(clock.pendingSleepCount >= 1)
        clock.advance(by: SessionCatalogTiming.mutationRepublishDebounce)
        try await Task.sleep(for: .milliseconds(20))

        let listedCount = await engine.bus.historySnapshot.reduce(into: 0) { count, item in
            if case .sessionsListed = item.event {
                count += 1
            }
        }
        #expect(listedCount == 1)
        try await engine.transcriptRepository.shutdown()
    }
}
