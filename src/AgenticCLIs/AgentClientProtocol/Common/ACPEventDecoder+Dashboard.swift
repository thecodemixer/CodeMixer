import Foundation

import AgentCore
import AgentProtocol

/// Initialize-time dashboard bootstrap (`agentDashboard`, auth) and the
/// session-metadata bookkeeping — archived / overview / needsAttention —
/// that feeds `sessionAttentionChanged` for the
/// session navigator's attention rollup. See `AgenticCLIs/README.md` and
/// `AGENTS.md`'s "ACP dashboard / attention / parked permissions" row.
extension ACPEventDecoder {
    func handleInitialize(result: JSONValue?) async -> Batch {
        state.setAgentCapabilities(result?["agentCapabilities"])
        let parsed = ACPInitializeResult.parse(result)
        var events: [AgentEvent] = []
        if let url = parsed.dashboardURL {
            events.append(.agentDashboard(url: url, title: parsed.dashboardTitle))
        }
        if let methodID = parsed.authMethodID {
            return Batch(
                events: events,
                replies: [
                    ACPInputEncoding.authenticate(methodID: methodID, state: state),
                ]
            )
        }
        let post = postInitializeBatch()
        return Batch(events: events + post.events, replies: post.replies)
    }

    func postInitializeBatch() -> Batch {
        var events: [AgentEvent] = []
        if let resume = ACPInputEncoding.resumeUnsupportedAfterInitialize(state: state) {
            events.append(.error(ACPAgentError.resumeUnsupported(sessionID: resume).agentError))
        }
        return Batch(
            events: events,
            replies: [ACPInputEncoding.postInitialize(state: state)]
        )
    }

    func sessionInfoUpdate(params: JSONValue, update: JSONValue) async -> Batch {
        let sessionID = params["sessionId"]?.stringValue ?? state.sessionID()
        guard let sessionID else { return Batch() }
        let title = update["title"]?.stringValue
        await updateSessionMetadata(.registered(sessionID: sessionID,
                                                title: title))
        var events: [AgentEvent] = []
        var replies: [Data] = []
        let meta = update["_meta"]?.objectValue ?? params["_meta"]?.objectValue
        if let archived = meta?["archived"]?.boolValue {
            if archived {
                await updateSessionMetadata(.archived(sessionID: sessionID))
            } else {
                await updateSessionMetadata(.unarchived(sessionID: sessionID))
            }
            if archived {
                // Migration Restart archives file sessions — drop parked reviews
                // and cancel any open permission RPCs so timeouts cannot auto-deny
                // into a restarted pipeline.
                let dropped = state.clearParkedPermissions(sessionID: sessionID)
                for parked in dropped {
                    events.append(.permissionAlreadyResolved(
                        id: parked.prompt.id,
                        byDevice: "session-archived"
                    ))
                    replies.append(ACPInputEncoding.permissionResponse(
                        id: parked.requestID,
                        optionID: nil,
                        cancelled: true
                    ))
                }
                if sessionID == state.sessionID() {
                    for pending in state.takeAllPendingApprovals() {
                        events.append(.permissionAlreadyResolved(
                            id: pending.promptID,
                            byDevice: "session-archived"
                        ))
                        replies.append(ACPInputEncoding.permissionResponse(
                            id: pending.approval.requestID,
                            optionID: nil,
                            cancelled: true
                        ))
                    }
                }
            }
        }
        if let needsAttention = meta?["needsAttention"]?.boolValue {
            let resolvedTitle: String
            if let title, !title.isEmpty {
                resolvedTitle = title
            } else {
                resolvedTitle = sessionID
            }
            events.append(.sessionAttentionChanged(
                sessionID: sessionID,
                title: resolvedTitle,
                needsAttention: needsAttention
            ))
        }
        if let isOverview = meta?["codemixer.dev/overviewSession"]?.boolValue
            ?? meta?["overviewSession"]?.boolValue {
            if isOverview {
                let overviewURL = meta?["codemixer.dev/dashboardUrl"]?.stringValue
                    .flatMap(URL.init(string:))
                await updateSessionMetadata(.markAsOverview(sessionID: sessionID,
                                                            url: overviewURL))
            } else {
                await updateSessionMetadata(.unmarkAsOverview(sessionID: sessionID))
            }
        }
        return Batch(events: events, replies: replies)
    }
}
