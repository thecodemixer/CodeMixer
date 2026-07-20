import Foundation

import AgentCore

/// Failures raised while framing, decoding, or driving an ACP agent.
public enum ACPAgentError: Error, Sendable, Equatable {
    case frameTooLarge(bytes: Int)
    case malformedFrame(detail: String)
    case malformedMessage(detail: String)
    case rpc(code: Int, message: String)
    case missingSessionID
    case authenticationRequired(displayName: String)
    case sessionLoadFailed(sessionID: String, message: String)
    case resumeUnsupported(sessionID: String)
    case pathOutsideWorkspace(path: String)
    case unknownServerRequest(method: String)
    case persistence(detail: String)
    case terminal(detail: String)

    public var agentError: AgentError {
        switch self {
        case .authenticationRequired:
            return .authenticationRequired(agentID: .other)
        default:
            return .unsupportedOperation(detail: "acp:\(detail)")
        }
    }

    public var detail: String {
        switch self {
        case .frameTooLarge(let bytes):
            return "frame-too-large:\(bytes)"
        case .malformedFrame(let detail):
            return "malformed-frame:\(detail)"
        case .malformedMessage(let detail):
            return "malformed-message:\(detail)"
        case .rpc(let code, let message):
            return "rpc:\(code):\(message)"
        case .missingSessionID:
            return "missing-session-id"
        case .authenticationRequired(let displayName):
            return "\(displayName) requires authentication. Run its login/auth command in Terminal, then open this project again."
        case .sessionLoadFailed(let sessionID, let message):
            return "session-load-failed:\(sessionID):\(message)"
        case .resumeUnsupported(let sessionID):
            return "resume-unsupported:\(sessionID)"
        case .pathOutsideWorkspace(let path):
            return "path-outside-workspace:\(path)"
        case .unknownServerRequest(let method):
            return "unknown-server-request:\(method)"
        case .persistence(let detail):
            return "persistence:\(detail)"
        case .terminal(let detail):
            return "terminal:\(detail)"
        }
    }
}
