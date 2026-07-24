import Foundation

import AgentCore
import AgentProtocol

/// Initialize-time dashboard bootstrap (`agentDashboard`, auth) and the
/// session-metadata bookkeeping — archived / overview / needsAttention —
/// that feeds `sessionIndexChanged` / `sessionAttentionChanged` for the
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
        guard let context = state.currentContext() else { return Batch() }
        let sessionID = params["sessionId"]?.stringValue ?? state.sessionID()
        guard let sessionID else { return Batch() }
        let title = update["title"]?.stringValue
        await sessionIndex.recordSession(
            id: sessionID,
            customAgentID: context.customAgentID,
            workspace: context.workspace,
            title: title
        )
        var events: [AgentEvent] = []
        var replies: [Data] = []
        let meta = update["_meta"]?.objectValue ?? params["_meta"]?.objectValue
        var didMutateIndex = false
        if let archived = meta?["archived"]?.boolValue {
            await sessionIndex.setArchived(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                archived: archived
            )
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
            didMutateIndex = true
        }
        if let needsAttention = meta?["needsAttention"]?.boolValue {
            await sessionIndex.setNeedsAttention(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                needsAttention: needsAttention
            )
            let resolvedTitle: String
            if let title, !title.isEmpty {
                resolvedTitle = title
            } else {
                resolvedTitle = await sessionTitle(
                    sessionID: sessionID,
                    customAgentID: context.customAgentID,
                    workspace: context.workspace
                ) ?? sessionID
            }
            events.append(.sessionAttentionChanged(
                sessionID: sessionID,
                title: resolvedTitle,
                needsAttention: needsAttention
            ))
            didMutateIndex = true
        }
        if let isOverview = meta?["codemixer.dev/overviewSession"]?.boolValue
            ?? meta?["overviewSession"]?.boolValue {
            let overviewURL = meta?["codemixer.dev/dashboardUrl"]?.stringValue
                .flatMap(URL.init(string:))
            await sessionIndex.setIsOverview(
                sessionID: sessionID,
                customAgentID: context.customAgentID,
                isOverview: isOverview,
                overviewURL: overviewURL
            )
            didMutateIndex = true
        }
        if didMutateIndex || title != nil {
            events.append(.sessionIndexChanged(projectPath: context.workspace))
        }
        return Batch(events: events, replies: replies)
    }
}
