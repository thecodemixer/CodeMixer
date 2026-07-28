import Foundation
import AgentCore
import AgentProtocol

/// Claude Code input and permission-response encoding shared by adapter and twin.
public enum ClaudeInputEncoding {
    /// Synthetic tool name for Claude's first-open "trust this folder" TUI gate.
    /// Opening a project in Codemixer is the trust decision; adapters auto-allow
    /// and encode allow as `1\r` / deny as `2\r`.
    public static let workspaceTrustToolName = "WorkspaceTrust"

    public static func userPrompt(_ text: String) -> Data {
        Data((text + "\r").utf8)
    }

    public static func cancelSequence() -> Data {
        Data([0x03])
    }

    /// Folder-trust gate is already decided by opening the project — return
    /// `.allow` so the engine does not surface the TUI prompt to the UI.
    public static func autoAllowDecision(for prompt: PermissionPrompt) -> PermissionDecision? {
        prompt.toolName == workspaceTrustToolName ? .allow : nil
    }

    public static func permissionResponse(_ decision: PermissionDecision,
                                          for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        if prompt.toolName == workspaceTrustToolName {
            let key = decision == .deny ? "2\r" : "1\r"
            return .writePTY(Data(key.utf8))
        }
        return permissionResponse(decision)
    }

    public static func permissionResponse(_ decision: PermissionDecision) -> PermissionResponseDelivery {
        .both(ptyBytes: ptyPermissionBytes(for: decision),
              hookStdout: hookPermissionJSON(for: decision))
    }

    private static func hookPermissionJSON(for decision: PermissionDecision) -> Data {
        let output = HookResponse(
            hookSpecificOutput: HookSpecificOutput(
                hookEventName: "PreToolUse",
                permissionDecision: hookPermissionDecision(for: decision)
            )
        )
        return (try? JSONEncoder().encode(output)) ?? Data("{}".utf8)
    }

    private static func hookPermissionDecision(for decision: PermissionDecision) -> String {
        switch decision {
        case .allow, .allowAlways:
            return "allow"
        case .deny:
            return "deny"
        case .option:
            return "allow"
        }
    }

    private static func ptyPermissionBytes(for decision: PermissionDecision) -> Data {
        let key: String
        switch decision {
        case .allow, .option: key = "1\r"
        case .allowAlways: key = "2\r"
        case .deny:        key = "3\r"
        }
        return Data(key.utf8)
    }

    private struct HookResponse: Encodable {
        let hookSpecificOutput: HookSpecificOutput
    }

    private struct HookSpecificOutput: Encodable {
        let hookEventName: String
        let permissionDecision: String
    }
}
