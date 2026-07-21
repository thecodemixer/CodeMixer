import Foundation
import Testing
@testable import ClaudeCode
import AgentTestSupport
import AgentCore

@Suite("ClaudeHookInstaller — idempotent settings merge")
struct ClaudeHookInstallerTests {

    @Test("Installer writes managed hook entries for every lifecycle event")
    func writesManagedEntries() throws {
        let fs = InMemoryFileSystem()
        let installer = ClaudeHookInstaller(fileSystem: fs)
        let workspace = TestPaths.underTemporary("workspace")
        let socket = TestPaths.underTemporary("hook.sock", isDirectory: false).path
        let url = try installer.install(socketPath: socket, into: workspace)

        let data = try fs.readData(at: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any] ?? [:]

        let preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        #expect(!preToolUse.isEmpty)
        #expect(preToolUse.first?["codemixer.managed"] as? Bool == true)
        #expect(preToolUse.first?["matcher"] as? String == "*")
        let commands = (preToolUse.first?["hooks"] as? [[String: Any]] ?? [])
            .compactMap { $0["command"] as? String }
        #expect(commands.contains { $0.contains("\(SystemPaths.python3.path) -c") })
        #expect(commands.contains { $0.contains(socket) })

        #expect(hooks["PostToolUse"] as? [[String: Any]] != nil)
        #expect(hooks["UserPromptSubmit"] as? [[String: Any]] != nil)
        #expect(hooks["SessionStart"] as? [[String: Any]] != nil)
    }

    @Test("Second install is a no-op on shape (same managed keys present)")
    func idempotent() throws {
        let fs = InMemoryFileSystem()
        let installer = ClaudeHookInstaller(fileSystem: fs)
        let workspace = TestPaths.underTemporary("workspace")
        let sockA = TestPaths.underTemporary("a.sock", isDirectory: false).path
        let url1 = try installer.install(socketPath: sockA, into: workspace)
        let url2 = try installer.install(socketPath: sockA, into: workspace)
        #expect(url1 == url2)
        let first = try fs.readData(at: url1)
        let second = try fs.readData(at: url2)
        #expect(first == second)
    }

    @Test("Installer replaces stale Codemixer spike hooks but preserves user hooks")
    func replacesStaleSpikeHooksPreservingUserHooks() throws {
        let fs = InMemoryFileSystem()
        let installer = ClaudeHookInstaller(fileSystem: fs)
        let workspace = TestPaths.underTemporary("workspace")
        let url = installer.settingsURL(for: workspace)
        try fs.createDirectory(at: url.deletingLastPathComponent(), withIntermediates: true)
        let userHook = SystemPaths.trueBinary.path
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
                    "command": "\(userHook)"
                  }
                ]
              }
            ]
          }
        }
        """.utf8)
        try fs.writeAtomically(existing, to: url)

        let liveSocket = TestPaths.underTemporary("live.sock", isDirectory: false).path
        try installer.install(socketPath: liveSocket, into: workspace)

        let data = try fs.readData(at: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any] ?? [:]
        let preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let commands = preToolUse.flatMap {
            ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        #expect(commands.contains(userHook))
        #expect(!commands.contains { $0.contains("codemixer-spike-hook") })
        #expect(commands.contains { $0.contains(liveSocket) })
    }
}
