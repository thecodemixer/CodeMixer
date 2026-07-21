import Foundation
import Testing

import AgentCore
import AgentTestSupport
import Codex

@Suite("Codex digital twin")
struct CodexTwinTests {
    @Test("Twin emits a Codex session and final assistant reply")
    func eventProjection() async {
        let replyID = UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1
        ))
        let twin = CodexTwin(
            configuration: .init(
                threadID: "thread-twin",
                model: "gpt-5.4",
                reply: "Twin reply"
            ),
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem(),
            clock: FakeClock(),
            random: FakeRandomSource(uuids: [replyID])
        )
        let workspace = TestPaths.underTemporary("project")
        let stream = twin.makeEventStream(inputs: AgentInputs(
            outputBytes: AsyncStream { $0.finish() },
            terminal: nil,
            hookSocket: nil,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        ))
        var iterator = stream.makeAsyncIterator()

        guard case .sessionStarted(let id, let model, let cwd) = await iterator.next() else {
            Issue.record("Expected sessionStarted")
            return
        }
        guard case .assistantText(_, _, let text, let isFinal) = await iterator.next() else {
            Issue.record("Expected assistantText")
            return
        }

        #expect(id == "thread-twin")
        #expect(model == "gpt-5.4")
        #expect(cwd == workspace)
        #expect(text == "Twin reply")
        #expect(isFinal)
    }

    @Test("Twin resumable sessions retain Codex identity")
    func resumableIdentity() async {
        let twin = CodexTwin(
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem(),
            clock: FakeClock(),
            random: FakeRandomSource()
        )

        let sessions = await twin.listResumableSessions(
            workspace: TestPaths.underTemporary("project")
        )

        #expect(sessions.count == 1)
        #expect(sessions.first?.agentID == .codex)
    }
}
