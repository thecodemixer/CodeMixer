import Foundation
import Testing
@testable import ClaudeCode
import AgentCore
import AgentProtocol
import AgentTestSupport


@Suite("ClaudeAdapter — hook-driven event stream")
struct ClaudeAdapterEventStreamTests {

    @Test("SessionStart hook binds the tailer before Stop drains the transcript")
    func sessionStartBindsTailerBeforeStopDrain() async throws {
        let fileSystem = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/tmp/codemixer-adapter-event")
        let environment = FakeEnvironment(home: home)
        let workspace = URL(fileURLWithPath: "/tmp/codemixer-workspace")
        let sessionID = "hook-session"
        let projects = ClaudeProjectPaths.projectDirectory(for: workspace,
                                                           claudeDirectory: environment.claudeDirectory)
        try fileSystem.createDirectory(at: projects, withIntermediates: true)

        var hookContinuation: AsyncStream<HookRequest>.Continuation!
        let hookStream = AsyncStream<HookRequest> { hookContinuation = $0 }
        let hookHandle = HookSocketHandle(incoming: hookStream, respond: { _, _ in })
        let adapter = ClaudeAdapter(environment: environment, fileSystem: fileSystem)
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: AsyncStream { $0.finish() },
            terminal: EmptyScreen(),
            hookSocket: hookHandle,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        ))

        hookContinuation.yield(HookRequest(id: UUID(),
                                           eventName: "SessionStart",
                                           jsonPayload: Data(#"{"session_id":"hook-session","cwd":"/tmp/codemixer-workspace"}"#.utf8)))
        try fileSystem.writeAtomically(
            Data(#"{"type":"assistant","uuid":"answer-1","sessionId":"hook-session","message":{"role":"assistant","content":[{"type":"text","text":"hook-bound reply"}]}}"#.utf8),
            to: projects.appendingPathComponent("\(sessionID).jsonl")
        )
        hookContinuation.yield(HookRequest(id: UUID(),
                                           eventName: "Stop",
                                           jsonPayload: Data(#"{"hook_event_name":"Stop"}"#.utf8)))

        let event = await nextAssistantText(from: stream)
        guard case .assistantText(_, _, "hook-bound reply", true)? = event else {
            Issue.record("expected assistantText, got \(String(describing: event))")
            return
        }
        hookContinuation.finish()
    }

    @Test("Stop hook with session_id drains the exact fresh transcript without SessionStart")
    func stopHookSessionIDBindsFreshTranscript() async throws {
        let fileSystem = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/tmp/codemixer-adapter-stop")
        let environment = FakeEnvironment(home: home)
        let workspace = URL(fileURLWithPath: "/tmp/codemixer-workspace")
        let sessionID = "stop-session"
        let projects = ClaudeProjectPaths.projectDirectory(for: workspace,
                                                           claudeDirectory: environment.claudeDirectory)
        try fileSystem.createDirectory(at: projects, withIntermediates: true)

        var hookContinuation: AsyncStream<HookRequest>.Continuation!
        let hookStream = AsyncStream<HookRequest> { hookContinuation = $0 }
        let hookHandle = HookSocketHandle(incoming: hookStream, respond: { _, _ in })
        let adapter = ClaudeAdapter(environment: environment, fileSystem: fileSystem)
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: AsyncStream { $0.finish() },
            terminal: EmptyScreen(),
            hookSocket: hookHandle,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        ))

        try fileSystem.writeAtomically(
            Data(#"{"type":"assistant","uuid":"answer-2","sessionId":"stop-session","message":{"role":"assistant","content":[{"type":"text","text":"stop-bound reply"}]}}"#.utf8),
            to: projects.appendingPathComponent("\(sessionID).jsonl")
        )
        hookContinuation.yield(HookRequest(id: UUID(),
                                           eventName: "Stop",
                                           jsonPayload: Data(#"{"hook_event_name":"Stop","session_id":"stop-session"}"#.utf8)))

        let event = await nextAssistantText(from: stream)
        guard case .assistantText(_, _, "stop-bound reply", true)? = event else {
            Issue.record("expected assistantText, got \(String(describing: event))")
            return
        }
        hookContinuation.finish()
    }

    @Test("Stop last_assistant_message is dropped when transcript already supplied assistantText")
    func stopDropsDuplicateAssistantFromHook() async throws {
        let fileSystem = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/tmp/codemixer-adapter-dedup")
        let environment = FakeEnvironment(home: home)
        let workspace = URL(fileURLWithPath: "/tmp/codemixer-workspace")
        let sessionID = "dedup-session"
        let projects = ClaudeProjectPaths.projectDirectory(for: workspace,
                                                           claudeDirectory: environment.claudeDirectory)
        try fileSystem.createDirectory(at: projects, withIntermediates: true)

        var hookContinuation: AsyncStream<HookRequest>.Continuation!
        let hookStream = AsyncStream<HookRequest> { hookContinuation = $0 }
        let hookHandle = HookSocketHandle(incoming: hookStream, respond: { _, _ in })
        let adapter = ClaudeAdapter(environment: environment, fileSystem: fileSystem)
        let stream = adapter.makeEventStream(inputs: AgentInputs(
            outputBytes: AsyncStream { $0.finish() },
            terminal: EmptyScreen(),
            hookSocket: hookHandle,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        ))

        hookContinuation.yield(HookRequest(id: UUID(),
                                           eventName: "SessionStart",
                                           jsonPayload: Data(#"{"session_id":"dedup-session","cwd":"/tmp/codemixer-workspace"}"#.utf8)))
        try fileSystem.writeAtomically(
            Data(#"{"type":"assistant","uuid":"answer-dedup","sessionId":"dedup-session","message":{"role":"assistant","content":[{"type":"text","text":"transcript reply"}]}}"#.utf8),
            to: projects.appendingPathComponent("\(sessionID).jsonl")
        )
        hookContinuation.yield(HookRequest(id: UUID(),
                                           eventName: "Stop",
                                           jsonPayload: Data(#"{"hook_event_name":"Stop","session_id":"dedup-session","last_assistant_message":"hook duplicate"}"#.utf8)))

        let event = await nextAssistantText(from: stream)
        guard case .assistantText(_, _, let text, true)? = event else {
            Issue.record("expected assistantText, got \(String(describing: event))")
            hookContinuation.finish()
            return
        }
        #expect(text == "transcript reply")
        hookContinuation.finish()
    }
}

private struct EmptyScreen: TerminalSnapshotting {
    func snapshotRows() async -> [String] { [] }
    func snapshotText() async -> String { "" }
    func cursorRow() async -> Int { 0 }
}

private func nextAssistantText(from stream: AsyncStream<AgentEvent>) async -> AgentEvent? {
    await withTaskGroup(of: AgentEvent?.self) { group in
        group.addTask {
            for await event in stream {
                if case .assistantText = event { return event }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(500))
            return nil
        }
        let event = await group.next() ?? nil
        group.cancelAll()
        return event
    }
}
