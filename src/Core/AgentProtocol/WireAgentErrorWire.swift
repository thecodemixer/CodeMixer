import Foundation

/// Stable wire codes for `WireAgentError.code`.
///
/// These strings are part of the remote protocol contract — bump `WireVersion`
/// when adding or renaming a case.
public enum WireAgentErrorCode: String, Sendable, CaseIterable {
    case binaryNotFound = "binary_not_found"
    case spawnFailed = "spawn_failed"
    case hookSocketFailed = "hook_socket_failed"
    case transcriptDecodeFailed = "transcript_decode_failed"
    case workspaceInvalid = "workspace_invalid"
    case authenticationRequired = "auth_required"
    case staleEditTarget = "stale_edit_target"
    case unsupportedCommand = "unsupported_command"
    case gitCheckoutFailed = "git_checkout_failed"
    case hunkRevertFailed = "hunk_revert_failed"
    case attachmentNotFound = "attachment_not_found"
    case engineRestartLimitReached = "engine_restart_limit"
    case permissionTimeout = "permission_timeout"
    case internalInvariant = "internal_invariant"
    case unsupportedOperation = "unsupported_operation"
}

/// Keys for `WireAgentError.context` entries paired with `WireAgentErrorCode`.
public enum WireAgentErrorContextKey: String, Sendable {
    case agentID
    case hint
    case errno
    case detail
    case path
    case targetID
    case name
    case hunkID
    case id
    case promptID
    case action
}

/// Typed builder and view over `WireAgentError.context`.
public struct WireAgentErrorContext: Sendable, Hashable {
    private var storage: [WireAgentErrorContextKey: String] = [:]

    public init() {}

    public init(_ dictionary: [String: String]) {
        for (rawKey, value) in dictionary {
            guard let key = WireAgentErrorContextKey(rawValue: rawKey) else { continue }
            storage[key] = value
        }
    }

    public subscript(_ key: WireAgentErrorContextKey) -> String? {
        get { storage[key] }
        set {
            if let newValue {
                storage[key] = newValue
            } else {
                storage.removeValue(forKey: key)
            }
        }
    }

    public var dictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: storage.map { ($0.key.rawValue, $0.value) })
    }
}
