import Foundation
import AgentProtocol

/// Rich error type emitted on the event stream.
///
/// Each case carries enough context that the UI can render a useful message
/// and the wire codec can translate to `WireAgentError` without losing
/// information.
public enum AgentError: Error, Sendable, Equatable {
    case binaryNotFound(agentID: AgentID, hint: String)
    case spawnFailed(errno: Int32, detail: String)
    case hookSocketFailed(detail: String)
    case transcriptDecodeFailed(path: String, detail: String)
    case workspaceInvalid(path: String, detail: String)
    case authenticationRequired(agentID: AgentID)
    case staleEditTarget(targetID: UUID)
    case unsupportedCommand(name: String)
    case gitCheckoutFailed(path: String, detail: String)
    case hunkRevertFailed(path: String, hunkID: UUID, detail: String)
    case attachmentNotFound(id: String)
    case engineRestartLimitReached
    case permissionTimeout(promptID: UUID, action: PermissionDecision)
    case internalInvariant(detail: String)
    case unsupportedOperation(detail: String)

    /// Stable string code for wire transport and log filtering.
    public var code: String { wireCode.rawValue }

    /// Typed wire code paired with `WireAgentError.context` keys.
    public var wireCode: WireAgentErrorCode {
        switch self {
        case .binaryNotFound:            return .binaryNotFound
        case .spawnFailed:               return .spawnFailed
        case .hookSocketFailed:          return .hookSocketFailed
        case .transcriptDecodeFailed:    return .transcriptDecodeFailed
        case .workspaceInvalid:          return .workspaceInvalid
        case .authenticationRequired:    return .authenticationRequired
        case .staleEditTarget:           return .staleEditTarget
        case .unsupportedCommand:        return .unsupportedCommand
        case .gitCheckoutFailed:         return .gitCheckoutFailed
        case .hunkRevertFailed:          return .hunkRevertFailed
        case .attachmentNotFound:        return .attachmentNotFound
        case .engineRestartLimitReached: return .engineRestartLimitReached
        case .permissionTimeout:         return .permissionTimeout
        case .internalInvariant:         return .internalInvariant
        case .unsupportedOperation:      return .unsupportedOperation
        }
    }

    public var userMessage: String {
        switch self {
        case .binaryNotFound(let id, let hint):
            return "Couldn't find the \(id.rawValue) binary. \(hint)"
        case .spawnFailed(_, let detail):
            return "Failed to start the agent: \(detail)"
        case .hookSocketFailed(let detail):
            return "Couldn't open the hook socket: \(detail)"
        case .transcriptDecodeFailed(let path, _):
            return "Couldn't parse the session transcript at \(path)."
        case .workspaceInvalid(let path, _):
            return "The workspace at \(path) isn't usable."
        case .authenticationRequired(let id):
            return "\(id.rawValue) needs to be signed in."
        case .staleEditTarget:
            return "The message you tried to edit was already replaced."
        case .unsupportedCommand(let name):
            return "Command \"\(name)\" isn't supported by this agent."
        case .gitCheckoutFailed(let path, let detail):
            return "Couldn't revert \(path): \(detail)"
        case .hunkRevertFailed(let path, _, let detail):
            return "Couldn't revert part of \(path): \(detail)"
        case .attachmentNotFound(let id):
            return "Attachment \(id) is no longer available."
        case .engineRestartLimitReached:
            return "The agent crashed too many times in a short window."
        case .permissionTimeout(_, let action):
            return "Permission request timed out — auto-\(action.rawValue)."
        case .internalInvariant(let detail):
            return "Internal error: \(detail)"
        case .unsupportedOperation(let detail):
            return detail
        }
    }
}
