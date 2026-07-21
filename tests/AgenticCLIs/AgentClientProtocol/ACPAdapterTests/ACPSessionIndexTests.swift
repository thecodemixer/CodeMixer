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
        let workspace = TestPaths.underTemporary("acp-ws")
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
        let workspace = TestPaths.underTemporary("acp-ws")
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
        let workspace = TestPaths.underTemporary("acp-ws")
        await index.recordSession(id: "old", customAgentID: "cursor", workspace: workspace, title: "Old")
        clock.advance(by: .seconds(30))
        await index.recordSession(id: "new", customAgentID: "cursor", workspace: workspace, title: "New")
        let summaries = await index.summaries(workspace: workspace, customAgentID: "cursor")
        #expect(summaries.map(\.id) == ["new", "old"])
    }

    @Test("recordSession preserves overview and attention flags across list merges")
    func recordSessionPreservesOverviewFlags() async {
        let env = FakeEnvironment()
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let index = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        let workspace = TestPaths.underTemporary("acp-ws")
        await index.recordSession(
            id: "control",
            customAgentID: "cursor",
            workspace: workspace,
            title: "Migration Dashboard"
        )
        await index.setIsOverview(
            sessionID: "control",
            customAgentID: "cursor",
            isOverview: true,
            overviewURL: URL(string: "http://127.0.0.1:9/")
        )
        await index.setNeedsAttention(sessionID: "control", customAgentID: "cursor", needsAttention: true)
        await index.recordSession(
            id: "control",
            customAgentID: "cursor",
            workspace: workspace,
            title: "Migration Dashboard"
        )
        let summaries = await index.summaries(workspace: workspace, customAgentID: "cursor")
        let control = summaries.first { $0.id == "control" }
        #expect(control?.isOverview == true)
        #expect(control?.needsAttention == true)
        #expect(control?.overviewURL?.absoluteString == "http://127.0.0.1:9/")
    }

    @Test("setIsOverview keeps a single overview and archives same-title controls")
    func setIsOverviewDedupesControls() async {
        let env = FakeEnvironment()
        let fs = InMemoryFileSystem()
        let clock = FakeClock()
        let index = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        let workspace = TestPaths.underTemporary("acp-ws")
        await index.recordSession(
            id: "old",
            customAgentID: "cursor",
            workspace: workspace,
            title: "Migration Dashboard"
        )
        await index.setIsOverview(
            sessionID: "old",
            customAgentID: "cursor",
            isOverview: true,
            overviewURL: URL(string: "http://127.0.0.1:8/")
        )
        await index.recordSession(
            id: "new",
            customAgentID: "cursor",
            workspace: workspace,
            title: "Migration Dashboard"
        )
        await index.setIsOverview(
            sessionID: "new",
            customAgentID: "cursor",
            isOverview: true,
            overviewURL: URL(string: "http://127.0.0.1:9/")
        )
        let summaries = await index.summaries(workspace: workspace, customAgentID: "cursor")
        #expect(summaries.map(\.id) == ["new"])
        #expect(summaries.first?.isOverview == true)
    }
}
