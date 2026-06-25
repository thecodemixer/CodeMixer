import Foundation
import AgentCore

/// Claude Code's built-in slash-command catalog.
///
/// The adapter and digital twin both expose this list so UI tests and live
/// sessions render the same command palette.
public enum ClaudeBuiltInSlashCommands {
    public static let all: [SlashCommand] = [
        SlashCommand(id: "claude.help",        name: "/help",        summary: "Show available commands."),
        SlashCommand(id: "claude.clear",       name: "/clear",       summary: "Start a new conversation."),
        SlashCommand(id: "claude.compact",     name: "/compact",     summary: "Summarize older context."),
        SlashCommand(id: "claude.resume",      name: "/resume",      summary: "Resume a previous session."),
        SlashCommand(id: "claude.model",       name: "/model",       summary: "Pick a model."),
        SlashCommand(id: "claude.permission",  name: "/permission",  summary: "Change permission policy."),
        SlashCommand(id: "claude.permissions", name: "/permissions", summary: "Manage tool permissions."),
        SlashCommand(id: "claude.usage",       name: "/usage",       summary: "Show usage and cost."),
        SlashCommand(id: "claude.cost",        name: "/cost",        summary: "Show running cost."),
        SlashCommand(id: "claude.login",       name: "/login",       summary: "Authenticate."),
        SlashCommand(id: "claude.logout",      name: "/logout",      summary: "Sign out."),
        SlashCommand(id: "claude.status",      name: "/status",      summary: "Show session status."),
        SlashCommand(id: "claude.think",       name: "/think",       summary: "Toggle extended thinking."),
        SlashCommand(id: "claude.review",      name: "/review",      summary: "Review uncommitted changes."),
        SlashCommand(id: "claude.interrupt",   name: "/interrupt",   summary: "Stop current turn."),
        SlashCommand(id: "claude.quit",        name: "/quit",        summary: "Exit Claude."),
    ]
}
