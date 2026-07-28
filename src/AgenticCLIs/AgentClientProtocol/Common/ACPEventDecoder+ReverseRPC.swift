import Foundation

import AgentCore
import AgentProtocol

/// Agent-initiated server requests that Codemixer answers as the reverse
/// RPC peer: creating a session record for `session/new`, and delegating
/// `fs/*` / `terminal/*` to their dedicated handlers. `request_permission`
/// is dispatched here but implemented in `+Permission`.
extension ACPEventDecoder {
    func serverRequest(id: JSONValue,
                       method: String,
                       params: JSONValue) async -> Batch {
        switch method {
        case "session/new":
            return await reverseSessionNew(id: id, params: params)
        case "request_permission", "session/request_permission":
            return await permissionRequest(id: id, params: params)
        case "fs/read_text_file":
            return await fileAccess.read(id: id, params: params)
        case "fs/write_text_file":
            return await fileAccess.write(id: id, params: params)
        case "terminal/create":
            return await terminals.create(id: id, params: params)
        case "terminal/output":
            return await terminals.output(id: id, params: params)
        case "terminal/wait_for_exit":
            return await terminals.waitForExit(id: id, params: params)
        case "terminal/kill":
            return await terminals.kill(id: id, params: params)
        case "terminal/release":
            return await terminals.release(id: id, params: params)
        default:
            return Batch(
                events: [.error(ACPAgentError.unknownServerRequest(method: method).agentError)],
                replies: [
                    ACPRPCCodec.errorResponse(
                        id: id,
                        code: -32601,
                        message: "Unsupported server request: \(method)"
                    ),
                ]
            )
        }
    }

    func reverseSessionNew(id: JSONValue, params: JSONValue) async -> Batch {
        guard state.currentContext() != nil else {
            return Batch(
                replies: [
                    ACPRPCCodec.errorResponse(
                        id: id,
                        code: -32_602,
                        message: "Missing session context"
                    ),
                ]
            )
        }
        guard let sessionID = params["sessionId"]?.stringValue, !sessionID.isEmpty else {
            return Batch(
                replies: [
                    ACPRPCCodec.errorResponse(
                        id: id,
                        code: -32_602,
                        message: "Missing sessionId"
                    ),
                ]
            )
        }
        let title = params["title"]?.stringValue
        let meta = params["_meta"]?.objectValue
        await updateSessionMetadata(.registered(sessionID: sessionID,
                                                title: title))
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
        if let archived = meta?["archived"]?.boolValue {
            if archived {
                await updateSessionMetadata(.archived(sessionID: sessionID))
            } else {
                await updateSessionMetadata(.unarchived(sessionID: sessionID))
            }
        }
        var events: [AgentEvent] = []
        if let needsAttention = meta?["needsAttention"]?.boolValue {
            events.append(.sessionAttentionChanged(sessionID: sessionID,
                                                   title: title ?? sessionID,
                                                   needsAttention: needsAttention))
        }
        return Batch(
            events: events,
            replies: [ACPRPCCodec.response(id: id, result: .object([:]))]
        )
    }
}
