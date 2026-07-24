import Foundation
import AgentProtocol

import AgentCore

/// Converts Codex App Server responses, notifications, and server requests
/// into Codemixer events plus protocol replies that must be written back.
///
/// A thin orchestrator: `decode(_:)` dispatches to one of three per-concern
/// extensions in this directory — `+ResponseHandler` (thread/turn start RPC
/// responses), `+TurnNotificationHandler` (streaming deltas plus item/turn
/// notifications), `+ApprovalServerRequestHandler` (permission server
/// requests) — with `+ToolItemProjector` shared by the latter two for turning
/// a raw Codex `item` into a tool name, summary, and output.
public actor CodexEventDecoder {
    public struct Batch: Sendable {
        public let events: [AgentEvent]
        public let replies: [Data]

        public init(events: [AgentEvent] = [], replies: [Data] = []) {
            self.events = events
            self.replies = replies
        }
    }

    /// Non-private: read by the `+ResponseHandler`/`+TurnNotificationHandler`/
    /// `+ApprovalServerRequestHandler` extensions in the other files in this
    /// directory.
    let state: CodexSessionState
    let threadIndex: CodexThreadIndex
    let workspace: URL
    let clock: any AgentClock
    let random: any RandomSource

    public init(state: CodexSessionState,
                threadIndex: CodexThreadIndex,
                workspace: URL,
                clock: any AgentClock,
                random: any RandomSource) {
        self.state = state
        self.threadIndex = threadIndex
        self.workspace = workspace
        self.clock = clock
        self.random = random
    }

    public func decode(_ incoming: CodexAppServerIncoming) async -> Batch {
        switch incoming {
        case .response(let id, let result, let error):
            return await response(id: id, result: result, error: error)
        case .notification(let method, let params):
            return await notification(method: method, params: params)
        case .serverRequest(let id, let method, let params):
            return await serverRequest(id: id, method: method, params: params)
        }
    }
}
