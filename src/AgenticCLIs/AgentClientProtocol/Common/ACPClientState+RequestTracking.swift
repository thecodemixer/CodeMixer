import Foundation

import AgentCore
import AgentProtocol

/// The outgoing-RPC-id → `RequestPurpose` map: every request Codemixer sends
/// gets a fresh id here so `+Session`'s `response(id:result:error:)` can look
/// up what the reply is for.
extension ACPClientState {
    func nextRequestID(for purpose: RequestPurpose) -> JSONValue {
        withLock {
            let id = JSONValue.number(Double(nextID))
            nextID += 1
            requests[id] = purpose
            return id
        }
    }

    func takePurpose(for id: JSONValue) -> RequestPurpose? {
        withLock { requests.removeValue(forKey: id) }
    }

    /// True while an ordinary `session/prompt` (user text) is outstanding.
    /// v0.9.1 has no A2UI action id/acknowledgement, so a validated action
    /// sent mid-turn could race the agent's own response; disable server
    /// `event` actions for that window instead (plan §3) rather than queue
    /// them behind the active prompt.
    func hasActivePrompt() -> Bool {
        withLock { requests.values.contains(.sessionPrompt) }
    }
}
