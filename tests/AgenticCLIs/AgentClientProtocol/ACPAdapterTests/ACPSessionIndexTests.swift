@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport
import Foundation
import Testing

@Suite("ACP session index")
struct ACPSessionIndexTests {

    @Test("recordTurn increments message count and updates title")
    func recordTurn() async {
        let env = FakeEnvironment()
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let index = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        let workspace = URL(fileURLWithPath: "/tmp/acp-ws")
        await index.recordSession(
            id: "s1",
            customAgentID: "cursor",
            workspace: workspace,
            title: "s1"
        )
        await index.recordTurn(sessionID: "s1", customAgentID: "cursor", title: "First prompt")
        let summaries = await index.summaries(workspace: workspace, customAgentID: "cursor")
        #expect(summaries.count == 1)
        #expect(summaries.first?.title == "First prompt")
        #expect(summaries.first?.messageCount == 1)
    }

    @Test("summaries filter by workspace and custom agent id")
    func summariesFilter() async {
        let env = FakeEnvironment()
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let index = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        let wsA = URL(fileURLWithPath: "/tmp/ws-a")
        let wsB = URL(fileURLWithPath: "/tmp/ws-b")
        await index.recordSession(id: "a1", customAgentID: "cursor", workspace: wsA, title: "A")
        await index.recordSession(id: "b1", customAgentID: "cursor", workspace: wsB, title: "B")
        await index.recordSession(id: "a2", customAgentID: "other", workspace: wsA, title: "Other")
        let cursorA = await index.summaries(workspace: wsA, customAgentID: "cursor")
        #expect(cursorA.map(\.id) == ["a1"])
    }

    @Test("session index persists across instances")
    func persistence() async throws {
        let env = FakeEnvironment()
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let workspace = URL(fileURLWithPath: "/tmp/acp-ws")
        let first = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        await first.recordSession(
            id: "persisted",
            customAgentID: "cursor",
            workspace: workspace,
            title: "Saved"
        )
        let second = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        let summaries = await second.summaries(workspace: workspace, customAgentID: "cursor")
        #expect(summaries.contains { $0.id == "persisted" && $0.title == "Saved" })
    }

    @Test("summaries sort by most recent activity")
    func sortOrder() async {
        let env = FakeEnvironment()
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let index = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        let workspace = URL(fileURLWithPath: "/tmp/acp-ws")
        await index.recordSession(id: "old", customAgentID: "cursor", workspace: workspace, title: "Old")
        clock.advance(by: .seconds(30))
        await index.recordSession(id: "new", customAgentID: "cursor", workspace: workspace, title: "New")
        let summaries = await index.summaries(workspace: workspace, customAgentID: "cursor")
        #expect(summaries.map(\.id) == ["new", "old"])
    }
}
