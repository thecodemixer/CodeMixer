import Foundation

import AgentCore

/// Failures raised while framing, decoding, or driving Codex App Server.
///
/// The adapter maps every case to `AgentError.unsupportedOperation` at the
/// module boundary so Codex-specific errors never expand AgentCore's error
/// alphabet.
public enum CodexAgentError: Error, Sendable, Equatable {
    case frameTooLarge(bytes: Int)
    case malformedFrame(detail: String)
    case malformedMessage(detail: String)
    case rpc(code: Int, message: String)
    case missingThreadID
    case missingTurnID
    case unknownServerRequest(method: String)
    case persistence(detail: String)

    public var agentError: AgentError {
        .unsupportedOperation(detail: "codex:\(detail)")
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
        case .missingThreadID:
            return "missing-thread-id"
        case .missingTurnID:
            return "missing-turn-id"
        case .unknownServerRequest(let method):
            return "unknown-server-request:\(method)"
        case .persistence(let detail):
            return "persistence:\(detail)"
        }
    }
}
