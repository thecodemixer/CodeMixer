import Foundation

import AgentCore
import AgentProtocol

/// Converts ACP responses, notifications, and server requests into Codemixer
/// events plus protocol replies that must be written back.
///
/// A thin orchestrator: `decode(_:)` dispatches to one of five same-actor
/// extensions in this directory — `+Session` (open/list/resume a session and
/// finalize a prompt turn), `+Dashboard` (initialize bootstrap, dashboard URL,
/// and the session-metadata bookkeeping — archived/overview/needsAttention —
/// that feeds `sessionIndexChanged`/`sessionAttentionChanged`), `+Streaming`
/// (`session/update` notifications: message/thought chunks, tool call
/// lifecycle, foreign-session caching), `+Permission` (permission-request
/// server calls), and `+ReverseRPC` (the remaining agent-initiated server
/// requests: `session/new`, `fs/*`, `terminal/*`).
public actor ACPEventDecoder {
    public struct Batch: Sendable {
        public let events: [AgentEvent]
        public let replies: [Data]

        public init(events: [AgentEvent] = [], replies: [Data] = []) {
            self.events = events
            self.replies = replies
        }
    }

    /// Non-private: read by the `+Session`/`+Dashboard`/`+Streaming`/
    /// `+Permission`/`+ReverseRPC` extensions in the other files in this
    /// directory.
    let state: ACPClientState
    let sessionIndex: any ACPSessionIndexing
    let fileAccess: ACPFileAccess
    let terminals: ACPTerminalSession
    let clock: any AgentClock
    let random: any RandomSource

    public init(state: ACPClientState,
                sessionIndex: any ACPSessionIndexing,
                fileAccess: ACPFileAccess,
                terminals: ACPTerminalSession,
                clock: any AgentClock,
                random: any RandomSource) {
        self.state = state
        self.sessionIndex = sessionIndex
        self.fileAccess = fileAccess
        self.terminals = terminals
        self.clock = clock
        self.random = random
    }

    public func decode(_ incoming: ACPIncoming) async -> Batch {
        switch incoming {
        case .response(let id, let result, let error):
            return await response(id: id, result: result, error: error)
        case .notification(let method, let params):
            return await notification(method: method, params: params)
        case .serverRequest(let id, let method, let params):
            return await serverRequest(id: id, method: method, params: params)
        }
    }

    /// Non-private: shared by `+Streaming`'s foreign-session caching and tool
    /// call handling, and `+Permission`'s argument-summary formatting.
    func stringified(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Non-private: shared by `+Dashboard`'s `sessionInfoUpdate` and
    /// `+Permission`'s background-session attention prompt.
    func sessionTitle(sessionID: String,
                      customAgentID: String,
                      workspace: URL) async -> String? {
        let summaries = await sessionIndex.summaries(
            workspace: workspace,
            customAgentID: customAgentID
        )
        return summaries.first(where: { $0.id == sessionID })?.title
    }
}
