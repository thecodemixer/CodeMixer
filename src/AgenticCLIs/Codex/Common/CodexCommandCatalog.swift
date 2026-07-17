import Foundation

import AgentCore

/// Built-in Codex commands exposed by Codemixer's command palette.
public enum CodexCommandCatalog {
    public static let builtIn: [SlashCommand] = [
        SlashCommand(id: "codex.help", name: "/help", summary: "Show available commands."),
        SlashCommand(id: "codex.new", name: "/new", summary: "Start a new thread."),
        SlashCommand(id: "codex.compact", name: "/compact", summary: "Compact thread context."),
        SlashCommand(id: "codex.model", name: "/model", summary: "Pick a model."),
        SlashCommand(id: "codex.permissions", name: "/permissions", summary: "Show permission policy."),
        SlashCommand(id: "codex.review", name: "/review", summary: "Review uncommitted changes."),
        SlashCommand(id: "codex.status", name: "/status", summary: "Show thread status."),
    ]

    public static func projectCommands(workspace: URL,
                                       codexDirectory: URL,
                                       fileSystem: any FileSystem) -> [SlashCommand] {
        let project = workspace.appendingPathComponent(
            ".codex/commands",
            isDirectory: true
        )
        let user = codexDirectory.appendingPathComponent("commands", isDirectory: true)
        return commands(in: project, isProjectDefined: true, fileSystem: fileSystem)
            + commands(in: user, isProjectDefined: false, fileSystem: fileSystem)
    }

    private static func commands(in directory: URL,
                                 isProjectDefined: Bool,
                                 fileSystem: any FileSystem) -> [SlashCommand] {
        guard fileSystem.isDirectory(at: directory),
              let entries = try? fileSystem.contentsOfDirectory(at: directory) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                SlashCommand(
                    id: "codex.command.\(url.path)",
                    name: "/" + url.deletingPathExtension().lastPathComponent,
                    summary: summary(at: url, fileSystem: fileSystem),
                    isProjectDefined: isProjectDefined
                )
            }
    }

    private static func summary(at url: URL,
                                fileSystem: any FileSystem) -> String {
        guard let data = try? fileSystem.readData(at: url),
              let text = String(data: data, encoding: .utf8) else {
            return "Custom Codex command."
        }
        for line in text.split(separator: "\n") where line.hasPrefix("description:") {
            return line.split(separator: ":", maxSplits: 1)
                .last.map { $0.trimmingCharacters(in: .whitespaces) }
                ?? "Custom Codex command."
        }
        return "Custom Codex command."
    }
}
