import Foundation
import AgentCore
import AgentProtocol

/// Claude Code input and permission-response encoding shared by adapter and twin.
public enum ClaudeInputEncoding {
    /// Synthetic tool name for Claude's first-open "trust this folder" TUI gate.
    /// Opening a project in Codemixer is the trust decision; adapters auto-allow
    /// and encode allow as `1\r` / deny as `2\r`.
    public static let workspaceTrustToolName = "WorkspaceTrust"

    /// Start of a bracketed-paste block (DECSET 2004), as a real terminal emits
    /// it when the user pastes into the TUI.
    static let pasteStart = "\u{1B}[200~"
    /// End of a bracketed-paste block.
    static let pasteEnd = "\u{1B}[201~"

    /// Single-line prompts go in as typed text plus Enter — the path Claude's
    /// transcript marks `promptSource: "typed"`.
    ///
    /// Multi-line prompts cannot: Claude's TUI reads a fast multi-line burst as
    /// an unbracketed paste, stops treating Enter as submit, and the turn sits
    /// in the input row forever with no error anywhere. Wrapping the block in
    /// bracketed paste makes the boundary explicit — exactly what a terminal
    /// sends on paste, including `\r` for the interior line breaks — so the
    /// trailing Enter submits instead of adding a fourth line.
    public static func userPrompt(_ text: String) -> Data {
        guard text.contains("\n") || text.contains("\r") else {
            return Data((text + "\r").utf8)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\r", with: "") }
        return Data((pasteStart + lines.joined(separator: "\r") + pasteEnd + "\r").utf8)
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
