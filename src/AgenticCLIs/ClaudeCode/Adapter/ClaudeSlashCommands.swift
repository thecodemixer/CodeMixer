import Foundation
import AgentCore

/// Built-in catalog of Claude's slash commands.
public enum ClaudeSlashCommands {

    public static let builtIn = ClaudeBuiltInSlashCommands.all

    /// Glob `~/.claude/commands/**/*.md` + `<workspace>/.claude/commands/**/*.md`
    /// and return them as `SlashCommand` values flagged `isProjectDefined`
    /// appropriately.
    public static func enumerateProjectCommands(workspace: URL,
                                                claudeDirectory: URL,
                                                fileSystem: any FileSystem = SystemFileSystem()) -> [SlashCommand] {
        let workspaceCommandsDir = workspace.appendingPathComponent(".claude/commands", isDirectory: true)
        let userCommandsDir = claudeDirectory.appendingPathComponent("commands", isDirectory: true)

        return scan(directory: workspaceCommandsDir,
                    isProjectDefined: true,
                    fileSystem: fileSystem) +
               scan(directory: userCommandsDir,
                    isProjectDefined: false,
                    fileSystem: fileSystem)
    }

    private static func scan(directory: URL,
                             isProjectDefined: Bool,
                             fileSystem: any FileSystem) -> [SlashCommand] {
        guard fileSystem.isDirectory(at: directory),
              let entries = try? recursiveContents(of: directory, fileSystem: fileSystem) else { return [] }
        var commands: [SlashCommand] = []
        for url in entries where url.pathExtension == "md" {
            let name = "/" + url.deletingPathExtension().lastPathComponent
            let summary = readFirstFrontmatterDescription(at: url,
                                                          fileSystem: fileSystem) ?? "Custom command."
            commands.append(SlashCommand(id: "custom.\(url.path)",
                                         name: name,
                                         summary: summary,
                                         isProjectDefined: isProjectDefined))
        }
        return commands
    }

    private static func recursiveContents(of directory: URL,
                                          fileSystem: any FileSystem) throws -> [URL] {
        var output: [URL] = []
        for entry in try fileSystem.contentsOfDirectory(at: directory) {
            if fileSystem.isDirectory(at: entry) {
                output.append(contentsOf: try recursiveContents(of: entry, fileSystem: fileSystem))
            } else {
                output.append(entry)
            }
        }
        return output
    }

    private static func readFirstFrontmatterDescription(at url: URL,
                                                       fileSystem: any FileSystem) -> String? {
        guard let data = try? fileSystem.readData(at: url),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("---") else { return nil }
        let lines = text.split(separator: "\n")
        for line in lines {
            if line.hasPrefix("description:") {
                return line.split(separator: ":", maxSplits: 1).last
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }
}
