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
    case internalInvariant(detail: String)
    case unsupportedOperation(detail: String)

    /// Stable string code for wire transport and log filtering.
    public var code: String {
        switch self {
        case .binaryNotFound:           return "binary_not_found"
        case .spawnFailed:              return "spawn_failed"
        case .hookSocketFailed:         return "hook_socket_failed"
        case .transcriptDecodeFailed:   return "transcript_decode_failed"
        case .workspaceInvalid:         return "workspace_invalid"
        case .authenticationRequired:   return "auth_required"
        case .staleEditTarget:          return "stale_edit_target"
        case .unsupportedCommand:       return "unsupported_command"
        case .gitCheckoutFailed:        return "git_checkout_failed"
        case .hunkRevertFailed:         return "hunk_revert_failed"
        case .attachmentNotFound:       return "attachment_not_found"
        case .engineRestartLimitReached: return "engine_restart_limit"
        case .internalInvariant:        return "internal_invariant"
        case .unsupportedOperation:     return "unsupported_operation"
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
        case .internalInvariant(let detail):
            return "Internal error: \(detail)"
        case .unsupportedOperation(let detail):
            return detail
        }
    }
}
