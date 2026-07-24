import Foundation
import AgentProtocol
import AgentCore

/// Handles JSON-RPC responses to requests the adapter issued: thread
/// start/resume, turn start, and the no-op purposes
/// (`initialize`/`compact`/`review`/`other`) that carry no event.
extension CodexEventDecoder {
    func response(id: JSONValue,
                  result: JSONValue?,
                  error: CodexAppServerIncoming.RPCError?) async -> Batch {
        let purpose = state.takePurpose(for: id)
        if let error {
            return Batch(events: [
                .error(CodexAgentError.rpc(code: error.code, message: error.message).agentError),
            ])
        }
        guard let purpose else { return Batch() }

        switch purpose {
        case .threadStart, .threadResume:
            guard let threadID = result?["thread"]?["id"]?.stringValue else {
                return Batch(events: [.error(CodexAgentError.missingThreadID.agentError)])
            }
            let queuedBatches = state.activateThread(id: threadID)
            await threadIndex.recordThread(id: threadID, workspace: workspace)
            let queued = CodexInputEncoding.queuedTurns(queuedBatches, state: state)
            let replies = queued.isEmpty ? [] : [queued]
            let model = result?["thread"]?["model"]?.stringValue
            var events: [AgentEvent] = [
                .sessionStarted(sessionID: threadID, model: model, cwd: workspace),
            ]
            if let turns = result?["thread"]?["turns"]?.arrayValue, !turns.isEmpty {
                events.append(contentsOf: CodexThreadHistoryReplay.events(from: turns, random: random))
            }
            return Batch(events: events, replies: replies)

        case .turnStart(let title):
            guard let turnID = result?["turn"]?["id"]?.stringValue else {
                return Batch(events: [.error(CodexAgentError.missingTurnID.agentError)])
            }
            state.beginTurn(turnID)
            if let threadID = state.threadID() {
                await threadIndex.recordTurn(threadID: threadID, title: title)
            }
            return Batch()

        case .initialize, .compact, .review, .other:
            return Batch()
        }
    }
}
