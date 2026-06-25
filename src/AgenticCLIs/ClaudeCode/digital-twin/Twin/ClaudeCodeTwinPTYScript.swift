import Foundation

/// PTY/TUI frames the twin prints so `ClaudeTUIFallback` and resume heuristics parse them.
public enum ClaudeCodeTwinPTYScript: Sendable {
    public static let promptReady = "❯ \n"
    /// Matches `AgentEngine.rowsContainClaudeReadyPrompt`: empty `❯` row plus a
    /// footer row containing `for shortcuts`.
    public static let startupPromptReady = "❯ \n? for shortcuts\n"
    public static let promptWithShortcutFooter = "for shortcuts\n> \n"
    public static let authURL = "Visit https://claude.ai/oauth/authorize?code=twin-test to authenticate\n"
    public static let statusWorking = "Working…\n"

    public static func workspaceTrust(workspace: String) -> String {
        """
        Quick safety check: Is this a project you trust?
        Accessing workspace:
        \(workspace)
        Claude Code'll be able to read, edit, and execute files here.
        1. Yes, I trust this folder
        2. No, exit
        """
    }

    public static func unsubmittedPrompt(_ text: String) -> String {
        "❯ \(text)\n"
    }

    public static func banner(sessionID: String) -> String {
        """
        fake-claude (Codemixer digital twin)
        Session: \(sessionID)
        """
    }
}
