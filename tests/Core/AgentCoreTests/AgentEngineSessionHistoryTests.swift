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
            .userTurn(id: "user-1", text: "Restored prompt"),
            for: key
        )

        await engine.restoreHistory(for: key)
        await engine.bus.publish(.sessionPromptReady(sessionID: key.sessionID))

        let events = await engine.bus.historySnapshot.map(\.event)

        let userIndex = try #require(events.firstIndex {
            if case .userTurn(_, let text) = $0 { return text == "Restored prompt" }
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
        #expect(userIndex < restoredIndex)
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
}
