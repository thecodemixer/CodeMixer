import Foundation

import AgentCore

/// Pure helpers for the session navigator — overview row vs chat list.
enum SessionNavigatorFiltering {
    /// Chat rows under a project. Hides the overview/control session, any
    /// orphaned control chats that share its title (including before
    /// `dashboardTitle` arrives from `agentDashboard`), and archived sessions.
    ///
    /// Archived rows are dropped because archiving is how an agent retires a
    /// session it no longer owns — a migration Restart archives every per-file
    /// session so the navigator reflects the new run, not the superseded one.
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
            if session.archived { return false }
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
