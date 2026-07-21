import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore

@Suite("Session navigator filtering")
struct SessionNavigatorFilteringTests {

    @Test("chat list hides overview rows and same-title orphans before dashboardTitle arrives")
    func hidesOverviewOrphansWithoutHostedTitle() {
        let workspace = URL(fileURLWithPath: "/tmp/mig")
        let sessions = [
            SessionSummary(
                id: "control-new",
                agentID: .other,
                workspace: workspace,
                title: "Migration Dashboard",
                lastActivity: Date(timeIntervalSince1970: 2),
                messageCount: 1,
                isOverview: true,
                overviewURL: URL(string: "http://127.0.0.1:9/")
            ),
            SessionSummary(
                id: "control-old",
                agentID: .other,
                workspace: workspace,
                title: "Migration Dashboard",
                lastActivity: Date(timeIntervalSince1970: 1),
                messageCount: 1,
                isOverview: false
            ),
            SessionSummary(
                id: "file:Orders.cs",
                agentID: .other,
                workspace: workspace,
                title: "Orders.cs",
                lastActivity: Date(timeIntervalSince1970: 3),
                messageCount: 2
            ),
        ]
        let chats = SessionNavigatorFiltering.chatSessions(from: sessions, dashboardTitle: nil)
        #expect(chats.map(\.id) == ["file:Orders.cs"])
    }

    @Test("preferringSingleOverview keeps the overview that has a dashboard URL")
    func prefersOverviewWithURL() {
        let workspace = URL(fileURLWithPath: "/tmp/mig")
        let sessions = [
            SessionSummary(
                id: "a",
                agentID: .other,
                workspace: workspace,
                title: "Migration Dashboard",
                lastActivity: Date(timeIntervalSince1970: 2),
                messageCount: 1,
                isOverview: true
            ),
            SessionSummary(
                id: "b",
                agentID: .other,
                workspace: workspace,
                title: "Migration Dashboard",
                lastActivity: Date(timeIntervalSince1970: 1),
                messageCount: 1,
                isOverview: true,
                overviewURL: URL(string: "http://127.0.0.1:9/")
            ),
        ]
        let kept = SessionNavigatorFiltering.preferringSingleOverview(sessions)
        #expect(kept.map(\.id) == ["b"])
    }
}
