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
}
