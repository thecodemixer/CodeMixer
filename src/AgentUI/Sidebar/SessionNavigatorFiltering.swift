import Foundation

import AgentCore

/// Pure helpers for the session navigator — overview row vs chat list.
enum SessionNavigatorFiltering {
    /// Chat rows under a project. Hides the overview/control session and any
    /// orphaned control chats that share its title (including before
    /// `dashboardTitle` arrives from `agentDashboard`).
    static func chatSessions(from sessions: [SessionSummary],
                             dashboardTitle: String?) -> [SessionSummary] {
        let overviewTitles = Set(
            sessions.filter(\.isOverview).map(\.title).filter { !$0.isEmpty }
        )
        var hiddenTitles = overviewTitles
        if let dashboardTitle, !dashboardTitle.isEmpty {
            hiddenTitles.insert(dashboardTitle)
        }
        return sessions.filter { session in
            if session.isOverview { return false }
            if hiddenTitles.contains(session.title) { return false }
            return true
        }
    }

    /// At most one overview session in the navigator list.
    static func preferringSingleOverview(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let overviews = sessions.filter(\.isOverview)
        guard overviews.count > 1 else { return sessions }
        let keeper = overviews.first(where: { $0.overviewURL != nil }) ?? overviews[0]
        return sessions.filter { !$0.isOverview || $0.id == keeper.id }
    }
}
