import Foundation
import Testing
@testable import ClaudeCode
import AgentTestSupport

@Suite("ClaudeHookInstaller — idempotent settings merge")
struct ClaudeHookInstallerTests {

    @Test("Installer writes managed hook entries for every lifecycle event")
    func writesManagedEntries() throws {
        let fs = InMemoryFileSystem()
        let installer = ClaudeHookInstaller(fileSystem: fs)
        let workspace = URL(fileURLWithPath: "/tmp/workspace")
        let url = try installer.install(socketPath: "/tmp/hook.sock", into: workspace)

        let data = try fs.readData(at: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any] ?? [:]

        let preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        #expect(!preToolUse.isEmpty)
        #expect(preToolUse.first?["codemixer.managed"] as? Bool == true)
        #expect(preToolUse.first?["matcher"] as? String == "*")
        let commands = (preToolUse.first?["hooks"] as? [[String: Any]] ?? [])
            .compactMap { $0["command"] as? String }
        #expect(commands.contains { $0.contains("/usr/bin/python3 -c") })
        #expect(commands.contains { $0.contains("/tmp/hook.sock") })

        #expect(hooks["PostToolUse"] as? [[String: Any]] != nil)
        #expect(hooks["UserPromptSubmit"] as? [[String: Any]] != nil)
        #expect(hooks["SessionStart"] as? [[String: Any]] != nil)
    }

    @Test("Second install is a no-op on shape (same managed keys present)")
    func idempotent() throws {
        let fs = InMemoryFileSystem()
        let installer = ClaudeHookInstaller(fileSystem: fs)
        let workspace = URL(fileURLWithPath: "/tmp/workspace")
        let url1 = try installer.install(socketPath: "/tmp/a.sock", into: workspace)
        let url2 = try installer.install(socketPath: "/tmp/a.sock", into: workspace)
        #expect(url1 == url2)
        let first = try fs.readData(at: url1)
        let second = try fs.readData(at: url2)
        #expect(first == second)
    }

    @Test("Installer replaces stale Codemixer spike hooks but preserves user hooks")
    func replacesStaleSpikeHooksPreservingUserHooks() throws {
        let fs = InMemoryFileSystem()
        let installer = ClaudeHookInstaller(fileSystem: fs)
        let workspace = URL(fileURLWithPath: "/tmp/workspace")
        let url = installer.settingsURL(for: workspace)
        try fs.createDirectory(at: url.deletingLastPathComponent(), withIntermediates: true)
        let existing = Data("""
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "socat - UNIX-CONNECT:/tmp/codemixer-spike-hook-123.sock"
                  }
                ]
              },
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/true"
                  }
                ]
              }
            ]
          }
        }
        """.utf8)
        try fs.writeAtomically(existing, to: url)

        try installer.install(socketPath: "/tmp/live.sock", into: workspace)

        let data = try fs.readData(at: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any] ?? [:]
        let preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let commands = preToolUse.flatMap {
            ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        #expect(commands.contains("/usr/bin/true"))
        #expect(!commands.contains { $0.contains("codemixer-spike-hook") })
        #expect(commands.contains { $0.contains("/tmp/live.sock") })
    }
}
