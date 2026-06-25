import Foundation
import Testing
@testable import ClaudeCode
import AgentCore

@Suite("ClaudeSlashCommands")
struct ClaudeSlashCommandsTests {

    @Test("builtIn catalog contains expected named commands")
    func builtInCatalog() {
        let names = Set(ClaudeSlashCommands.builtIn.map(\.name))
        let required: Set<String> = [
            "/clear", "/compact", "/model", "/help",
            "/resume", "/login", "/think", "/review", "/permission",
        ]
        #expect(required.isSubset(of: names))
    }

    @Test("builtIn commands all have non-empty ids, names starting with '/', and non-empty summaries")
    func builtInShapeValid() {
        for cmd in ClaudeSlashCommands.builtIn {
            #expect(!cmd.id.isEmpty, "empty id: \(cmd.name)")
            #expect(cmd.name.hasPrefix("/"), "name should start with /: \(cmd.name)")
            #expect(!cmd.summary.isEmpty, "empty summary: \(cmd.name)")
        }
    }

    @Test("enumerateProjectCommands returns empty for a workspace with no .claude/commands dir")
    func enumerateEmpty() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-no-commands-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = ClaudeSlashCommands.enumerateProjectCommands(
            workspace: tmp,
            claudeDirectory: tmp.appendingPathComponent("fake-claude", isDirectory: true)
        )
        #expect(result.isEmpty)
    }

    @Test("enumerateProjectCommands picks up .md files in workspace/.claude/commands")
    func enumerateWorkspaceCommands() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-ws-\(UUID().uuidString)", isDirectory: true)
        let commandsDir = workspace.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let content = """
        ---
        description: My custom deploy command.
        ---
        Do the deploy.
        """
        try content.write(to: commandsDir.appendingPathComponent("deploy.md"),
                          atomically: true, encoding: .utf8)

        let result = ClaudeSlashCommands.enumerateProjectCommands(
            workspace: workspace,
            claudeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fake-claude-\(UUID().uuidString)", isDirectory: true)
        )
        #expect(!result.isEmpty)
        let deploy = result.first(where: { $0.name == "/deploy" })
        #expect(deploy != nil)
        #expect(deploy?.summary == "My custom deploy command.")
        #expect(deploy?.isProjectDefined == true)
    }

    @Test("enumerateProjectCommands uses 'Custom command.' fallback when no frontmatter description")
    func enumerateFallbackSummary() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-ws2-\(UUID().uuidString)", isDirectory: true)
        let commandsDir = workspace.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "Just a plain markdown file.".write(
            to: commandsDir.appendingPathComponent("review.md"),
            atomically: true, encoding: .utf8)

        let result = ClaudeSlashCommands.enumerateProjectCommands(
            workspace: workspace,
            claudeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fake-claude-\(UUID().uuidString)", isDirectory: true)
        )
        let review = result.first(where: { $0.name == "/review" })
        #expect(review?.summary == "Custom command.")
    }
}
