import Foundation
import AgentCore

/// Canonical slash-command catalogue Claude Code ships with, materialised
/// in the twin so UI tests can drive `SlashCommandPalette` without a real
/// `claude` binary.
public enum ClaudeCodeTwinSlashCommands {
    public static let builtIn = ClaudeBuiltInSlashCommands.all
}
