import Foundation
import AgentCore
import AgentProtocol

/// Claude Code input and permission-response encoding shared by adapter and twin.
public enum ClaudeInputEncoding {
    public static func userPrompt(_ text: String) -> Data {
        Data((text + "\r").utf8)
    }

    public static func cancelSequence() -> Data {
        Data([0x03])
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
        }
    }

    private static func ptyPermissionBytes(for decision: PermissionDecision) -> Data {
        let key: String
        switch decision {
        case .allow:       key = "1\r"
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
